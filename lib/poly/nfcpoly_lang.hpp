// The interface between the language-neutral core (nfcpoly.cpp) and a language backend (nfcpoly_mruby.cpp,
// nfcpoly_lua.cpp, nfcpoly_python.cpp, nfcpoly_js.cpp, nfcpoly_go.cpp). Not for users of the library. A backend subclasses Lang, converts between its
// interpreter's values and the neutral Var, and registers itself with a static LangRegistrar.
//
// The rules every backend keeps (docs/notes/poly.md, "Exceptions"):
//   1. Host code calling the interpreter checks for failure and converts it: raise_script_error, or, for a script error
//      that carries a host exception, rethrow that exception.
//   2. The interpreter calling host code goes through one trampoline, which catches whatever the Callable throws and
//      raises a script error instead (a host exception travels inside it and is rethrown at the host boundary).
//   3. decode() is shallow (plain kinds and registered objects convert, everything else becomes a Script handle);
//      Lang::to_var() is the deep conversion (arrays become Arr).
#pragma once
#include "nfcpoly.hpp"

namespace nfcpoly {
namespace detail {

struct Lang {
  Impl* impl;
  unsigned long exc_serial = 0;  // the serial of the script error object the backend last handed to the host
  explicit Lang(Impl* i);        // both register in a table of live languages, so that a Value can tell (nfcpoly.cpp)
  virtual ~Lang();
  virtual const char* name() const = 0;

  // Runs CODE. The result is shallow-decoded, with src set to this language.
  virtual Var eval(std::string_view code) = 0;
  // v if it is not a Script value of this language; else the deep conversion (arrays become Arr, elements converted the
  // same way), and v itself where it cannot be converted.
  virtual Var to_var(const Var& v) = 0;
  // target.method(args...), the result shallow-decoded.
  virtual Var call(const Var& target, const std::string& method, const std::vector<Var>& args) = 0;
  virtual std::string inspect(const Var& v) = 0;
  virtual std::string type_name(const Var& v) = 0;
  virtual bool is_array(const Var& v) = 0;

  // Declarations, replayed into a language that starts after they were made.
  virtual void define_fn(const std::string& name, Callable* c) = 0;
  virtual void define_value(const std::string& name, const Var& v) = 0;
  virtual void define_variable(const std::string& name, Callable* get, Callable* set) = 0;  // set may be null
  virtual void class_define(ClassInfo* ci) = 0;
  virtual void class_method(ClassInfo* ci, const std::string& name, Callable* c) = 0;
  virtual void class_prop(ClassInfo* ci, const std::string& name, Callable* get, Callable* set) = 0;
  virtual void class_ctor(ClassInfo* ci, Callable* c) = 0;
};

using LangFactory = std::unique_ptr<Lang> (*)(Impl*);

// A static object in a backend's translation unit: makes `name` (and the aliases, which may be null) an eval language.
struct LangRegistrar {
  LangRegistrar(const char* name, const char* alias1, const char* alias2, LangFactory factory);
};

// The started interpreter of a language (starting it, with the declarations replayed, on first use). Throws
// UnsupportedLanguage.
Lang* get_lang(Impl* impl, std::string_view language);
Impl* impl_of(Lang* l);

// Throws the host-side exception for a script error: SyntaxError when `syntax`, else ScriptError. Records a serial in
// l->exc_serial; the backend has stashed the script error object so that a trampoline can raise it again.
[[noreturn]] void raise_script_error(Lang* l, const std::string& cls, const std::string& msg,
                                     std::vector<std::string> backtrace, bool syntax);

// A global name a script can write as a bare identifier: lower-case or '_' first, then letters, digits, '_'.
bool valid_global_name(const std::string& name);

}  // namespace detail
}  // namespace nfcpoly
