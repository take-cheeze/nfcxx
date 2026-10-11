// The vecAdd kernel of NVIDIA cuda-samples 0_Introduction/vectorAdd, device side. The thread indices are
// intrinsic calls (scripts/pathb-ptx-emit.rb maps them to PTX special registers): the device compile has no
// CUDA headers. The kernel is `vecAdd` in the sample, with threadIdx.x + blockIdx.x * blockDim.x as the index.
extern "C" unsigned __nfcxx_tid_x(void);
extern "C" unsigned __nfcxx_ctaid_x(void);
extern "C" unsigned __nfcxx_ntid_x(void);

void vecAdd(float *A, float *B, float *C, int vectorLength) {
  int workIndex = (int)__nfcxx_tid_x() + (int)__nfcxx_ctaid_x() * (int)__nfcxx_ntid_x();
  if (workIndex < vectorLength) {
    C[workIndex] = A[workIndex] + B[workIndex];
  }
}
