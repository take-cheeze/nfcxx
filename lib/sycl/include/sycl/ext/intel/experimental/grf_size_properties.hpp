// sycl::ext::intel::experimental::grf_size_automatic (sycl_ext_intel_kernel_properties_grf_size): the kernel property that
// lets the compiler pick the general register file size. The shim has no register-file allocation to steer, so the property
// is accepted and changes nothing: a kernel with the property runs as it would without it.
#ifndef NFCXX_SYCL_EXT_INTEL_EXPERIMENTAL_GRF_SIZE_PROPERTIES_HPP
#define NFCXX_SYCL_EXT_INTEL_EXPERIMENTAL_GRF_SIZE_PROPERTIES_HPP

#include <sycl/sycl.hpp>

namespace sycl {
namespace ext::oneapi::experimental {

// the kernel-property list (sycl_ext_oneapi_properties) as ggml-sycl uses it: properties{ key, ... }
template <class... P> struct properties {
  constexpr explicit properties(P...) {}   // with no P, the default constructor
};

}  // namespace ext::oneapi::experimental

namespace ext::intel::experimental {

struct grf_size_automatic_key {};
inline constexpr grf_size_automatic_key grf_size_automatic{};

}  // namespace ext::intel::experimental
}  // namespace sycl

#endif
