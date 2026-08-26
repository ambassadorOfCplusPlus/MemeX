#include "memex/expert_cache.hpp"

#include <algorithm>
#include <chrono>
#include <cstring>
#include <limits>

#ifdef _WIN32
#define WIN32_LEAN_AND_MEAN
#define NOMINMAX  // windows.h min/max macros break std::numeric_limits<>::max()
#include <windows.h>
#include <dxgi1_4.h>
#pragma comment(lib, "dxgi.lib")
#else
#include <fcntl.h>
#include <sys/mman.h>
#include <sys/stat.h>
#include <unistd.h>
#endif

namespace memex {
namespace {

constexpr ExpertId kInvalid = std::numeric_limits<ExpertId>::max();

double now_ms() {
    using clock = std::chrono::steady_clock;
    return std::chrono::duration<double, std::milli>(
               clock::now().time_since_epoch())
        .count();
}

// Round expert sizes into a few classes so heterogeneous experts still map onto
// fixed-size slots (slab allocation). Power-of-two-ish buckets keep waste < 25%.
uint32_t size_class(uint32_t bytes) {
    uint32_t cls = 64u * 1024u;
    while (cls < bytes) cls += cls / 4;  // 1.25x growth
    return cls;
}

}  // namespace

ExpertBlob::~ExpertBlob() {
#ifdef _WIN32
    if (data_) UnmapViewOfFile(data_);
    if (handle_) CloseHandle(handle_);
    if (file_ && file_ != INVALID_HANDLE_VALUE) CloseHandle(file_);
#else
    if (data_) munmap(const_cast<uint8_t*>(data_), size_);
#endif
}

bool ExpertBlob::open(const std::string& path, std::string* err) {
#ifdef _WIN32
    HANDLE f = CreateFileA(path.c_str(), GENERIC_READ, FILE_SHARE_READ, nullptr,
                           OPEN_EXISTING, FILE_ATTRIBUTE_NORMAL, nullptr);
    if (f == INVALID_HANDLE_VALUE) {
        if (err) *err = "cannot open blob: " + path;
        return false;
    }
    LARGE_INTEGER sz;
    if (!GetFileSizeEx(f, &sz)) {
        CloseHandle(f);
        if (err) *err = "cannot size blob";
        return false;
    }
    HANDLE m = CreateFileMappingA(f, nullptr, PAGE_READONLY, 0, 0, nullptr);
    if (!m) {
        CloseHandle(f);
        if (err) *err = "cannot map blob";
        return false;
    }
    void* p = MapViewOfFile(m, FILE_MAP_READ, 0, 0, 0);
    if (!p) {
        CloseHandle(m);
        CloseHandle(f);
        if (err) *err = "cannot view blob";
        return false;
    }
    file_ = f;
    handle_ = m;
    data_ = static_cast<const uint8_t*>(p);
    size_ = static_cast<std::size_t>(sz.QuadPart);
#else
    int fd = ::open(path.c_str(), O_RDONLY);
    if (fd < 0) {
        if (err) *err = "cannot open blob: " + path;
        return false;
    }
    struct stat st {};
    if (fstat(fd, &st) != 0) {
        ::close(fd);
        if (err) *err = "cannot size blob";
        return false;
    }
    void* p = mmap(nullptr, st.st_size, PROT_READ, MAP_PRIVATE, fd, 0);
    ::close(fd);
    if (p == MAP_FAILED) {
        if (err) *err = "cannot map blob";
        return false;
    }
    data_ = static_cast<const uint8_t*>(p);
    size_ = static_cast<std::size_t>(st.st_size);
#endif
    return true;
}

bool ExpertBlob::read(uint64_t offset, uint32_t bytes, uint8_t* dst) const {
    if (!data_ || offset + bytes > size_) return false;
    std::memcpy(dst, data_ + offset, bytes);
    return true;
}

void ExpertCache::SlabPool::grow(std::size_t extra) {
    for (std::size_t i = 0; i < extra; ++i) {
        mem.push_back(std::make_unique<uint8_t[]>(slot_bytes));
        occupant.push_back(kInvalid);
        free_list.push_back(mem.size() - 1);
    }
}

ExpertCache::ExpertCache(CacheConfig cfg, std::vector<ExpertDesc> experts,
                         ExpertBlob* blob)
    : cfg_(cfg), experts_(std::move(experts)), blob_(blob) {
    entries_.resize(experts_.size());

    // Build slot pools sized to the configured budgets, split across the size
    // classes present in the model (proportional to how many experts use each).
    std::unordered_map<uint32_t, std::size_t> class_counts;
    for (const auto& e : experts_) class_counts[size_class(e.bytes)]++;
    std::size_t total = experts_.empty() ? 1 : experts_.size();

    auto build = [&](std::unordered_map<uint32_t, SlabPool>& pools,
                     std::size_t budget) {
        for (const auto& [cls, count] : class_counts) {
            std::size_t share = static_cast<std::size_t>(
                double(budget) * double(count) / double(total));
            std::size_t slots = cls ? share / cls : 0;
            SlabPool pool;
            pool.slot_bytes = cls;
            pool.grow(slots);
            pools.emplace(cls, std::move(pool));
        }
    };
    build(device_pools_, cfg_.device_bytes);
    build(host_pools_, cfg_.host_bytes);

    for (int i = 0; i < std::max(1, cfg_.loader_threads); ++i)
        workers_.emplace_back([this] { worker_loop(); });
}

ExpertCache::~ExpertCache() {
    stop_ = true;
    queue_cv_.notify_all();
    for (auto& t : workers_)
        if (t.joinable()) t.join();
}

ExpertCache::SlabPool& ExpertCache::pool_for(uint32_t bytes, bool device) {
    auto& pools = device ? device_pools_ : host_pools_;
    return pools.at(size_class(bytes));
}

bool ExpertCache::is_resident(ExpertId id) const {
    std::lock_guard<std::mutex> lk(mu_);
    if (id >= entries_.size()) return false;
    const Entry& e = entries_[id];
    return e.tier == Tier::Device || e.loading;
}

Tier ExpertCache::tier_of(ExpertId id) const {
    std::lock_guard<std::mutex> lk(mu_);
    return id < entries_.size() ? entries_[id].tier : Tier::Disk;
}

void ExpertCache::prefetch(const std::vector<ExpertId>& ids) {
    std::lock_guard<std::mutex> lk(mu_);
    for (ExpertId id : ids) {
        if (id >= entries_.size()) continue;
        Entry& e = entries_[id];
        if (e.tier == Tier::Device || e.loading) continue;
        e.loading = true;
        queue_.push_back({id, true});
        stats_.prefetch_issued++;
    }
    queue_cv_.notify_all();
}

void ExpertCache::worker_loop() {
    while (!stop_) {
        std::vector<std::pair<ExpertId, bool>> batch;
        {
            std::unique_lock<std::mutex> lk(mu_);
            queue_cv_.wait(lk, [this] { return stop_ || !queue_.empty(); });
            if (stop_) return;
            const int take = std::max(1, cfg_.batch_loads);
            while (!queue_.empty() && int(batch.size()) < take) {
                batch.push_back(queue_.front());
                queue_.pop_front();
            }
        }
        // Ascending blob offset: the disk head sweeps forward instead of seeking
        // back and forth between unrelated experts.
        std::sort(batch.begin(), batch.end(),
                  [this](const auto& a, const auto& b) {
                      return experts_[a.first].offset < experts_[b.first].offset;
                  });

        double t0 = now_ms();
        for (const auto& [id, to_device] : batch) {
            bool was_on_disk;
            {
                std::lock_guard<std::mutex> lk(mu_);
                was_on_disk = entries_[id].tier == Tier::Disk;
            }
            ensure_host(id);
            // With single-step migration a disk resident only reaches RAM this
            // round; the next prefetch or plan tick lifts it into VRAM.
            if (to_device && !(cfg_.single_step_migration && was_on_disk))
                promote_to_device(id);
            std::lock_guard<std::mutex> lk(mu_);
            entries_[id].loading = false;
        }
        {
            std::lock_guard<std::mutex> lk(mu_);
            stats_.load_ms += now_ms() - t0;
        }
    }
}

void ExpertCache::ensure_host(ExpertId id) {
    const ExpertDesc& d = experts_[id];
    uint8_t* dst = nullptr;
    {
        std::lock_guard<std::mutex> lk(mu_);
        if (entries_[id].tier >= Tier::Host) return;
        SlabPool& pool = pool_for(d.bytes, /*device=*/false);
        if (pool.free_list.empty()) {
            ExpertId victim = pick_victim(pool, /*device=*/false);
            if (victim == kInvalid) return;  // everything pinned; stay on disk
            Entry& ve = entries_[victim];
            std::size_t slot = ve.host_slot;
            if (slot == SIZE_MAX) return;
            ve.host_ptr = nullptr;
            ve.host_slot = SIZE_MAX;
            ve.tier = Tier::Disk;
            pool.occupant[slot] = kInvalid;
            pool.free_list.push_back(slot);
            stats_.evictions++;
        }
        std::size_t slot = pool.free_list.back();
        pool.free_list.pop_back();
        pool.occupant[slot] = id;
        dst = pool.mem[slot].get();
        entries_[id].host_ptr = dst;
        entries_[id].host_slot = slot;
    }
    // The actual disk read happens outside the lock: it is the slow part.
    if (dst && blob_ && blob_->read(d.offset, d.bytes, dst)) {
        std::lock_guard<std::mutex> lk(mu_);
        entries_[id].tier = Tier::Host;
        stats_.disk_reads++;
    }
}

bool ExpertCache::promote_to_device(ExpertId id) {
    const ExpertDesc& d = experts_[id];
    std::lock_guard<std::mutex> lk(mu_);
    Entry& e = entries_[id];
    if (e.tier == Tier::Device) return true;
    if (e.tier != Tier::Host) return false;
    SlabPool& pool = pool_for(d.bytes, /*device=*/true);
    if (pool.occupant.empty()) return false;
    if (pool.free_list.empty()) {
        ExpertId victim = pick_victim(pool, /*device=*/true);
        if (victim == kInvalid) return false;
        Entry& ve = entries_[victim];
        if (ve.device_slot >= pool.occupant.size()) return false;
        pool.occupant[ve.device_slot] = kInvalid;
        pool.free_list.push_back(ve.device_slot);
        ve.device_slot = SIZE_MAX;
        // Read-only weights: dropping the device copy needs no writeback, the
        // host tier still holds it.
        ve.tier = ve.host_ptr ? Tier::Host : Tier::Disk;
        stats_.evictions++;
    }
    std::size_t slot = pool.free_list.back();
    pool.free_list.pop_back();
    pool.occupant[slot] = id;
    e.device_slot = slot;
    // Stand-in for the host->device transfer; a CUDA/HIP backend replaces this
    // memcpy with an async copy on a dedicated stream.
    std::memcpy(pool.mem[slot].get(), e.host_ptr, d.bytes);
    e.tier = Tier::Device;
    return true;
}

ExpertId ExpertCache::pick_victim(SlabPool& pool, bool device) const {
    // LFRU: frequency discounted by recency — the policy that survived the
    // trace-replay critique (arXiv:2608.07911) better than plain LRU/LFU.
    ExpertId best = kInvalid;
    double best_score = std::numeric_limits<double>::max();
    for (ExpertId occ : pool.occupant) {
        if (occ == kInvalid) continue;
        const Entry& e = entries_[occ];
        if (e.pinned || e.loading) continue;
        // The victim must own a slot in THIS pool, and a device-resident expert
        // may never lose its host copy (the device copy was made from it).
        if (device) {
            if (e.device_slot >= pool.occupant.size()) continue;
        } else {
            if (e.tier == Tier::Device || e.host_slot >= pool.occupant.size())
                continue;
        }
        double age = double(clock_ - e.last_use) + 1.0;
        double score = double(e.uses) / age;
        if (score < best_score) {
            best_score = score;
            best = occ;
        }
    }
    return best;
}

Tier ExpertCache::acquire(ExpertId id) {
    if (id >= entries_.size()) return Tier::Disk;
    {
        std::lock_guard<std::mutex> lk(mu_);
        Entry& e = entries_[id];
        clock_++;
        e.last_use = clock_;
        e.uses++;
        e.popularity += cfg_.ema_alpha * (1.0 - e.popularity);
        stats_.lookups++;
        if (e.tier == Tier::Device) {
            stats_.device_hits++;
            if (e.loading) stats_.prefetch_useful++;
            return Tier::Device;
        }
        if (e.tier == Tier::Host) {
            stats_.host_hits++;
            return Tier::Host;
        }
        if (cfg_.cpu_compute_on_miss) {
            // Moving a few KB of activations to the CPU beats dragging tens of
            // MB of weights across a slow bus; queue the load for next time.
            stats_.cpu_fallbacks++;
            if (!e.loading) {
                e.loading = true;
                queue_.push_back({id, true});
            }
            queue_cv_.notify_all();
            return Tier::Disk;
        }
    }
    double t0 = now_ms();
    ensure_host(id);
    std::lock_guard<std::mutex> lk(mu_);
    stats_.stall_ms += now_ms() - t0;
    entries_[id].loading = false;
    return entries_[id].tier;
}

void ExpertCache::rerank_and_pin() {
    // Slow loop: decay popularity, then pin the hottest experts of each size
    // class up to pin_fraction of the device slots.
    for (auto& e : entries_) {
        e.popularity *= (1.0 - cfg_.ema_alpha);
        e.pinned = false;
    }
    for (auto& [cls, pool] : device_pools_) {
        std::size_t budget = static_cast<std::size_t>(
            double(pool.occupant.size()) * cfg_.pin_fraction);
        if (!budget) continue;
        std::vector<ExpertId> ids;
        ids.reserve(experts_.size());
        for (ExpertId id = 0; id < experts_.size(); ++id)
            if (size_class(experts_[id].bytes) == cls) ids.push_back(id);
        std::partial_sort(
            ids.begin(), ids.begin() + std::min(budget, ids.size()), ids.end(),
            [this](ExpertId a, ExpertId b) {
                return entries_[a].popularity > entries_[b].popularity;
            });
        for (std::size_t i = 0; i < std::min(budget, ids.size()); ++i) {
            entries_[ids[i]].pinned = true;
            if (entries_[ids[i]].tier != Tier::Device && !entries_[ids[i]].loading) {
                entries_[ids[i]].loading = true;
                queue_.push_back({ids[i], true});
            }
        }
    }
    queue_cv_.notify_all();
}

namespace {
std::size_t free_physical_memory() {
#ifdef _WIN32
    MEMORYSTATUSEX st{};
    st.dwLength = sizeof(st);
    if (GlobalMemoryStatusEx(&st)) return static_cast<std::size_t>(st.ullAvailPhys);
    return 0;
#else
    long pages = sysconf(_SC_AVPHYS_PAGES);
    long page = sysconf(_SC_PAGE_SIZE);
    return (pages > 0 && page > 0) ? std::size_t(pages) * std::size_t(page) : 0;
#endif
}
}  // namespace

std::size_t ExpertCache::host_bytes() const {
    std::lock_guard<std::mutex> lk(mu_);
    std::size_t n = 0;
    for (const auto& [cls, pool] : host_pools_) n += pool.bytes();
    return n;
}

std::size_t ExpertCache::pools_bytes(
    const std::unordered_map<uint32_t, SlabPool>& pools) const {
    std::size_t n = 0;
    for (const auto& [cls, pool] : pools) n += pool.bytes();
    return n;
}

std::size_t ExpertCache::query_free_vram() {
#ifdef _WIN32
    // DXGI works with any vendor's GPU and needs no vendor SDK, which matters on
    // a machine where CUDA does not exist.
    IDXGIFactory4* factory = nullptr;
    if (FAILED(CreateDXGIFactory1(__uuidof(IDXGIFactory4), (void**)&factory)))
        return 0;
    // Pick the real discrete GPU (largest dedicated VRAM), not whichever adapter
    // reports the biggest budget — software/virtual adapters advertise shared
    // system memory and would wildly overstate what is available.
    std::size_t best_free = 0, best_dedicated = 0;
    for (UINT i = 0;; ++i) {
        IDXGIAdapter1* ad1 = nullptr;
        if (factory->EnumAdapters1(i, &ad1) == DXGI_ERROR_NOT_FOUND) break;
        DXGI_ADAPTER_DESC1 desc{};
        if (SUCCEEDED(ad1->GetDesc1(&desc)) &&
            !(desc.Flags & DXGI_ADAPTER_FLAG_SOFTWARE) &&
            desc.DedicatedVideoMemory > best_dedicated) {
            IDXGIAdapter3* ad3 = nullptr;
            if (SUCCEEDED(ad1->QueryInterface(__uuidof(IDXGIAdapter3), (void**)&ad3))) {
                DXGI_QUERY_VIDEO_MEMORY_INFO info{};
                if (SUCCEEDED(ad3->QueryVideoMemoryInfo(
                        0, DXGI_MEMORY_SEGMENT_GROUP_LOCAL, &info))) {
                    const std::size_t dedicated =
                        static_cast<std::size_t>(desc.DedicatedVideoMemory);
                    std::size_t budget = static_cast<std::size_t>(info.Budget);
                    if (budget > dedicated) budget = dedicated;  // ignore spillover
                    const std::size_t used =
                        static_cast<std::size_t>(info.CurrentUsage);
                    best_free = budget > used ? budget - used : 0;
                    best_dedicated = dedicated;
                }
                ad3->Release();
            }
        }
        ad1->Release();
    }
    factory->Release();
    return best_free;
#else
    return 0;
#endif
}

std::size_t ExpertCache::device_bytes() const {
    std::lock_guard<std::mutex> lk(mu_);
    std::size_t n = 0;
    for (const auto& [cls, pool] : device_pools_) n += pool.bytes();
    return n;
}

void ExpertCache::resize_pools(std::unordered_map<uint32_t, SlabPool>& pools,
                               std::size_t target, bool device) {
    std::size_t current = 0;
    for (const auto& [cls, pool] : pools) current += pool.bytes();
    for (auto& [cls, pool] : pools) {
        const double frac = current ? double(pool.bytes()) / double(current)
                                    : 1.0 / double(pools.size());
        const std::size_t want = static_cast<std::size_t>(double(target) * frac) / cls;
        if (want > pool.mem.size()) {
            pool.grow(want - pool.mem.size());
            continue;
        }
        std::size_t to_drop = pool.mem.size() - want;
        while (to_drop-- && !pool.mem.empty()) {
            const std::size_t idx = pool.mem.size() - 1;
            const ExpertId occ = pool.occupant[idx];
            if (occ != kInvalid) {
                Entry& e = entries_[occ];
                if (e.loading) break;             // in flight: stop shrinking here
                if (device) {
                    if (e.device_slot != idx) break;
                    e.device_slot = SIZE_MAX;
                    e.tier = e.host_ptr ? Tier::Host : Tier::Disk;  // one step down
                } else {
                    if (e.tier == Tier::Device || e.host_slot != idx) break;
                    e.host_ptr = nullptr;
                    e.host_slot = SIZE_MAX;
                    e.tier = Tier::Disk;
                }
                stats_.demotions++;
            }
            pool.mem.pop_back();
            pool.occupant.pop_back();
            pool.free_list.erase(
                std::remove(pool.free_list.begin(), pool.free_list.end(), idx),
                pool.free_list.end());
        }
    }
}

std::size_t ExpertCache::adapt_device_to_free_vram(double take_fraction,
                                                   std::size_t keep_free_bytes,
                                                   std::size_t max_bytes) {
    std::lock_guard<std::mutex> lk(mu_);
    const std::size_t avail = query_free_vram();
    if (!avail) return pools_bytes(device_pools_);
    std::size_t current = pools_bytes(device_pools_);
    const std::size_t headroom = avail > keep_free_bytes ? avail - keep_free_bytes : 0;
    std::size_t target = current + static_cast<std::size_t>(double(headroom) *
                                                           take_fraction);
    if (avail < keep_free_bytes) {
        // VRAM got tighter (KV cache grew, another app started): give slots back.
        const std::size_t deficit = keep_free_bytes - avail;
        target = current > deficit ? current - deficit : 0;
    }
    resize_pools(device_pools_, std::min(target, max_bytes), /*device=*/true);
    return pools_bytes(device_pools_);
}

std::size_t ExpertCache::adapt_to_free_memory(double take_fraction,
                                              std::size_t keep_free_bytes,
                                              std::size_t max_bytes) {
    std::lock_guard<std::mutex> lk(mu_);
    const std::size_t avail = free_physical_memory();
    std::size_t current = 0;
    for (const auto& [cls, pool] : host_pools_) current += pool.bytes();

    // Target = what we hold now plus a slice of what is genuinely free, always
    // leaving `keep_free_bytes` for the rest of the system. If memory got tight
    // (another program started), the target shrinks and slots are handed back.
    std::size_t headroom = avail > keep_free_bytes ? avail - keep_free_bytes : 0;
    std::size_t target = current + static_cast<std::size_t>(double(headroom) *
                                                            take_fraction);
    if (avail < keep_free_bytes) {
        const std::size_t deficit = keep_free_bytes - avail;
        target = current > deficit ? current - deficit : 0;
    }

    resize_pools(host_pools_, std::min(target, max_bytes), /*device=*/false);
    return pools_bytes(host_pools_);
}

std::size_t ExpertCache::device_capacity() const {
    std::lock_guard<std::mutex> lk(mu_);
    std::size_t n = 0;
    for (const auto& [cls, pool] : device_pools_) n += pool.occupant.size();
    return n;
}

std::size_t ExpertCache::host_capacity() const {
    std::lock_guard<std::mutex> lk(mu_);
    std::size_t n = 0;
    for (const auto& [cls, pool] : host_pools_) n += pool.occupant.size();
    return n;
}

void ExpertCache::apply_placement(const std::vector<ExpertId>& ranking) {
    std::lock_guard<std::mutex> lk(mu_);
    stats_.placements++;

    // Slice the ranking into tier bands by capacity: band 2 = VRAM, band 1 = RAM,
    // band 0 (everything else) = disk.
    std::size_t dev_cap = 0, host_cap = 0;
    for (const auto& [cls, pool] : device_pools_) dev_cap += pool.occupant.size();
    for (const auto& [cls, pool] : host_pools_) host_cap += pool.occupant.size();

    std::unordered_map<ExpertId, uint8_t> band;
    band.reserve(ranking.size() * 2);
    for (std::size_t i = 0; i < ranking.size(); ++i) {
        uint8_t b = 0;
        if (i < dev_cap) b = 2;
        else if (i < dev_cap + host_cap) b = 1;
        band[ranking[i]] = b;
    }

    auto target_of = [&](ExpertId id) -> uint8_t {
        auto it = band.find(id);
        return it == band.end() ? 0 : it->second;
    };

    // Demote what fell out of its band: release the slot, keep the lower copy.
    if (cfg_.plan_device_tier) for (auto& [cls, pool] : device_pools_) {
        for (std::size_t slot = 0; slot < pool.occupant.size(); ++slot) {
            ExpertId id = pool.occupant[slot];
            if (id == kInvalid) continue;
            if (target_of(id) >= 2) continue;
            Entry& e = entries_[id];
            if (e.loading) continue;
            if (clock_ - e.last_use < cfg_.demote_guard_uses) continue;
            pool.occupant[slot] = kInvalid;
            pool.free_list.push_back(slot);
            e.device_slot = SIZE_MAX;
            e.pinned = false;
            e.tier = e.host_ptr ? Tier::Host : Tier::Disk;
            stats_.demotions++;
        }
    }
    for (auto& [cls, pool] : host_pools_) {
        for (std::size_t slot = 0; slot < pool.occupant.size(); ++slot) {
            ExpertId id = pool.occupant[slot];
            if (id == kInvalid) continue;
            if (target_of(id) >= 1) continue;
            Entry& e = entries_[id];
            if (e.loading || e.tier == Tier::Device) continue;
            if (clock_ - e.last_use < cfg_.demote_guard_uses) continue;
            pool.occupant[slot] = kInvalid;
            pool.free_list.push_back(slot);
            e.host_ptr = nullptr;
            e.host_slot = SIZE_MAX;
            e.tier = Tier::Disk;
            stats_.demotions++;
        }
    }

    // Promote the head of the ranking, pinning it so LFRU cannot undo the plan
    // before it pays off. Loads run on the worker threads.
    // Pin only the head of the device band: pinning the whole band would leave
    // the fast loop no slots to work with, and a plan that blocks prefetch costs
    // more than it saves.
    const std::size_t pin_upto =
        static_cast<std::size_t>(double(dev_cap) * cfg_.pin_fraction);
    if (cfg_.plan_device_tier) for (std::size_t i = 0; i < ranking.size() && i < dev_cap; ++i) {
        ExpertId id = ranking[i];
        if (id >= entries_.size()) continue;
        Entry& e = entries_[id];
        e.pinned = i < pin_upto;
        if (e.tier != Tier::Device && !e.loading) {
            e.loading = true;
            queue_.push_back({id, true});
            stats_.promotions++;
        }
    }

    // Fill idle VRAM slots without evicting anything. Planning VRAM is harmful
    // (demand beats forecast), but leaving capacity empty is pure waste: if slots
    // are free, the hottest RAM residents may as well sit in L1. Purely additive,
    // so it cannot displace what the fast loop just fetched.
    if (!cfg_.plan_device_tier) {
        std::size_t free_slots = 0;
        for (const auto& [cls, pool] : device_pools_) free_slots += pool.free_list.size();
        for (std::size_t i = 0; i < ranking.size() && free_slots > 0; ++i) {
            ExpertId id = ranking[i];
            if (id >= entries_.size()) continue;
            Entry& e = entries_[id];
            if (e.tier != Tier::Host || e.loading) continue;
            e.loading = true;
            queue_.push_back({id, true});
            stats_.promotions++;
            --free_slots;
        }
    }

    // Warm the RAM band from disk: this is where a multi-token forecast pays off,
    // because a cold expert cannot be fetched from disk inside one layer of
    // compute, while a RAM-resident one only needs a bus transfer.
    const std::size_t host_band_end = dev_cap + host_cap;
    for (std::size_t i = dev_cap; i < ranking.size() && i < host_band_end; ++i) {
        ExpertId id = ranking[i];
        if (id >= entries_.size()) continue;
        Entry& e = entries_[id];
        if (e.tier == Tier::Disk && !e.loading) {
            e.loading = true;
            queue_.push_back({id, false});  // RAM only, do not claim a VRAM slot
            stats_.promotions++;
        }
    }
    queue_cv_.notify_all();
}

void ExpertCache::end_of_token() {
    std::lock_guard<std::mutex> lk(mu_);
    tokens_++;
    if (cfg_.rerank_every_tokens > 0 &&
        tokens_ % static_cast<uint64_t>(cfg_.rerank_every_tokens) == 0) {
        rerank_and_pin();
    }
}

}  // namespace memex
