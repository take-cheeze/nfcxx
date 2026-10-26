// nfcffi from nfcpoly scripts (Python): builds the context with nfcffi::bind_poly and runs the same calls as tests/ffi/host.cpp
// through ffi_load and lib.call. Usage: poly_host <dir with the tests/ffi files>. Exits 0 when every check passes.
#include <cstdio>
#include <fstream>
#include <sstream>
#include <string>

#include "nfcffi_poly.hpp"

namespace {

int failures = 0, checks = 0;

void check(bool ok, const char* what) {
  ++checks;
  if (!ok) {
    ++failures;
    std::printf("FAIL %s\n", what);
  }
}

std::string read_text(const std::string& path) {
  std::ifstream in(path, std::ios::binary);
  std::stringstream ss;
  ss << in.rdbuf();
  return ss.str();
}

}  // namespace

static int run(const std::string& dir);

int main(int argc, char** argv) {
  if (argc != 2) {
    std::fprintf(stderr, "usage: %s <dir with the tests/ffi files>\n", argv[0]);
    return 2;
  }
  try {
    return run(argv[1]);
  } catch (const std::exception& e) {
    std::printf("FAILED: %s\n", e.what());
    return 1;
  }
}

static int run(const std::string& dir) {
  const std::string src = read_text(dir + "/dyn_impl.c");

  nfcpoly::Context ctx;
  nfcffi::bind_poly(ctx);

#ifdef TEST_PYTHON
  // Python: integers, floats, a C string argument, and a struct by value through an array of its bytes.
  const std::string load = "lib = ffi_load('" + dir + "/dyn.h', '''" + src + "''')\n";
  ctx.eval<void>("python", load);
  check(ctx.eval<long long>("python", "lib.call('add_int', [4, 5])") == 9, "python add_int");
  check(ctx.eval<double>("python", "lib.call('scale', [1.5, 4])") == 6.0, "python scale (integer to double)");
  check(ctx.eval<double>("python", "lib.call('halve', [3.0])") == 1.5, "python halve");
  check(ctx.eval<long long>("python", "lib.call('count_bytes', ['hello'])") == 5, "python count_bytes (string)");
  check(ctx.eval<bool>("python", "lib.callable('vec_add') and not lib.callable('no_such')"), "python callable");
  check(ctx.eval<double>("python",
                         "import struct\n"
                         "sum(struct.unpack('dd', bytes(lib.call('vec_add', [list(struct.pack('dd', 1, 2)), "
                         "list(struct.pack('dd', 3, 4))]))))") == 10.0,
        "python vec_add (struct by value through bytes)");

  // The same library from Python, with a variadic C function from <stdio.h>.
  ctx.eval<void>("python", "cstd = ffi_load('" + dir + "/var.h', '', ['snprintf'])\n");
  check(ctx.eval<long long>("python", "cstd.call('snprintf', [None, 0, '%d-%s', 42, 'hi'])") == 5,
        "python snprintf (variadic: the length with a null buffer)");

  // Python functions as the callbacks of C functions: the C side calls them through trampolines.
  ctx.eval<void>("python", "cb = ffi_load('" + dir + "/cb.h', '''" + read_text(dir + "/cb_impl.c") + "''')\n");
  check(ctx.eval<long long>("python", "cb.call('apply_twice', [lambda x: x * 3, 2])") == 18,
        "python callback (apply_twice: the script's result, twice)");
  check(ctx.eval<long long>("python", "cb.call('sum_with', [lambda i, d: i * 10, 3])") == 30,
        "python callback (sum_with: a script function with an int and a double)");
  check(ctx.eval<double>("python",
                         "seen = []\n"
                         "cb.call('each_pair', [lambda i, d: seen.append(d), 3])\n"
                         "sum(seen)") == 1.5,
        "python callback (each_pair: a void callback)");
  check(ctx.eval<long long>("python",
                            "import struct\n"
                            "cb.call('count_pts', [lambda p: int(sum(struct.unpack('dd', bytes(p)))), 3])") == 9,
        "python callback with a struct parameter (the bytes of a Pt)");
  bool script_error = false;
  try {
    ctx.eval<long long>("python", "cb.call('apply_twice', [lambda x: 1 // 0, 2])");
  } catch (const std::exception&) {
    script_error = true;
  }
  check(script_error, "python callback: an exception in the script is rethrown to the caller");

#endif
#ifdef TEST_RUBY
  // mruby: the same library through ffi_load and lib.call, with the source in a heredoc.
  ctx.eval<void>("ruby", "lib = ffi_load('" + dir + "/dyn.h', <<'SRC')\n" + src + "\nSRC\n");
  check(ctx.eval<long long>("ruby", "lib.call('add_int', [4, 5])") == 9, "ruby add_int");
  check(ctx.eval<double>("ruby", "lib.call('scale', [1.5, 4])") == 6.0, "ruby scale (integer to double)");
  check(ctx.eval<double>("ruby", "lib.call('halve', [3.0])") == 1.5, "ruby halve");
  check(ctx.eval<long long>("ruby", "lib.call('count_bytes', ['hello'])") == 5, "ruby count_bytes (string)");
  check(ctx.eval<bool>("ruby", "lib.callable('vec_add') && !lib.callable('no_such')"), "ruby callable");
  check(ctx.eval<long long>("ruby", "cstd = ffi_load('" + dir + "/var.h', '', ['snprintf'])\n"
                                    "cstd.call('snprintf', [nil, 0, '%d-%s', 42, 'hi'])") == 5,
        "ruby snprintf (variadic)");
  // Ruby blocks and lambdas as the callbacks of C functions.
  ctx.eval<void>("ruby", "cb = ffi_load('" + dir + "/cb.h', <<'SRC')\n" + read_text(dir + "/cb_impl.c") + "\nSRC\n");
  check(ctx.eval<long long>("ruby", "cb.call('apply_twice', [->(x) { x * 3 }, 2])") == 18,
        "ruby callback (apply_twice)");
  check(ctx.eval<double>("ruby", "$seen = []\n"
                                 "cb.call('each_pair', [->(i, d) { $seen << d }, 3])\n"
                                 "$seen.inject(0.0) { |a, b| a + b }") == 1.5,
        "ruby callback (each_pair: a void callback)");
#endif

  // Errors reach the script as script errors, and the C++ side can read the result of an eval.
  bool error = false;
  try {
    ctx.eval<long long>("python", "lib.call('vec_add', [1, 2])");
  } catch (const std::exception&) {
    error = true;
  }
  check(error, "python: wrong argument count is an error");

  std::printf("%s: %d of %d checks passed\n", failures ? "FAILED" : "ok", checks - failures, checks);
  return failures ? 1 : 0;
}
