#!/usr/bin/env bash
# The state nfcc's option handling leaves behind, and the commands it would run, for one argument list: the oracle for the
# Ruby port (scripts/driver-loop.rb). The harness is nfcc's own code, with these changes, all made by sed on a copy:
#   - the existence checks for build/qbe, build/cil and scripts/pathb-cc are stubbed out (they only guard the compile);
#   - every host, toolchain and gcc command prints "RUN argv..." instead of running (the root and the temporary directory
#     show as ROOT and TMP), cp and cat print CP and CAT, a symlink prints "RUN LN -s ..", and pathb-ldrt's output is LDRT;
#   - exec (the query options, -E, -M, -fsyntax-only, the qbe-try wrapper) prints "EXEC argv..." and stops.
# The state is dumped between the post-loop checks and the compile-only path, so the compile is checked after the state.
# The backend and the other settings come from the environment, as nfcc reads them: NFCXX_BACKEND (default gcc),
# NFCXX_GCC_PASSTHROUGH, NFCXX_QBE_KERNEL, NFCXX_QBE_TRY and NFCXX_PATHB_FALLBACK; STUB_PATHB_STATUS is the status
# scripts/pathb-cc returns in this harness (default 0); STUB_WIDE_LITERAL=1 makes the host preprocessor show a wide literal;
# the host's -dumpfullversion is 13.3.0 and its --version first line is "cc (stub) 0". The host is cc; the shell's gcc --version decides -fno-crossjumping.
#   tests/nfcc/option-state.sh ARG...    prints the state and the commands, one per line
#   tests/nfcc/option-state.sh --self    checks the harness itself on a few argument lists
cd "$(dirname "$0")/../.."
root=$PWD
tmp=$(mktemp -d); trap 'rm -rf "$tmp"' EXIT

# The stub functions, defined before nfcc's code runs.
stub_funcs='_out() { local tag=$1 s x; shift; s=$tag; for x in "$@"; do x=${x//$root/ROOT}; x=${x//"${tmp-}"/TMP}; s+=" $x"; done; printf "%s\n" "$s"; }
run_stub() { local rc=0; case $1 in *scripts/pathb-cc) rc=${STUB_PATHB_STATUS:-0} ;; esac; if [ "$2" = -dumpfullversion ]; then echo 13.3.0; return 0; fi; if [ "$2" = --version ]; then echo "cc (stub) 0"; return 0; fi; if [ "$2" = -E ] && [ -n "${STUB_WIDE_LITERAL:-}" ]; then echo L\"x\"; return 0; fi; _out RUN "$@"; return $rc; }
cp() { _out CP "$@"; }
cat() { if [ $# -eq 0 ]; then return 0; fi; if [ "$1" = -- ]; then command cat "$@"; return; fi; _out CAT "$@"; }
exec_stub() { echo "EXEC $*"; exit 0; }'

# The dump of the state the port prints first, then the compile-only path (which follows it in nfcc).
dump_state='dump_scalar() { printf "%s=%s\n" "$1" "${!1-}"; }
dump_array() {
  local name=$1; local -n ref=$1
  [ "${#ref[@]}" -gt 0 ] || return 0
  local x; for x in "${ref[@]}"; do printf "%s+=%s\n" "$name" "$x"; done
}
for n in mode asm out sawout lang backend optlvl depmode dfile dp spon pathb_pic pathb_pie pb_m16 pb_regparm nofp nounwind wchar16; do dump_scalar "$n"; done
for n in inputs pp ld gccf isa asf picf dbg spguard dts kqf pbf needgcc; do dump_array "$n"; done'

harness() {
  local nfcc_sed=$tmp/nfcc.sed
  sed -e "s|^root=\$(cd \"\$(dirname \"\$0\")\" \&\& pwd)|root=$root|" \
      -e 's|die "QBE not built; run scripts/setup-qbe.sh"|:|' \
      -e 's|die "CIL backend not set up; run scripts/setup-cil.sh"|:|' \
      -e 's|die "Path B not available (scripts/pathb-cc)"|:|' \
      -e 's|"\$("\$root/scripts/pathb-ldrt")"|"LDRT"|' \
      -e 's|"\$host" |run_stub "$host" |g' \
      -e 's|exec run_stub "\$host" |exec_stub "$host" |g' \
      -e 's|exec "\$root/scripts/qbe-try" |exec_stub qbe-try |g' \
      -e 's|"\$qcc" |run_stub "$qcc" |g' \
      -e 's|^\( *\)"\$root/scripts/pathb-cc" |\1run_stub "$root/scripts/pathb-cc" |' \
      -e 's|PATHB_KEEP=\$keep "\$root/scripts/pathb-cc" |PATHB_KEEP=$keep run_stub "$root/scripts/pathb-cc" |' \
      -e 's|\bgcc \$what|run_stub gcc $what|g' \
      -e 's|^  gcc "\${objs|  run_stub gcc "${objs|' \
      -e 's|\bln -s |run_stub LN -s |g' \
      "$root/nfcc" > "$nfcc_sed"
  # the compile-only dispatch: the "if" line before the line that sets suffix (the post-loop checks have an "if" of their own)
  local at
  at=$(grep -n '^  suffix=\.o; ' "$nfcc_sed" | head -1 | cut -d: -f1)
  [ -n "$at" ] || { echo "oracle: cannot find the compile-only dispatch in nfcc" >&2; exit 1; }
  printf '%s\n' "$stub_funcs"
  head -n $((at - 2)) "$nfcc_sed"
  printf '%s\n' "$dump_state"
  tail -n +$((at - 1)) "$nfcc_sed"
}
harness > "$tmp/harness.sh"

state() { NFCXX_BACKEND=${NFCXX_BACKEND:-gcc} bash "$tmp/harness.sh" "$@" 2>&1; }

if [ "${1:-}" = --self ]; then
  pass=0; fail=0
  check() { if [ "$1" = "$2" ]; then pass=$((pass + 1)); else fail=$((fail + 1)); echo "FAIL: want [$2] got [$1]"; fi; }
  check "$(state -c x.c -o x.o | grep '^mode=')" "mode=compile"
  check "$(state -c x.c -o x.o | grep '^out=')" "out=x.o"
  check "$(state -c x.c -DA=1 -Iinc | grep '^pp+=')" "$(printf 'pp+=-DA=1\npp+=-Iinc')"
  check "$(state -c x.c -fPIC | grep '^picf+=')" "picf+=-fPIC"
  check "$(state -c x.c -MD -MF d.d -MT t | grep -E '^(depmode|dfile|dts)')" "$(printf 'depmode=-MD\ndfile=d.d\ndts+=-MT\ndts+=t')"
  check "$(state -c -dumpmachine | head -1)" "EXEC cc -c -dumpmachine"
  check "$(state -c x.c | tail -1)" "RUN gcc -c -O2 -fwrapv -fno-strict-aliasing -x c x.c -o x.o"
  echo "$pass passed, $fail failed"
  [ "$fail" = 0 ]
  exit $?
fi

state "$@"
