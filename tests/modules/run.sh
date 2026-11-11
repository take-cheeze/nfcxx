#!/usr/bin/env bash
# C++20 modules (docs/notes/modules.md): interface units with a class, a template, an inline function that calls a
# builtin and a plain function; a chain of imports; the one-command build (sources in any order) and the separate
# compile (-c, the interface files beside the objects), linked afterwards. Also the refusals, which must name the
# reason, and a program with identifiers named import and module, which is not a module and must still compile.
#   NFCXX_BACKEND=gcc|qbe   (default: both)
cd "$(dirname "$0")/../.."
backends=${NFCXX_BACKEND:-"qbe gcc"}
fail=0; tmp=$(mktemp -d); trap 'rm -rf "$tmp"' EXIT
d=tests/modules

expect_exit() {  # expect_exit NAME WANT EXE: EXE runs and exits with WANT
  "$3" >/dev/null 2>&1; local rc=$?
  if [ "$rc" = "$2" ]; then echo "ok   $1: exit $rc"; else echo "FAIL $1: exit $rc, want $2"; fail=1; fi
}
expect_refused() {  # expect_refused NAME PATTERN nfcxx-args...: the build fails and its message contains PATTERN
  local name=$1 pat=$2; shift 2
  local out
  if out=$(./nfcxx "$@" -o "$tmp/refused" 2>&1); then echo "FAIL $name: built, want a refusal"; fail=1
  elif grep -q -- "$pat" <<<"$out"; then echo "ok   $name: refused"
  else echo "FAIL $name: refused without '$pat'"; head -5 <<<"$out"; fail=1; fi
}

for be in $backends; do
  export NFCXX_BACKEND=$be
  # One command: the driver compiles each source (interface units first) and links them.
  if out=$(./nfcxx $d/geom.cppm $d/main.cpp -o "$tmp/one-$be" 2>&1); then expect_exit "$be interface and importer" 19 "$tmp/one-$be"
  else echo "FAIL $be interface and importer (build)"; head -10 <<<"$out"; fail=1; fi

  # A chain given in reverse order: mid imports base, chain imports mid.
  if out=$(./nfcxx $d/chain.cpp $d/mid.cppm $d/base.cppm -o "$tmp/chain-$be" 2>&1); then expect_exit "$be chain, reverse order" 14 "$tmp/chain-$be"
  else echo "FAIL $be chain (build)"; head -10 <<<"$out"; fail=1; fi

  # Separate compile: -c writes each interface file beside its object (the default module directory), the link takes the objects.
  sep=$tmp/sep-$be; mkdir -p "$sep"
  if out=$(./nfcxx -c $d/base.cppm -o "$sep/base.o" 2>&1 && ./nfcxx -c $d/mid.cppm -o "$sep/mid.o" 2>&1 \
           && ./nfcxx -c $d/chain.cpp -o "$sep/chain.o" 2>&1 && ./nfcxx "$sep/chain.o" "$sep/mid.o" "$sep/base.o" -o "$sep/prog" 2>&1); then
    expect_exit "$be separate objects" 14 "$sep/prog"
  else echo "FAIL $be separate objects (build)"; head -10 <<<"$out"; fail=1; fi

  # --module-dir sends the interface files elsewhere; the importer finds them there.
  bmi=$tmp/bmi-$be; mkdir -p "$bmi"
  if out=$(./nfcxx -c $d/base.cppm -o "$bmi/base.o" --module-dir="$bmi/iface" 2>&1 && ./nfcxx -c $d/mid.cppm -o "$bmi/mid.o" --module-dir="$bmi/iface" 2>&1 \
           && ./nfcxx -c $d/chain.cpp -o "$bmi/chain.o" --module-dir="$bmi/iface" 2>&1 && ./nfcxx "$bmi/chain.o" "$bmi/mid.o" "$bmi/base.o" -o "$bmi/prog" 2>&1); then
    expect_exit "$be --module-dir" 14 "$bmi/prog"
  else echo "FAIL $be --module-dir (build)"; head -10 <<<"$out"; fail=1; fi

  # The refusals.
  expect_refused "$be import std" "not built yet" $d/std_import.cpp
  expect_refused "$be module partition" "partitions are not supported" $d/partition.cppm
  expect_refused "$be cyclic imports" "cyclic module imports" $d/cycle_a.cppm $d/cycle_b.cppm
  expect_refused "$be -std=c++17 with modules" "need -std=c++20" -std=c++17 $d/base.cppm

  # Not a module: the identifiers import and module are ordinary names.
  if out=$(./nfcxx $d/plain.cpp -o "$tmp/plain-$be" 2>&1); then expect_exit "$be identifiers import and module" 0 "$tmp/plain-$be"
  else echo "FAIL $be identifiers import and module (build)"; head -10 <<<"$out"; fail=1; fi
done
exit $fail
