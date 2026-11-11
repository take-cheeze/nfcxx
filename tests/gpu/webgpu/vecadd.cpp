// WebGPU (Dawn, Vulkan) vector add on the Intel Arc B60: a[i] + b[i] over 50000 floats, read back and compared.
// Prints "mismatches: M of N" and exits 0 only when every element matches. With --mutant the shader computes a - b,
// which must be reported as mismatches (run.sh checks that). Exit 2 when there is no Intel Vulkan adapter.
#include "common.h"
#include <cstring>
#include <vector>

int main(int argc, char **argv) {
  const bool mutant = argc > 1 && std::strcmp(argv[1], "--mutant") == 0;
  const uint32_t n = 50000;

  IntelGpu g;
  if (!open_intel_gpu(g)) return 2;
  wgpu::Device device = g.device;

  std::vector<float> a(n), b(n);
  for (uint32_t i = 0; i < n; i++) { a[i] = (float)i; b[i] = 2.0f * (float)i; }
  const uint64_t bytes = n * sizeof(float);
  auto mk = [&](wgpu::BufferUsage u, const void *src) {
    wgpu::BufferDescriptor d{};
    d.size = bytes;
    d.usage = u;
    d.mappedAtCreation = src != nullptr;
    wgpu::Buffer buf = device.CreateBuffer(&d);
    if (src) { std::memcpy(buf.GetMappedRange(), src, bytes); buf.Unmap(); }
    return buf;
  };
  wgpu::Buffer ba = mk(wgpu::BufferUsage::Storage, a.data());
  wgpu::Buffer bb = mk(wgpu::BufferUsage::Storage, b.data());
  wgpu::Buffer bc = mk(wgpu::BufferUsage::Storage | wgpu::BufferUsage::CopySrc, nullptr);
  wgpu::Buffer rb = mk(wgpu::BufferUsage::MapRead | wgpu::BufferUsage::CopyDst, nullptr);

  wgpu::ComputePipeline pipe = make_pipeline(device, vecadd_wgsl(mutant));

  wgpu::BindGroupEntry e[3] = {};
  e[0].binding = 0; e[0].buffer = ba; e[0].size = bytes;
  e[1].binding = 1; e[1].buffer = bb; e[1].size = bytes;
  e[2].binding = 2; e[2].buffer = bc; e[2].size = bytes;
  wgpu::BindGroupDescriptor bgd{};
  bgd.layout = pipe.GetBindGroupLayout(0);
  bgd.entryCount = 3;
  bgd.entries = e;
  wgpu::BindGroup bg = device.CreateBindGroup(&bgd);

  wgpu::CommandEncoder enc = device.CreateCommandEncoder();
  wgpu::ComputePassEncoder pass = enc.BeginComputePass();
  pass.SetPipeline(pipe);
  pass.SetBindGroup(0, bg);
  pass.DispatchWorkgroups((n + 127) / 128, 1, 1);
  pass.End();
  enc.CopyBufferToBuffer(bc, 0, rb, 0, bytes);
  wgpu::CommandBuffer cb = enc.Finish();
  device.GetQueue().Submit(1, &cb);

  bool done = false, ok = false;
  rb.MapAsync(wgpu::MapMode::Read, 0, bytes, wgpu::CallbackMode::AllowProcessEvents,
              [&](wgpu::MapAsyncStatus s, wgpu::StringView) { done = true; ok = s == wgpu::MapAsyncStatus::Success; });
  while (!done) g.instance.ProcessEvents();
  if (!ok) { std::printf("readback failed\n"); return 1; }
  const float *out = static_cast<const float *>(rb.GetConstMappedRange());
  uint32_t bad = 0;
  for (uint32_t i = 0; i < n; i++) {
    bad += out[i] != a[i] + b[i];
  }
  std::printf("mismatches: %u of %u%s\n", bad, n, mutant ? " (mutant: shader computes a - b)" : "");
  rb.Unmap();
  return bad != 0;
}
