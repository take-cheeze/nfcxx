// Raw access to the "ast" backend (the nfcast engine, lib/ast), for code that needs the engine's API next to nfcpoly. Link
// nfcpoly_ast.cpp and the six lib/ast/nfcast_*.cpp files.
#pragma once
#include "nfcast.hpp"
#include "nfcpoly.hpp"

namespace nfcpoly {

// The interpreter state of the context (started if it is not yet).
nfcast::State& ast_state(Context& ctx);
// The engine value behind a Value of the ast backend (a script value, or a plain one), to use with ast_state(ctx).
nfcast::Value ast_value(const Value& v);

}  // namespace nfcpoly
