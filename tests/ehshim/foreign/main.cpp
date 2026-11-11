// Exceptions thrown with plain `throw` by a library built by g++ (lib.cpp), caught by this program (built by nfcxx on
// tests/ehshim/run.sh's backends; docs/notes/eh-shim.md): by the exact class, by a base, by value, as a pointer, with
// catch (...) and a rethrow to an outer handler, through std::exception_ptr, a `throw;` inside the library, on a second
// thread; throws the library catches itself stay with it, also when this program's try block is around them. Each
// LibError is destroyed once. Prints a line per case; exits 0 when every case got what the all-g++ build gets.
#include <cstdio>
#include <exception>
#include <string>
#include <thread>
#include "lib.h"

static int fails = 0;
static void check(bool ok, const char* name) {
  std::printf("%s %s\n", ok ? "ok  " : "FAIL", name);
  if (!ok) fails++;
}

static void throw_from_callback() { lib_throw_error(9); }

static int on_thread() {
  try {
    lib_throw_error(11);
  } catch (const LibError& e) {
    return e.code;
  }
  return 0;
}

int main() {
  try {
    lib_throw_runtime("runtime");
    check(false, "runtime_error");
  } catch (const std::runtime_error& e) {
    check(std::string(e.what()) == "runtime", "runtime_error");
  }
  try {
    lib_throw_error(3);
    check(false, "LibError exact");
  } catch (LibError& e) {
    check(e.code == 3 && std::string(e.what()) == "lib error 3", "LibError exact");
  }
  check(lib_live_errors() == 0, "LibError destroyed");
  try {
    lib_throw_error(4);
  } catch (const std::exception& e) {
    check(std::string(e.what()) == "lib error 4", "LibError as std::exception");
  }
  try {
    lib_throw_int(42);
  } catch (int v) {
    check(v == 42, "int");
  }
  try {
    lib_throw_cstr("text");
  } catch (const char* s) {
    check(std::string(s) == "text", "const char*");
  }
  try {
    try {
      lib_throw_error(5);
    } catch (...) {
      throw;
    }
  } catch (const LibError& e) {
    check(e.code == 5, "catch (...) and rethrow");
  }
  std::exception_ptr p;
  try {
    lib_throw_error(6);
  } catch (...) {
    p = std::current_exception();
  }
  try {
    std::rethrow_exception(p);
  } catch (const LibError& e) {
    check(e.code == 6, "exception_ptr");
  }
  p = nullptr;
  check(lib_live_errors() == 0, "LibErrors destroyed");
  try {
    check(lib_internal_catch(7) == 8, "caught inside the library");
  } catch (...) {
    check(false, "caught inside the library");
  }
  try {
    lib_rethrow(8);
  } catch (const LibError& e) {
    check(e.code == 8, "throw; inside the library");
  }
  try {
    check(lib_call(throw_from_callback) == 5, "the library's handler beyond a frame of this program");
  } catch (...) {
    check(false, "the library's handler beyond a frame of this program");
  }
  int code = 0;
  std::thread t([&] { code = on_thread(); });
  t.join();
  check(code == 11, "second thread");
  check(lib_live_errors() == 0, "all LibErrors destroyed");
  return fails;
}
