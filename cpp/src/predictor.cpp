#include "memex/predictor.hpp"

#include <algorithm>
#include <cmath>
#include <numeric>

namespace memex {
namespace {
constexpr double kEma = 0.05;
}

ExpertPredictor::ExpertPredictor(uint32_t layers, uint32_t experts_per_layer)
    : layers_(layers), per_layer_(experts_per_layer),
      last_active_(layers), popularity_(std::size_t(layers) * experts_per_layer, 0.0) {}

void ExpertPredictor::observe(uint32_t layer, const std::vector<ExpertId>& active) {
    if (layer < layers_) last_active_[layer] = active;
    for (double& p : popularity_) p *= (1.0 - kEma);
    for (ExpertId e : active)
        if (e < popularity_.size()) popularity_[e] += kEma;
}

void ExpertPredictor::warm_set(int budget, std::vector<ExpertId>* out) {
    // Default long-horizon policy: globally hottest experts by EMA popularity.
    out->clear();
    if (budget <= 0) return;
    std::vector<ExpertId> ids(popularity_.size());
    std::iota(ids.begin(), ids.end(), ExpertId(0));
    std::size_t k = std::min<std::size_t>(budget, ids.size());
    std::partial_sort(ids.begin(), ids.begin() + k, ids.end(),
                      [this](ExpertId a, ExpertId b) {
                          return popularity_[a] > popularity_[b];
                      });
    out->assign(ids.begin(), ids.begin() + k);
}

void ExpertPredictor::score(const std::vector<ExpertId>& predicted,
                            const std::vector<ExpertId>& actual) {
    stats_.predicted += predicted.size();
    stats_.needed += actual.size();
    for (ExpertId a : actual)
        if (std::find(predicted.begin(), predicted.end(), a) != predicted.end())
            stats_.hits++;
}

void PersistPredictor::predict(uint32_t layer, int budget,
                               std::vector<ExpertId>* out) {
    out->clear();
    if (layer >= layers_) return;
    const auto& prev = last_active_[layer];
    out->assign(prev.begin(),
                prev.begin() + std::min<std::size_t>(budget, prev.size()));
}

PopularityPredictor::PopularityPredictor(uint32_t layers, uint32_t experts_per_layer)
    : ExpertPredictor(layers, experts_per_layer), order_(layers) {}

void PopularityPredictor::predict(uint32_t layer, int budget,
                                  std::vector<ExpertId>* out) {
    out->clear();
    if (layer >= layers_ || budget <= 0) return;
    // Re-sorting every call would dominate the layer budget; refresh lazily.
    if (order_[layer].empty() || ++since_sort_ > int(layers_) * 32) {
        since_sort_ = 0;
        order_[layer].resize(per_layer_);
        for (uint32_t i = 0; i < per_layer_; ++i)
            order_[layer][i] = ExpertId(layer * per_layer_ + i);
        std::sort(order_[layer].begin(), order_[layer].end(),
                  [this](ExpertId a, ExpertId b) {
                      return popularity_[a] > popularity_[b];
                  });
    }
    std::size_t k = std::min<std::size_t>(budget, order_[layer].size());
    out->assign(order_[layer].begin(), order_[layer].begin() + k);
}

CoocPredictor::CoocPredictor(uint32_t layers, uint32_t experts_per_layer,
                             int max_succ)
    : ExpertPredictor(layers, experts_per_layer), max_succ_(max_succ) {}

void CoocPredictor::bump(ExpertId from, ExpertId to) {
    Succ& s = succ_[from];
    for (auto& kv : s.counts) {
        if (kv.first == to) {
            kv.second++;
            // keep roughly sorted so truncation drops the coldest successors
            std::sort(s.counts.begin(), s.counts.end(),
                      [](const auto& a, const auto& b) { return a.second > b.second; });
            return;
        }
    }
    s.counts.emplace_back(to, 1u);
    if (int(s.counts.size()) > max_succ_) {
        std::sort(s.counts.begin(), s.counts.end(),
                  [](const auto& a, const auto& b) { return a.second > b.second; });
        s.counts.resize(max_succ_);
    }
}

void CoocPredictor::observe(uint32_t layer, const std::vector<ExpertId>& active) {
    ExpertPredictor::observe(layer, active);
    if (prev_layer_ != UINT32_MAX && layer == prev_layer_ + 1) {
        for (ExpertId from : prev_layer_active_)
            for (ExpertId to : active) bump(from, to);
    }
    prev_layer_ = layer;
    prev_layer_active_ = active;
}

void CoocPredictor::successors(
    ExpertId from, std::vector<std::pair<ExpertId, uint32_t>>* out) const {
    out->clear();
    auto it = succ_.find(from);
    if (it != succ_.end()) *out = it->second.counts;
}

void CoocPredictor::predict(uint32_t layer, int budget,
                            std::vector<ExpertId>* out) {
    out->clear();
    if (budget <= 0) return;
    // Vote: every expert active in the previous layer nominates its successors,
    // weighted by how often that transition was observed.
    std::unordered_map<ExpertId, uint32_t> votes;
    if (prev_layer_ != UINT32_MAX && layer == prev_layer_ + 1) {
        for (ExpertId from : prev_layer_active_) {
            auto it = succ_.find(from);
            if (it == succ_.end()) continue;
            for (const auto& [to, count] : it->second.counts) votes[to] += count;
        }
    }
    if (votes.empty()) {  // cold start: fall back to what this layer just used
        if (layer < layers_) {
            const auto& prev = last_active_[layer];
            out->assign(prev.begin(),
                        prev.begin() + std::min<std::size_t>(budget, prev.size()));
        }
        return;
    }
    std::vector<std::pair<ExpertId, uint32_t>> ranked(votes.begin(), votes.end());
    std::size_t k = std::min<std::size_t>(budget, ranked.size());
    std::partial_sort(ranked.begin(), ranked.begin() + k, ranked.end(),
                      [](const auto& a, const auto& b) { return a.second > b.second; });
    for (std::size_t i = 0; i < k; ++i) out->push_back(ranked[i].first);
}

HorizonPredictor::HorizonPredictor(uint32_t layers, uint32_t experts_per_layer,
                                   int horizon_tokens)
    : ExpertPredictor(layers, experts_per_layer),
      cooc_(layers, experts_per_layer),
      last_seen_(std::size_t(layers) * experts_per_layer, 0),
      reach_(std::size_t(layers) * experts_per_layer, 0.0),
      horizon_(std::max(1, horizon_tokens)) {}

void HorizonPredictor::observe(uint32_t layer, const std::vector<ExpertId>& active) {
    ExpertPredictor::observe(layer, active);
    cooc_.observe(layer, active);
    for (ExpertId e : active) {
        if (e < last_seen_.size()) last_seen_[e] = token_;
        active_now_.push_back(e);
    }
}

void HorizonPredictor::predict(uint32_t layer, int budget,
                               std::vector<ExpertId>* out) {
    cooc_.predict(layer, budget, out);  // short horizon: co-activation
}

void HorizonPredictor::warm_set(int budget, std::vector<ExpertId>* out) {
    out->clear();
    if (budget <= 0) return;

    // Reachability: one hop of the learned transition graph out of the experts
    // active right now — demand that has not materialised yet, which neither
    // popularity nor recency can see.
    std::fill(reach_.begin(), reach_.end(), 0.0);
    std::vector<std::pair<ExpertId, uint32_t>> succ;
    for (ExpertId from : active_now_) {
        cooc_.successors(from, &succ);
        uint32_t total = 0;
        for (const auto& [to, c] : succ) total += c;
        if (!total) continue;
        for (const auto& [to, c] : succ)
            if (to < reach_.size()) reach_[to] += double(c) / double(total);
    }

    const double inv_h = 1.0 / double(horizon_);
    std::vector<double> score(popularity_.size(), 0.0);
    for (std::size_t e = 0; e < score.size(); ++e) {
        const double age = double(token_ - last_seen_[e]);
        const double recency = last_seen_[e] ? std::exp(-age * inv_h) : 0.0;
        score[e] = popularity_[e] + 0.5 * recency + 0.3 * reach_[e];
    }

    // Demand is per layer: every token needs top-k experts from EVERY layer, so a
    // globally sorted ranking would hand all the slots to a few layers and starve
    // the rest. Rank inside each layer, then interleave by rank — each layer gets
    // an equal share of every tier (the per-layer allocation AdapMoE argues for).
    std::vector<std::vector<ExpertId>> by_layer(layers_);
    for (uint32_t l = 0; l < layers_; ++l) {
        auto& v = by_layer[l];
        v.resize(per_layer_);
        for (uint32_t i = 0; i < per_layer_; ++i) v[i] = ExpertId(l * per_layer_ + i);
        std::sort(v.begin(), v.end(),
                  [&score](ExpertId a, ExpertId b) { return score[a] > score[b]; });
    }
    out->reserve(std::min<std::size_t>(budget, popularity_.size()));
    for (uint32_t rank = 0; rank < per_layer_ && int(out->size()) < budget; ++rank)
        for (uint32_t l = 0; l < layers_ && int(out->size()) < budget; ++l)
            out->push_back(by_layer[l][rank]);
}

void HorizonPredictor::end_of_token() {
    token_++;
    active_now_.clear();
    cooc_.end_of_token();
}

HybridPredictor::HybridPredictor(uint32_t layers, uint32_t experts_per_layer)
    : ExpertPredictor(layers, experts_per_layer),
      cooc_(layers, experts_per_layer),
      persist_(layers, experts_per_layer),
      popular_(layers, experts_per_layer) {}

void HybridPredictor::observe(uint32_t layer, const std::vector<ExpertId>& active) {
    ExpertPredictor::observe(layer, active);
    cooc_.observe(layer, active);
    persist_.observe(layer, active);
    popular_.observe(layer, active);
}

void HybridPredictor::predict(uint32_t layer, int budget,
                              std::vector<ExpertId>* out) {
    out->clear();
    if (budget <= 0) return;
    std::vector<ExpertId> buf;
    auto take = [&](std::vector<ExpertId>& src) {
        for (ExpertId e : src) {
            if (int(out->size()) >= budget) return;
            if (std::find(out->begin(), out->end(), e) == out->end())
                out->push_back(e);
        }
    };
    cooc_.predict(layer, budget, &buf);
    take(buf);
    persist_.predict(layer, budget, &buf);
    take(buf);
    popular_.predict(layer, budget, &buf);
    take(buf);
}

void HybridPredictor::warm_set(int budget, std::vector<ExpertId>* out) {
    ExpertPredictor::warm_set(budget, out);
}

void HybridPredictor::end_of_token() {
    cooc_.end_of_token();
    persist_.end_of_token();
    popular_.end_of_token();
}

}  // namespace memex
