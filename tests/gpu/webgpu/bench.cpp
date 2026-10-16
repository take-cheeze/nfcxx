// WebGPU (Dawn, Vulkan) launch overhead and throughput on the Intel Arc B60. Three measurements, each the median of
// 5 timed runs after one untimed warm-up run:
//   (a) one 50000-element vector add: encode, submit, execute and read back, end to end (pipeline and buffers are
//       created once beforehand, inputs uploaded once);
//   (b) N = 10000 back-to-back dispatches of the small kernel (1 workgroup each) in one compute pass and one command
//       buffer, timed from submit to queue-idle, reported per dispatch;
//   (c) the same N dispatches as N separate command buffers, each submitted on its own, reported per dispatch.
// Exit 2 when there is no Intel Vulkan adapter, 1 when the vector add is wrong.
#include "common.h"
#include <algorithm>
#include <chrono>
#include <cstring>
#include <vector>

static double now_ms() {
  return std::chrono::duration<double, std::milli>(std::chrono::steady_clock::now().time_since_epoch()).count();
}

static double median(std::vector<double> v) {
  std::sort(v.begin(), v.end());
  return v[v.size() / 2];
}

static void print_series(const char *label, const std::vector<double> &v, const char *unit, int per) {
  std::printf("%s: median %.3f %s", label, median(v), unit);
  if (per > 0) std::printf(" per dispatch (N=%d)", per);
  std::printf(" [runs:");
  for (double x : v) std::printf(" %.3f", x);
  std::printf("]\n");
}

int main() {
  IntelGpu g;
  if (!open_intel_gpu(g)) return 2;
  wgpu::Device dev = g.device;
  wgpu::Queue q = dev.GetQueue();
  wgpu::Instance inst = g.instance;

  const int kRuns = 5;
  const uint32_t kSmallN = 10000;

  // Waits until everything submitted so far has finished on the GPU.
  auto wait_idle = [&]() {
    bool done = false;
    q.OnSubmittedWorkDone(wgpu::CallbackMode::AllowProcessEvents,
                          [&done](wgpu::QueueWorkDoneStatus, wgpu::StringView) { done = true; });
    while (!done) inst.ProcessEvents();
  };

  // (a) one 50000-element vector add, end to end including readback.
  const uint32_t n = 50000;
  const uint64_t bytes = n * sizeof(float);
  std::vector<float> a(n), b(n), want(n);
  for (uint32_t i = 0; i < n; i++) { a[i] = (float)i; b[i] = 2.0f * (float)i; want[i] = a[i] + b[i]; }
  auto mk = [&](wgpu::BufferUsage u, uint64_t size, const void *src) {
    wgpu::BufferDescriptor d{};
    d.size = size;
    d.usage = u;
    d.mappedAtCreation = src != nullptr;
    wgpu::Buffer buf = dev.CreateBuffer(&d);
    if (src) { std::memcpy(buf.GetMappedRange(), src, size); buf.Unmap(); }
    return buf;
  };
  wgpu::Buffer ba = mk(wgpu::BufferUsage::Storage, bytes, a.data());
  wgpu::Buffer bb = mk(wgpu::BufferUsage::Storage, bytes, b.data());
  wgpu::Buffer bc = mk(wgpu::BufferUsage::Storage | wgpu::BufferUsage::CopySrc, bytes, nullptr);
  wgpu::Buffer rb = mk(wgpu::BufferUsage::MapRead | wgpu::BufferUsage::CopyDst, bytes, nullptr);
  wgpu::ComputePipeline vpipe = make_pipeline(dev, vecadd_wgsl(false));
  wgpu::BindGroupEntry e[3] = {};
  e[0].binding = 0; e[0].buffer = ba; e[0].size = bytes;
  e[1].binding = 1; e[1].buffer = bb; e[1].size = bytes;
  e[2].binding = 2; e[2].buffer = bc; e[2].size = bytes;
  wgpu::BindGroupDescriptor vbgd{};
  vbgd.layout = vpipe.GetBindGroupLayout(0);
  vbgd.entryCount = 3;
  vbgd.entries = e;
  wgpu::BindGroup vbg = dev.CreateBindGroup(&vbgd);

  bool vec_ok = true;
  std::vector<double> ta;
  for (int r = 0; r <= kRuns; r++) {
    double t0 = now_ms();
    wgpu::CommandEncoder enc = dev.CreateCommandEncoder();
    wgpu::ComputePassEncoder pass = enc.BeginComputePass();
    pass.SetPipeline(vpipe);
    pass.SetBindGroup(0, vbg);
    pass.DispatchWorkgroups((n + 127) / 128, 1, 1);
    pass.End();
    enc.CopyBufferToBuffer(bc, 0, rb, 0, bytes);
    wgpu::CommandBuffer cb = enc.Finish();
    q.Submit(1, &cb);
    bool done = false, ok = false;
    rb.MapAsync(wgpu::MapMode::Read, 0, bytes, wgpu::CallbackMode::AllowProcessEvents,
                [&](wgpu::MapAsyncStatus s, wgpu::StringView) { done = true; ok = s == wgpu::MapAsyncStatus::Success; });
    while (!done) inst.ProcessEvents();
    if (!ok) { std::printf("readback failed\n"); return 1; }
    const float *out = static_cast<const float *>(rb.GetConstMappedRange());
    for (uint32_t i = 0; i < n; i++) if (out[i] != want[i]) { vec_ok = false; break; }
    rb.Unmap();
    double dt = now_ms() - t0;
    if (r > 0) ta.push_back(dt);  // run 0 is the warm-up
  }
  if (!vec_ok) { std::printf("vecadd result wrong\n"); return 1; }

  // Small kernel shared by (b) and (c).
  wgpu::ComputePipeline spipe = make_pipeline(dev, small_wgsl());
  wgpu::BufferDescriptor sd{};
  sd.size = 64;
  sd.usage = wgpu::BufferUsage::Storage;
  wgpu::Buffer sink = dev.CreateBuffer(&sd);
  wgpu::BindGroupEntry se{};
  se.binding = 0; se.buffer = sink; se.size = 64;
  wgpu::BindGroupDescriptor sbgd{};
  sbgd.layout = spipe.GetBindGroupLayout(0);
  sbgd.entryCount = 1;
  sbgd.entries = &se;
  wgpu::BindGroup sbg = dev.CreateBindGroup(&sbgd);

  // (b) N dispatches in one pass, one command buffer.
  std::vector<double> tb;
  for (int r = 0; r <= kRuns; r++) {
    double t0 = now_ms();
    wgpu::CommandEncoder enc = dev.CreateCommandEncoder();
    wgpu::ComputePassEncoder pass = enc.BeginComputePass();
    pass.SetPipeline(spipe);
    pass.SetBindGroup(0, sbg);
    for (uint32_t i = 0; i < kSmallN; i++) pass.DispatchWorkgroups(1, 1, 1);
    pass.End();
    wgpu::CommandBuffer cb = enc.Finish();
    q.Submit(1, &cb);
    wait_idle();
    double dt = now_ms() - t0;
    if (r > 0) tb.push_back(dt * 1000.0 / kSmallN);  // microseconds per dispatch
  }

  // (c) N dispatches, each in its own command buffer submitted separately.
  std::vector<double> tc;
  for (int r = 0; r <= kRuns; r++) {
    double t0 = now_ms();
    for (uint32_t i = 0; i < kSmallN; i++) {
      wgpu::CommandEncoder enc = dev.CreateCommandEncoder();
      wgpu::ComputePassEncoder pass = enc.BeginComputePass();
      pass.SetPipeline(spipe);
      pass.SetBindGroup(0, sbg);
      pass.DispatchWorkgroups(1, 1, 1);
      pass.End();
      wgpu::CommandBuffer cb = enc.Finish();
      q.Submit(1, &cb);
    }
    wait_idle();
    double dt = now_ms() - t0;
    if (r > 0) tc.push_back(dt * 1000.0 / kSmallN);
  }

  print_series("(a) vecadd 50000, end to end", ta, "ms", 0);
  print_series("(b) small dispatches, one command buffer", tb, "us", kSmallN);
  print_series("(c) small dispatches, N submits", tc, "us", kSmallN);
  return 0;
}
