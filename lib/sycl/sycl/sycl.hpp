// Host runtime for the SYCL subset of the nfcxx SYCL front end (scripts/sycl-rewrite.rb). A program includes
// <sycl/sycl.hpp>; the device half of each parallel_for is the kernel __nfcxx_sycl_kN of the rewrite, which is
// assembled to SPIR-V and loaded from the file named by NFCXX_SYCL_SPV at run time. Launches go through OpenCL
// (clCreateProgramWithIL), on the first Intel GPU (else the first GPU).
//
// Model. A queue is in order. A buffer owns its host memory (the vector it was built from) and a device copy, made on
// first use; the device copy is written back to the host when the buffer is destroyed, if an accessor could write it.
// A handler collects the accessors created on it, in order; parallel_for launches kernel k (k counts the parallel_for
// calls of the process) with those buffers as pointer arguments, then `int n` (the range). The kernel's argument count
// must match, which is checked. The lambda body is not run on the host: an accessor's operator[] only gives the host
// element so that the body compiles.
//
// Limits: one-dimensional ranges and buffers, one parallel_for per submit, float and any element type that is a plain
// C type, no events, no USM, no local accessors, no sub-groups, no error handling beyond fatal messages.
#ifndef NFCXX_SYCL_HPP
#define NFCXX_SYCL_HPP

#ifndef CL_TARGET_OPENCL_VERSION
#define CL_TARGET_OPENCL_VERSION 210
#endif
#include <CL/cl.h>
#include <cstddef>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <string>
#include <type_traits>
#include <vector>

namespace sycl {

class handler;
class queue;

namespace access {
enum class mode { read, write, read_write };
}

template <access::mode M>
using mode_tag = std::integral_constant<access::mode, M>;
inline constexpr mode_tag<access::mode::read> read_only{};
inline constexpr mode_tag<access::mode::write> write_only{};
inline constexpr mode_tag<access::mode::read_write> read_write{};

// The device selector: the runtime picks an Intel GPU (else the first GPU), whatever the tag.
inline constexpr int gpu_selector_v = 1;

template <int Dim>
struct range;

template <>
struct range<1> {
  size_t size0;
  explicit range(size_t n) : size0(n) {}
};

template <int Dim>
struct id;

template <>
struct id<1> {
  size_t v;
  id(size_t x) : v(x) {}
  operator size_t() const { return v; }
};

namespace info {
namespace device {
struct name {};
}
}

namespace detail {

inline void fatal(const char *what, cl_int err) {
  std::fprintf(stderr, "sycl: %s: OpenCL error %d\n", what, (int)err);
  std::exit(2);
}

inline void fatal(const char *msg) {
  std::fprintf(stderr, "sycl: %s\n", msg);
  std::exit(2);
}

struct runtime {
  cl_device_id dev = nullptr;
  cl_context ctx = nullptr;
  cl_command_queue q = nullptr;
  cl_program prog = nullptr;
  std::string dev_name;
  int next_kernel = 0;
};

inline runtime &rt() {
  static runtime r;
  static bool ready = false;
  if (ready) return r;
  ready = true;

  cl_platform_id plat[8];
  cl_uint nplat = 0;
  if (clGetPlatformIDs(8, plat, &nplat) != CL_SUCCESS || nplat == 0) fatal("no OpenCL platform");
  cl_device_id any = nullptr;
  for (cl_uint p = 0; p < nplat && !r.dev; p++) {
    cl_device_id devs[8];
    cl_uint ndev = 0;
    if (clGetDeviceIDs(plat[p], CL_DEVICE_TYPE_GPU, 8, devs, &ndev) != CL_SUCCESS) continue;
    for (cl_uint d = 0; d < ndev && !r.dev; d++) {
      char vendor[256];
      clGetDeviceInfo(devs[d], CL_DEVICE_VENDOR, sizeof vendor, vendor, nullptr);
      if (!any) any = devs[d];
      if (std::strstr(vendor, "Intel")) r.dev = devs[d];
    }
  }
  if (!r.dev) r.dev = any;
  if (!r.dev) fatal("no OpenCL GPU device");

  char name[256];
  clGetDeviceInfo(r.dev, CL_DEVICE_NAME, sizeof name, name, nullptr);
  r.dev_name = name;

  cl_int err;
  r.ctx = clCreateContext(nullptr, 1, &r.dev, nullptr, nullptr, &err);
  if (err != CL_SUCCESS) fatal("clCreateContext", err);
  r.q = clCreateCommandQueueWithProperties(r.ctx, r.dev, nullptr, &err);
  if (err != CL_SUCCESS) fatal("clCreateCommandQueueWithProperties", err);

  const char *path = std::getenv("NFCXX_SYCL_SPV");
  if (!path) fatal("NFCXX_SYCL_SPV is not set (the SPIR-V module of the device kernels)");
  std::FILE *f = std::fopen(path, "rb");
  if (!f) {
    std::fprintf(stderr, "sycl: cannot open %s\n", path);
    std::exit(2);
  }
  std::fseek(f, 0, SEEK_END);
  size_t len = (size_t)std::ftell(f);
  std::rewind(f);
  std::vector<unsigned char> il(len);
  if (std::fread(il.data(), 1, len, f) != len) fatal("short read of the SPIR-V module");
  std::fclose(f);

  r.prog = clCreateProgramWithIL(r.ctx, il.data(), len, &err);
  if (err != CL_SUCCESS) fatal("clCreateProgramWithIL", err);
  err = clBuildProgram(r.prog, 1, &r.dev, "", nullptr, nullptr);
  if (err != CL_SUCCESS) fatal("clBuildProgram", err);
  return r;
}

// The host side of a buffer: its memory and its device copy.
struct buffer_state {
  void *host = nullptr;
  size_t bytes = 0;
  cl_mem mem = nullptr;
  bool written = false;   // an accessor can write it: copy back on destruction
};

// Launches kernel __nfcxx_sycl_k<next> over n work items with the buffers as its pointer arguments, then n.
inline void launch(const std::vector<buffer_state *> &bufs, size_t n) {
  runtime &r = rt();
  char name[64];
  std::snprintf(name, sizeof name, "__nfcxx_sycl_k%d", r.next_kernel++);
  cl_int err;
  cl_kernel k = clCreateKernel(r.prog, name, &err);
  if (err != CL_SUCCESS) fatal(name, err);
  cl_uint nargs = 0;
  clGetKernelInfo(k, CL_KERNEL_NUM_ARGS, sizeof nargs, &nargs, nullptr);
  if (nargs != bufs.size() + 1) {
    std::fprintf(stderr, "sycl: %s takes %u arguments, the handler has %zu accessors\n", name, (unsigned)nargs, bufs.size());
    std::exit(2);
  }
  for (size_t i = 0; i < bufs.size(); i++) {
    buffer_state *b = bufs[i];
    if (!b->mem) {
      b->mem = clCreateBuffer(r.ctx, CL_MEM_READ_WRITE | CL_MEM_COPY_HOST_PTR, b->bytes, b->host, &err);
      if (err != CL_SUCCESS) fatal("clCreateBuffer", err);
    }
    if ((err = clSetKernelArg(k, (cl_uint)i, sizeof(cl_mem), &b->mem)) != CL_SUCCESS) fatal("clSetKernelArg", err);
  }
  int count = (int)n;
  if ((err = clSetKernelArg(k, (cl_uint)bufs.size(), sizeof(int), &count)) != CL_SUCCESS) fatal("clSetKernelArg", err);

  const size_t local = 128;
  size_t global = (n + local - 1) / local * local;
  if ((err = clEnqueueNDRangeKernel(r.q, k, 1, nullptr, &global, &local, 0, nullptr, nullptr)) != CL_SUCCESS)
    fatal("clEnqueueNDRangeKernel", err);
  clReleaseKernel(k);
}

}  // namespace detail

class device {
 public:
  template <typename P>
  std::string get_info() const {
    return info_of(P{});
  }

 private:
  std::string info_of(info::device::name) const { return detail::rt().dev_name; }
};

template <typename T, int Dim = 1>
class buffer;

template <typename T>
class buffer<T, 1> {
 public:
  explicit buffer(std::vector<T> &host) : host_(host.data()), count_(host.size()) {
    state_.host = host_;
    state_.bytes = count_ * sizeof(T);
  }
  buffer(const buffer &) = delete;
  buffer &operator=(const buffer &) = delete;
  ~buffer() {
    if (state_.mem && state_.written) {
      clEnqueueReadBuffer(detail::rt().q, state_.mem, CL_TRUE, 0, state_.bytes, host_, 0, nullptr, nullptr);
    }
    if (state_.mem) clReleaseMemObject(state_.mem);
  }

  detail::buffer_state &state() { return state_; }
  size_t size() const { return count_; }

 private:
  T *host_;
  size_t count_;
  detail::buffer_state state_;
};

template <typename T, access::mode M = access::mode::read_write>
class accessor;

class handler {
 public:
  template <typename F>
  void parallel_for(range<1> r, F &&) {
    detail::launch(bufs_, r.size0);
  }

  void add(detail::buffer_state *s, bool write) {
    bufs_.push_back(s);
    if (write) s->written = true;
  }

 private:
  std::vector<detail::buffer_state *> bufs_;
};

template <typename T, access::mode M>
class accessor {
 public:
  accessor(buffer<T, 1> &b, handler &h, mode_tag<M>) : data_(static_cast<T *>(b.state().host)) {
    h.add(&b.state(), M != access::mode::read);
  }

  // The host element, so that the lambda body compiles. The body itself runs on the device.
  T &operator[](id<1> i) const { return data_[i.v]; }

 private:
  T *data_;
};

template <typename T, access::mode M>
accessor(buffer<T, 1> &, handler &, mode_tag<M>) -> accessor<T, M>;

class queue {
 public:
  explicit queue(int) { detail::rt(); }

  device get_device() const { return device(); }

  template <typename F>
  void submit(F &&f) {
    handler h;
    f(h);
  }

  void wait() { clFinish(detail::rt().q); }
};

}  // namespace sycl

#endif
