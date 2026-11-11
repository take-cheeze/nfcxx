#include "lib.h"

static int live = 0;

LibError::LibError(const std::string& what, int code) : std::runtime_error(what), code(code) { live++; }
LibError::~LibError() { live--; }

int lib_live_errors() { return live; }

void lib_throw_runtime(const char* what) { throw std::runtime_error(what); }

struct Guard {  // a frame of the library with a destructor between the throw and the handler
  int* p;
  ~Guard() { ++*p; }
};
static int guards = 0;
__attribute__((noinline)) static void level2(int code) {
  Guard g = {&guards};
  throw LibError("lib error " + std::to_string(code), code);
}
__attribute__((noinline)) static void level1(int code) { level2(code); }
void lib_throw_error(int code) { level1(code); }

void lib_throw_int(int v) { throw v; }
void lib_throw_cstr(const char* s) { throw s; }

int lib_internal_catch(int v) {
  try {
    throw v;
  } catch (int x) {
    return x + 1;
  }
}

void lib_rethrow(int code) {
  try {
    lib_throw_error(code);
  } catch (LibError&) {
    throw;
  }
}

int lib_call(void (*f)()) {
  try {
    f();
  } catch (LibError& e) {
    return 5;
  }
  return 0;
}
