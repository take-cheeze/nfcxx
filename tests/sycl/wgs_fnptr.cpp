// Two work-group statics that one kernel uses together must not share local memory (scripts/pathb-spirv-emit.rb wgs_layout),
// one of them reached through a constexpr function pointer from a template selector (fnptr_constexpr.cpp's shape). Work-item
// 0 writes both buffers, the group barriers, and work-item 1 reads both back. Expected output: "wgs_fnptr ok".
#include <sycl/sycl.hpp>
#include <sycl/ext/oneapi/work_group_static.hpp>
#include <cstdio>

namespace syclex = sycl::ext::oneapi::experimental;

static float *direct_buf() {
    syclex::work_group_static<float[64]> a;
    return (float *) &a;
}

static float *pointer_buf() {
    syclex::work_group_static<float[64]> b;
    return (float *) &b;
}

typedef float *(*buf_t)();
template <int D> constexpr buf_t get_buf() { return pointer_buf; }   // fnptr_constexpr.cpp's selector shape

int main() {
    sycl::queue q;
    float *out = sycl::malloc_shared<float>(2, q);
    out[0] = out[1] = -1.0f;
    q.parallel_for(sycl::nd_range<1>(sycl::range<1>(2), sycl::range<1>(2)), [=](sycl::nd_item<1> it) {
        constexpr buf_t get = get_buf<0>();
        float *b = get();
        float *a = direct_buf();
        if (it.get_local_id(0) == 0) {
            b[0] = 7.0f;
            a[0] = 3.0f;
        }
        sycl::group_barrier(it.get_group());
        if (it.get_local_id(0) == 1) {
            out[0] = a[0];
            out[1] = b[0];
        }
    }).wait();
    int bad = 0;
    if (out[0] != 3.0f) { std::printf("a[0] = %g, want 3\n", (double) out[0]); bad++; }
    if (out[1] != 7.0f) { std::printf("b[0] = %g, want 7 (a and b overlap?)\n", (double) out[1]); bad++; }
    std::printf(bad ? "wgs_fnptr FAIL %d\n" : "wgs_fnptr ok\n", bad);
    return bad != 0;
}
