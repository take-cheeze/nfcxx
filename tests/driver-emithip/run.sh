#!/bin/bash
# Differential test of the --emit-hip option filter: the bash case verbatim (from ./nfcxx) against
# scripts/nfcxx-emit-hip.rb plan. Each case is one cflags list; the planner's output is read back with
# while IFS= read -r -d '' as the driver reads it, and must match the bash list element by element.
#   bash tests/driver-emithip/run.sh
set -u
here=$(cd "$(dirname "$0")" && pwd -P)
repo=$(cd "$here/../.." && pwd -P)
ruby_bin=${RUBY:-$(command -v ruby)}
pass=0; fail=0

# run_case NAME [CFLAG...]: the bash filter and the planner over these cflags
run_case() {
  local name=$1; shift
  local cflags=("$@")
  local hip_opts=() f x rc=0 i
  # the bash filter, verbatim from ./nfcxx
  hip_opts=(); for f in ${cflags[@]+"${cflags[@]}"}; do case $f in -I*|-D*|-U*) hip_opts+=("$f");; esac; done
  local want=("${hip_opts[@]+"${hip_opts[@]}"}")
  # the planner, read back as the driver reads it (the status is the planner's)
  local got=()
  while IFS= read -r -d '' x; do got+=("$x"); done < <("$ruby_bin" "$repo/scripts/nfcxx-emit-hip.rb" plan ${cflags[@]+"${cflags[@]}"})
  wait $! || rc=$?
  local same=1
  if [ "${#want[@]}" != "${#got[@]}" ]; then same=0; else
    for i in "${!want[@]}"; do [ "${want[$i]}" = "${got[$i]}" ] || same=0; done
  fi
  if [ "$rc" = 0 ] && [ "$same" = 1 ]; then pass=$((pass + 1))
  else
    fail=$((fail + 1))
    printf 'FAIL %s: status %s\n  bash:'  "$name" "$rc"; printf ' [%q]' "${want[@]+"${want[@]}"}"; printf '\n  ruby:'; printf ' [%q]' "${got[@]+"${got[@]}"}"; printf '\n'
  fi
}

run_case "no cflags"
run_case "-I with a path" -I/usr/include
run_case "-D with a value" -DFOO=1
run_case "-U" -UBAR
run_case "bare -I" -I
run_case "bare -D" -D
run_case "bare -U" -U
run_case "dropped options" -O2 -std=c++17 -include x.h -isystem d
run_case "element with a space" "-I/with space" "-DX=a b" "x -I"
run_case "element with a newline" $'-I/a\nb' $'-DX=1\n-I' $'x\n-I'
run_case "empty element" "" -I/x "" -D
run_case "only an empty element" ""
run_case "mixed order" -O1 -DA -isystem s -I/i -include h.h -UB -std=c++20 -I -D
run_case "glob characters" "*" "-I*" "-I/tmp/*" "[D]"
run_case "case-sensitive prefixes" -i/x -d -u -Ix -Dx -Ux

# the planner's usage error
"$ruby_bin" "$repo/scripts/nfcxx-emit-hip.rb" --bogus </dev/null >/dev/null 2>&1; rc=$?
if [ "$rc" = 2 ]; then pass=$((pass + 1)); else fail=$((fail + 1)); echo "FAIL usage: status $rc, want 2"; fi

# a planner that fails ends the read with its status (the driver's wait $! || exit $?)
bash -c 'while IFS= read -r -d "" y; do :; done < <(false -I); wait $! || exit $?'; rc=$?
if [ "$rc" = 1 ]; then pass=$((pass + 1)); else fail=$((fail + 1)); echo "FAIL failing planner: status $rc, want 1"; fi

echo "driver-emithip: $pass passed, $fail failed"
[ "$fail" = 0 ]
