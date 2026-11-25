#!/usr/bin/env bash
# bc2cpp world: scripts/nfcxx-early-exit.rb, the driver's early refusals and the emit-hip route (status 3), as a script world
# (tests/bc2cpp/leaf.sh). The script's top level is the whole program: it reads its state on stdin and exits. The cases are
# the arguments pre or post with a record file each (tests/driver-early-exit covers the driver itself).
# Needs Ruby with the Gemfile's gems (prism 1.9.0, rbs 4.0.0, installed by bundle); without them it prints a skip.
cd "$(dirname "$0")/../.." || exit 1
root=$PWD
command -v ruby >/dev/null || { echo "SKIP bc2cpp nfcxx-early-exit: ruby not installed"; exit 0; }
. tests/bc2cpp/leaf.sh
leaf_prepare; status=$?
[ "$status" = 2 ] && exit 0 # a fetch failure is a network fault, not a result (fetch.sh printed why)
[ "$status" = 0 ] || { echo "FAIL bc2cpp nfcxx-early-exit: preparing the world failed"; exit 1; }

work=build/bc2cpp/nfcxx-early-exit
mkdir -p "$work/edg"
printf '#!/bin/sh\nexit 0\n' > "$work/edg/eccp" && chmod +x "$work/edg/eccp"
# a state record file: each "NAME=VALUE" is one NUL-terminated record "sNAME=VALUE" (scripts/nfcxx-body.rb early_records)
state() { local f=$1; shift; : > "$f"; for kv in "$@"; do printf 's%s\0' "$kv" >> "$f"; done; }
ok=(ncpp=1 nobj=0 cfiles_n=0 cu_n=0 stdin_src=0 emit_hip=0 compile_only=1 emit_c=0 xlang= depmode= dialect=g++ "edg=$root/$work/edg")
state "$work/ok.rec" "${ok[@]}"
state "$work/none.rec" ncpp=0 nobj=0 cfiles_n=0 cu_n=0 stdin_src=0 emit_hip=0 compile_only=1 emit_c=0 xlang= depmode= dialect=g++ "edg=$root/$work/edg"
state "$work/hip.rec" ncpp=0 nobj=0 cfiles_n=0 cu_n=1 stdin_src=0 emit_hip=1 compile_only=1 emit_c=0 xlang= depmode= dialect=g++ "edg=$root/$work/edg"
state "$work/hip-two.rec" ncpp=0 nobj=0 cfiles_n=0 cu_n=2 stdin_src=0 emit_hip=1 compile_only=1 emit_c=0 xlang= depmode= dialect=g++ "edg=$root/$work/edg"
state "$work/stdin.rec" ncpp=0 nobj=0 cfiles_n=0 cu_n=0 stdin_src=1 emit_hip=0 compile_only=1 emit_c=0 xlang= depmode= dialect=g++ "edg=$root/$work/edg"
state "$work/xlang-c.rec" ncpp=1 nobj=0 cfiles_n=0 cu_n=0 stdin_src=0 emit_hip=0 compile_only=1 emit_c=0 xlang=c depmode= dialect=g++ "edg=$root/$work/edg"
state "$work/depmode.rec" ncpp=1 nobj=0 cfiles_n=0 cu_n=0 stdin_src=0 emit_hip=0 compile_only=0 emit_c=0 xlang= depmode=-MD dialect=g++ "edg=$root/$work/edg"
state "$work/edg-missing.rec" ncpp=1 nobj=0 cfiles_n=0 cu_n=0 stdin_src=0 emit_hip=0 compile_only=1 emit_c=0 xlang= depmode= dialect=g++ edg=/nonexistent
state "$work/dialect.rec" ncpp=1 nobj=0 cfiles_n=0 cu_n=0 stdin_src=0 emit_hip=0 compile_only=1 emit_c=0 xlang= depmode= dialect=bogus "edg=$root/$work/edg"

cases="$work/cases.txt"
{
  echo "<$root/$work/ok.rec pre"
  echo "<$root/$work/none.rec pre"
  echo "<$root/$work/hip.rec pre"
  echo "<$root/$work/hip-two.rec pre"
  echo "<$root/$work/stdin.rec post"
  echo "<$root/$work/xlang-c.rec post"
  echo "<$root/$work/depmode.rec post"
  echo "<$root/$work/edg-missing.rec post"
  echo "<$root/$work/dialect.rec post"
  echo "<$root/$work/ok.rec post"
  echo "<$root/$work/ok.rec bogus"
} > "$cases"

world="$work/world.rb"
leaf_world "$world" scripts/nfcxx-early-exit.rb
tail=$'exit 0\n'

if leaf_run nfcxx-early-exit "$world" "$tail" 0 "$cases"; then
  echo "PASS bc2cpp nfcxx-early-exit"
else
  echo "FAIL bc2cpp nfcxx-early-exit: the compiled and interpreted runs differ (build/bc2cpp/nfcxx-early-exit.log)"
  exit 1
fi
