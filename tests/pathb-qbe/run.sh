#!/usr/bin/env bash
# Path B stage 3: translation validation of the IR -> QBE emitter (scripts/pathb-qbe-emit.rb, run by the mruby interpreter, scripts/mrb).
#
# For each program: scripts/pathb-dump --ir (the harness) -> scripts/pathb-qbe-emit.rb -> build/qbe/qbe ->
# cc -c -> link with EDG's runtime the way eccp links (-L build/edg/lib -lC -lstdc++ -lgcc_s -lpthread; libC.a first, so EDG's EH runtime and operator new/delete win) -> run.
# The exit code must equal the // EXPECT: value. The gcc backend (NFCXX_BACKEND=gcc ./nfcxx) must agree with it.
#
#   tests/pathb-qbe/cases/*.cpp   probes of the emitted subset: arithmetic, conversions, globals, control flow,
#                                 `continue`, bool loads, unreachable code. A probe with a `// GCC: undefined` line
#                                 relies on a case C++ leaves undefined: only EXPECT is checked, gcc is not compared.
#                                 volatile.cpp and tls.cpp: volatile accesses and thread-local objects (a second pthread).
#                                 A probe may carry `// ASM-COUNT: FUNCTION PREFIX N` lines: the assembly of FUNCTION must
#                                 call exactly N functions whose name starts with PREFIX (check_asm below).
#                                 A probe with a `// STDOUT: same` line also needs the same standard output as the gcc
#                                 backend (dyn_*.cpp: constructor/destructor order of global, static and heap objects).
#                                 eh_*.cpp: C++ exceptions through EDG's setjmp/longjmp ABI and the runtime in libC.a
#                                 (docs/notes/pathb-stage3.md, "C++ exceptions"). `// STD: c++14` selects the standard.
#   tests/cases/*.cpp             the regression programs (same EXPECT values as the production runner).
#   tests/pathb-qbe/multi/*/      programs of several translation units (all *.cpp of a directory, linked together):
#                                 COMDAT/weak linkage of inline and template code from a shared header.
#   tests/pathb-qbe/traps/*.cpp   programs whose checked operations must abort (exit status 134, SIGABRT); a
#                                 `// TRAP-STDERR: text` line also requires that text on stderr (EH runtime messages).
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
emit=scripts/pathb-qbe-emit.rb
mrb=$root/scripts/mrb

tmp=$(mktemp -d); trap 'rm -rf "$tmp"' EXIT
total=0; built=0; ran=0; match=0; refused=0; failed=0; trapped=0
lines=()

expect_of() { sed -n 's,^// EXPECT: *\(-\?[0-9]*\).*,\1,p' "$1" | head -1; }
# `// STD: c++14` in a probe selects the language standard (default c++23), for pathb-dump and for the gcc backend.
# C++ exceptions: dynamic exception specifications exist only before C++17.
std_of() { sed -n 's,^// STD: *\(c++[0-9]*\).*,-std=\1,p' "$1" | head -1; }

# check_asm <source> <asm>: the "// ASM-COUNT: FUNCTION PREFIX N" lines of a probe. The assembly of FUNCTION must
# contain exactly N call instructions whose callee starts with PREFIX. Volatile accesses are calls of helper
# functions (docs/notes/pathb-stage3.md), so this shows that QBE kept every one of them (and, with N = 0 on the same
# code without volatile, that the count means something). Prints the reason and fails when a count is wrong.
check_asm() {
  local src=$1 asm=$2 fnname prefix want got
  while read -r fnname prefix want; do
    got=$(awk -v f="$fnname" -v p="$prefix" '
      $0 == f ":" { on = 1; next }
      on && /^\.size / { on = 0 }
      on && $1 == "callq" && index($2, p) == 1 { n++ }
      END { print n + 0 }' "$asm")
    if [ "$got" != "$want" ]; then echo "asm check: $fnname has $got calls to $prefix*, expected $want"; return 1; fi
  done < <(sed -n 's,^// ASM-COUNT: *\([A-Za-z_0-9]*\) \([A-Za-z_0-9]*\) \([0-9]*\).*,\1 \2 \3,p' "$src")
  return 0
}

# run_one <file> <mode: exit|trap>. Prints one table line and updates the counters.
run_one() {
  local f=$1 mode=$2 n name ir ssa s obj exe want got gcc_rc rc msg std
  std=$(std_of "$f")
  total=$((total + 1))
  n=$(basename "$f" .cpp); name=${f#tests/}
  ir=$tmp/$n.ir; ssa=$tmp/$n.ssa; s=$tmp/$n.s; obj=$tmp/$n.o; exe=$tmp/$n.exe
  if [ "$mode" = trap ]; then
    NFCXX_IR_OVERFLOW=trap scripts/pathb-dump --ir $std "$f" > "$ir" 2> "$tmp/$n.fe" || {
      failed=$((failed + 1)); lines+=("FAIL     $name: front end: $(head -1 "$tmp/$n.fe")"); return; }
  else
    scripts/pathb-dump --ir $std "$f" > "$ir" 2> "$tmp/$n.fe" || {
      failed=$((failed + 1)); lines+=("FAIL     $name: front end: $(head -1 "$tmp/$n.fe")"); return; }
  fi
  "$mrb" "$emit" "$ir" > "$ssa" 2> "$tmp/$n.emit" ; rc=$?
  if [ $rc = 3 ]; then
    refused=$((refused + 1)); lines+=("REFUSED  $name: $(head -1 "$tmp/$n.emit")"); return
  fi
  if [ $rc != 0 ]; then
    failed=$((failed + 1)); lines+=("FAIL     $name: emitter: $(head -1 "$tmp/$n.emit")"); return
  fi
  if ! "$qbe" "$ssa" > "$s" 2> "$tmp/$n.qbe"; then
    failed=$((failed + 1)); lines+=("FAIL     $name: qbe rejected the emitted IL: $(head -1 "$tmp/$n.qbe")"); return
  fi
  "$mrb" "$emit" --append-weak "$ssa" "$s"   # QBE has no weak linkage: .weak for the IR's (weak) definitions
  if ! check_asm "$f" "$s" > "$tmp/$n.asmcheck"; then
    failed=$((failed + 1)); lines+=("FAIL     $name: $(head -1 "$tmp/$n.asmcheck")"); return
  fi
  if ! cc -c -o "$obj" "$s" 2> "$tmp/$n.as"; then
    failed=$((failed + 1)); lines+=("FAIL     $name: assembler: $(head -1 "$tmp/$n.as")"); return
  fi
  if ! cc -o "$exe" "$obj" -L"$libdir" -lC -lstdc++ -lgcc_s -lpthread 2> "$tmp/$n.ld"; then
    failed=$((failed + 1)); lines+=("FAIL     $name: link: $(grep -m1 -o "undefined reference to .*" "$tmp/$n.ld" || head -1 "$tmp/$n.ld")"); return
  fi
  built=$((built + 1))
  sh -c 'timeout 10 "$0" > "$1" 2> "$2"; exit $?' "$exe" "$tmp/$n.stdout" "$tmp/$n.rt"; got=$?
  ran=$((ran + 1))
  if [ "$mode" = trap ]; then
    # A `// TRAP-STDERR: text` line names a message the abort must have printed, so that a program which aborts for
    # another reason (a broken unwinder, say) is not taken for the trap it is testing.
    want=$(sed -n 's,^// TRAP-STDERR: *\(.*\),\1,p' "$f" | head -1)
    if [ $got != 134 ]; then failed=$((failed + 1)); lines+=("FAIL     $name: exit $got, expected a trap (134)")
    elif [ -n "$want" ] && ! grep -qF "$want" "$tmp/$n.rt"; then
      failed=$((failed + 1)); lines+=("FAIL     $name: aborted, but stderr lacks '$want'")
    else trapped=$((trapped + 1)); lines+=("trapped  $name (SIGABRT)"); fi
    return
  fi
  want=$(expect_of "$f")
  if [ -z "$want" ]; then failed=$((failed + 1)); lines+=("FAIL     $name: no // EXPECT: line"); return; fi
  gcc_rc=n/a
  if grep -q '^// GCC: undefined' "$f"; then
    # The program relies on a case C++ leaves undefined (a bool holding 2): gcc is not compared.
    if [ $((got & 255)) -ne $((want & 255)) ]; then
      failed=$((failed + 1)); lines+=("MISMATCH $name: exit $got, EXPECT $want (gcc not compared)"); return
    fi
    match=$((match + 1)); lines+=("ok       $name: exit $got = EXPECT $want (gcc not compared: undefined in C++)"); return
  fi
  if NFCXX_BACKEND=gcc ./nfcxx $std "$f" -o "$tmp/$n.gcc" > /dev/null 2> "$tmp/$n.gccerr"; then
    sh -c 'timeout 10 "$0" > "$1" 2>/dev/null; exit $?' "$tmp/$n.gcc" "$tmp/$n.gcc.stdout"; gcc_rc=$?
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
  # A probe with a `// STDOUT: same` line prints (constructor and destructor order, ...): the output of the Path B
  # program must be byte for byte the output of the gcc backend's program.
  if grep -q '^// STDOUT: same' "$f" && ! cmp -s "$tmp/$n.stdout" "$tmp/$n.gcc.stdout"; then
    failed=$((failed + 1)); lines+=("MISMATCH $name: stdout differs from the gcc backend: $(diff "$tmp/$n.stdout" "$tmp/$n.gcc.stdout" | head -3 | tr '\n' '|')")
    return
  fi
  match=$((match + 1))
  lines+=("ok       $name: exit $got = EXPECT $want (gcc $gcc_rc)")
}

# run_multi <dir>: a program of several translation units (every *.cpp in the directory). Each unit goes through
# the pipeline separately, the objects are linked together, and the exit code must equal the // EXPECT: value of the
# unit that has one. This is where COMDAT/weak definitions (inline and template code in a shared header) must merge.
# The gcc backend (all units in one nfcxx call) must agree.
run_multi() {
  local d=$1 n name f b obj objs=() want got gcc_rc srcs=() exe
  total=$((total + 1))
  n=$(basename "$d"); name=${d#tests/}; exe=$tmp/multi_$n.exe
  for f in "$d"/*.cpp; do
    b=multi_${n}_$(basename "$f" .cpp); obj=$tmp/$b.o; srcs+=("$f")
    scripts/pathb-dump --ir "$f" > "$tmp/$b.ir" 2> "$tmp/$b.fe" || {
      failed=$((failed + 1)); lines+=("FAIL     $name: front end ($f): $(head -1 "$tmp/$b.fe")"); return; }
    "$mrb" "$emit" "$tmp/$b.ir" > "$tmp/$b.ssa" 2> "$tmp/$b.emit"; rc=$?
    if [ $rc = 3 ]; then refused=$((refused + 1)); lines+=("REFUSED  $name: $(head -1 "$tmp/$b.emit")"); return; fi
    if [ $rc != 0 ]; then failed=$((failed + 1)); lines+=("FAIL     $name: emitter: $(head -1 "$tmp/$b.emit")"); return; fi
    "$qbe" "$tmp/$b.ssa" > "$tmp/$b.s" 2> "$tmp/$b.qbe" || {
      failed=$((failed + 1)); lines+=("FAIL     $name: qbe rejected the emitted IL: $(head -1 "$tmp/$b.qbe")"); return; }
    "$mrb" "$emit" --append-weak "$tmp/$b.ssa" "$tmp/$b.s"
    cc -c -o "$obj" "$tmp/$b.s" 2> "$tmp/$b.as" || {
      failed=$((failed + 1)); lines+=("FAIL     $name: assembler: $(head -1 "$tmp/$b.as")"); return; }
    objs+=("$obj")
  done
  if ! cc -o "$exe" "${objs[@]}" -L"$libdir" -lC -lstdc++ -lgcc_s -lpthread 2> "$tmp/multi_$n.ld"; then
    failed=$((failed + 1)); lines+=("FAIL     $name: link: $(grep -m1 -o "multiple definition of .*\|undefined reference to .*" "$tmp/multi_$n.ld" || head -1 "$tmp/multi_$n.ld")"); return
  fi
  built=$((built + 1))
  sh -c 'timeout 10 "$0" > /dev/null 2>&1; exit $?' "$exe"; got=$?
  ran=$((ran + 1))
  want=$(for f in "$d"/*.cpp; do expect_of "$f"; done | head -1)
  if [ -z "$want" ]; then failed=$((failed + 1)); lines+=("FAIL     $name: no // EXPECT: line"); return; fi
  gcc_rc=compile-error
  if NFCXX_BACKEND=gcc ./nfcxx "${srcs[@]}" -o "$tmp/multi_$n.gcc" > /dev/null 2> "$tmp/multi_$n.gccerr"; then
    sh -c 'timeout 10 "$0" > /dev/null 2>&1; exit $?' "$tmp/multi_$n.gcc"; gcc_rc=$?
  fi
  if [ $((got & 255)) -ne $((want & 255)) ]; then
    failed=$((failed + 1)); lines+=("MISMATCH $name: exit $got, EXPECT $want (gcc $gcc_rc)"); return
  fi
  if [ "$gcc_rc" != "$((want & 255))" ]; then
    failed=$((failed + 1)); lines+=("MISMATCH $name: path B matches EXPECT $want but gcc gives $gcc_rc"); return
  fi
  match=$((match + 1))
  lines+=("ok       $name: exit $got = EXPECT $want (gcc $gcc_rc), ${#objs[@]} translation units")
}

# Probe the harness: a stage 2 harness has no sizes on slots and the emitter says so.
probe=$(ls tests/cases/*.cpp | head -1)
scripts/pathb-dump --ir "$probe" > "$tmp/probe.ir" 2>/dev/null
"$mrb" "$emit" "$tmp/probe.ir" > /dev/null 2> "$tmp/probe.err"; prc=$?
if [ $prc = 1 ] && grep -q "rebuild the harness" "$tmp/probe.err"; then
  echo "pathb-qbe: the harness at $cpfe is older than stage 3; rebuild it with scripts/setup-pathb.sh" >&2; exit 2
fi

# PATHB_ONLY=REGEX runs only the programs whose path matches (quick iteration on one probe).
only=${PATHB_ONLY:-.}
for f in tests/pathb-qbe/cases/*.cpp tests/cases/*.cpp; do
  case $(basename "$f") in qbe_*) continue ;; esac   # production-path only (system headers, GNU forms)
  [[ $f =~ $only ]] || continue
  [ -e "$f" ] && run_one "$f" exit
done
for f in tests/pathb-qbe/traps/*.cpp; do [[ $f =~ $only ]] && [ -e "$f" ] && run_one "$f" trap; done
for d in tests/pathb-qbe/multi/*/; do [[ $d =~ $only ]] && [ -d "$d" ] && run_multi "${d%/}"; done

for l in "${lines[@]}"; do echo "$l"; done
echo
echo "pathb-qbe: $total programs: $built built, $ran ran, $match match EXPECT, $trapped trapped as required, $refused refused, $failed failed"
[ $failed = 0 ] || { echo "pathb-qbe: FAILED"; exit 1; }
echo "pathb-qbe: ok"
