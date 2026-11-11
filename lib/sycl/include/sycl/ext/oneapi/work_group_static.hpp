// sycl::ext::oneapi::experimental::work_group_static (sycl_ext_oneapi_work_group_static): work-group local storage declared
// in a kernel. The shim declares the type so that ggml-sycl's sources compile; it does NOT yet give the storage work-group
// scope. The object below is ordinary storage of each work-item, so a kernel that shares it through the address of the
// object (as ggml's fattn-vec.hpp does, (float *) &lsm) sees per-item copies. The device emitter has no lowering that places
// a kernel-scope object in local memory; a kernel that depends on sharing through work_group_static gives wrong values.
#ifndef NFCXX_SYCL_EXT_ONEAPI_WORK_GROUP_STATIC_HPP
#define NFCXX_SYCL_EXT_ONEAPI_WORK_GROUP_STATIC_HPP

#include <sycl/sycl.hpp>

namespace sycl {
namespace ext::oneapi::experimental {

template <class T> class work_group_static {
 public:
  work_group_static() = default;
  T &get() { return *reinterpret_cast<T *>(storage_); }
  const T &get() const { return *reinterpret_cast<const T *>(storage_); }
  operator T &() { return get(); }
  operator const T &() const { return get(); }

 private:
  alignas(16) unsigned char storage_[sizeof(T)];
};

}  // namespace ext::oneapi::experimental
}  // namespace sycl

#endif
