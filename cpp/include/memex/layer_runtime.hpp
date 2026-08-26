// The three finished pieces, wired together: policy decides, loader fetches, compute
// uses whatever is resident right now.
//
// Until this existed each piece was verified alone - the blob format bit-exact, the
// loader reading around the file cache, the dispatch computing a layer at 1.245 ms -
// while the policies that decide *which* precision each expert should have ran only
// against recorded traces with a cost model standing in for the disk. That is exactly
// the arrangement that hides the interesting failures: a promotion that never arrives
// in time, a queue that fills, a swap that lands while the expert is being read.
//
// So this owns the runtime state of one layer: for every expert, which precision is
// currently in memory, which promotion is in flight, and the buffer each one lives in.
// Rules that came out of measurement and are enforced here rather than assumed:
//
//   * an expert is always usable. A promotion writes into a freshly allocated buffer
//     and only swaps the pointer when the read has finished, so no request ever waits
//     and no reader ever sees a half-written tensor.
//   * a miss is computed, never awaited. Computing an expert from RAM costs 0.18 ms
//     against 0.98 ms to fetch it, so the fetch only ever pays for later tokens.
//   * fetches are bounded. The link delivers ~177 experts/s from SSD and ~47/s from
//     the spinning disk against a ~113 ms token, so the queue must be short enough
//     that the policy cannot promise transfers the disk will not deliver.
#pragma once

#include <atomic>
#include <cstdint>
#include <memory>
#include <mutex>
#include <string>
#include <unordered_map>
#include <vector>

#include "memex/blob_loader.hpp"

namespace memex {

// A resident copy of one expert tensor: the bytes, and which ggml type they are in.
// The buffer is shared so that a reader can hold it alive across a precision change:
// a promotion completing on a loader thread must not free memory a compute in flight
// is still reading from.
struct ResidentTensor {
    std::shared_ptr<AlignedBuffer> buf;
    int32_t ggml_type = -1;
    uint32_t bytes = 0;
    uint32_t rows = 0;
    uint32_t cols = 0;
};

// One expert: three tensors, plus what is happening to it.
struct ResidentExpert {
    ResidentTensor t[3];              // up, gate, down - what readers see now
    ResidentTensor staging[3];        // where a move in progress lands
    // The coarse copy is kept alive while the expert is promoted, EPLB's redundant
    // expert idea applied to precision: demotion then costs a pointer swap instead of
    // three disk reads, so no move ever has to wait on the disk.
    ResidentTensor coarse[3];
    bool has_coarse = false;
    std::string step;                 // ladder step currently in memory
    std::atomic<int> pending{0};      // tensors still arriving for the move
    bool moving = false;
    bool target_source = false;       // direction of the move in progress
};

struct RuntimeStats {
    uint64_t tokens = 0;
    uint64_t rebalances = 0;
    uint64_t instant_demotions = 0;   // served by the retained coarse copy
    uint64_t expert_uses = 0;
    uint64_t uses_at_source = 0;      // served by full-precision weights
    uint64_t promotions_started = 0;
    uint64_t promotions_done = 0;
    uint64_t promotions_dropped = 0;  // queue was full - policy asked for too much
    uint64_t demotions = 0;
    double degraded_share() const {
        return expert_uses ? 1.0 - double(uses_at_source) / double(expert_uses) : 0.0;
    }
};

// Runtime for one layer's experts. Deliberately not a cache: nothing is ever absent,
// only coarser or finer, which is what removes waiting from the design entirely.
class LayerRuntime {
  public:
    LayerRuntime(BlobLoader* loader, uint32_t layer, int n_experts)
        : loader_(loader), layer_(layer), n_(n_experts), experts_(n_experts) {}

    // Load every expert. Startup path, so it reads synchronously; the moves later are
    // the asynchronous ones. At most `full_budget_` experts are loaded at source
    // precision - otherwise the policy would start over budget and never promote.
    bool prime(std::string* err);

    // Charge one token's demand and let the policy act on it. `ids` are the experts
    // the router chose. Returns how many of them were served at full precision.
    int on_token(const std::vector<int>& ids);

    // Feed the prompt's own routing before generation starts. The prefill computes
    // these decisions anyway, and a set built from the first 128 prompt tokens covered
    // 91% of what an oracle would have chosen, so this is the cheapest predictor
    // available - it costs nothing and it removes the cold start.
    void prime_from_prefill(const std::vector<std::vector<int>>& prompt_ids);

    // Recompute the wanted full-precision set from the window and issue up to
    // `max_moves_` moves towards it. Called automatically every rebalance_every_
    // tokens; exposed so the prefill path can rebalance once before the first token.
    void rebalance();

    // A promotion target: how many experts may hold full precision at once. Sized by
    // memory, and the reason it is a knob at all is that the measured degradation on
    // code fell from 22.9% to 5.3% when this grew from 1843 to 4000 slots model-wide.
    void set_full_budget(int n) { full_budget_ = n; }

    const ResidentExpert& expert(int e) const { return experts_[e]; }

    // A reader's view of one expert: buffers pinned by reference for as long as the
    // caller keeps this alive, so a concurrent move cannot pull them away mid-compute.
    struct Held {
        std::shared_ptr<AlignedBuffer> buf[3];
        int32_t ggml_type[3] = {-1, -1, -1};
        bool ok = false;
    };
    Held hold(int e) const;
    const RuntimeStats& stats() const { return stats_; }
    // Bytes currently held by this layer's experts, so the caller can see the real
    // footprint rather than the planned one.
    std::size_t resident_bytes() const;

  private:
    struct Arrival {
        LayerRuntime* self;
        int expert;
        int slot;                     // 0 up, 1 gate, 2 down
    };

    static void on_arrival(const BlobEntry& e, uint8_t* data, void* user);
    bool read_into(const BlobEntry& e, ResidentTensor* t);
    // One mechanism for both directions: staged read, then an atomic swap.
    bool retarget(int expert, bool want_source);
    int weakest_full(int keep) const;

    BlobLoader* loader_;
    uint32_t layer_;
    int n_;
    std::vector<ResidentExpert> experts_;
    std::vector<uint32_t> uses_;      // per expert, for the ranking
    std::vector<double> ema_;
    int full_count_ = 0;
    int full_budget_ = 32;            // per layer; 4000/48 ≈ 83 model-wide at Q6
    int in_flight_ = 0;
    int max_in_flight_ = 8;
    double ema_alpha_ = 0.02;
    double promote_margin_ = 1.5;
    // Window and cadence, after EPLB's window-size / step-interval pair. The move
    // budget is what keeps a rebalance inside what the disk can deliver before the
    // next one arrives.
    std::vector<uint32_t> window_;     // per-expert load inside the window
    uint64_t window_tokens_ = 0;
    uint64_t window_size_ = 512;
    uint64_t rebalance_every_ = 256;
    int max_moves_ = 8;
    mutable std::mutex mu_;
    RuntimeStats stats_;
    // Arrivals are owned here so a completion callback never touches freed memory.
    std::vector<std::unique_ptr<Arrival>> arrivals_;
};

}  // namespace memex
