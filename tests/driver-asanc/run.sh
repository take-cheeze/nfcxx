#!/bin/bash
# Differential test of nfcxx's ASan options block: the bash block verbatim (from the frozen driver, tests/driver-body/nfcxx-oracle.sh)
# against scripts/nfcxx-asan-c.rb plan, over asan 0 and 1 with the gcc and pathb backends, an unknown backend (the refusal's
# stderr and status 2), and asanopts with spaces and a quote. The arrays asan_c and asanopts, stderr and status must match.
#   bash tests/driver-asanc/run.sh
set -u
here=$(cd "$(dirname "$0")" && pwd -P)
repo=$(cd "$here/../.." && pwd -P)
work=$(mktemp -d); trap 'rm -rf "$work"' EXIT
pass=0; fail=0
# The body's ASan block now starts at its fallback: the elif after the driver's NFCXX_SETUP_ASAN state (the driver's Ruby
# planner, scripts/nfcxx-setup.rb asan, makes that state). The fallback runs when the driver gave no state; it is the elif
# through its fi (the else clears asanopts), made an if so the suite sources it as it sourced the old block.
sed -n '/^elif \[ \$asan = 1 \]; then$/,/^fi$/p' "$repo/tests/driver-body/nfcxx-oracle.sh" | sed '1s/^elif /if /' > "$work/bash.sh"
grep -q '^if \[ \$asan = 1 \]; then$' "$work/bash.sh" && grep -q '^else$' "$work/bash.sh" \
  || { echo "driver-asanc: no ASan fallback block in the frozen driver" >&2; exit 2; }

# run SIDE ASAN BACKEND [OPT...]: prints the arrays, the stderr and the status
run() {
  local side=$1 asan=$2 backend=$3; shift 3
  local -a opts=("$@")
  local out rc=0 err
  if [ "$side" = bash ]; then
    err=$(bash -c 'set -u; asan=$1; backend=$2; file=$3; shift 3; asanopts=("$@"); asan_c=(); source "$file"; printf "asan_c:"; printf " <%s>" "${asan_c[@]}"; echo; printf "asanopts:"; printf " <%s>" "${asanopts[@]}"; echo' _ "$asan" "$backend" "$work/bash.sh" "${opts[@]}" 2>&1 >"$work/out.$side") || rc=$?
  else
    err=$(bash -c 'set -u; asan=$1; backend=$2; script=$3; shift 3; asanopts=("$@"); asan_c=(); s_sh=$(ruby "$script" plan asan="$asan" backend="$backend" ${asanopts[@]+"${asanopts[@]/#/asanopts=}"}) || exit $?; eval "$s_sh"; printf "asan_c:"; printf " <%s>" "${asan_c[@]}"; echo; printf "asanopts:"; printf " <%s>" "${asanopts[@]}"; echo' _ "$asan" "$backend" "$repo/scripts/nfcxx-asan-c.rb" "${opts[@]}" 2>&1 >"$work/out.$side") || rc=$?
  fi
  printf 'rc %s\nstderr %s\n' "$rc" "$err"
  cat "$work/out.$side"
}

case_() {  # case_ NAME ASAN BACKEND [OPT...]
  local name=$1; shift
  local b t
  b=$(run bash "$@"); t=$(run ruby "$@")
  if [ "$b" = "$t" ]; then pass=$((pass + 1)); echo "ok   $name"
  else fail=$((fail + 1)); echo "FAIL $name"; diff <(printf '%s\n' "$b") <(printf '%s\n' "$t") | head -10 | sed 's/^/  /'; fi
}

case_ "asan off, gcc" 0 gcc
case_ "asan off, an unknown backend is not checked" 0 bogus -O1
case_ "asan on, gcc" 1 gcc
case_ "asan on, pathb with options" 1 pathb -O1 "-DX=1"
case_ "asan on, options with spaces and a quote" 1 gcc "a b" "it's"
case_ "asan on, unknown backend: refused with status 2" 1 bogus

echo "driver-asanc: $pass passed, $fail failed"
[ "$fail" = 0 ]
