#!/usr/bin/env bash
# mruby scripting check (docs/notes/mruby-scripting.md): every script ported from Python to mruby must
# give byte-identical output to the Python original on real inputs. The Python originals live on as the
# oracles in tests/mruby/oracle/ (they are no longer used by the build).
#   1. scripts/weak-symbols.{py,rb}: the assembly QBE produces for generated C of several tests/cases.
#   2. tests/hexagon/flatlink.{py,rb}: Hexagon objects (clang, if it has the hexagon target) built from
#      the generated C of several tests/cases and the HVX kernel; output image, stderr and exit status.
#   3. scripts/pathb-qbe-emit.{py,rb}: the QBE IL (stdout), stderr text and exit status over every IR in
#      tests/pathb-ir (goldens), tests/mruby/pathb-edge (hand-written IR: constants, floats, data, every
#      refusal and error path) and, when the Path B harness exists, the IR of tests/pathb-qbe/{cases,multi,
#      traps} and tests/cases; plus --no-prune, stdin, usage errors and --append-weak.
#   4. scripts/qbe-prep.{py,rb}: tests/mruby/qbe-prep.sh (its own header says what it compares).
# Parts whose tools are missing (EDG, QBE, hexagon clang, the Path B harness) are skipped with a message.
#   CLANG (default clang)   MRB (an existing mruby executable; default build/mruby-tool/bin/mruby)
#   PATHB_CPFE, PATHB_BASE  the Path B harness (default build/pathb/...), as for tests/pathb-qbe/run.sh
cd "$(dirname "$0")/../.."
root=$PWD; oracle=$root/tests/mruby/oracle; clang=${CLANG:-clang}
tmp=$(mktemp -d); trap 'rm -rf "$tmp"' EXIT
fail=0; pass=0; skip=0

command -v python3 >/dev/null || { echo "SKIP mruby: python3 not installed"; exit 0; }
if [ ! -x "${MRB:-$root/build/mruby-tool/bin/mruby}" ]; then
  command -v ruby >/dev/null || { echo "SKIP mruby: ruby (needed to build mruby) not installed"; exit 0; }
  "$root/scripts/setup-mruby.sh" || { echo "FAIL mruby: setup-mruby.sh failed"; exit 1; }
fi
mrb=$root/scripts/mrb

# Sanity: the interpreter works and has the gems the scripts use.
got=$("$mrb" -e 'puts [1, 258].pack("vV").unpack("vV").inspect + format("%04x", 255) + Set.new([1]).size.to_s' 2>&1)
if [ "$got" != '[1, 258]00ff1' ]; then echo "FAIL mruby: interpreter sanity check gave '$got'"; exit 1; fi
echo "ok   mruby interpreter (pack, sprintf, Set)"

report() { # report <ok|fail|skip> message
  case $1 in
    ok) echo "ok   $2"; pass=$((pass + 1)) ;;
    skip) echo "skip $2"; skip=$((skip + 1)) ;;
    *) echo "FAIL $2"; fail=1 ;;
  esac
}

# ---- 1. weak-symbols ------------------------------------------------------------------------------
if [ -x "$root/build/edg/bin/cpfe" ] && [ -x "$root/build/qbe/qbe" ] && [ -x "$root/build/cproc/cproc-qbe" ]; then
  weak_total=0
  for n in templates_lambdas raii_templates_class virtual_dispatch exceptions qbe_gnu_forms constexpr_static \
           struct_libc qbe_atomics qbe_global_ctor; do
    f=$root/tests/cases/$n.cpp
    if ! "$root/nfcxx" --emit-c "$f" >"$tmp/$n.c" 2>"$tmp/$n.err"; then report skip "weak-symbols $n: front end failed"; continue; fi
    cc -E -P -undef -D__CPROC__ "$tmp/$n.c" >"$tmp/$n.pp.c" 2>/dev/null
    if ! "$mrb" "$root/scripts/qbe-prep.rb" "$tmp/$n.pp.c" "$tmp/$n.prep.c" "$tmp/$n.tail.s" 2>/dev/null ||
       ! "$root/build/cproc/cproc-qbe" <"$tmp/$n.prep.c" >"$tmp/$n.ssa" 2>/dev/null ||
       ! "$root/build/qbe/qbe" "$tmp/$n.ssa" >"$tmp/$n.s" 2>/dev/null; then
      report skip "weak-symbols $n: QBE pipeline failed"; continue
    fi
    cp "$tmp/$n.s" "$tmp/$n.py.s"; cp "$tmp/$n.s" "$tmp/$n.rb.s"
    python3 "$oracle/weak-symbols.py" "$tmp/$n.prep.c" "$tmp/$n.py.s"
    "$mrb" "$root/scripts/weak-symbols.rb" "$tmp/$n.prep.c" "$tmp/$n.rb.s"
    k=$(grep -c '^\.weak ' "$tmp/$n.py.s")
    if cmp -s "$tmp/$n.py.s" "$tmp/$n.rb.s"; then report ok "weak-symbols $n ($k .weak lines identical)"; weak_total=$((weak_total + k))
    else report fail "weak-symbols $n: output differs"; diff "$tmp/$n.py.s" "$tmp/$n.rb.s" | head -5; fi
  done
  # The comparison must not be vacuous.
  if [ $weak_total -eq 0 ]; then report fail "weak-symbols: no input produced a .weak line"; fi
  # Hand-made edge cases for the scanner: attributes with nested parentheses, declarations, no match.
  cat >"$tmp/edge.c" <<'EOF'
int __attribute__((__weak__)) alpha(int x) { return x; }
static __attribute__((__weak__, __aligned__(__alignof__((long))))) void beta ( void ) { }
extern void gamma_decl(void) __attribute__((__weak__));
__attribute__((__weak__)) int *delta(void) { return 0; }
struct S { int v; } __attribute__((__weak__)) obj;
int not_weak(int y) { return y; }
__attribute__((__weak__)) const unsigned cmp_id = sizeof(int);
extern __attribute__((__weak__)) char lits[24];
void (**retfn(int a))(void *) { return 0; }
__attribute__((__weak__)) void (**retfn_weak(int a))(void *) { return 0; }
extern __inline__ __attribute__((__always_inline__)) char *ext_inline(int n) { return 0; }
static __inline__ int static_inline(int n) { return n; }
EOF
  printf 'cmp_id:\nlits:\nretfn:\nretfn_weak:\next_inline:\nstatic_inline:\nalpha:\n\tret\nbeta:\n\tret\ngamma_decl:\nobj:\ndelta:\n\tret\n.Lx:\nnot_weak:\n  bad:\n' >"$tmp/edge.s"
  cp "$tmp/edge.s" "$tmp/edge.py.s"; cp "$tmp/edge.s" "$tmp/edge.rb.s"
  python3 "$oracle/weak-symbols.py" "$tmp/edge.c" "$tmp/edge.py.s"
  "$mrb" "$root/scripts/weak-symbols.rb" "$tmp/edge.c" "$tmp/edge.rb.s"
  if cmp -s "$tmp/edge.py.s" "$tmp/edge.rb.s" && [ "$(grep -c '^\.weak ' "$tmp/edge.py.s")" -ge 3 ]; then
    report ok "weak-symbols edge cases (nested attributes, declarations)"
  else report fail "weak-symbols edge cases differ"; diff "$tmp/edge.py.s" "$tmp/edge.rb.s" | head -5; fi
  # No-op case: the assembly is left untouched when nothing is weak.
  cp "$tmp/edge.s" "$tmp/none.s"; "$mrb" "$root/scripts/weak-symbols.rb" /dev/null "$tmp/none.s"
  if cmp -s "$tmp/edge.s" "$tmp/none.s"; then report ok "weak-symbols no-op leaves the assembly untouched"
  else report fail "weak-symbols no-op changed the assembly"; fi
else
  report skip "weak-symbols: needs EDG and QBE (scripts/setup-edg.sh, scripts/setup-qbe.sh)"
fi

# ---- 2. flatlink ----------------------------------------------------------------------------------
triple=hexagon-unknown-linux-musl
here=$root/tests/hexagon
if ! echo 'int f(void){return 0;}' | $clang --target=$triple -ffreestanding -c -x c - -o /dev/null 2>/dev/null; then
  report skip "flatlink: $clang has no hexagon target"
else
  objs=()
  # The hand-written HVX kernel needs no front end.
  if $clang --target=$triple -ffreestanding -fno-pic -O2 -mhvx -mhvx-length=128b -w -c "$here/hvx_vaddh.c" -o "$tmp/hvx_vaddh.o" 2>/dev/null; then
    objs+=(hvx_vaddh)
  fi
  # An object flatlink must refuse (undefined symbol): the SKIP-undef message has to match too.
  printf 'extern int ext(void);\nint _start(void) { return ext(); }\n' >"$tmp/undef.c"
  $clang --target=$triple -ffreestanding -fno-pic -G0 -O2 -w -c "$tmp/undef.c" -o "$tmp/undef.o" 2>/dev/null && objs+=(undef)
  if [ -x "$root/build/edg/bin/cpfe" ]; then
    for f in "$root"/tests/cases/*.cpp; do
      n=$(basename "$f" .cpp)
      "$root/scripts/gen-c-target.sh" -t linux_riscv32 -o "$tmp/$n.c" "$f" 2>/dev/null || continue
      cat "$here/stub.c" >>"$tmp/$n.c"
      ehdef=
      if grep -q '__throw_setup\|__rethrow\|__internal_rethrow' "$tmp/$n.c"; then ehdef=-DNFCXX_EH_RT; cat "$here/eh_rt.c" >>"$tmp/$n.c"; fi
      $clang --target=$triple -ffreestanding -fno-pic -G0 -O2 -fwrapv -fno-strict-aliasing -w $ehdef \
        -c "$tmp/$n.c" -o "$tmp/$n.o" 2>/dev/null && objs+=("$n")
    done
  else
    report skip "flatlink: EDG not built, only the HVX kernel is checked"
  fi
  linked=0
  for n in "${objs[@]}"; do
    python3 "$oracle/flatlink.py" "$tmp/$n.o" "$tmp/$n.py.elf" _start 2>"$tmp/$n.py.err"; rcp=$?
    "$mrb" "$here/flatlink.rb" "$tmp/$n.o" "$tmp/$n.rb.elf" _start 2>"$tmp/$n.rb.err"; rcr=$?
    if [ $rcp -ne $rcr ] || ! cmp -s "$tmp/$n.py.err" "$tmp/$n.rb.err"; then
      report fail "flatlink $n: status/stderr differ (py=$rcp rb=$rcr)"; head -2 "$tmp/$n.py.err" "$tmp/$n.rb.err"
    elif [ $rcp -ne 0 ]; then
      report ok "flatlink $n (same refusal: $(head -c 90 "$tmp/$n.py.err"))"
    elif cmp -s "$tmp/$n.py.elf" "$tmp/$n.rb.elf"; then
      report ok "flatlink $n (image identical, $(stat -c %s "$tmp/$n.py.elf") bytes)"; linked=$((linked + 1))
    else
      report fail "flatlink $n: images differ"
    fi
  done
  if [ $linked -eq 0 ]; then report fail "flatlink: no object was linked, the comparison is vacuous"; fi
  # Error paths: not an ELF, entry symbol missing.
  echo notelf >"$tmp/bad.o"
  python3 "$oracle/flatlink.py" "$tmp/bad.o" "$tmp/bad.elf" _start 2>"$tmp/bad.py.err"; rcp=$?
  "$mrb" "$here/flatlink.rb" "$tmp/bad.o" "$tmp/bad.elf" _start 2>"$tmp/bad.rb.err"; rcr=$?
  if [ $rcp -eq $rcr ] && [ $rcp -ne 0 ] && cmp -s "$tmp/bad.py.err" "$tmp/bad.rb.err"; then report ok "flatlink rejects a non-ELF the same way"
  else report fail "flatlink non-ELF handling differs (py=$rcp rb=$rcr)"; fi
  if [ ${#objs[@]} -gt 0 ]; then
    n=${objs[0]}
    python3 "$oracle/flatlink.py" "$tmp/$n.o" "$tmp/x.elf" no_such_symbol 2>"$tmp/ns.py.err"; rcp=$?
    "$mrb" "$here/flatlink.rb" "$tmp/$n.o" "$tmp/x.elf" no_such_symbol 2>"$tmp/ns.rb.err"; rcr=$?
    if [ $rcp -eq $rcr ] && cmp -s "$tmp/ns.py.err" "$tmp/ns.rb.err"; then report ok "flatlink missing entry symbol handled the same way"
    else report fail "flatlink missing-entry handling differs (py=$rcp rb=$rcr)"; fi
  fi
fi

# ---- 3. pathb-qbe-emit ----------------------------------------------------------------------------
# emit_cmp <label> <args...>: run the Python oracle and the mruby port with the same arguments (stdin from
# $emit_in, if set); stdout, stderr and the exit status must be identical. Sets emit_rc to the status.
emit_cmp() {
  local label=$1; shift
  local in=${emit_in:-/dev/null}
  python3 "$oracle/pathb-qbe-emit.py" "$@" <"$in" >"$tmp/em.py.out" 2>"$tmp/em.py.err"; local rcp=$?
  "$mrb" "$root/scripts/pathb-qbe-emit.rb" "$@" <"$in" >"$tmp/em.rb.out" 2>"$tmp/em.rb.err"; local rcr=$?
  emit_rc=$rcp
  if [ $rcp -ne $rcr ]; then report fail "pathb-qbe-emit $label: exit status py=$rcp rb=$rcr"; head -2 "$tmp/em.py.err" "$tmp/em.rb.err"; emit_rc=-1
  elif ! cmp -s "$tmp/em.py.out" "$tmp/em.rb.out"; then report fail "pathb-qbe-emit $label: output differs"; diff "$tmp/em.py.out" "$tmp/em.rb.out" | head -5; emit_rc=-1
  elif ! cmp -s "$tmp/em.py.err" "$tmp/em.rb.err"; then report fail "pathb-qbe-emit $label: stderr differs"; head -2 "$tmp/em.py.err" "$tmp/em.rb.err"; emit_rc=-1
  fi
}
emit_n=0; emit_ok=0; emit_refused=0; emit_err=0; emit_bytes=0
# emit_file <label> <file.ir>: with and without pruning
emit_file() {
  local label=$1 f=$2 flag
  for flag in "" --no-prune; do
    emit_n=$((emit_n + 1))
    emit_cmp "$label${flag:+ $flag}" ${flag:+"$flag"} "$f"
    case $emit_rc in
      0) emit_ok=$((emit_ok + 1)); emit_bytes=$((emit_bytes + $(wc -c <"$tmp/em.py.out"))) ;;
      3) emit_refused=$((emit_refused + 1)) ;;
      1) emit_err=$((emit_err + 1)) ;;
    esac
    [ $emit_rc -ge 0 ] || return
  done
}
before=$fail
for f in "$root"/tests/pathb-ir/*.ir "$root"/tests/mruby/pathb-edge/*.ir; do emit_file "${f#$root/tests/}" "$f"; done
# --long-double=trap: a function that mentions long double becomes an aborting stub (refused without the option).
for f in "$root"/tests/mruby/pathb-edge/ld_trap.ir "$root"/tests/mruby/pathb-edge/e_long_double*.ir; do
  [ -e "$f" ] || continue
  emit_n=$((emit_n + 1))
  emit_cmp "${f#$root/tests/} --long-double=trap" --long-double=trap "$f"
done
# The IR of the C++ programs, when the Path B harness is built.
cpfe=${PATHB_CPFE:-$root/build/pathb/cmake/bin/cpfe}
if [ -x "$cpfe" ]; then
  export PATHB_CPFE=$cpfe PATHB_BASE=${PATHB_BASE:-$root/build/pathb/edg-base}
  mkdir -p "$tmp/ir"
  gen=0
  for f in "$root"/tests/pathb-qbe/cases/*.cpp "$root"/tests/pathb-qbe/multi/*/*.cpp "$root"/tests/cases/*.cpp \
           "$root"/tests/pathb-qbe/traps/*.cpp; do
    case $(basename "$f") in qbe_*) continue ;; esac
    b=$(echo "${f#$root/tests/}" | tr / _)
    case $f in
      */traps/*) NFCXX_IR_OVERFLOW=trap "$root/scripts/pathb-dump" --ir "$f" >"$tmp/ir/$b.ir" 2>/dev/null || continue ;;
      *) "$root/scripts/pathb-dump" --ir "$f" >"$tmp/ir/$b.ir" 2>/dev/null || continue ;;
    esac
    gen=$((gen + 1))
    emit_file "${f#$root/tests/}" "$tmp/ir/$b.ir"
  done
  [ $gen -gt 0 ] || report fail "pathb-qbe-emit: the harness produced no IR"
else
  report skip "pathb-qbe-emit: no Path B harness at $cpfe (scripts/setup-pathb.sh), only the stored IR is checked"
fi
if [ $fail -eq $before ]; then
  report ok "pathb-qbe-emit: $emit_n runs identical ($emit_ok emitted, $((emit_bytes / 1024)) KB of QBE IL, $emit_refused refused, $emit_err errors)"
fi
# The comparison must not be vacuous: all three exit paths and a sizeable amount of IL were exercised.
if [ $emit_ok -lt 20 ] || [ $emit_refused -lt 20 ] || [ $emit_err -lt 20 ] || [ $emit_bytes -lt 100000 ]; then
  report fail "pathb-qbe-emit: too little was compared (ok=$emit_ok refused=$emit_refused errors=$emit_err bytes=$emit_bytes)"
fi
# Input from stdin ('-' and no argument) and the usage errors.
g=$root/tests/pathb-ir/templates_lambdas.ir
emit_in=$g emit_cmp "stdin" ; r1=$emit_rc
emit_in=$g emit_cmp "stdin -" -; r2=$emit_rc
emit_cmp "usage (two files)" "$g" "$g"; r3=$emit_rc
emit_cmp "usage (append-weak args)" --append-weak "$g"; r4=$emit_rc
emit_cmp "usage (no-prune twice)" --no-prune --no-prune "$g"; r5=$emit_rc
# A missing file is an uncaught exception in both (a Python traceback, an mruby backtrace): only the status is compared.
python3 "$oracle/pathb-qbe-emit.py" "$tmp/no-such-file.ir" >/dev/null 2>&1; r6=$?
"$mrb" "$root/scripts/pathb-qbe-emit.rb" "$tmp/no-such-file.ir" >/dev/null 2>&1; r7=$?
if [ "$r1 $r2 $r3 $r4 $r5" = "0 0 1 1 1" ] && [ "$r6" = 1 ] && [ "$r7" = 1 ]; then report ok "pathb-qbe-emit stdin, usage errors and a missing file behave the same"
else report fail "pathb-qbe-emit stdin/usage statuses unexpected: $r1 $r2 $r3 $r4 $r5 $r6 $r7"; fi
# --append-weak: the `# pathb-weak` marks of the IL become .weak lines at the end of the assembly.
weak_n=0; weak_lines=0
for f in "$root"/tests/pathb-ir/*.ir "$root"/tests/mruby/pathb-edge/*.ir; do
  python3 "$oracle/pathb-qbe-emit.py" "$f" >"$tmp/w.ssa" 2>/dev/null || continue
  grep -q '^# pathb-weak ' "$tmp/w.ssa" || continue
  printf '\t.text\nfoo:\n\tret\n' >"$tmp/w.py.s"; cp "$tmp/w.py.s" "$tmp/w.rb.s"
  python3 "$oracle/pathb-qbe-emit.py" --append-weak "$tmp/w.ssa" "$tmp/w.py.s"; rcp=$?
  "$mrb" "$root/scripts/pathb-qbe-emit.rb" --append-weak "$tmp/w.ssa" "$tmp/w.rb.s"; rcr=$?
  if [ $rcp -eq $rcr ] && cmp -s "$tmp/w.py.s" "$tmp/w.rb.s"; then
    weak_n=$((weak_n + 1)); weak_lines=$((weak_lines + $(grep -c '^\.weak ' "$tmp/w.py.s")))
  else report fail "pathb-qbe-emit --append-weak ${f#$root/tests/}: differs"; fi
done
if [ $weak_lines -gt 0 ]; then report ok "pathb-qbe-emit --append-weak ($weak_n modules, $weak_lines .weak lines identical)"
else report fail "pathb-qbe-emit --append-weak: no module had a weak definition"; fi
# The `# pathb-x87` marks (long double thunks, docs/notes/pathb-longdouble.md) become assembly: identical output, and, when QBE
# and an assembler are there, a file the assembler accepts.
x87_n=0; x87_marks=0
for f in "$root"/tests/pathb-ir/*.ir "$root"/tests/mruby/pathb-edge/*.ir; do
  python3 "$oracle/pathb-qbe-emit.py" "$f" >"$tmp/x.ssa" 2>/dev/null || continue
  grep -q '^# pathb-x87 ' "$tmp/x.ssa" || continue
  printf '\t.text\nfoo:\n\tret\n' >"$tmp/x.py.s"; cp "$tmp/x.py.s" "$tmp/x.rb.s"
  python3 "$oracle/pathb-qbe-emit.py" --append-weak "$tmp/x.ssa" "$tmp/x.py.s"; rcp=$?
  "$mrb" "$root/scripts/pathb-qbe-emit.rb" --append-weak "$tmp/x.ssa" "$tmp/x.rb.s"; rcr=$?
  if [ $rcp -eq $rcr ] && cmp -s "$tmp/x.py.s" "$tmp/x.rb.s"; then
    x87_n=$((x87_n + 1)); x87_marks=$((x87_marks + $(grep -c '^# pathb-x87 ' "$tmp/x.ssa")))
    if ! cc -c -o "$tmp/x.o" "$tmp/x.py.s" 2>"$tmp/x.as"; then report fail "pathb-qbe-emit x87 thunks of ${f#$root/tests/} do not assemble: $(head -1 "$tmp/x.as")"; fi
  else report fail "pathb-qbe-emit --append-weak (x87) ${f#$root/tests/}: differs"; fi
done
if [ $x87_marks -gt 0 ]; then report ok "pathb-qbe-emit x87 thunks ($x87_n modules, $x87_marks thunks identical and assembled)"
else report fail "pathb-qbe-emit x87 thunks: no module had a thunk"; fi
printf 'x\n' >"$tmp/w.none.s"; cp "$tmp/w.none.s" "$tmp/w.none2.s"
echo '# no marks' >"$tmp/w.none.ssa"
python3 "$oracle/pathb-qbe-emit.py" --append-weak "$tmp/w.none.ssa" "$tmp/w.none.s"
"$mrb" "$root/scripts/pathb-qbe-emit.rb" --append-weak "$tmp/w.none.ssa" "$tmp/w.none2.s"
if cmp -s "$tmp/w.none.s" "$tmp/w.none2.s" && [ "$(cat "$tmp/w.none2.s")" = x ]; then report ok "pathb-qbe-emit --append-weak without marks leaves the assembly alone"
else report fail "pathb-qbe-emit --append-weak without marks"; fi
# One deliberate difference: a string constant "(" or ")" in the IR. The Python original compares the token
# (a str subclass) with "(" and so reads the string as a parenthesis (an "unbalanced" error); the port does not.
printf '%s\n' '(ir-module "p.cpp" (layout (int 4)))' '(data "p" (array 2 (const char)) (string "("))' \
  '(function "main" (ret int) (params) (return (const int 0)))' >"$tmp/paren.ir"
"$mrb" "$root/scripts/pathb-qbe-emit.rb" "$tmp/paren.ir" >"$tmp/paren.out" 2>&1; rcr=$?
python3 "$oracle/pathb-qbe-emit.py" "$tmp/paren.ir" >/dev/null 2>&1; rcp=$?
if [ $rcr -eq 0 ] && grep -q '^data \$p = { b 40, b 0 }' "$tmp/paren.out" && [ $rcp -eq 1 ]; then
  report ok "pathb-qbe-emit reads a \"(\" string constant (the Python original misreads it as a parenthesis: known bug)"
else report fail "pathb-qbe-emit parenthesis string constant: rb=$rcr py=$rcp"; fi
"$root/tests/mruby/qbe-prep.sh" || fail=1

echo "tests/mruby: $pass passed, $skip skipped"
[ $fail -eq 0 ]
