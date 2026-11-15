#!/bin/bash
# The compile cache on the gcc backend, live: the real nfcxx and the real EDG front end (build/edg) on a C++ file, twice. The
# first -c is a miss and stores its entry; the second is a hit and copies the object back (no eccp run). The cache log says
# miss then hit, both objects are identical, and the second run is not slower than the first by a build (a hit is a copy).
# This is the bash's behaviour that a Ruby planner of the cache must reproduce (tests/nfcxx-cache is the planner's test).
#   bash tests/nfcxx-cache-live/run.sh
root=$(cd "$(dirname "$0")/../.." && pwd)
tmp=$(mktemp -d); trap 'rm -rf "$tmp"' EXIT
pass=0; fail=0
ok() { echo "ok   $1"; pass=$((pass + 1)); }
bad() { echo "FAIL $1: $2"; fail=$((fail + 1)); }
[ -x "$root/build/edg/bin/eccp" ] || { echo "skip: no EDG front end (build/edg/bin/eccp)"; exit 0; }
printf 'int add(int a, int b) { return a + b; }\nint main() { return add(20, 22) - 42; }\n' > "$tmp/a.cpp"
cache=$tmp/cache; log=$tmp/cache.log
# the key covers the output path (argv, cwd, out, src), so both runs name the same object: a.o
run() { (cd "$tmp" && rm -f a.o && NFCXX_BACKEND=gcc NFCXX_CACHE="$cache" "$root/nfcxx" --cache-log="$log" -c a.cpp -o a.o 2>"$tmp/$1.err"); }
run first; rc1=$?
[ $rc1 = 0 ] && [ -s "$tmp/a.o" ] && ok "first -c builds the object" || bad "first -c builds the object" "rc=$rc1 $(head -2 "$tmp/first.err")"
cp "$tmp/a.o" "$tmp/first.o"
run second; rc2=$?
cp "$tmp/a.o" "$tmp/second.o" 2>/dev/null
[ $rc2 = 0 ] && [ -s "$tmp/second.o" ] && ok "second -c succeeds" || bad "second -c succeeds" "rc=$rc2 $(head -2 "$tmp/second.err")"
states=$(grep -E '^(miss|hit)$' "$log" | tr '\n' ' ')
[ "$states" = "miss hit " ] && ok "cache log: miss, then hit" || bad "cache log: miss, then hit" "got: $states"
cmp -s "$tmp/first.o" "$tmp/second.o" && ok "the hit's object is the built one" || bad "the hit's object is the built one" "objects differ"
n=$(find "$cache/objects" -name obj 2>/dev/null | wc -l)
[ "$n" = 1 ] && ok "one entry in the cache" || bad "one entry in the cache" "$n entries"
echo "$pass passed, $fail failed"
[ $fail = 0 ]
