// nfcuop layout, AVX-512 emitter (lib/uop/nfcuop_layout_avx512.hpp): the packed, register-blocked GEMM with the row-sum
// epilogue, generated as C, compiled with $NFCUOP_CC (or cc) -O2 -mavx512f -mfma, loaded with dlopen and checked bit for
// bit against a reference (the inputs are small integers, so every sum is exact). Prints SKIP without AVX-512F.
#undef NDEBUG
#include "nfcuop_layout_avx512.hpp"
#include "nfcuop_layout_avx2.hpp"  // emit_for_solution: the plan-to-emitter map covers both targets

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

// True when /proc/cpuinfo lists every flag (the __builtin_cpu_* functions are not used; see test_layout_avx2.cpp).
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

void* load_kernel(const std::string& dir, const std::string& src, const std::string& tag, KernelFn* out) {
  std::string c = dir + "/" + tag + ".c", so = dir + "/" + tag + ".so";
  { std::ofstream f(c); f << src; }
  const char* cc = std::getenv("NFCUOP_CC");
  std::string cmd = std::string(cc && *cc ? cc : "cc") + " -O2 -mavx512f -mfma -shared -fPIC -o '" + so + "' '" + c + "' 2>'" + dir + "/" + tag + ".err'";
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
  *out = reinterpret_cast<KernelFn>(dlsym(h, "nfc_gemm_rowsum"));
  if (!*out) {
    std::fprintf(stderr, "FAIL %s: nfc_gemm_rowsum not found\n", tag.c_str());
    ++failures;
    return nullptr;
  }
  return h;
}

void run_case(const std::string& dir, int mr, int64_t M, int64_t N, int64_t K, std::mt19937& rng) {
  std::string tag = "avx512_mr" + std::to_string(mr) + "_" + std::to_string(M) + "x" + std::to_string(N) + "x" + std::to_string(K);
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
  void* h = load_kernel(dir, emit_gemm_rowsum_packed512_c(M, N, K, mr), tag, &fn);
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

// The plan the AVX-512 target's solver picks, emitted through emit_for_solution, compiled and checked bit for bit.
void run_plan_case(const std::string& dir, int64_t M, int64_t N, int64_t K, std::mt19937& rng) {
  Solution s = solve(gemm_rowsum(M, N, K, avx512_f32()));
  std::string tag = "plan_avx512_" + std::to_string(M) + "x" + std::to_string(N) + "x" + std::to_string(K);
  if (!s.feasible) {
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
  KernelFn fn = nullptr;
  void* h = load_kernel(dir, src, tag, &fn);
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
    std::printf("ok   %s (%s)\n", tag.c_str(), s.variant[0].c_str());
  }
}

void expect_refused(int64_t M, int64_t N, int64_t K, int mr, const char* what) {
  try {
    emit_gemm_rowsum_packed512_c(M, N, K, mr);
    std::fprintf(stderr, "FAIL %s: no exception\n", what);
    ++failures;
  } catch (const std::invalid_argument&) {
    std::printf("ok   refused: %s\n", what);
  }
}

}  // namespace

int main() {
  if (!cpu_has_flags({"avx512f", "fma"})) {
    std::printf("SKIP test_layout_avx512: this CPU has no AVX-512F and FMA\n");
    return 0;
  }
  char tmpl[] = "/tmp/nfcuop-layout-avx512-XXXXXX";
  if (!mkdtemp(tmpl)) {
    std::fprintf(stderr, "FAIL: mkdtemp\n");
    return 1;
  }
  std::string dir = tmpl;
  std::mt19937 rng(20261112);
  for (int mr : {4, 6}) {
    for (auto [M, N, K] : std::vector<std::array<int64_t, 3>>{{mr, 32, 1}, {2 * mr, 64, 5}, {3 * mr, 96, 33}, {12 * mr, 128, 64}}) {
      run_case(dir, mr, M, N, K, rng);
    }
  }
  expect_refused(12, 48, 4, 6, "N = 48 (not a multiple of 32)");
  expect_refused(12, 32, 4, 5, "mr = 5");
  expect_refused(10, 32, 4, 4, "M = 10 with mr = 4");
  expect_refused(8, 32, 0, 4, "K = 0");

  // Plans from the AVX-512 solver, emitted through emit_for_solution and checked (the shapes are the packed kernel's).
  run_plan_case(dir, 12, 32, 5, rng);
  run_plan_case(dir, 24, 64, 33, rng);

  if (failures == 0) {
    std::string rm = "rm -rf '" + dir + "'";
    if (std::system(rm.c_str()) != 0) std::fprintf(stderr, "note: could not remove %s\n", dir.c_str());
  }
  if (failures) {
    std::fprintf(stderr, "test_layout_avx512: %d failure(s), files kept in %s\n", failures, dir.c_str());
    return 1;
  }
  std::printf("test_layout_avx512: all checks passed\n");
  return 0;
}
