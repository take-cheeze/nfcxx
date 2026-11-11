#!/usr/bin/env bash
# C compiler wrapper for the mruby build (CC=): the core C files in $COREC_FILES (default: hash kernel object class) of the
# compiled optcarrot build are compiled by nfcc (backend $COREC_BACKEND (default qbe; not NFCXX_BACKEND, which the probe reads to switch its gembox)), everything else by gcc.
#   COREC_FACTS=path/to/facts.h   compile hash.c against it (core_c_facts_inject.h); needs hash.c in COREC_FILES
#   COREC_FILES="hash.c kernel.c"   which src/*.c go to nfcc; ALL: every C file under the build's src/
args=("$@"); src=${args[-1]}; out=
for ((i = 0; i < ${#args[@]}; i++)); do [ "${args[i]}" = -o ] && out=${args[i + 1]}; done
[ -n "${COREC_LOG:-}" ] && echo "out=$out src=$src" >> "$COREC_LOG"
here=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)
case "$out" in
  *optcarrotcompiled*sealed/src/*)
    for f in ${COREC_FILES:-hash.c kernel.c object.c class.c}; do
      inject=()
      # COREC_FACTS=header: hash.c is compiled against the closed-world facts (bc2cpp/tools/bc2cpp/core_c_facts.rb)
      [ -n "${COREC_FACTS:-}" ] && [ "$(basename "$src")" = hash.c ] &&
        inject=(-DBC2CPP_CORE_C_FACTS_H="\"$COREC_FACTS\"" -include "$here/bc2cpp/tools/bc2cpp/runtime/core_c_facts_inject.h")
      if [ "$(basename "$src")" = "$f" ] || { [ "$f" = ALL ] && [[ $src == *.c ]]; }; then echo "corec_cc: nfcc[${COREC_BACKEND:-qbe}] $f" >&2; NFCXX_BACKEND=${COREC_BACKEND:-qbe} exec "$here/nfcc" "${inject[@]}" "$@"; fi
    done;;
esac
exec gcc "$@"
