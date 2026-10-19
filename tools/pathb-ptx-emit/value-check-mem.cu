// GPU value check of the memory forms (see value-check-mem.rb): loads the module of the emitter's index, load and store
// lines, runs each type's kernel on 32 threads (thread t copies in[idx[t]] to out[t]), and compares the output bytes with
// the host's copy. Usage: value-check-mem MODULE.ptx. Build: nvcc -o value-check-mem value-check-mem.cu -lcuda
#include <cuda.h>

#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <fstream>
#include <sstream>
#include <string>
#include <vector>

struct Type {
  const char *name;
  size_t size;
};

static const Type TYPES[] = {
    {"char", 1},  {"unsigned_char", 1}, {"short", 2}, {"unsigned_short", 2}, {"int", 4},
    {"unsigned_int", 4}, {"long", 8}, {"unsigned_long", 8}, {"float", 4}, {"double", 8},
};

#define CHECK(call)                                                             \
  do {                                                                          \
    CUresult r = (call);                                                        \
    if (r != CUDA_SUCCESS) {                                                    \
      const char *msg = nullptr;                                                \
      cuGetErrorString(r, &msg);                                                \
      std::fprintf(stderr, "%s: %s\n", #call, msg ? msg : "error");             \
      std::exit(2);                                                             \
    }                                                                           \
  } while (0)

int main(int argc, char **argv) {
  if (argc != 2) {
    std::fprintf(stderr, "usage: value-check-mem MODULE.ptx\n");
    return 2;
  }
  std::ifstream in(argv[1]);
  std::stringstream ss;
  ss << in.rdbuf();
  std::string ptx = ss.str();

  CHECK(cuInit(0));
  CUdevice dev;
  CHECK(cuDeviceGet(&dev, 0));
  CUcontext ctx;
  CHECK(cuDevicePrimaryCtxRetain(&ctx, dev));
  CHECK(cuCtxSetCurrent(ctx));
  CUmodule mod;
  CHECK(cuModuleLoadData(&mod, ptx.c_str()));

  const int threads = 32, elems = 64;
  int failures = 0;
  std::srand(12345);
  for (const Type &t : TYPES) {
    std::vector<unsigned char> src(elems * t.size);
    for (auto &b : src) b = static_cast<unsigned char>(std::rand());
    std::vector<int> idx(threads);
    for (auto &i : idx) i = std::rand() % elems;
    std::vector<unsigned char> expect(threads * t.size);
    for (int i = 0; i < threads; i++) std::memcpy(&expect[i * t.size], &src[idx[i] * t.size], t.size);

    CUdeviceptr din, didx, dout;
    CHECK(cuMemAlloc(&din, src.size()));
    CHECK(cuMemAlloc(&didx, idx.size() * sizeof(int)));
    CHECK(cuMemAlloc(&dout, expect.size()));
    CHECK(cuMemsetD8(dout, 0xAA, expect.size()));
    CHECK(cuMemcpyHtoD(din, src.data(), src.size()));
    CHECK(cuMemcpyHtoD(didx, idx.data(), idx.size() * sizeof(int)));

    std::string fn = std::string("k_") + t.name;
    CUfunction f;
    CHECK(cuModuleGetFunction(&f, mod, fn.c_str()));
    void *args[] = {&din, &didx, &dout};
    CHECK(cuLaunchKernel(f, 1, 1, 1, threads, 1, 1, 0, nullptr, args, nullptr));
    CHECK(cuCtxSynchronize());

    std::vector<unsigned char> got(expect.size());
    CHECK(cuMemcpyDtoH(got.data(), dout, got.size()));
    int bad = 0;
    for (size_t i = 0; i < got.size(); i++) bad += got[i] != expect[i];
    std::printf("%-15s %2d threads, %3zu bytes, %d mismatched bytes\n", t.name, threads, got.size(), bad);
    failures += bad != 0;
    cuMemFree(din);
    cuMemFree(didx);
    cuMemFree(dout);
  }
  std::printf("memory value check: %s\n", failures == 0 ? "ok" : "FAIL");
  return failures == 0 ? 0 : 1;
}
