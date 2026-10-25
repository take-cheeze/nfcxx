// A library built by g++ (tests/ehshim/foreign/lib.cpp) that throws with plain `throw` statements, which call
// __cxa_throw; tests/ehshim/foreign/main.cpp catches them (docs/notes/eh-shim.md, "Exceptions thrown by gcc-compiled
// code").
#include <stdexcept>
#include <string>

struct LibError : std::runtime_error {
  int code;
  LibError(const std::string& what, int code);
  ~LibError() override;
};

int lib_live_errors();                 // LibError objects alive (constructed, not destroyed)
void lib_throw_runtime(const char* what);
void lib_throw_error(int code);        // LibError, through two more frames of the library
void lib_throw_int(int v);
void lib_throw_cstr(const char* s);
int lib_internal_catch(int v);         // throws and catches inside the library: v + 1
void lib_rethrow(int code);            // catches a LibError inside the library and rethrows it with `throw;`
int lib_call(void (*f)());             // calls f inside a try block of the library that catches LibError: 5
