__device__ float f(int n) {
    extern __shared__ float2 meta[];
    float acc = 0.0f;
    for (int l = 0; l < n; ++l) {
        const float s = expf(meta[l].x);
        acc += s * meta[l].y;
    }
    return acc;
}

// A kernel that calls f, so the device unit keeps it.
__global__ void kf(float *o) { o[threadIdx.x] = f(threadIdx.x); }
