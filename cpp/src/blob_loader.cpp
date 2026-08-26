#include "memex/blob_loader.hpp"

#include <chrono>
#include <cstdio>
#include <cstdlib>

#ifdef _WIN32
#ifndef NOMINMAX
#define NOMINMAX
#endif
#ifndef WIN32_LEAN_AND_MEAN
#define WIN32_LEAN_AND_MEAN
#endif
#include <windows.h>
#else
#include <fcntl.h>
#include <sys/mman.h>
#include <unistd.h>
#endif

namespace memex {

namespace {

using Clock = std::chrono::steady_clock;

double ms_since(Clock::time_point t0) {
    return std::chrono::duration<double, std::milli>(Clock::now() - t0).count();
}

// Minimal scanner for the flat, machine-written manifest. A real JSON parser would
// be a dependency for no gain: every value is a number or a short bare word, and the
// file is produced by our own writer.
class Scan {
  public:
    explicit Scan(const std::string& text) : s_(text) {}

    // Move to the next occurrence of "\"key\":" and read what follows.
    bool next_field(const char* key, std::size_t* pos) const {
        const std::string pat = std::string("\"") + key + "\":";
        const std::size_t at = s_.find(pat, *pos);
        if (at == std::string::npos) {
            return false;
        }
        *pos = at + pat.size();
        return true;
    }

    long long read_int(std::size_t* pos) const {
        while (*pos < s_.size() && (s_[*pos] == ' ' || s_[*pos] == '"')) {
            (*pos)++;
        }
        char* end = nullptr;
        const long long v = strtoll(s_.c_str() + *pos, &end, 10);
        *pos = std::size_t(end - s_.c_str());
        return v;
    }

    // "bits" is either a number or the word "source".
    bool read_bits(std::size_t* pos, int32_t* bits) const {
        while (*pos < s_.size() && s_[*pos] == ' ') {
            (*pos)++;
        }
        if (s_.compare(*pos, 8, "\"source\"") == 0) {
            *pos += 8;
            *bits = -1;
            return true;
        }
        *bits = int32_t(read_int(pos));
        return true;
    }

    std::size_t find_from(const char* what, std::size_t pos) const {
        return s_.find(what, pos);
    }
    std::size_t size() const { return s_.size(); }
    const std::string& text() const { return s_; }

  private:
    const std::string& s_;
};

uint8_t tensor_code(const std::string& name) {
    if (name == "gate") return 1;
    if (name == "down") return 2;
    if (name == "router") return 3;   // the layer router, stored beside its experts
    return 0;
}

}  // namespace

void AlignedBuffer::alloc(std::size_t bytes) {
    free_all();
    size_ = round_up(bytes);
#ifdef _WIN32
    data_ = (uint8_t*)VirtualAlloc(nullptr, size_, MEM_COMMIT | MEM_RESERVE,
                                   PAGE_READWRITE);
#else
    void* p = nullptr;
    if (posix_memalign(&p, kSector, size_) != 0) {
        p = nullptr;
    }
    data_ = (uint8_t*)p;
#endif
    if (!data_) {
        size_ = 0;
    }
}

void AlignedBuffer::free_all() {
    if (data_) {
#ifdef _WIN32
        VirtualFree(data_, 0, MEM_RELEASE);
#else
        std::free(data_);
#endif
    }
    data_ = nullptr;
    size_ = 0;
}

BlobLoader::~BlobLoader() {
    stop_workers();
#ifdef _WIN32
    if (handle_) {
        CloseHandle((HANDLE)handle_);
    }
#else
    if (handle_) {
        close((int)(intptr_t)handle_ - 1);
    }
#endif
    handle_ = nullptr;
}

bool BlobLoader::open(const std::string& blob_path,
                      const std::string& manifest_path, std::string* err) {
    blob_path_ = blob_path;

    // Read the manifest with ordinary buffered I/O: it is small and read once.
    FILE* mf = fopen(manifest_path.c_str(), "rb");
    if (!mf) {
        if (err) *err = "манифест не открывается: " + manifest_path;
        return false;
    }
    // 64-bit seek and tell: MSVC's long is 32-bit, so the plain idiom wraps on anything past
    // 2 GB and hands back a size that is merely wrong rather than an error.
#ifdef _WIN32
    if (_fseeki64(mf, 0, SEEK_END) != 0) {
        fclose(mf);
        if (err) *err = "манифест не позиционируется: " + manifest_path;
        return false;
    }
    const long long n = _ftelli64(mf);
    const int rewind_rc = _fseeki64(mf, 0, SEEK_SET);
#else
    if (fseeko(mf, 0, SEEK_END) != 0) {
        fclose(mf);
        if (err) *err = "манифест не позиционируется: " + manifest_path;
        return false;
    }
    const long long n = (long long) ftello(mf);
    const int rewind_rc = fseeko(mf, 0, SEEK_SET);
#endif
    if (n < 0 || rewind_rc != 0) {
        fclose(mf);
        if (err) *err = "размер манифеста не определяется: " + manifest_path;
        return false;
    }
    std::string text;
    text.resize(std::size_t(n));
    if (fread(&text[0], 1, std::size_t(n), mf) != std::size_t(n)) {
        fclose(mf);
        if (err) *err = "манифест читается не полностью";
        return false;
    }
    fclose(mf);

    Scan sc(text);
    std::size_t pos = sc.find_from("\"entries\"", 0);
    if (pos == std::string::npos) {
        if (err) *err = "в манифесте нет entries";
        return false;
    }
    // Each entry is a flat object; fields always appear in writer order, so a single
    // forward pass is enough.
    while (true) {
        std::size_t p = pos;
        if (!sc.next_field("layer", &p)) {
            break;
        }
        BlobEntry e;
        e.layer = uint32_t(sc.read_int(&p));
        std::size_t q = p;
        if (!sc.next_field("tensor", &q)) break;
        while (q < sc.size() && (sc.text()[q] == ' ' || sc.text()[q] == '"')) q++;
        const std::size_t name_end = sc.text().find('"', q);
        e.tensor = tensor_code(sc.text().substr(q, name_end - q));
        q = name_end + 1;
        if (!sc.next_field("expert", &q)) break;
        e.expert = uint32_t(sc.read_int(&q));
        // The ladder step is a ggml type name (or "source" for the model's own
        // blocks); the numeric ggml type that follows is what the loader actually
        // needs, since the payload is already in that type's block layout.
        if (!sc.next_field("step", &q)) break;
        while (q < sc.size() && (sc.text()[q] == ' ' || sc.text()[q] == '"')) q++;
        const std::size_t step_end = sc.text().find('"', q);
        e.step = sc.text().substr(q, step_end - q);
        q = step_end + 1;
        if (!sc.next_field("ggml_type", &q)) break;
        e.ggml_type = int32_t(sc.read_int(&q));
        if (!sc.next_field("offset", &q)) break;
        e.offset = uint64_t(sc.read_int(&q));
        if (!sc.next_field("bytes", &q)) break;
        e.bytes = uint32_t(sc.read_int(&q));
        if (!sc.next_field("rows", &q)) break;
        e.rows = uint32_t(sc.read_int(&q));
        if (!sc.next_field("cols", &q)) break;
        e.cols = uint32_t(sc.read_int(&q));
        index_[key_of(e.layer, e.tensor, e.expert, e.ggml_type)] = entries_.size();
        entries_.push_back(e);
        pos = q;
    }
    if (entries_.empty()) {
        if (err) *err = "манифест разобран, но записей нет";
        return false;
    }

#ifdef _WIN32
    // FILE_FLAG_NO_BUFFERING is the whole point: see the header for the 37% that
    // buffered reads cost.
    HANDLE h = CreateFileA(blob_path.c_str(), GENERIC_READ, FILE_SHARE_READ, nullptr,
                           OPEN_EXISTING,
                           FILE_FLAG_NO_BUFFERING | FILE_FLAG_RANDOM_ACCESS, nullptr);
    if (h == INVALID_HANDLE_VALUE) {
        if (err) *err = "блоб не открывается: " + blob_path;
        return false;
    }
    handle_ = (void*)h;
#else
    int fd = ::open(blob_path.c_str(), O_RDONLY);
    if (fd < 0) {
        if (err) *err = "блоб не открывается: " + blob_path;
        return false;
    }
#ifdef POSIX_FADV_DONTNEED
    posix_fadvise(fd, 0, 0, POSIX_FADV_RANDOM);
#endif
    handle_ = (void*)(intptr_t)(fd + 1);
#endif
    return true;
}

const BlobEntry* BlobLoader::find(uint32_t layer, uint8_t tensor, uint32_t expert,
                                  int32_t bits) const {
    const auto it = index_.find(key_of(layer, tensor, expert, bits));
    return it == index_.end() ? nullptr : &entries_[it->second];
}

bool BlobLoader::read_sync(const BlobEntry& e, uint8_t* dst,
                           std::size_t dst_bytes) {
    const std::size_t need = AlignedBuffer::round_up(e.bytes);
    if (dst_bytes < need || (e.offset % kSector) != 0) {
        return false;
    }
    const auto t0 = Clock::now();
#ifdef _WIN32
    OVERLAPPED ov;
    memset(&ov, 0, sizeof(ov));
    ov.Offset = DWORD(e.offset & 0xFFFFFFFFull);
    ov.OffsetHigh = DWORD(e.offset >> 32);
    DWORD got = 0;
    const BOOL ok = ReadFile((HANDLE)handle_, dst, DWORD(need), &got, &ov);
    if (!ok || got < e.bytes) {
        return false;
    }
#else
    const int fd = (int)(intptr_t)handle_ - 1;
    ssize_t got = 0;
    while (std::size_t(got) < need) {
        const ssize_t r = pread(fd, dst + got, need - got, off_t(e.offset) + got);
        if (r <= 0) break;
        got += r;
    }
    if (std::size_t(got) < e.bytes) {
        return false;
    }
#endif
    std::lock_guard<std::mutex> lk(mu_);
    stats_.reads++;
    stats_.bytes += e.bytes;
    stats_.read_ms += ms_since(t0);
    return true;
}

bool BlobLoader::request(const BlobEntry& e, uint8_t* dst, std::size_t dst_bytes,
                         Done done, void* user) {
    {
        std::lock_guard<std::mutex> lk(mu_);
        if (queue_.size() >= max_queue_) {
            stats_.queue_full++;
            return false;      // never block generation on a full queue
        }
        queue_.push_back({e, dst, dst_bytes, done, user});
    }
    cv_.notify_one();
    return true;
}

void BlobLoader::start_workers(int n) {
    stop_ = false;
    for (int i = 0; i < n; ++i) {
        workers_.emplace_back([this] { worker_loop(); });
    }
}

void BlobLoader::stop_workers() {
    stop_ = true;
    cv_.notify_all();
    for (auto& t : workers_) {
        if (t.joinable()) {
            t.join();
        }
    }
    workers_.clear();
}

void BlobLoader::worker_loop() {
    while (true) {
        Request r;
        {
            std::unique_lock<std::mutex> lk(mu_);
            cv_.wait(lk, [this] { return stop_ || !queue_.empty(); });
            if (stop_ && queue_.empty()) {
                return;
            }
            // Service in ascending offset order: on a spinning disk the seek
            // dominates the transfer, so this turns a random pattern into a
            // near-sequential one, and it costs nothing on SSD.
            auto best = queue_.begin();
            for (auto it = queue_.begin(); it != queue_.end(); ++it) {
                if (it->entry.offset < best->entry.offset) {
                    best = it;
                }
            }
            r = *best;
            queue_.erase(best);
        }
        if (read_sync(r.entry, r.dst, r.dst_bytes) && r.done) {
            r.done(r.entry, r.dst, r.user);
        }
    }
}

std::size_t BlobLoader::queue_depth() const {
    std::lock_guard<std::mutex> lk(mu_);
    return queue_.size();
}

}  // namespace memex
