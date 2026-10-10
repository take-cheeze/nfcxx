#!/usr/bin/env bash
# Several translation units compiled by nfcxx, all using std::string / std::vector / std::map / templates,
# inline functions and inline or static-member variables, linked into one program. C++ requires the link to
# merge those entities across the objects (COMDAT) and keep the others unique; see docs/notes/multi-tu.md.
# Built per backend: one command with every source, separate objects (-c) linked afterwards by nfcxx (in both
# orders), and a mix of sources and objects. Also a minimal std::string pair (the original report).
#   NFCXX_BACKEND=gcc|qbe   (default: both)
cd "$(dirname "$0")/../.."
backends=${NFCXX_BACKEND:-"qbe gcc"}
fail=0; tmp=$(mktemp -d); trap 'rm -rf "$tmp"' EXIT
d=tests/multi-tu
srcs=($d/main.cpp $d/a.cpp $d/b.cpp $d/c.cpp)

run() {  # run NAME EXE
  if out=$("$2" 2>&1); then echo "ok   $1: $out"; else echo "FAIL $1 (run)"; head -10 <<<"$out"; fail=1; fi
}
build() {  # build NAME EXE nfcxx-args...
  local name=$1 exe=$2; shift 2
  if out=$(./nfcxx "$@" -o "$exe" 2>&1); then run "$name" "$exe"
  else echo "FAIL $name (build)"; head -10 <<<"$out"; fail=1; fi
}

for be in $backends; do
  export NFCXX_BACKEND=$be
  build "$be one command" "$tmp/one-$be" "${srcs[@]}"
  build "$be string pair" "$tmp/pair-$be" $d/pair_a.cpp $d/pair_b.cpp
  objs=(); ok=1
  for s in "${srcs[@]}" $d/pair_a.cpp $d/pair_b.cpp; do
    o=$tmp/$(basename "$s" .cpp)-$be.o
    if ! out=$(./nfcxx -c "$s" -o "$o" 2>&1); then echo "FAIL $be -c $s"; head -10 <<<"$out"; fail=1; ok=0; break; fi
    objs+=("$o")
  done
  [ $ok = 1 ] || continue
  prog=("${objs[@]:0:4}")
  build "$be separate objects" "$tmp/objs-$be" "${prog[@]}"
  rev=(); for ((i = ${#prog[@]} - 1; i >= 0; i--)); do rev+=("${prog[i]}"); done
  build "$be separate objects (reverse order)" "$tmp/rev-$be" "${rev[@]}"
  build "$be sources and objects" "$tmp/mix-$be" $d/main.cpp $d/a.cpp "${objs[@]:2:2}"
  build "$be string pair objects" "$tmp/pairobj-$be" "${objs[@]:4:2}"
done
exit $fail
