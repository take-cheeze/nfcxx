#!/usr/bin/env bash
# The state nfcc's option loop leaves behind, for one argument list: the oracle for the Ruby port of the loop (option 3 of
# docs/notes/mruby-scripting.md's plan; see the branch's commits). The loop is taken from nfcc itself: the first 345 lines
# (the setup, the helpers, and the loop with its final checks), with nfcc's own root, followed by a dump of the variables the
# loop sets. Nothing after the loop runs, so no compiler is needed. The gcc backend is selected so that the QBE check
# (which needs build/qbe) is not reached.
#   tests/nfcc/option-state.sh ARG...    prints the state, one variable per line
#   tests/nfcc/option-state.sh --self    checks the harness itself on a few argument lists
cd "$(dirname "$0")/../.."
root=$PWD
tmp=$(mktemp -d); trap 'rm -rf "$tmp"' EXIT

harness() {
  # up to (not including) the post-loop checks, found by their text rather than by line number
  awk '/^for a in "\$\{spguard\[@\]/ { exit } { print }' "$root/nfcc" | sed "s|^root=\$(cd \"\$(dirname \"\$0\")\" && pwd)|root=$root|"
  cat <<'EOF'
dump_scalar() { printf '%s=%s\n' "$1" "${!1-}"; }
dump_array() {
  local name=$1; local -n ref=$1
  [ "${#ref[@]}" -gt 0 ] || return 0
  local x; for x in "${ref[@]}"; do printf '%s+=%s\n' "$name" "$x"; done
}
for n in mode asm out sawout lang backend optlvl depmode dfile dp spon pathb_pic pathb_pie; do dump_scalar "$n"; done
for n in inputs pp ld gccf isa asf picf dbg spguard dts; do dump_array "$n"; done
EOF
}
harness > "$tmp/harness.sh"

state() { NFCXX_BACKEND=gcc bash "$tmp/harness.sh" "$@" 2>&1; }

if [ "${1:-}" = --self ]; then
  pass=0; fail=0
  check() { if [ "$1" = "$2" ]; then pass=$((pass + 1)); else fail=$((fail + 1)); echo "FAIL: want [$2] got [$1]"; fi; }
  check "$(state -c x.c -o x.o | grep '^mode=')" "mode=compile"
  check "$(state -c x.c -o x.o | grep '^out=')" "out=x.o"
  check "$(state -c x.c -DA=1 -Iinc | grep '^pp+=')" "$(printf 'pp+=-DA=1\npp+=-Iinc')"
  check "$(state -c x.c -fPIC | grep '^picf+=')" "picf+=-fPIC"
  check "$(state -c x.c -MD -MF d.d -MT t | grep -E '^(depmode|dfile|dts)')" "$(printf 'depmode=-MD\ndfile=d.d\ndts+=-MT\ndts+=t')"
  echo "$pass passed, $fail failed"
  [ "$fail" = 0 ]
  exit $?
fi

state "$@"
