// Score the adaptive-precision tier against a recorded routing trace.
//
// The question is not whether compression saves memory - it plainly does, 24% of the
// expert footprint at 4 bits. The question is what it costs while the task changes,
// because that is when the resident set is wrong: newly needed experts are the ones
// still compressed, and they are exactly the ones now carrying the work.
//
// So the metric here is not throughput, it is the share of routing decisions served
// by reduced-precision weights, over time. In a steady task it should settle near
// the cold share; right after a switch it should spike and then recover, and the
// recovery time is what the disk rate buys.
#include <algorithm>
#include <cstdint>
#include <cstdio>
#include <cstring>
#include <string>
#include <unordered_map>
#include <vector>

#include "memex/precision_tier.hpp"

namespace {

// Same trace layout as the residency simulator: int32 layer, n_used, n_tokens, ids.
bool load_trace(const std::string& path, int n_experts,
                std::vector<std::vector<memex::SlotId>>* per_token) {
    FILE* f = fopen(path.c_str(), "rb");
    if (!f) {
        fprintf(stderr, "net trassy: %s\n", path.c_str());
        return false;
    }
    std::unordered_map<int, std::vector<memex::SlotId>> by_layer;
    int32_t hdr[3];
    int top_k = 0;
    while (fread(hdr, sizeof(int32_t), 3, f) == 3) {
        const int layer = hdr[0], n_used = hdr[1], n_tok = hdr[2];
        const size_t n = size_t(n_used) * size_t(n_tok);
        std::vector<int32_t> ids(n);
        if (fread(ids.data(), sizeof(int32_t), n, f) != n) break;
        if (layer < 0) continue;
        top_k = n_used;
        auto& dst = by_layer[layer];
        for (size_t i = 0; i < n; ++i)
            dst.push_back(memex::SlotId(layer * n_experts + ids[i]));
    }
    fclose(f);
    if (by_layer.empty() || top_k == 0) return false;
    size_t full = 0;
    for (auto& kv : by_layer) full = std::max(full, kv.second.size());
    std::vector<int> layers;
    for (auto& kv : by_layer)
        if (kv.second.size() >= full / 2) layers.push_back(kv.first);
    std::sort(layers.begin(), layers.end());
    const size_t tokens = full / size_t(top_k);
    per_token->assign(tokens, {});
    for (int l : layers) {
        const auto& v = by_layer[l];
        for (size_t t = 0; t < tokens && (t + 1) * size_t(top_k) <= v.size(); ++t)
            (*per_token)[t].insert((*per_token)[t].end(),
                                   v.begin() + t * size_t(top_k),
                                   v.begin() + (t + 1) * size_t(top_k));
    }
    return true;
}

}  // namespace

int main(int argc, char** argv) {
    setvbuf(stdout, nullptr, _IONBF, 0);
    std::string trace = "D:/MemeX/results/tr_switch.bin";
    int n_experts = 128;
    double token_ms = 113.0;              // measured all-CPU token at 8.85 tok/s
    memex::PrecisionConfig cfg;
    for (int i = 1; i < argc; ++i) {
        if (!strcmp(argv[i], "--trace") && i + 1 < argc) trace = argv[++i];
        else if (!strcmp(argv[i], "--budget") && i + 1 < argc) cfg.full_budget = (size_t)atoi(argv[++i]);
        else if (!strcmp(argv[i], "--rate") && i + 1 < argc) cfg.upgrade_per_second = atof(argv[++i]);
        else if (!strcmp(argv[i], "--token-ms") && i + 1 < argc) token_ms = atof(argv[++i]);
        else if (!strcmp(argv[i], "--in-flight") && i + 1 < argc) cfg.max_in_flight = (size_t)atoi(argv[++i]);
    }

    std::vector<std::vector<memex::SlotId>> per_token;
    if (!load_trace(trace, n_experts, &per_token)) return 1;
    printf("trassa: %zu tokenov, %zu obrashenii na token\n", per_token.size(),
           per_token.empty() ? 0 : per_token[0].size());
    printf("budjet polnoi tochnosti: %zu slotov, podnyatie %.0f ekspertov/s, "
           "token %.0f ms\n\n", cfg.full_budget, cfg.upgrade_per_second, token_ms);

    memex::PrecisionTier tier(cfg);
    // Report in windows so the recovery after the switch is visible instead of being
    // averaged away.
    const size_t W = 250;
    printf("%8s %14s %10s %10s %9s\n", "tokeny", "szhatyh dostup", "polnyh",
           "v polete", "podnyato");
    uint64_t prev_acc = 0, prev_deg = 0;
    for (size_t t = 0; t < per_token.size(); ++t) {
        tier.on_token(per_token[t], token_ms);
        if ((t + 1) % W == 0 || t + 1 == per_token.size()) {
            const auto& st = tier.stats();
            const uint64_t da = st.accesses - prev_acc;
            const uint64_t dd = st.served_compressed - prev_deg;
            printf("%8zu %13.1f%% %10zu %10zu %9llu\n", t + 1,
                   da ? 100.0 * double(dd) / double(da) : 0.0,
                   tier.full_count(), tier.in_flight(),
                   (unsigned long long)st.upgrades);
            prev_acc = st.accesses;
            prev_deg = st.served_compressed;
        }
    }
    const auto& st = tier.stats();
    printf("\nitogo: obrashenii %llu, iz nih po szhatym %.1f%%\n",
           (unsigned long long)st.accesses, 100.0 * st.degraded_share());
    printf("podnyatii %llu, sbrosov %llu, iz nih zrya %llu\n",
           (unsigned long long)st.upgrades, (unsigned long long)st.downgrades,
           (unsigned long long)st.upgrades_wasted);
    printf("pik kopii v polete: %zu (%.0f MB dopolnitelnoi pamyati)\n",
           st.peak_in_flight, st.peak_extra_mb);
    const double saved = (6144.0 - double(cfg.full_budget)) *
                         (cfg.full_mb - cfg.compressed_mb) / 1024.0;
    printf("ekonomiya pamyati pri takom budjete: %.1f GB\n", saved);
    return 0;
}
