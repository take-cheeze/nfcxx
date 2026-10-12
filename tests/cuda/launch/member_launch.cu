// A launch inside a member of a class template (MC_EstimatePiP's PiEstimator<Real>::operator()): the member's
// template parameter is the class's, and its instances are the class's explicit instantiations.
#include <cuda_runtime.h>
#include <stdio.h>

template <typename Real> __global__ void kern(Real *p, int n) { p[0] = (Real)n; }

template <typename Real> struct Est {
  Real run(Real *p);
};

template <typename Real> Real Est<Real>::run(Real *p) {
  kern<Real><<<1, 1>>>(p, 7);
  return (Real)0;
}

template struct Est<float>;

int main() {
  float *p = 0;
  cudaMalloc((void **)&p, sizeof(float));
  Est<float> e;
  e.run(p);
  cudaError_t err = cudaGetLastError();
  float v = 0;
  cudaMemcpy(&v, p, sizeof v, cudaMemcpyDeviceToHost);
  printf("member launch: %s, value %.1f\n", cudaGetErrorString(err), v);
  cudaFree(p);
  return v != 7.0f;
}
