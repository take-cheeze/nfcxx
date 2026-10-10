#!/usr/bin/env bash
# Real-world check: nlohmann/json (MIT, single header json.hpp) at a pinned upstream release, built with nfcxx on
# the hosted path (not --freestanding). tests/realworld/json_main.cpp (one translation unit) parses, mutates,
# dumps with indentation, iterates, round-trips (text, CBOR, MessagePack), converts a user struct with
# to_json/from_json, and provokes parse/type/out_of_range exceptions. Its whole output is compared byte for byte
# with the host g++ build of the same program. The source is cloned into build/realworld, not vendored.
#   NFCXX_BACKEND=gcc|qbe   (default: both)
cd "$(dirname "$0")/../.."
root=$PWD; work=$root/build/realworld
pin=55f93686c01528224f448c19128836e7df245f72   # nlohmann/json tag v3.12.0
src=$work/json
if [ ! -d "$src/.git" ]; then
  mkdir -p "$src" && git -C "$src" init -q &&
    git -C "$src" remote add origin https://github.com/nlohmann/json || exit 1
fi
if [ "$(git -C "$src" rev-parse -q --verify "$pin^{commit}" 2>/dev/null)" != "$pin" ]; then
  git -C "$src" fetch -q --depth 1 origin "$pin" || { echo "SKIP json: fetch failed"; exit 0; }
fi
git -C "$src" checkout -q "$pin" || { echo "FAIL json: checkout $pin failed"; exit 1; }

backends=${NFCXX_BACKEND:-"gcc qbe"}
inc=$src/single_include
fail=0; tmp=$(mktemp -d); trap 'rm -rf "$tmp"' EXIT
host=${NFCXX_CXX:-g++}
if ! "$host" -std=c++17 -I"$inc" "$root/tests/realworld/json_main.cpp" -o "$tmp/host" 2>"$tmp/host.err"; then
  echo "FAIL json: host $host build"; grep error "$tmp/host.err" | head -5; exit 1
fi
"$tmp/host" > "$tmp/host.out" 2>&1 || { echo "FAIL json: host run exit $?"; exit 1; }
for b in $backends; do
  if ! out=$(NFCXX_BACKEND=$b "$root/nfcxx" -I"$inc" "$root/tests/realworld/json_main.cpp" -o "$tmp/j-$b" 2>&1); then
    echo "FAIL $b json (build)"; grep -E "error|undefined reference" <<<"$out" | head -5; fail=1; continue
  fi
  "$tmp/j-$b" > "$tmp/run-$b.out" 2>&1; got=$?
  if [ $got -ne 0 ]; then echo "FAIL $b json: exit $got"; tail -3 "$tmp/run-$b.out"; fail=1; continue; fi
  if cmp -s "$tmp/host.out" "$tmp/run-$b.out"; then echo "ok   $b json ($(wc -l < "$tmp/host.out") lines match host $host)"
  else echo "FAIL $b json: output differs from host"; diff "$tmp/host.out" "$tmp/run-$b.out" | head -10; fail=1; fi
done
exit $fail
