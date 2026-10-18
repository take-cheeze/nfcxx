// A function pointer as a non-type template argument, called inside a kernel (the shape of ggml-sycl's get_rows_sycl<..., dq>
// through k_get_rows's dequantize_kernel parameter). The device pass sees "nonnull &dq" (the front end's check of the
// function pointer) before the direct call; the function's address is never null, so the check is dropped.
// A second launcher is never called and must still compile. Expected output: "fnptr_template_arg ok".
#include <sycl/sycl.hpp>
#include <cstdio>

typedef void (*dq_t)(int, float &);

static void dq(int i, float & v) { v = (float) i * 0.5f; }

template <dq_t f>
static void k(float * out, const sycl::nd_item<1> & it) {
    float v;
    f((int) it.get_global_id(0), v);
    out[it.get_global_id(0)] = v;
}

template <dq_t f>
static void launch(sycl::queue & q, float * out) {
    q.parallel_for(sycl::nd_range<1>(sycl::range<1>(64), sycl::range<1>(32)),
                   [=](sycl::nd_item<1> it) { k<f>(out, it); });
}

[[maybe_unused]] static void never_called(sycl::queue & q, float * o) { launch<dq>(q, o); }

int main() {
    sycl::queue q;
    const int N = 64;
    float * o = sycl::malloc_shared<float>(N, q);
    for (int i = 0; i < N; i++) o[i] = -1.0f;
    launch<dq>(q, o);
    q.wait();
    int bad = 0;
    for (int i = 0; i < N; i++)
        if (o[i] != (float) i * 0.5f) bad++;
    sycl::free(o, q);
    std::printf(bad ? "fnptr_template_arg FAIL %d\n" : "fnptr_template_arg ok\n", bad);
    return bad != 0;
}
