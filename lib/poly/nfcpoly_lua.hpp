// Raw access to the Lua backend, for code that needs the Lua API next to nfcpoly. Link nfcpoly_lua.cpp and the liblua that
// scripts/setup-poly-lua.sh builds; add -I build/poly-lua/<backend>/include.
#pragma once
extern "C" {
#include <lua.h>
}

#include "nfcpoly.hpp"

namespace nfcpoly {

// The Lua state of the context: the running thread while a script (or a function it called) runs, else the main thread.
// The interpreter is started if it is not yet.
lua_State* lua_state(Context& ctx);
// Pushes the Lua value behind a Value of the Lua backend (a script value, or a plain one) onto L's stack.
void lua_push_value(lua_State* L, const Value& v);

}  // namespace nfcpoly
