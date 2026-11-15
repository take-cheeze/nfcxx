#!/bin/bash
# The gcc planner's cache, live: scripts/nfcxx.rb (the planned route) and the bash nfcxx share one cache. An entry the planner
# stores is a hit for the bash, and an entry the bash stores is a hit for the planner; the objects are identical. The keys are
# the same only when the planner passes the bash's key inputs (the arguments, the environment, the dependency list, the files).
#   bash tests/nfcxx-cache-live/planned.sh
root=$(cd "$(dirname "$0")/../.." && pwd)
tmp=$(mktemp -d); trap 'rm -rf "$tmp"' EXIT
pass=0; fail=0
ok() { echo "ok   $1"; pass=$((pass + 1)); }
bad() { echo "FAIL $1: $2"; fail=$((fail + 1)); }
[ -x "$root/build/edg/bin/eccp" ] || { echo "skip: no EDG front end (build/edg/bin/eccp)"; exit 0; }
printf 'int add(int a, int b) { return a + b; }\nint main() { return add(20, 22) - 42; }\n' > "$tmp/a.cpp"
cache=$tmp/cache
planned() { (cd "$tmp" && rm -f a.o && NFCXX_CACHE="$cache" NFCXX_CACHE_LOG="$1" "$root/scripts/nfcxx.rb" --backend=gcc -c a.cpp -o a.o 2>"$tmp/p.err"); }
bashc() { (cd "$tmp" && rm -f a.o && NFCXX_CACHE="$cache" NFCXX_CACHE_LOG="$1" "$root/nfcxx" --backend=gcc -c a.cpp -o a.o 2>"$tmp/b.err"); }
planned "$tmp/log1.txt"; rc=$?
[ $rc = 0 ] && grep -qx miss "$tmp/log1.txt" && ok "planned first run: miss, stores" || bad "planned first run: miss, stores" "rc=$rc $(grep -E '^(miss|hit)$' "$tmp/log1.txt" | tr '\n' ' ') $(head -2 "$tmp/p.err")"
cp "$tmp/a.o" "$tmp/planned.o"
bashc "$tmp/log2.txt"; rc=$?
[ $rc = 0 ] && grep -qx hit "$tmp/log2.txt" && ok "bash reads the planner's entry as a hit" || bad "bash reads the planner's entry as a hit" "rc=$rc $(grep -E '^(miss|hit)$' "$tmp/log2.txt" | tr '\n' ' ')"
cmp -s "$tmp/a.o" "$tmp/planned.o" && ok "the bash's copy is the planner's object" || bad "the bash's copy is the planner's object" "objects differ"
rm -rf "$cache"
bashc "$tmp/log3.txt"; rc=$?
[ $rc = 0 ] && grep -qx miss "$tmp/log3.txt" && ok "bash first run on a fresh cache: miss, stores" || bad "bash first run on a fresh cache: miss, stores" "rc=$rc"
cp "$tmp/a.o" "$tmp/bash.o"
planned "$tmp/log4.txt"; rc=$?
[ $rc = 0 ] && grep -qx hit "$tmp/log4.txt" && ok "planner reads the bash's entry as a hit" || bad "planner reads the bash's entry as a hit" "rc=$rc $(grep -E '^(miss|hit)$' "$tmp/log4.txt" | tr '\n' ' ')"
cmp -s "$tmp/a.o" "$tmp/bash.o" && ok "the planner's copy is the bash's object" || bad "the planner's copy is the bash's object" "objects differ"
echo "$pass passed, $fail failed"
[ $fail = 0 ]
