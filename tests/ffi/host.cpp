// nfcffi host: compiles tests/ffi/lib.c at run time and calls it through C++ signatures, then calls functions of the C library
// that gcc compiled (div, ldiv, qsort, strlen). Usage: host <dir holding lib.c>. Exits 0 when every check passes.
#include <cstdio>
#include <stdexcept>
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

// Finds NAME among the declarations, or returns an empty one (name "") when it is absent.
nfcffi::Declaration find(const std::vector<nfcffi::Declaration>& ds, const std::string& name) {
  for (const nfcffi::Declaration& d : ds) {
    if (d.name == name) return d;
  }
  return nfcffi::Declaration();
}

// The signatures the front end reads from headers (lib/ffi declarations, docs/notes/ffi.md).
void check_declarations(const nfcffi::Ffi& ffi, const std::string& dir) {
  std::vector<nfcffi::Declaration> ds = ffi.declarations(dir + "/decls.h");
  nfcffi::Declaration add = find(ds, "add");
  CHECK(add.return_type == "int" && add.params.size() == 2 && !add.variadic && !add.overloaded);
  CHECK(add.param_decl(0, "a") == "int a" && add.param_decl(1, "") == "int");

  nfcffi::Declaration name = find(ds, "name");
  CHECK(name.return_type == "const char *");
  CHECK(name.param_decl(0, "s") == "const char *s" && name.param_decl(1, "n") == "unsigned long n");

  nfcffi::Declaration vec = find(ds, "vec_add");
  CHECK(vec.return_type == "Vec2" && vec.param_decl(1, "b") == "Vec2 b");

  nfcffi::Declaration pair = find(ds, "pair_make");
  CHECK(pair.return_type == "Pair" && pair.params.size() == 1);

  nfcffi::Declaration sort = find(ds, "sort");
  CHECK(sort.params.size() == 4 && sort.param_decl(0, "") == "void *");
  CHECK(sort.param_decl(1, "n") == "size_t n");
  CHECK(sort.param_decl(3, "cmp") == "int (*cmp)(const void *, const void *)");

  nfcffi::Declaration printf_like = find(ds, "printf_like");
  CHECK(printf_like.variadic && printf_like.params.size() == 1);

  nfcffi::Declaration noargs = find(ds, "noargs");
  CHECK(noargs.return_type == "int" && noargs.params.empty() && !noargs.variadic);

  CHECK(find(ds, "pick").return_type == "enum Color");
  CHECK(find(ds, "flag").return_type == "_Bool" && find(ds, "flag").param_decl(0, "b") == "_Bool b");
  CHECK(find(ds, "alloc").return_type == "void *");
  CHECK(find(ds, "takes_array").param_decl(0, "xs") == "int *xs");
  CHECK(find(ds, "takes_array").param_decl(1, "p") == "char * const p");  // C keeps the top-level const
  CHECK(find(ds, "call_back").param_decl(0, "f") == "int (*f)(int)");

  // The C library's headers: the same reader, with the functions gcc compiled.
  std::vector<nfcffi::Declaration> libc = ffi.declarations(dir + "/libc_decls.h");
  nfcffi::Declaration strlen_d = find(libc, "strlen");
  CHECK(strlen_d.return_type == "size_t" && strlen_d.param_decl(0, "s") == "const char *s");
  nfcffi::Declaration qsort_d = find(libc, "qsort");
  CHECK(qsort_d.param_decl(3, "cmp") == "__compar_fn_t cmp");
  CHECK(find(libc, "snprintf").variadic);
  // The global div is the C one; the C++ overload in namespace std is not a free function, so it is not listed.
  CHECK(find(libc, "div").return_type == "div_t" && !find(libc, "div").overloaded);
  CHECK(find(libc, "strlen").overloaded == false);

  // Two global declarations with one name: an overload set (C++ headers), flagged so the caller can skip it.
  std::vector<nfcffi::Declaration> ovl = ffi.declarations(dir + "/overloads.h", nfcffi::Ffi::Dialect::Cxx);
  CHECK(ovl.size() == 2 && ovl[0].overloaded && ovl[1].overloaded);
  CHECK(ovl[1].param_decl(0, "a") == "double a");

  // Errors: a file that does not parse, and a missing tool.
  bool parse_error = false;
  try {
    ffi.declarations(dir + "/bad_decls.h");
  } catch (const nfcffi::Error&) {
    parse_error = true;
  }
  CHECK(parse_error);

  bool no_tool = false;
  nfcffi::Ffi missing_tool;
  missing_tool.set_decl_tool("/nonexistent/libclang-cursors");
  try {
    missing_tool.declarations(dir + "/decls.h");
  } catch (const nfcffi::Error&) {
    no_tool = true;
  }
  CHECK(no_tool);
}

int twice_fn(int x) { return 2 * x; }

// Calls by name through a Library (Ffi::load): the header and the source are compiled together, one wrapper per callable
// function; values are converted by the declared kinds (docs/notes/ffi.md, "Calls by name").
void check_library(const nfcffi::Ffi& ffi, const std::string& dir) {
  using nfcffi::Value;
  nfcffi::Library lib = ffi.load(dir + "/dyn.h", read_text(dir + "/dyn_impl.c"));

  CHECK(lib.callable("add_int") && lib.callable("scale") && lib.callable("halve") && lib.callable("mixed"));
  CHECK(lib.callable("count_bytes") && lib.callable("call_back"));
  CHECK(lib.callable("vec_add") && lib.callable("big_make"));    // structs by value
  CHECK(lib.callable("sum_all"));                                // variadic: callable with extra arguments
  CHECK(lib.declarations().size() == 9);                          // every function is listed

  Value sum = lib.call("add_int", {Value::of_signed(4), Value::of_signed(5)});
  CHECK(sum.kind() == Value::Kind::Signed && sum.as_signed() == 9);
  CHECK(lib.call("add_int", {Value::of_unsigned(7), Value::of_signed(-2)}).as_signed() == 5);  // integers convert
  CHECK(lib.call("scale", {Value::of_float(1.5), Value::of_signed(4)}).as_float() == 6.0);     // to floating point
  CHECK(lib.call("halve", {Value::of_float(3.0)}).as_float() == 1.5);
  CHECK(lib.call("mixed", {Value::of_float(0.5), Value::of_signed(2), Value::of_float(0.25), Value::of_signed(1)})
            .as_float() == 3.75);
  // Structs by value: the bytes of a host struct with the C layout, in and out.
  Vec2 p{1, 2}, q{3, 4};
  Value vsum = lib.call("vec_add", {Value::of_bytes(&p, sizeof p), Value::of_bytes(&q, sizeof q)});
  CHECK(vsum.kind() == Value::Kind::Bytes && vsum.as_bytes().size() == sizeof(Vec2));
  Vec2 vout{};
  std::memcpy(&vout, vsum.as_bytes().data(), sizeof vout);
  CHECK(vout.x == 4 && vout.y == 6);
  Value big = lib.call("big_make", {Value::of_signed(7)});
  Big bout{};
  std::memcpy(&bout, big.as_bytes().data(), sizeof bout);
  CHECK(big.as_bytes().size() == sizeof(Big) && bout.a == 7 && bout.b == 14 && bout.c == 21);

  CHECK(lib.call("count_bytes", {Value::of_pointer("hello")}).as_unsigned() == 5);
  CHECK(lib.call("call_back", {Value::of_pointer(reinterpret_cast<const void*>(&twice_fn)), Value::of_signed(21)})
            .as_signed() == 42);  // the C code calls a host function through a pointer

  // long double and 128-bit integers: callable, as the bytes of the value.
  nfcffi::Library wide = ffi.load(dir + "/wide.h", read_text(dir + "/wide_impl.c"));
  CHECK(wide.callable("twice_ld") && wide.callable("twice_i128"));
  long double ld = 1.25L;
  Value ldr = wide.call("twice_ld", {Value::of_bytes(&ld, sizeof ld)});
  long double ldout = 0;
  CHECK(ldr.as_bytes().size() == sizeof(long double));
  std::memcpy(&ldout, ldr.as_bytes().data(), sizeof ldout);
  CHECK(ldout == 2.5L);
  __int128 wide128 = (static_cast<__int128>(1) << 100) + 7;
  Value wide128r = wide.call("twice_i128", {Value::of_bytes(&wide128, sizeof wide128)});
  __int128 wide128out = 0;
  std::memcpy(&wide128out, wide128r.as_bytes().data(), sizeof wide128out);
  CHECK(wide128out == wide128 * 2);

  // Callbacks: a host callable stands in for a C function pointer; the C side calls it through a trampoline.
  nfcffi::Library cbs = ffi.load(dir + "/cb.h", read_text(dir + "/cb_impl.c"));
  CHECK(cbs.callable("apply_twice") && cbs.callable("each_pair") && cbs.callable("sum_with"));
  CHECK(cbs.declarations().size() == 3);
  Value twice = cbs.call("apply_twice", {Value::of_callable([](const std::vector<Value>& a) {
                                          return Value::of_signed(a[0].as_signed() * 3);
                                        }),
                                        Value::of_signed(2)});
  CHECK(twice.as_signed() == 18);  // 2 -> 6 -> 18: the C code calls the host twice
  std::vector<long long> seen;
  double seen_last = 0;
  cbs.call("each_pair", {Value::of_callable([&](const std::vector<Value>& a) {
                           seen.push_back(a[0].as_signed());
                           seen_last = a[1].as_float();
                           return Value();
                         }),
                         Value::of_signed(4)});
  CHECK(seen.size() == 4 && seen[3] == 3 && seen_last == 1.5);
  Value total = cbs.call("sum_with", {Value::of_callable([](const std::vector<Value>& a) {
                                        return Value::of_signed(a[0].as_signed() + (long long)(a[1].as_float() * 4));
                                      }),
                                      Value::of_signed(4)});
  CHECK(total.as_signed() == 10);  // f(i, 0.25) = i + 1 for i = 0..3
  CHECK(cbs.call("each_pair", {Value::of_pointer(nullptr), Value::of_signed(0)}).kind() == Value::Kind::Void);  // nil, unused

  bool kind_error = false;
  try {
    cbs.call("apply_twice", {Value::of_signed(5), Value::of_signed(2)});
  } catch (const nfcffi::Error&) {
    kind_error = true;
  }
  CHECK(kind_error);

  // A callable's exception crosses the C frames as a rethrow after the call.
  bool rethrown = false;
  try {
    cbs.call("apply_twice", {Value::of_callable([](const std::vector<Value>&) -> Value {
                              throw std::runtime_error("boom");
                            }),
                            Value::of_signed(2)});
  } catch (const std::runtime_error& e) {
    rethrown = std::strcmp(e.what(), "boom") == 0;
  }
  CHECK(rethrown);

  // Variadic functions: the extra arguments are passed by their promoted kinds (integer, double, pointer).
  nfcffi::Library vlib = ffi.load(dir + "/var.h", "", {"snprintf"});
  CHECK(vlib.callable("snprintf"));
  char buf[64] = {0};
  Value written = vlib.call("snprintf", {Value::of_pointer(buf), Value::of_unsigned(sizeof buf),
                                         Value::of_pointer("%d-%s-%.2f"), Value::of_signed(42),
                                         Value::of_pointer("hi"), Value::of_float(3.14159)});
  CHECK(written.as_signed() == 10 && std::strcmp(buf, "42-hi-3.14") == 0);
  // The same function with another kind sequence (a second wrapper, compiled on demand).
  char buf2[32] = {0};
  CHECK(vlib.call("snprintf", {Value::of_pointer(buf2), Value::of_unsigned(sizeof buf2), Value::of_pointer("%ld"),
                               Value::of_unsigned(1234567890123ULL)}).as_signed() == 13 &&
        std::strcmp(buf2, "1234567890123") == 0);

  // Errors: an uncallable name, a wrong count, a wrong kind, and an accessor for another kind.
  auto throws = [](auto&& f) {
    try {
      f();
    } catch (const nfcffi::Error&) {
      return true;
    }
    return false;
  };
  CHECK(throws([&] { lib.call("vec_add", {}); }));
  CHECK(throws([&] { lib.call("vec_add", {Value::of_bytes(&p, 8), Value::of_bytes(&q, sizeof q)}); }));  // size
  CHECK(throws([&] { lib.call("vec_add", {Value::of_signed(1), Value::of_bytes(&q, sizeof q)}); }));     // kind
  CHECK(throws([&] { lib.call("add_int", {Value::of_signed(1)}); }));
  CHECK(throws([&] { lib.call("add_int", {Value::of_pointer(nullptr), Value::of_signed(1)}); }));
  CHECK(throws([&] { lib.call("halve", {Value::of_pointer("x")}); }));
  CHECK(throws([&] { vlib.call("snprintf", {Value::of_pointer(buf)}); }));  // fewer than the fixed arguments
  CHECK(throws([&] { sum.as_float(); }));

  // A function of the C library by name, from a header that includes <string.h>; only strlen is wrapped.
  nfcffi::Library libc = ffi.load(dir + "/str.h", "", {"strlen"});
  CHECK(libc.callable("strlen") && !libc.callable("strcmp"));
  CHECK(libc.call("strlen", {Value::of_pointer("abc")}).as_unsigned() == 3);
}

}  // namespace

static int run_checks(int argc, char** argv);

int main(int argc, char** argv) {
  try {
    return run_checks(argc, argv);
  } catch (const std::exception& e) {
    std::printf("FAILED: %s\n", e.what());
    return 1;
  }
}

static int run_checks(int argc, char** argv) {
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
  check_declarations(ffi, argv[1]);
  check_library(ffi, argv[1]);

  std::printf("%s: %d of %d checks passed\n", failures ? "FAILED" : "ok", checks - failures, checks);
  return failures ? 1 : 0;
}
