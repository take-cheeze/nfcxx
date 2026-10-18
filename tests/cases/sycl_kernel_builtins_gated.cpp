// EXPECT: 0
// The kernel-info builtins (__builtin_sycl_kernel_*) are reported absent by __has_builtin when __SYCL_UNNAMED_LAMBDA__ is
// defined, as the real toolchain defines it: the oneAPI headers then take the integration-header path (the driver's second
// pass supplies KernelInfoData). __builtin_sycl_unique_stable_name stays available. docs/notes/sycl-kernel-builtins.md.
// The checks need __has_builtin: hosts that do not define it (hexagon) skip them, so the case is a no-op there.
#if defined(__has_builtin)
#if __has_builtin(__builtin_sycl_kernel_name) != 1
#error the kernel-info builtins are present without __SYCL_UNNAMED_LAMBDA__
#endif
#if __has_builtin(__builtin_sycl_unique_stable_name) != 1
#error the stable name is always present
#endif
#define __SYCL_UNNAMED_LAMBDA__ 1
#if __has_builtin(__builtin_sycl_kernel_name) != 0
#error the kernel-info builtins must be hidden with __SYCL_UNNAMED_LAMBDA__
#endif
#if __has_builtin(__builtin_sycl_kernel_param_kind) != 0
#error the kernel-info builtins must be hidden with __SYCL_UNNAMED_LAMBDA__
#endif
#if __has_builtin(__builtin_sycl_unique_stable_name) != 1
#error the stable name is always present
#endif
#endif
int main() { return 0; }
