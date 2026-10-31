#!/usr/bin/env bash
# --cosmo (docs/notes/cosmo.md). Two parts:
#  1. Routing, always: a stand-in cosmocc (gcc, logging its arguments) must be the compiler of both the C compile and
#     the link, and the program must run. Checks the driver's wiring, not Cosmopolitan itself.
#  2. The real cosmocc, when it is installed (scripts/setup-cosmo.sh or NFCXX_COSMOCC): the program is an APE binary
#     and runs. Skipped otherwise.
set -euo pipefail
root=$(cd "$(dirname "$0")/../.." && pwd)
tmp=$(mktemp -d); trap 'rm -rf "$tmp"' EXIT
src=$tmp/hello.c
cat > "$src" <<'C'
#include <stdio.h>
int main(void) { puts("cosmo ok"); return 0; }
C

# 1. routing
stub=$tmp/stub/cosmocc
mkdir -p "$tmp/stub"
cat > "$stub" <<EOS
#!/usr/bin/env bash
echo "\$*" >> "$tmp/stub.log"
exec gcc "\$@"
EOS
chmod +x "$stub"
NFCXX_COSMOCC=$stub "$root/nfcxx" --cosmo "$src" -o "$tmp/hello-stub"
"$tmp/hello-stub" | grep -qx 'cosmo ok'
grep -q -- '-c' "$tmp/stub.log" || { echo "FAIL: the C compile did not run cosmocc" >&2; exit 1; }
grep -q -- '-o '"$tmp/hello-stub" "$tmp/stub.log" || { echo "FAIL: the link did not run cosmocc" >&2; exit 1; }
echo "ok: --cosmo routes the compile and the link through NFCXX_COSMOCC"

# refusals
if NFCXX_COSMOCC=$stub "$root/nfcxx" --cosmo --backend=qbe "$src" -o "$tmp/x" 2>/dev/null; then
  echo "FAIL: --cosmo --backend=qbe was accepted" >&2; exit 1
fi
if NFCXX_COSMOCC=$tmp/none/cosmocc "$root/nfcxx" --cosmo "$src" -o "$tmp/x" 2>/dev/null; then
  echo "FAIL: a missing cosmocc was accepted" >&2; exit 1
fi
echo "ok: refusals (qbe backend, missing cosmocc)"

# 2. the real cosmocc
real=${NFCXX_COSMOCC:-$root/build/cosmocc/bin/cosmocc}
if [ ! -x "$real" ]; then
  echo "skip: no cosmocc at $real (scripts/setup-cosmo.sh)"; exit 0
fi
NFCXX_COSMOCC=$real "$root/nfcxx" --cosmo "$src" -o "$tmp/hello.com"
"$tmp/hello.com" | grep -qx 'cosmo ok'
echo "ok: cosmocc build runs"
