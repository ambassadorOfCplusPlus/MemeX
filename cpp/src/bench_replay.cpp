// Replay a MoE routing trace through the MemeX expert cache with REAL disk and
// memory traffic — the point of the C++ harness over the Python simulator,
// which only models bandwidth analytically.
//
// Usage (synthetic trace):
//   memex_bench --blob D:\MemeX\bench\experts.bin --make-blob \
//               --experts 512 --layers 32 --topk 8 --expert-kb 1800 \
//               --device-mb 2048 --host-mb 8192 --tokens 200
#include "memex/expert_cache.hpp"
#include "memex/predictor.hpp"

#include <algorithm>
#include <chrono>
#include <memory>
#include <cmath>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <random>
#include <string>
#include <vector>

using namespace memex;

namespace {

struct Args {
    std::string blob = "experts.bin";
    bool make_blob = false;
    int experts = 512;       // experts per MoE layer
    int layers = 32;         // MoE layers
    int topk = 8;            // active experts per token per layer
    int expert_kb = 1800;    // bytes per expert / 1024
    int device_mb = 2048;
    int host_mb = 8192;
    int tokens = 200;
    int rerank = 64;
    double zipf = 1.0;
    double sticky = 0.35;    // chance an expert repeats on the next token
    double prefetch_acc = 0.97;  // cross-layer gate prediction accuracy (Fate)
    bool cpu_on_miss = true;
    int threads = 2;
    // Without simulated compute the replay loop runs orders of magnitude faster
    // than real generation, so prefetches never have time to land and every
    // lookup looks like a miss. This is the window the loaders work inside.
    int layer_us = 400;      // per-layer compute time (48 layers ~ 19 ms/token)
    int warmup_tokens = 0;   // populate the warm tier before measuring
    std::string predictor = "hybrid";  // oracle|fixed|persist|popular|cooc|hybrid
    int predict_budget = 0;  // guesses per layer (0 = topk, i.e. no overfetch)
    int cpu_expert_us = 300;  // extra wall time when an expert runs on CPU
    int host_hit_us = 500;    // RAM -> VRAM transfer at use time (1.76 MB / PCIe x4)
    int lookahead = 1;        // how many layers ahead to prefetch
    bool residency_filter = true;  // don't waste budget on resident experts
    std::string placement = "none";  // none = reactive LFRU, ranked = tier plan
    int horizon = 4;          // tokens the long-horizon ranking looks ahead
    bool adaptive = false;    // grow/shrink the warm tier to fit free RAM
    double take_fraction = 0.6;
    int keep_free_mb = 4096;  // always leave this much for the rest of the system
    bool plan_device = false; // let the ranked plan touch VRAM (measured: worse)
    bool calibrate_costs = false;  // measure transfer/CPU costs on this machine
    double bytes_per_param = 0.56; // q4, used to turn expert bytes into params
    bool single_step = false;      // migrate one tier at a time (VRAM<->RAM<->disk)
    int batch_loads = 8;           // loads serviced per batch, sorted by offset
    bool autotune = false;         // hill-climb the prefetch budget on throughput
    int tune_every = 5;            // tokens per tuning window
    bool reorder = false;          // lay the blob out by co-activation affinity
    // AdapMoE-style demand reduction: keep experts until this much of the gate
    // mass is covered and skip the rest. 1.0 = keep all (no skipping).
    double keep_gate_mass = 1.0;
    double vram_take_fraction = 0.8;  // share of leftover VRAM used as L1 cache
    int keep_free_vram_mb = 384;      // headroom left for the KV cache and drivers
    int device_max_mb = 2560;         // stub safety cap (device slots live in RAM)
    int host_max_mb = 7168;           // leave physical memory for the OS page cache
};

Args parse(int argc, char** argv) {
    Args a;
    auto next = [&](int& i) { return (i + 1 < argc) ? argv[++i] : ""; };
    for (int i = 1; i < argc; ++i) {
        std::string k = argv[i];
        if (k == "--blob") a.blob = next(i);
        else if (k == "--make-blob") a.make_blob = true;
        else if (k == "--experts") a.experts = std::atoi(next(i));
        else if (k == "--layers") a.layers = std::atoi(next(i));
        else if (k == "--topk") a.topk = std::atoi(next(i));
        else if (k == "--expert-kb") a.expert_kb = std::atoi(next(i));
        else if (k == "--device-mb") a.device_mb = std::atoi(next(i));
        else if (k == "--host-mb") a.host_mb = std::atoi(next(i));
        else if (k == "--tokens") a.tokens = std::atoi(next(i));
        else if (k == "--rerank") a.rerank = std::atoi(next(i));
        else if (k == "--zipf") a.zipf = std::atof(next(i));
        else if (k == "--sticky") a.sticky = std::atof(next(i));
        else if (k == "--prefetch-acc") a.prefetch_acc = std::atof(next(i));
        else if (k == "--no-cpu-on-miss") a.cpu_on_miss = false;
        else if (k == "--threads") a.threads = std::atoi(next(i));
        else if (k == "--layer-us") a.layer_us = std::atoi(next(i));
        else if (k == "--warmup-tokens") a.warmup_tokens = std::atoi(next(i));
        else if (k == "--predictor") a.predictor = next(i);
        else if (k == "--predict-budget") a.predict_budget = std::atoi(next(i));
        else if (k == "--cpu-expert-us") a.cpu_expert_us = std::atoi(next(i));
        else if (k == "--lookahead") a.lookahead = std::atoi(next(i));
        else if (k == "--no-residency-filter") a.residency_filter = false;
        else if (k == "--placement") a.placement = next(i);
        else if (k == "--horizon") a.horizon = std::atoi(next(i));
        else if (k == "--host-hit-us") a.host_hit_us = std::atoi(next(i));
        else if (k == "--adaptive") a.adaptive = true;
        else if (k == "--take-fraction") a.take_fraction = std::atof(next(i));
        else if (k == "--keep-free-mb") a.keep_free_mb = std::atoi(next(i));
        else if (k == "--plan-device") a.plan_device = true;
        else if (k == "--calibrate") a.calibrate_costs = true;
        else if (k == "--single-step") a.single_step = true;
        else if (k == "--bytes-per-param") a.bytes_per_param = std::atof(next(i));
        else if (k == "--batch-loads") a.batch_loads = std::atoi(next(i));
        else if (k == "--autotune") a.autotune = true;
        else if (k == "--tune-every") a.tune_every = std::atoi(next(i));
        else if (k == "--reorder") a.reorder = true;
        else if (k == "--keep-gate-mass") a.keep_gate_mass = std::atof(next(i));
        else if (k == "--vram-take-fraction") a.vram_take_fraction = std::atof(next(i));
        else if (k == "--keep-free-vram-mb") a.keep_free_vram_mb = std::atoi(next(i));
        else if (k == "--device-max-mb") a.device_max_mb = std::atoi(next(i));
        else if (k == "--host-max-mb") a.host_max_mb = std::atoi(next(i));
        else {
            std::fprintf(stderr, "unknown flag: %s\n", k.c_str());
            std::exit(2);
        }
    }
    return a;
}

// Measure the two costs that decide the whole tier policy, on THIS machine,
// instead of guessing them:
//   transfer — moving one expert across the bus (memcpy of its payload; a real
//              GPU backend would time cudaMemcpyAsync here)
//   cpu run  — executing one expert on the CPU at batch 1, which is a
//              memory-bandwidth-bound sweep over its parameters
// If cpu-run is cheaper than transfer, a miss should be computed locally rather
// than paged in (Fiddler's rule); if it is dearer, residency is worth paying for.
struct Calibration {
    double transfer_us = 0.0;
    double cpu_run_us = 0.0;
};

Calibration calibrate(std::size_t expert_bytes, double bytes_per_param) {
    using clock = std::chrono::steady_clock;
    Calibration c;
    const int reps = 12;

    std::vector<uint8_t> src(expert_bytes, 0x5A), dst(expert_bytes, 0);
    auto t0 = clock::now();
    for (int i = 0; i < reps; ++i) std::memcpy(dst.data(), src.data(), expert_bytes);
    c.transfer_us = std::chrono::duration<double, std::micro>(clock::now() - t0)
                        .count() / reps;

    const std::size_t params =
        std::size_t(double(expert_bytes) / std::max(bytes_per_param, 0.01));
    std::vector<float> w(params, 1.0001f);
    volatile float sink = 0.0f;
    t0 = clock::now();
    for (int i = 0; i < reps; ++i) {
        float acc = 0.0f;
        for (std::size_t j = 0; j < params; ++j) acc += w[j] * 1.0001f;
        sink = acc;
    }
    (void)sink;
    c.cpu_run_us = std::chrono::duration<double, std::micro>(clock::now() - t0)
                       .count() / reps;
    return c;
}

// Offline blob layout optimisation: experts that are fetched close together in
// time should sit close together on disk, so one forward sweep of the head pulls
// in a useful group instead of one expert. Affinity is measured between adjacent
// layers (that is the direction prefetch actually walks), then a greedy chain
// lays the experts out: start at the busiest node, repeatedly append its
// strongest not-yet-placed neighbour. Cheap, one-off, and it needs no labels —
// only the routing the model already produced.
std::vector<ExpertId> coactivation_layout(
    const std::vector<std::vector<std::vector<ExpertId>>>& trace,
    std::size_t n_experts) {
    std::unordered_map<uint64_t, uint32_t> edge;
    std::vector<uint32_t> degree(n_experts, 0);
    auto key = [](ExpertId a, ExpertId b) {
        return (uint64_t(std::min(a, b)) << 32) | uint64_t(std::max(a, b));
    };
    for (const auto& token : trace) {
        for (std::size_t l = 0; l + 1 < token.size(); ++l) {
            for (ExpertId a : token[l]) {
                for (ExpertId b : token[l + 1]) {
                    edge[key(a, b)]++;
                    degree[a]++;
                    degree[b]++;
                }
            }
        }
    }
    // adjacency lists for the greedy walk
    std::vector<std::vector<std::pair<ExpertId, uint32_t>>> adj(n_experts);
    for (const auto& [k, w] : edge) {
        ExpertId a = ExpertId(k >> 32), b = ExpertId(k & 0xffffffffu);
        adj[a].push_back({b, w});
        adj[b].push_back({a, w});
    }
    for (auto& v : adj)
        std::sort(v.begin(), v.end(),
                  [](const auto& x, const auto& y) { return x.second > y.second; });

    std::vector<bool> placed(n_experts, false);
    std::vector<ExpertId> order;
    order.reserve(n_experts);
    ExpertId cur = ExpertId(std::max_element(degree.begin(), degree.end()) -
                            degree.begin());
    while (order.size() < n_experts) {
        placed[cur] = true;
        order.push_back(cur);
        ExpertId next = UINT32_MAX;
        for (const auto& [cand, w] : adj[cur]) {
            if (!placed[cand]) { next = cand; break; }
        }
        if (next == UINT32_MAX) {  // chain exhausted: jump to the busiest leftover
            uint32_t best = 0;
            for (ExpertId e = 0; e < n_experts; ++e)
                if (!placed[e] && (next == UINT32_MAX || degree[e] > best)) {
                    next = e;
                    best = degree[e];
                }
            if (next == UINT32_MAX) break;
        }
        cur = next;
    }
    return order;
}

bool write_blob(const std::string& path, std::size_t total_bytes) {
    std::FILE* f = std::fopen(path.c_str(), "wb");
    if (!f) return false;
    std::vector<uint8_t> chunk(4u << 20, 0xA5);
    std::size_t left = total_bytes;
    while (left) {
        std::size_t n = std::min(left, chunk.size());
        if (std::fwrite(chunk.data(), 1, n, f) != n) {
            std::fclose(f);
            return false;
        }
        left -= n;
    }
    std::fclose(f);
    return true;
}

}  // namespace

int main(int argc, char** argv) {
    Args a = parse(argc, argv);
    const std::size_t expert_bytes = std::size_t(a.expert_kb) * 1024;
    const std::size_t n_experts = std::size_t(a.experts) * a.layers;
    const std::size_t blob_bytes = n_experts * expert_bytes;

    if (a.make_blob) {
        std::printf("writing blob %s (%.1f GB) ...\n", a.blob.c_str(),
                    double(blob_bytes) / 1e9);
        if (!write_blob(a.blob, blob_bytes)) {
            std::fprintf(stderr, "failed to write blob\n");
            return 1;
        }
    }

    if (a.calibrate_costs) {
        Calibration c = calibrate(expert_bytes, a.bytes_per_param);
        a.host_hit_us = int(c.transfer_us + 0.5);
        a.cpu_expert_us = int(c.cpu_run_us + 0.5);
        std::printf("calibrated on this machine: bus transfer %.0f us/expert, "
                    "CPU run %.0f us/expert -> misses should be %s\n",
                    c.transfer_us, c.cpu_run_us,
                    c.cpu_run_us < c.transfer_us ? "computed on CPU"
                                                 : "paged into VRAM");
    }

    ExpertBlob blob;
    std::string err;
    if (!blob.open(a.blob, &err)) {
        std::fprintf(stderr, "%s (use --make-blob first)\n", err.c_str());
        return 1;
    }

    // Routing model: Zipf popularity per layer (own permutation per layer) plus
    // temporal stickiness — the locality structure real MoE traces show.
    std::mt19937 rng(1234);
    std::vector<double> weights(a.experts);
    for (int i = 0; i < a.experts; ++i)
        weights[i] = 1.0 / std::pow(double(i + 1), a.zipf);
    std::discrete_distribution<int> zipf_dist(weights.begin(), weights.end());
    std::uniform_real_distribution<double> unit(0.0, 1.0);
    std::vector<std::vector<int>> perm(a.layers, std::vector<int>(a.experts));
    for (int l = 0; l < a.layers; ++l) {
        for (int i = 0; i < a.experts; ++i) perm[l][i] = i;
        std::shuffle(perm[l].begin(), perm[l].end(), rng);
    }
    std::vector<std::vector<ExpertId>> prev(a.layers);

    std::vector<ExpertDesc> descs(n_experts);
    for (std::size_t i = 0; i < n_experts; ++i) {
        descs[i].id = ExpertId(i);
        descs[i].layer = uint32_t(i / a.experts);
        descs[i].offset = uint64_t(i) * expert_bytes;
        descs[i].bytes = uint32_t(expert_bytes);
    }

    if (a.reorder) {
        // Learn affinity from an independent sample of the same routing process
        // (own RNG, so the measured trace stays untouched — no oracle leakage),
        // then place expert `order[p]` at file position p.
        std::mt19937 dry(999);
        std::discrete_distribution<int> dz(weights.begin(), weights.end());
        std::uniform_real_distribution<double> du(0.0, 1.0);
        std::vector<std::vector<ExpertId>> dprev(a.layers);
        std::vector<std::vector<std::vector<ExpertId>>> sample;
        for (int t = 0; t < 30; ++t) {
            std::vector<std::vector<ExpertId>> token(a.layers);
            for (int l = 0; l < a.layers; ++l) {
                std::vector<ExpertId> sel;
                for (ExpertId e : dprev[l])
                    if (du(dry) < a.sticky && int(sel.size()) < a.topk) sel.push_back(e);
                while (int(sel.size()) < a.topk) {
                    ExpertId id = ExpertId(l * a.experts + perm[l][dz(dry)]);
                    if (std::find(sel.begin(), sel.end(), id) == sel.end())
                        sel.push_back(id);
                }
                dprev[l] = sel;
                token[l] = sel;
            }
            sample.push_back(std::move(token));
        }
        std::vector<ExpertId> order = coactivation_layout(sample, n_experts);
        for (std::size_t pos = 0; pos < order.size(); ++pos)
            descs[order[pos]].offset = uint64_t(pos) * expert_bytes;
        std::printf("blob layout   : reordered by co-activation affinity "
                    "(%zu experts placed from a %zu-token sample)\n",
                    order.size(), sample.size());
    }

    CacheConfig cfg;
    cfg.device_bytes = std::size_t(a.device_mb) << 20;
    cfg.host_bytes = std::size_t(a.host_mb) << 20;
    cfg.rerank_every_tokens = a.rerank;
    cfg.cpu_compute_on_miss = a.cpu_on_miss;
    cfg.loader_threads = a.threads;
    cfg.plan_device_tier = a.plan_device;
    cfg.single_step_migration = a.single_step;
    cfg.batch_loads = a.batch_loads;
    ExpertCache cache(cfg, descs, &blob);

    auto pick_layer = [&](int layer) {
        std::vector<ExpertId> sel;
        sel.reserve(a.topk);
        for (ExpertId e : prev[layer])
            if (unit(rng) < a.sticky && int(sel.size()) < a.topk) sel.push_back(e);
        while (int(sel.size()) < a.topk) {
            ExpertId id = ExpertId(layer * a.experts + perm[layer][zipf_dist(rng)]);
            if (std::find(sel.begin(), sel.end(), id) == sel.end()) sel.push_back(id);
        }
        prev[layer] = sel;  // stickiness follows the router, not the skip decision
        if (a.keep_gate_mass < 1.0 && !sel.empty()) {
            // Router weights decay with rank; keep the prefix that carries
            // `keep_gate_mass` of the total and skip the marginal tail. Fewer
            // expert calls means fewer chances to miss — demand-side saving.
            double total = 0.0;
            std::vector<double> w(sel.size());
            for (std::size_t r = 0; r < sel.size(); ++r) {
                w[r] = std::exp(-double(r) * 0.5);
                total += w[r];
            }
            double acc = 0.0;
            std::size_t keep = 0;
            for (; keep < sel.size(); ++keep) {
                acc += w[keep] / total;
                if (acc >= a.keep_gate_mass) { ++keep; break; }
            }
            sel.resize(std::max<std::size_t>(1, keep));
        }
        return sel;
    };

    // Spin instead of sleeping: Windows sleep granularity (~1-15 ms) would
    // dwarf a sub-millisecond layer time.
    auto burn_us = [](int us) {
        if (us <= 0) return;
        const auto until = std::chrono::steady_clock::now() +
                           std::chrono::microseconds(us);
        while (std::chrono::steady_clock::now() < until) { /* busy */ }
    };

    std::unique_ptr<ExpertPredictor> predictor;
    const uint32_t L = uint32_t(a.layers), E = uint32_t(a.experts);
    if (a.predictor == "persist") predictor.reset(new PersistPredictor(L, E));
    else if (a.predictor == "popular") predictor.reset(new PopularityPredictor(L, E));
    else if (a.predictor == "cooc") predictor.reset(new CoocPredictor(L, E));
    else if (a.predictor == "hybrid") predictor.reset(new HybridPredictor(L, E));
    else if (a.predictor == "horizon")
        predictor.reset(new HorizonPredictor(L, E, a.horizon));
    // "oracle" and "fixed" need no model: they read the plan directly.

    int pbudget = a.predict_budget > 0 ? a.predict_budget : a.topk;
    // Prefetch aggressiveness has an optimum, not a maximum: more guesses cut
    // misses but cost bandwidth and CPU that the compute path needs. Hill-climb
    // on measured throughput instead of assuming a value.
    struct Tuner {
        int step = 4, dir = 1;
        double best_rate = 0.0;
        int best_budget = 0;
        std::chrono::steady_clock::time_point mark = std::chrono::steady_clock::now();
        int tokens_in_window = 0;
    } tuner;
    tuner.best_budget = pbudget;
    PersistPredictor persist_only(L, E);  // supplies the deeper lookahead layers

    std::size_t served_device = 0, served_host = 0, served_cpu = 0;
    // "Useful" prefetch accounting: only experts that were missing at prediction
    // time can be won by prefetching, so this is the metric that tracks speed.
    std::size_t needed_missing = 0, useful_hits = 0;
    std::size_t tokens_seen = 0;
    const std::size_t plan_slots = cache.device_capacity() + cache.host_capacity();
    auto run_token = [&](bool count) {
        std::vector<std::vector<ExpertId>> plan(a.layers);
        for (int l = 0; l < a.layers; ++l) plan[l] = pick_layer(l);
        for (int l = 0; l < a.layers; ++l) {
            // Order matters: layer l's gate fires first, so the router output is
            // known before we predict l+1 and prefetch during l's compute.
            if (predictor) predictor->observe(uint32_t(l), plan[l]);
            persist_only.observe(uint32_t(l), plan[l]);
            // Look several layers ahead: one layer of compute is often too short
            // to finish a multi-MB load, so depth buys the loaders time. Depth 1
            // uses the co-activation model (fresh, driven by the layer just
            // routed); deeper layers fall back to temporal persistence, which is
            // available without chaining the transition model.
            for (int d = 1; d <= a.lookahead && l + d < a.layers; ++d) {
                const int target = l + d;
                std::vector<ExpertId> cand;
                if (a.predictor == "oracle") {
                    cand = plan[target];
                } else if (a.predictor == "fixed") {
                    for (ExpertId e : plan[target])
                        if (unit(rng) < a.prefetch_acc) cand.push_back(e);
                } else if (d == 1) {
                    predictor->predict(uint32_t(target), pbudget * 3, &cand);
                } else {
                    persist_only.predict(uint32_t(target), pbudget * 2, &cand);
                }
                // Spend the budget only on genuinely missing experts.
                std::vector<ExpertId> pred;
                for (ExpertId e : cand) {
                    if (int(pred.size()) >= pbudget) break;
                    if (!a.residency_filter || !cache.is_resident(e))
                        pred.push_back(e);
                }
                if (count && d == 1) {
                    if (predictor) predictor->score(pred, plan[target]);
                    for (ExpertId e : plan[target]) {
                        if (cache.is_resident(e)) continue;
                        needed_missing++;
                        if (std::find(pred.begin(), pred.end(), e) != pred.end())
                            useful_hits++;
                    }
                }
                cache.prefetch(pred);
            }
            int cpu_here = 0, host_here = 0;
            for (ExpertId e : plan[l]) {
                Tier tier = cache.acquire(e);
                if (tier == Tier::Device) { if (count) served_device++; }
                else if (tier == Tier::Host) { host_here++; if (count) served_host++; }
                else { cpu_here++; if (count) served_cpu++; }
            }
            // Cost model: a VRAM-resident expert runs inside layer_us; one that is
            // only in RAM must cross the bus first (this is why tier placement,
            // not just residency, matters); one that is on disk runs on the CPU.
            burn_us(a.layer_us + cpu_here * a.cpu_expert_us +
                    host_here * a.host_hit_us);
        }
        if (predictor) predictor->end_of_token();
        cache.end_of_token();
        // Slow loop, explicit form: every `rerank` tokens rebuild the demand
        // ranking and re-slice it across the tiers. Runs at a token boundary and
        // only queues work — the loader threads do the moving.
        ++tokens_seen;
        if (a.autotune && count && ++tuner.tokens_in_window >= a.tune_every) {
            const double secs = std::chrono::duration<double>(
                std::chrono::steady_clock::now() - tuner.mark).count();
            const double rate = secs > 0 ? tuner.tokens_in_window / secs : 0.0;
            if (rate > tuner.best_rate) {
                tuner.best_rate = rate;          // keep going this way
                tuner.best_budget = pbudget;
            } else {
                tuner.dir = -tuner.dir;          // that direction was worse
                pbudget = tuner.best_budget;
            }
            pbudget = std::max(a.topk, std::min(48, pbudget + tuner.dir * tuner.step));
            tuner.tokens_in_window = 0;
            tuner.mark = std::chrono::steady_clock::now();
        }
        if (a.adaptive && a.rerank > 0 && (tokens_seen % a.rerank) == 0) {
            // Hardware auto-tuning: claim whatever RAM and VRAM are free right
            // now, hand memory back if the machine (or the KV cache) needs it.
            // Cap the warm tier: our RAM slots compete with the OS page cache for
            // the same physical memory, and the page cache is itself holding the
            // expert blob. Grabbing everything turns page-cache hits into real
            // disk reads — measured, not hypothetical.
            cache.adapt_to_free_memory(a.take_fraction,
                                       std::size_t(a.keep_free_mb) << 20,
                                       std::size_t(a.host_max_mb) << 20);
            // The device tier is a host-memory stub in this harness, so cap it —
            // a real GPU backend would be bounded by the card itself.
            cache.adapt_device_to_free_vram(a.vram_take_fraction,
                                            std::size_t(a.keep_free_vram_mb) << 20,
                                            std::size_t(a.device_max_mb) << 20);
        }
        if (a.placement == "ranked" && predictor && a.rerank > 0 &&
            (tokens_seen % a.rerank) == 0) {
            std::vector<ExpertId> ranking;
            const std::size_t slots = cache.device_capacity() + cache.host_capacity();
            predictor->warm_set(int(slots), &ranking);
            cache.apply_placement(ranking);
        }
    };

    if (a.warmup_tokens > 0) {
        std::printf("warmup %d tokens (filling the warm tier) ...\n",
                    a.warmup_tokens);
        for (int t = 0; t < a.warmup_tokens; ++t) run_token(false);
        cache.reset_stats();
    }

    const auto t_start = std::chrono::steady_clock::now();
    for (int t = 0; t < a.tokens; ++t) run_token(true);
    const double wall_ms_measured =
        std::chrono::duration<double, std::milli>(
            std::chrono::steady_clock::now() - t_start).count();
    const double wall_ms = wall_ms_measured;
    // "ideal" = everything resident: layer compute only, no CPU fallbacks.
    const double compute_ms = double(a.tokens) * a.layers * a.layer_us / 1000.0;

    const Stats& s = cache.stats();
    std::printf("\n== MemeX expert cache replay ==\n");
    std::printf("model proxy   : %d experts x %d layers = %zu experts, "
                "%.2f MB each (pool %.1f GB)\n",
                a.experts, a.layers, n_experts,
                double(expert_bytes) / 1e6, double(blob_bytes) / 1e9);
    std::printf("tiers         : device %d MB, host %d MB, rerank every %d tok\n",
                a.device_mb, a.host_mb, a.rerank);
    std::printf("lookups       : %llu (device %llu, host %llu, cpu-fallback %llu)\n",
                (unsigned long long)s.lookups, (unsigned long long)s.device_hits,
                (unsigned long long)s.host_hits,
                (unsigned long long)s.cpu_fallbacks);
    std::printf("hit rate      : %.4f  (device %.4f)\n", s.hit_rate(),
                s.lookups ? double(s.device_hits) / double(s.lookups) : 0.0);
    std::printf("disk reads    : %llu (%.2f GB), evictions %llu\n",
                (unsigned long long)s.disk_reads,
                double(s.disk_reads) * double(expert_bytes) / 1e9,
                (unsigned long long)s.evictions);
    std::printf("prefetch      : issued %llu, arrived before use %llu\n",
                (unsigned long long)s.prefetch_issued,
                (unsigned long long)s.prefetch_useful);
    if (predictor) {
        const PredictorStats& p = predictor->stats();
        std::printf("predictor     : %s, budget %d/layer -> recall %.4f, "
                    "precision %.4f (%llu guesses)\n",
                    a.predictor.c_str(), pbudget, p.recall(), p.precision(),
                    (unsigned long long)p.predicted);
    } else {
        std::printf("predictor     : %s (no model)\n", a.predictor.c_str());
    }
    // Prediction recall is misleading for prefetch (a correct guess about an
    // already-resident expert buys nothing, and deep lookahead shifts the
    // denominator). What matters is how many issued loads turned into hits.
    if (a.autotune)
        std::printf("autotune      : prefetch budget settled at %d/layer "
                    "(best measured %.2f tok/s in a %d-token window)\n",
                    pbudget, tuner.best_rate, a.tune_every);
    if (a.adaptive)
        std::printf("adaptive      : RAM tier %.2f GB (from %d MB), VRAM tier "
                    "%.0f MB (from %d MB); free VRAM seen %.0f MB\n",
                    double(cache.host_bytes()) / 1e9, a.host_mb,
                    double(cache.device_bytes()) / 1e6, a.device_mb,
                    double(ExpertCache::query_free_vram()) / 1e6);
    std::printf("placement     : %s%s, %llu plans -> %llu promotions, "
                "%llu demotions (%zu ranked slots: %zu vram + %zu ram)\n",
                a.placement.c_str(), a.plan_device ? " (incl. VRAM)" : " (RAM band only)",
                (unsigned long long)s.placements,
                (unsigned long long)s.promotions,
                (unsigned long long)s.demotions, plan_slots,
                cache.device_capacity(), cache.host_capacity());
    std::printf("prefetch payoff: %.3f device hits per issued load "
                "(lookahead %d, residency filter %s)\n",
                s.prefetch_issued ? double(s.device_hits) / double(s.prefetch_issued)
                                  : 0.0,
                a.lookahead, a.residency_filter ? "on" : "off");
    (void)needed_missing; (void)useful_hits;
    std::printf("load threads  : %.0f ms moving bytes, %.0f ms generation stalled\n",
                s.load_ms, s.stall_ms);
    std::printf("wall          : %.0f ms for %d tokens -> %.2f tok/s "
                "(simulated compute %.0f ms, i.e. %.2f tok/s ideal)\n",
                wall_ms, a.tokens, 1000.0 * a.tokens / wall_ms, compute_ms,
                compute_ms > 0 ? 1000.0 * a.tokens / compute_ms : 0.0);
    std::printf("paging cost   : %.1f%% over ideal\n",
                compute_ms > 0 ? (wall_ms / compute_ms - 1.0) * 100.0 : 0.0);
    std::printf("served        : device %zu, host %zu, cpu %zu\n",
                served_device, served_host, served_cpu);
    return 0;
}
