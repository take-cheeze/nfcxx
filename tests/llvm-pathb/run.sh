#!/usr/bin/env bash
# LLVM IR frontend for Path B (docs/notes/pathb-llvm.md): translation validation of the subset.
#
# For each tests/llvm-pathb/cases/*.c: clang-18 -O0 -S -emit-llvm (or -O1 when the program has `// OPT: 1`) ->
# scripts/llvm-to-pathb.rb -> nfcxx IR -> scripts/pathb-qbe-emit.rb -> build/qbe/qbe -> cc -> run.
# The exit code must equal the `// EXPECT:` value, and the clang -O0 binary of the same source must agree.
# `// TRAP: 1` programs are checked for SIGABRT instead (checked operations; no clang comparison, since C leaves
# the overflow undefined and clang wraps).
#
# A program the translator or the emitter refuses (exit 3, `refused: ...` on stderr) is reported, not counted as a
# failure: the subset does not cover it yet. Any other problem is a failure, and the script exits 1. Exit 2 when
# the QBE binary or clang-18 is missing.
cd "$(dirname "$0")/../.."
root=$PWD
qbe=${QBE:-build/qbe/qbe}
[ -x "$qbe" ] || { echo "llvm-pathb: no QBE at $qbe; run scripts/setup-qbe.sh" >&2; exit 2; }
clang=${CLANG:-clang-18}
command -v "$clang" >/dev/null || { echo "llvm-pathb: no $clang" >&2; exit 2; }
mrb=$root/scripts/mrb
xlate=scripts/llvm-to-pathb.rb
emit=scripts/pathb-qbe-emit.rb

tmp=$(mktemp -d); trap 'rm -rf "$tmp"' EXIT
total=0; ran=0; match=0; refused=0; failed=0; trapped=0
lines=()

expect_of() { sed -n 's,^// EXPECT: *\(-*[0-9]*\).*,\1,p' "$1" | head -1; }
opt_of() { sed -n 's,^// OPT: *\([0-9]\).*,-O\1,p' "$1" | head -1; }
trap_of() { sed -n 's,^// TRAP: *1.*,1,p' "$1" | head -1; }

run_case() {
  local src=$1 name=$2 opt=${3:--O0} expect=$4 trapping=$5
  local ll=$tmp/$name.ll ir=$tmp/$name.ir ssa=$tmp/$name.ssa s=$tmp/$name.s exe=$tmp/$name
  total=$((total + 1))
  if ! "$clang" "$opt" -w -S -emit-llvm -fno-discard-value-names -o "$ll" "$src" 2> "$tmp/$name.clang"; then
    failed=$((failed + 1)); lines+=("FAIL     $name: clang rejected the source: $(head -1 "$tmp/$name.clang")"); return
  fi
  "$mrb" "$xlate" "$ll" > "$ir" 2> "$tmp/$name.xlate"
  local rc=$?
  if [ "$rc" != 0 ]; then
    if grep -q '^refused:' "$tmp/$name.xlate"; then
      refused=$((refused + 1)); lines+=("REFUSED  $name: $(grep '^refused:' "$tmp/$name.xlate" | head -1)"); return
    fi
    failed=$((failed + 1)); lines+=("FAIL     $name: translator exit $rc: $(head -1 "$tmp/$name.xlate")"); return
  fi
  "$mrb" "$emit" "$ir" > "$ssa" 2> "$tmp/$name.emit"
  local rc=$?
  if [ "$rc" != 0 ]; then
    if [ "$rc" = 3 ]; then
      refused=$((refused + 1)); lines+=("REFUSED  $name: emitter: $(head -1 "$tmp/$name.emit")"); return
    fi
    failed=$((failed + 1)); lines+=("FAIL     $name: emitter exit $rc: $(head -1 "$tmp/$name.emit")"); return
  fi
  if ! "$qbe" "$ssa" > "$s" 2> "$tmp/$name.qbe"; then
    failed=$((failed + 1)); lines+=("FAIL     $name: qbe rejected the IL: $(head -1 "$tmp/$name.qbe")"); return
  fi
  if ! cc -o "$exe" "$s" -lm 2> "$tmp/$name.link"; then
    failed=$((failed + 1)); lines+=("FAIL     $name: link: $(head -1 "$tmp/$name.link")"); return
  fi
  ran=$((ran + 1))
  # The shell reports a signal death on its own stderr; the substitution keeps that message out of the log.
  local got
  got=$( { "$exe" > /dev/null 2>&1; echo $?; } 2> /dev/null )
  if [ "$trapping" = 1 ]; then
    if [ "$got" = 134 ]; then
      trapped=$((trapped + 1)); lines+=("TRAPPED  $name")
    else
      failed=$((failed + 1)); lines+=("FAIL     $name: exit $got, expected SIGABRT (134)")
    fi
    return
  fi
  if [ "$got" != "$expect" ]; then
    failed=$((failed + 1)); lines+=("FAIL     $name: exit $got, EXPECT $expect"); return
  fi
  # The clang -O0 binary of the same source is the reference.
  "$clang" -O0 -w -o "$tmp/$name.ref" "$src" 2> /dev/null && "$tmp/$name.ref" > /dev/null 2>&1
  local ref=$?
  if [ "$ref" != "$got" ]; then
    failed=$((failed + 1)); lines+=("FAIL     $name: exit $got, clang -O0 exit $ref"); return
  fi
  match=$((match + 1)); lines+=("OK       $name: exit $got = EXPECT = clang -O0")
}

for src in tests/llvm-pathb/cases/*.c; do
  [ -e "$src" ] || continue
  name=$(basename "$src" .c)
  expect=$(expect_of "$src")
  trapping=$(trap_of "$src")
  if [ -z "$expect" ] && [ "$trapping" != 1 ]; then
    failed=$((failed + 1)); lines+=("FAIL     $name: no // EXPECT: line"); total=$((total + 1)); continue
  fi
  run_case "$src" "$name" "$(opt_of "$src" | grep . || echo -O0)" "$expect" "$trapping"
done

printf '%s\n' "${lines[@]}"
echo
echo "llvm-pathb: $total programs: $ran built and ran, $match match EXPECT and clang -O0, $trapped trapped as required, $refused refused, $failed failed"
[ "$failed" = 0 ]
