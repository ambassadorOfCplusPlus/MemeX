// Loader for the MemeX expert blob: reads expert payloads without disturbing
// generation, and hands out slots grouped by bit width.
//
// Everything unusual here is forced by a measurement.
//
//   * Reads bypass the file cache. A background loader that pulled experts through
//     the cache evicted the model's own pages and cost 37% of generation speed
//     (8.04 -> 5.05 tok/s); with unbuffered reads the same traffic cost nothing
//     (8.33 tok/s). On Windows that means FILE_FLAG_NO_BUFFERING, which is why the
//     blob writer aligns every payload to 4096 bytes.
//   * Slots come in size classes by bit width. Experts are stored at 3-7 bits plus a
//     verbatim source copy, so one pool per size cannot work; a promotion allocates
//     from the larger class, fills it, and only then releases the smaller one, which
//     is what keeps an expert readable at every instant.
//   * Loading happens on worker threads with a bounded queue. Measured rates are
//     177.5 experts/s from the SATA SSD and 47.5/s from the spinning disk, against a
//     ~113 ms token, so a token affords one or two arrivals - the queue must be
//     short or it plans work it cannot deliver.
#pragma once

#include <atomic>
#include <condition_variable>
#include <cstdint>
#include <cstring>
#include <deque>
#include <memory>
#include <mutex>
#include <string>
#include <thread>
#include <unordered_map>
#include <vector>

namespace memex {

constexpr std::size_t kSector = 4096;

// One stored copy of one expert tensor.
struct BlobEntry {
    uint32_t layer = 0;
    uint8_t tensor = 0;     // 0 up, 1 gate, 2 down
    uint32_t expert = 0;
    std::string step;       // ladder step: a ggml type name, or "source"
    int32_t ggml_type = -1; // the payload is already in this type's block layout
    uint64_t offset = 0;    // sector-aligned
    uint32_t bytes = 0;
    uint32_t rows = 0;
    uint32_t cols = 0;
};

struct LoaderStats {
    uint64_t reads = 0;
    uint64_t bytes = 0;
    uint64_t queue_full = 0;    // times a request was dropped for lack of room
    double read_ms = 0.0;
};

// Aligned buffer: unbuffered reads require the destination address, the file offset
// and the length all to be sector multiples.
class AlignedBuffer {
  public:
    AlignedBuffer() = default;
    explicit AlignedBuffer(std::size_t bytes) { alloc(bytes); }
    ~AlignedBuffer() { free_all(); }
    AlignedBuffer(AlignedBuffer&& o) noexcept { *this = std::move(o); }
    AlignedBuffer& operator=(AlignedBuffer&& o) noexcept {
        if (this != &o) {
            free_all();
            data_ = o.data_;
            size_ = o.size_;
            o.data_ = nullptr;
            o.size_ = 0;
        }
        return *this;
    }
    AlignedBuffer(const AlignedBuffer&) = delete;
    AlignedBuffer& operator=(const AlignedBuffer&) = delete;

    void alloc(std::size_t bytes);
    void free_all();
    uint8_t* data() const { return data_; }
    std::size_t size() const { return size_; }
    static std::size_t round_up(std::size_t n) {
        return (n + kSector - 1) / kSector * kSector;
    }

  private:
    uint8_t* data_ = nullptr;
    std::size_t size_ = 0;
};

class BlobLoader {
  public:
    BlobLoader() = default;
    ~BlobLoader();

    // `manifest_path` is the JSON written by memex/build_expert_blob.py. Parsing is
    // deliberately minimal - the file is machine-written and flat.
    bool open(const std::string& blob_path, const std::string& manifest_path,
              std::string* err);
    void start_workers(int n);
    void stop_workers();

    // Blocking read of one entry into `dst`, which must be sector-aligned and large
    // enough for the rounded-up length. Used by the foreground path and by tests.
    bool read_sync(const BlobEntry& e, uint8_t* dst, std::size_t dst_bytes);

    // Queue a read; `done` runs on the worker thread once the bytes have landed. The
    // queue is bounded, and a full queue drops the request rather than blocking the
    // caller - generation must never wait on the loader.
    using Done = void (*)(const BlobEntry&, uint8_t*, void*);
    bool request(const BlobEntry& e, uint8_t* dst, std::size_t dst_bytes,
                 Done done, void* user);

    const std::vector<BlobEntry>& entries() const { return entries_; }
    // index by (layer, tensor, expert, ggml type)
    const BlobEntry* find(uint32_t layer, uint8_t tensor, uint32_t expert,
                          int32_t ggml_type) const;
    const LoaderStats& stats() const { return stats_; }
    std::size_t queue_depth() const;

  private:
    struct Request {
        BlobEntry entry;
        uint8_t* dst;
        std::size_t dst_bytes;
        Done done;
        void* user;
    };

    void worker_loop();
    static uint64_t key_of(uint32_t layer, uint8_t tensor, uint32_t expert,
                           int32_t ggml_type) {
        // ggml type numbers reach into the hundreds in this fork, so give them 9 bits
        const uint64_t b = uint64_t(ggml_type < 0 ? 0 : ggml_type) & 0x1FF;
        return (uint64_t(layer) << 45) | (uint64_t(tensor) << 41) |
               (uint64_t(expert) << 9) | b;
    }

    void* handle_ = nullptr;         // platform file handle, opened unbuffered
    std::string blob_path_;
    std::vector<BlobEntry> entries_;
    std::unordered_map<uint64_t, std::size_t> index_;

    mutable std::mutex mu_;
    std::condition_variable cv_;
    std::deque<Request> queue_;
    std::vector<std::thread> workers_;
    std::atomic<bool> stop_{false};
    std::size_t max_queue_ = 32;
    LoaderStats stats_;
};

}  // namespace memex
