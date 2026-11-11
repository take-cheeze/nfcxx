// Closer to fattn-vec.hpp: the kernel body is a function template reached through a function-pointer template argument
// (fattn_kernel_t), and inside it a constexpr function-pointer local from a template selector (get_vec_dot_KQ) is called.
#include <sycl/sycl.hpp>

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
                   [=](sycl::nd_item<1> it) { if (it.get_global_id(0) == 0) f(out, in); });
}

int main() {
    sycl::queue q;
    float * o = sycl::malloc_shared<float>(32, q);
    float * i = sycl::malloc_shared<float>(32, q);
    i[0] = 2.0f;
    launch<body<64>, 64>(q, o, i);
    q.wait();
    return 0;
}
