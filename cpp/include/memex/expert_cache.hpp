// MemeX expert paging engine — model-agnostic three-tier cache for MoE experts.
//
// Tiers:            device (VRAM)  <-  host (RAM, warm)  <-  disk (mmap, cold)
// Expert weights are read-only, so eviction is a slot release: nothing is ever
// written back, and only loads cost bandwidth.
//
// Two control loops, matching the MemeX design:
//   fast  — per-layer prefetch: the gate of layer i predicts layer i+1's
//           experts, so their loads are issued while layer i still computes.
//   slow  — every N tokens the popularity ranking (EMA) is recomputed and the
//           hottest experts are pinned to the device tier; migrations run on
//           worker threads and never block generation.
//
// Slots are fixed-size per size-class (slab allocator), so the device pool
// cannot fragment even when experts differ in size (heterogeneous MoE).
#pragma once

#include <atomic>
#include <condition_variable>
#include <cstddef>
#include <cstdint>
#include <deque>
#include <memory>
#include <mutex>
#include <string>
#include <thread>
#include <unordered_map>
#include <vector>

namespace memex {

using ExpertId = uint32_t;

struct ExpertDesc {
    ExpertId id = 0;
    uint32_t layer = 0;
    uint64_t offset = 0;  // byte offset inside the blob file
    uint32_t bytes = 0;   // expert payload size
};

// Where an expert currently lives. Device is the only tier with a slot budget
// that policy fights over; host is an inclusive warm cache; disk always has it.
enum class Tier : uint8_t { Disk = 0, Host = 1, Device = 2 };

struct CacheConfig {
    std::size_t device_bytes = 2ull << 30;  // usable VRAM for experts
    std::size_t host_bytes = 24ull << 30;   // usable RAM for the warm pool
    int loader_threads = 2;
    int rerank_every_tokens = 64;  // slow loop period (0 disables)
    double ema_alpha = 0.02;       // popularity smoothing
    double pin_fraction = 0.5;     // share of device slots reserved for pinned
    bool cpu_compute_on_miss = true;  // cheaper than a blocking transfer
    // A ranked plan must not evict what the fast loop just fetched: experts used
    // within this many recent lookups are left alone even if out of band.
    uint64_t demote_guard_uses = 1000;
    // Whether the ranked plan may touch the device tier. Measured answer: no —
    // actual routing demand (fast loop) is a much stronger signal than a
    // multi-token forecast, so planning VRAM destroys value. The plan earns its
    // keep on the RAM tier, which the fast loop cannot fill in time from disk.
    bool plan_device_tier = false;
    // One tier per migration: disk -> RAM -> VRAM and back, never skipping a
    // level. Keeps each background step short and bounded (a disk read and a bus
    // transfer never queue behind each other), at the cost of a cold expert
    // needing two ticks to reach VRAM.
    bool single_step_migration = false;
    // Loaders take work in batches sorted by blob offset instead of arrival
    // order. On a spinning disk the seek dominates the transfer, so servicing
    // requests in ascending offset turns a random pattern into a near-sequential
    // one; on SSD/NVMe it is harmless.
    int batch_loads = 8;
};

struct Stats {
    uint64_t lookups = 0;
    uint64_t device_hits = 0;
    uint64_t host_hits = 0;
    uint64_t disk_reads = 0;
    uint64_t cpu_fallbacks = 0;
    uint64_t evictions = 0;
    uint64_t prefetch_issued = 0;
    uint64_t prefetch_useful = 0;
    uint64_t placements = 0;   // times the ranked plan was applied
    uint64_t promotions = 0;   // experts moved up a tier by the plan
    uint64_t demotions = 0;    // experts moved down a tier by the plan
    double stall_ms = 0.0;      // time generation actually waited
    double load_ms = 0.0;       // total time spent moving bytes
    double hit_rate() const {
        return lookups ? double(device_hits + host_hits) / double(lookups) : 0.0;
    }
};

// Backing store for expert payloads: one blob file, memory-mapped read-only.
class ExpertBlob {
  public:
    ~ExpertBlob();
    bool open(const std::string& path, std::string* err);
    const uint8_t* data() const { return data_; }
    std::size_t size() const { return size_; }
    // Copies without touching the page cache assumptions of mmap; returns false
    // if the range is out of bounds.
    bool read(uint64_t offset, uint32_t bytes, uint8_t* dst) const;

  private:
    const uint8_t* data_ = nullptr;
    std::size_t size_ = 0;
    void* handle_ = nullptr;  // platform mapping handle
    void* file_ = nullptr;
};

class ExpertCache {
  public:
    ExpertCache(CacheConfig cfg, std::vector<ExpertDesc> experts, ExpertBlob* blob);
    ~ExpertCache();

    // Fast loop: hint that these experts are likely needed next (per-layer
    // gate prediction). Non-blocking; loads are queued for worker threads.
    void prefetch(const std::vector<ExpertId>& ids);

    // Generation path: ensure the expert is usable now. Returns the tier it was
    // served from; Tier::Disk means the caller should run it on CPU (or accept
    // that the blocking read already happened, if cpu_compute_on_miss=false).
    Tier acquire(ExpertId id);

    // Called once per generated token so the slow loop can fire on schedule.
    void end_of_token();

    const Stats& stats() const { return stats_; }
    void reset_stats() { stats_ = Stats{}; }
    // Predictors use this to spend their prefetch budget only on experts that
    // are NOT already usable: a correct guess about a resident expert buys
    // nothing, which is why raw prediction recall overstates prefetch value.
    bool is_resident(ExpertId id) const;

    // Ranked tier planning (the MemeX slow loop, explicit form): given experts
    // ordered by predicted demand over the next few tokens, slice the ranking by
    // tier capacity — the head goes to VRAM, the next band stays warm in RAM, the
    // tail belongs on disk — then migrate only the differences. Promotions are
    // queued for the loader threads; demotions just release a slot, because
    // read-only weights need no writeback. Generation never blocks on this.
    void apply_placement(const std::vector<ExpertId>& ranking);
    std::size_t device_capacity() const;  // total device slots across size classes
    std::size_t host_capacity() const;

    // Hardware auto-tuning: look at how much RAM is actually free right now and
    // claim `take_fraction` of it for the warm tier, growing or shrinking the slot
    // pools in place. Slots are allocated per slot (not as one block), so growing
    // never moves an expert that is already loaded. Returns the new host budget.
    std::size_t adapt_to_free_memory(double take_fraction = 0.6,
                                     std::size_t keep_free_bytes = 4ull << 30,
                                     std::size_t max_bytes = SIZE_MAX);
    std::size_t host_bytes() const;

    // Same idea for the device tier: whatever VRAM is left after the resident
    // weights, the KV cache and other processes becomes L1 expert cache instead
    // of sitting idle. Re-checked periodically because the KV cache grows with
    // context length, so slots must be handed back as well as claimed.
    // Returns the new device budget in bytes.
    std::size_t adapt_device_to_free_vram(double take_fraction = 0.8,
                                          std::size_t keep_free_bytes = 512ull << 20,
                                          std::size_t max_bytes = SIZE_MAX);
    std::size_t device_bytes() const;
    // Free VRAM as reported by the OS (DXGI on Windows); 0 if unavailable.
    static std::size_t query_free_vram();
    // Current tier of an expert, for tests and introspection.
    Tier tier_of(ExpertId id) const;

  private:
    struct Entry {
        Tier tier = Tier::Disk;
        uint64_t last_use = 0;
        uint32_t uses = 0;
        double popularity = 0.0;
        bool pinned = false;
        uint8_t* host_ptr = nullptr;    // valid when tier >= Host
        std::size_t host_slot = SIZE_MAX;
        std::size_t device_slot = SIZE_MAX;  // valid when tier == Device
        bool loading = false;
    };

    // Fixed-size slot pools, one per size class -> no fragmentation. Each slot is
    // its own allocation so the pool can grow or shrink at runtime without
    // invalidating pointers into slots that are currently in use.
    struct SlabPool {
        uint32_t slot_bytes = 0;
        std::vector<std::unique_ptr<uint8_t[]>> mem;
        std::vector<ExpertId> occupant;    // slot -> expert (or kInvalid)
        std::vector<std::size_t> free_list;
        void grow(std::size_t extra);
        std::size_t bytes() const { return mem.size() * slot_bytes; }
    };

    void worker_loop();
    void ensure_host(ExpertId id);                 // disk -> host
    bool promote_to_device(ExpertId id);           // host -> device
    // LFRU over unpinned slots of one pool. `device` selects which slot index the
    // victim must actually own: a host victim must not be one that still holds a
    // device copy, otherwise the device slot would be left pointing at freed
    // host memory and the same slot could be handed out twice.
    ExpertId pick_victim(SlabPool& pool, bool device) const;
    void rerank_and_pin();                         // slow loop
    SlabPool& pool_for(uint32_t bytes, bool device);
    // Grow or shrink a tier to `target` bytes. Shrinking demotes occupants one
    // level (device -> RAM, RAM -> disk); pointers of loaded experts are never
    // moved because each slot is its own allocation.
    void resize_pools(std::unordered_map<uint32_t, SlabPool>& pools,
                      std::size_t target, bool device);
    // Sum of slot bytes in a tier; caller already holds the lock.
    std::size_t pools_bytes(const std::unordered_map<uint32_t, SlabPool>& pools) const;

    CacheConfig cfg_;
    std::vector<ExpertDesc> experts_;
    ExpertBlob* blob_;
    std::vector<Entry> entries_;
    std::unordered_map<uint32_t, SlabPool> device_pools_;  // keyed by slot_bytes
    std::unordered_map<uint32_t, SlabPool> host_pools_;

    mutable std::mutex mu_;
    std::condition_variable queue_cv_;
    // (expert, promote_to_device): the ranked plan can warm the RAM tier without
    // claiming a VRAM slot, which the fast loop needs for actual demand.
    std::deque<std::pair<ExpertId, bool>> queue_;
    std::vector<std::thread> workers_;
    std::atomic<bool> stop_{false};

    uint64_t clock_ = 0;
    uint64_t tokens_ = 0;
    Stats stats_;
};

}  // namespace memex
