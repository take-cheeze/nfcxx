// Calls the two extern instances; their kernels are in inst_2.cu's and inst_3.cu's device images, not in this unit's.
#include <stdio.h>
#include "scale.cuh"

int main() {
    const int n = 64;
    int *d = nullptr, h[n];
    for (int i = 0; i < n; i++) h[i] = i;
    if (cudaMalloc(&d, sizeof h) != cudaSuccess) { printf("extern_inst: no device\n"); return 1; }
    cudaMemcpy(d, h, sizeof h, cudaMemcpyHostToDevice);
    int rc = scale_case<2>(d, n) | scale_case<3>(d, n);  // ((i * 2 + 2) * 3 + 3)
    cudaMemcpy(h, d, sizeof h, cudaMemcpyDeviceToHost);
    cudaFree(d);
    int bad = 0;
    for (int i = 0; i < n; i++) bad += h[i] != (i * 2 + 2) * 3 + 3;
    printf("extern_inst: %s, %d mismatches\n", rc ? "launch error" : "no error", bad);
    return bad != 0 || rc != 0;
}
