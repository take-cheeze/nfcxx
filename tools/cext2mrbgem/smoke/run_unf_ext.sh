#!/bin/bash
# Runtime smoke test of the converted unf_ext (C++): links the converted unf.cc with the mruby core and gem archives and the mruby
# compiled mrblib, runs the gem's init, and evaluates Ruby that uses UNF::Normalizer (the probes print each result or exception).
# usage: run_unf_ext.sh CONVERTED_UNF_EXT_DIR CORE_ARCHIVE GEMS_ARCHIVE MRBLIB_OBJ
set -e
HERE=$(cd "$(dirname "$0")" && pwd)
MR=${MRUBY:-/home/user/mruby}
G=${1:?converted unf_ext dir}; CORE=${2:?core archive}; GEMS=${3:?gems archive}; MRBLIB=${4:?mrblib object}
W=$(mktemp -d); trap 'rm -rf "$W"' EXIT
gcc -c -w -I "$MR/include" -I "$MR/build/host-debug/include" "$HERE/unf_ext_main.c" -o "$W/main.o"
g++ -c -std=gnu++17 -w -fPIC -I "$G/include" -I "$MR/include" -I "$MR/build/host-debug/include" "$G/src/unf.cc" -o "$W/unf.o"
g++ -o "$W/run" "$W/main.o" "$W/unf.o" "$MRBLIB" -Wl,--start-group "$CORE" "$GEMS" -Wl,--end-group -lm
"$W/run"
