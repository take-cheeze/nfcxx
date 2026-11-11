// Dawn setup shared by vecadd.cpp and bench.cpp: open the Intel Vulkan adapter (the Arc B60 under ANV, never the
// NVIDIA card that enumerates first) and build the shaders the checks and the benchmark dispatch.
#pragma once
#include <dawn/dawn_proc.h>
#include <dawn/native/DawnNative.h>
#include <dawn/webgpu_cpp.h>
#include <cstdio>
#include <string>

struct IntelGpu {
  wgpu::Instance instance;
  wgpu::Adapter adapter;
  wgpu::Device device;
};

// Opens the first Intel Vulkan adapter. Prints "no Intel Vulkan adapter" and returns false when there is none.
inline bool open_intel_gpu(IntelGpu &g) {
  // The native instance is deliberately never destroyed: destroying it in an exit-time static destructor runs after
  // libvulkan has torn down its loader and crashes in the Vulkan instance destructor. Wrappers take their own references.
  static dawn::native::Instance *native = new dawn::native::Instance;
  static bool procs_set = false;
  if (!procs_set) {
    DawnProcTable procs = dawn::native::GetProcs();
    dawnProcSetProcs(&procs);
    procs_set = true;
  }
  WGPUInstance ih = native->Get();
  wgpuInstanceAddRef(ih);
  g.instance = wgpu::Instance::Acquire(ih);

  WGPURequestAdapterOptions opts = {};
  opts.backendType = WGPUBackendType_Vulkan;
  auto adapters = native->EnumerateAdapters(&opts);
  for (auto &na : adapters) {
    WGPUAdapter ah = na.Get();
    wgpuAdapterAddRef(ah);
    wgpu::Adapter cand = wgpu::Adapter::Acquire(ah);
    wgpu::AdapterInfo info{};
    cand.GetInfo(&info);
    std::string dev(info.device.data, info.device.length);
    std::string desc(info.description.data, info.description.length);
    if (desc.find("Intel") == std::string::npos && dev.find("Arc") == std::string::npos) continue;
    g.adapter = cand;
    g.device = cand.CreateDevice();
    if (!g.device) {
      std::printf("no device on Intel adapter\n");
      return false;
    }
    std::printf("device: %s (%s, Vulkan)\n", dev.c_str(), desc.c_str());
    return true;
  }
  std::printf("no Intel Vulkan adapter\n");
  return false;
}

// Elementwise a + b (or a - b for the mutant check) over 128-wide workgroups with a bounds guard.
inline std::string vecadd_wgsl(bool mutant) {
  return std::string(R"(
@group(0) @binding(0) var<storage, read> a : array<f32>;
@group(0) @binding(1) var<storage, read> b : array<f32>;
@group(0) @binding(2) var<storage, read_write> c : array<f32>;
@compute @workgroup_size(128)
fn main(@builtin(global_invocation_id) gid : vec3<u32>) {
  let i = gid.x;
  if (i < arrayLength(&c)) { c[i] = a[i] )") + (mutant ? "-" : "+") + R"( b[i]; }
}
)";
}

// Small-dispatch kernel for the launch-overhead benchmark: one 64-thread workgroup, one thread touches one word.
// The OpenCL twin is opencl_bench.c (__kernel small, local size 64).
inline std::string small_wgsl() {
  return R"(
@group(0) @binding(0) var<storage, read_write> sink : array<f32>;
@compute @workgroup_size(64)
fn main(@builtin(local_invocation_index) li : u32) {
  if (li == 0u) { sink[0] = sink[0] + 1.0; }
}
)";
}

inline wgpu::ComputePipeline make_pipeline(wgpu::Device &d, const std::string &code) {
  wgpu::ShaderSourceWGSL wgsl{};
  wgsl.code = code.c_str();
  wgpu::ShaderModuleDescriptor smd{};
  smd.nextInChain = &wgsl;
  wgpu::ShaderModule mod = d.CreateShaderModule(&smd);
  wgpu::ComputePipelineDescriptor cpd{};
  cpd.compute.module = mod;
  cpd.compute.entryPoint = "main";
  return d.CreateComputePipeline(&cpd);
}
