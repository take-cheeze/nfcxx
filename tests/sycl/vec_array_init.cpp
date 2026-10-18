// A local array of a class with a non-trivial default constructor (sycl::vec<float,2>, whose constructor zero-fills it) in a
// device kernel. The front end default-initialises the array with one __cxa_vec_ctor call that takes the constructor's
// address; the device pass unrolls it into one direct constructor call per element (scripts/pathb-spirv-emit.rb,
// expand_cxa_vec_ctor). Every element that is not written must read back as zero. Expected output: "vec_array_init ok".
#include <sycl/sycl.hpp>
#include <cstdio>

int main() {
    const int N = 16;
    sycl::queue q;
    float * out = sycl::malloc_shared<float>(N, q);
    for (int i = 0; i < N; i++) out[i] = -1.0f;
    q.parallel_for(sycl::range<1>(N), [=](sycl::id<1> i) {
        sycl::vec<float, 2> t[3];          // default-initialised: all six lanes are zero
        t[1][0] = (float) i[0];
        out[i[0]] = t[0][0] + t[1][0] + t[2][1];
    }).wait();
    int bad = 0;
    for (int i = 0; i < N; i++)
        if (out[i] != (float) i) bad++;
    std::printf(bad ? "vec_array_init FAIL %d\n" : "vec_array_init ok\n", bad);
    return bad != 0;
}
