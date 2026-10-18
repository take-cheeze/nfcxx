// The device pass emits only the functions a kernel reaches. host_only_arrays() is host code: it default-initialises an array
// of std::unique_ptr (a non-trivial constructor AND destructor, which the device pass cannot lower) and no kernel calls it.
// The kernel next to it must still build and run. Expected output: "host_only_reach ok".
#include <sycl/sycl.hpp>
#include <cstdio>
#include <memory>

static int host_only_arrays() {
    std::unique_ptr<int> p[4];   // default-initialised: a constructor and a destructor per element
    p[0].reset(new int(7));
    return *p[0];
}

int main() {
    const int N = 8;
    sycl::queue q;
    int * out = sycl::malloc_shared<int>(N, q);
    q.parallel_for(sycl::range<1>(N), [=](sycl::id<1> i) { out[i[0]] = (int) i[0] * 2; }).wait();
    int bad = 0;
    for (int i = 0; i < N; i++)
        if (out[i] != i * 2) bad++;
    bad += host_only_arrays() != 7;
    std::printf(bad ? "host_only_reach FAIL %d\n" : "host_only_reach ok\n", bad);
    return bad != 0;
}
