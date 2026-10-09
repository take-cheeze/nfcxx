#!/usr/bin/env bash
# Real-world check: build tinyxml2 (zlib license) at a pinned upstream commit with nfcxx and run a
# small driver. The source is cloned into build/realworld, not vendored.
#   NFCXX_BACKEND=gcc|qbe   (default: both)
# A backend failure is reported as a FAIL unless it matches a known gap listed in KNOWN below.
cd "$(dirname "$0")/../.."
root=$PWD; work=$root/build/realworld
pin=8224e427b655b83dae5e2298f1e6919523a78737   # leethomason/tinyxml2 master, 2026-05-23
src=$work/tinyxml2
if [ ! -d "$src/.git" ]; then
  mkdir -p "$src" && git -C "$src" init -q &&
    git -C "$src" remote add origin https://github.com/leethomason/tinyxml2 || exit 1
fi
if [ "$(git -C "$src" rev-parse -q --verify "$pin^{commit}" 2>/dev/null)" != "$pin" ]; then
  git -C "$src" fetch -q --depth 1 origin "$pin" || { echo "SKIP tinyxml2: fetch failed"; exit 0; }
fi
git -C "$src" checkout -q "$pin" || { echo "FAIL tinyxml2: checkout $pin failed"; exit 1; }

backends=${NFCXX_BACKEND:-"gcc qbe"}
fail=0; tmp=$(mktemp -d); trap 'rm -rf "$tmp"' EXIT
for b in $backends; do
  if ! out=$(NFCXX_BACKEND=$b "$root/nfcxx" -I"$src" "$root/tests/realworld/tinyxml2_main.cpp" "$src/tinyxml2.cpp" \
             -o "$tmp/t-$b" 2>&1); then
    if [ "$b" = qbe ] && grep -q "no type in struct member" <<<"$out"; then
      echo "xfail qbe tinyxml2: cproc rejects empty classes (docs/notes/freestanding.md)"; continue
    fi
    echo "FAIL $b tinyxml2 (build)"; head -5 <<<"$out"; fail=1; continue
  fi
  "$tmp/t-$b"; got=$?
  if [ $got -eq 12 ]; then echo "ok   $b tinyxml2"; else echo "FAIL $b tinyxml2: want 12 got $got"; fail=1; fi
done
exit $fail
