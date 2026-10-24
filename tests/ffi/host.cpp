// nfcffi host: compiles tests/ffi/lib.c at run time and calls it through C++ signatures, then calls functions of the C library
// that gcc compiled (div, ldiv, qsort, strlen). Usage: host <dir holding lib.c>. Exits 0 when every check passes.
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <fstream>
#include <sstream>
#include <string>
#include <utility>

#include "nfcffi.hpp"

namespace {

int failures = 0, checks = 0;

#define CHECK(cond)                                                          \
  do {                                                                       \
    ++checks;                                                                \
    if (!(cond)) {                                                           \
      ++failures;                                                            \
      std::printf("FAIL %s:%d: %s\n", __FILE__, __LINE__, #cond);            \
    }                                                                        \
  } while (0)

struct Vec2 { double x, y; };
struct Big { long a, b, c; };
struct Small { int n; char tag; };
struct DivT { int quot; int rem; };    // glibc's div_t
struct LDivT { long quot; long rem; }; // glibc's ldiv_t

int twice(int x) { return 2 * x; }      // a host callback: C calls it through a function pointer

int compare_ints(const void* a, const void* b) {
  int x = *static_cast<const int*>(a), y = *static_cast<const int*>(b);
  return (x > y) - (x < y);
}

std::string read_text(const std::string& path) {
  std::ifstream in(path, std::ios::binary);
  std::stringstream ss;
  ss << in.rdbuf();
  return ss.str();
}

// Calls done through a Module compiled by nfcffi (the C side is built with nfcxx -shared).
void check_module(const nfcffi::Module& m) {
  auto add = m.function<int(int, int)>("add_int");
  CHECK(add(4, 5) == 9);
  CHECK(add(-7, 2) == -5);

  CHECK(m.function<double(double, double)>("scale")(1.5, 4.0) == 6.0);
  CHECK(m.function<float(float)>("halve")(3.0f) == 1.5f);
  CHECK(m.function<double(float, int, double, char)>("mixed")(0.5f, 2, 0.25, 1) == 3.75);

  Vec2 s = m.function<Vec2(Vec2, Vec2)>("vec_add")(Vec2{1, 2}, Vec2{3, 4});
  CHECK(s.x == 4 && s.y == 6);

  Big b = m.function<Big(long)>("big_make")(7);
  CHECK(b.a == 7 && b.b == 14 && b.c == 21);

  Small sm = m.function<Small(int)>("small_make")(42);
  CHECK(sm.n == 42 && sm.tag == 'z');

  CHECK(m.function<unsigned long(const char*)>("count_bytes")("hello") == 5);

  // The C code calls back into the host through a function pointer.
  CHECK(m.function<int(int (*)(int), int)>("call_back")(twice, 21) == 42);
}

void check_process() {
  // gcc-compiled C library: div returns a two-int struct in one register, ldiv a pair of longs in two.
  DivT d = nfcffi::process_function<DivT(int, int)>("div")(17, 5);
  CHECK(d.quot == 3 && d.rem == 2);
  DivT dn = nfcffi::process_function<DivT(int, int)>("div")(-17, 5);
  CHECK(dn.quot == -3 && dn.rem == -2);
  LDivT ld = nfcffi::process_function<LDivT(long, long)>("ldiv")(-17L, 5L);
  CHECK(ld.quot == -3 && ld.rem == -2);

  CHECK(nfcffi::process_function<size_t(const char*)>("strlen")("abc") == 3);

  // A host comparator passed to C's qsort.
  int v[] = {5, 1, 4, 2, 3};
  nfcffi::process_function<void(void*, size_t, size_t, int (*)(const void*, const void*))>("qsort")(
      v, 5, sizeof v[0], compare_ints);
  CHECK(v[0] == 1 && v[1] == 2 && v[2] == 3 && v[3] == 4 && v[4] == 5);

  bool threw = false;
  try {
    nfcffi::process_function<int(void)>("no_such_function_nfcffi");
  } catch (const nfcffi::Error&) {
    threw = true;
  }
  CHECK(threw);
}

void check_errors(const nfcffi::Ffi& ffi) {
  bool compile_error = false;
  try {
    ffi.compile("int broken(void) { return undeclared_name; }\n");
  } catch (const nfcffi::CompileError& e) {
    compile_error = std::strstr(e.what(), "undeclared_name") != nullptr;
  }
  CHECK(compile_error);

  bool missing = false;
  nfcffi::Module m = ffi.compile("int present(void) { return 1; }\n");
  try {
    m.function<int(void)>("absent");
  } catch (const nfcffi::Error&) {
    missing = true;
  }
  CHECK(missing);
  CHECK(m.function<int(void)>("present")() == 1);
}

}  // namespace

int main(int argc, char** argv) {
  if (argc != 2) {
    std::fprintf(stderr, "usage: %s <dir with lib.c>\n", argv[0]);
    return 2;
  }
  std::string src = read_text(std::string(argv[1]) + "/lib.c");

  nfcffi::Ffi ffi;
  nfcffi::Module m = ffi.compile(src);
  CHECK(m.valid());
  check_module(m);

  // Moving a module keeps its functions alive; the moved-from object is empty.
  nfcffi::Module moved = std::move(m);
  CHECK(!m.valid() && moved.valid());
  CHECK(moved.function<int(int, int)>("add_int")(1, 1) == 2);

  // The same source again: the object comes from the cache, and the functions still work.
  nfcffi::Module again = nfcffi::Ffi().compile(src);
  CHECK(again.function<int(int, int)>("add_int")(10, 20) == 30);

  check_process();
  check_errors(ffi);

  std::printf("%s: %d of %d checks passed\n", failures ? "FAILED" : "ok", checks - failures, checks);
  return failures ? 1 : 0;
}
