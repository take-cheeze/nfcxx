#!/usr/bin/env bash
# The state nfcc's option handling leaves behind, for one argument list: the oracle for the Ruby port of the option loop
# (scripts/driver-loop.rb). The harness is taken from nfcc itself: its lines up to the Path B section (the setup, the
# helpers, the pre-loop queries, the loop and the post-loop checks), with nfcc's own root, followed by a dump of the
# variables those leave behind. Nothing after that section runs, so no compiler and no built toolchain is needed:
#   - the existence checks for build/qbe, build/cil and scripts/pathb-cc are stubbed out (they only guard the compile);
#   - exec of the host compiler (the query options, -E, -M, -fsyntax-only) prints "EXEC" and the arguments, and stops.
# The backend comes from NFCXX_BACKEND (default gcc), NFCXX_GCC_PASSTHROUGH and NFCXX_QBE_KERNEL from the environment, as nfcc reads them.
#   tests/nfcc/option-state.sh ARG...    prints the state, one variable per line
#   tests/nfcc/option-state.sh --self    checks the harness itself on a few argument lists
cd "$(dirname "$0")/../.."
root=$PWD
tmp=$(mktemp -d); trap 'rm -rf "$tmp"' EXIT

harness() {
  # up to (not including) the Path B section, found by its text rather than by line number
  awk '/^pb_opts=\(\) pb_std=/ { exit } { print }' "$root/nfcc" |
    sed -e "s|^root=\$(cd \"\$(dirname \"\$0\")\" && pwd)|root=$root|" \
        -e 's|die "QBE not built; run scripts/setup-qbe.sh"|:|' \
        -e 's|die "CIL backend not set up; run scripts/setup-cil.sh"|:|' \
        -e 's|die "Path B not available (scripts/pathb-cc)"|:|' \
        -e 's|exec "\$host" |exec_stub "$host" |g' \
        -e 's|exec "\$root/scripts/qbe-try" |exec_stub qbe-try |g'
  cat <<'EOF'
dump_scalar() { printf '%s=%s\n' "$1" "${!1-}"; }
dump_array() {
  local name=$1; local -n ref=$1
  [ "${#ref[@]}" -gt 0 ] || return 0
  local x; for x in "${ref[@]}"; do printf '%s+=%s\n' "$name" "$x"; done
}
for n in mode asm out sawout lang backend optlvl depmode dfile dp spon pathb_pic pathb_pie pb_m16 pb_regparm nofp nounwind wchar16; do dump_scalar "$n"; done
for n in inputs pp ld gccf isa asf picf dbg spguard dts kqf pbf needgcc; do dump_array "$n"; done
EOF
}
exec_stub_def='exec_stub() { echo "EXEC $*"; exit 0; }'
{ echo "$exec_stub_def"; harness; } > "$tmp/harness.sh"

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
  echo "$pass passed, $fail failed"
  [ "$fail" = 0 ]
  exit $?
fi

state "$@"
