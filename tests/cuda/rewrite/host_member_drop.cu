// The host-only member of a device-side class is not kept: it calls a host helper that the device unit must not carry.
static bool host_dispatch_available(const int cc) { return cc >= 700; }

struct config {
    __host__ int layout(const int cc) const {
        if (host_dispatch_available(cc)) {
            return 1;
        }
        return 0;
    }

    constexpr __device__ bool layout() const { return true; }
};

__global__ void use_config(int *out) {
    config c;
    out[threadIdx.x] = c.layout() ? 1 : 0;
}
