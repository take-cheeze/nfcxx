#!/usr/bin/env bash
# Stand-in for scripts/qbe-prep in tests/mruby/qbe-prep.sh: use it as NFCXX_QBE_PREP=<this file> (scripts/qbe-cc runs
# it). It copies the input scripts/qbe-cc hands it (and whether --c-input was given) into a fresh directory under
# QBE_PREP_TAP, then runs scripts/qbe-prep unchanged, so the test can replay exactly the inputs real compiles produce
# against the oracle.
root=$(cd "$(dirname "$0")/../.." && pwd)
args=("$@"); n=${#args[@]}
flag=; for a in "${args[@]:0:n-3}"; do [ "$a" = --c-input ] && flag=c; done
d=$(mktemp -d "${QBE_PREP_TAP:?}/in.XXXXXX") && cp "${args[n-3]}" "$d/src.c" && echo "$flag" >"$d/flag"
exec "$root/scripts/qbe-prep" "$@"
