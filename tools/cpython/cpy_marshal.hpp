// CPython 3.13 .pyc reader: the 16-byte header and the marshal (version 5) object stream, with code objects (cpy_marshal.cpp).
#ifndef NFCXX_CPYTHON_MARSHAL_HPP
#define NFCXX_CPYTHON_MARSHAL_HPP

#include <cstdint>
#include <memory>
#include <string>
#include <vector>

namespace cpy {

struct Code;

// One marshal object. Only the kinds the lowering reads are decoded; the rest (floats, complex numbers, containers
// other than tuples) are kept as Kind::Other, and the lowering refuses them where they are used.
struct Obj {
  enum class Kind { None, True, False, Ellipsis, Int, Float, Str, Bytes, Tuple, Code, Other };
  Kind kind = Kind::Other;
  std::int64_t i = 0;                        // Int: the value, when it fits in 62 bits (see `big`)
  bool big = false;                          // Int: wider than the lowering handles (a bignum)
  std::string s;                             // Str (UTF-8 or ASCII bytes), Bytes, Float text is not kept
  std::vector<std::shared_ptr<Obj>> items;   // Tuple
  std::shared_ptr<Code> code;                // Code
  char other = '?';                          // Other: the marshal type code
};
using ObjPtr = std::shared_ptr<Obj>;

// A code object (3.13 layout: marshal.c, w_object's TYPE_CODE branch).
struct Code {
  int argcount = 0, posonlyargcount = 0, kwonlyargcount = 0, stacksize = 0, flags = 0;
  std::string code;                       // co_code: 2-byte units (opcode, argument)
  std::vector<ObjPtr> consts;             // co_consts
  std::vector<std::string> names;         // co_names (every item is a str)
  std::vector<std::string> localsplusnames;  // co_localsplusnames: the fast locals, cells and frees, in slot order
  std::string localspluskinds;            // co_localspluskinds: one byte per localsplus entry (CO_FAST_* kinds)
  std::string name, qualname, filename;
  std::string exctable;                   // co_exceptiontable: empty when the code has no try/with regions
};

// The module: the code object of the .pyc's marshalled object.
struct Pyc {
  std::shared_ptr<Code> main;
};

// Reads a .pyc image. Throws std::runtime_error whose message starts with "refused: " when the file is not a CPython
// 3.13 timestamp-based .pyc, or when it contains a marshal object the reader does not decode.
Pyc load_pyc(const std::vector<std::uint8_t> &bytes);

}  // namespace cpy

#endif  // NFCXX_CPYTHON_MARSHAL_HPP
