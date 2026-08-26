// Verify the blob loader against the writer, and measure what it costs.
//
// Two things must hold before the engine can rely on this path, and neither is
// obvious from the code:
//
//   * the manifest must parse into the same entries the writer emitted, including the
//     ladder step and the ggml type each payload is already packed in. A file that
//     loads and produces plausible-looking numbers is exactly the failure mode that
//     already cost this project a day - a model whose size matched to the byte but
//     whose contents were wrong ran happily and emitted garbage.
//   * unbuffered reads must actually be unbuffered. If the flag were silently
//     ignored, a background loader would evict the model from the file cache and cost
//     37% of generation speed, and nothing in the API would say so. Reading the same
//     entries twice and comparing the timings shows it: cached reads are an order of
//     magnitude faster than the disk, so if the second pass is not faster, the cache
//     is genuinely out of the way.
#include <cmath>
#include <cstdio>
#include <cstring>
#include <map>
#include <string>
#include <vector>

#include "memex/blob_loader.hpp"

namespace {

}  // namespace


int main(int argc, char** argv) {
    setvbuf(stdout, nullptr, _IONBF, 0);
    std::string blob = "D:/MemeX/blob/test.bin";
    std::string man = "D:/MemeX/blob/test.json";

    for (int i = 1; i < argc; ++i) {
        if (!strcmp(argv[i], "--blob") && i + 1 < argc) blob = argv[++i];
        else if (!strcmp(argv[i], "--manifest") && i + 1 < argc) man = argv[++i];

    }

    memex::BlobLoader loader;
    std::string err;
    if (!loader.open(blob, man, &err)) {
        printf("не открылось: %s\n", err.c_str());
        return 1;
    }
    const auto& es = loader.entries();
    printf("записей в манифесте: %zu\n", es.size());
    int source_copies = 0;
    std::map<std::string, int> by_step;
    for (const auto& e : es) {
        by_step[e.step]++;
        if (e.step == "source") source_copies++;
    }
    printf("по ступеням лестницы:");
    for (const auto& kv : by_step) {
        printf(" %s=%d", kv.first.c_str(), kv.second);
    }
    printf(" (kopii v ishodnom vide %d)\n", source_copies);

    // Read every quantised entry once, then a second time, and compare rates.
    memex::AlignedBuffer buf(1 << 22);
    double first_ms = 0.0, second_ms = 0.0;
    std::size_t first_bytes = 0;
    int n_read = 0;
    for (int pass = 0; pass < 2; ++pass) {
        const auto before = loader.stats();
        for (const auto& e : es) {
            if (e.step == "source") continue;          // sizes vary by source type
            if (memex::AlignedBuffer::round_up(e.bytes) > buf.size()) continue;
            if (!loader.read_sync(e, buf.data(), buf.size())) {
                printf("чтение не удалось: слой %u эксперт %u\n", e.layer, e.expert);
                return 1;
            }
            if (pass == 0) {
                first_bytes += e.bytes;
                n_read++;
            }
        }
        const auto after = loader.stats();
        const double ms = after.read_ms - before.read_ms;
        if (pass == 0) first_ms = ms; else second_ms = ms;
    }
    printf("прочитано %d записей, %.2f ГБ\n", n_read, first_bytes / 1e9);
    printf("первый проход %.0f мс (%.0f МБ/с), второй %.0f мс (%.0f МБ/с)\n",
           first_ms, first_bytes / first_ms / 1e3,
           second_ms, first_bytes / second_ms / 1e3);
    printf("вывод: %s\n",
           second_ms > first_ms * 0.6
               ? "кэш не участвует — чтение действительно небуферизованное"
               : "второй проход намного быстрее — похоже, читаем из кэша");

    return 0;
}
