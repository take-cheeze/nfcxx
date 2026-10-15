__device__ float f(int n) {
    extern __shared__ float2 meta[];
    float acc = 0.0f;
    for (int l = 0; l < n; ++l) {
        const float s = expf(meta[l].x);
        acc += s * meta[l].y;
    }
    return acc;
}
