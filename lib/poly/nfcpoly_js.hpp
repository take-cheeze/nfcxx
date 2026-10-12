// Raw access to the JavaScript backend, for code that needs the QuickJS API next to nfcpoly. Link nfcpoly_js.cpp and the
// libquickjs that scripts/setup-poly-js.sh builds; add -I build/poly-js/<backend>/include.
#pragma once
// quickjs.h marks its printf-style functions with a `gnu_printf` format attribute, which EDG does not know (one warning per
// function): leave the marker empty unless the program has chosen its own.
#ifndef JS_PRINTF_FORMAT
#define JS_PRINTF_FORMAT
#define JS_PRINTF_FORMAT_ATTR(format_param, dots_param)
#endif
extern "C" {
#include <quickjs.h>
}

#include "nfcpoly.hpp"

namespace nfcpoly {

// The QuickJS context of the nfcpoly context (the interpreter is started if it is not yet). JS_GetRuntime(js_context(ctx))
// is its runtime. Values the code makes with it must be freed before the Context is destroyed (QuickJS asserts that no
// object is left when its runtime closes).
JSContext* js_context(Context& ctx);
// A new reference to the JavaScript value behind a Value of this backend (a script value, or a plain one converted): the
// caller frees it with JS_FreeValue. Throws Error for a Value that is empty, whose context is gone, or that comes from
// another language.
JSValue js_value(const Value& v);
// A Value for a JavaScript value of the context's QuickJS context, shallow-decoded like any result of eval. The reference
// is duplicated: the caller still owns v.
Value js_wrap(Context& ctx, JSValueConst v);

}  // namespace nfcpoly
