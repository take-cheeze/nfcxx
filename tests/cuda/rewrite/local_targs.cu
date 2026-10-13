// A launch whose template arguments are constexpr locals of the block holding the launch: the wrapper takes their values.
template <int W, int K>
static __global__ void scale(float *p) { p[threadIdx.x] = (float)(W * 10 + K); }
static void run_case(float *d, bool use) {
    if (use) {
        constexpr int K = 3;
        constexpr int W = 4;
        scale<W, K><<<1, 2>>>(d);
    }
}
