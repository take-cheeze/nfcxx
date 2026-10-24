// nfcffi in nfcpoly scripts: `ffi_load(header, source)` and the FfiLibrary it returns (`lib.call(name, [args])`, `lib.callable(name)`).
// Arguments convert from script values: integers and booleans as integers, floats as floats, strings as C strings (for the
// call), nil as a null pointer or 0, and an array of integers 0..255 as the bytes of a struct. Results come back the same way
// (a struct result is an array of bytes; a pointer result is its address). See docs/notes/ffi.md, "Python".
#pragma once
#include "../poly/nfcpoly.hpp"

namespace nfcffi {

// Declares ffi_load and the FfiLibrary class in CTX (every language of the context sees them).
void bind_poly(nfcpoly::Context& ctx);

}  // namespace nfcffi
