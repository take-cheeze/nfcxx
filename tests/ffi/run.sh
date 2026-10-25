#!/usr/bin/env bash
# nfcffi: build tests/ffi/host.cpp with lib/ffi/nfcffi.cpp (a second translation unit) and run it. The host compiles tests/ffi/lib.c
# at run time with nfcxx (NFCXX is left unset, so the driver is ./nfcxx) and calls it through C++ signatures; it also calls
# C-library functions compiled by gcc (div, ldiv, qsort, strlen), reads the signatures in headers (declarations), and checks the
# error paths. See docs/notes/ffi.md.
#   NFCXX_BACKEND=gcc|qbe   (default: both)
cd "$(dirname "$0")/../.."
root=$PWD
backends=${NFCXX_BACKEND:-"qbe gcc"}
fail=0; tmp=$(mktemp -d); trap 'rm -rf "$tmp"' EXIT
unset NFCXX
# The declaration reader (Ffi::declarations) runs the libclang-edg front end: build it once if it is missing.
[ -x build/libclang-edg/cmake/bin/cpfe ] || scripts/setup-libclang-edg.sh > "$tmp/setup-libclang-edg.log" 2>&1 || {
  echo "FAIL setup-libclang-edg"; tail -20 "$tmp/setup-libclang-edg.log"; exit 1; }
for be in $backends; do
  if ! out=$(NFCXX_BACKEND=$be ./nfcxx -I lib/ffi -rdynamic tests/ffi/host.cpp lib/ffi/nfcffi.cpp -o "$tmp/host-$be" 2>&1); then
    echo "FAIL $be ffi (host build)"; head -20 <<<"$out"; fail=1; continue
  fi
  if out=$(NFCXX_BACKEND=$be NFCFFI_CACHE="$tmp/cache-$be" "$tmp/host-$be" "$root/tests/ffi" 2>&1); then
    echo "ok   $be ffi: $(tail -1 <<<"$out")"
  else
    echo "FAIL $be ffi"; head -30 <<<"$out"; fail=1
  fi
  # The same through nfcpoly scripts (Python), when the CPython development files are installed (lib/ffi/nfcffi_poly.hpp).
  if command -v python3-config >/dev/null && pyinc=$(python3-config --includes 2>/dev/null) && pylib=$(python3-config --ldflags --embed 2>/dev/null) &&
     [ -f "$(python3-config --includes | sed 's/^-I\([^ ]*\).*/\1/')/Python.h" ]; then
    if ! out=$(NFCXX_BACKEND=$be ./nfcxx -DTEST_PYTHON $pyinc -I lib/ffi -I lib/poly -rdynamic tests/ffi/poly_host.cpp lib/ffi/nfcffi.cpp lib/ffi/nfcffi_poly.cpp lib/poly/nfcpoly.cpp lib/poly/nfcpoly_python.cpp $pylib -o "$tmp/poly-$be" 2>&1); then
      echo "FAIL $be ffi poly (host build)"; head -20 <<<"$out"; fail=1
    elif out=$(NFCXX_BACKEND=$be NFCFFI_CACHE="$tmp/cache-poly-$be" "$tmp/poly-$be" "$root/tests/ffi" 2>&1); then
      echo "ok   $be ffi poly (python): $(tail -1 <<<"$out")"
    else
      echo "FAIL $be ffi poly"; head -30 <<<"$out"; fail=1
    fi
  else
    echo "SKIP $be ffi poly: python3-config or Python.h not found (apt-get install python3-dev)"
  fi
done
exit $fail
