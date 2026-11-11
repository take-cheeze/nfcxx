#!/usr/bin/env bash
# CXX= wrapper for the mruby build (see corec_cc.sh): the C-as-C++ core objects (src/*-cxx.o: error, gc, vm_frames) of the
# compiled optcarrot build go to nfcxx (backend $COREC_CXX_BACKEND, default gcc); every other C++ file to g++.
args=("$@"); out=
for ((i = 0; i < ${#args[@]}; i++)); do [ "${args[i]}" = -o ] && out=${args[i + 1]}; done
here=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)
case "$out" in
  *optcarrotcompiled*sealed/src/*-cxx.o)
    echo "corec_cxx: nfcxx[${COREC_CXX_BACKEND:-gcc}] $(basename "$out")" >&2
    exec "$here/nfcxx" --backend="${COREC_CXX_BACKEND:-gcc}" "$@";;
esac
exec g++ "$@"
