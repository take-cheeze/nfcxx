#!/usr/bin/env bash
# Path B stage 3: translation validation of the IR -> QBE emitter (scripts/pathb-qbe-emit.py).
#
# For each program: scripts/pathb-dump --ir (the harness) -> scripts/pathb-qbe-emit.py -> build/qbe/qbe ->
# cc -c -> link with EDG's runtime the way eccp links (-L build/edg/lib -lstdc++ -lgcc_s -lpthread -lC) -> run.
# The exit code must equal the // EXPECT: value. The gcc backend (NFCXX_BACKEND=gcc ./nfcxx) must agree with it.
#
#   tests/pathb-qbe/cases/*.cpp   probes of the emitted subset: arithmetic, conversions, globals, control flow.
#   tests/cases/*.cpp             the regression programs (same EXPECT values as the production runner).
#   tests/pathb-qbe/traps/*.cpp   programs whose checked operations must abort (exit status 134, SIGABRT).
#                                 Built with NFCXX_IR_OVERFLOW=trap. The gcc backend is not compared: C leaves
#                                 these cases undefined (gcc dies with SIGFPE or SIGSEGV instead).
#
# A node, type or marker the emitter does not handle is REFUSED: reported with its reason, not counted as a
# failure. Any other problem (front end, emitter error, QBE, assembler, linker, wrong exit code, gcc disagreeing
# with EXPECT) is a failure, and the script exits 1. Needs the stage 3 harness: PATHB_CPFE and PATHB_BASE must
# point at a build made by scripts/setup-pathb.sh (see docs/notes/pathb-stage3.md). Exit 2 when the harness or
# the QBE binary is missing.
cd "$(dirname "$0")/../.."
root=$PWD
cpfe=${PATHB_CPFE:-build/pathb/cmake/bin/cpfe}
[ -x "$cpfe" ] || { echo "pathb-qbe: no harness at $cpfe; set PATHB_CPFE and PATHB_BASE (docs/notes/pathb-stage3.md)" >&2; exit 2; }
qbe=${QBE:-build/qbe/qbe}
[ -x "$qbe" ] || { echo "pathb-qbe: no QBE at $qbe; run scripts/setup-qbe.sh" >&2; exit 2; }
libdir=${EDG_LIB:-$root/build/edg/lib}
export PATHB_CPFE=$cpfe
export PATHB_BASE=${PATHB_BASE:-$root/build/pathb/edg-base}
emit=scripts/pathb-qbe-emit.py

tmp=$(mktemp -d); trap 'rm -rf "$tmp"' EXIT
total=0; built=0; ran=0; match=0; refused=0; failed=0; trapped=0
lines=()

expect_of() { sed -n 's,^// EXPECT: *\(-\?[0-9]*\).*,\1,p' "$1" | head -1; }

# run_one <file> <mode: exit|trap>. Prints one table line and updates the counters.
run_one() {
  local f=$1 mode=$2 n name ir ssa s obj exe want got gcc_rc rc msg
  total=$((total + 1))
  n=$(basename "$f" .cpp); name=${f#tests/}
  ir=$tmp/$n.ir; ssa=$tmp/$n.ssa; s=$tmp/$n.s; obj=$tmp/$n.o; exe=$tmp/$n.exe
  if [ "$mode" = trap ]; then
    NFCXX_IR_OVERFLOW=trap scripts/pathb-dump --ir "$f" > "$ir" 2> "$tmp/$n.fe" || {
      failed=$((failed + 1)); lines+=("FAIL     $name: front end: $(head -1 "$tmp/$n.fe")"); return; }
  else
    scripts/pathb-dump --ir "$f" > "$ir" 2> "$tmp/$n.fe" || {
      failed=$((failed + 1)); lines+=("FAIL     $name: front end: $(head -1 "$tmp/$n.fe")"); return; }
  fi
  python3 "$emit" "$ir" > "$ssa" 2> "$tmp/$n.emit" ; rc=$?
  if [ $rc = 3 ]; then
    refused=$((refused + 1)); lines+=("REFUSED  $name: $(head -1 "$tmp/$n.emit")"); return
  fi
  if [ $rc != 0 ]; then
    failed=$((failed + 1)); lines+=("FAIL     $name: emitter: $(head -1 "$tmp/$n.emit")"); return
  fi
  if ! "$qbe" "$ssa" > "$s" 2> "$tmp/$n.qbe"; then
    failed=$((failed + 1)); lines+=("FAIL     $name: qbe rejected the emitted IL: $(head -1 "$tmp/$n.qbe")"); return
  fi
  if ! cc -c -o "$obj" "$s" 2> "$tmp/$n.as"; then
    failed=$((failed + 1)); lines+=("FAIL     $name: assembler: $(head -1 "$tmp/$n.as")"); return
  fi
  if ! cc -o "$exe" "$obj" -L"$libdir" -lstdc++ -lgcc_s -lpthread -lC 2> "$tmp/$n.ld"; then
    failed=$((failed + 1)); lines+=("FAIL     $name: link: $(grep -m1 -o "undefined reference to .*" "$tmp/$n.ld" || head -1 "$tmp/$n.ld")"); return
  fi
  built=$((built + 1))
  sh -c 'timeout 10 "$0" > /dev/null 2>&1; exit $?' "$exe"; got=$?
  ran=$((ran + 1))
  if [ "$mode" = trap ]; then
    if [ $got = 134 ]; then trapped=$((trapped + 1)); lines+=("trapped  $name (SIGABRT)")
    else failed=$((failed + 1)); lines+=("FAIL     $name: exit $got, expected a trap (134)"); fi
    return
  fi
  want=$(expect_of "$f")
  if [ -z "$want" ]; then failed=$((failed + 1)); lines+=("FAIL     $name: no // EXPECT: line"); return; fi
  gcc_rc=n/a
  if NFCXX_BACKEND=gcc ./nfcxx "$f" -o "$tmp/$n.gcc" > /dev/null 2> "$tmp/$n.gccerr"; then
    sh -c 'timeout 10 "$0" > /dev/null 2>&1; exit $?' "$tmp/$n.gcc"; gcc_rc=$?
  else
    gcc_rc=compile-error
  fi
  if [ $((got & 255)) -ne $((want & 255)) ]; then
    failed=$((failed + 1)); lines+=("MISMATCH $name: exit $got, EXPECT $want (gcc $gcc_rc)")
    return
  fi
  if [ "$gcc_rc" != "$((want & 255))" ] && [ "$gcc_rc" != "$want" ]; then
    failed=$((failed + 1)); lines+=("MISMATCH $name: path B matches EXPECT $want but gcc gives $gcc_rc")
    return
  fi
  match=$((match + 1))
  lines+=("ok       $name: exit $got = EXPECT $want (gcc $gcc_rc)")
}

# Probe the harness: a stage 2 harness has no sizes on slots and the emitter says so.
probe=$(ls tests/cases/*.cpp | head -1)
scripts/pathb-dump --ir "$probe" > "$tmp/probe.ir" 2>/dev/null
python3 "$emit" "$tmp/probe.ir" > /dev/null 2> "$tmp/probe.err"; prc=$?
if [ $prc = 1 ] && grep -q "rebuild the harness" "$tmp/probe.err"; then
  echo "pathb-qbe: the harness at $cpfe is older than stage 3; rebuild it with scripts/setup-pathb.sh" >&2; exit 2
fi

for f in tests/pathb-qbe/cases/*.cpp tests/cases/*.cpp; do
  case $(basename "$f") in qbe_*) continue ;; esac   # production-path only (system headers, GNU forms)
  [ -e "$f" ] && run_one "$f" exit
done
for f in tests/pathb-qbe/traps/*.cpp; do [ -e "$f" ] && run_one "$f" trap; done

for l in "${lines[@]}"; do echo "$l"; done
echo
echo "pathb-qbe: $total programs: $built built, $ran ran, $match match EXPECT, $trapped trapped as required, $refused refused, $failed failed"
[ $failed = 0 ] || { echo "pathb-qbe: FAILED"; exit 1; }
echo "pathb-qbe: ok"
