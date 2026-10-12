// Raw access to the Ruby backend (mruby), for code that needs the mruby API next to nfcpoly. Link nfcpoly_mruby.cpp and
// the libmruby that scripts/setup-poly.sh builds; add -I build/poly/<backend>/include.
#pragma once
#include <mruby.h>

#include "nfcpoly.hpp"

namespace nfcpoly {

// The embedded interpreter of the context (started if it is not yet).
mrb_state* mruby_state(Context& ctx);
// The mruby value behind a Value that came from the Ruby backend. Valid while the Value lives.
mrb_value mruby_raw(const Value& v);

}  // namespace nfcpoly
