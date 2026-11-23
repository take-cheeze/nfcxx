#!/usr/bin/env bash
# The device image cache key of scripts/nfcxx-cuda-device.rb (--key, the port of cu_device_key). Each case is a tree (the
# device unit, the emitter's sources, a ptxas stub, the toolkit's absence), the environment, the flags and the -D/-U words.
# Environment words are NAME=VALUE, with @W@ for the case's tree.
#
# The expected keys are pinned: they are the keys the bash cu_device_key of the frozen driver (tests/nfcxx-cuda-device/
# nfcxx-bash, origin/main c06e138fb) printed for each case, so the port is no longer checked against a copy of the bash
# function. The keys hash file contents and the flags only, so they do not change from one run to the next.
#
# cpfe-missing is not pinned. Its key hashes a "missing <path>" line for the absent PATHB_CPFE, and that path is inside
# this run's temporary tree, so the value differs on every run. The case checks its structure instead: the port exits 0,
# prints a 40-digit hex key, prints the same key on a second run of the same tree, and that key is not the default key (the
# missing file changes the key).
#   tests/nfcxx-cuda-device/key.sh     exit 1 on a mismatch
cd "$(dirname "$0")/../.." || exit 2
work=$(mktemp -d) || exit 2
trap 'rm -rf "$work"' EXIT
pass=0; fail=0

# pinned NAME: the key the frozen driver's cu_device_key prints for the case NAME
pinned() {
  case $1 in
    default) echo 3cdba39da0a57e99f68a8d94c5bb0effd511dfdf ;;
    defines) echo a4095b3824a80ff46b21ef27c0556b3de2e2f949 ;;
    quoted-defines) echo 13ebed1a72795d41acfcfd62c449ce14d60cf629 ;;
    non-ascii-define) echo bf9872d37752776df8472e8cac2ecbe57d3360d9 ;;
    empty-define) echo 75449e035869f9cfd8f3ede10ebcbfe903c230f3 ;;
    ir-opt-off) echo 19e87ef792c44bd3a69f59759b1a58c8d7dc3524 ;;
    ir-opt-inline) echo 2dd3efb132d1653eabd6152901bc78886b787ac8 ;;
    ir-opt-empty) echo d06e65b052efa7faead2d7dae3a40e9a48851a24 ;;
    promote-unroll-struct-0) echo b60b24dbdfeb8624c9068d3af33e56161dbac8ce ;;
    sm-80-budgets) echo 811530faa3b98e018d2d59e0d3d53ef6b8fe39cb ;;
    inline-device-0) echo dd7510628af79b51b6fcdb57e6129a4ae023cc39 ;;
    jit-ptx) echo ee6b0ef6bbeb54a71a12421d336d1a6687046317 ;;
    pathb-base-missing) echo 8dd49196b1ec269519f0690a7a530de550df9bc5 ;;
    jit-no-ptxas-path) echo ba17d9483cef63549b54772faf3fbe39a5d6a516 ;;
    *) return 1 ;;  # cpfe-missing: structural check, see above
  esac
}

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
  local name=$1 envs=$2 defs=$3 flags=$4 w=$work/case e d
  mk_tree "$w"
  envs=${envs//@W@/$w}
  local -a envw defw flagw
  read -r -a envw <<< "$envs"; IFS='|' read -r -a defw <<< "$defs"; read -r -a flagw <<< "$flags"
  local nenv=() ndef=()
  for e in ${envw[@]+"${envw[@]}"}; do nenv+=("--nfcxx-env=$e"); done
  for d in ${defw[@]+"${defw[@]}"}; do ndef+=("--cflag=$d"); done
  # the port's key for this case's tree
  port_key() {
    env -i PATH="$PATH" ruby scripts/nfcxx-cuda-device.rb --key --root="$w/root" --tmp="$w/tmp" \
      "--nfcxx-env=CUDA_HOME=$w/no-toolkit" ${nenv[@]+"${nenv[@]}"} ${ndef[@]+"${ndef[@]}"} ${flagw[@]+"${flagw[@]}"} \
      "$w/x.cu" 2>&1
  }
  local ro rs ro2 rs2 want
  ro=$(port_key); rs=$?
  if want=$(pinned "$name"); then
    if [ "$rs" = 0 ] && [ "$ro" = "$want" ]; then
      pass=$((pass + 1)); echo "ok   $name ($ro)"
    else
      fail=$((fail + 1)); echo "FAIL $name: pinned [$want], port [$ro] status $rs"
    fi
  else
    # structural check for a key that varies per run (see the header)
    ro2=$(port_key); rs2=$?
    if [ "$rs" = 0 ] && [ "$rs2" = 0 ] && [ "$ro" = "$ro2" ] && [[ $ro =~ ^[0-9a-f]{40}$ ]] && [ "$ro" != "$(pinned default)" ]; then
      pass=$((pass + 1)); echo "ok   $name (structure: 40 hex, stable within a run, not the default key)"
    else
      fail=$((fail + 1)); echo "FAIL $name: port [$ro] status $rs, second run [$ro2] status $rs2"
    fi
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
