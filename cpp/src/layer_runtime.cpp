#include "memex/layer_runtime.hpp"

#include <algorithm>
#include <chrono>
#include <cstring>
#include <thread>

namespace memex {

namespace {

// The blob keeps one entry per (expert, tensor, step). Coarse steps are the ladder's
// lower rungs; "source" is the model's own blocks and the target of every promotion.
//
// `strict` matters more than it looks. An expert the ladder already placed at source
// precision has no coarse entry at all, and a lenient lookup used to hand back the
// source entry instead - so a "demotion" re-read the same bytes and relabelled the
// expert as coarse while it was still full precision. The runtime then reported a
// precision it did not have. Moves must therefore be strict and refuse when the
// wanted rung is absent; only the startup load may fall back, because it needs
// something to load.
const BlobEntry* find_entry(const BlobLoader& loader, uint32_t layer, int expert,
                            int slot, bool want_source, bool strict) {
    const BlobEntry* fallback = nullptr;
    for (const auto& e : loader.entries()) {
        if (e.layer != layer || int(e.expert) != expert || int(e.tensor) != slot) {
            continue;
        }
        const bool is_src = (e.step == "source");
        if (is_src == want_source) {
            return &e;
        }
        if (!fallback) {
            fallback = &e;
        }
    }
    return strict ? nullptr : fallback;
}

}  // namespace

bool LayerRuntime::read_into(const BlobEntry& e, ResidentTensor* t) {
    if (!t->buf) {
        t->buf = std::make_shared<AlignedBuffer>();
    }
    if (t->buf->size() < AlignedBuffer::round_up(e.bytes)) {
        t->buf->alloc(e.bytes);
    }
    if (!t->buf->data()) {
        return false;
    }
    if (!loader_->read_sync(e, t->buf->data(), t->buf->size())) {
        return false;
    }
    t->ggml_type = e.ggml_type;
    t->bytes = e.bytes;
    t->rows = e.rows;
    t->cols = e.cols;
    return true;
}

bool LayerRuntime::prime(std::string* err) {
    uses_.assign(n_, 0);
    ema_.assign(n_, 0.0);
    window_.assign(n_, 0);
    for (int e = 0; e < n_; ++e) {
        // Start everything coarse. Handing out full precision here by index order gave
        // it to arbitrary experts, and cache-conditional routing then steered demand
        // towards them - the cache deciding what the cache holds. Every promotion is
        // now earned from observed demand, which is what the prefill pass is for.
        const bool allow_source = false;
        for (int slot = 0; slot < 3; ++slot) {
            const BlobEntry* be = find_entry(*loader_, layer_, e, slot,
                                             /*want_source=*/allow_source,
                                             /*strict=*/false);
            if (!be) {
                if (err) {
                    *err = "нет записи для эксперта " + std::to_string(e);
                }
                return false;
            }
            if (!read_into(*be, &experts_[e].t[slot])) {
                if (err) {
                    *err = "не читается эксперт " + std::to_string(e);
                }
                return false;
            }
            if (slot == 0) {
                experts_[e].step = be->step;
            }
        }
        if (experts_[e].step == "source") {
            full_count_++;
        }
    }
    return true;
}

void LayerRuntime::on_arrival(const BlobEntry& e, uint8_t* data, void* user) {
    auto* a = (Arrival*)user;
    LayerRuntime* self = a->self;
    (void)data;   // the loader wrote straight into the destination buffer
    std::lock_guard<std::mutex> lk(self->mu_);
    ResidentExpert& ex = self->experts_[a->expert];
    // The bytes are already in the destination buffer; publishing means recording the
    // new type, and only once all three tensors have landed does the expert change
    // step. Until then every read still sees the old, coarser copy - which is what
    // makes a promotion invisible to whoever is computing.
    ex.staging[a->slot].ggml_type = e.ggml_type;
    ex.staging[a->slot].bytes = e.bytes;
    ex.staging[a->slot].rows = e.rows;
    ex.staging[a->slot].cols = e.cols;
    if (--ex.pending > 0) {
        return;
    }
    // All three tensors have landed. Only now does the expert change precision: the
    // old copy served every read until this instant, so nobody waited and nobody saw
    // a half-written tensor.
    const bool to_source = ex.target_source;
    for (int slot = 0; slot < 3; ++slot) {
        if (to_source) {
            // Retain the coarse copy rather than freeing it: that is what makes the
            // reverse move free later.
            ex.coarse[slot] = std::move(ex.t[slot]);
        }
        ex.t[slot] = std::move(ex.staging[slot]);
        ex.staging[slot] = ResidentTensor{};
    }
    if (to_source) {
        ex.has_coarse = true;
    }
    ex.step = to_source ? "source" : "coarse";
    ex.moving = false;
    self->in_flight_--;
    if (to_source) {
        self->full_count_++;
        self->stats_.promotions_done++;
    } else {
        self->full_count_--;
        self->stats_.demotions++;
    }
}

// Move one expert to the other end of the ladder. Both directions are the same
// operation: read the wanted entry into a staging buffer and swap when it is whole.
bool LayerRuntime::retarget(int expert, bool want_source) {
    ResidentExpert& ex = experts_[expert];
    if (ex.moving) {
        return false;
    }
    if ((ex.step == "source") == want_source) {
        return false;      // already there
    }
    // Demotion with a retained coarse copy needs no disk at all - swap and done.
    if (!want_source && ex.has_coarse) {
        for (int slot = 0; slot < 3; ++slot) {
            ex.t[slot] = std::move(ex.coarse[slot]);
            ex.coarse[slot] = ResidentTensor{};
        }
        ex.has_coarse = false;
        ex.step = "coarse";
        full_count_--;
        stats_.demotions++;
        stats_.instant_demotions++;
        return true;
    }
    if (in_flight_ >= max_in_flight_) {
        if (want_source) {
            stats_.promotions_dropped++;
        }
        return false;
    }
    const BlobEntry* be[3] = {nullptr, nullptr, nullptr};
    for (int slot = 0; slot < 3; ++slot) {
        be[slot] = find_entry(*loader_, layer_, expert, slot, want_source,
                              /*strict=*/true);
        if (!be[slot]) {
            return false;
        }
    }
    for (int slot = 0; slot < 3; ++slot) {
        auto nb = std::make_shared<AlignedBuffer>(be[slot]->bytes);
        if (!nb->data()) {
            for (int k = 0; k <= slot; ++k) {
                ex.staging[k] = ResidentTensor{};
            }
            return false;
        }
        ex.staging[slot].buf = std::move(nb);
    }
    ex.pending = 3;
    ex.moving = true;
    ex.target_source = want_source;
    in_flight_++;
    if (want_source) {
        stats_.promotions_started++;
    }
    for (int slot = 0; slot < 3; ++slot) {
        auto up = std::unique_ptr<Arrival>(new Arrival{this, expert, slot});
        Arrival* raw = up.get();
        arrivals_.push_back(std::move(up));
        if (!loader_->request(*be[slot], ex.staging[slot].buf->data(),
                              ex.staging[slot].buf->size(), on_arrival, raw)) {
            // Queue full: unwind rather than leave a half-issued move behind.
            ex.pending = 0;
            ex.moving = false;
            in_flight_--;
            for (int k = 0; k < 3; ++k) {
                ex.staging[k] = ResidentTensor{};
            }
            stats_.promotions_dropped++;
            return false;
        }
    }
    return true;
}

int LayerRuntime::weakest_full(int keep) const {
    int victim = -1;
    double worst = 1e300;
    for (int e = 0; e < n_; ++e) {
        if (e == keep || experts_[e].step != "source" || experts_[e].moving) {
            continue;
        }
        if (ema_[e] < worst) {
            worst = ema_[e];
            victim = e;
        }
    }
    return victim;
}

void LayerRuntime::rebalance() {
    // Wanted set: the window's heaviest experts, up to the budget. This is EPLB's
    // rebalance step with tiers in place of ranks - the assignment is recomputed from
    // accumulated load rather than from the last token.
    std::vector<int> order(n_);
    for (int e = 0; e < n_; ++e) {
        order[e] = e;
    }
    std::sort(order.begin(), order.end(), [&](int a, int b) {
        if (window_[a] != window_[b]) {
            return window_[a] > window_[b];
        }
        return ema_[a] > ema_[b];
    });
    std::vector<char> want(n_, 0);
    int wanted = 0;
    for (int i = 0; i < n_ && wanted < full_budget_; ++i) {
        if (window_[order[i]] == 0 && ema_[order[i]] <= 0.0) {
            break;      // nothing in the window asked for it
        }
        want[order[i]] = 1;
        wanted++;
    }
    // Demote first: with a retained coarse copy that is free, and it frees budget for
    // the promotions in the same pass.
    int moves = 0;
    for (int e = 0; e < n_ && moves < max_moves_; ++e) {
        if (!want[e] && experts_[e].step == "source" && !experts_[e].moving) {
            if (retarget(e, /*want_source=*/false)) {
                moves++;
            }
        }
    }
    for (int i = 0; i < n_ && moves < max_moves_; ++i) {
        const int e = order[i];
        if (want[e] && experts_[e].step != "source" && !experts_[e].moving) {
            if (retarget(e, /*want_source=*/true)) {
                moves++;
            }
        }
    }
    stats_.rebalances++;
}

void LayerRuntime::prime_from_prefill(const std::vector<std::vector<int>>& prompt_ids) {
    {
        std::lock_guard<std::mutex> lk(mu_);
        for (const auto& ids : prompt_ids) {
            for (int e : ids) {
                if (e >= 0 && e < n_) {
                    window_[e]++;
                    ema_[e] += ema_alpha_;
                }
            }
        }
        window_tokens_ = prompt_ids.size();
    }
    // Rebalance repeatedly: prefill leaves seconds of slack, and the whole point is to
    // arrive at the first generated token with memory already arranged.
    for (int round = 0; round < 64; ++round) {
        {
            std::lock_guard<std::mutex> lk(mu_);
            rebalance();
        }
        // Let the queued reads land before deciding again.
        while (loader_->queue_depth() > 0) {
            std::this_thread::sleep_for(std::chrono::milliseconds(2));
        }
        std::this_thread::sleep_for(std::chrono::milliseconds(2));
        std::lock_guard<std::mutex> lk(mu_);
        if (full_count_ >= full_budget_ || in_flight_ == 0) {
            bool done = true;
            for (int e = 0; e < n_ && done; ++e) {
                if (experts_[e].moving) {
                    done = false;
                }
            }
            if (done && full_count_ >= full_budget_) {
                break;
            }
        }
    }
}

int LayerRuntime::on_token(const std::vector<int>& ids) {
    std::lock_guard<std::mutex> lk(mu_);
    stats_.tokens++;
    for (double& v : ema_) {
        v *= (1.0 - ema_alpha_);
    }
    int at_source = 0;
    for (int e : ids) {
        if (e < 0 || e >= n_) {
            continue;
        }
        uses_[e]++;
        ema_[e] += ema_alpha_;
        window_[e]++;
        stats_.expert_uses++;
        if (experts_[e].step == "source") {
            at_source++;
            stats_.uses_at_source++;
        }
    }
    // Decide on a cadence, not per token. Below the budget a wanted expert is taken
    // straight away, since nothing has to be displaced for it; above the budget the
    // choice waits for the window, which is what stopped the thrashing.
    for (int e : ids) {
        if (e < 0 || e >= n_) {
            continue;
        }
        if (experts_[e].step != "source" && !experts_[e].moving &&
            full_count_ + in_flight_ < full_budget_) {
            retarget(e, /*want_source=*/true);
        }
    }
    if (++window_tokens_ % rebalance_every_ == 0) {
        rebalance();
        // Age the window instead of clearing it, so a rebalance sees the recent past
        // rather than only the last interval.
        if (window_tokens_ >= window_size_) {
            for (auto& v : window_) {
                v = v / 2;
            }
        }
    }
    // Completed moves leave bookkeeping behind; reclaim it here, where the lock is
    // already held, instead of letting the list grow for the whole run.
    if (arrivals_.size() > 4096) {
        std::vector<std::unique_ptr<Arrival>> keep;
        for (auto& a : arrivals_) {
            if (a && experts_[a->expert].moving) {
                keep.push_back(std::move(a));
            }
        }
        arrivals_.swap(keep);
    }
    return at_source;
}

LayerRuntime::Held LayerRuntime::hold(int e) const {
    Held out;
    if (e < 0 || e >= n_) {
        return out;
    }
    std::lock_guard<std::mutex> lk(mu_);
    const ResidentExpert& ex = experts_[e];
    for (int slot = 0; slot < 3; ++slot) {
        if (!ex.t[slot].buf) {
            return out;
        }
        out.buf[slot] = ex.t[slot].buf;          // takes a reference, pinning the bytes
        out.ggml_type[slot] = ex.t[slot].ggml_type;
    }
    out.ok = true;
    return out;
}

std::size_t LayerRuntime::resident_bytes() const {
    std::lock_guard<std::mutex> lk(mu_);
    std::size_t n = 0;
    for (const auto& ex : experts_) {
        for (int slot = 0; slot < 3; ++slot) {
            if (ex.t[slot].buf) {
                n += ex.t[slot].buf->size();
            }
        }
    }
    return n;
}

}  // namespace memex
