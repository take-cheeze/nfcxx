#!/usr/bin/env bash
# The assembly the qbe back end writes does not depend on how fast qbe-prep.rb and weak-symbols.rb are: `nfcc -S` with the
# scripts gives the same text as with their oracle ports (tests/mruby/oracle, the straightforward versions the scripts are
# checked against byte for byte). Inputs: tests/c/*.c, tests/cases/*.c when present, the cached Lua sources
# (build/realworld/lua), and any C files named in QBE_ASM_EXTRA (a space-separated list; ASTro's SD_*.c are the case this was
# written for; their -I/-D flags go in QBE_ASM_FLAGS). Skipped without QBE (scripts/setup-qbe.sh).
cd "$(dirname "$0")/../.."
root=$PWD
[ -x "$root/build/qbe/qbe" ] && { [ -x "$root/build/cproc/cproc-qbe" ] || [ -x "$root/build/cproc/stage2/cproc-qbe" ]; } ||
  { echo "SKIP qbe-asm: needs QBE and cproc (scripts/setup-qbe.sh)"; exit 0; }
tmp=$(mktemp -d); trap 'rm -rf "$tmp"' EXIT
export NFCXX_BACKEND=qbe
srcs=(tests/c/*.c)
[ ! -d tests/cases ] || srcs+=(tests/cases/*.c)
if [ -d build/realworld/lua ]; then
  for f in build/realworld/lua/*.c; do
    case $(basename "$f") in luac.c|ltests.c|onelua.c) ;; *) srcs+=("$f") ;; esac
  done
fi
# shellcheck disable=SC2206
srcs+=(${QBE_ASM_EXTRA:-})
# shellcheck disable=SC2206
flags=(${QBE_ASM_FLAGS:-})
pass=0; fail=0; skipped=0
for f in "${srcs[@]}"; do
  [ -f "$f" ] || continue
  n=$(basename "$f")
  if ! "$root/nfcc" -S "${flags[@]}" "$f" -o "$tmp/new.s" 2>"$tmp/new.err"; then
    # a source the back end cannot compile (a test of a refusal, a file that needs EDG) must fail the same way with the oracles
    NFCXX_QBE_PREP_RB=$root/tests/mruby/oracle/qbe-prep.rb NFCXX_WEAK_SYMBOLS_RB=$root/tests/mruby/oracle/weak-symbols.rb \
      "$root/nfcc" -S "${flags[@]}" "$f" -o "$tmp/old.s" 2>"$tmp/old.err" && { echo "FAIL qbe-asm $n: only the oracles compile it"; fail=$((fail + 1)); continue; }
    skipped=$((skipped + 1)); continue
  fi
  if ! NFCXX_QBE_PREP_RB=$root/tests/mruby/oracle/qbe-prep.rb NFCXX_WEAK_SYMBOLS_RB=$root/tests/mruby/oracle/weak-symbols.rb \
       "$root/nfcc" -S "${flags[@]}" "$f" -o "$tmp/old.s" 2>"$tmp/old.err"; then
    echo "FAIL qbe-asm $n: the oracles fail: $(head -2 "$tmp/old.err" | tr '\n' ' ')"; fail=$((fail + 1)); continue
  fi
  if cmp -s "$tmp/new.s" "$tmp/old.s"; then pass=$((pass + 1))
  else echo "FAIL qbe-asm $n: the assembly differs"; diff "$tmp/old.s" "$tmp/new.s" | head -5; fail=$((fail + 1)); fi
done
echo "tests/mruby qbe-asm: $pass identical, $fail differ, $skipped not compiled by either"
[ $fail -eq 0 ] && [ $pass -ge 10 ]
