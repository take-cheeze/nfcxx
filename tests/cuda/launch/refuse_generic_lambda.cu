// A generic lambda called with a value that is only known at run time: its instances are not known at compile time,
// so the rewriter refuses it by name (the call is not a literal std::integral_constant).
#include <cuda_runtime.h>
#include <type_traits>

template <int N> __global__ void kern(int * out) { out[N] = N; }

void dispatch(int * out, int v) {
    auto launch_kernel = [&](auto NC) {
        constexpr int kN = decltype(NC)::value;
        kern<kN><<<1, 1>>>(out);
    };
    launch_kernel(std::integral_constant<int, 3>{});
    launch_kernel(std::integral_constant<int, 0>{} + v);
}

int main() {
    int * d = 0;
    dispatch(d, 1);
    return 0;
}
