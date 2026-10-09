#!/usr/bin/env bash
# Interpreter shim for tests/mruby/qbe-prep.sh: use it as MRB=<this file>. It runs the real interpreter
# (QBE_PREP_REAL_MRB) unchanged, but when the script is scripts/qbe-prep.rb it first copies the input
# scripts/qbe-cc handed it (and whether --c-input was given) into a fresh directory under QBE_PREP_TAP, so
# the test can replay exactly the inputs real compiles produce against the Python oracle.
case "${1:-}" in
  *qbe-prep.rb)
    args=("$@"); n=${#args[@]}
    flag=; for a in "${args[@]:1:n-4}"; do [ "$a" = --c-input ] && flag=c; done
    d=$(mktemp -d "$QBE_PREP_TAP/in.XXXXXX") && cp "${args[n-3]}" "$d/src.c" && echo "$flag" >"$d/flag"
    ;;
esac
exec "${QBE_PREP_REAL_MRB:?}" "$@"
