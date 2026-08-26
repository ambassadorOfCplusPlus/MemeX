// Score residency protocols against a recorded routing trace.
//
// Everything here is driven by numbers measured on this machine rather than
// assumed, because the choice of protocol flips depending on them:
//
//   RAM read, 4 threads   21.5 GB/s   (measured: 1t 8.9, 2t 13.6, 4t 21.5, 8t 24.6)
//   PCIe 3.0 x4            3.94 GB/s
//   VRAM                 144    GB/s
//   one expert             3.87 MB    (Qwen3-30B-A3B at Q6_K)
//   device tier             594 experts of 6144 (2.3 GB usable VRAM)
//
// The trace comes from llama-moe-trace running the real model, so the demand
// stream is the model's own routing, not a synthetic distribution.
//
// The point of the exercise is that a resident expert is computed by the GPU and
// a missing one by the CPU, with no transfer on the critical path. If the two
// devices work at the same time, a token costs max(cpu, gpu) instead of their sum,
// and the resident share decides how the work splits. Transfers are then a
// background activity whose only job is to raise that share over time, spending
// bandwidth generation is not using.
#include <algorithm>
#include <cstdint>
#include <cstdio>
#include <cstring>
#include <string>
#include <unordered_map>
#include <vector>

#include "memex/residency.hpp"
#include "memex/topic_profiles.hpp"

namespace {

struct Hw {
    // All of these are measured, not taken from specifications. The GPU figure is
    // the one that matters most and the one that was wrong at first: VRAM peaks at
    // 144 GB/s, but a single-token matrix-vector product only reaches 84.6, which
    // is what the concurrency probe recorded against resident weights.
    double ram_gbs = 20.1;       // ggml Q6_K kernels, 4 threads, cache-cold
    double vram_gbs = 84.6;      // resident weights, one token
    double link_gbs = 3.94;      // PCIe 3.0 x4
    double expert_mb = 3.87;
    double crossing_us = 240.0;  // measured round trip incl. one expert of compute
    int layers = 47;
    // Attention, shared FFN, router and kernel overhead, obtained by subtracting
    // the measured expert cost from the measured all-CPU token time (8.85 tok/s).
    double dense_ms = 39.0;
};

// Trace layout, repeated: int32 layer, int32 n_used, int32 n_tokens, then ids.
bool load_trace(const std::string& path, int n_experts,
                std::vector<std::vector<memex::SlotId>>* per_token,
                int* top_k) {
    FILE* f = fopen(path.c_str(), "rb");
    if (!f) {
        fprintf(stderr, "нет трассы: %s\n", path.c_str());
        return false;
    }
    std::unordered_map<int, std::vector<memex::SlotId>> by_layer;
    int32_t hdr[3];
    *top_k = 0;
    while (fread(hdr, sizeof(int32_t), 3, f) == 3) {
        const int layer = hdr[0], n_used = hdr[1], n_tok = hdr[2];
        const size_t n = size_t(n_used) * size_t(n_tok);
        std::vector<int32_t> ids(n);
        if (fread(ids.data(), sizeof(int32_t), n, f) != n) {
            break;
        }
        if (layer < 0) {
            continue;                  // node whose name carried no layer index
        }
        *top_k = n_used;
        auto& dst = by_layer[layer];
        for (size_t i = 0; i < n; ++i) {
            dst.push_back(memex::SlotId(layer * n_experts + ids[i]));
        }
    }
    fclose(f);
    if (by_layer.empty()) {
        return false;
    }
    // The last layer runs its FFN for the final token only, so it holds a single
    // row and would truncate everything else; drop such short layers.
    size_t full = 0;
    for (auto& kv : by_layer) {
        full = std::max(full, kv.second.size());
    }
    std::vector<int> layers;
    for (auto& kv : by_layer) {
        if (kv.second.size() >= full / 2) {
            layers.push_back(kv.first);
        }
    }
    std::sort(layers.begin(), layers.end());
    size_t tokens = full / size_t(*top_k);
    per_token->assign(tokens, {});
    for (int l : layers) {
        const auto& v = by_layer[l];
        for (size_t t = 0; t < tokens && (t + 1) * size_t(*top_k) <= v.size(); ++t) {
            auto& out = (*per_token)[t];
            out.insert(out.end(), v.begin() + t * size_t(*top_k),
                       v.begin() + (t + 1) * size_t(*top_k));
        }
    }
    return true;
}

struct Result {
    std::string name;
    double hit_rate = 0.0;
    double tok_s_serial = 0.0;      // CPU and GPU take turns
    double tok_s_overlap = 0.0;     // CPU and GPU work at the same time
    double link_util = 0.0;
    uint64_t fetched = 0;
    uint64_t wasted = 0;
};

// Cost of one token given how its expert demand split between the tiers.
void token_cost(const Hw& hw, size_t on_gpu, size_t on_cpu,
                double* cpu_ms, double* gpu_ms) {
    const double mb_gpu = double(on_gpu) * hw.expert_mb;
    const double mb_cpu = double(on_cpu) * hw.expert_mb;
    *gpu_ms = mb_gpu / hw.vram_gbs;                  // MB / (GB/s) = ms
    *cpu_ms = mb_cpu / hw.ram_gbs;
    if (on_gpu > 0) {
        // activations hop to the device and back once per layer that has any
        // resident expert; charged in full as the pessimistic case
        *gpu_ms += double(hw.layers) * hw.crossing_us / 1000.0;
    }
}

Result run(const std::string& name, const Hw& hw, memex::ResidencyConfig rc,
           const std::vector<std::vector<memex::SlotId>>& per_token,
           bool use_oracle_forecast, const std::vector<memex::SlotId>* preload,
           bool use_topics = false) {
    memex::ResidencyPolicy pol(rc);
    if (preload) {
        pol.preload(*preload);
    }
    memex::TopicConfig tcfg;
    memex::TopicLibrary topics(tcfg);
    bool aim_at_profile = false;
    double total_serial = 0.0, total_overlap = 0.0, link_ms = 0.0;
    const size_t T = per_token.size();
    for (size_t t = 0; t < T; ++t) {
        const auto& need = per_token[t];
        pol.note_use_for_ranking(need);
        const size_t hits = pol.on_token(need);
        double cpu_ms = 0.0, gpu_ms = 0.0;
        token_cost(hw, hits, need.size() - hits, &cpu_ms, &gpu_ms);
        const double serial = hw.dense_ms + cpu_ms + gpu_ms;
        const double overlap = hw.dense_ms + std::max(cpu_ms, gpu_ms);
        total_serial += serial;
        total_overlap += overlap;

        // What the predictor thinks the next tokens need. The oracle arm reads it
        // from the trace to bound what perfect prediction could buy; the realistic
        // arm reuses the current token's set, which the measured 34% adjacency
        // overlap says is a decent guess.
        std::vector<memex::SlotId> forecast;
        if (use_topics) {
            // Recognise the task from what the recent tokens routed to, then aim
            // the resident set at the set that task needed before. On a return to
            // a known task this replaces relearning with a lookup.
            if (topics.on_token(need)) {
                aim_at_profile = true;
            }
            forecast = need;
            if (aim_at_profile) {
                const auto rank = topics.current_ranking(rc.capacity);
                forecast.insert(forecast.end(), rank.begin(), rank.end());
            }
        } else if (use_oracle_forecast) {
            for (int k = 1; k <= rc.lookahead_tokens && t + k < T; ++k) {
                const auto& f = per_token[t + k];
                forecast.insert(forecast.end(), f.begin(), f.end());
            }
        } else {
            forecast = need;
        }
        pol.age();
        pol.plan(forecast, overlap);
        link_ms = pol.stats().link_ms;
    }
    if (use_topics) {
        printf("   [profili: tem %zu, pereklyuchenii %llu]\n",
               topics.profile_count(), (unsigned long long) topics.switches());
    }
    Result r;
    r.name = name;
    r.hit_rate = pol.stats().hit_rate();
    r.tok_s_serial = 1000.0 * double(T) / total_serial;
    r.tok_s_overlap = 1000.0 * double(T) / total_overlap;
    r.link_util = total_overlap > 0 ? link_ms / total_overlap : 0.0;
    r.fetched = pol.stats().fetched;
    r.wasted = pol.stats().fetch_wasted;
    return r;
}

}  // namespace

int main(int argc, char** argv) {
    std::string trace = "D:/MemeX/results/moe_trace.bin";
    int n_experts = 128;
    Hw hw;
    memex::ResidencyConfig base;
    for (int i = 1; i < argc; ++i) {
        if (!strcmp(argv[i], "--trace") && i + 1 < argc) trace = argv[++i];
        else if (!strcmp(argv[i], "--experts") && i + 1 < argc) n_experts = atoi(argv[++i]);
        else if (!strcmp(argv[i], "--capacity") && i + 1 < argc) base.capacity = size_t(atoi(argv[++i]));
        else if (!strcmp(argv[i], "--crossing-us") && i + 1 < argc) hw.crossing_us = atof(argv[++i]);
        else if (!strcmp(argv[i], "--checkpoint") && i + 1 < argc) base.checkpoint_every = atoi(argv[++i]);
        else if (!strcmp(argv[i], "--lookahead") && i + 1 < argc) base.lookahead_tokens = atoi(argv[++i]);
    }

    std::vector<std::vector<memex::SlotId>> per_token;
    int top_k = 0;
    if (!load_trace(trace, n_experts, &per_token, &top_k)) {
        return 1;
    }
    printf("трасса: %zu токенов, top-%d, экспертов на токен %zu\n",
           per_token.size(), top_k, per_token.empty() ? 0 : per_token[0].size());
    printf("ёмкость устройства: %zu экспертов, переход %.0f мкс\n\n",
           base.capacity, hw.crossing_us);

    // popularity order over the whole trace: the ceiling a warm start could reach
    std::unordered_map<memex::SlotId, uint64_t> pop;
    for (auto& v : per_token) {
        for (auto s : v) {
            pop[s]++;
        }
    }
    std::vector<std::pair<uint64_t, memex::SlotId>> ranked;
    for (auto& kv : pop) {
        ranked.push_back({kv.second, kv.first});
    }
    std::sort(ranked.begin(), ranked.end(),
              [](const auto& a, const auto& b) { return a.first > b.first; });
    std::vector<memex::SlotId> hot_order;
    for (auto& p : ranked) {
        hot_order.push_back(p.second);
    }

    std::vector<Result> out;
    {   // no device tier at all: everything on the CPU
        memex::ResidencyConfig rc = base;
        rc.capacity = 0;
        out.push_back(run("всё на CPU (база)", hw, rc, per_token, false, nullptr));
    }
    {   // the protocol under test: warm from the first token, look ahead, checkpoint
        out.push_back(run("протокол: прогрев + 2 вперёд + чекпоинт", hw, base,
                          per_token, false, nullptr));
    }
    {   // same, but the forecast is perfect - upper bound on prediction quality
        out.push_back(run("тот же, но предсказание идеальное", hw, base,
                          per_token, true, nullptr));
    }
    {   // start already holding the globally hottest experts
        out.push_back(run("протокол + горячий набор заранее", hw, base,
                          per_token, false, &hot_order));
    }
    {   // the same protocol, but aiming at a remembered per-task profile
        out.push_back(run("протокол + профили тем", hw, base, per_token, false,
                          nullptr, true));
    }
    {   // static: hot set pinned, no transfers at all during generation
        memex::ResidencyConfig rc = base;
        rc.link_duty = 0.0;
        rc.popularity_ranking = false;
        out.push_back(run("статично закреплённый горячий набор", hw, rc,
                          per_token, false, &hot_order));
    }

    printf("%-42s %7s %9s %9s %7s %8s\n", "вариант", "попад", "посл.",
           "одноврем", "канал", "впустую");
    for (auto& r : out) {
        printf("%-42s %6.1f%% %7.2f т/с %7.2f т/с %6.0f%% %8llu\n",
               r.name.c_str(), 100.0 * r.hit_rate, r.tok_s_serial,
               r.tok_s_overlap, 100.0 * r.link_util,
               (unsigned long long) r.wasted);
    }
    printf("\nпосл. = CPU и GPU по очереди, одноврем = считают одновременно\n");
    return 0;
}
