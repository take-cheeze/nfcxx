// Byte processing with a table lookup and a histogram: memory-heavy integer loop.
#include <cstdio>
#include <cstdint>
#include <ctime>
static uint8_t buf[1 << 16];
static uint32_t table[256];
static uint32_t hist[256];
__attribute__((noinline)) uint32_t crcish(const uint8_t* p, int n, uint32_t seed) {
    uint32_t h = seed;
    for (int i = 0; i < n; i++) {
        uint8_t v = p[i];
        h = (h << 5) ^ (h >> 27) ^ table[(v ^ h) & 255];
        hist[v] += 1;
    }
    return h;
}
int main() {
    for (int i = 0; i < 256; i++) table[i] = (uint32_t)i * 2654435761u;
    for (int i = 0; i < (1 << 16); i++) buf[i] = (uint8_t)((i * 131) ^ (i >> 3));
    uint32_t h = 1;
    timespec t0, t1; clock_gettime(CLOCK_MONOTONIC, &t0);
    for (int r = 0; r < 3000; r++) h = crcish(buf, 1 << 16, h);
    clock_gettime(CLOCK_MONOTONIC, &t1);
    double secs = (t1.tv_sec - t0.tv_sec) + (t1.tv_nsec - t0.tv_nsec) * 1e-9;
    uint64_t hs = 0; for (int i = 0; i < 256; i++) hs += hist[i] * (uint64_t)(i + 1);
    std::printf("int checksum %u %llu\n", h, (unsigned long long)hs);
    std::fprintf(stderr, "TIME %.4f\n", secs);
    return 0;
}
