// nfcffi in nfcpoly scripts. See nfcffi_poly.hpp.
#include "nfcffi_poly.hpp"

#include <climits>
#include <deque>

#include "nfcffi.hpp"

namespace nfcffi {

namespace {

using Var = nfcpoly::detail::Var;  // the script value (nfcpoly::Value wraps it)

// The Value of a script value. Strings are kept in STRINGS, so their C strings outlive the call.
Value to_value(const Var& v, std::deque<std::string>& strings) {
  switch (v.kind()) {
    case Var::Nil:
      return Value::of_signed(0);
    case Var::Bool:
      return Value::of_signed(v.b() ? 1 : 0);
    case Var::Int:
      return Value::of_signed(v.i());
    case Var::Float:
      return Value::of_float(v.d());
    case Var::Str:
      strings.push_back(v.s());
      return Value::of_pointer(strings.back().c_str());
    case Var::Arr: {
      std::vector<unsigned char> bytes;
      for (const Var& e : v.a()) {
        if (e.kind() != Var::Int || e.i() < 0 || e.i() > 255) {
          throw Error("nfcffi: an array argument must hold bytes (integers 0..255), for a struct or union");
        }
        bytes.push_back(static_cast<unsigned char>(e.i()));
      }
      return Value::of_bytes(bytes.data(), bytes.size());
    }
    default:
      throw Error(std::string("nfcffi: cannot pass a ") + v.kind_name() + " to a C function");
  }
}

// The script value of a call result.
Var to_var(const Value& r) {
  switch (r.kind()) {
    case Value::Kind::Signed:
      return Var::integer(r.as_signed());
    case Value::Kind::Unsigned:
      return Var::integer(static_cast<long long>(r.as_unsigned()));
    case Value::Kind::Float:
      return Var::real(r.as_float());
    case Value::Kind::Pointer:
      return r.as_pointer() == nullptr ? Var() : Var::integer(reinterpret_cast<long long>(r.as_pointer()));
    case Value::Kind::Bytes: {
      std::vector<Var> out;
      for (unsigned char b : r.as_bytes()) out.push_back(Var::integer(b));
      return Var::array(std::move(out));
    }
    default:
      return Var();
  }
}

Ffi& compiler() {
  static Ffi ffi;  // one driver and cache for the scripts of the process
  return ffi;
}

}  // namespace

void bind_poly(nfcpoly::Context& ctx) {
  ctx.def_class<Library>("FfiLibrary")
      .method("callable", &Library::callable)
      .method_fn("call", [](const Library& self, const std::string& name, const std::vector<nfcpoly::Value>& args) {
        std::deque<std::string> strings;
        std::vector<Value> values;
        for (const nfcpoly::Value& a : args) values.push_back(to_value(a.var(), strings));
        return nfcpoly::Value(to_var(self.call(name, values)));
      });
  // ffi_load(header, source, [names]): the names of the functions to wrap (default: every callable one).
  ctx.bind_fn("ffi_load", [](const std::string& header, const std::string& source, const nfcpoly::Value& only) {
    std::vector<std::string> names;
    if (!only.is_nil()) {
      for (const nfcpoly::Value& n : only.as<std::vector<nfcpoly::Value>>()) names.push_back(n.as<std::string>());
    }
    return compiler().load(header, source, names);
  }, 2);
}

}  // namespace nfcffi
