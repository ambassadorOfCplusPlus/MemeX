#include "memex/kv_zones.hpp"

#include <algorithm>
#include <cmath>
#include <cstdio>
#include <cstring>
#include <thread>

namespace memex {

namespace {

// fp16 helpers. The cache is stored in half precision because that is what the model
// produces and what attention reads; converting to float would double the very traffic
// the zones exist to reduce.
inline float h2f(uint16_t h) {
    const uint32_t sign = uint32_t(h >> 15) << 31;
    uint32_t exp = (h >> 10) & 0x1F;
    uint32_t man = h & 0x3FF;
    uint32_t bits;
    if (exp == 0) {
        if (man == 0) {
            bits = sign;
        } else {
            exp = 127 - 15 + 1;
            while ((man & 0x400) == 0) {
                man <<= 1;
                exp--;
            }
            man &= 0x3FF;
            bits = sign | (exp << 23) | (man << 13);
        }
    } else if (exp == 31) {
        bits = sign | 0x7F800000u | (man << 13);
    } else {
        bits = sign | ((exp - 15 + 127) << 23) | (man << 13);
    }
    float f;
    std::memcpy(&f, &bits, sizeof(f));
    return f;
}

inline uint16_t f2h(float f) {
    uint32_t x;
    std::memcpy(&x, &f, sizeof(x));
    const uint32_t sign = (x >> 31) & 1;
    int32_t exp = int32_t((x >> 23) & 0xFF) - 127 + 15;
    uint32_t man = x & 0x7FFFFF;
    if (exp <= 0) {
        return uint16_t(sign << 15);          // underflow to zero, good enough here
    }
    if (exp >= 31) {
        return uint16_t((sign << 15) | 0x7C00);
    }
    return uint16_t((sign << 15) | (uint32_t(exp) << 10) | (man >> 13));
}

// One Q8_0 block, byte-for-byte ggml's: 32 values sharing an fp16 scale, 34 bytes. Written
// by hand so this file keeps no ggml dependency - the same choice the expert blob made,
// and checkable the same way, by handing the result to a graph and comparing the answer.
constexpr int kQ8Block = 32;
constexpr int kQ8Bytes = 34;

void quant_q8_row(const float* x, int n, uint8_t* dst) {
    for (int b = 0; b * kQ8Block < n; ++b) {
        const int base = b * kQ8Block;
        float amax = 0.0f;
        for (int i = 0; i < kQ8Block; ++i) {
            const float v = base + i < n ? x[size_t(base + i)] : 0.0f;
            amax = std::max(amax, std::abs(v));
        }
        // A block of exact zeros has no scale worth storing; zero keeps the decode from
        // dividing by nothing, and padded lanes decode to zero either way.
        const float d = amax / 127.0f;
        const float id = d > 0.0f ? 1.0f / d : 0.0f;
        uint8_t* blk = dst + size_t(b) * kQ8Bytes;
        const uint16_t dh = f2h(d);
        std::memcpy(blk, &dh, sizeof(dh));
        int8_t* qs = (int8_t*)(blk + 2);
        for (int i = 0; i < kQ8Block; ++i) {
            const float v = base + i < n ? x[size_t(base + i)] : 0.0f;
            const float r = v * id;
            qs[i] = int8_t(r < 0.0f ? r - 0.5f : r + 0.5f);
        }
    }
}

// A random Hadamard rotation: Sylvester construction times a fixed sign diagonal, so it is
// orthonormal, deterministic, and needs neither storage nor calibration. Requires the
// dimension to be a power of two, which head_dim is.
//
// Why it belongs here: block quantisation is limited by the largest value in each block, and
// a rotation spreads outliers evenly over the coordinates. Since a dot product is invariant
// under a shared rotation, the scores are unchanged as long as the query is rotated to
// match - so the accuracy is bought for the price of one small matrix product per token.
void build_rotation(int n, std::vector<float>* out) {
    if (n <= 0 || (n & (n - 1)) != 0) {
        out->clear();
        return;               // not a power of two: no Sylvester matrix, so no rotation
    }
    std::vector<int8_t> sign;
    sign.resize(size_t(n));
    uint32_t s = 0x9E3779B9u;
    for (int i = 0; i < n; ++i) {
        s = s * 1664525u + 1013904223u;
        sign[size_t(i)] = (s >> 16) & 1 ? 1 : -1;
    }
    const float scale = 1.0f / std::sqrt(float(n));
    out->assign(size_t(n) * size_t(n), 0.0f);
    for (int i = 0; i < n; ++i) {
        for (int j = 0; j < n; ++j) {
            int bits = i & j, par = 0;
            while (bits) {
                par ^= bits & 1;
                bits >>= 1;
            }
            (*out)[size_t(i) * size_t(n) + size_t(j)] =
                (par ? -scale : scale) * float(sign[size_t(j)]);
        }
    }
}

}  // namespace

KvZones::KvZones(KvConfig cfg) : cfg_(cfg) {
    sink_k_.reserve(size_t(cfg_.n_sinks) * d_kv());
    sink_v_.reserve(size_t(cfg_.n_sinks) * d_kv());
    note_k_.reserve(size_t(cfg_.notebook_cap) * d_kv());
    note_v_.reserve(size_t(cfg_.notebook_cap) * d_kv());
    window_.reserve(size_t(cfg_.window) + 1);
    // Staging was reserved in set_projection, which the quantised tail never calls.
    pending_k_.reserve(size_t(pending_cap_) * d_kv());
    pending_v_.reserve(size_t(pending_cap_) * d_kv());
    if (cfg_.tail_form == TailForm::Q8_0 && cfg_.tail_cap > 0) {
        // Rounded to a whole number of blocks, and preallocated: value blocks run along
        // positions, so growing the buffer later would move every row.
        const int cap = (cfg_.tail_cap + kQ8Block - 1) / kQ8Block * kQ8Block;
        cfg_.tail_cap = cap;
        tail_kq_.assign(size_t(cfg_.n_kv_heads) * size_t(cap) *
                            size_t(q8_row_bytes(cfg_.head_dim)), 0);
        tail_vq_.assign(size_t(cfg_.n_kv_heads) * size_t(cfg_.head_dim) *
                            size_t(q8_row_bytes(cap)), 0);
        if (cfg_.rotate_tail_keys) {
            build_rotation(cfg_.head_dim, &rot_);
        }
    }
}

void KvZones::set_projection(const uint16_t* wk_down, const uint16_t* wk_up,
                             const uint16_t* wv_down, const uint16_t* wv_up) {
    const size_t nk = size_t(cfg_.rank_k) * d_kv();
    const size_t nv = size_t(cfg_.rank_v) * d_kv();
    wk_down_f_.resize(nk);
    wv_down_f_.resize(nv);
    for (size_t i = 0; i < nk; ++i) {
        wk_down_f_[i] = h2f(wk_down[i]);
    }
    for (size_t i = 0; i < nv; ++i) {
        wv_down_f_[i] = h2f(wv_down[i]);
    }
    wk_up_.assign(wk_up, wk_up + nk);
    wv_up_.assign(wv_up, wv_up + nv);
    pending_k_.reserve(size_t(pending_cap_) * d_kv());
    pending_v_.reserve(size_t(pending_cap_) * d_kv());
}

bool KvZones::load_basis(const char* path, std::string* err) {
    FILE* f = fopen(path, "rb");
    if (!f) {
        if (err) *err = std::string("не открывается файл базиса: ") + path;
        return false;
    }
    int32_t hdr[2] = {0, 0};
    if (fread(hdr, sizeof(int32_t), 2, f) != 2) {
        fclose(f);
        if (err) *err = "файл базиса пуст";
        return false;
    }
    const int rank = hdr[0], d = hdr[1];
    if (d != d_kv()) {
        fclose(f);
        if (err) *err = "d_kv в файле не совпадает с конфигурацией";
        return false;
    }
    // The file holds one rank for both sides; the configuration may ask for less on one
    // of them, which is fine - the leading rows of an eigenbasis are still the best
    // basis of that smaller size. Asking for more than the file has is not.
    if (cfg_.rank_k > rank || cfg_.rank_v > rank) {
        fclose(f);
        if (err) *err = "в файле базиса меньше рангов, чем просит конфигурация";
        return false;
    }
    const size_t per = size_t(rank) * size_t(d);
    std::vector<uint16_t> buf(per * 4);
    const size_t got = fread(buf.data(), sizeof(uint16_t), per * 4, f);
    fclose(f);
    if (got != per * 4) {
        if (err) *err = "файл базиса короче ожидаемого";
        return false;
    }
    // Layout: W_down(K), W_up(K), W_down(V), W_up(V), each [rank, d_kv].
    std::vector<uint16_t> kd(buf.begin(), buf.begin() + size_t(cfg_.rank_k) * d);
    std::vector<uint16_t> ku(buf.begin() + per,
                             buf.begin() + per + size_t(cfg_.rank_k) * d);
    std::vector<uint16_t> vd(buf.begin() + 2 * per,
                             buf.begin() + 2 * per + size_t(cfg_.rank_v) * d);
    std::vector<uint16_t> vu(buf.begin() + 3 * per,
                             buf.begin() + 3 * per + size_t(cfg_.rank_v) * d);
    set_projection(kd.data(), ku.data(), vd.data(), vu.data());
    return true;
}

double KvZones::round_trip_error(const uint16_t* rows, int n_rows, bool values) const {
    const std::vector<float>& w = values ? wv_down_f_ : wk_down_f_;
    const int r = values ? cfg_.rank_v : cfg_.rank_k;
    if (w.empty() || n_rows <= 0) {
        return -1.0;
    }
    const int d = d_kv();
    double num = 0.0, den = 0.0;
    std::vector<float> x, c, back;
    x.resize(size_t(d));
    c.resize(size_t(r));
    back.resize(size_t(d));
    for (int p = 0; p < n_rows; ++p) {
        const uint16_t* row = rows + size_t(p) * d;
        for (int j = 0; j < d; ++j) {
            x[size_t(j)] = h2f(row[j]);
        }
        for (int i = 0; i < r; ++i) {
            const float* wi = w.data() + size_t(i) * d;
            float acc = 0.0f;
            for (int j = 0; j < d; ++j) {
                acc += wi[j] * x[size_t(j)];
            }
            c[size_t(i)] = acc;
        }
        std::fill(back.begin(), back.end(), 0.0f);
        for (int i = 0; i < r; ++i) {
            const float* wi = w.data() + size_t(i) * d;
            const float ci = c[size_t(i)];
            for (int j = 0; j < d; ++j) {
                back[size_t(j)] += ci * wi[j];
            }
        }
        for (int j = 0; j < d; ++j) {
            const double dx = double(back[size_t(j)]) - double(x[size_t(j)]);
            num += dx * dx;
            den += double(x[size_t(j)]) * double(x[size_t(j)]);
        }
    }
    return den > 0.0 ? std::sqrt(num / den) : 0.0;
}

void KvZones::push_exact(std::vector<uint16_t>* dst, const uint16_t* row) {
    dst->insert(dst->end(), row, row + d_kv());
}

void KvZones::stage_for_tail(const uint16_t* k, const uint16_t* v) {
    const int d = d_kv();
    pending_k_.insert(pending_k_.end(), k, k + d);
    pending_v_.insert(pending_v_.end(), v, v + d);
    if (++pending_ >= pending_cap_) {
        flush_pending();
    }
}

void KvZones::flush_pending() {
    if (cfg_.tail_form == TailForm::Q8_0) {
        flush_pending_q8();
    } else {
        flush_pending_lowrank();
    }
}

void KvZones::flush() {
    flush_pending();
}

// Quantise straight into the layout a graph wants.
//
// Keys are per-position: a row is one head of one position, so an arrival is written once
// and never touched again. Values are the awkward side - a row is one dimension across all
// positions, so a block of 32 spans 32 positions and cannot be finalised until the last of
// them arrives. The staging buffer therefore keeps the originals of every position in the
// currently unfinished block, and that block is rewritten from those originals each time.
//
// Rewriting from originals rather than from the quantised bytes matters: requantising what
// was already quantised would compound the error on exactly the oldest positions, which
// are the ones the structure exists to keep cheaply.
void KvZones::flush_pending_q8() {
    if (tail_kq_.empty()) {
        return;
    }
    const int d = d_kv();
    const int hd = cfg_.head_dim;
    const int cap = cfg_.tail_cap;
    const int k_row = q8_row_bytes(hd);
    const int v_row = q8_row_bytes(cap);
    // Positions already written but still staged because their block is unfinished.
    const int carried = tail_pos_ - tail_blk_base_;
    int n_new = pending_ - carried;
    if (n_new <= 0) {
        return;
    }
    if (tail_pos_ + n_new > cap) {
        // The tail is full. Dropping is the honest failure: pretending a position was
        // stored would make the read accounting describe a cache that does not exist.
        n_new = cap - tail_pos_;
        if (n_new <= 0) {
            return;
        }
    }
    const int total = tail_pos_ + n_new;

    std::vector<float> x, rbuf;
    x.resize(size_t(d));
    rbuf.resize(size_t(hd));
    for (int p = 0; p < n_new; ++p) {
        const uint16_t* kp = pending_k_.data() + size_t(carried + p) * size_t(d);
        for (int j = 0; j < d; ++j) {
            x[size_t(j)] = h2f(kp[j]);
        }
        for (int g = 0; g < cfg_.n_kv_heads; ++g) {
            uint8_t* dst = tail_kq_.data() +
                (size_t(g) * size_t(cap) + size_t(tail_pos_ + p)) * size_t(k_row);
            const float* src = x.data() + size_t(g) * size_t(hd);
            if (!rot_.empty()) {
                for (int i = 0; i < hd; ++i) {
                    const float* r = rot_.data() + size_t(i) * size_t(hd);
                    float acc = 0.0f;
                    for (int j = 0; j < hd; ++j) {
                        acc += r[j] * src[j];
                    }
                    rbuf[size_t(i)] = acc;
                }
                src = rbuf.data();
            }
            quant_q8_row(src, hd, dst);
        }
    }

    std::vector<float> lane;
    lane.resize(size_t(kQ8Block));
    const int blk_from = tail_blk_base_ / kQ8Block;
    const int blk_to = (total + kQ8Block - 1) / kQ8Block;
    for (int b = blk_from; b < blk_to; ++b) {
        for (int g = 0; g < cfg_.n_kv_heads; ++g) {
            for (int j = 0; j < hd; ++j) {
                for (int i = 0; i < kQ8Block; ++i) {
                    const int pos = b * kQ8Block + i;
                    // Beyond what has arrived the lane is zero; those positions are
                    // masked out of the softmax, so the value never reaches an answer.
                    float val = 0.0f;
                    if (pos >= tail_blk_base_ && pos < total) {
                        const uint16_t* vp = pending_v_.data() +
                                             size_t(pos - tail_blk_base_) * size_t(d);
                        val = h2f(vp[size_t(g) * size_t(hd) + size_t(j)]);
                    }
                    lane[size_t(i)] = val;
                }
                uint8_t* dst = tail_vq_.data() +
                    (size_t(g) * size_t(hd) + size_t(j)) * size_t(v_row) +
                    size_t(b) * kQ8Bytes;
                quant_q8_row(lane.data(), kQ8Block, dst);
            }
        }
    }

    tail_pos_ = total;
    tail_settled_ = total / kQ8Block * kQ8Block;
    stats_.to_tail += uint64_t(n_new);
    // Keep exactly the positions of the unfinished block, drop the rest.
    const int new_base = total - total % kQ8Block;
    const size_t drop = size_t(new_base - tail_blk_base_) * size_t(d);
    if (drop > 0 && drop <= pending_k_.size()) {
        pending_k_.erase(pending_k_.begin(), pending_k_.begin() + long(drop));
        pending_v_.erase(pending_v_.begin(), pending_v_.begin() + long(drop));
    }
    tail_blk_base_ = new_base;
    pending_ = total - new_base;
    pending_k_.resize(size_t(pending_) * size_t(d));
    pending_v_.resize(size_t(pending_) * size_t(d));
}

void KvZones::flush_pending_lowrank() {
    if (pending_ == 0) {
        return;
    }
    // c = W_down * x for the whole batch. The basis is already float and the inputs are
    // converted once per position, so the inner loop is a float dot product - which is
    // the difference between 0.26 ms per position and something a prefill can afford.
    const int d = d_kv();
    const int rk = cfg_.rank_k;
    const int rv = cfg_.rank_v;
    // resize rather than a constructor argument: `vector<float> xk(size_t(d))` is the
    // most vexing parse and compiles as a function declaration
    std::vector<float> xk, xv;
    xk.resize(size_t(d));
    xv.resize(size_t(d));
    const size_t base_k = tail_k_.size();
    const size_t base_v = tail_v_.size();
    tail_k_.resize(base_k + size_t(pending_) * rk);
    tail_v_.resize(base_v + size_t(pending_) * rv);
    // Positions are independent, so the batch splits across threads with no
    // synchronisation. This is the difference between 137 s of projection for a 32k
    // prefill and something a prefill can absorb. Two threads by default: the expert
    // FFN already saturates memory bandwidth at two, so the rest of the machine is
    // what this is allowed to use.
    auto work = [&](int from, int to, std::vector<float>* xkb, std::vector<float>* xvb) {
        for (int p = from; p < to; ++p) {
            const uint16_t* kp = pending_k_.data() + size_t(p) * d;
            const uint16_t* vp = pending_v_.data() + size_t(p) * d;
            for (int j = 0; j < d; ++j) {
                (*xkb)[j] = h2f(kp[j]);
                (*xvb)[j] = h2f(vp[j]);
            }
            uint16_t* ck = tail_k_.data() + base_k + size_t(p) * rk;
            uint16_t* cv = tail_v_.data() + base_v + size_t(p) * rv;
            for (int i = 0; i < rk; ++i) {
                const float* w = wk_down_f_.data() + size_t(i) * d;
                float acc = 0.0f;
                for (int j = 0; j < d; ++j) {
                    acc += w[j] * (*xkb)[j];
                }
                ck[i] = f2h(acc);
            }
            for (int i = 0; i < rv; ++i) {
                const float* w = wv_down_f_.data() + size_t(i) * d;
                float acc = 0.0f;
                for (int j = 0; j < d; ++j) {
                    acc += w[j] * (*xvb)[j];
                }
                cv[i] = f2h(acc);
            }
        }
    };
    const int nth = std::max(1, project_threads_);
    if (nth == 1 || pending_ < 8) {
        work(0, pending_, &xk, &xv);
    } else {
        std::vector<std::thread> pool;
        // resize, not a constructor argument: `vector<...> bk(size_t(nth))` is the most
        // vexing parse and compiles as a function declaration - this is the third time
        // that bit in this file.
        std::vector<std::vector<float>> bk, bv;
        bk.resize(size_t(nth));
        bv.resize(size_t(nth));
        const int chunk = (pending_ + nth - 1) / nth;
        for (int t = 0; t < nth; ++t) {
            const int from = t * chunk;
            const int to = std::min(pending_, from + chunk);
            if (from >= to) {
                break;
            }
            bk[size_t(t)].resize(size_t(d));
            bv[size_t(t)].resize(size_t(d));
            pool.emplace_back(work, from, to, &bk[size_t(t)], &bv[size_t(t)]);
        }
        for (auto& th : pool) {
            th.join();
        }
    }
    tail_pos_ += pending_;
    stats_.to_tail += uint64_t(pending_);
    pending_ = 0;
    pending_k_.clear();
    pending_v_.clear();
}

bool KvZones::notebook_admit(float importance) {
    if (int(notebook_pos_.size()) < cfg_.notebook_cap) {
        return true;
    }
    // Elastic notebook: when nothing held is less important than the candidate, the
    // honest answer is to ask for room rather than to discard something that matters.
    // The threshold is scale-free - a share of the mean - because importances arrive on
    // whatever scale the model produces.
    double mean = 0.0;
    for (float v : notebook_importance_) {
        mean += v;
    }
    mean = notebook_importance_.empty() ? 0.0
                                       : mean / double(notebook_importance_.size());
    const auto weakest = std::min_element(notebook_importance_.begin(),
                                          notebook_importance_.end());
    if (weakest == notebook_importance_.end()) {
        return false;
    }
    if (importance <= *weakest) {
        return false;      // ordinary refusal: nothing here is worth less than this
    }
    // The arrival deserves a place. If the position it would displace is itself valuable
    // - not far below the notebook's average - then discarding it is the wrong trade, and
    // the honest response is to ask for room. This is the "evict or expand" rule, and
    // getting the direction wrong reported almost every ordinary refusal as a dilemma.
    if (cfg_.elastic_notebook && *weakest >= 0.5 * mean) {
        stats_.expand_requests++;
        return false;
    }
    // Displace the weakest: it goes to the tail rather than disappearing, so the
    // information degrades instead of vanishing.
    const size_t idx = size_t(weakest - notebook_importance_.begin());
    const int d = d_kv();
    if (tail_ready()) {
        stage_for_tail(note_k_.data() + idx * d, note_v_.data() + idx * d);
    }
    note_k_.erase(note_k_.begin() + idx * d, note_k_.begin() + (idx + 1) * d);
    note_v_.erase(note_v_.begin() + idx * d, note_v_.begin() + (idx + 1) * d);
    notebook_importance_.erase(notebook_importance_.begin() + idx);
    notebook_pos_.erase(notebook_pos_.begin() + idx);
    stats_.notebook_evicted++;
    return true;
}

void KvZones::drain_window() {
    while (int(window_.size()) > cfg_.window) {
        WinEntry e = std::move(window_.front());
        window_.erase(window_.begin());
        if (notebook_admit(e.importance)) {
            push_exact(&note_k_, e.k.data());
            push_exact(&note_v_, e.v.data());
            notebook_importance_.push_back(e.importance);
            notebook_pos_.push_back(int(stats_.appended));
            stats_.to_notebook++;
        } else if (tail_ready()) {
            stage_for_tail(e.k.data(), e.v.data());
        }
        // Without a projection the position is simply dropped, which is why
        // set_projection is required before long contexts: silently losing the tail
        // would look like a working cache while quietly forgetting the past.
    }
}

void KvZones::append(const uint16_t* k, const uint16_t* v, float importance) {
    const int d = d_kv();
    if (sinks_pos_ < cfg_.n_sinks) {
        push_exact(&sink_k_, k);
        push_exact(&sink_v_, v);
        sinks_pos_++;
        stats_.appended++;
        return;
    }
    WinEntry e;
    e.k.assign(k, k + d);
    e.v.assign(v, v + d);
    e.importance = importance;
    window_.push_back(std::move(e));
    stats_.appended++;
    drain_window();
}

int KvZones::copy_exact(std::vector<uint16_t>* k_rows,
                        std::vector<uint16_t>* v_rows) const {
    const int d = d_kv();
    const int n = sinks_pos_ + int(notebook_pos_.size()) + int(window_.size());
    k_rows->clear();
    v_rows->clear();
    k_rows->reserve(size_t(n) * size_t(d));
    v_rows->reserve(size_t(n) * size_t(d));
    // Order is sinks, notebook, window. Attention is a sum over a set, so the order does
    // not change the result - but it has to be the same order for K and V, which is the
    // one thing that would silently pair a score with the wrong value.
    k_rows->insert(k_rows->end(), sink_k_.begin(), sink_k_.end());
    v_rows->insert(v_rows->end(), sink_v_.begin(), sink_v_.end());
    k_rows->insert(k_rows->end(), note_k_.begin(), note_k_.end());
    v_rows->insert(v_rows->end(), note_v_.begin(), note_v_.end());
    for (const WinEntry& e : window_) {
        k_rows->insert(k_rows->end(), e.k.begin(), e.k.end());
        v_rows->insert(v_rows->end(), e.v.begin(), e.v.end());
    }
    return n;
}

ZoneSpan KvZones::span(Zone z) const {
    ZoneSpan s;
    switch (z) {
        case Zone::Sink:
            s.k = (const uint8_t*)sink_k_.data();
            s.v = (const uint8_t*)sink_v_.data();
            s.n_pos = sinks_pos_;
            s.width = d_kv();
            break;
        case Zone::Notebook:
            s.k = (const uint8_t*)note_k_.data();
            s.v = (const uint8_t*)note_v_.data();
            s.n_pos = int(notebook_pos_.size());
            s.width = d_kv();
            break;
        case Zone::Tail:
            if (cfg_.tail_form == TailForm::Q8_0) {
                // Quantised blocks, already in the layout a graph wants. The width is the
                // logical one; the byte stride is q8_row_bytes of head_dim for keys and of
                // the capacity for values, which is why those are separate accessors.
                s.k = tail_kq_.data();
                s.v = tail_vq_.data();
                s.n_pos = tail_pos_;
                s.width = d_kv();
            } else {
                s.k = (const uint8_t*)tail_k_.data();
                s.v = (const uint8_t*)tail_v_.data();
                s.n_pos = tail_pos_;
                s.width = cfg_.rank_k;      // K width; V uses rank_v, see config()
            }
            break;
        case Zone::Window:
            // The window is stored per position, so it has no single contiguous span;
            // the caller reads it entry by entry. Reported for accounting only.
            s.n_pos = int(window_.size());
            s.width = d_kv();
            break;
    }
    return s;
}

std::size_t KvZones::read_bytes_per_token() const {
    const std::size_t d = std::size_t(d_kv()) * 2;      // fp16, K and V counted below
    const std::size_t exact =
        (std::size_t(sinks_pos_) + notebook_pos_.size() + window_.size()) * d * 2;
    const std::size_t tail = cfg_.tail_form == TailForm::Q8_0
        ? std::size_t(tail_pos_) * std::size_t(q8_row_bytes(d_kv())) * 2
        : std::size_t(tail_pos_) * std::size_t(cfg_.rank_k + cfg_.rank_v) * 2;
    return exact + tail;
}

}  // namespace memex
