// Raw access to the Go backend, for code that needs the interpreter's state next to nfcpoly. Link nfcpoly_go.cpp and the
// libnfcgo that scripts/setup-poly-go.sh builds (-L build/poly-go -lnfcgo, and the run-time path of the library).
#pragma once
#include "nfcpoly.hpp"

namespace nfcpoly {

// Runs Go's garbage collector and waits for the finalizers of the script's dropped wrappers of host objects, then releases
// those host objects on the calling thread. Go runs finalizers on a goroutine of its own and offers no way to wait for them,
// so "waits" means: until no more of them have run for a few milliseconds (at most a second). The interpreter is started if
// it is not yet.
void go_collect(Context& ctx);

}  // namespace nfcpoly
