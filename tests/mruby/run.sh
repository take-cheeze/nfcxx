#!/usr/bin/env bash
# mruby scripting check (docs/notes/mruby-scripting.md): every script ported from Python to mruby must
# give byte-identical output to the Python original on real inputs. The Python originals live on as the
# oracles in tests/mruby/oracle/ (they are no longer used by the build).
#   1. scripts/weak-symbols.{py,rb}: the assembly QBE produces for generated C of several tests/cases.
#   2. tests/hexagon/flatlink.{py,rb}: Hexagon objects (clang, if it has the hexagon target) built from
#      the generated C of several tests/cases and the HVX kernel; output image, stderr and exit status.
# Parts whose tools are missing (EDG, QBE, hexagon clang) are skipped with a message.
#   CLANG (default clang)   MRB (an existing mruby executable; default build/mruby-tool/bin/mruby)
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
    if ! python3 "$root/scripts/qbe-prep.py" "$tmp/$n.pp.c" "$tmp/$n.prep.c" "$tmp/$n.tail.s" 2>/dev/null ||
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
EOF
  printf 'alpha:\n\tret\nbeta:\n\tret\ngamma_decl:\nobj:\ndelta:\n\tret\n.Lx:\nnot_weak:\n  bad:\n' >"$tmp/edge.s"
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

echo "tests/mruby: $pass passed, $skip skipped"
[ $fail -eq 0 ]
