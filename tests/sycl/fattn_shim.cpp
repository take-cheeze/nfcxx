// Regression for the shim gaps that stop ggml-sycl's flash-attention sources (fattn-vec.hpp, fattn-common.hpp, vecdotq.hpp,
// dpct/helper.hpp) from compiling: sycl::sub_sat on integers, a one-element sycl::vec converting to its element, the lane-wise
// vector relational operators read through std::equal_to and .as<VecT>() (dpct's vectorized_binary), the architecture
// enumerators with the runtime's values, and the work_group_static / grf_size_automatic headers. Host path only (the
// device pass has no use of these). Expected output: "fattn_shim ok".
#include <sycl/sycl.hpp>
#include <sycl/ext/oneapi/work_group_static.hpp>
#include <sycl/ext/intel/experimental/grf_size_properties.hpp>
#include <cstdio>
#include <functional>
#include <limits>

static int bad = 0;
#define CHECK(c) do { if (!(c)) { std::printf("check failed: %s (line %d)\n", #c, __LINE__); bad++; } } while (0)

// dpct's vectorized_binary for a relational op: VecT lanes through BinaryOperation, read back as VecT (the bytes of the mask)
template <typename VecT, class BinaryOperation> static VecT vec_binary(VecT a, VecT b, BinaryOperation op) {
  return op(a, b).template as<VecT>();
}

int main() {
  // sub_sat: the saturating ends of signed and unsigned types, and the plain case
  CHECK(sycl::sub_sat((signed char) 100, (signed char) -100) == 127);
  CHECK(sycl::sub_sat((signed char) -100, (signed char) 100) == -128);
  CHECK(sycl::sub_sat((signed char) 5, (signed char) 3) == 2);
  CHECK(sycl::sub_sat(std::numeric_limits<int>::min(), 1) == std::numeric_limits<int>::min());
  CHECK(sycl::sub_sat(std::numeric_limits<int>::max(), -1) == std::numeric_limits<int>::max());
  CHECK(sycl::sub_sat(3u, 5u) == 0u);
  CHECK(sycl::sub_sat(5u, 3u) == 2u);
  CHECK(sycl::add_sat((unsigned char) 200, (unsigned char) 100) == 255);
  CHECK(sycl::add_sat((short) -30000, (short) -10000) == -32768);
  // on vectors, lane by lane (dpct's sub_sat functor on sycl::char4)
  sycl::char4 sx(100, -100, 5, 0), sy(-100, 100, 3, 1);
  sycl::char4 sd = sycl::sub_sat(sx, sy);
  CHECK(sd[0] == 127 && sd[1] == -128 && sd[2] == 2 && sd[3] == -1);

  // float classification by arithmetic
  // the bit patterns of +infinity and a quiet NaN (the C library's HUGE_VALF and NAN need builtins the C backend lacks)
  const uint32_t inf_bits = 0x7f800000u, nan_bits = 0x7fc00000u;
  float inf, nan;
  std::memcpy(&inf, &inf_bits, 4);
  std::memcpy(&nan, &nan_bits, 4);
  CHECK(sycl::isinf(inf) && sycl::isinf(-inf));
  CHECK(!sycl::isinf(1.0f) && !sycl::isinf(nan));
  CHECK(sycl::isnan(nan) && !sycl::isnan(inf) && !sycl::isnan(0.0f));
  CHECK(sycl::isfinite(2.0f) && !sycl::isfinite(inf) && !sycl::isfinite(nan));

  // a one-element vector is its element
  sycl::vec<unsigned int, 1> v1{7u};
  unsigned u = v1;
  CHECK(u == 7u);
  __builtin_assume(u == 7u);  // an optimizer hint: no effect on the value
  CHECK(static_cast<unsigned>(sycl::vec<unsigned int, 1>(9u)) == 9u);

  // the lane-wise relational operator: -1 in each equal lane, 0 in each other lane, read back as the uchar4 bytes
  sycl::uchar4 a(1, 2, 3, 4), b(1, 9, 3, 0);
  sycl::vec<signed char, 4> m = (a == b);
  CHECK(m[0] == -1 && m[1] == 0 && m[2] == -1 && m[3] == 0);
  sycl::uchar4 mask = vec_binary<sycl::uchar4>(a, b, std::equal_to<>());
  CHECK(mask[0] == 0xff && mask[1] == 0 && mask[2] == 0xff && mask[3] == 0);
  CHECK((a != b)[1] == -1);

  // the architecture enumerators carry the runtime's values (device_architecture.def)
  using arch = sycl::ext::oneapi::experimental::architecture;
  CHECK((uint64_t) arch::intel_gpu_bmg_g21 == 0x0000000500400400ull);
  CHECK((uint64_t) arch::intel_gpu_bmg_g31 == 0x0000000500800000ull);
  CHECK((uint64_t) arch::intel_gpu_lnl_m == 0x0000000501000400ull);
  CHECK(arch::intel_gpu_dg2_g10 == arch::intel_gpu_acm_g10);

  // the headers: the work-group static type exists and is storage of its own size; the property is a value
  sycl::ext::oneapi::experimental::work_group_static<float[4]> wgs;
  CHECK(sizeof(wgs) >= sizeof(float) * 4);
  sycl::ext::oneapi::experimental::properties p{ sycl::ext::intel::experimental::grf_size_automatic };
  (void) p;

  if (bad == 0) std::printf("fattn_shim ok\n");
  return bad != 0;
}
