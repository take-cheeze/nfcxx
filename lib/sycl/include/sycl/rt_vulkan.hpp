// Vulkan runtime for lib/sycl: the backend functions of sycl.hpp over one compute queue. The kernels are the SPIR-V module of
// scripts/pathb-spirv-emit.rb (PREFIX.spv, with PREFIX.man beside it); the buffers, the closures, the statics, the
// per-invocation stacks and the work-group memory are all in one device-local heap, addressed by 64-bit device addresses
// (VK_KHR_buffer_device_address, which Vulkan 1.2 has in core).
//
// Memory. The heap is host-visible and coherent, so the host reads and writes it through a mapping. A device address and
// the mapping's address are the same number on some implementations (lavapipe is one); then a USM pointer is valid on both
// sides and kernels may capture it, which is what the USM tests need. On other implementations USM is refused (SYCL buffers
// and accessors work everywhere: they only need device addresses, which the runtime gets from the driver).
//
// Dispatch. Each dispatch is submitted and waited for before the next (an in-order queue, the simple way). The flag word at
// the start of the heap holds the first failed check's code; it is read after every dispatch.
//
// Environment: NFCXX_SYCL_IMAGE (the prefix; defaults to the NFCXX_SYCL_IMAGE_PREFIX macro of the build).
#ifndef NFCXX_SYCL_RT_VULKAN_HPP
#define NFCXX_SYCL_RT_VULKAN_HPP

#include <vulkan/vulkan.h>

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

// The push constant block of scripts/pathb-spirv-emit.rb (PUSH_MEMBERS): offsets as the SPIR-V module has them.
struct vk_push {
  uint64_t closure, statics, stack, local, flag;
  uint32_t gx, gy, gz, nx, ny, nz, stack_bytes, local_stride, local_user, ox, oy, oz;
};
static_assert(sizeof(vk_push) == 88, "push block layout");
constexpr uint32_t vk_push_size = 88;

class vk_rt {
 public:
  static vk_rt &get() {
    static vk_rt r;
    return r;
  }

  // ---- heap
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
    // coalesce neighbours
    auto nx = free_.find(off + n);
    if (nx != free_.end()) { free_[off] += nx->second; free_.erase(nx); }
    auto it = free_.find(off);
    if (it != free_.begin()) {
      auto pv = std::prev(it);
      if (pv->first + pv->second == it->first) { pv->second += it->second; free_.erase(it); }
    }
  }
  uint8_t *at(uint64_t addr) const {
    if (addr < dev_base_ || addr - dev_base_ >= heap_size_) fail("device address outside the heap");
    return host_ + (addr - dev_base_);
  }
  bool in_heap(const void *p) const {
    uint64_t a = (uint64_t)(uintptr_t)p;
    return a >= dev_base_ && a - dev_base_ < heap_size_;
  }
  bool identity() const { return identity_; }
  uint64_t dev_base() const { return dev_base_; }

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
    check_limits(g, l, lmem);
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
    // a grid with more groups in a dimension than the device takes is submitted in slices, each starting at its first group
    uint32_t lim[3];
    for (int d = 0; d < 3; d++) lim[d] = limits_.maxComputeWorkGroupCount[d];
    uint64_t stride = (uint64_t(lmem) + 1024 + 15) & ~uint64_t(15);
    uint64_t stack_total = invocations * stack_bytes_;
    uint64_t region = alloc(stack_total + groups * stride);
    std::memset(at(dev_base_ + 0), 0, 4);   // the flag
    std::memcpy(at(closure_addr()), closure, closure_bytes);
    vk_push p{};
    p.closure = closure_addr();
    p.statics = statics_;
    p.stack = region;
    p.local = region + stack_total;
    p.flag = dev_base_;
    p.gx = gs[0]; p.gy = gs[1]; p.gz = gs[2];
    p.nx = ng[0]; p.ny = ng[1]; p.nz = ng[2];
    p.stack_bytes = stack_bytes_;
    p.local_stride = (uint32_t)stride;
    p.local_user = lmem;
    VkPipeline pipe = pipeline(it->second.entry, l);
    for (uint32_t oz = 0; oz < ng[2]; oz += lim[2])
      for (uint32_t oy = 0; oy < ng[1]; oy += lim[1])
        for (uint32_t ox = 0; ox < ng[0]; ox += lim[0]) {
          p.ox = ox;
          p.oy = oy;
          p.oz = oz;
          uint32_t cnt[3] = {std::min(lim[0], ng[0] - ox), std::min(lim[1], ng[1] - oy), std::min(lim[2], ng[2] - oz)};
          submit(pipe, &p, cnt);
        }
    release(region);
    uint32_t flag = 0;
    std::memcpy(&flag, at(dev_base_), 4);
    if (flag) {
      static const char *why[] = {"", "integer division by zero or INT_MIN / -1", "shift count out of range", "index out of bounds",
                                  "null pointer dereference", "trap or unreachable", "float to integer conversion out of range",
                                  "a write to the kernel's captured state"};
      std::fprintf(stderr, "sycl: a kernel trapped: %s\n", flag < 8 ? why[flag] : "unknown");
      std::exit(71);
    }
    for (int i = 0; i < nbufs; i++) if (modes[i] & 2) { bufs[i]->dev_valid = true; bufs[i]->host_valid = false; }
  }

  // ---- buffer copies: the device copy is valid after a kernel that writes it; the host copy after a read
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

  bool usm_ok() const { return identity_; }

 private:
  struct kernel_info {
    std::string entry;
    uint32_t closure_size;
  };

  vk_rt() {
    const char *prefix = std::getenv("NFCXX_SYCL_IMAGE");
#ifdef NFCXX_SYCL_IMAGE_PREFIX
    if (!prefix) prefix = NFCXX_SYCL_IMAGE_PREFIX;
#endif
    if (!prefix) fail("set NFCXX_SYCL_IMAGE (see scripts/sycl-build.sh)");
    read_manifest(std::string(prefix) + ".man");
    init_device(std::string(prefix) + ".spv");
  }

  [[noreturn]] void fail(const std::string &why) const {
    std::fprintf(stderr, "sycl: Vulkan runtime: %s\n", why.c_str());
    std::exit(70);
  }

  void check(VkResult r, const char *what) const {
    if (r != VK_SUCCESS) fail(std::string(what) + " failed (VkResult " + std::to_string((int)r) + ")");
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
      } else if (s.size() > 2 && s[0] == 'S' && s[1] == '\t') {
        size_t a = s.find('\t', 2);
        static_size_ = std::strtoull(s.c_str() + 2, nullptr, 10);
        hex = s.substr(a + 1);
      } else if (s.size() > 2 && s[0] == 'R' && s[1] == '\t') {
        size_t a = s.find('\t', 2);
        relocs_.push_back({std::strtoull(s.c_str() + 2, nullptr, 10), std::strtoull(s.c_str() + a + 1, nullptr, 10)});
      }
    }
    std::fclose(f);
    static_hex_ = hex;
  }

  void init_device(const std::string &spv_path) {
    VkApplicationInfo app{VK_STRUCTURE_TYPE_APPLICATION_INFO};
    app.apiVersion = VK_API_VERSION_1_2;
    VkInstanceCreateInfo ici{VK_STRUCTURE_TYPE_INSTANCE_CREATE_INFO};
    ici.pApplicationInfo = &app;
    check(vkCreateInstance(&ici, nullptr, &inst_), "vkCreateInstance");
    uint32_t n = 0;
    vkEnumeratePhysicalDevices(inst_, &n, nullptr);
    if (n == 0) fail("no Vulkan device");
    std::vector<VkPhysicalDevice> pds(n);
    vkEnumeratePhysicalDevices(inst_, &n, pds.data());
    pd_ = pds[0];
    uint32_t qn = 0;
    vkGetPhysicalDeviceQueueFamilyProperties(pd_, &qn, nullptr);
    std::vector<VkQueueFamilyProperties> qp(qn);
    vkGetPhysicalDeviceQueueFamilyProperties(pd_, &qn, qp.data());
    qf_ = qn;
    for (uint32_t i = 0; i < qn; i++)
      if (qp[i].queueFlags & VK_QUEUE_COMPUTE_BIT) { qf_ = i; break; }
    if (qf_ == qn) fail("no compute queue");
    VkPhysicalDeviceProperties props;
    vkGetPhysicalDeviceProperties(pd_, &props);
    limits_ = props.limits;
    device_name_ = props.deviceName;

    VkPhysicalDeviceVulkan12Features f12{VK_STRUCTURE_TYPE_PHYSICAL_DEVICE_VULKAN_1_2_FEATURES};
    f12.bufferDeviceAddress = VK_TRUE;
    f12.vulkanMemoryModel = VK_TRUE;
    f12.vulkanMemoryModelDeviceScope = VK_TRUE;
    VkPhysicalDeviceFeatures2 f2{VK_STRUCTURE_TYPE_PHYSICAL_DEVICE_FEATURES_2};
    f2.pNext = &f12;
    f2.features.shaderInt64 = VK_TRUE;
    f2.features.shaderFloat64 = VK_TRUE;
    float prio = 1.0f;
    VkDeviceQueueCreateInfo qci{VK_STRUCTURE_TYPE_DEVICE_QUEUE_CREATE_INFO};
    qci.queueFamilyIndex = qf_;
    qci.queueCount = 1;
    qci.pQueuePriorities = &prio;
    VkDeviceCreateInfo dci{VK_STRUCTURE_TYPE_DEVICE_CREATE_INFO};
    dci.pNext = &f2;
    dci.queueCreateInfoCount = 1;
    dci.pQueueCreateInfos = &qci;
    check(vkCreateDevice(pd_, &dci, nullptr, &dev_), "vkCreateDevice (needs bufferDeviceAddress, Int64, Float64, the Vulkan memory model)");
    vkGetDeviceQueue(dev_, qf_, 0, &queue_);

    // the heap
    heap_size_ = (std::getenv("NFCXX_SYCL_HEAP_MB") ? std::strtoull(std::getenv("NFCXX_SYCL_HEAP_MB"), nullptr, 10) : 1024) << 20;
    VkBufferCreateInfo bci{VK_STRUCTURE_TYPE_BUFFER_CREATE_INFO};
    bci.size = heap_size_;
    bci.usage = VK_BUFFER_USAGE_STORAGE_BUFFER_BIT | VK_BUFFER_USAGE_SHADER_DEVICE_ADDRESS_BIT |
                VK_BUFFER_USAGE_TRANSFER_SRC_BIT | VK_BUFFER_USAGE_TRANSFER_DST_BIT;
    bci.sharingMode = VK_SHARING_MODE_EXCLUSIVE;
    check(vkCreateBuffer(dev_, &bci, nullptr, &heap_buf_), "vkCreateBuffer");
    VkMemoryRequirements mr;
    vkGetBufferMemoryRequirements(dev_, heap_buf_, &mr);
    VkPhysicalDeviceMemoryProperties mp;
    vkGetPhysicalDeviceMemoryProperties(pd_, &mp);
    const VkMemoryPropertyFlags want = VK_MEMORY_PROPERTY_HOST_VISIBLE_BIT | VK_MEMORY_PROPERTY_HOST_COHERENT_BIT;
    int mt = -1;
    for (uint32_t i = 0; i < mp.memoryTypeCount; i++)
      if ((mr.memoryTypeBits & (1u << i)) && (mp.memoryTypes[i].propertyFlags & want) == want) { mt = (int)i; break; }
    if (mt < 0) fail("no host-visible coherent memory for the heap");
    VkMemoryAllocateFlagsInfo mfi{VK_STRUCTURE_TYPE_MEMORY_ALLOCATE_FLAGS_INFO};
    mfi.flags = VK_MEMORY_ALLOCATE_DEVICE_ADDRESS_BIT;
    VkMemoryAllocateInfo mai{VK_STRUCTURE_TYPE_MEMORY_ALLOCATE_INFO};
    mai.pNext = &mfi;
    mai.allocationSize = mr.size;
    mai.memoryTypeIndex = (uint32_t)mt;
    check(vkAllocateMemory(dev_, &mai, nullptr, &heap_mem_), "vkAllocateMemory (heap)");
    check(vkBindBufferMemory(dev_, heap_buf_, heap_mem_, 0), "vkBindBufferMemory");
    void *p = nullptr;
    check(vkMapMemory(dev_, heap_mem_, 0, VK_WHOLE_SIZE, 0, &p), "vkMapMemory");
    host_ = (uint8_t *)p;
    VkBufferDeviceAddressInfo bi{VK_STRUCTURE_TYPE_BUFFER_DEVICE_ADDRESS_INFO};
    bi.buffer = heap_buf_;
    dev_base_ = vkGetBufferDeviceAddress(dev_, &bi);
    identity_ = dev_base_ == (uint64_t)(uintptr_t)host_;
    free_[8192] = heap_size_ - 8192;   // [0, 8192): the flag at 0, the closure slot at 256

    // the module and the layout
    std::FILE *f = std::fopen(spv_path.c_str(), "rb");
    if (!f) fail("cannot read " + spv_path);
    std::vector<uint32_t> words;
    uint32_t w;
    while (std::fread(&w, 4, 1, f) == 1) words.push_back(w);
    std::fclose(f);
    VkShaderModuleCreateInfo smci{VK_STRUCTURE_TYPE_SHADER_MODULE_CREATE_INFO};
    smci.codeSize = words.size() * 4;
    smci.pCode = words.data();
    check(vkCreateShaderModule(dev_, &smci, nullptr, &module_), "vkCreateShaderModule");
    VkPushConstantRange pcr{VK_SHADER_STAGE_COMPUTE_BIT, 0, vk_push_size};
    VkPipelineLayoutCreateInfo plci{VK_STRUCTURE_TYPE_PIPELINE_LAYOUT_CREATE_INFO};
    plci.pushConstantRangeCount = 1;
    plci.pPushConstantRanges = &pcr;
    check(vkCreatePipelineLayout(dev_, &plci, nullptr, &layout_), "vkCreatePipelineLayout");
    VkCommandPoolCreateInfo cpci{VK_STRUCTURE_TYPE_COMMAND_POOL_CREATE_INFO};
    cpci.queueFamilyIndex = qf_;
    check(vkCreateCommandPool(dev_, &cpci, nullptr, &pool_), "vkCreateCommandPool");
    VkFenceCreateInfo fci{VK_STRUCTURE_TYPE_FENCE_CREATE_INFO};
    check(vkCreateFence(dev_, &fci, nullptr, &fence_), "vkCreateFence");

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

  void check_limits(const unsigned *g, const unsigned *l, unsigned lmem) const {
    uint64_t total = 1;
    for (int d = 0; d < 3; d++) {
      if (l[d] > limits_.maxComputeWorkGroupSize[d]) fail("a work-group of " + std::to_string(l[d]) + " work-items in one dimension; the device allows " + std::to_string(limits_.maxComputeWorkGroupSize[d]));
      total *= l[d];
    }
    if (total > limits_.maxComputeWorkGroupInvocations)
      fail("a work-group of " + std::to_string(total) + " work-items; the device allows " + std::to_string(limits_.maxComputeWorkGroupInvocations) + " (device::get_info<max_work_group_size>)");
    if (lmem + 1024 > limits_.maxComputeSharedMemorySize && lmem > 0)
      fail(std::to_string(lmem) + " bytes of local memory; the device allows " + std::to_string(limits_.maxComputeSharedMemorySize));
  }

  uint64_t closure_addr() const { return dev_base_ + 256; }

  VkPipeline pipeline(const std::string &entry, const unsigned *l) {
    std::string k = entry + "/" + std::to_string(l[0]) + "/" + std::to_string(l[1]) + "/" + std::to_string(l[2]);
    auto it = pipes_.find(k);
    if (it != pipes_.end()) return it->second;
    uint32_t sv[3] = {l[0], l[1], l[2]};
    VkSpecializationMapEntry me[3];
    for (uint32_t i = 0; i < 3; i++) me[i] = VkSpecializationMapEntry{i, i * 4, 4};
    VkSpecializationInfo si{3, me, sizeof sv, sv};
    VkComputePipelineCreateInfo cpci{VK_STRUCTURE_TYPE_COMPUTE_PIPELINE_CREATE_INFO};
    cpci.stage.sType = VK_STRUCTURE_TYPE_PIPELINE_SHADER_STAGE_CREATE_INFO;
    cpci.stage.stage = VK_SHADER_STAGE_COMPUTE_BIT;
    cpci.stage.module = module_;
    cpci.stage.pName = entry.c_str();
    cpci.stage.pSpecializationInfo = &si;
    cpci.layout = layout_;
    VkPipeline p;
    check(vkCreateComputePipelines(dev_, VK_NULL_HANDLE, 1, &cpci, nullptr, &p), "vkCreateComputePipelines");
    pipes_[k] = p;
    return p;
  }

  void submit(VkPipeline pipe, const vk_push *p, const uint32_t *ng) {
    VkCommandBufferAllocateInfo cbai{VK_STRUCTURE_TYPE_COMMAND_BUFFER_ALLOCATE_INFO};
    cbai.commandPool = pool_;
    cbai.level = VK_COMMAND_BUFFER_LEVEL_PRIMARY;
    cbai.commandBufferCount = 1;
    VkCommandBuffer cb;
    check(vkAllocateCommandBuffers(dev_, &cbai, &cb), "vkAllocateCommandBuffers");
    VkCommandBufferBeginInfo bbi{VK_STRUCTURE_TYPE_COMMAND_BUFFER_BEGIN_INFO};
    bbi.flags = VK_COMMAND_BUFFER_USAGE_ONE_TIME_SUBMIT_BIT;
    vkBeginCommandBuffer(cb, &bbi);
    vkCmdBindPipeline(cb, VK_PIPELINE_BIND_POINT_COMPUTE, pipe);
    vkCmdPushConstants(cb, layout_, VK_SHADER_STAGE_COMPUTE_BIT, 0, sizeof *p, p);
    vkCmdDispatch(cb, ng[0], ng[1], ng[2]);
    vkEndCommandBuffer(cb);
    VkSubmitInfo si{VK_STRUCTURE_TYPE_SUBMIT_INFO};
    si.commandBufferCount = 1;
    si.pCommandBuffers = &cb;
    check(vkQueueSubmit(queue_, 1, &si, fence_), "vkQueueSubmit");
    check(vkWaitForFences(dev_, 1, &fence_, VK_TRUE, UINT64_MAX), "vkWaitForFences");
    vkResetFences(dev_, 1, &fence_);
    vkFreeCommandBuffers(dev_, pool_, 1, &cb);
  }

 public:
  std::string device_name() const { return device_name_; }
  bool identity_ = false;

 private:
  VkInstance inst_ = VK_NULL_HANDLE;
  VkPhysicalDevice pd_ = VK_NULL_HANDLE;
  VkDevice dev_ = VK_NULL_HANDLE;
  VkQueue queue_ = VK_NULL_HANDLE;
  uint32_t qf_ = 0;
  VkBuffer heap_buf_ = VK_NULL_HANDLE;
  VkDeviceMemory heap_mem_ = VK_NULL_HANDLE;
  VkShaderModule module_ = VK_NULL_HANDLE;
  VkPipelineLayout layout_ = VK_NULL_HANDLE;
  VkCommandPool pool_ = VK_NULL_HANDLE;
  VkFence fence_ = VK_NULL_HANDLE;
  VkPhysicalDeviceLimits limits_{};
  std::string device_name_;
  uint8_t *host_ = nullptr;
  uint64_t dev_base_ = 0;
  uint64_t heap_size_ = 0;
  std::map<uint64_t, uint64_t> free_, used_;
  std::map<std::string, kernel_info> kernels_;
  std::map<std::string, VkPipeline> pipes_;
  uint32_t stack_bytes_ = 0;
  uint64_t static_size_ = 0, statics_ = 0;
  std::string static_hex_;
  std::vector<std::pair<uint64_t, uint64_t>> relocs_;
};

// ---- the backend functions declared in sycl.hpp
inline unsigned long backend_dev_offset(buffer_state &s) {
  if (s.dev == 0) {
    s.dev = vk_rt::get().alloc(s.bytes ? s.bytes : 4);
    s.dev_valid = false;
  }
  return s.dev;
}
inline void backend_sync_to_host(buffer_state &s) { vk_rt::get().sync_down(&s); }
inline void backend_release(buffer_state &s) {
  if (s.dev) { vk_rt::get().release(s.dev); s.dev = 0; }
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
  vk_rt::get().dispatch(key, closure, closure_bytes, g, l, lmem, bufs, n, modes);
}
inline void backend_wait() {}
inline void *backend_usm_alloc(unsigned long bytes, unsigned align, int kind) {
  (void)align;
  (void)kind;
  vk_rt &r = vk_rt::get();
  if (!r.identity()) {
    throw exception(errc::feature_not_supported,
                    "sycl: USM pointers need the device address to equal the host address; this Vulkan device does not give that "
                    "(SYCL buffers and accessors work)");
  }
  return (void *)(uintptr_t)r.alloc(bytes);
}
inline void backend_usm_free(void *p) { vk_rt::get().release((uint64_t)(uintptr_t)p); }
inline void backend_memcpy(void *dst, const void *src, unsigned long n) { std::memmove(dst, src, n); }
inline void backend_memset(void *p, int v, unsigned long n) { std::memset(p, v, n); }
inline bool backend_is_usm(const void *p) { return vk_rt::get().in_heap(p); }

}  // namespace detail
}  // namespace sycl

#endif
