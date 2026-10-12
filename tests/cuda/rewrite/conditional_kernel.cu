// A kernel inside #if/#else: the device pass keeps the branch it takes, so the kernel is in the unit.
#define USE_FAST 1
#if defined(USE_FAST) && USE_FAST == 1
__global__ void fast_kernel(int *a) { a[threadIdx.x] = 1; }
#else
__global__ void slow_kernel(int *a) { a[threadIdx.x] = 2; }
#endif

#if defined(__CUDA_ARCH__) && __CUDA_ARCH__ >= 700
__global__ void arch_kernel(int *a) { a[threadIdx.x] = 3; }
#elif defined(__CUDA_ARCH__)
__global__ void old_arch_kernel(int *a) { a[threadIdx.x] = 4; }
#else
__global__ void host_only_kernel(int *a) { a[threadIdx.x] = 5; }
#endif

#ifndef NO_SUCH_MACRO
__global__ void ifndef_kernel(int *a) { a[threadIdx.x] = 6; }
#endif

int main() { return 0; }
