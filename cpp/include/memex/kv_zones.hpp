// The context memory: four zones over one KV cache.
//
// Why the engine needs this at all. Attention re-reads the whole cache for every
// generated token, and for this model each context token costs 98 KB across all layers
// (4 kv-heads x 128 dims x 2 tensors x 2 bytes x 48 layers). So 4k of context is ~400
// MB per token and 32k is 3.2 GB - measured at 162 ms per token on the CPU, which caps
// generation at six tokens a second from attention alone. Beyond a few thousand tokens
// the context, not the weights, is the wall.
//
// The zones exist because those bytes are not equally useful:
//
//   sinks   - the first few positions. Attention leans on them heavily whatever the
//             content, so they stay exact and are never evicted.
//   notebook- positions worth keeping exactly although they are old: the facts a later
//             question will need. Full rank, bounded, and refilled by policy.
//   tail    - the bulk of the past, kept compressed. The zone itself is confirmed; its
//             representation is not what this file was built for. Rank-r latents were the
//             original plan and they are refuted: at 512 bytes per position rank 128
//             leaves 78.96% error on the attention output, while four-bit full rank at 576
//             bytes leaves 31.72% and eight-bit at 1088 leaves 3.09%. Low rank loses even
//             with a basis fitted on the very text being measured (55.08%). The cause is
//             structural - grouped-query attention already compressed the cache fourfold,
//             d_kv 512 against n_embd 2048, so the remaining spectrum is nearly flat and a
//             low-rank basis is compressing what was compressed already.
//
//             The projection machinery below stays because it is measured and because a
//             model without grouped-query attention would have more slack, but the tail an
//             engine should ship holds full-rank values at low precision. See
//             ARCHITECTURE.md 8.23.
//   window  - the most recent positions, exact, because local attention is where
//             approximation hurts most.
//
// This module owns the layout and the movement between zones. It deliberately knows
// nothing about ggml: the graph is built by the caller from the spans this hands out,
// which keeps the zone logic testable on its own.
#pragma once

#include <cstddef>
#include <cstdint>
#include <memory>
#include <string>
#include <vector>

namespace memex {

// What the tail holds once a position leaves the window.
//
// LowRank was the original design and it is refuted by measurement: at 512 bytes per
// position a rank-128 basis leaves 78.96% error on the attention output, where eight-bit
// full rank at 1088 bytes leaves 3.09% and four-bit at 576 leaves 31.72%. Kept as an
// option because it is measured and because a model without grouped-query attention would
// have more spectrum to exploit, but it is not what an engine should run.
//
// Q8_0 is ggml's own block format - 32 values sharing one fp16 scale, 34 bytes - so the
// tail can be handed to a graph as a tensor with no conversion. Written here by hand
// rather than through ggml, which keeps this file free of that dependency; the expert blob
// does the same thing for the same reason.
enum class TailForm : uint8_t { LowRank = 0, Q8_0 = 1 };

struct KvConfig {
    int n_kv_heads = 4;
    int head_dim = 128;
    TailForm tail_form = TailForm::Q8_0;
    // Separate widths, because the two spectra genuinely differ: at rank 128 of 512 the
    // keys lose 15.6% and the values 39.7%. Held apart so the split can be tuned per
    // model - but on this one it should not be tuned far. Sweeping a fixed budget of 256
    // latents per position gives a flat optimum around the middle: 23.39% combined at
    // 128/128, 23.49% at 96/160, and 25.49% at 64/192.
    //
    // The defaults were briefly 64/192, from a sweep whose trace recorded the keys four
    // times - one copy pre-k_norm with rows 40x longer, hence ~1600x the covariance
    // energy. That copy dominated the fit, made the keys look cheap to compress, and so
    // argued for spending the budget on values. On one record per pass the argument
    // disappears. Left as a warning that a basis fitted to the wrong vectors reports
    // excellent numbers right up until something checks them.
    int rank_k = 128;
    int rank_v = 128;
    int n_sinks = 4;
    int notebook_cap = 64;
    int window = 512;
    // Tail capacity in positions, preallocated. Required by the quantised tail and unused
    // by the low-rank one, for a structural reason rather than an implementation
    // preference: values are quantised in blocks of 32 *along positions*, because the
    // graph needs them with positions in the fast dimension, so a position's bytes sit
    // interleaved with those of 31 neighbours. Growing such a buffer would mean moving
    // every row, so the length is fixed up front and the unused tail is masked - which is
    // exactly what llama.cpp does with its own cache.
    int tail_cap = 0;
    // Rotate keys by a random Hadamard matrix before quantising them. Free in quality
    // terms and it halves the error: a dot product is invariant under a shared rotation,
    // so the query is rotated to match and the scores come out identical, while block
    // quantisation - limited by the largest value in each block - gets a flat distribution
    // to work with instead of one with outliers. Measured on the attention output: 3.09%
    // becomes 1.57% at eight bits.
    //
    // Keys only, and that is measured rather than assumed. Rotating values as well gives
    // 1.58% against 1.57%, which is nothing, because value blocks run along *positions*
    // while the rotation mixes *dimensions* - so it cannot flatten anything inside a block.
    // Skipping it also removes the inverse rotation the output would otherwise need.
    bool rotate_tail_keys = true;
    bool elastic_notebook = true;   // ask to grow before discarding a kept position
};

enum class Zone : uint8_t { Sink = 0, Notebook = 1, Tail = 2, Window = 3 };

struct KvStats {
    uint64_t appended = 0;
    uint64_t to_notebook = 0;     // left the window and was kept exactly
    uint64_t to_tail = 0;         // left the window and was compressed
    uint64_t notebook_evicted = 0;
    uint64_t expand_requests = 0; // elastic notebook asked for room instead of dropping
    // Bytes attention would read for one token, by zone. The point of the whole
    // structure is that these differ by an order of magnitude.
    std::size_t bytes_exact = 0;
    std::size_t bytes_tail = 0;
};

// One zone's contents as plain spans, ready to wrap in tensors.
struct ZoneSpan {
    const uint8_t* k = nullptr;
    const uint8_t* v = nullptr;
    int n_pos = 0;
    int width = 0;            // d_kv for exact zones, rank for the tail
};

class KvZones {
  public:
    explicit KvZones(KvConfig cfg);

    int d_kv() const { return cfg_.n_kv_heads * cfg_.head_dim; }
    const KvConfig& config() const { return cfg_; }

    // Add one position. `k` and `v` are fp16 rows of d_kv values. `importance` decides
    // where the position goes when it later leaves the window; the caller supplies it,
    // because only the model knows which positions a future query will want.
    void append(const uint16_t* k, const uint16_t* v, float importance);

    // Bases for the tail, one per side, as fitted to the model's own vectors. Until
    // they are set, compression is refused: a random basis would read the same bytes
    // while destroying the content, which is worse than an honest failure.
    void set_projection(const uint16_t* wk_down, const uint16_t* wk_up,
                        const uint16_t* wv_down, const uint16_t* wv_up);
    // Load the file written by memex/fit_kv_basis.py. Returns false if the ranks in the
    // file disagree with the configuration, rather than quietly reinterpreting it.
    bool load_basis(const char* path, std::string* err);
    void set_project_threads(int n) { project_threads_ = n; }

    // Round-trip error of the fitted basis, measured through this code rather than
    // taken from the fitting script - the check that the C++ path reproduces it.
    double round_trip_error(const uint16_t* rows, int n_rows, bool values) const;
    bool has_projection() const { return !wk_down_f_.empty(); }
    // Whether the tail can take a position at all. The low-rank form needs a fitted
    // basis; the quantised form needs its buffers, which means a capacity was configured.
    // Without either, a position leaving the window is dropped, and a cache that silently
    // forgets the past looks exactly like one that works.
    bool tail_ready() const {
        return cfg_.tail_form == TailForm::Q8_0 ? !tail_kq_.empty() : has_projection();
    }

    // Compress whatever is still staged. Call before reading the tail span, otherwise
    // the last positions are counted as pending rather than present.
    void flush();

    ZoneSpan span(Zone z) const;

    // Sinks, notebook and window laid out as one [n_pos, d_kv] pair, which is what a
    // graph wants: the three exact zones differ in policy but not in shape, and attention
    // has no reason to visit them separately. Returns the number of positions written.
    //
    // This copies. The window is stored per position so that eviction is a move rather
    // than a shuffle, and that choice is right for the policy and wrong for the graph. An
    // engine generating token after token would keep the window as a ring buffer and hand
    // out a view; here the copy happens once per measurement and stays out of the timing.
    int copy_exact(std::vector<uint16_t>* k_rows, std::vector<uint16_t>* v_rows) const;
    const uint16_t* projection_up_k() const { return wk_up_.data(); }
    const uint16_t* projection_up_v() const { return wv_up_.data(); }

    // The quantised tail, laid out for a graph and nothing else.
    //
    // Keys as [head_dim, capacity, n_kv_heads]: a row is one head of one position, so a
    // position is four independent rows and can be written the moment it arrives.
    // Values as [capacity, head_dim, n_kv_heads]: a row is one dimension across all
    // positions, which is what lets the weighted sum be a plain matrix-vector product -
    // and which is also why a block cannot be finalised until 32 positions have arrived.
    const uint8_t* tail_k_q() const { return tail_kq_.data(); }
    const uint8_t* tail_v_q() const { return tail_vq_.data(); }
    int tail_positions() const { return tail_pos_; }
    // The rotation the tail keys were stored under, [head_dim, head_dim] row-major, or
    // null when rotation is off. The caller must rotate the query by the same matrix
    // before scoring against the tail - otherwise the scores are simply wrong, which is
    // the one way this optimisation can go bad silently.
    const float* key_rotation() const {
        return rot_.empty() ? nullptr : rot_.data();
    }
    // Positions whose value blocks are complete. Positions between this and
    // tail_positions() are present but sit in a block that will be rewritten when it
    // fills, so a reader that cares about exactness should stop here.
    int tail_settled() const { return tail_settled_; }
    static int q8_row_bytes(int n) { return (n + 31) / 32 * 34; }

    int n_positions() const {
        return int(sinks_pos_ + notebook_pos_.size() + tail_pos_ + window_.size());
    }
    const KvStats& stats() const { return stats_; }
    // What one token of attention costs to read, given the current zone occupancy.
    std::size_t read_bytes_per_token() const;

  private:
    void drain_window();
    void push_exact(std::vector<uint16_t>* dst, const uint16_t* row);
    void stage_for_tail(const uint16_t* k, const uint16_t* v);
    void flush_pending();          // compress everything staged, as one batch
    void flush_pending_lowrank();
    void flush_pending_q8();
    bool notebook_admit(float importance);

    KvConfig cfg_;
    // Exact zones are stored as [pos, d_kv] fp16, one array for K and one for V.
    std::vector<uint16_t> sink_k_, sink_v_;
    std::vector<uint16_t> note_k_, note_v_;
    std::vector<uint16_t> tail_k_, tail_v_;    // [pos, rank], low-rank form only
    std::vector<uint8_t> tail_kq_, tail_vq_;   // Q8_0 blocks, preallocated to tail_cap
    std::vector<float> rot_;                   // [head_dim, head_dim], keys only
    int tail_settled_ = 0;
    // Absolute index of the first staged position, which is also the start of the
    // unfinished value block.
    int tail_blk_base_ = 0;
    struct WinEntry {
        std::vector<uint16_t> k, v;
        float importance = 0.0f;
    };
    std::vector<WinEntry> window_;
    std::vector<float> notebook_importance_;
    std::vector<int> notebook_pos_;
    // Held in float, not fp16: the basis is read for every compressed position, and
    // converting it inside the inner loop cost more than storing it plainly (256 KB).
    std::vector<float> wk_down_f_, wv_down_f_;   // [rank_k, d_kv], [rank_v, d_kv]
    std::vector<uint16_t> wk_up_, wv_up_;        // handed to the caller for the query
    // Positions leaving the window wait here so compression is a matrix product rather
    // than a sequence of vector ones.
    std::vector<uint16_t> pending_k_, pending_v_;
    int pending_ = 0;
    int pending_cap_ = 256;        // bigger batches so threading amortises
    // Threads used for projection. Two by default: the expert FFN saturates memory
    // bandwidth at two threads, so this is what the rest of the machine can spare.
    int project_threads_ = 2;
    int sinks_pos_ = 0;
    int tail_pos_ = 0;
    KvStats stats_;
};

}  // namespace memex
