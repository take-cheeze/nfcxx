// A `using namespace n;` lets device code name n's templates unqualified (ggml-cuda's mmq-vec-dot.cuh uses
// ggml_cuda_mma's tile that way). The device unit keeps the directive with n's kept pieces: the class template tile
// with its partial specialization, which the kernel uses. The host helper of n is not carried.
namespace tiles {
    enum layout { ROW, COL };
    template <int I, int J, typename T, layout L = ROW>
    struct tile {};
    template <int I, int J>
    struct tile<I, J, float, ROW> {
        static constexpr int rows = I;
        static constexpr int cols = J;
    };
    static void host_only_helper(int x) { (void) x; }
}
using namespace tiles;

template <int N>
__global__ void k(float *out) {
    typedef tile<16, 8, float> t;
    out[threadIdx.x] = (float) t::rows + (float) N;
}

// The unqualified tile of a kernel body, and the template kernel launched from the host (its instance is kept).
__global__ void kuse(float *out) { out[threadIdx.x] = (float) tile<16, 8, float>::cols; }
void launch(float *out) { k<4><<<1, 4>>>(out); }
