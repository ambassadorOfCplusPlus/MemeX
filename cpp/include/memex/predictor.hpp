// Expert demand prediction for the MemeX paging engine.
//
// Two horizons, matching the two control loops:
//   short  — which experts does the NEXT layer of the current token need?
//            Prefetch must land within one layer of compute, so accuracy here
//            decides whether a load is hidden or becomes a stall.
//   long   — which experts will be needed within the next few tokens?
//            This drives the slow loop: migrate into VRAM/RAM the set that is
//            about to matter, evict the set that stopped mattering, all async.
//
// Everything learns online from the routing decisions the model already makes,
// so no offline training and no model-specific code is required.
#pragma once

#include <cstdint>
#include <deque>
#include <unordered_map>
#include <vector>

#include "memex/expert_cache.hpp"

namespace memex {

struct PredictorStats {
    uint64_t predicted = 0;   // experts we asked to prefetch
    uint64_t hits = 0;        // of those, actually used
    uint64_t needed = 0;      // experts actually used
    double recall() const { return needed ? double(hits) / double(needed) : 0.0; }
    double precision() const {
        return predicted ? double(hits) / double(predicted) : 0.0;
    }
};

class ExpertPredictor {
  public:
    ExpertPredictor(uint32_t layers, uint32_t experts_per_layer);
    virtual ~ExpertPredictor() = default;

    // Ground truth for layer `layer` of the current token.
    virtual void observe(uint32_t layer, const std::vector<ExpertId>& active);
    // Short horizon: fill `out` with up to `budget` guesses for `layer`.
    virtual void predict(uint32_t layer, int budget, std::vector<ExpertId>* out) = 0;
    // Long horizon: the set worth keeping resident over the next few tokens.
    virtual void warm_set(int budget, std::vector<ExpertId>* out);
    virtual void end_of_token() {}

    // Scoring helper: call once per layer with prediction and truth.
    void score(const std::vector<ExpertId>& predicted,
               const std::vector<ExpertId>& actual);
    const PredictorStats& stats() const { return stats_; }

  protected:
    uint32_t layers_;
    uint32_t per_layer_;
    std::vector<std::vector<ExpertId>> last_active_;  // per layer, previous token
    std::vector<double> popularity_;                  // EMA per expert
    PredictorStats stats_;
};

// Baseline: whatever this layer used on the previous token. Cheap, and stronger
// than it sounds because expert choice is temporally sticky.
class PersistPredictor : public ExpertPredictor {
  public:
    using ExpertPredictor::ExpertPredictor;
    void predict(uint32_t layer, int budget, std::vector<ExpertId>* out) override;
};

// Baseline: the globally hottest experts of that layer (EMA popularity).
class PopularityPredictor : public ExpertPredictor {
  public:
    PopularityPredictor(uint32_t layers, uint32_t experts_per_layer);
    void predict(uint32_t layer, int budget, std::vector<ExpertId>* out) override;

  private:
    std::vector<std::vector<ExpertId>> order_;  // per layer, by popularity
    int since_sort_ = 0;
};

// Online co-activation model: for every expert seen in layer i, count which
// experts followed in layer i+1. Prediction = vote over the successors of the
// experts just observed. This is the trainable-free analogue of reading the
// next layer's gate early, and it needs no access to model internals.
class CoocPredictor : public ExpertPredictor {
  public:
    CoocPredictor(uint32_t layers, uint32_t experts_per_layer, int max_succ = 24);
    void observe(uint32_t layer, const std::vector<ExpertId>& active) override;
    void predict(uint32_t layer, int budget, std::vector<ExpertId>* out) override;
    // Learned transition edges out of `from`, for multi-hop demand estimation.
    void successors(ExpertId from,
                    std::vector<std::pair<ExpertId, uint32_t>>* out) const;

  private:
    struct Succ {
        std::vector<std::pair<ExpertId, uint32_t>> counts;  // capped, sorted
    };
    void bump(ExpertId from, ExpertId to);
    std::unordered_map<ExpertId, Succ> succ_;
    std::vector<ExpertId> prev_layer_active_;
    uint32_t prev_layer_ = UINT32_MAX;
    int max_succ_;
};

// Long-horizon demand model: ranks every expert by how likely it is to be needed
// within the next few tokens. Three signals, each covering a different case:
//   popularity — steady demand across the whole request (EMA)
//   recency    — the working set of the last few tokens (exponential decay)
//   reachability — successors of the experts active right now, from the online
//                  co-activation graph, i.e. demand that has not happened yet
// The resulting ranking is what gets sliced across VRAM / RAM / disk.
class HorizonPredictor : public ExpertPredictor {
  public:
    HorizonPredictor(uint32_t layers, uint32_t experts_per_layer,
                     int horizon_tokens = 4);
    void observe(uint32_t layer, const std::vector<ExpertId>& active) override;
    void predict(uint32_t layer, int budget, std::vector<ExpertId>* out) override;
    void warm_set(int budget, std::vector<ExpertId>* out) override;
    void end_of_token() override;

  private:
    CoocPredictor cooc_;
    std::vector<uint64_t> last_seen_;      // token index of last use
    std::vector<ExpertId> active_now_;     // experts used during this token
    std::vector<double> reach_;            // scratch: reachability scores
    uint64_t token_ = 1;
    int horizon_;
};

// Union of co-activation, persistence and popularity, in that priority order:
// each mechanism covers a different failure mode of the others.
class HybridPredictor : public ExpertPredictor {
  public:
    HybridPredictor(uint32_t layers, uint32_t experts_per_layer);
    void observe(uint32_t layer, const std::vector<ExpertId>& active) override;
    void predict(uint32_t layer, int budget, std::vector<ExpertId>* out) override;
    void warm_set(int budget, std::vector<ExpertId>* out) override;
    void end_of_token() override;

  private:
    CoocPredictor cooc_;
    PersistPredictor persist_;
    PopularityPredictor popular_;
};

}  // namespace memex
