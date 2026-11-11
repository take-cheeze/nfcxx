// A constexpr function pointer chosen by a template selector (get_kq<D>()), stored in a local and called inside a kernel body
// that a function-pointer template argument reaches (fattn-vec.hpp's vec_dot_KQ shape). The device pass folds the stored
// address into direct calls (scripts/pathb-spirv-emit.rb, scripts/pathb-wgsl-emit.rb: fold_fnptr_slots). The reproducer that
// the device pass refused before is tests/sycl/refuse_fnptr_constexpr.cpp. Expected output: "fnptr_constexpr ok".
#include <sycl/sycl.hpp>
#include <cstdio>

typedef float (*kq_t)(const float *, const float *);

template <int D> static float dot_k(const float * x, const float * y) { return x[0] * y[0] * (float) D; }
template <int D> constexpr kq_t get_kq() {
    if constexpr (D == 64) {
        return dot_k<D>;
    } else {
        return nullptr;
    }
}

template <int D> static void body(float * out, const float * in) {
    constexpr kq_t kq = get_kq<D>();
    out[0] = kq(in, in);
}

template <void (*f)(float *, const float *), int D> static void launch(sycl::queue & q, float * out, const float * in) {
    q.parallel_for(sycl::nd_range<1>(sycl::range<1>(32), sycl::range<1>(16)),
                   [=](sycl::nd_item<1> it) { if (it.get_global_id(0) == 0) f(out, in); }).wait();
}

int main() {
    sycl::queue q;
    float * o = sycl::malloc_shared<float>(32, q);
    float * i = sycl::malloc_shared<float>(32, q);
    o[0] = -1.0f;
    i[0] = 2.0f;
    launch<body<64>, 64>(q, o, i);
    const float want = 2.0f * 2.0f * 64.0f;
    if (o[0] == want) {
        std::printf("fnptr_constexpr ok\n");
        return 0;
    }
    std::printf("fnptr_constexpr FAIL: out[0] = %g, want %g\n", (double) o[0], (double) want);
    return 1;
}
