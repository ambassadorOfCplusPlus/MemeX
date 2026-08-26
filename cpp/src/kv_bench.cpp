// Drive the zoned context memory over a long context and report what it costs.
//
// The probe that motivated this measured attention as a single monolithic cache: 3.22 GB
// re-read per token at 32k, 162 ms on the CPU, 38 ms on the GPU, and 44 ms on the CPU
// when the tail was kept as rank-128 latents. Those numbers said the structure was worth
// building; this says what the structure actually does once positions move between zones
// - how many end up exact, how many compressed, and what a token really reads.
//
// The basis matters as much as the layout. Fitted to the model's own keys and values, a
// rank-128 projection leaves 13.11% error on K and 39.73% on V; a random projection of
// the same size leaves 91.29%. A random basis therefore measures bytes and time correctly
// while telling you nothing about quality - so pass --basis to load a fitted one, or be
// warned in the output rather than misled by it.
//
// Deliberately no ggml here. The arithmetic of attention was already timed by the probe;
// what was untested is the bookkeeping - eviction from the window, admission to the
// notebook, the elastic refusal, and the read volume that results.
#include <algorithm>
#include <chrono>
#include <cmath>
#include <cstdio>
#include <cstring>
#include <random>
#include <string>
#include <vector>

#include "memex/kv_zones.hpp"

namespace {

using Clock = std::chrono::steady_clock;

double ms_since(Clock::time_point t0) {
    return std::chrono::duration<double, std::milli>(Clock::now() - t0).count();
}

// Real keys and values for one layer, as recorded by the tracer: tag -(l+1)-30000 for K
// and -(l+1)-40000 for V, then nu*nt float32. Synthetic vectors cannot test the basis at
// all - an orthonormal basis of rank r leaves exactly sqrt(1-r/d) on isotropic noise, no
// matter how well it was fitted - so the quality question only has meaning on these.
bool read_kv_rows(const std::string& path, int layer, int d, bool values,
                  std::vector<float>* out) {
    FILE* f = fopen(path.c_str(), "rb");
    if (!f) return false;
    const int want = -layer - (values ? 40001 : 30001);
    int32_t hdr[3];
    while (fread(hdr, sizeof(int32_t), 3, f) == 3) {
        const int tag = hdr[0];
        const size_t n = size_t(hdr[1]) * size_t(hdr[2]);
        // The width test is not cosmetic: the graph names several nodes Kcur, so the
        // trace holds the layer's keys four times - at this width, reshaped, and twice
        // for the pre-norm tensor whose rows are 40x longer. Taking all of them fits the
        // basis to the copy the cache never stores.
        if (tag != want || hdr[1] != d || n % size_t(d) != 0) {
            fseek(f, long(4 * n), SEEK_CUR);
            continue;
        }
        const size_t base = out->size();
        out->resize(base + n);
        if (fread(out->data() + base, sizeof(float), n, f) != n) {
            out->resize(base);
            break;
        }
    }
    fclose(f);
    return !out->empty();
}

uint16_t f2h_local(float f) {
    uint32_t x;
    std::memcpy(&x, &f, sizeof(x));
    const uint32_t sign = (x >> 31) & 1;
    int32_t exp = int32_t((x >> 23) & 0xFF) - 127 + 15;
    const uint32_t man = x & 0x7FFFFF;
    if (exp <= 0) return uint16_t(sign << 15);
    if (exp >= 31) return uint16_t((sign << 15) | 0x7C00);
    return uint16_t((sign << 15) | (uint32_t(exp) << 10) | (man >> 13));
}

}  // namespace

int main(int argc, char** argv) {
    setvbuf(stdout, nullptr, _IONBF, 0);
    memex::KvConfig cfg;
    int n_ctx = 32768;
    int layers = 48;
    bool with_projection = true;
    int proj_threads = 2;
    std::string basis;
    std::string kv_trace;
    int layer = 20;
    for (int i = 1; i < argc; ++i) {
        if (!strcmp(argv[i], "--ctx") && i + 1 < argc) n_ctx = atoi(argv[++i]);
        else if (!strcmp(argv[i], "--rank-k") && i + 1 < argc) cfg.rank_k = atoi(argv[++i]);
        else if (!strcmp(argv[i], "--rank-v") && i + 1 < argc) cfg.rank_v = atoi(argv[++i]);
        else if (!strcmp(argv[i], "--basis") && i + 1 < argc) basis = argv[++i];
        else if (!strcmp(argv[i], "--kv-trace") && i + 1 < argc) kv_trace = argv[++i];
        else if (!strcmp(argv[i], "--layer") && i + 1 < argc) layer = atoi(argv[++i]);
        else if (!strcmp(argv[i], "--window") && i + 1 < argc) cfg.window = atoi(argv[++i]);
        else if (!strcmp(argv[i], "--notebook") && i + 1 < argc) cfg.notebook_cap = atoi(argv[++i]);
        else if (!strcmp(argv[i], "--layers") && i + 1 < argc) layers = atoi(argv[++i]);
        else if (!strcmp(argv[i], "--threads") && i + 1 < argc) proj_threads = atoi(argv[++i]);
        else if (!strcmp(argv[i], "--no-tail")) with_projection = false;
    }

    // The quantised tail needs its length up front, because value blocks run along
    // positions and a growing buffer would move every row. Nothing bigger than the context
    // can ever reach it, so that is the capacity.
    if (cfg.tail_form == memex::TailForm::Q8_0 && cfg.tail_cap == 0) {
        cfg.tail_cap = n_ctx;
    }
    memex::KvZones kv(cfg);
    kv.set_project_threads(proj_threads);
    const int d = kv.d_kv();
    printf("d_kv=%d, ранг K=%d V=%d, окно=%d, блокнот=%d, стоки=%d, ctx=%d\n",
           d, cfg.rank_k, cfg.rank_v, cfg.window, cfg.notebook_cap,
           cfg.n_sinks, n_ctx);

    std::mt19937 rng(7);
    std::normal_distribution<float> nd(0.0f, 1.0f / float(std::sqrt(double(d))));
    const bool low_rank = cfg.tail_form == memex::TailForm::LowRank;
    if (!low_rank) {
        // No basis, and nothing to warn about: the quantised tail keeps full rank, so
        // there is no projection whose calibration could be wrong. Its own error is
        // checked where it matters, by handing the blocks to a graph - see
        // examples/memex-attn.
        printf("хвост: Q8_0, полный ранг, %d байт на позицию, ёмкость %d\n",
               2 * memex::KvZones::q8_row_bytes(d), cfg.tail_cap);
    } else if (!basis.empty()) {
        std::string berr;
        if (!kv.load_basis(basis.c_str(), &berr)) {
            printf("базис не загружен: %s\n", berr.c_str());
            return 1;
        }
        printf("базис загружен из %s (подогнан под настоящие K и V)\n", basis.c_str());
    } else if (with_projection) {
        // A calibrated basis is what makes the tail faithful; this one is a timing-only
        // stand-in, labelled as such so its quality figure is never mistaken for real.
        std::vector<uint16_t> wd, wu;
        wd.resize(size_t(std::max(cfg.rank_k, cfg.rank_v)) * size_t(d));
        wu.resize(wd.size());
        for (size_t i = 0; i < wd.size(); ++i) {
            const float val = nd(rng);
            wd[i] = f2h_local(val);
            wu[i] = f2h_local(val);
        }
        kv.set_projection(wd.data(), wu.data(), wd.data(), wu.data());
        printf("ВНИМАНИЕ: базис случайный. Объём и время он мерит верно, качество нет:\n");
        printf("  подогнанный базис ранга 128 оставляет 13%% ошибки на K, случайный 91%%.\n");
    } else {
        printf("проекции нет: всё, что покидает окно, отбрасывается\n");
    }

    // Written as resize rather than a constructor argument: `vector<uint16_t> k(size_t(d))`
    // is the most vexing parse, and the compiler reads it as a function declaration.
    std::vector<uint16_t> k, v;
    k.resize(size_t(d));
    v.resize(size_t(d));
    // Importance with a heavy tail: most positions are ordinary, a few carry a fact the
    // notebook should keep. Uniform importance would make the notebook meaningless.
    std::lognormal_distribution<float> imp(0.0f, 1.0f);

    // Real vectors when a trace is given, noise otherwise. The distinction is the whole
    // point of the quality figure below: on noise the answer is fixed by the rank alone.
    std::vector<float> rk, rv;
    int n_real = 0;
    if (!kv_trace.empty()) {
        if (!read_kv_rows(kv_trace, layer, d, false, &rk) ||
            !read_kv_rows(kv_trace, layer, d, true, &rv)) {
            printf("в трассе нет K или V для слоя %d — снимай с MOE_TRACE_KV=1\n", layer);
            return 1;
        }
        n_real = int(std::min(rk.size(), rv.size()) / size_t(d));
        printf("настоящих векторов из трассы: %d (слой %d), при нехватке идут по кругу\n",
               n_real, layer);
    }

    const auto t0 = Clock::now();
    for (int t = 0; t < n_ctx; ++t) {
        if (n_real > 0) {
            const size_t off = size_t(t % n_real) * size_t(d);
            for (int j = 0; j < d; ++j) {
                k[j] = f2h_local(rk[off + size_t(j)]);
                v[j] = f2h_local(rv[off + size_t(j)]);
            }
        } else {
            for (int j = 0; j < d; ++j) {
                k[j] = f2h_local(nd(rng));
                v[j] = f2h_local(nd(rng));
            }
        }
        kv.append(k.data(), v.data(), imp(rng));
    }
    kv.flush();          // compress whatever is still staged before reading the zones
    const double build_ms = ms_since(t0);

    const auto& st = kv.stats();
    const auto sink = kv.span(memex::Zone::Sink);
    const auto note = kv.span(memex::Zone::Notebook);
    const auto tail = kv.span(memex::Zone::Tail);
    const auto win = kv.span(memex::Zone::Window);

    printf("\nзаполнение заняло %.0f мс (%d позиций, один слой, %d потоков)\n",
           build_ms, n_ctx, proj_threads);
    printf("  стоки %d, блокнот %d, хвост %d, окно %d\n",
           sink.n_pos, note.n_pos, tail.n_pos, win.n_pos);
    printf("  в блокнот попало %llu, в хвост %llu, вытеснено из блокнота %llu, "
           "запросов на расширение %llu\n",
           (unsigned long long)st.to_notebook, (unsigned long long)st.to_tail,
           (unsigned long long)st.notebook_evicted,
           (unsigned long long)st.expand_requests);

    // Round-trip error measured here, not taken from the fitting script: the point is that
    // this code reproduces it. The notebook holds real stored vectors, so it is the honest
    // place to ask - the tail holds latents, which have already lost what we are measuring.
    if (note.n_pos > 0 && low_rank && kv.has_projection()) {
        const double ek = kv.round_trip_error((const uint16_t*)note.k, note.n_pos, false);
        const double ev = kv.round_trip_error((const uint16_t*)note.v, note.n_pos, true);
        printf("\nошибка через наш код на %d векторах (%s): K %.2f%%, V %.2f%%\n",
               note.n_pos, n_real > 0 ? "настоящие" : "шум, цифра ничего не значит",
               100.0 * ek, 100.0 * ev);
    }

    // What attention reads per generated token, one layer and the whole model.
    const std::size_t zoned = kv.read_bytes_per_token();
    const std::size_t flat = std::size_t(n_ctx) * std::size_t(d) * 2 * 2;
    printf("\nчтение на один сгенерированный токен:\n");
    printf("  монолитный KV : %8.1f МБ на слой, %7.2f ГБ на %d слоёв\n",
           flat / 1e6, double(flat) * layers / 1e9, layers);
    printf("  зоны          : %8.1f МБ на слой, %7.2f ГБ на %d слоёв  (в %.2f раза меньше)\n",
           zoned / 1e6, double(zoned) * layers / 1e9, layers,
           zoned ? double(flat) / double(zoned) : 0.0);

    // Turn bytes into a ceiling using the measured bandwidths, so the number means
    // something on this machine rather than in the abstract.
    const double ram_gbs = 20.1, vram_gbs = 84.6;
    const double flat_ms_cpu = double(flat) * layers / 1e9 / ram_gbs * 1000.0;
    const double zoned_ms_cpu = double(zoned) * layers / 1e9 / ram_gbs * 1000.0;
    const double zoned_ms_gpu = double(zoned) * layers / 1e9 / vram_gbs * 1000.0;
    printf("\nпотолок по полосе (RAM %.1f ГБ/с, VRAM %.1f ГБ/с):\n", ram_gbs, vram_gbs);
    printf("  монолит на CPU: %7.1f мс -> %6.2f ток/с (только внимание)\n",
           flat_ms_cpu, 1000.0 / flat_ms_cpu);
    printf("  зоны на CPU   : %7.1f мс -> %6.2f ток/с\n",
           zoned_ms_cpu, 1000.0 / zoned_ms_cpu);
    printf("  зоны на GPU   : %7.1f мс -> %6.2f ток/с\n",
           zoned_ms_gpu, 1000.0 / zoned_ms_gpu);
    return 0;
}
