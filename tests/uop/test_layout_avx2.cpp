// nfcuop layout, AVX2 emitter (lib/uop/nfcuop_layout_avx2.hpp, docs/notes/uop-layout.md): the two GEMM variants,
// generated as C, compiled with $NFCUOP_CC (or cc) -O2 -mavx2 -mfma, loaded with dlopen and run against a reference.
// The inputs are small integers, so every product and sum is exact in float and the comparison is exact.
// Prints SKIP when the CPU has no AVX2 and FMA.
#undef NDEBUG
#include "nfcuop_layout_avx2.hpp"

#include <dlfcn.h>
#include <unistd.h>

#include <array>
#include <cstdio>
#include <cstdlib>
#include <fstream>
#include <initializer_list>
#include <random>
#include <stdexcept>
#include <string>
#include <vector>

using namespace nfcuop::layout;

namespace {

int failures = 0;

using KernelFn = void (*)(const float*, const float*, float*, float*, float*);

// Compile the source into a shared object in dir and load the kernel; returns nullptr (and prints why) on failure.
template <class F>
void* load_kernel(const std::string& dir, const std::string& src, const std::string& tag, F* out) {
  std::string c = dir + "/" + tag + ".c", so = dir + "/" + tag + ".so";
  { std::ofstream f(c); f << src; }
  const char* cc = std::getenv("NFCUOP_CC");
  std::string cmd = std::string(cc && *cc ? cc : "cc") + " -O2 -mavx2 -mfma -shared -fPIC -o '" + so + "' '" + c + "' 2>'" + dir + "/" + tag + ".err'";
  if (std::system(cmd.c_str()) != 0) {
    std::fprintf(stderr, "FAIL %s: compile failed (%s)\n", tag.c_str(), cmd.c_str());
    ++failures;
    return nullptr;
  }
  void* h = dlopen(so.c_str(), RTLD_NOW | RTLD_LOCAL);
  if (!h) {
    std::fprintf(stderr, "FAIL %s: dlopen: %s\n", tag.c_str(), dlerror());
    ++failures;
    return nullptr;
  }
  *out = reinterpret_cast<F>(dlsym(h, "nfc_gemm_rowsum"));
  if (!*out) {
    std::fprintf(stderr, "FAIL %s: nfc_gemm_rowsum not found\n", tag.c_str());
    ++failures;
    return nullptr;
  }
  return h;
}

void run_case(const std::string& dir, GemmVariant v, bool simd, Storage st, int64_t M, int64_t N, int64_t K, std::mt19937& rng) {
  const char* name = v == GemmVariant::VecN ? "vec-n" : (st == Storage::Blocked8 ? (simd ? "vec-m-blocked-simd" : "vec-m-blocked-scalar") : (simd ? "vec-m-simd" : "vec-m-scalar"));
  std::string tag = std::string(name) + "_" + std::to_string(M) + "x" + std::to_string(N) + "x" + std::to_string(K);
  std::uniform_int_distribution<int> d(-4, 4);
  std::vector<float> A(M * K), B(K * N);
  for (auto& x : A) x = float(d(rng));
  for (auto& x : B) x = float(d(rng));

  // Reference: C in row-major (m, n), R[m] the sum over n.
  std::vector<float> refC(M * N), refR(M, 0.0f);
  for (int64_t m = 0; m < M; ++m)
    for (int64_t n = 0; n < N; ++n) {
      float s = 0;
      for (int64_t k = 0; k < K; ++k) s += A[m * K + k] * B[k * N + n];
      refC[m * N + n] = s;
      refR[m] += s;
    }

  KernelFn fn = nullptr;
  void* h = load_kernel(dir, emit_gemm_rowsum_c(v, M, N, K, simd, st), tag, &fn);
  if (!h) return;
  std::vector<float> C(M * N, -999.0f), R(M, -999.0f), At(M * K, -999.0f);
  fn(A.data(), B.data(), C.data(), R.data(), At.data());
  dlclose(h);

  int bad = 0;
  for (int64_t m = 0; m < M; ++m) {
    // VecN writes C row-major (C[m*N + n]); VecM strided is column-major (C[n*M + m]); blocked is 8-row blocks.
    for (int64_t n = 0; n < N; ++n) {
      float got = v == GemmVariant::VecN ? C[m * N + n]
                : st == Storage::Blocked8 ? C[(m - m % 8) * N + n * 8 + m % 8]
                                          : C[n * M + m];
      if (got != refC[m * N + n]) ++bad;
    }
    if (R[m] != refR[m]) ++bad;
  }
  if (bad) {
    std::fprintf(stderr, "FAIL %s: %d value(s) differ from the reference\n", tag.c_str(), bad);
    ++failures;
  } else {
    std::printf("ok   %s\n", tag.c_str());
  }
}

void expect_plan_throw(const Solution& s, int64_t M, int64_t N, int64_t K, const char* what) {
  try {
    emit_for_solution(s, M, N, K);
    std::fprintf(stderr, "FAIL %s: no exception\n", what);
    ++failures;
  } catch (const std::invalid_argument&) {
    std::printf("ok   refused: %s\n", what);
  }
}

void expect_throw(GemmVariant v, int64_t M, int64_t N, int64_t K, const char* what) {
  try {
    emit_gemm_rowsum_c(v, M, N, K);
    std::fprintf(stderr, "FAIL %s: no exception\n", what);
    ++failures;
  } catch (const std::invalid_argument&) {
    std::printf("ok   refused: %s\n", what);
  }
}

}  // namespace

// True when /proc/cpuinfo lists every flag. The __builtin_cpu_* functions are not used: cproc (the qbe back end's C
// compiler) does not implement them, so the test would not build under nfcxx --backend=qbe.
bool cpu_has_flags(std::initializer_list<const char*> flags) {
  std::ifstream f("/proc/cpuinfo");
  std::string line;
  while (std::getline(f, line)) {
    if (line.compare(0, 5, "flags") != 0) continue;
    for (const char* flag : flags) {
      std::string needle = std::string(" ") + flag;
      size_t at = line.find(needle);
      bool whole = at != std::string::npos && (at + needle.size() == line.size() || line[at + needle.size()] == ' ');
      if (!whole) return false;
    }
    return true;
  }
  return false;
}

// The packed, register-blocked kernel (emit_gemm_rowsum_packed_c): C row-major, R the row sums, Bp the packing scratch.
void run_packed_case(const std::string& dir, int64_t M, int64_t N, int64_t K, int mr, std::mt19937& rng) {
  std::string tag = "packed" + std::to_string(mr) + "_" + std::to_string(M) + "x" + std::to_string(N) + "x" + std::to_string(K);
  std::uniform_int_distribution<int> d(-4, 4);
  std::vector<float> A(M * K), B(K * N);
  for (auto& x : A) x = float(d(rng));
  for (auto& x : B) x = float(d(rng));
  std::vector<float> refC(M * N), refR(M, 0.0f);
  for (int64_t m = 0; m < M; ++m)
    for (int64_t n = 0; n < N; ++n) {
      float s = 0;
      for (int64_t k = 0; k < K; ++k) s += A[m * K + k] * B[k * N + n];
      refC[m * N + n] = s;
      refR[m] += s;
    }
  KernelFn fn = nullptr;
  void* h = load_kernel(dir, emit_gemm_rowsum_packed_c(M, N, K, mr), tag, &fn);
  if (!h) return;
  std::vector<float> C(M * N, -999.0f), R(M, -999.0f), Bp(K * N, -999.0f);
  fn(A.data(), B.data(), C.data(), R.data(), Bp.data());
  dlclose(h);
  int bad = 0;
  for (int64_t i = 0; i < M * N; ++i) bad += C[i] != refC[i];
  for (int64_t m = 0; m < M; ++m) bad += R[m] != refR[m];
  if (bad) {
    std::fprintf(stderr, "FAIL %s: %d value(s) differ from the reference\n", tag.c_str(), bad);
    ++failures;
  } else {
    std::printf("ok   %s\n", tag.c_str());
  }
}

// The threaded packed kernel (emit_gemm_rowsum_packed_mt_c): the same results at every thread count. Compiled with -pthread.
void run_mt_case(const std::string& dir, int mr, int64_t M, int64_t N, int64_t K, int threads, std::mt19937& rng) {
  std::string tag = "packed_mt" + std::to_string(mr) + "_" + std::to_string(M) + "x" + std::to_string(N) + "x" + std::to_string(K) + "_t" + std::to_string(threads);
  std::uniform_int_distribution<int> d(-4, 4);
  std::vector<float> A(M * K), B(K * N);
  for (auto& x : A) x = float(d(rng));
  for (auto& x : B) x = float(d(rng));
  std::vector<float> refC(M * N), refR(M, 0.0f);
  for (int64_t m = 0; m < M; ++m)
    for (int64_t n = 0; n < N; ++n) {
      float s = 0;
      for (int64_t k = 0; k < K; ++k) s += A[m * K + k] * B[k * N + n];
      refC[m * N + n] = s;
      refR[m] += s;
    }
  std::string src = emit_gemm_rowsum_packed_mt_c(M, N, K, mr);
  std::string c = dir + "/" + tag + ".c", so = dir + "/" + tag + ".so";
  { std::ofstream f(c); f << src; }
  const char* cc = std::getenv("NFCUOP_CC");
  std::string cmd = std::string(cc && *cc ? cc : "cc") + " -O2 -mavx2 -mfma -pthread -shared -fPIC -o '" + so + "' '" + c + "'";
  if (std::system(cmd.c_str()) != 0) {
    std::fprintf(stderr, "FAIL %s: compile failed\n", tag.c_str());
    ++failures;
    return;
  }
  void* h = dlopen(so.c_str(), RTLD_NOW | RTLD_LOCAL);
  using MtFn = void (*)(const float*, const float*, float*, float*, float*, int);
  MtFn fn = h ? reinterpret_cast<MtFn>(dlsym(h, "nfc_gemm_rowsum")) : nullptr;
  if (!fn) {
    std::fprintf(stderr, "FAIL %s: load\n", tag.c_str());
    ++failures;
    return;
  }
  std::vector<float> C(M * N, -999.0f), R(M, -999.0f), Bp(K * N, -999.0f);
  fn(A.data(), B.data(), C.data(), R.data(), Bp.data(), threads);
  dlclose(h);
  int bad = 0;
  for (int64_t i = 0; i < M * N; ++i) bad += C[i] != refC[i];
  for (int64_t m = 0; m < M; ++m) bad += R[m] != refR[m];
  if (bad) {
    std::fprintf(stderr, "FAIL %s: %d value(s) differ from the reference\n", tag.c_str(), bad);
    ++failures;
  } else {
    std::printf("ok   %s\n", tag.c_str());
  }
}

// The plan the solver picks for gemm_rowsum(M, N, K), emitted by emit_for_solution, compiled and run against the
// reference. The kernel's arguments and its output layout follow the plan: packed takes the packing scratch and a thread
// count (run with 2 threads), VecN and VecM the transpose scratch, and VecM's C is in the storage the plan holds for it.
void run_plan_case(const std::string& dir, int64_t M, int64_t N, int64_t K, std::mt19937& rng) {
  using PackedFn = void (*)(const float*, const float*, float*, float*, float*, int);
  Solution s = solve(gemm_rowsum(M, N, K));
  std::string tag = "plan_" + s.variant[0] + "_" + std::to_string(M) + "x" + std::to_string(N) + "x" + std::to_string(K);
  if (s.variant.size() == 2 && s.variant[0] == "avx2-vec-m" && s.storage.count("C"))
    tag += s.storage.at("C") == Storage::Blocked8 ? "_blocked8" : "_strided";
  if (!s.feasible || s.variant.size() != 2) {
    std::fprintf(stderr, "FAIL %s: the model found no plan\n", tag.c_str());
    ++failures;
    return;
  }
  std::string src;
  try {
    src = emit_for_solution(s, M, N, K);
  } catch (const std::exception& e) {
    std::fprintf(stderr, "FAIL %s: %s\n", tag.c_str(), e.what());
    ++failures;
    return;
  }
  const bool packed = s.variant[0] == "avx2-packed-n";
  const bool row_major = packed || s.variant[0] == "avx2-vec-n";
  const Storage st = s.storage.count("C") ? s.storage.at("C") : Storage::Strided;

  std::uniform_int_distribution<int> d(-4, 4);
  std::vector<float> A(M * K), B(K * N);
  for (auto& x : A) x = float(d(rng));
  for (auto& x : B) x = float(d(rng));
  std::vector<float> refC(M * N), refR(M, 0.0f);
  for (int64_t m = 0; m < M; ++m)
    for (int64_t n = 0; n < N; ++n) {
      float acc = 0;
      for (int64_t k = 0; k < K; ++k) acc += A[m * K + k] * B[k * N + n];
      refC[m * N + n] = acc;
      refR[m] += acc;
    }

  std::vector<float> C(M * N, -999.0f), R(M, -999.0f), scratch(std::max(M * K, K * N), -999.0f);
  if (packed) {
    PackedFn fn = nullptr;
    void* h = load_kernel(dir, src, tag, &fn);
    if (!h) return;
    fn(A.data(), B.data(), C.data(), R.data(), scratch.data(), 2);
    dlclose(h);
  } else {
    KernelFn fn = nullptr;
    void* h = load_kernel(dir, src, tag, &fn);
    if (!h) return;
    fn(A.data(), B.data(), C.data(), R.data(), scratch.data());
    dlclose(h);
  }

  int bad = 0;
  for (int64_t m = 0; m < M; ++m) {
    for (int64_t n = 0; n < N; ++n) {
      float got = row_major ? C[m * N + n]
                : st == Storage::Blocked8 ? C[(m - m % 8) * N + n * 8 + m % 8]
                                          : C[n * M + m];
      if (got != refC[m * N + n]) ++bad;
    }
    if (R[m] != refR[m]) ++bad;
  }
  if (bad) {
    std::fprintf(stderr, "FAIL %s: %d value(s) differ from the reference\n", tag.c_str(), bad);
    ++failures;
  } else {
    std::printf("ok   %s\n", tag.c_str());
  }
}

int main() {
  if (!cpu_has_flags({"avx2", "fma"})) {
    std::printf("SKIP test_layout_avx2: this CPU has no AVX2 and FMA\n");
    return 0;
  }
  char tmpl[] = "/tmp/nfcuop-layout-avx2-XXXXXX";
  if (!mkdtemp(tmpl)) {
    std::fprintf(stderr, "FAIL: mkdtemp\n");
    return 1;
  }
  std::string dir = tmpl;
  std::mt19937 rng(20261112);

  struct Case { GemmVariant v; int64_t M, N, K; };
  const Case cases[] = {
      {GemmVariant::VecN, 8, 8, 1},     {GemmVariant::VecN, 16, 24, 5},   {GemmVariant::VecN, 64, 64, 64},
      {GemmVariant::VecM, 8, 8, 1},     {GemmVariant::VecM, 16, 24, 5},   {GemmVariant::VecM, 24, 40, 33},
      {GemmVariant::VecM, 64, 64, 64},  {GemmVariant::VecM, 16, 8, 8},    {GemmVariant::VecM, 32, 16, 13},
  };
  for (const Case& c : cases) {
    if (c.v == GemmVariant::VecN) {
      run_case(dir, c.v, false, Storage::Strided, c.M, c.N, c.K, rng);
    } else {
      // Both transposes: the 8x8 kernel, and the scalar loop it replaces. K values that are not multiples of 8
      // (5, 33, 13) also cover the scalar tail after the 8x8 blocks. Both storages.
      run_case(dir, c.v, true, Storage::Strided, c.M, c.N, c.K, rng);
      run_case(dir, c.v, false, Storage::Strided, c.M, c.N, c.K, rng);
      run_case(dir, c.v, true, Storage::Blocked8, c.M, c.N, c.K, rng);
      run_case(dir, c.v, false, Storage::Blocked8, c.M, c.N, c.K, rng);
    }
  }

  expect_throw(GemmVariant::VecN, 8, 12, 4, "VecN with N = 12");
  expect_throw(GemmVariant::VecM, 12, 8, 4, "VecM with M = 12");
  expect_throw(GemmVariant::VecN, 8, 8, 0, "K = 0");

  // Threaded packed kernel: the same results at 1, 2, 3, 4 and 64 threads (more threads than row tiles included).
  for (int mr : {4, 6}) {
    for (int threads : {1, 2, 3, 4, 64}) {
      run_mt_case(dir, mr, 12 * mr, 64, 17, threads, rng);
    }
  }

  // Packed, register-blocked kernel: M % 4 and N % 16, K values with no alignment requirement.
  for (int mr : {4, 6}) {
    for (auto [M, N, K] : std::vector<std::array<int64_t, 3>>{{mr, 16, 1}, {2 * mr, 32, 5}, {3 * mr, 48, 33}, {12 * mr, 64, 64}}) {
      run_packed_case(dir, M, N, K, mr, rng);
    }
  }
  try {
    emit_gemm_rowsum_packed_c(12, 32, 4, 5);
    std::fprintf(stderr, "FAIL packed with mr = 5: no exception\n");
    ++failures;
  } catch (const std::invalid_argument&) {
    std::printf("ok   refused: packed with mr = 5\n");
  }
  try {
    emit_gemm_rowsum_packed_c(4, 24, 4);
    std::fprintf(stderr, "FAIL packed with N = 24: no exception\n");
    ++failures;
  } catch (const std::invalid_argument&) {
    std::printf("ok   refused: packed with N = 24\n");
  }

  // Plans from the solver, emitted through emit_for_solution. Each shape picks a different kernel: 48x64x17 the packed
  // one (M % 6 and N % 16 fit), 16x24x64 VecN (K large, N not a multiple of 16), 16x24x5 and 64x64x8 and 256x256x8 VecM.
  // The tag shows the storage of VecM's lanes-on-M tensors that the model chose.
  run_plan_case(dir, 48, 64, 17, rng);
  run_plan_case(dir, 16, 24, 64, rng);
  run_plan_case(dir, 16, 24, 5, rng);
  run_plan_case(dir, 64, 64, 8, rng);
  run_plan_case(dir, 256, 256, 8, rng);

  // emit_for_solution refuses what it cannot emit: a packed plan without B in Panel, VecM with A^T and C in different
  // storages, and a combination with no emitter (VecN with reduce-vertical).
  {
    Solution s = solve(gemm_rowsum(48, 64, 17));
    s.storage.erase("B");
    expect_plan_throw(s, 48, 64, 17, "packed plan without Panel B");
  }
  {
    Solution s = solve(gemm_rowsum(256, 256, 8));
    s.storage["A"] = Storage::Strided;
    expect_plan_throw(s, 256, 256, 8, "VecM plan with A^T and C in different storages");
  }
  {
    Solution s = solve(gemm_rowsum(16, 24, 64));
    s.variant[1] = "reduce-vertical";
    expect_plan_throw(s, 16, 24, 64, "VecN with reduce-vertical");
  }

  std::string rm = "rm -rf '" + dir + "'";
  if (failures == 0 && std::system(rm.c_str()) != 0) std::fprintf(stderr, "note: could not remove %s\n", dir.c_str());
  if (failures) {
    std::fprintf(stderr, "test_layout_avx2: %d failure(s), files kept in %s\n", failures, dir.c_str());
    return 1;
  }
  std::printf("test_layout_avx2: all checks passed\n");
  return 0;
}
