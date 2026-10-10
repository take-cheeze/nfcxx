#!/usr/bin/env bash
# Path B stage 2 regression: lower each tests/cases/*.cpp to the mid-level IR (scripts/pathb-dump --ir) and diff
# the text against the golden tests/pathb-ir/<name>.ir. `tests/pathb-ir/run.sh --update` rewrites the goldens after
# an intended change. The run also reports coverage: how many IL node kinds were lowered and how many were not
# (NFCXX_PATHB_STATS=1 counts them in the back end). Needs a harness built by scripts/setup-pathb.sh: set
# PATHB_CPFE (and PATHB_BASE) to a scratch build, or use build/pathb.
cd "$(dirname "$0")/../.."
update=0; [ "${1:-}" = --update ] && update=1
# No automatic build: a missing harness is an error, so a worktree never rebuilds the shared build/ directory.
cpfe=${PATHB_CPFE:-build/pathb/cmake/bin/cpfe}
[ -x "$cpfe" ] || { echo "run.sh: no harness at $cpfe; set PATHB_CPFE (see docs/notes/pathb-stage2.md)" >&2; exit 2; }
tmp=$(mktemp -d); trap 'rm -rf "$tmp"' EXIT
fail=0; gaps=0
# The probes of tests/pathb-qbe/cases that exercise the lowering itself (continue, bool loads, setjmp, unreachable
# code, EH thunks, volatile accesses, thread-local objects) have goldens here too, so a change in the IR text shows up as a diff.
probes="tests/pathb-qbe/cases/continue.cpp tests/pathb-qbe/cases/bool_load.cpp tests/pathb-qbe/cases/setjmp.cpp tests/pathb-qbe/cases/reachability.cpp tests/pathb-qbe/cases/eh_thunk.cpp tests/pathb-qbe/cases/volatile.cpp tests/pathb-qbe/cases/tls.cpp tests/pathb-qbe/cases/bitfield_vol.cpp"
# Dynamic initialization (global constructors, local statics, constructor/destructor attributes, new/delete).
probes="$probes tests/pathb-qbe/cases/dyn_global.cpp tests/pathb-qbe/cases/dyn_local_static.cpp tests/pathb-qbe/cases/dyn_ctor_attr.cpp tests/pathb-qbe/cases/dyn_ctor_members.cpp tests/pathb-qbe/cases/dyn_new_delete.cpp tests/pathb-qbe/cases/dyn_global_forms.cpp tests/pathb-qbe/cases/dyn_init_forms.cpp"
probes="$probes tests/pathb-qbe/cases/tls_dyn.cpp tests/pathb-qbe/cases/tls_dyn_forms.cpp"   # thread_local with dynamic initialization (_ZTW wrappers, _ZTH, __tls_init)
probes="$probes tests/pathb-qbe/cases/bitfield.cpp tests/pathb-qbe/cases/bitfield2.cpp tests/pathb-qbe/cases/vla.cpp tests/pathb-qbe/cases/stmtexpr.cpp tests/pathb-qbe/cases/base_null.cpp tests/pathb-qbe/cases/vararg_def.cpp tests/pathb-qbe/cases/abi_struct.cpp"   # bit-fields, VLAs, statement expressions
# Union aggregate constants, bit-fields in unions, class statement-expression results, VLA scope exit, asm barriers, weak declarations.
probes="$probes tests/pathb-qbe/cases/longdouble_ir.cpp tests/pathb-qbe/cases/agg_union.cpp tests/pathb-qbe/cases/bitfield_union.cpp tests/pathb-qbe/cases/stmtexpr_class.cpp tests/pathb-qbe/cases/vla_scope.cpp tests/pathb-qbe/cases/asm_barrier.cpp tests/pathb-qbe/cases/weak_decl.cpp"
for f in tests/cases/*.cpp $probes; do
  case $(basename "$f") in qbe_*) continue ;; esac   # production-path only (system headers, GNU forms): outside Path B
  n=$(basename "$f" .cpp)
  if ! NFCXX_PATHB_STATS=1 scripts/pathb-dump --ir "$f" > "$tmp/$n.ir" 2> "$tmp/$n.err"; then
    echo "FAIL (front end) $f"; grep -v '^ir-stat' "$tmp/$n.err" | head -5; fail=1; continue
  fi
  if ! head -1 "$tmp/$n.ir" | grep -q '^(ir-module '; then
    echo "FAIL harness $cpfe has no IR back end (no (ir-module) output); build it with scripts/setup-pathb.sh"; exit 2
  fi
  g=$(grep -c '(unsupported' "$tmp/$n.ir" || true); gaps=$((gaps + g))
  if [ $update = 1 ]; then cp "$tmp/$n.ir" "tests/pathb-ir/$n.ir"; echo "wrote tests/pathb-ir/$n.ir"; continue; fi
  if diff -u "tests/pathb-ir/$n.ir" "$tmp/$n.ir" > "$tmp/$n.diff"; then
    echo "ok   $f"
  else
    echo "DIFF $f"; head -40 "$tmp/$n.diff"; fail=1
  fi
done
# Gap probe: tests/pathb-ir/gaps.cpp uses constructs the lowering handled late (VLA, statement
# expressions, bit-fields) next to one it still does not handle (inline asm). Its golden shows the (unsupported ...) marker; the count must match.
gap_expected=1   # inline asm; VLAs, statement expressions and bit-fields are lowered
if ! NFCXX_PATHB_STATS=1 scripts/pathb-dump --ir tests/pathb-ir/gaps.cpp > "$tmp/gaps.ir" 2> "$tmp/gaps.err"; then
  echo "FAIL (front end) tests/pathb-ir/gaps.cpp"; fail=1
else
  g=$(grep -c '(unsupported' "$tmp/gaps.ir" || true)
  if [ $update = 1 ]; then cp "$tmp/gaps.ir" tests/pathb-ir/gaps.ir; echo "wrote tests/pathb-ir/gaps.ir"
  elif diff -u tests/pathb-ir/gaps.ir "$tmp/gaps.ir" > "$tmp/gaps.diff"; then
    if [ "$g" = "$gap_expected" ]; then echo "ok   tests/pathb-ir/gaps.cpp ($g unsupported markers)"
    else echo "FAIL tests/pathb-ir/gaps.cpp: $g unsupported markers, expected $gap_expected"; fail=1; fi
  else
    echo "DIFF tests/pathb-ir/gaps.cpp"; head -40 "$tmp/gaps.diff"; fail=1
  fi
fi
# Built-ins and va_arg lowered without a library call (va_arg of long double is a helper call), and the inline asm cases the emitter must refuse by name.
# Each has a golden; the emitter (scripts/pathb-qbe-emit.rb through scripts/mrb) must accept or refuse the IR as stated:
#   builtins, vaarg_agg, vaarg_ld: accepted (exit 0)    asm_refuse: refused (exit 3) with the text shown
mrb=scripts/mrb
for spec in "builtins:0:" "vaarg_agg:0:" "vaarg_ld:0:" "asm_refuse:3:asm-template \"mfence\""; do
  n=${spec%%:*}; rest=${spec#*:}; want_rc=${rest%%:*}; want_msg=${rest#*:}
  f=tests/pathb-ir/$n.cpp
  if ! scripts/pathb-dump --ir "$f" > "$tmp/$n.ir" 2> "$tmp/$n.err"; then echo "FAIL (front end) $f"; head -5 "$tmp/$n.err"; fail=1; continue; fi
  if [ $update = 1 ]; then cp "$tmp/$n.ir" "tests/pathb-ir/$n.ir"; echo "wrote tests/pathb-ir/$n.ir"; continue; fi
  if diff -u "tests/pathb-ir/$n.ir" "$tmp/$n.ir" > "$tmp/$n.diff"; then echo "ok   $f"; else echo "DIFF $f"; head -40 "$tmp/$n.diff"; fail=1; continue; fi
  "$mrb" scripts/pathb-qbe-emit.rb "$tmp/$n.ir" > /dev/null 2> "$tmp/$n.emit"; rc=$?
  if [ "$rc" != "$want_rc" ]; then echo "FAIL $f: emitter exit $rc, expected $want_rc: $(head -1 "$tmp/$n.emit")"; fail=1
  elif [ -n "$want_msg" ] && ! grep -qF -- "$want_msg" "$tmp/$n.emit"; then echo "FAIL $f: emitter message lacks '$want_msg': $(head -1 "$tmp/$n.emit")"; fail=1
  else echo "ok   $f (emitter exit $rc${want_msg:+, refused with '$want_msg'})"; fi
done
# asm_refuse: four statements stay unsupported markers (mfence template, cpuid and lock operands, a register clobber); pause, rep nop are lowered
if [ $update = 0 ]; then
  g=$(grep -c '(unsupported stmt' "tests/pathb-ir/asm_refuse.ir" || true)
  [ "$g" = 4 ] && echo "ok   tests/pathb-ir/asm_refuse.cpp ($g unsupported asm markers)" || { echo "FAIL tests/pathb-ir/asm_refuse.cpp: $g unsupported markers, expected 4"; fail=1; }
fi
# Coverage: sum the per-kind counts of tests/cases (the gap probe is reported above, not here). A kind with a nonzero unsupported count is a gap.
for f in tests/cases/*.cpp; do case $(basename "$f") in qbe_*) continue ;; esac; cat "$tmp/$(basename "$f" .cpp).err"; done 2>/dev/null | awk '
  $1 == "ir-stat" && $2 != "total" {
    key = $2 " " $3; ok[key] += $5; gap[key] += $7; if (!(key in seen)) { seen[key] = 1; order[++n] = key }
  }
  END {
    kinds = 0; lowered_kinds = 0; gap_kinds = 0; tot_ok = 0; tot_gap = 0;
    for (i = 1; i <= n; i++) {
      k = order[i]; kinds++; tot_ok += ok[k]; tot_gap += gap[k];
      if (gap[k] > 0) { gap_kinds++; printf "coverage gap: %-22s lowered %d unsupported %d\n", k, ok[k], gap[k] }
      else lowered_kinds++;
    }
    printf "coverage: %d node kinds seen, %d lowered with no gap, %d with unsupported nodes\n", kinds, lowered_kinds, gap_kinds;
    printf "coverage: %d node occurrences lowered, %d unsupported\n", tot_ok, tot_gap;
  }'
echo "unsupported IR nodes across tests/cases: $gaps"
exit $fail
