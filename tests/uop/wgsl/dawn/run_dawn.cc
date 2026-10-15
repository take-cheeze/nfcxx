// Runs one generated WGSL case (see to_spec.js) on Dawn's Metal backend and checks the output against the interpreter's values.
#include <dawn/webgpu.h>
#include <dawn/dawn_proc.h>
#include <dawn/native/DawnNative.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <math.h>
#include <time.h>

#define MAXB 16
static WGPUInstance inst;

static void wait_on(WGPUFuture f) {
  WGPUFutureWaitInfo w = {f, 0};
  wgpuInstanceWaitAny(inst, 1, &w, UINT64_MAX);
}

static void on_adapter(WGPURequestAdapterStatus s, WGPUAdapter a, WGPUStringView m, void* u1, void* u2) {
  if (s != WGPURequestAdapterStatus_Success) { fprintf(stderr, "adapter: %.*s\n", (int)m.length, m.data); exit(2); }
  *(WGPUAdapter*)u1 = a;
}
static void on_device(WGPURequestDeviceStatus s, WGPUDevice d, WGPUStringView m, void* u1, void* u2) {
  if (s != WGPURequestDeviceStatus_Success) { fprintf(stderr, "device: %.*s\n", (int)m.length, m.data); exit(2); }
  *(WGPUDevice*)u1 = d;
}
static int map_done = 0;
static void on_map(WGPUMapAsyncStatus s, WGPUStringView m, void* u1, void* u2) {
  map_done = (s == WGPUMapAsyncStatus_Success) ? 1 : -1;
}

static WGPUErrorType scope_err = WGPUErrorType_NoError;
static void on_scope(WGPUPopErrorScopeStatus s, WGPUErrorType t, WGPUStringView m, void* u1, void* u2) {
  if (t != WGPUErrorType_NoError) fprintf(stderr, "validation: %.*s\n", (int)m.length, m.data);
  scope_err = t;
}

static double now_ms(void) {
  struct timespec ts; clock_gettime(CLOCK_MONOTONIC, &ts);
  return ts.tv_sec * 1e3 + ts.tv_nsec / 1e6;
}

int main(int argc, char** argv) {
  if (argc != 3) { fprintf(stderr, "usage: run_dawn case.wgsl case.spec\n"); return 2; }
  double t0 = now_ms();
  dawnProcSetProcs(&dawn::native::GetProcs());

  // Source and spec.
  FILE* f = fopen(argv[1], "rb"); if (!f) { perror(argv[1]); return 2; }
  fseek(f, 0, SEEK_END); long n = ftell(f); fseek(f, 0, SEEK_SET);
  char* src = (char*)malloc(n + 1); fread(src, 1, n, f); src[n] = 0; fclose(f);

  int nbuf = 0, out = -1; int bcount[MAXB] = {0}, binput[MAXB] = {0};
  float* inputs[MAXB] = {0}; int icount[MAXB] = {0};
  const char* ename[16]; int ecount[16], ebind[16][4], enb[16]; int nk = 0;
  float* expect = NULL; int nexp = 0;
  f = fopen(argv[2], "r"); if (!f) { perror(argv[2]); return 2; }
  static char line[1 << 16];
  while (fgets(line, sizeof line, f)) {
    char* tok = strtok(line, " \n");
    if (!tok) continue;
    if (!strcmp(tok, "output")) out = atoi(strtok(NULL, " \n"));
    else if (!strcmp(tok, "buf")) {
      int i = atoi(strtok(NULL, " \n"));
      bcount[i] = atoi(strtok(NULL, " \n")); binput[i] = atoi(strtok(NULL, " \n"));
      if (i + 1 > nbuf) nbuf = i + 1;
    } else if (!strcmp(tok, "input")) {
      int i = atoi(strtok(NULL, " \n"));
      inputs[i] = (float*)malloc(sizeof(float) * bcount[i]); icount[i] = 0;
      char* v; while ((v = strtok(NULL, " \n"))) inputs[i][icount[i]++] = strtof(v, NULL);
    } else if (!strcmp(tok, "kernel")) {
      ename[nk] = strdup(strtok(NULL, " \n"));
      ecount[nk] = atoi(strtok(NULL, " \n"));
      enb[nk] = 0; char* b;
      while ((b = strtok(NULL, " \n"))) ebind[nk][enb[nk]++] = atoi(b);
      nk++;
    } else if (!strcmp(tok, "expect")) {
      expect = (float*)malloc(sizeof(float) * 1024); char* v;
      while ((v = strtok(NULL, " \n"))) expect[nexp++] = strtof(v, NULL);
    }
  }
  fclose(f);

  // Instance, adapter (Metal on macOS), device.
  WGPUInstanceFeatureName feats[] = {WGPUInstanceFeatureName_TimedWaitAny};
  WGPUInstanceDescriptor idesc = {0};
  idesc.requiredFeatureCount = 1;
  idesc.requiredFeatures = feats;
  inst = wgpuCreateInstance(&idesc);
  WGPUAdapter adapter = NULL;
  wait_on(wgpuInstanceRequestAdapter(inst, NULL, (WGPURequestAdapterCallbackInfo){
      .mode = WGPUCallbackMode_WaitAnyOnly, .callback = on_adapter, .userdata1 = &adapter}));
  WGPUAdapterInfo info = {0};
  wgpuAdapterGetInfo(adapter, &info);
  WGPUDevice dev = NULL;
  wait_on(wgpuAdapterRequestDevice(adapter, NULL, (WGPURequestDeviceCallbackInfo){
      .mode = WGPUCallbackMode_WaitAnyOnly, .callback = on_device, .userdata1 = &dev}));
    double t_dev = now_ms();

  // Buffers.
  WGPUBuffer bufs[MAXB];
  for (int i = 0; i < nbuf; i++) {
    WGPUBufferDescriptor d = {0};
    d.size = bcount[i] * 4;
    d.usage = WGPUBufferUsage_Storage | WGPUBufferUsage_CopySrc | WGPUBufferUsage_CopyDst;
    bufs[i] = wgpuDeviceCreateBuffer(dev, &d);
    if (binput[i]) wgpuQueueWriteBuffer(wgpuDeviceGetQueue(dev), bufs[i], 0, inputs[i], bcount[i] * 4);
  }
  WGPUBufferDescriptor rd = {0};
  rd.size = bcount[out] * 4; rd.usage = WGPUBufferUsage_MapRead | WGPUBufferUsage_CopyDst;
  WGPUBuffer readback = wgpuDeviceCreateBuffer(dev, &rd);

  // Shader module; compilation errors are reported through the module's compilation info.
  WGPUShaderSourceWGSL wsrc = {0};
  wsrc.chain.sType = WGPUSType_ShaderSourceWGSL;
  wsrc.code = (WGPUStringView){src, (size_t)n};
  WGPUShaderModuleDescriptor smd = {0};
  smd.nextInChain = &wsrc.chain;
  WGPUShaderModule module = wgpuDeviceCreateShaderModule(dev, &smd);

  // One compute pass per kernel, in order, in one command encoder.
  WGPUQueue queue = wgpuDeviceGetQueue(dev);
  WGPUCommandEncoder enc = wgpuDeviceCreateCommandEncoder(dev, NULL);
  wgpuDevicePushErrorScope(dev, WGPUErrorFilter_Validation);
  for (int k = 0; k < nk; k++) {
    WGPUComputePipelineDescriptor pd = {0};
    pd.compute.module = module;
    pd.compute.entryPoint = (WGPUStringView){ename[k], (size_t)strlen(ename[k])};
    WGPUComputePipeline pipe = wgpuDeviceCreateComputePipeline(dev, &pd);
    WGPUBindGroupLayout bgl = wgpuComputePipelineGetBindGroupLayout(pipe, 0);
    WGPUBindGroupEntry ents[MAXB] = {0};
    for (int j = 0; j < enb[k]; j++) {
      ents[j].binding = ebind[k][j];
      ents[j].buffer = bufs[ebind[k][j]];
      ents[j].size = bcount[ebind[k][j]] * 4;
    }
    WGPUBindGroupDescriptor bgd = {0};
    bgd.layout = bgl;
    bgd.entryCount = enb[k];
    bgd.entries = ents;
    WGPUBindGroup bg = wgpuDeviceCreateBindGroup(dev, &bgd);
    WGPUComputePassEncoder pass = wgpuCommandEncoderBeginComputePass(enc, NULL);
    wgpuComputePassEncoderSetPipeline(pass, pipe);
    wgpuComputePassEncoderSetBindGroup(pass, 0, bg, 0, NULL);
    wgpuComputePassEncoderDispatchWorkgroups(pass, (ecount[k] + 63) / 64, 1, 1);
    wgpuComputePassEncoderEnd(pass);
  }
  wgpuCommandEncoderCopyBufferToBuffer(enc, bufs[out], 0, readback, 0, rd.size);
  WGPUCommandBuffer cb = wgpuCommandEncoderFinish(enc, NULL);
  wgpuQueueSubmit(queue, 1, &cb);
  wait_on(wgpuDevicePopErrorScope(dev, (WGPUPopErrorScopeCallbackInfo){
      .mode = WGPUCallbackMode_WaitAnyOnly, .callback = on_scope, .userdata1 = &scope_err}));
  if (scope_err != WGPUErrorType_NoError) { printf("FAIL validation: error type %d\n", (int)scope_err); return 1; }
  double t_submit = now_ms();

  wait_on(wgpuBufferMapAsync(readback, WGPUMapMode_Read, 0, rd.size, (WGPUBufferMapCallbackInfo){
      .mode = WGPUCallbackMode_WaitAnyOnly, .callback = on_map}));
  if (map_done != 1) { printf("FAIL readback map\n"); return 1; }
  const float* got = (const float*)wgpuBufferGetConstMappedRange(readback, 0, rd.size);
  int exact = 0, bad = 0; float maxerr = 0;
  for (int i = 0; i < nexp; i++) {
    float d = fabsf(got[i] - expect[i]);
    float tol = 1e-6f * fmaxf(1.0f, fabsf(expect[i]));
    if (!(d <= tol)) { if (bad < 5) printf("  mismatch %d: got %.9g want %.9g\n", i, got[i], expect[i]); bad++; }
    if (d == 0) exact++;
    if (d > maxerr) maxerr = d;
  }
  double t_end = now_ms();
  printf("%s n=%d exact=%d maxabs=%.3e kernels=%d adapter=%.*s/%.*s backend=%d time_device=%.0fms time_run=%.0fms time_total=%.0fms\n",
         bad ? "FAIL" : "PASS", nexp, exact, maxerr, nk,
         (int)info.vendor.length, info.vendor.data, (int)info.architecture.length, info.architecture.data,
         (int)info.backendType, t_dev - t0, t_end - t_submit, t_end - t0);
  return bad ? 1 : 0;
}
