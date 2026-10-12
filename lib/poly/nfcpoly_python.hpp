// Raw access to the Python backend, for code that needs the CPython API next to nfcpoly. Compile with the flags of
// `python3-config --includes` and link with `python3-config --ldflags --embed`.
#pragma once
#include <Python.h>

#include "nfcpoly.hpp"

namespace nfcpoly {

// The globals dict of the context's Python (a borrowed reference). The interpreter is started if it is not yet.
PyObject* python_globals(Context& ctx);
// A new reference to the Python object behind a Value of the Python backend.
PyObject* python_object(const Value& v);

}  // namespace nfcpoly
