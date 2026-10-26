// The nfcxx side of the ABI integration test (run.sh): abi.h and abi_impl.c are compiled by nfcxx and called through nfcffi.
// It prints the lines abi_gcc.c prints, from the same calls: the layouts through Library::member_offsets.
// Usage: abi_host <dir with the tests/ffi files>.
#include <cstddef>
#include <cstdio>
#include <cstring>
#include <fstream>
#include <sstream>
#include <string>
#include <vector>

#include "nfcffi.hpp"

namespace {

using nfcffi::Value;

// The host's mirrors of the header's types: the layouts are checked against the C ones by the first lines of the output.
struct HostPt { double x, y; };
struct HostRec { int n; char tag; HostPt p; };
struct HostBig { long a, b, c; };
struct HostMixed { float f; short s; unsigned char u; };

std::string read_text(const std::string& path) {
  std::ifstream in(path, std::ios::binary);
  std::stringstream ss;
  ss << in.rdbuf();
  return ss.str();
}

template <class T>
T from_bytes(const Value& v) {
  T t;
  std::memcpy(&t, v.as_bytes().data(), sizeof t);
  return t;
}

template <class T>
Value to_bytes(const T& t) {
  return Value::of_bytes(&t, sizeof t);
}

void layout(const char* name, const std::vector<std::size_t>& o) {
  std::printf("layout %s %zu", name, o[0]);
  for (std::size_t i = 1; i < o.size(); ++i) std::printf(" %zu", o[i]);
  std::printf("\n");
}

}  // namespace

int main(int argc, char** argv) {
  if (argc != 2) {
    std::fprintf(stderr, "usage: %s <dir with the tests/ffi files>\n", argv[0]);
    return 2;
  }
  try {
    const std::string dir = argv[1];
    nfcffi::Ffi ffi;
    nfcffi::Library lib = ffi.load(dir + "/abi.h", read_text(dir + "/abi_impl.c"));

    layout("Pt", lib.member_offsets("Pt", {"x", "y"}));
    layout("Rec", lib.member_offsets("Rec", {"n", "tag", "p"}));
    layout("Mixed", lib.member_offsets("Mixed", {"f", "s", "u"}));

    const long double ld_in = 1.25L;
    long double ld_out = 0;
    Value ld = lib.call("ld_twice", {to_bytes(ld_in)});
    std::memcpy(&ld_out, ld.as_bytes().data(), sizeof ld_out);
    std::printf("ld_twice %.17Lg\n", ld_out);

    HostRec r = from_bytes<HostRec>(lib.call("rec_make", {Value::of_signed(3), Value::of_float(1.5)}));
    std::printf("rec_make %d %d %.17g %.17g\n", r.n, r.tag, r.p.x, r.p.y);
    std::printf("rec_sum %.17g\n", lib.call("rec_sum", {to_bytes(r)}).as_float());

    HostBig b = from_bytes<HostBig>(lib.call("big_make", {Value::of_signed(7)}));
    std::printf("big_make %ld %ld %ld\n", b.a, b.b, b.c);

    HostMixed m = from_bytes<HostMixed>(lib.call("mixed_make", {Value::of_float(2.5)}));
    std::printf("mixed_make %.17g %d %d\n", m.f, m.s, m.u);

    // The callbacks: a struct parameter and result as bytes, and scalar ones.
    auto step_up = [](const std::vector<Value>& a) {
      HostPt p = from_bytes<HostPt>(a[0]);
      HostPt out = {p.x + 1, p.y * 2};
      return to_bytes(out);
    };
    auto count_xy = [](const std::vector<Value>& a) {
      HostPt p = from_bytes<HostPt>(a[0]);
      return Value::of_signed((long long)(p.x + p.y));
    };
    auto square = [](const std::vector<Value>& a) { return Value::of_signed(a[0].as_signed() * a[0].as_signed()); };

    HostPt q = from_bytes<HostPt>(lib.call("pt_step", {Value::of_callable(step_up), to_bytes(HostPt{1.0, 3.0})}));
    std::printf("pt_step %.17g %.17g\n", q.x, q.y);
    std::printf("pt_count %lld\n", lib.call("pt_count", {Value::of_callable(count_xy), Value::of_signed(3)}).as_signed());
    std::printf("sum_squares %lld\n", lib.call("sum_squares", {Value::of_callable(square), Value::of_signed(4)}).as_signed());
    return 0;
  } catch (const std::exception& e) {
    std::printf("FAILED: %s\n", e.what());
    return 1;
  }
}
