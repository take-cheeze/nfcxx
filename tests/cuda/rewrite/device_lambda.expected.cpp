#line 1 "rewrite/device_lambda.cu"
// A device lambda: `[&] __device__ (...) {...}`. The qualifier is dropped in the device unit; `static` after a capture
// list is not C++ (the rewriter took the `(...)` for a function's parameter list, as in llama.cpp's fattn-tile.cuh).
static __forceinline__ void scale_tile(const float *const __restrict__ src, float *const __restrict__ tile, const int n) {
  constexpr int cpy_nb = 16;
  auto load = [&]  (const int k) {
    tile[k] = src[k] * (float)(k + n + cpy_nb);
  };
  load(2);
}

static float scale_all(float s, int n) {
  return s * (float)n;
}
