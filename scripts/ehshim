#!/usr/bin/env bash
# Print the path of the EH shim object (lib/ehshim/nfcxx_eh_shim.cpp, docs/notes/eh-shim.md), building it first when it
# is missing or older than its source or EDG's runtime. The shim makes exceptions thrown by libstdc++.so (std::__throw_*
# functions) and std::exception_ptr work on EDG's exception runtime; the driver and the Path B test harness link the object into
# every hosted program.
#   NFCXX_EHSHIM=0       print nothing (link without the shim)
#   NFCXX_EHSHIM_DIR=d   where the object is kept (default build/ehshim)
# The object is compiled by nfcxx itself with the gcc backend (needs EDG: scripts/setup-edg.sh), so that its `throw`
# statements are EDG throws. It depends on the host g++ (headers), hence the version in the file name. When it cannot be
# built the script prints a warning on stderr and nothing on stdout: programs then link without the shim, as before.
set -euo pipefail
root=$(cd "$(dirname "$0")/.." && pwd)
[ "${NFCXX_EHSHIM:-1}" != 0 ] || exit 0
source "$root/scripts/host-sys.sh"
src=$root/lib/ehshim/nfcxx_eh_shim.cpp
dir=${NFCXX_EHSHIM_DIR:-$root/build/ehshim}
# -tls: built against an EDG runtime whose exception handling state is thread-local (the eh-tls marker of
# scripts/setup-edg.sh): its references to that state are TLS ones, which do not link against the other runtime.
tls=; [ ! -f "${EDG_BUILD:-$root/build/edg}/eh-tls" ] || tls=-tls
out=$dir/nfcxx_eh_shim-$(host_gnu_version)$tls.o
rt=${EDG_BUILD:-$root/build/edg}/lib/libC.a   # an EDG rebuild rebuilds the shim too
if [ ! -f "$out" ] || [ "$src" -nt "$out" ] || { [ -f "$rt" ] && [ "$rt" -nt "$out" ]; }; then
  mkdir -p "$dir"
  tmp=$(mktemp -d "$dir/.build.XXXXXX"); trap 'rm -rf "$tmp"' EXIT
  # the driver of this checkout; NFCXX_PATH=b, NFCXX_BACKEND and NFCXX_CC (set by the qbe backend) must not redirect the shim to another compiler.
  # NFCXX_EH_UNWIND is unset too: the shim is linked into every hosted program, QBE ones included, and its copy of the
  # unwinder flag (lib/ehshim/nfcxx_eh_unwind.h, weak and 0 here) must stay 0 so that only gcc programs built with the gate use the unwinder.
  if ! env -u NFCXX_PATH -u NFCXX_BACKEND -u NFCXX_CC -u NFCXX_EHSHIM -u NFCXX_EH_UNWIND "$root/nfcxx" --backend=gcc -c "$src" -o "$tmp/shim.o" > "$tmp/log" 2>&1; then
    echo "ehshim: cannot build $src; linking without it (exceptions thrown by libstdc++ will abort):" >&2
    head -5 "$tmp/log" >&2
    exit 0
  fi
  mv -f "$tmp/shim.o" "$out"   # atomic: concurrent builds each write their own copy
fi
printf '%s\n' "$out"
