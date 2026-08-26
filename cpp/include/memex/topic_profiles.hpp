// Topic profiles: remember which experts a kind of work needs, so a return to that
// kind of work does not have to be relearned.
//
// The measurement that makes this worth building: hot expert sets are almost
// disjoint across kinds of text. The top 594 slots for code and for prose overlap
// by 2.2% - below chance - and a set learned on code covers 3.1% of prose's routing
// decisions against prose's own 69.1%. So a resident set is not a property of the
// model, it is a property of the task.
//
// A popularity policy with exponential decay does eventually find the new set, but
// it pays for the discovery twice: once in misses while the old set is still
// resident, and once in transfers, and the link is the scarcest resource in the
// machine (a fetch costs 0.98 ms against 0.18 ms to just compute the expert on the
// CPU). Profiles remove the relearning: recognise the topic, then aim straight at
// the set that worked last time.
//
// Recognition uses the only signal available for free - which experts the last few
// tokens actually routed to. That is a fingerprint of the topic, and comparing it
// against stored profiles costs a few hundred set lookups per checkpoint.
#pragma once

#include <algorithm>
#include <cstddef>
#include <cstdint>
#include <unordered_map>
#include <vector>

namespace memex {

using SlotId = uint32_t;

struct TopicConfig {
    std::size_t window = 128;      // tokens of fingerprint; 128 gave 91% of the
                                   // achievable coverage on prose
    double match_threshold = 0.35;  // overlap needed to call it the same topic
    std::size_t max_profiles = 8;
    std::size_t profile_slots = 1024;  // how much of a profile is worth keeping
};

// One remembered task: the experts it used, by weight.
struct Profile {
    std::unordered_map<SlotId, double> weight;
    uint64_t tokens = 0;

    void add(const std::vector<SlotId>& used) {
        for (SlotId s : used) {
            weight[s] += 1.0;
        }
        tokens++;
    }

    // Ranked slots, hottest first, truncated to what a resident set could hold.
    std::vector<SlotId> ranking(std::size_t n) const {
        std::vector<std::pair<double, SlotId>> v;
        v.reserve(weight.size());
        for (const auto& kv : weight) {
            v.push_back({kv.second, kv.first});
        }
        std::sort(v.begin(), v.end(),
                  [](const auto& a, const auto& b) { return a.first > b.first; });
        std::vector<SlotId> out;
        out.reserve(std::min(n, v.size()));
        for (std::size_t i = 0; i < v.size() && i < n; ++i) {
            out.push_back(v[i].second);
        }
        return out;
    }
};

class TopicLibrary {
  public:
    explicit TopicLibrary(TopicConfig cfg) : cfg_(cfg) {}

    // Feed one token's routing. Returns true when the recognised topic changed,
    // which is the moment the resident set should be re-aimed.
    bool on_token(const std::vector<SlotId>& used) {
        recent_.push_back(used);
        for (SlotId s : used) {
            fingerprint_[s] += 1.0;
        }
        if (recent_.size() > cfg_.window) {
            for (SlotId s : recent_.front()) {
                if ((fingerprint_[s] -= 1.0) <= 0.0) {
                    fingerprint_.erase(s);
                }
            }
            recent_.pop_front_compat();
        }
        if (profiles_.empty()) {
            profiles_.emplace_back();
            current_ = 0;
        }
        profiles_[current_].add(used);

        // Only re-examine once the fingerprint is full, otherwise every topic looks
        // like the one that happens to be current.
        if (recent_.size() < cfg_.window) {
            return false;
        }
        if (++since_check_ < cfg_.window / 4) {
            return false;
        }
        since_check_ = 0;

        std::size_t best = current_;
        double best_score = score(profiles_[current_]);
        for (std::size_t i = 0; i < profiles_.size(); ++i) {
            if (i == current_) {
                continue;
            }
            const double sc = score(profiles_[i]);
            if (sc > best_score) {
                best_score = sc;
                best = i;
            }
        }
        // Nothing on file resembles what is happening: start a new profile rather
        // than polluting an old one with a different task's experts.
        if (best_score < cfg_.match_threshold) {
            if (profiles_.size() < cfg_.max_profiles) {
                profiles_.emplace_back();
                current_ = profiles_.size() - 1;
                switches_++;
                return true;
            }
            return false;
        }
        if (best != current_) {
            current_ = best;
            switches_++;
            return true;
        }
        return false;
    }

    std::vector<SlotId> current_ranking(std::size_t n) const {
        if (profiles_.empty()) {
            return {};
        }
        return profiles_[current_].ranking(n);
    }

    std::size_t profile_count() const { return profiles_.size(); }
    uint64_t switches() const { return switches_; }
    std::size_t current_index() const { return current_; }

  private:
    // Share of the recent fingerprint's mass that this profile also considers hot.
    // Mass-weighted rather than a plain set overlap, so a profile that merely
    // touched an expert once does not count as knowing the topic.
    double score(const Profile& p) const {
        if (fingerprint_.empty() || p.weight.empty()) {
            return 0.0;
        }
        const auto top = p.ranking(cfg_.profile_slots);
        std::unordered_map<SlotId, char> in_top;
        in_top.reserve(top.size() * 2);
        for (SlotId s : top) {
            in_top[s] = 1;
        }
        double hit = 0.0, total = 0.0;
        for (const auto& kv : fingerprint_) {
            total += kv.second;
            if (in_top.count(kv.first)) {
                hit += kv.second;
            }
        }
        return total > 0.0 ? hit / total : 0.0;
    }

    // Small deque replacement: a ring of the last `window` token id lists.
    struct Ring {
        std::vector<std::vector<SlotId>> buf;
        std::size_t head = 0;
        void push_back(const std::vector<SlotId>& v) { buf.push_back(v); }
        void pop_front_compat() { head++; }
        std::size_t size() const { return buf.size() - head; }
        const std::vector<SlotId>& front() const { return buf[head]; }
    };

    TopicConfig cfg_;
    Ring recent_;
    std::unordered_map<SlotId, double> fingerprint_;
    std::vector<Profile> profiles_;
    std::size_t current_ = 0;
    std::size_t since_check_ = 0;
    uint64_t switches_ = 0;
};

}  // namespace memex
