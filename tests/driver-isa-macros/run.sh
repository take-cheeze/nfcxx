#!/bin/bash
# Differential test of nfcxx's isa block (the -D options of the -m options): the bash pipeline, verbatim from the driver before the
# port, against scripts/nfcxx-isa-macros.rb, for several -m sets. The outputs must be the same, lines and order.
#   bash tests/driver-isa-macros/run.sh
set -u
here=$(cd "$(dirname "$0")" && pwd -P)
repo=$(cd "$here/../.." && pwd -P)
pass=0; fail=0

# the bash, as the driver ran it: ISA is the array of -m options
bash_macros() {
  local isa=("$@") out
  while IFS= read -r d; do printf '%s\n' "$d"; done < <(
    comm -13 <(gcc -dM -E -x c /dev/null | sort) <(gcc ${isa[@]+"${isa[@]}"} -dM -E -x c /dev/null | sort) \
      | sed -n 's/^#define \([^ (]*\) */-D\1=/p')
}

case_() {  # case_ NAME -m-OPTION...: the same lines from the bash and from the port
  local name=$1; shift
  local b t
  b=$(bash_macros "$@"); t=$(ruby "$repo/scripts/nfcxx-isa-macros.rb" "$@")
  if [ "$b" = "$t" ]; then pass=$((pass + 1)); echo "ok   $name ($(printf '%s\n' "$t" | grep -c .) macros)"
  else fail=$((fail + 1)); echo "FAIL $name"; diff <(printf '%s\n' "$b") <(printf '%s\n' "$t") | head -10 | sed 's/^/  /'; fi
}

case_ "no -m option" 
case_ "-mavx2" -mavx2
case_ "two options" -mavx2 -mfma
case_ "an option that narrows nothing new" -mno-sse4a
case_ "a target option gcc rejects: no macros" -mnot-a-real-option
case_ "a tuning option" -mtune=native
case_ "a 32-bit option" -m32

echo "driver-isa-macros: $pass passed, $fail failed"
[ "$fail" = 0 ]
