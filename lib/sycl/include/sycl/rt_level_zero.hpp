// Level Zero runtime for lib/sycl: the backend functions of sycl.hpp over one immediate command list on an Intel GPU (the Arc
// B60 with the Intel compute driver; any GPU with shared USM that supports atomics). The kernels are the SPIR-V module of
// scripts/pathb-spirv-emit.rb --kernel-cl (PREFIX.cl.spv, with PREFIX.man beside it): one kernel per entry point, taking the
// push block as its one argument. This is rt_opencl.hpp over the Level Zero API (ze_api.h, libze_loader); the layout of the
// heap, the push block and the dispatch are the same.
//
// Memory. The heap is one shared USM allocation (zeMemAllocShared): the host and the device see it at the same addresses, so
// a device address is the host address (the identity case of rt_vulkan.hpp). The device must support atomic access to shared
// allocations (ZE_MEMORY_ACCESS_CAP_FLAG_ATOMIC); the runtime checks it. The allocator starts at 8192.
// The words the host writes or reads on every dispatch are in a separate host allocation (zeMemAllocHost, ctl_): the flag
// word at 0, the kernel's captured state at 256 (up to 4096 bytes) and the push block at 4352. The driver migrates a
// shared allocation as a whole when the host touches it, so with them in the heap every dispatch moved all of it to the
// host and back (0.4 ms per MB, 400 ms per dispatch with the 1 GB default).
//
// Dispatch. The local size is the module's specialization constants (ids 0, 1, 2, ze_module_constants_t), and the group size
// is set with zeKernelSetGroupSize. A module is built once per local size (the same cache as the OpenCL programs). Each
// dispatch is waited for before the next (zeCommandListHostSynchronize), and the flag is read after it.
//
// Images. Every TU built by scripts/sycl-build.sh registers its image; the runtime loads them all (rt_image.hpp), and each
// keeps its own statics. Environment: NFCXX_SYCL_IMAGE (a colon-separated list of prefixes in place of the registered ones).
#ifndef NFCXX_SYCL_RT_LEVEL_ZERO_HPP
#define NFCXX_SYCL_RT_LEVEL_ZERO_HPP

#include <level_zero/ze_api.h>

#include <algorithm>
#include <cstdint>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <iterator>
#include <map>
#include <string>
#include <vector>

#include "rt_image.hpp"
#include "rt_spirv_split.hpp"

namespace sycl {
namespace detail {

// The push block of scripts/pathb-spirv-emit.rb (PUSH_MEMBERS, natural alignment): the same struct as rt_opencl.hpp.
struct ze_push {
  uint64_t closure, statics, stack, local, flag;
  uint32_t gx, gy, gz, nx, ny, nz, stack_bytes, local_stride, local_user, ox, oy, oz;
  uint64_t hlo, hsize, dbase;
};
static_assert(sizeof(ze_push) == 112, "push block layout");
constexpr uint64_t ze_push_at = 4352;   // the push block's offset in the control block (ctl_)
constexpr uint64_t ze_closure_at = 256;

class ze_rt {
 public:
  static ze_rt &get() {
    static ze_rt r;
    return r;
  }

  // ---- heap (the same allocator as rt_opencl.hpp)
  // align: a power of two; the address (not only the offset) is a multiple of it. A block's skipped head stays free.
  uint64_t alloc(uint64_t bytes, uint64_t align = 16) {
    bytes = bytes ? (bytes + 15) & ~uint64_t(15) : 16;
    if (align < 16) align = 16;
    for (auto it = free_.begin(); it != free_.end(); ++it) {
      const uint64_t start = it->first, size = it->second;
      const uint64_t off = ((dev_base_ + start + align - 1) & ~(align - 1)) - dev_base_;
      if (off - start + bytes > size) continue;
      const uint64_t left = start + size - (off + bytes);
      free_.erase(it);
      if (off > start) free_[start] = off - start;
      if (left) free_[off + bytes] = left;
      used_[off] = bytes;
      return dev_base_ + off;
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
    std::memcpy(&flag, ctl_, 4);
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
    const image_kernel *it = images_.find(key);
    if (!it && load_images()) it = images_.find(key);
    if (!it) {
      std::fprintf(stderr, "sycl: no kernel for the closure type %s (the %d images have %d)\n", key.c_str(),
                   (int)images_.modules.size(), (int)images_.kernel_count());
      std::exit(3);
    }
    if (closure_bytes != it->closure_size && it->closure_size) {
      std::fprintf(stderr, "sycl: the closure of %s is %u bytes on the host but %u in the device pass (build with the same "
                   "compiler on both sides)\n", key.c_str(), closure_bytes, it->closure_size);
      std::exit(5);
    }
    if (closure_bytes > 4096) fail("the kernel's captured state is larger than 4096 bytes");
    const image_module &mod = images_.modules[it->module];
    const uint32_t stack_bytes = mod.stack_bytes;
    const uint64_t static_local = mod.static_local;
    check_limits(l, lmem, mod, it->subgroup_size);
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
    uint64_t stride = (uint64_t(lmem) + 1024 + static_local + 15) & ~uint64_t(15);
    // the stacks and the work-group memory of the grid: one slab when they fit the heap's largest free block, otherwise
    // several launches. A slab is a run of groups along the outermost dimension with more than one group (sd), with
    // every group below sd and one group of each dimension above it: consecutive groups in the linear group index (x
    // fastest). The emitter numbers stacks and local memory over the whole grid, group by group (the slab offset ox/oy/oz is in that
    // index), so each slab's bases are biased by the slab's first index and the region holds just the slab.
    uint64_t stack_total = invocations * stack_bytes;
    uint64_t room = largest_free();
    int sd = 0;
    for (int d = 2; d >= 0; d--) if (ng[d] > 1) { sd = d; break; }
    uint64_t inv_group = (uint64_t)l[0] * l[1] * l[2];
    uint64_t per_group = inv_group * stack_bytes + stride;
    // the groups in the dimensions below d: one group along d takes them all
    auto below = [&](int d) { uint64_t b = 1; for (int e = 0; e < d; e++) b *= ng[e]; return b; };
    // when even one group along sd does not fit (with all the groups below it), the slab moves to the next dimension
    // inward; the dimensions above it then run one group per launch
    if (stack_total + groups * stride > room)
      while (sd > 0 && below(sd) * per_group > room) sd--;
    uint64_t inner = below(sd);
    uint64_t outer = 1;   // the groups of the dimensions above sd, one per launch
    for (int e = sd + 1; e < 3; e++) outer *= ng[e];
    uint32_t per_launch = ng[sd];   // groups along sd in one launch
    if (stack_total + groups * stride > room) {
      uint64_t fit = room / (inner * per_group);
      per_launch = fit >= 1 ? (uint32_t)std::min<uint64_t>(fit, ng[sd]) : 1;
    }
    const uint64_t chunks = (ng[sd] + per_launch - 1) / per_launch;   // launches along sd for each group above it
    std::memset(ctl_, 0, 4);   // the flag
    std::memcpy(ctl_ + ze_closure_at, closure, closure_bytes);
    ze_kernel_handle_t k = kernel(it->entry, l, it->module, it->subgroup_size);
    for (uint64_t step = 0; step < outer * chunks; step++) {
      // og: the group of each dimension above sd (the linear group index puts x fastest, as the emitter does)
      const uint64_t above = step / chunks;
      uint32_t og[3] = {0, 0, 0};
      { uint64_t r = above; for (int e = sd + 1; e < 3; e++) { og[e] = (uint32_t)(r % ng[e]); r /= ng[e]; } }
      uint32_t s0 = (uint32_t)(step % chunks) * per_launch;
      uint32_t cnt = std::min(per_launch, ng[sd] - s0);
      uint64_t first_group = (above * ng[sd] + s0) * inner;
      uint64_t slab_groups = (uint64_t)cnt * inner;
      uint64_t slab_stack = slab_groups * inv_group * stack_bytes;
      uint64_t region = alloc(slab_stack + slab_groups * stride);
      ze_push p{};
      p.closure = closure_addr();
      p.statics = mod.statics;
      p.stack = region - first_group * inv_group * stack_bytes;   // biased: the slab's first invocation is at region
      p.local = region + slab_stack - first_group * stride;
      p.flag = (uint64_t)(uintptr_t)ctl_;
      p.hlo = (uint64_t)(uintptr_t)host_;
      p.hsize = heap_size_;
      p.dbase = dev_base_;
      p.gx = gs[0]; p.gy = gs[1]; p.gz = gs[2];
      p.nx = ng[0]; p.ny = ng[1]; p.nz = ng[2];
      p.stack_bytes = stack_bytes;
      p.local_stride = (uint32_t)stride;
      p.local_user = lmem;
      p.ox = 0; p.oy = 0; p.oz = 0;
      uint32_t *o[3] = {&p.ox, &p.oy, &p.oz};
      *o[sd] = s0;
      for (int e = sd + 1; e < 3; e++) *o[e] = og[e];
      std::memcpy(ctl_ + ze_push_at, &p, sizeof p);
      void *push = ctl_ + ze_push_at;
      check(zeKernelSetArgumentValue(k, 0, sizeof push, &push), "zeKernelSetArgumentValue");
      uint32_t ngs[3] = {ng[0], ng[1], ng[2]};
      ngs[sd] = cnt;
      for (int e = sd + 1; e < 3; e++) ngs[e] = 1;
      ze_group_count_t gc = {ngs[0], ngs[1], ngs[2]};
      check(zeCommandListAppendLaunchKernel(imm_, k, &gc, nullptr, 0, nullptr), "zeCommandListAppendLaunchKernel");
      check(zeCommandListAppendBarrier(imm_, nullptr, 0, nullptr), "zeCommandListAppendBarrier");
      check(zeCommandListHostSynchronize(imm_, UINT64_MAX), "zeCommandListHostSynchronize");
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

  std::string device_name() const { return device_name_; }
  bool has_fp16() const { return has_fp16_; }
  unsigned compute_units() const { return compute_units_ ? compute_units_ : 1; }

 private:
  ze_rt() {
    init_device();
    load_images();
  }

  [[noreturn]] void fail(const std::string &why) const {
    std::fprintf(stderr, "sycl: Level Zero runtime: %s\n", why.c_str());
    std::exit(70);
  }

  void check(ze_result_t r, const char *what) const {
    if (r != ZE_RESULT_SUCCESS) {
      char buf[32];
      std::snprintf(buf, sizeof buf, "0x%x", (unsigned)r);
      fail(std::string(what) + " failed (Level Zero error " + buf + ")");
    }
  }

  // the registered images not loaded yet: their statics go in the heap
  bool load_images() {
    return images_.load_pending([this](uint64_t n) { return alloc(n); },
                                [this](uint64_t a, const void *src, uint64_t n) { write(a, src, n); },
                                [this](const std::string &why) { fail(why); });
  }

  void init_device() {
    check(zeInit(0), "zeInit");
    uint32_t ndrv = 0;
    check(zeDriverGet(&ndrv, nullptr), "zeDriverGet");
    std::vector<ze_driver_handle_t> drivers(ndrv);
    check(zeDriverGet(&ndrv, drivers.data()), "zeDriverGet");
    // the device: the first Intel GPU, else the first GPU of any vendor
    ze_device_handle_t any = nullptr;
    ze_driver_handle_t any_drv = nullptr;
    for (uint32_t d = 0; d < ndrv && !dev_; d++) {
      uint32_t nd = 0;
      if (zeDeviceGet(drivers[d], &nd, nullptr) != ZE_RESULT_SUCCESS || nd == 0) continue;
      std::vector<ze_device_handle_t> ds(nd);
      if (zeDeviceGet(drivers[d], &nd, ds.data()) != ZE_RESULT_SUCCESS) continue;
      for (uint32_t i = 0; i < nd && !dev_; i++) {
        ze_device_properties_t p = {};
        p.stype = ZE_STRUCTURE_TYPE_DEVICE_PROPERTIES;
        if (zeDeviceGetProperties(ds[i], &p) != ZE_RESULT_SUCCESS || p.type != ZE_DEVICE_TYPE_GPU) continue;
        if (!any) { any = ds[i]; any_drv = drivers[d]; }
        if (p.vendorId == 0x8086) { dev_ = ds[i]; drv_ = drivers[d]; }
      }
    }
    if (!dev_) { dev_ = any; drv_ = any_drv; }
    if (!dev_) fail("no Level Zero GPU device");

    ze_device_properties_t props = {};
    props.stype = ZE_STRUCTURE_TYPE_DEVICE_PROPERTIES;
    check(zeDeviceGetProperties(dev_, &props), "zeDeviceGetProperties");
    device_name_ = props.name;
    compute_units_ = props.numSlices * props.numSubslicesPerSlice * props.numEUsPerSubslice;   // the EUs, as DPC++ counts them

    ze_device_compute_properties_t cp = {};
    cp.stype = ZE_STRUCTURE_TYPE_DEVICE_COMPUTE_PROPERTIES;
    check(zeDeviceGetComputeProperties(dev_, &cp), "zeDeviceGetComputeProperties");
    max_wg_ = cp.maxTotalGroupSize;
    max_wi_[0] = cp.maxGroupSizeX;
    max_wi_[1] = cp.maxGroupSizeY;
    max_wi_[2] = cp.maxGroupSizeZ;
    local_mem_ = cp.maxSharedLocalMemory;
    ze_device_module_properties_t mp = {};
    mp.stype = ZE_STRUCTURE_TYPE_DEVICE_MODULE_PROPERTIES;
    check(zeDeviceGetModuleProperties(dev_, &mp), "zeDeviceGetModuleProperties");
    has_fp16_ = (mp.flags & ZE_DEVICE_MODULE_FLAG_FP16) != 0;

    ze_device_memory_access_properties_t mem = {};
    mem.stype = ZE_STRUCTURE_TYPE_DEVICE_MEMORY_ACCESS_PROPERTIES;
    check(zeDeviceGetMemoryAccessProperties(dev_, &mem), "zeDeviceGetMemoryAccessProperties");
    const ze_memory_access_cap_flags_t need = ZE_MEMORY_ACCESS_CAP_FLAG_RW | ZE_MEMORY_ACCESS_CAP_FLAG_ATOMIC;
    if ((mem.sharedSingleDeviceAllocCapabilities & need) != need)
      fail(device_name_ + " has no shared USM with atomic access (the heap needs it)");

    ze_context_desc_t cdesc = {};
    cdesc.stype = ZE_STRUCTURE_TYPE_CONTEXT_DESC;
    check(zeContextCreate(drv_, &cdesc, &ctx_), "zeContextCreate");

    // the compute queue group of the device
    uint32_t ng = 0;
    check(zeDeviceGetCommandQueueGroupProperties(dev_, &ng, nullptr), "zeDeviceGetCommandQueueGroupProperties");
    std::vector<ze_command_queue_group_properties_t> groups(ng);
    for (auto &g : groups) g.stype = ZE_STRUCTURE_TYPE_COMMAND_QUEUE_GROUP_PROPERTIES;
    check(zeDeviceGetCommandQueueGroupProperties(dev_, &ng, groups.data()), "zeDeviceGetCommandQueueGroupProperties");
    uint32_t ordinal = ng;
    for (uint32_t i = 0; i < ng && ordinal == ng; i++)
      if (groups[i].flags & ZE_COMMAND_QUEUE_GROUP_PROPERTY_FLAG_COMPUTE) ordinal = i;
    if (ordinal == ng) fail("no compute queue group on " + device_name_);
    ze_command_queue_desc_t qdesc = {};
    qdesc.stype = ZE_STRUCTURE_TYPE_COMMAND_QUEUE_DESC;
    qdesc.ordinal = ordinal;
    qdesc.index = 0;
    qdesc.mode = ZE_COMMAND_QUEUE_MODE_SYNCHRONOUS;
    qdesc.priority = ZE_COMMAND_QUEUE_PRIORITY_NORMAL;
    check(zeCommandListCreateImmediate(ctx_, dev_, &qdesc, &imm_), "zeCommandListCreateImmediate");

    // the heap
    heap_size_ = (std::getenv("NFCXX_SYCL_HEAP_MB") ? std::strtoull(std::getenv("NFCXX_SYCL_HEAP_MB"), nullptr, 10) : 1024) << 20;
    ze_device_mem_alloc_desc_t dmem = {};
    dmem.stype = ZE_STRUCTURE_TYPE_DEVICE_MEM_ALLOC_DESC;
    ze_host_mem_alloc_desc_t hmem = {};
    hmem.stype = ZE_STRUCTURE_TYPE_HOST_MEM_ALLOC_DESC;
    // the device may refuse a large shared allocation: halve the request until one fits (64 MB at least)
    void *p = nullptr;
    for (;;) {
      ze_result_t r = zeMemAllocShared(ctx_, &dmem, &hmem, heap_size_, 16, dev_, &p);
      if (r == ZE_RESULT_SUCCESS && p) break;
      if (heap_size_ <= (64ull << 20)) {
        char buf[32];
        std::snprintf(buf, sizeof buf, "0x%x", (unsigned)r);
        fail(std::string("zeMemAllocShared of the heap failed (Level Zero error ") + buf + ")");
      }
      heap_size_ /= 2;
    }
    host_ = (uint8_t *)p;
    dev_base_ = (uint64_t)(uintptr_t)host_;   // shared USM: the device sees the host address
    free_[8192] = heap_size_ - 8192;
    std::memset(host_, 0, 8192);
    // the control block: host memory the device reads and writes over the bus, so touching it moves nothing
    void *c = nullptr;
    check(zeMemAllocHost(ctx_, &hmem, 8192, 64, &c), "zeMemAllocHost of the control block");
    ctl_ = (uint8_t *)c;
    std::memset(ctl_, 0, 8192);
  }

  void check_limits(const unsigned *l, unsigned lmem, const image_module &mod, uint32_t subgroup_size) const {
    uint64_t total = 1;
    for (int d = 0; d < 3; d++) {
      if (l[d] > max_wi_[d]) fail("a work-group of " + std::to_string(l[d]) + " work-items in one dimension; the device allows " + std::to_string(max_wi_[d]));
      total *= l[d];
    }
    if (total > max_wg_)
      fail("a work-group of " + std::to_string(total) + " work-items; the device allows " + std::to_string(max_wg_) + " (device::get_info<max_work_group_size>)");
    // a kernel that uses sub-group shuffles runs them 16 lanes wide (its SubgroupSize execution mode): whole sub-groups only,
    // since a shuffle or a reduction over a partial sub-group would read lanes that are not there
    if (subgroup_size && total % subgroup_size != 0)
      fail("a work-group of " + std::to_string(total) + " work-items; the kernel's sub-groups have " + std::to_string(subgroup_size) +
           " lanes, so the work-group size must be a multiple of " + std::to_string(subgroup_size));
    if (lmem + 1024 + mod.static_local > local_mem_ && lmem > 0)
      fail(std::to_string(lmem) + " bytes of local memory; the device allows " + std::to_string(local_mem_));
  }

  uint64_t closure_addr() const { return (uint64_t)(uintptr_t)(ctl_ + ze_closure_at); }

  // The SPIR-V of one entry point of an image (rt_spirv_split.hpp: the driver then compiles that kernel alone), kept per image.
  const std::vector<uint32_t> &entry_il(const std::string &entry, size_t m) {
    std::string k = std::to_string(m) + "/" + entry;
    auto it = entry_il_.find(k);
    if (it != entry_il_.end()) return it->second;
    const image_module &img = images_.modules[m];
    std::vector<uint32_t> il = detail::spirv_entry_module(img.il.data(), img.il.size(), entry);
    if (il.empty()) fail("the image has no entry point " + entry);
    return entry_il_[k] = std::move(il);
  }

  // The module of an entry point of an image for a local size: one module per kernel and local size (the specialization
  // constants set the size).
  ze_module_handle_t module(const std::string &entry, const unsigned *l, size_t m) {
    std::string k = std::to_string(m) + "/" + entry + "/" + std::to_string(l[0]) + "/" + std::to_string(l[1]) + "/" + std::to_string(l[2]);
    auto it = modules_.find(k);
    if (it != modules_.end()) return it->second;
    const std::vector<uint32_t> &il = entry_il(entry, m);
    uint32_t ids[3] = {0, 1, 2};
    uint32_t vals[3] = {l[0], l[1], l[2]};
    const void *ptrs[3] = {&vals[0], &vals[1], &vals[2]};
    ze_module_constants_t consts = {};
    consts.numConstants = 3;
    consts.pConstantIds = ids;
    consts.pConstantValues = ptrs;
    ze_module_desc_t desc = {};
    desc.stype = ZE_STRUCTURE_TYPE_MODULE_DESC;
    desc.format = ZE_MODULE_FORMAT_IL_SPIRV;
    desc.inputSize = il.size() * 4;
    desc.pInputModule = reinterpret_cast<const uint8_t *>(il.data());
    desc.pBuildFlags = "";
    desc.pConstants = &consts;
    ze_module_handle_t mod = nullptr;
    ze_module_build_log_handle_t log = nullptr;
    ze_result_t r = zeModuleCreate(ctx_, dev_, &desc, &mod, &log);
    if (r != ZE_RESULT_SUCCESS) {
      std::string text;
      if (log) {
        size_t n = 0;
        zeModuleBuildLogGetString(log, &n, nullptr);
        std::vector<char> buf(n + 1, 0);
        zeModuleBuildLogGetString(log, &n, buf.data());
        text = buf.data();
      }
      char code[32];
      std::snprintf(code, sizeof code, "0x%x", (unsigned)r);
      fail("the Level Zero module build failed (" + std::string(code) + "):\n" + text);
    }
    modules_[k] = mod;
    return mod;
  }

  // The kernel of an entry point of an image for a local size.
  ze_kernel_handle_t kernel(const std::string &entry, const unsigned *l, size_t m, uint32_t subgroup_size) {
    std::string k = std::to_string(m) + "/" + entry + "/" + std::to_string(l[0]) + "/" + std::to_string(l[1]) + "/" + std::to_string(l[2]);
    auto it = kernels_obj_.find(k);
    if (it != kernels_obj_.end()) return it->second;
    ze_kernel_desc_t kd = {};
    kd.stype = ZE_STRUCTURE_TYPE_KERNEL_DESC;
    kd.pKernelName = entry.c_str();
    ze_kernel_handle_t kern = nullptr;
    check(zeKernelCreate(module(entry, l, m), &kd, &kern), "zeKernelCreate");
    check(zeKernelSetGroupSize(kern, l[0], l[1], l[2]), "zeKernelSetGroupSize");
    // the kernel's only argument is the push block in the control block; the heap (stacks, the closure's USM pointers,
    // the statics) is reached through pointers, so the driver is told to keep the shared allocations resident
    check(zeKernelSetIndirectAccess(kern, ZE_KERNEL_INDIRECT_ACCESS_FLAG_SHARED | ZE_KERNEL_INDIRECT_ACCESS_FLAG_HOST |
                                              ZE_KERNEL_INDIRECT_ACCESS_FLAG_DEVICE),
          "zeKernelSetIndirectAccess");
    if (subgroup_size) {
      // the kernel must be compiled for the sub-group size it asks for (its SubgroupSize execution mode)
      ze_kernel_properties_t kp = {};
      kp.stype = ZE_STRUCTURE_TYPE_KERNEL_PROPERTIES;
      check(zeKernelGetProperties(kern, &kp), "zeKernelGetProperties");
      if (kp.requiredSubgroupSize != subgroup_size)
        fail("the kernel requires sub-groups of " + std::to_string(kp.requiredSubgroupSize) + " lanes; it needs " +
             std::to_string(subgroup_size));
    }
    kernels_obj_[k] = kern;
    return kern;
  }

  ze_driver_handle_t drv_ = nullptr;
  ze_device_handle_t dev_ = nullptr;
  ze_context_handle_t ctx_ = nullptr;
  ze_command_list_handle_t imm_ = nullptr;
  std::string device_name_;
  uint32_t compute_units_ = 0;
  uint32_t max_wg_ = 0;
  uint32_t max_wi_[3] = {0, 0, 0};
  uint32_t local_mem_ = 0;
  bool has_fp16_ = false;
  uint8_t *host_ = nullptr;
  uint8_t *ctl_ = nullptr;   // the flag, the captured state and the push block (see Memory above)
  uint64_t dev_base_ = 0;
  uint64_t heap_size_ = 0;
  std::map<uint64_t, uint64_t> free_, used_;
  image_set images_;
  std::map<std::string, ze_module_handle_t> modules_;
  std::map<std::string, std::vector<uint32_t>> entry_il_;   // image/entry => the entry point's module
  std::map<std::string, ze_kernel_handle_t> kernels_obj_;
};

// ---- the backend functions declared in sycl.hpp (the same as rt_opencl.hpp over the Level Zero runtime)
inline unsigned long backend_dev_offset(buffer_state &s) {
  if (s.dev == 0) {
    s.dev = ze_rt::get().alloc(s.bytes ? s.bytes : 4);
    s.dev_valid = false;
  }
  return s.dev;
}
inline void backend_sync_to_host(buffer_state &s) { ze_rt::get().sync_down(&s); }
inline void backend_release(buffer_state &s) {
  if (s.dev) { ze_rt::get().release(s.dev); s.dev = 0; }
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
  ze_rt::get().dispatch(key, closure, closure_bytes, g, l, lmem, bufs, n, modes);
}
inline void backend_wait() {}
inline void *backend_usm_alloc(unsigned long bytes, unsigned align, int kind) {
  (void)kind;
  ze_rt &r = ze_rt::get();
  return (void *)r.at(r.alloc(bytes, align));
}
inline void backend_usm_free(void *p) {
  ze_rt &r = ze_rt::get();
  if (r.in_heap(p)) r.release(r.dev_of(p));
}
inline void backend_memcpy(void *dst, const void *src, unsigned long n) { std::memmove(dst, src, n); }
inline void backend_memset(void *p, int v, unsigned long n) { std::memset(p, v, n); }
inline bool backend_is_usm(const void *p) { return ze_rt::get().in_heap(p); }

}  // namespace detail
}  // namespace sycl

#endif
