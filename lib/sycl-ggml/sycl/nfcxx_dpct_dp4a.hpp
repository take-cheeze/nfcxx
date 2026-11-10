// dpct::dp4a(int, int, int) on the device: the packed signed 8-bit dot product in the hardware. ggml-sycl's dpct/helper.hpp
// defines dp4a as a template that unpacks both words into sycl::vec<int, 4> and sums four products; after inlining, the
// SPIR-V emitter sees only those byte extracts and multiplies. This plain function, declared before the template (the helper
// includes <sycl/half_type.hpp>, which includes this header, at its top), is the better overload for int operands: the call
// stays the intrinsic __nfcxx_sycl_dp4a, which the emitters lower to OpSDot (the OpenCL module) or to the byte products
// (Vulkan, WGSL). The result is the template's: c plus the four products, wrapping as int does on the device.
#ifndef NFCXX_SYCL_GGML_DPCT_DP4A_HPP
#define NFCXX_SYCL_GGML_DPCT_DP4A_HPP

#ifdef __NFCXX_SYCL_DEVICE__
extern "C" int __nfcxx_sycl_dp4a(int a, int b, int c);

namespace dpct {
inline int dp4a(int a, int b, int c) { return __nfcxx_sycl_dp4a(a, b, c); }
}  // namespace dpct
#endif

#endif
