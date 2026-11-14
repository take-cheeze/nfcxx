// Dense float reduction and saxpy: the kind of loop a vectorizer should win on.
#include <cstdio>
#include <cstdint>
#include <ctime>
static const int N = 1 << 14;
static float a[N], b[N], c[N];
__attribute__((noinline)) float dot(const float* x, const float* y, int n) {
    float s = 0;
    for (int i = 0; i < n; i++) s += x[i] * y[i];
    return s;
}
__attribute__((noinline)) void saxpy(float k, const float* x, float* y, int n) {
    for (int i = 0; i < n; i++) y[i] = k * x[i] + y[i];
}
int main() {
    for (int i = 0; i < N; i++) { a[i] = (float)(i % 97) * 0.5f; b[i] = (float)(i % 31) * 0.25f; c[i] = 0; }
    float acc = 0;
    timespec t0, t1; clock_gettime(CLOCK_MONOTONIC, &t0);
    for (int r = 0; r < 20000; r++) {
        acc += dot(a, b, N);
        saxpy(1e-6f, a, c, N);
    }
    clock_gettime(CLOCK_MONOTONIC, &t1);
    double secs = (t1.tv_sec - t0.tv_sec) + (t1.tv_nsec - t0.tv_nsec) * 1e-9;
    double csum = 0; for (int i = 0; i < N; i++) csum += c[i];
    std::printf("float checksum %.3f %.3f\n", acc, csum);
    std::fprintf(stderr, "TIME %.4f\n", secs);
    return 0;
}
