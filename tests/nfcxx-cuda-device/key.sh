#!/usr/bin/env bash
# The device image cache key of scripts/nfcxx-cuda-device.rb (--key, the port of cu_device_key) against nfcxx's own
# cu_device_key, from the driver before the port (tests/nfcxx-cuda-device/nfcxx-bash). Each case is a tree (the device
# unit, the emitter's sources, a ptxas stub, the toolkit's absence), the environment, the flags and the -D/-U words; the bash
# function and the port must print the same key. Environment words are NAME=VALUE, with @W@ for the case's tree.
#   tests/nfcxx-cuda-device/key.sh     exit 1 on a mismatch
cd "$(dirname "$0")/../.." || exit 2
here=tests/nfcxx-cuda-device
work=$(mktemp -d) || exit 2
trap 'rm -rf "$work"' EXIT
pass=0; fail=0

# the bash's cache_sha and cu_device_key, from the fixture
oracle=$work/oracle.sh
{ awk 'index($0, "cache_sha() {") == 1' "$here/nfcxx-bash"
  awk 'index($0, "cu_device_key() {") == 1 { p = 1 } p { print } p && $0 == "}" { p = 0 }' "$here/nfcxx-bash"; } > "$oracle"
grep -q '^cu_device_key() {' "$oracle" || { echo "key.sh: cu_device_key was not extracted from the fixture" >&2; exit 2; }

mk_tree() {  # mk_tree W: the case's tree (the tools' stand-ins are text; the ptxas stub prints a version with two lines)
  local w=$1
  rm -rf "$w"
  mkdir -p "$w/root/scripts" "$w/root/build/pathb/edg-base" "$w/root/build/pathb/cmake/bin" "$w/tmp" "$w/bin" || exit 2
  echo "ir passes" > "$w/root/scripts/pathb-ir-opt.rb"
  echo "pathb dump" > "$w/root/scripts/pathb-dump.rb"
  echo "host sys" > "$w/root/scripts/host-sys.rb"
  echo "ptx emit" > "$w/root/build/pathb-ptx-emit"
  echo "cpfe" > "$w/root/build/pathb/cmake/bin/cpfe"
  printf 'one\n' > "$w/root/build/pathb/edg-base/one.h"
  printf 'two two' > "$w/root/build/pathb/edg-base/two.h"
  printf '__global__ void k(){}\n' > "$w/tmp/x.dev.cpp"
  printf 'k\n' > "$w/tmp/x.dev.kernels"
  printf '#!/bin/sh\necho "ptxas: NVIDIA (stub)"\necho "Cuda compilation tools, release 13.5, V13.5.1"\n' > "$w/bin/ptxas"
  chmod +x "$w/bin/ptxas"
  : > "$w/x.cu"
}

check() {  # check NAME "ENV..." "DEF|DEF..." "FLAG..."  (DEFs are separated by |, so a -D word may hold a space; FLAG: --ir-opt=V, ...)
  local name=$1 envs=$2 defs=$3 flags=$4 w=$work/case e d f
  mk_tree "$w"
  envs=${envs//@W@/$w}
  local -a envw defw flagw
  read -r -a envw <<< "$envs"; IFS='|' read -r -a defw <<< "$defs"; read -r -a flagw <<< "$flags"
  # the driver's variables (the bash's own state, as the driver sets it from its flags and the environment)
  local ir_set=0 ir_val=inline,sroa promote=1 unroll=1 struct=1 ext=cubin sm=75 ptxas="$w/bin/ptxas"
  for f in ${flagw[@]+"${flagw[@]}"}; do
    case $f in
      --ir-opt=*) ir_set=1; ir_val=${f#--ir-opt=} ;;
      --promote-slots=*) promote=${f#*=} ;;
      --unroll=*) unroll=${f#*=} ;;
      --struct-slots=*) struct=${f#*=} ;;
    esac
  done
  for e in ${envw[@]+"${envw[@]}"}; do
    case $e in NFCXX_CUDA_JIT=1) ext=ptx ;; NFCXX_SM=*) sm=${e#NFCXX_SM=} ;; NFCXX_PTXAS=*) ptxas=${e#NFCXX_PTXAS=} ;; esac
  done
  local bo bs ro rs
  bo=$(env -i PATH="$PATH" CUDA_HOME="$w/no-toolkit" ${envw[@]+"${envw[@]}"} bash -c '
    set -u
    root=$1; promote_slots=$2; unroll=$3; struct_slots=$4; ir_opt_set=$5; ir_opt=$6; oracle=$7
    shift 7
    . "$oracle"
    cu_device_key "$@"' _ "$w/root" "$promote" "$unroll" "$struct" "$ir_set" "$ir_val" "$oracle" \
    "$w/tmp/x.dev" "$sm" "$ptxas" "$ext" ${defw[@]+"${defw[@]}"}); bs=$?
  local nenv=()
  for e in ${envw[@]+"${envw[@]}"}; do nenv+=("--nfcxx-env=$e"); done
  local ndef=() ; for d in ${defw[@]+"${defw[@]}"}; do ndef+=("--cflag=$d"); done
  ro=$(env -i PATH="$PATH" ruby scripts/nfcxx-cuda-device.rb --key --root="$w/root" --tmp="$w/tmp" \
       "--nfcxx-env=CUDA_HOME=$w/no-toolkit" ${nenv[@]+"${nenv[@]}"} ${ndef[@]+"${ndef[@]}"} ${flagw[@]+"${flagw[@]}"} \
       "$w/x.cu" 2>&1); rs=$?
  if [ "$bs" = 0 ] && [ "$rs" = 0 ] && [ "$bo" = "$ro" ] && [ ${#bo} = 40 ]; then
    pass=$((pass + 1)); echo "ok   $name ($bo)"
  else
    fail=$((fail + 1)); echo "FAIL $name: bash [$bo] status $bs, port [$ro] status $rs"
  fi
}

check default "NFCXX_PTXAS=@W@/bin/ptxas" "" ""
check defines "NFCXX_PTXAS=@W@/bin/ptxas" "-DA=1|-DNAME=a b|-U_X" ""
check quoted-defines "NFCXX_PTXAS=@W@/bin/ptxas" '-DQ="x"|-DD=$v|-DHASH=#x|-DTILDE=~x|-DBR={a}|-DBS=a\b|-DT=a	tab' ""
check non-ascii-define "NFCXX_PTXAS=@W@/bin/ptxas" "-DNAME=é" ""
check empty-define "NFCXX_PTXAS=@W@/bin/ptxas" "-DE=" ""
check ir-opt-off "NFCXX_PTXAS=@W@/bin/ptxas" "" "--ir-opt=off"
check ir-opt-inline "NFCXX_PTXAS=@W@/bin/ptxas" "" "--ir-opt=inline"
check ir-opt-empty "NFCXX_PTXAS=@W@/bin/ptxas" "" "--ir-opt="
check promote-unroll-struct-0 "NFCXX_PTXAS=@W@/bin/ptxas" "" "--promote-slots=0 --unroll=0 --struct-slots=0"
check sm-80-budgets "NFCXX_PTXAS=@W@/bin/ptxas NFCXX_SM=80 NFCXX_CUDA_MAX_CONST_BYTES=32768 NFCXX_CUDA_MAX_PTX_LINES=500" "" ""
check inline-device-0 "NFCXX_PTXAS=@W@/bin/ptxas NFCXX_INLINE_DEVICE=0" "" ""
check jit-ptx "NFCXX_PTXAS=@W@/bin/ptxas NFCXX_CUDA_JIT=1" "-DA=2" ""
check pathb-base-missing "NFCXX_PTXAS=@W@/bin/ptxas PATHB_BASE=@W@/no-such-dir" "" ""
check cpfe-missing "NFCXX_PTXAS=@W@/bin/ptxas PATHB_CPFE=@W@/no-such-cpfe" "" ""
check jit-no-ptxas-path "NFCXX_CUDA_JIT=1 PATHB_BASE=@W@/root/build/pathb/edg-base" "" ""

# bash_quote (printf %q, the key's opts): every printable ASCII byte, alone and in the positions where the quoting differs
# (after a letter, after = and :, at the start), and the empty word. The port's quoting must print what bash prints.
quoting() {
  local -a words=()
  local i w p
  for p in '%s' 'a%s' 'a=%s' 'a:%s' '%sb'; do
    for ((i = 32; i < 127; i++)); do
      printf -v w "$p" "$(printf "\\$(printf '%03o' "$i")")"
      words+=("$w")
    done
  done
  words+=("")
  local bo ro
  bo=$(for w in "${words[@]}"; do printf ' %q\n' "$w"; done)
  ro=$(ruby -e 'require "./scripts/nfcxx-cuda-device"; ARGV.each { |w| puts(" " + bash_quote(w)) }' -- "${words[@]}")
  if [ "$bo" = "$ro" ]; then pass=$((pass + 1)); echo "ok   bash_quote (${#words[@]} words)"
  else fail=$((fail + 1)); echo "FAIL bash_quote differs from printf %q"; diff <(printf '%s\n' "$bo") <(printf '%s\n' "$ro") | head -6; fi
}
quoting

echo "$pass passed, $fail failed"
[ "$fail" = 0 ]
