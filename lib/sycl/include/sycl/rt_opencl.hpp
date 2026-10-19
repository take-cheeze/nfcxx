// OpenCL runtime for lib/sycl: the backend functions of sycl.hpp over one in-order OpenCL queue on an Intel GPU (the Arc B60
// with NEO; any GPU with fine-grained shared virtual memory). The kernels are the SPIR-V module of
// scripts/pathb-spirv-emit.rb --kernel-cl (PREFIX.cl.spv, with PREFIX.man beside it): an OpenCL kernel per entry point,
// taking the push block as its one argument.
//
// Memory. The heap is one shared USM allocation (cl_intel_unified_shared_memory, clSharedMemAllocINTEL): the host and the
// device see it at the same addresses, so a device address is the host address (the identity case of rt_vulkan.hpp), and
// the device's atomics work on it (the B60 has ATOMIC_ACCESS for shared allocations; its SVM is coarse-grained only, with no
// atomics). Layout: the flag word at 0, the push block at 4352, the kernel's captured state at 256 (up to 4096 bytes), then
// the allocator from 8192.
//
// Dispatch. The local size is the module's specialization constants (ids 0, 1, 2), which OpenCL sets per program before the
// build; a program is built once per local size (the same cache as the Vulkan pipelines). Each dispatch is waited for before
// the next, and the flag is read after it.
//
// Environment: NFCXX_SYCL_IMAGE (the prefix; defaults to the NFCXX_SYCL_IMAGE_PREFIX macro of the build).
#ifndef NFCXX_SYCL_RT_OPENCL_HPP
#define NFCXX_SYCL_RT_OPENCL_HPP

#define CL_TARGET_OPENCL_VERSION 220
#include <CL/cl.h>
#include <CL/cl_ext.h>

#include <algorithm>
#include <cstdint>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <iterator>
#include <map>
#include <string>
#include <vector>

namespace sycl {
namespace detail {

// The push block of scripts/pathb-spirv-emit.rb (PUSH_MEMBERS, natural alignment): the same struct as rt_vulkan.hpp.
struct cl_push {
  uint64_t closure, statics, stack, local, flag;
  uint32_t gx, gy, gz, nx, ny, nz, stack_bytes, local_stride, local_user, ox, oy, oz;
  uint64_t hlo, hsize, dbase;
};
static_assert(sizeof(cl_push) == 112, "push block layout");
constexpr uint64_t cl_push_at = 4352;   // the push block's offset in the heap
constexpr uint64_t cl_closure_at = 256;

class cl_rt {
 public:
  static cl_rt &get() {
    static cl_rt r;
    return r;
  }

  // ---- heap (the same allocator as rt_vulkan.hpp)
  uint64_t alloc(uint64_t bytes) {
    bytes = bytes ? (bytes + 15) & ~uint64_t(15) : 16;
    for (auto it = free_.begin(); it != free_.end(); ++it) {
      if (it->second >= bytes) {
        uint64_t off = it->first;
        uint64_t left = it->second - bytes;
        free_.erase(it);
        if (left) free_[off + bytes] = left;
        used_[off] = bytes;
        return dev_base_ + off;
      }
    }
    fail("out of device memory (the heap is " + std::to_string(heap_size_ >> 20) + " MB; the stacks of a dispatch take "
         "invocations times stack bytes)");
    return 0;
  }
  void release(uint64_t addr) {
    if (!addr) return;
    uint64_t off = addr - dev_base_;
    auto u = used_.find(off);
    if (u == used_.end()) return;
    uint64_t n = u->second;
    used_.erase(u);
    free_[off] = n;
    auto nx = free_.find(off + n);
    if (nx != free_.end()) { free_[off] += nx->second; free_.erase(nx); }
    auto it = free_.find(off);
    if (it != free_.begin()) {
      auto pv = std::prev(it);
      if (pv->first + pv->second == it->first) { pv->second += it->second; free_.erase(it); }
    }
  }
  uint64_t largest_free() const {
    uint64_t m = 0;
    for (const auto &f : free_) m = std::max(m, f.second);
    return m;
  }
  // a check that failed in the kernel sets the flag: the program stops with the reason
  void check_flag() {
    uint32_t flag = 0;
    std::memcpy(&flag, at(dev_base_), 4);
    if (flag) {
      static const char *why[] = {"", "integer division by zero or INT_MIN / -1", "shift count out of range", "index out of bounds",
                                  "null pointer dereference", "trap or unreachable", "float to integer conversion out of range",
                                  "a write to the kernel's captured state"};
      std::fprintf(stderr, "sycl: a kernel trapped: %s\n", flag < 8 ? why[flag] : "unknown");
      std::exit(71);
    }
  }
  uint8_t *at(uint64_t addr) const {
    if (addr < dev_base_ || addr - dev_base_ >= heap_size_) fail("device address outside the heap");
    return host_ + (addr - dev_base_);
  }
  bool in_heap(const void *p) const {
    uintptr_t a = (uintptr_t)p;
    return a >= (uintptr_t)host_ && a - (uintptr_t)host_ < heap_size_;
  }
  uint64_t dev_of(const void *p) const { return dev_base_ + ((uintptr_t)p - (uintptr_t)host_); }

  // ---- dispatch
  void dispatch(const std::string &key, const void *closure, unsigned closure_bytes, const unsigned *g, const unsigned *l,
                unsigned lmem, buffer_state **bufs, int nbufs, const int *modes) {
    auto it = kernels_.find(key);
    if (it == kernels_.end()) {
      std::fprintf(stderr, "sycl: no kernel for the closure type %s (the image has %d)\n", key.c_str(), (int)kernels_.size());
      std::exit(3);
    }
    if (closure_bytes != it->second.closure_size && it->second.closure_size) {
      std::fprintf(stderr, "sycl: the closure of %s is %u bytes on the host but %u in the device pass (build with the same "
                   "compiler on both sides)\n", key.c_str(), closure_bytes, it->second.closure_size);
      std::exit(5);
    }
    if (closure_bytes > 4096) fail("the kernel's captured state is larger than 4096 bytes");
    check_limits(l, lmem);
    for (int i = 0; i < nbufs; i++) sync_up(bufs[i], modes[i]);
    uint32_t ng[3], gs[3];
    uint64_t invocations = 1, groups = 1;
    for (int d = 0; d < 3; d++) {
      uint32_t n = l[d] ? (g[d] + l[d] - 1) / l[d] : 1;
      ng[d] = n;
      gs[d] = g[d];
      invocations *= (uint64_t)n * l[d];
      groups *= n;
    }
    // the group's local region: the user's local memory, the 1024-byte scratch tail, then the work-group statics (manifest L)
    uint64_t stride = (uint64_t(lmem) + 1024 + static_local_ + 15) & ~uint64_t(15);
    // the stacks and the work-group memory of the grid: one slab when they fit the heap's largest free block, otherwise
    // several launches. A slab is a run of groups along the outermost dimension with more than one group (sd); the
    // dimensions above sd must be a single invocation, so the slab's invocations are contiguous in the emitter's linear
    // index. The emitter numbers stacks and local memory over the whole grid (the slab offset ox/oy/oz is in that
    // index), so each slab's bases are biased by the slab's first index and the region holds just the slab.
    uint64_t stack_total = invocations * stack_bytes_;
    uint64_t room = largest_free();
    int sd = 0;
    for (int d = 2; d >= 0; d--) if (ng[d] > 1) { sd = d; break; }
    bool sliceable = true;
    for (int e = sd + 1; e < 3; e++) if (l[e] != 1) sliceable = false;
    uint64_t inner = 1;   // the groups in the dimensions below sd
    for (int e = 0; e < sd; e++) inner *= ng[e];
    uint64_t inv_group = (uint64_t)l[0] * l[1] * l[2];
    uint64_t per_group = inv_group * stack_bytes_ + stride;
    uint32_t per_launch = ng[sd];   // groups along sd in one launch
    if (stack_total + groups * stride > room && sliceable) {
      uint64_t fit = room / (inner * per_group);
      per_launch = fit >= 1 ? (uint32_t)std::min<uint64_t>(fit, ng[sd]) : 1;
    }
    std::memset(at(dev_base_), 0, 4);   // the flag
    std::memcpy(at(closure_addr()), closure, closure_bytes);
    cl_kernel k = kernel(it->second.entry, l);
    for (uint32_t s0 = 0; s0 < ng[sd]; s0 += per_launch) {
      uint32_t cnt = std::min(per_launch, ng[sd] - s0);
      uint64_t first_group = (uint64_t)s0 * inner;
      uint64_t slab_groups = (uint64_t)cnt * inner;
      uint64_t slab_stack = slab_groups * inv_group * stack_bytes_;
      uint64_t region = alloc(slab_stack + slab_groups * stride);
      cl_push p{};
      p.closure = closure_addr();
      p.statics = statics_;
      p.stack = region - first_group * inv_group * stack_bytes_;   // biased: the slab's first invocation is at region
      p.local = region + slab_stack - first_group * stride;
      p.flag = dev_base_;
      p.hlo = (uint64_t)(uintptr_t)host_;
      p.hsize = heap_size_;
      p.dbase = dev_base_;
      p.gx = gs[0]; p.gy = gs[1]; p.gz = gs[2];
      p.nx = ng[0]; p.ny = ng[1]; p.nz = ng[2];
      p.stack_bytes = stack_bytes_;
      p.local_stride = (uint32_t)stride;
      p.local_user = lmem;
      p.ox = 0; p.oy = 0; p.oz = 0;
      uint32_t *o[3] = {&p.ox, &p.oy, &p.oz};
      *o[sd] = s0;
      uint32_t ngs[3] = {ng[0], ng[1], ng[2]};
      ngs[sd] = cnt;
      std::memcpy(at(dev_base_ + cl_push_at), &p, sizeof p);
      check(set_arg_mem_(k, 0, at(dev_base_ + cl_push_at)), "clSetKernelArgMemPointerINTEL");
      size_t global[3] = {(size_t)ngs[0] * l[0], (size_t)ngs[1] * l[1], (size_t)ngs[2] * l[2]};
      size_t local[3] = {l[0], l[1], l[2]};
      check(clEnqueueNDRangeKernel(queue_, k, 3, nullptr, global, local, 0, nullptr, nullptr), "clEnqueueNDRangeKernel");
      check(clFinish(queue_), "clFinish");
      release(region);
      check_flag();
    }
    for (int i = 0; i < nbufs; i++) if (modes[i] & 2) { bufs[i]->dev_valid = true; bufs[i]->host_valid = false; }
  }

  // ---- buffer copies (the heap is shared memory: a copy is a memcpy, but the device copy is written by kernels)
  void write(uint64_t addr, const void *src, uint64_t n) { std::memcpy(at(addr), src, n); }
  void read(uint64_t addr, void *dst, uint64_t n) { std::memcpy(dst, at(addr), n); }

  void sync_up(buffer_state *s, int mode) {
    if (s->dev == 0) return;
    if ((mode & 1) && !s->dev_valid && s->host_valid) {
      write(s->dev, s->host, s->bytes);
      s->dev_valid = true;
    }
  }

  void sync_down(buffer_state *s) {
    if (s->dev == 0 || s->host_valid) return;
    read(s->dev, s->host, s->bytes);
    s->host_valid = true;
  }

 private:
  struct kernel_info {
    std::string entry;
    uint32_t closure_size;
  };

  cl_rt() {
    const char *prefix = std::getenv("NFCXX_SYCL_IMAGE");
#ifdef NFCXX_SYCL_IMAGE_PREFIX
    if (!prefix) prefix = NFCXX_SYCL_IMAGE_PREFIX;
#endif
    if (!prefix) fail("set NFCXX_SYCL_IMAGE (see scripts/sycl-build.sh)");
    read_manifest(std::string(prefix) + ".man");
    init_device(std::string(prefix) + ".cl.spv");
  }

  [[noreturn]] void fail(const std::string &why) const {
    std::fprintf(stderr, "sycl: OpenCL runtime: %s\n", why.c_str());
    std::exit(70);
  }

  void check(cl_int r, const char *what) const {
    if (r != CL_SUCCESS) fail(std::string(what) + " failed (OpenCL error " + std::to_string((int)r) + ")");
  }

  void read_manifest(const std::string &path) {
    FILE *f = std::fopen(path.c_str(), "rb");
    if (!f) fail("cannot read " + path);
    char line[4096];
    std::string hex;
    while (std::fgets(line, sizeof line, f)) {
      std::string s(line);
      while (!s.empty() && (s.back() == '\n' || s.back() == '\r')) s.pop_back();
      if (s.size() >= 2 && s[0] == 'k' && s.find('\t') != std::string::npos) {
        size_t a = s.find('\t'), b = s.find('\t', a + 1);
        std::string key = s.substr(a + 1, b - a - 1);
        kernels_[key] = kernel_info{s.substr(0, a), (uint32_t)std::strtoul(s.c_str() + b + 1, nullptr, 10)};
      } else if (s.size() > 2 && s[0] == 'T' && s[1] == '\t') {
        stack_bytes_ = (uint32_t)std::strtoul(s.c_str() + 2, nullptr, 10);
      } else if (s.size() > 2 && s[0] == 'G' && s[1] == '\t') {
        subgroup_size_ = (uint32_t)std::strtoul(s.c_str() + 2, nullptr, 10);
      } else if (s.size() > 2 && s[0] == 'S' && s[1] == '\t') {
        size_t a = s.find('\t', 2);
        static_size_ = std::strtoull(s.c_str() + 2, nullptr, 10);
        hex = s.substr(a + 1);
      } else if (s.size() > 2 && s[0] == 'L' && s[1] == '\t') {
        static_local_ = std::strtoull(s.c_str() + 2, nullptr, 10);   // the work-group statics per group (absent: 0)
      } else if (s.size() > 2 && s[0] == 'R' && s[1] == '\t') {
        size_t a = s.find('\t', 2);
        relocs_.push_back({std::strtoull(s.c_str() + 2, nullptr, 10), std::strtoull(s.c_str() + a + 1, nullptr, 10)});
      }
    }
    std::fclose(f);
    static_hex_ = hex;
  }

  void init_device(const std::string &il_path) {
    // the device: the first Intel GPU, else the first GPU of any vendor
    cl_platform_id pl[8];
    cl_uint np = 0;
    check(clGetPlatformIDs(8, pl, &np), "clGetPlatformIDs");
    cl_device_id any = nullptr;
    cl_platform_id any_plat = nullptr;
    for (cl_uint p = 0; p < np && !dev_; p++) {
      cl_device_id ds[8];
      cl_uint nd = 0;
      if (clGetDeviceIDs(pl[p], CL_DEVICE_TYPE_GPU, 8, ds, &nd) != CL_SUCCESS) continue;
      for (cl_uint i = 0; i < nd && !dev_; i++) {
        char vendor[256];
        clGetDeviceInfo(ds[i], CL_DEVICE_VENDOR, sizeof vendor, vendor, nullptr);
        if (!any) { any = ds[i]; any_plat = pl[p]; }
        if (std::strstr(vendor, "Intel")) { dev_ = ds[i]; plat_ = pl[p]; }
      }
    }
    if (!dev_) { dev_ = any; plat_ = any_plat; }
    if (!dev_) fail("no OpenCL GPU device");
    char name[256];
    clGetDeviceInfo(dev_, CL_DEVICE_NAME, sizeof name, name, nullptr);
    device_name_ = name;
    cl_device_unified_shared_memory_capabilities_intel shared = 0;
    clGetDeviceInfo(dev_, CL_DEVICE_SINGLE_DEVICE_SHARED_MEM_CAPABILITIES_INTEL, sizeof shared, &shared, nullptr);
    if (!(shared & CL_UNIFIED_SHARED_MEMORY_ACCESS_INTEL) || !(shared & CL_UNIFIED_SHARED_MEMORY_ATOMIC_ACCESS_INTEL))
      fail(device_name_ + " has no shared USM with atomic access (the heap needs it: cl_intel_unified_shared_memory)");
    shared_alloc_ = (shared_alloc_fn)clGetExtensionFunctionAddressForPlatform(plat_, "clSharedMemAllocINTEL");
    set_arg_mem_ = (set_arg_mem_fn)clGetExtensionFunctionAddressForPlatform(plat_, "clSetKernelArgMemPointerINTEL");
    if (!shared_alloc_ || !set_arg_mem_) fail("cl_intel_unified_shared_memory entry points are not in the platform");
    clGetDeviceInfo(dev_, CL_DEVICE_MAX_WORK_GROUP_SIZE, sizeof max_wg_, &max_wg_, nullptr);
    clGetDeviceInfo(dev_, CL_DEVICE_MAX_WORK_ITEM_SIZES, sizeof max_wi_, max_wi_, nullptr);
    clGetDeviceInfo(dev_, CL_DEVICE_LOCAL_MEM_SIZE, sizeof local_mem_, &local_mem_, nullptr);
    cl_device_fp_config half_cfg = 0;
    clGetDeviceInfo(dev_, CL_DEVICE_HALF_FP_CONFIG, sizeof half_cfg, &half_cfg, nullptr);
    has_fp16_ = half_cfg != 0;

    cl_int e = CL_SUCCESS;
    ctx_ = clCreateContext(nullptr, 1, &dev_, nullptr, nullptr, &e);
    check(e, "clCreateContext");
    queue_ = clCreateCommandQueueWithProperties(ctx_, dev_, nullptr, &e);
    check(e, "clCreateCommandQueueWithProperties");

    // the heap
    heap_size_ = (std::getenv("NFCXX_SYCL_HEAP_MB") ? std::strtoull(std::getenv("NFCXX_SYCL_HEAP_MB"), nullptr, 10) : 1024) << 20;
    // the device may refuse a large shared allocation: halve the request until one fits (64 MB at least)
    void *p = nullptr;
    for (;;) {
      cl_int err = CL_SUCCESS;
      p = shared_alloc_(ctx_, dev_, nullptr, heap_size_, 16, &err);
      if (p && err == CL_SUCCESS) break;
      if (heap_size_ <= (64ull << 20)) fail("clSharedMemAllocINTEL of the heap failed (error " + std::to_string((int)err) + ")");
      heap_size_ /= 2;
    }
    host_ = (uint8_t *)p;
    dev_base_ = (uint64_t)(uintptr_t)host_;   // shared USM: the device sees the host address
    free_[8192] = heap_size_ - 8192;
    std::memset(host_, 0, 8192);

    // the module and its kernels (built per local size, see pipeline)
    std::FILE *f = std::fopen(il_path.c_str(), "rb");
    if (!f) fail("cannot read " + il_path);
    std::fseek(f, 0, SEEK_END);
    il_size_ = (size_t)std::ftell(f);
    std::rewind(f);
    il_.resize(il_size_);
    if (std::fread(il_.data(), 1, il_size_, f) != il_size_) fail("short read of " + il_path);
    std::fclose(f);

    // the statics: the constant tables and globals, relocated to device addresses
    if (static_size_) {
      statics_ = alloc(static_size_);
      std::vector<uint8_t> img(static_size_, 0);
      for (size_t i = 0; i + 1 < static_hex_.size() && i / 2 < img.size(); i += 2)
        img[i / 2] = (uint8_t)std::strtoul(static_hex_.substr(i, 2).c_str(), nullptr, 16);
      for (auto &r : relocs_) {
        uint64_t v = statics_ + r.second;
        std::memcpy(&img[r.first], &v, 8);
      }
      write(statics_, img.data(), img.size());
    }
  }

  void check_limits(const unsigned *l, unsigned lmem) const {
    uint64_t total = 1;
    for (int d = 0; d < 3; d++) {
      if (l[d] > max_wi_[d]) fail("a work-group of " + std::to_string(l[d]) + " work-items in one dimension; the device allows " + std::to_string(max_wi_[d]));
      total *= l[d];
    }
    if (total > max_wg_)
      fail("a work-group of " + std::to_string(total) + " work-items; the device allows " + std::to_string(max_wg_) + " (device::get_info<max_work_group_size>)");
    if (lmem + 1024 + static_local_ > local_mem_ && lmem > 0)
      fail(std::to_string(lmem) + " bytes of local memory; the device allows " + std::to_string(local_mem_));
    // a module that uses sub-groups runs them 16 lanes wide (its SubgroupSize execution mode): whole sub-groups only
    if (subgroup_size_ && total % subgroup_size_ != 0)
      fail("a work-group of " + std::to_string(total) + " work-items; the module's sub-groups have " + std::to_string(subgroup_size_) +
           " lanes, so the work-group size must be a multiple of " + std::to_string(subgroup_size_));
  }

  uint64_t closure_addr() const { return dev_base_ + cl_closure_at; }

  // The kernel of an entry point for a local size: a program per local size (the specialization constants set the size).
  cl_kernel kernel(const std::string &entry, const unsigned *l) {
    std::string k = entry + "/" + std::to_string(l[0]) + "/" + std::to_string(l[1]) + "/" + std::to_string(l[2]);
    auto it = kernels_obj_.find(k);
    if (it != kernels_obj_.end()) return it->second;
    cl_int e = CL_SUCCESS;
    cl_program prog = clCreateProgramWithIL(ctx_, il_.data(), il_size_, &e);
    check(e, "clCreateProgramWithIL");
    cl_uint sz[3] = {l[0], l[1], l[2]};
    for (cl_uint i = 0; i < 3; i++) check(clSetProgramSpecializationConstant(prog, i, sizeof(cl_uint), &sz[i]), "clSetProgramSpecializationConstant");
    e = clBuildProgram(prog, 1, &dev_, "", nullptr, nullptr);
    if (e != CL_SUCCESS) {
      size_t logn = 0;
      clGetProgramBuildInfo(prog, dev_, CL_PROGRAM_BUILD_LOG, 0, nullptr, &logn);
      std::vector<char> log(logn + 1, 0);
      clGetProgramBuildInfo(prog, dev_, CL_PROGRAM_BUILD_LOG, logn, log.data(), nullptr);
      fail("the OpenCL build failed (" + std::to_string((int)e) + "):\n" + log.data());
    }
    cl_kernel kern = clCreateKernel(prog, entry.c_str(), &e);
    check(e, "clCreateKernel");
    if (subgroup_size_) {
      // the driver must run this local size with the sub-group size the module asks for (16 lanes)
      size_t lsz[3] = {l[0], l[1], l[2]}, sg = 0;
      check(clGetKernelSubGroupInfo(kern, dev_, CL_KERNEL_MAX_SUB_GROUP_SIZE_FOR_NDRANGE, sizeof lsz, lsz, sizeof sg, &sg, nullptr),
            "clGetKernelSubGroupInfo");
      if (sg != subgroup_size_)
        fail("the device runs sub-groups of " + std::to_string(sg) + " lanes for this kernel; the module needs " + std::to_string(subgroup_size_));
    }
    clReleaseProgram(prog);
    kernels_obj_[k] = kern;
    return kern;
  }


 public:
  std::string device_name() const { return device_name_; }
  bool has_fp16() const { return has_fp16_; }

 private:
  // the USM entry points of cl_intel_unified_shared_memory (the ICD loader resolves them per platform)
  typedef void *(*shared_alloc_fn)(cl_context, cl_device_id, const void *properties, size_t, cl_uint, cl_int *errcode_ret);
  typedef cl_int (*set_arg_mem_fn)(cl_kernel, cl_uint, const void *);

  cl_platform_id plat_ = nullptr;
  cl_device_id dev_ = nullptr;
  shared_alloc_fn shared_alloc_ = nullptr;
  set_arg_mem_fn set_arg_mem_ = nullptr;
  cl_context ctx_ = nullptr;
  cl_command_queue queue_ = nullptr;
  std::string device_name_;
  size_t max_wg_ = 0;
  size_t max_wi_[3] = {0, 0, 0};
  cl_ulong local_mem_ = 0;
  bool has_fp16_ = false;
  std::vector<uint8_t> il_;
  size_t il_size_ = 0;
  uint8_t *host_ = nullptr;
  uint64_t dev_base_ = 0;
  uint64_t heap_size_ = 0;
  std::map<uint64_t, uint64_t> free_, used_;
  std::map<std::string, kernel_info> kernels_;
  std::map<std::string, cl_kernel> kernels_obj_;
  uint32_t stack_bytes_ = 0;
  uint32_t subgroup_size_ = 0;   // the sub-group size of the module's kernels (manifest line G), 0 when none uses sub-groups
  uint64_t static_size_ = 0, statics_ = 0;
  uint64_t static_local_ = 0;   // the work-group static bytes per group (manifest L)
  std::string static_hex_;
  std::vector<std::pair<uint64_t, uint64_t>> relocs_;
};

// ---- the backend functions declared in sycl.hpp (the same as rt_vulkan.hpp over the OpenCL runtime)
inline unsigned long backend_dev_offset(buffer_state &s) {
  if (s.dev == 0) {
    s.dev = cl_rt::get().alloc(s.bytes ? s.bytes : 4);
    s.dev_valid = false;
  }
  return s.dev;
}
inline void backend_sync_to_host(buffer_state &s) { cl_rt::get().sync_down(&s); }
inline void backend_release(buffer_state &s) {
  if (s.dev) { cl_rt::get().release(s.dev); s.dev = 0; }
}
inline void backend_dispatch(const char *key, const void *closure, unsigned closure_bytes, const unsigned *g, const unsigned *l,
                             unsigned lmem, buffer_use *uses, int nuses) {
  buffer_state *bufs[16];
  int modes[16];
  int n = 0;
  for (int i = 0; i < nuses && n < 16; i++) {
    buffer_state *s = uses[i].st;
    if (s->dev == 0) backend_dev_offset(*s);
    bufs[n] = s;
    modes[n] = (reads(uses[i].mode) ? 1 : 0) | (writes(uses[i].mode) ? 2 : 0);
    n++;
  }
  cl_rt::get().dispatch(key, closure, closure_bytes, g, l, lmem, bufs, n, modes);
}
inline void backend_wait() {}
inline void *backend_usm_alloc(unsigned long bytes, unsigned align, int kind) {
  (void)align;
  (void)kind;
  cl_rt &r = cl_rt::get();
  return (void *)r.at(r.alloc(bytes));
}
inline void backend_usm_free(void *p) {
  cl_rt &r = cl_rt::get();
  if (r.in_heap(p)) r.release(r.dev_of(p));
}
inline void backend_memcpy(void *dst, const void *src, unsigned long n) { std::memmove(dst, src, n); }
inline void backend_memset(void *p, int v, unsigned long n) { std::memset(p, v, n); }
inline bool backend_is_usm(const void *p) { return cl_rt::get().in_heap(p); }

}  // namespace detail
}  // namespace sycl

#endif
