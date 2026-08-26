// Residency policy: which experts live in fast memory, decided while generation
// runs and never blocking it.
//
// The mechanism (slots, tiers, loader threads) lives in ExpertCache. This is only
// the decision layer, kept separate so it can be replayed against a recorded
// routing trace and scored before it is wired into the runtime.
//
// Three measured facts shape it, and each one rules out an obvious design:
//
//   * computing a missing expert on the CPU costs 0.18 ms, fetching it over PCIe
//     3.0 x4 costs 0.98 ms. A miss must therefore never be served by a transfer -
//     the transfer only ever pays for *future* tokens;
//   * consecutive tokens share about half their experts, so the demand stream is
//     predictable enough to prefetch, but the per-token delta still needs 743 MB
//     of transfers against ~113 ms of compute. The link cannot keep up with
//     demand, so fetches must live inside an explicit budget instead of chasing
//     every miss;
//   * expert use is heavily skewed: the hottest ~10% of slots serve ~64% of all
//     routing decisions. A resident set chosen by popularity therefore earns far
//     more than one chosen by recency, and it is worth spending the scarce link
//     bandwidth on climbing towards that set.
//
// The resulting protocol matches the design being tested: warm the set from the
// first token, look a couple of tokens ahead, and revisit the ranking on a fixed
// checkpoint period, with every transfer asynchronous and rate-limited.
#pragma once

#include <algorithm>
#include <cstddef>
#include <cstdint>
#include <unordered_map>
#include <unordered_set>
#include <vector>

namespace memex {

using SlotId = uint32_t;   // global expert index: layer * n_experts + local id

struct ResidencyConfig {
    std::size_t capacity = 594;      // experts that fit in the device tier
    int lookahead_tokens = 2;        // how far the predictor forecasts
    int checkpoint_every = 3;        // tokens between ranking revisions
    double link_gbs = 3.94;          // PCIe 3.0 x4, measured ceiling
    double expert_mb = 3.87;         // one expert at the model's precision
    // Fetches may only use the part of the link that generation leaves idle;
    // above 1.0 the queue would grow without bound and the policy would be
    // promising transfers it cannot deliver.
    double link_duty = 1.0;
    bool popularity_ranking = true;  // rank by smoothed use, not by recency
    double ema_alpha = 0.05;
    bool warm_first_token = true;    // push the first token's experts up front
};

struct ResidencyStats {
    uint64_t lookups = 0;
    uint64_t hits = 0;             // served from the device tier
    uint64_t misses = 0;           // computed on the CPU instead
    uint64_t fetched = 0;          // experts actually transferred
    uint64_t fetch_wasted = 0;     // transferred but never used again
    uint64_t evicted = 0;
    double link_ms = 0.0;          // time the link was busy
    double hit_rate() const {
        return lookups ? double(hits) / double(lookups) : 0.0;
    }
};

// Replay-friendly policy object: it is told what a token needed, and what the
// predictor thinks the next tokens will need, and it answers with fetches that
// fit the link budget. It never returns "wait".
class ResidencyPolicy {
  public:
    explicit ResidencyPolicy(ResidencyConfig cfg) : cfg_(cfg) {
        fetch_cost_ms_ = cfg_.expert_mb / cfg_.link_gbs;
    }

    // Charge the demand of one token. `needed` are the experts this token routed
    // to; returns how many of them were resident (the rest are computed on the
    // CPU, which is cheaper than waiting for a transfer).
    std::size_t on_token(const std::vector<SlotId>& needed) {
        std::size_t hits = 0;
        for (SlotId s : needed) {
            auto& e = state_[s];
            e.uses++;
            e.last_use = clock_;
            if (resident_.count(s)) {
                hits++;
                e.useful = true;
            }
        }
        stats_.lookups += needed.size();
        stats_.hits += hits;
        stats_.misses += needed.size() - hits;
        clock_++;
        return hits;
    }

    // Decay popularity so a set that was hot long ago gives way to the current
    // one. Called once per token, before planning.
    void age() {
        for (auto& kv : state_) {
            kv.second.pop *= (1.0 - cfg_.ema_alpha);
            if (kv.second.last_use + 1 == clock_) {
                kv.second.pop += cfg_.ema_alpha * double(kv.second.uses_this_token);
            }
            kv.second.uses_this_token = 0;
        }
    }

    void note_use_for_ranking(const std::vector<SlotId>& needed) {
        for (SlotId s : needed) {
            state_[s].uses_this_token++;
        }
    }

    // Plan transfers for the coming tokens. `forecast` is what the predictor
    // expects to be needed; only the part that is missing and that fits into the
    // budget is fetched, and the budget is the link time generation leaves free.
    void plan(const std::vector<SlotId>& forecast, double token_ms) {
        budget_ms_ += token_ms * cfg_.link_duty;
        // Candidates: forecast first (imminent demand), then the popularity
        // ranking, so a spare budget keeps climbing towards the hot set instead
        // of idling.
        for (SlotId s : forecast) {
            if (budget_ms_ < fetch_cost_ms_) {
                break;
            }
            if (!resident_.count(s)) {
                admit(s);
            }
        }
        if (!cfg_.popularity_ranking) {
            return;
        }
        if (clock_ % cfg_.checkpoint_every != 0) {
            return;
        }
        // Checkpoint: revisit the ranking. This is where the resident set drifts
        // towards the globally hot experts rather than the last few tokens.
        std::vector<std::pair<double, SlotId>> ranked;
        ranked.reserve(state_.size());
        for (auto& kv : state_) {
            if (!resident_.count(kv.first)) {
                ranked.push_back({kv.second.pop, kv.first});
            }
        }
        std::sort(ranked.begin(), ranked.end(),
                  [](const auto& a, const auto& b) { return a.first > b.first; });
        for (auto& [pop, s] : ranked) {
            if (budget_ms_ < fetch_cost_ms_ || pop <= 0.0) {
                break;
            }
            admit(s);
        }
    }

    // Static warm start from a known popularity order (used to score "what if we
    // already knew the hot set", the ceiling any online policy aims at).
    void preload(const std::vector<SlotId>& order) {
        for (SlotId s : order) {
            if (resident_.size() >= cfg_.capacity) {
                break;
            }
            resident_.insert(s);
        }
    }

    const ResidencyStats& stats() const { return stats_; }
    std::size_t resident_count() const { return resident_.size(); }

  private:
    struct Entry {
        uint32_t uses = 0;
        uint32_t uses_this_token = 0;
        uint64_t last_use = 0;
        double pop = 0.0;
        bool useful = false;
    };

    void admit(SlotId s) {
        if (resident_.size() >= cfg_.capacity && !evict_one()) {
            return;
        }
        resident_.insert(s);
        budget_ms_ -= fetch_cost_ms_;
        stats_.link_ms += fetch_cost_ms_;
        stats_.fetched++;
        state_[s].useful = false;
    }

    bool evict_one() {
        // Drop the least popular resident expert. Weights are read-only, so
        // eviction is just releasing a slot - there is nothing to write back.
        double worst = 1e300;
        SlotId victim = 0;
        bool found = false;
        for (SlotId s : resident_) {
            double p = state_.count(s) ? state_[s].pop : 0.0;
            if (p < worst) {
                worst = p;
                victim = s;
                found = true;
            }
        }
        if (!found) {
            return false;
        }
        if (state_.count(victim) && !state_[victim].useful) {
            stats_.fetch_wasted++;
        }
        resident_.erase(victim);
        stats_.evicted++;
        return true;
    }

    ResidencyConfig cfg_;
    std::unordered_set<SlotId> resident_;
    std::unordered_map<SlotId, Entry> state_;
    ResidencyStats stats_;
    double fetch_cost_ms_ = 0.0;
    double budget_ms_ = 0.0;
    uint64_t clock_ = 0;
};

}  // namespace memex
