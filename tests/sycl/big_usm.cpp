// A device allocation larger than the device heap (1 GB by default) is a device-only block of its own: a memset, a kernel
// write over the whole block, and copies back from its interior (a row of a matrix, as flash attention's buffers are read).
// Expected output: "big_usm ok".
#include <sycl/sycl.hpp>
#include <cstdio>
#include <vector>

int main() {
    sycl::queue q;
    const size_t n = size_t(3) << 27;   // 402M floats = 1.5 GB
    float *big = sycl::malloc_device<float>(n, q);
    float *small = sycl::malloc_device<float>(1024, q);
    if (!big || !small) { std::printf("big_usm: allocation failed\n"); return 1; }
    q.memset(big, 0, n * sizeof(float)).wait();
    q.parallel_for(sycl::range<1>(n), [=](sycl::id<1> i) { big[i] = float(i[0] & 1023); }).wait();
    q.parallel_for(sycl::range<1>(1024), [=](sycl::id<1> i) { small[i] = float(i[0]); }).wait();
    std::vector<float> host(1024);
    q.memcpy(host.data(), big + (n - 1024), 1024 * sizeof(float)).wait();
    bool ok = true;
    for (int i = 0; i < 1024; i++) ok = ok && host[i] == float((n - 1024 + i) & 1023);
    q.memcpy(host.data(), small, 1024 * sizeof(float)).wait();
    for (int i = 0; i < 1024; i++) ok = ok && host[i] == float(i);
    sycl::free(big, q);
    sycl::free(small, q);
    std::printf("%s\n", ok ? "big_usm ok" : "big_usm: wrong values");
    return ok ? 0 : 1;
}
