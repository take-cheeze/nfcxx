#!/usr/bin/env bash
# Path B: a static function has internal linkage. Two C files that each define their own `static helper` must link into
# one program (the SSA emitter used to write every function `export`, so the second object's `helper` was a duplicate
# definition: TinyCC's static inline read32le in x86_64-gen.c and x86_64-link.c). Built with nfcc on Path B, as one command
# and as separate objects.
cd "$(dirname "$0")/../.."
d=tests/pathb-qbe/static
fail=0; tmp=$(mktemp -d); trap 'rm -rf "$tmp"' EXIT
export NFCXX_BACKEND=pathb
if ! out=$(./nfcc $d/a.c $d/b.c $d/main.c -o "$tmp/one" 2>&1); then echo "FAIL static linkage (one command)"; head -5 <<<"$out"; fail=1
elif "$tmp/one"; then echo "ok   static linkage (one command)"; else echo "FAIL static linkage (one command): wrong result"; fail=1; fi
for f in a b main; do
  ./nfcc -c $d/$f.c -o "$tmp/$f.o" 2>"$tmp/$f.err" || { echo "FAIL static linkage: -c $f.c"; head -5 "$tmp/$f.err"; fail=1; }
done
if [ $fail = 0 ]; then
  if ! out=$(./nfcc "$tmp/a.o" "$tmp/b.o" "$tmp/main.o" -o "$tmp/objs" 2>&1); then echo "FAIL static linkage (objects)"; head -5 <<<"$out"; fail=1
  elif "$tmp/objs"; then echo "ok   static linkage (objects)"; else echo "FAIL static linkage (objects): wrong result"; fail=1; fi
fi
exit $fail
