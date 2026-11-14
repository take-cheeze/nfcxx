#!/usr/bin/env bash
# nfcpoly Go under AddressSanitizer and LeakSanitizer: the Go-only host (tests/poly/host.cpp, lib/poly/nfcpoly.cpp,
# lib/poly/nfcpoly_go.cpp) is built with nfcxx -fsanitize=address and linked with libnfcgo.so (the cgo library, uninstrumented), and
# must run to the end, pass all its checks and leak nothing. The instrumented side is the C++ of the bridge and of nfcpoly's core;
# the Go runtime is not instrumented (see docs/notes/poly.md, "Sanitizers and valgrind"). Heap blocks that Go hands over with
# C.malloc (the replies) are malloc blocks of libasan's, so an overflow when the host reads one is found, and a reply the host
# forgets to free is a leak.
#   NFCXX_BACKEND="gcc pathb"   (default gcc only: gcc instruments the C that EDG generates; pathb has the SSA emitter call libasan's checks)
#   PATHB-BLOCKED: pathb is not in the default: tests/poly/host.cpp's go_child_status checks (lines 1927-1932) fail on Path B even
#   without -fsanitize=address, and its exit then reports a heap-use-after-free; the qbe run this replaces passed (cproc is retired for ASan)
#   POLY_GO_DIR=DIR           the library to link (scripts/setup-(mruby|poly|poly-host|poly-js|poly-lua|poly-go|poly-astro|libclang-edg).rb builds it; default build/poly-go)
# tests/poly/lsan.supp lists the one deliberate leak (the class table of the core). Exit status: 0 clean, 1 a failure, 0 and a
# SKIP line when the library cannot be built here (as tests/poly/run.sh) or LeakSanitizer cannot run (ptrace blocked).
cd "$(dirname "$0")/../.."
backends=${NFCXX_BACKEND:-"gcc"}
out=$(scripts/setup-(mruby|poly|poly-host|poly-js|poly-lua|poly-go|poly-astro|libclang-edg).rb 2>&1); rc=$?
if [ $rc = 3 ]; then echo "SKIP asan go: $(tail -1 <<<"$out" | sed 's/^setup-poly-go: //')"; exit 0
elif [ $rc != 0 ]; then echo "FAIL asan go (libnfcgo build)"; tail -20 <<<"$out"; exit 1; fi
godir=${POLY_GO_DIR:-$PWD/build/poly-go}
tmp=$(mktemp -d); trap 'rm -rf "$tmp"' EXIT
fail=0
for be in $backends; do
  case $be in
    gcc) drv=(env NFCXX_BACKEND=gcc ./nfcxx) ;;
    pathb) drv=(./nfcxx --backend=pathb) ;;
    *) echo "FAIL asan go: unknown back end $be"; fail=1; continue ;;
  esac
  if ! out=$("${drv[@]}" -fsanitize=address -DTEST_GO -I lib/poly tests/poly/host.cpp lib/poly/nfcpoly.cpp lib/poly/nfcpoly_go.cpp \
             -L"$godir" -lnfcgo "-Wl,-rpath,$godir" -o "$tmp/host-$be" 2>&1); then
    echo "FAIL $be asan go (host build)"; grep -v prelinker <<<"$out" | head -30; fail=1; continue
  fi
  out=$(ASAN_OPTIONS=detect_leaks=1 LSAN_OPTIONS="suppressions=$(realpath tests/poly/lsan.supp):print_suppressions=0" "$tmp/host-$be" 2>&1); rc=$?
  if grep -q 'LeakSanitizer has encountered a fatal error\|LeakSanitizer does not work under ptrace' <<<"$out"; then
    echo "SKIP $be asan go: LeakSanitizer cannot run here (ptrace is blocked)"; continue
  fi
  if [ $rc = 0 ] && grep -q 'checks passed' <<<"$out"; then
    echo "ok   $be asan go: $(grep 'checks passed' <<<"$out" | tail -1), no memory error, no leak"
  else
    echo "FAIL $be asan go (exit $rc)"; grep -v '^-- ' <<<"$out" | cut -c1-220 | head -60; fail=1
  fi
done
exit $fail
