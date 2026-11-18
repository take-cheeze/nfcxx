#!/bin/bash
# Runs a converted gem's Ruby-level probes (probes/GEM.txt: "expression<TAB>expected", see gem_probe_main.c) against the gem's
# converted sources, linked with the mruby core and gem archives and the compiled mrblib.
# usage: run_gem_probes.sh CONVERTED_GEM_DIR GEM GEM_INIT_SYMBOL
# env: MRUBY (checkout, default /home/user/mruby), MRUBY_CORE, MRUBY_GEMS (archives), MRUBY_MRBLIB (mrblib object)
set -e
HERE=$(cd "$(dirname "$0")" && pwd)
MR=${MRUBY:-/home/user/mruby}
G=${1:?converted gem dir}; N=${2:?gem name}; INIT=${3:?init symbol}
CORE=${MRUBY_CORE:?MRUBY_CORE: core archive}; GEMS=${MRUBY_GEMS:?MRUBY_GEMS: gems archive}; MRBLIB=${MRUBY_MRBLIB:?MRUBY_MRBLIB: mrblib object}
DEFS=$(python3 -I "$HERE/../corpus_defs.py" "$HERE/../corpus_flags.json" "$N")
W=$(mktemp -d); trap 'rm -rf "$W"' EXIT
INC="-I $G/include -I $MR/include -I $MR/build/host-debug/include"
objs=(); linker=gcc
for c in "$G"/src/*.c "$G"/src/*.cc; do
  [ -f "$c" ] || continue
  o="$W/$(basename "${c%.*}").o"
  case "$c" in
    *.cc) linker=g++; g++ -std=gnu++17 -c -w -fPIC $DEFS $INC "$c" -o "$o" ;;
    *)    gcc -std=gnu99 -c -w -fPIC $DEFS $INC "$c" -o "$o" ;;
  esac
  objs+=("$o")
done
gcc -c -w -DGEM_INIT="$INIT" -I "$MR/include" -I "$MR/build/host-debug/include" "$HERE/gem_probe_main.c" -o "$W/main.o"
$linker -o "$W/probe" "$W/main.o" "${objs[@]}" "$MRBLIB" -Wl,--start-group "$CORE" "$GEMS" -Wl,--end-group -lm
[ -n "$PROBE_BIN" ] && cp "$W/probe" "$PROBE_BIN"
"$W/probe" "$HERE/probes/$N.txt"
