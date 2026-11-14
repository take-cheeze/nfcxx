/* nfcxx: an empty <bits/math-vector.h> for Path B's hosted front end on a Linux aarch64 host. The front end targets x86-64
   Linux, but the host's glibc (aarch64) puts its vector math declarations in this header: they use GCC's AdvSIMD and SVE
   vector types (__Float32x4_t, __SVFloat32_t), which EDG does not have, so math.h fails. The x86-64 header declares
   nothing without -ffast-math, so this gives the same declarations: none, with the SIMD declaration macros defined as
   empty. Found first on the include path (the driver and scripts/pathb-dump pass it only on Linux aarch64, hosted). */
#ifndef NFCXX_PATHB_LINUX_AARCH64_MATH_VECTOR_H
#define NFCXX_PATHB_LINUX_AARCH64_MATH_VECTOR_H
#include <bits/libm-simd-decl-stubs.h>
#endif
