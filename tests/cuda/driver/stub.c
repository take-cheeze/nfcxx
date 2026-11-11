// The toolkit's lib64/stubs/libcuda.so stand-in (soname libcuda.so.1), for the CMake case of run.sh: CMake finds it
// for CUDA::cuda_driver; a link that kept it would need libcuda.so.1 at run time.
int cuInit(unsigned f) { (void)f; return 999; }
int cuDeviceGetCount(int *n) { *n = 0; return 999; }
int cuGetErrorName(int e, const char **s) { (void)e; *s = "stub"; return 0; }
