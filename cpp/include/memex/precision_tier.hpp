// Adaptive precision: every expert is always usable, and precision follows demand.
//
// The problem this solves. Experts must fit in RAM - the model is 26.3 GB against
// 31.9 GB of memory, and once the page cache cannot hold it, generation faults its
// weights off the disk. Compressing everything would fit, but it damages the few
// experts that carry the work: use is heavily skewed, the hot 30% serve ~78% of all
// routing decisions, and 4-bit costs those weights ~8% relative error.
//
// The resolution is to make precision a function of demand instead of a global
// choice: hot experts full precision, cold experts compressed, and the assignment
// moves as the task moves. Both copies live on disk, so an upgrade is a read rather
// than a recomputation.
//
// Two rules make it safe and non-disruptive, and both come from measurement:
//
//   * write the new copy into a fresh slot and only then release the old one. There
//     is never a moment when an expert has no usable weights, so generation never
//     waits and never sees a torn tensor. The transient cost is one extra slot per
//     upgrade in flight, which the 11 GB of headroom covers easily.
//   * upgrades must read around the file cache. A background reader pulling experts
//     through the cache evicted the model's own pages and cost 37% of generation
//     speed (8.04 -> 5.05 tok/s measured). Unbuffered reads are not an optimisation
//     here, they are a correctness condition for "asynchronous and non-disruptive".
//
// Measured rates this is sized against: 177.5 experts/s from the SATA SSD, 47.5/s
// from the spinning disk, both for expert-sized (1.29 MB) random reads.
#pragma once

#include <algorithm>
#include <cstddef>
#include <cstdint>
#include <deque>
#include <unordered_map>
#include <vector>

namespace memex {

using SlotId = uint32_t;

enum class Precision : uint8_t { Compressed = 0, Full = 1 };

struct PrecisionConfig {
    // How many experts may be worth keeping at full precision. Sized by memory, not
    // by taste: full experts cost 1.29 MB, compressed ones 0.88 MB.
    std::size_t full_budget = 1843;          // ~30% of 6144 slots
    double upgrade_per_second = 177.5;       // measured, SSD, unbuffered
    double downgrade_per_second = 400.0;     // compression is cheaper than reading
    std::size_t max_in_flight = 64;          // bounds the transient memory
    // One expert is three tensors - up, gate and down - so a slot is their sum, not
    // a single matrix. Getting this wrong understated the memory at stake by 3.3x.
    double full_mb = 4.25;                   // 1.29 + 1.29 + 1.67 at Q6/Q8
    double compressed_mb = 2.64;             // three tensors at 4 bits
    // Hysteresis. A first version promoted anything used a few times and thrashed:
    // 118k upgrades against 117k demotions, every one of them wasted, because the
    // budget holds 1843 slots while a trace touches 5849. Promotion now requires
    // beating the weakest full-precision expert by a clear margin, measured on
    // smoothed demand rather than raw counts.
    double ema_alpha = 0.02;
    double promote_margin = 1.5;
};

struct PrecisionStats {
    uint64_t accesses = 0;
    uint64_t served_compressed = 0;
    uint64_t upgrades = 0;
    uint64_t downgrades = 0;
    uint64_t upgrades_wasted = 0;   // upgraded, then demoted without being used
    std::size_t peak_in_flight = 0;
    double peak_extra_mb = 0.0;
    double degraded_share() const {
        return accesses ? double(served_compressed) / double(accesses) : 0.0;
    }
};

// Models the double-buffered promotion: a new slot is filled while the old one keeps
// serving, and the swap happens only when the copy is complete.
class PrecisionTier {
  public:
    explicit PrecisionTier(PrecisionConfig cfg) : cfg_(cfg) {}

    // One generated token: charge the accesses and note demand. `token_ms` is how
    // long the token took, which is the budget the background loader gets.
    void on_token(const std::vector<SlotId>& used, double token_ms) {
        // Decay first, so an expert that stopped being used falls behind even if
        // nothing new arrives to displace it.
        for (auto& kv : state_) {
            kv.second.ema *= (1.0 - cfg_.ema_alpha);
        }
        for (SlotId s : used) {
            Entry& e = state_[s];
            e.uses++;
            e.ema += cfg_.ema_alpha;
            stats_.accesses++;
            // An expert being upgraded still serves from its old copy - that is the
            // whole point of writing the new one separately.
            if (e.precision == Precision::Compressed) {
                stats_.served_compressed++;
            }
        }
        advance(token_ms);
        plan(used);
    }

    const PrecisionStats& stats() const { return stats_; }
    std::size_t full_count() const { return full_; }
    std::size_t in_flight() const { return flight_.size(); }

    Precision precision_of(SlotId s) const {
        auto it = state_.find(s);
        return it == state_.end() ? Precision::Compressed : it->second.precision;
    }

  private:
    struct Entry {
        uint32_t uses = 0;
        uint32_t uses_at_last_change = 0;
        double ema = 0.0;              // smoothed demand, the ranking signal
        Precision precision = Precision::Compressed;
        bool upgrading = false;
    };

    struct InFlight {
        SlotId slot;
        double remaining_ms;
    };

    // Spend the token's worth of background time on the copies in flight. Only when
    // a copy finishes does the expert switch precision and the old slot come back.
    void advance(double token_ms) {
        double budget = token_ms;
        while (budget > 0.0 && !flight_.empty()) {
            InFlight& f = flight_.front();
            const double take = std::min(budget, f.remaining_ms);
            f.remaining_ms -= take;
            budget -= take;
            if (f.remaining_ms > 1e-9) {
                break;
            }
            Entry& e = state_[f.slot];
            e.upgrading = false;
            e.precision = Precision::Full;
            e.uses_at_last_change = e.uses;
            full_++;
            stats_.upgrades++;
            flight_.pop_front();
        }
        stats_.peak_in_flight = std::max(stats_.peak_in_flight, flight_.size());
        stats_.peak_extra_mb = std::max(
                stats_.peak_extra_mb, double(flight_.size()) * cfg_.full_mb);
    }

    void plan(const std::vector<SlotId>& used) {
        const double upgrade_ms = 1000.0 / cfg_.upgrade_per_second;
        for (SlotId s : used) {
            Entry& e = state_[s];
            if (e.precision == Precision::Full || e.upgrading) {
                continue;
            }
            if (flight_.size() >= cfg_.max_in_flight) {
                break;
            }
            // Under budget: take the slot outright. Over budget: only displace the
            // weakest full-precision expert, and only by a clear margin, otherwise
            // the two swap places forever and the disk works for nothing.
            if (full_ + flight_.size() >= cfg_.full_budget) {
                const SlotId victim = weakest_full(s);
                if (victim == kNone ||
                    state_[s].ema < state_[victim].ema * cfg_.promote_margin) {
                    continue;
                }
                demote(victim);
            }
            e.upgrading = true;
            flight_.push_back({s, upgrade_ms});
        }
    }

    static constexpr SlotId kNone = 0xFFFFFFFFu;

    SlotId weakest_full(SlotId keep) const {
        SlotId victim = kNone;
        double worst = 1e300;
        for (const auto& kv : state_) {
            if (kv.first == keep || kv.second.precision != Precision::Full ||
                kv.second.upgrading) {
                continue;
            }
            if (kv.second.ema < worst) {
                worst = kv.second.ema;
                victim = kv.first;
            }
        }
        return victim;
    }

    void demote(SlotId victim) {
        Entry& v = state_[victim];
        if (v.uses == v.uses_at_last_change) {
            stats_.upgrades_wasted++;   // upgraded and never used at full precision
        }
        v.precision = Precision::Compressed;
        v.uses_at_last_change = v.uses;
        full_--;
        stats_.downgrades++;
    }

    PrecisionConfig cfg_;
    std::unordered_map<SlotId, Entry> state_;
    std::deque<InFlight> flight_;
    std::size_t full_ = 0;
    PrecisionStats stats_;
};

}  // namespace memex
