// A launch macro defined and used inside a function body (ggml-cuda's allreduce LAUNCH_AR_KERNEL): its calls are expanded,
// so the wrappers take the argument types, not the macro's parameter names.
template <typename T_dst, typename T_wire>
static __global__ void ar_kernel(const T_dst *a, T_wire *b) { b[threadIdx.x] = (T_wire) a[threadIdx.x]; }

static void run(const float *a, void *b, int t) {
#define LAUNCH_AR(T_dst, T_wire) \
    ar_kernel<T_dst, T_wire><<<dim3(1), dim3(32), 0, 0>>>( \
        reinterpret_cast<const T_dst *>(a), reinterpret_cast<T_wire *>(b));
    switch (t) {
        case 0: LAUNCH_AR(float, float); break;
        default: LAUNCH_AR(float, double); break;
    }
#undef LAUNCH_AR
}
