// Branchy struct updates over an array of records: register pressure and if-conversion.
#include <cstdio>
#include <cstdint>
#include <ctime>
struct Rec { int32_t a, b, c; uint8_t flag; };
static const int N = 1 << 14;
static Rec recs[N];
__attribute__((noinline)) int64_t step(Rec* r, int n, int64_t acc) {
    for (int i = 0; i < n; i++) {
        int32_t x = r[i].a, y = r[i].b;
        int32_t m = x > y ? x - y : y - x;
        if (r[i].flag & 1) r[i].c += m; else r[i].c -= m >> 1;
        r[i].a = (x * 3 + r[i].c) & 0xffff;
        acc += (r[i].c > 0) ? r[i].c : -r[i].c;
    }
    return acc;
}
int main() {
    for (int i = 0; i < N; i++) { recs[i].a = i * 7 % 1000; recs[i].b = i * 13 % 997; recs[i].c = 0; recs[i].flag = (uint8_t)(i & 3); }
    int64_t acc = 0;
    timespec t0, t1; clock_gettime(CLOCK_MONOTONIC, &t0);
    for (int r = 0; r < 20000; r++) acc = step(recs, N, acc);
    clock_gettime(CLOCK_MONOTONIC, &t1);
    double secs = (t1.tv_sec - t0.tv_sec) + (t1.tv_nsec - t0.tv_nsec) * 1e-9;
    int64_t cs = 0; for (int i = 0; i < N; i++) cs += recs[i].c;
    std::printf("branchy checksum %lld %lld\n", (long long)acc, (long long)cs);
    std::fprintf(stderr, "TIME %.4f\n", secs);
    return 0;
}
