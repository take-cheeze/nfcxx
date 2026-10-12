#!/usr/bin/env bash
# C++ front-end checks: the prelinker and the link of EDG's output, and the --emit-c driver options.
#   1. std::filesystem::directory_iterator holds a shared_ptr<_Dir>, whose complete-object destructor (D1) must be
#      emitted (gcc backend: scripts/gcc-cc makes it weak; qbe: its link already works).
#   2. Two or three units that use the same destructor link to one copy of each (gcc: the .weak step of gcc-cc).
#   3. std::make_shared on the qbe backend: the <memory> include pulls in std::numbers' _Float16 variables.
#   4. --emit-c takes the user's -I directories.
set -euo pipefail
cd "$(dirname "$0")"
root=$(cd ../.. && pwd)
out=$(mktemp -d)
trap 'rm -rf "$out"' EXIT
fail=0
run_prog() {  # run_prog NAME BACKEND SOURCES...: compile, link and run; the program prints "ok" and exits 0
  local name=$1 be=$2; shift 2
  local objs=() src
  for src in "$@"; do
    local o=$out/$(basename "$src" .cpp).o
    if ! NFCXX_BACKEND=$be "$root/nfcxx" -c "$src" -o "$o" > "$out/c.log" 2>&1; then
      echo "FAIL $name ($be): compile $(basename "$src"): $(grep -m1 error "$out/c.log" | cut -c1-120)"; fail=1; return
    fi
    objs+=("$o")
  done
  if ! NFCXX_BACKEND=$be "$root/nfcxx" "${objs[@]}" -o "$out/prog" > "$out/l.log" 2>&1; then
    echo "FAIL $name ($be): link $(grep -m1 'multiple\|undefined' "$out/l.log" | cut -c1-160)"; fail=1; return
  fi
  if [ "$("$out/prog" 2>/dev/null)" = "ok" ]; then echo "ok   $name ($be)"; else echo "FAIL $name ($be): run"; fail=1; fi
}
for be in gcc qbe; do
  run_prog "directory_iterator, one unit" $be dir_shared.cpp
done
run_prog "directory_iterator, three units" gcc dir_shared_tu2.cpp dir_shared_tu3.cpp dir_shared_main.cpp
run_prog "shared_ptr" qbe shared_ptr_qbe.cpp

# 4. --emit-c with a user -I directory: the header's declaration must reach the generated C.
if "$root/nfcxx" --emit-c -Iinc emit_inc.cpp > "$out/emit.c" 2> "$out/emit.err" && grep -q from_inc_dir "$out/emit.c"; then
  echo "ok   --emit-c -I"
else
  echo "FAIL --emit-c -I: $(head -c 160 "$out/emit.err")"; fail=1
fi
exit $fail
