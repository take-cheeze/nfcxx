#!/usr/bin/env bash
# nfcffi: build tests/ffi/host.cpp with lib/ffi/nfcffi.cpp (a second translation unit) and run it. The host compiles tests/ffi/lib.c
# at run time with nfcxx (NFCXX is left unset, so the driver is ./nfcxx) and calls it through C++ signatures; it also calls
# C-library functions compiled by gcc (div, ldiv, qsort, strlen), reads the signatures in headers (declarations), and checks the
# error paths. See docs/notes/ffi.md.
# The ABI integration: abi_gcc.c, built by the system C compiler, and abi_host.cpp, built by nfcxx, print the same lines for
# the functions of abi.h. Their output must match.
#   NFCXX_BACKEND=gcc|qbe   (default: both)
cd "$(dirname "$0")/../.."
root=$PWD
backends=${NFCXX_BACKEND:-"qbe gcc"}
fail=0; tmp=$(mktemp -d); trap 'rm -rf "$tmp"' EXIT
unset NFCXX
# The declaration reader (Ffi::declarations) runs the libclang-edg front end: build it once if it is missing.
[ -x build/libclang-edg/cmake/bin/cpfe ] || scripts/setup-libclang-edg.sh > "$tmp/setup-libclang-edg.log" 2>&1 || {
  echo "FAIL setup-libclang-edg"; tail -20 "$tmp/setup-libclang-edg.log"; exit 1; }
# The gcc side of the ABI integration (see above), built once.
if out=$(${CC:-cc} -std=c11 -Wall -Werror -I tests/ffi tests/ffi/abi_gcc.c -o "$tmp/abi-gcc" 2>&1); then
  "$tmp/abi-gcc" > "$tmp/abi-gcc.out"
else
  echo "FAIL abi (gcc build)"; head -20 <<<"$out"; fail=1
fi
for be in $backends; do
  if ! out=$(NFCXX_BACKEND=$be ./nfcxx -I lib/ffi -rdynamic tests/ffi/host.cpp lib/ffi/nfcffi.cpp -o "$tmp/host-$be" 2>&1); then
    echo "FAIL $be ffi (host build)"; head -20 <<<"$out"; fail=1; continue
  fi
  if out=$(NFCXX_BACKEND=$be NFCFFI_CACHE="$tmp/cache-$be" "$tmp/host-$be" "$root/tests/ffi" 2>&1); then
    echo "ok   $be ffi: $(tail -1 <<<"$out")"
  else
    echo "FAIL $be ffi"; head -30 <<<"$out"; fail=1
  fi
  # The nfcxx side of the ABI integration: the same lines as the gcc side, byte for byte.
  if [ -f "$tmp/abi-gcc.out" ] && out=$(NFCXX_BACKEND=$be ./nfcxx -I lib/ffi -rdynamic tests/ffi/abi_host.cpp lib/ffi/nfcffi.cpp -o "$tmp/abi-host-$be" 2>&1); then
    if NFCXX_BACKEND=$be NFCFFI_CACHE="$tmp/cache-abi-$be" "$tmp/abi-host-$be" "$root/tests/ffi" > "$tmp/abi-host-$be.out" 2>&1 &&
       cmp -s "$tmp/abi-host-$be.out" "$tmp/abi-gcc.out"; then
      echo "ok   $be abi (nfcxx against gcc): $(wc -l < "$tmp/abi-gcc.out") lines match"
    else
      echo "FAIL $be abi (nfcxx against gcc)"; diff "$tmp/abi-gcc.out" "$tmp/abi-host-$be.out" | head -30; fail=1
    fi
  else
    echo "FAIL $be abi (host build)"; head -20 <<<"$out"; fail=1
  fi
  # The same through nfcpoly scripts: mruby (Ruby) always, and Python when the CPython development files are installed
  # (lib/ffi/nfcffi_poly.hpp). The mruby build is scripts/setup-poly.sh, once per back end.
  defs=(-DTEST_RUBY); incs=(); libs=(); srcs=(lib/poly/nfcpoly_mruby.cpp)
  if out=$(NFCXX_BACKEND=$be scripts/setup-poly.sh 2>&1); then
    incs+=(-I build/poly/$be/include); libs+=(build/poly/$be/lib/libmruby.a)
  else
    echo "FAIL $be ffi poly (mruby build)"; tail -10 <<<"$out"; fail=1; continue
  fi
  langs="ruby"
  if command -v python3-config >/dev/null && pyinc=$(python3-config --includes 2>/dev/null) && pylib=$(python3-config --ldflags --embed 2>/dev/null) &&
     [ -f "$(python3-config --includes | sed 's/^-I\([^ ]*\).*/\1/')/Python.h" ]; then
    defs+=(-DTEST_PYTHON); incs+=($pyinc); libs+=($pylib); srcs+=(lib/poly/nfcpoly_python.cpp); langs="ruby python"
  else
    echo "SKIP $be ffi poly python: python3-config or Python.h not found (apt-get install python3-dev)"
  fi
  if ! out=$(NFCXX_BACKEND=$be ./nfcxx "${defs[@]}" "${incs[@]}" -I lib/ffi -I lib/poly -rdynamic tests/ffi/poly_host.cpp lib/ffi/nfcffi.cpp lib/ffi/nfcffi_poly.cpp lib/poly/nfcpoly.cpp "${srcs[@]}" "${libs[@]}" -o "$tmp/poly-$be" 2>&1); then
    echo "FAIL $be ffi poly (host build)"; head -20 <<<"$out"; fail=1
  elif out=$(NFCXX_BACKEND=$be NFCFFI_CACHE="$tmp/cache-poly-$be" "$tmp/poly-$be" "$root/tests/ffi" 2>&1); then
    echo "ok   $be ffi poly ($langs): $(tail -1 <<<"$out")"
  else
    echo "FAIL $be ffi poly"; head -30 <<<"$out"; fail=1
  fi
done
exit $fail
