#!/usr/bin/env bash
# The live differential test of the CUDA compile planned in Ruby (scripts/nfcxx-cuda-live.rb, reached through scripts/nfcxx.rb)
# against nfcxx's bash driver before the port (tests/nfcxx-cuda-device/nfcxx-bash, the oracle). Each case runs in one scratch
# directory, at the same absolute path every time, so the cache keys and the paths the images record are the same. Three
# runs per case:
#   1. the bash driver (the oracle) on the arguments: its status, stdout, stderr, the object and the cache entry of the copy
#   2. the Ruby device stages alone (NFCXX_CUDA_LIVE_STOP=finish): the copy with its embedded images and the groups must be
#      the bash's files, byte for byte (the rewriter, the device IR, the emitter, ptxas and the embedding are the Ruby's)
#   3. the planned driver (scripts/nfcxx.rb) on the arguments: its status, stdout, stderr and object must be the bash's
# A case runs only with a CUDA toolkit: CUDA_HOME with bin/ptxas and include/cuda_runtime.h (else it is skipped, exit 0).
# The object of a -c compile is compared after the cache is cleared; the copy and the groups are compared where the cache is.
#   CUDA_HOME=/path/to/toolkit tests/nfcxx-cuda-live/run.sh     (exit 1 on a mismatch)
cd "$(dirname "$0")/../.." || exit 2
root=$PWD
here=$root/tests/nfcxx-cuda-live
if [ -z "${CUDA_HOME:-}" ] || [ ! -x "$CUDA_HOME/bin/ptxas" ] || [ ! -f "$CUDA_HOME/include/cuda_runtime.h" ]; then
  echo "skip: no CUDA toolkit (CUDA_HOME with bin/ptxas and include/cuda_runtime.h)"; exit 0
fi
work=$(mktemp -d) || exit 2
trap 'rm -rf "$work"' EXIT
w=$work/w                      # the scratch directory: the same absolute path for every run
mkdir -p "$w/home"
cp "$root/tests/nfcxx-cuda-device/fixtures/mul2.cu" "$here/fixtures/two.cu" "$w/" || exit 2
pass=0; fail=0; planned=0; fellback=0
# The bash oracle is the driver before the port (tests/nfcxx-cuda-device/nfcxx-bash): this tree's files, linked into a sandbox
# whose nfcxx is that driver (its root is the sandbox, its tools are this tree's build).
oracle=$work/oracle
mkdir -p "$oracle"
for f in "$root"/* "$root"/.[!.]*; do b=${f##*/}; [ "$b" = nfcxx ] || ln -s "$f" "$oracle/$b"; done
cp "$here/../nfcxx-cuda-device/nfcxx-bash" "$oracle/nfcxx" || exit 2

# the environment of a run: the variables a driver reads, cleared of the rest (the case's own NAME=VALUE words come first)
# The obfuscation seed is fixed (the bash draws a random one otherwise), and the cache of the copies is in the scratch
# directory: for a -c compile only. The other variables a driver reads (NFCXX_*) make the planned driver refuse some plans
# (the live facts of the freestanding and Path B ports), so the cases without them run without them.
cenv=()
run_env() {  # run_env [NAME=VALUE]...: the environment words of one run
  env -i PATH="$PATH" HOME="$w/home" CUDA_HOME="$CUDA_HOME" "${cenv[@]+"${cenv[@]}"}" "$@"
}
# the temporary directories of the bash's own messages have random names: both sides' are made the same. The oracle's root is
# its sandbox: its messages name this tree's files (lib/cuda/nfcxx_cuda.h), so the sandbox is the tree's root.
norm() { sed -e "s#$oracle#$root#g" -e 's#/tmp/nfcxx-tmp\.[A-Za-z0-9._-]*/tmp\.[A-Za-z0-9]*#TMP#g' -e 's#/tmp/tmp\.[A-Za-z0-9]*#TMP#g' -e 's#/tmp/nfcxx-cu[A-Za-z0-9_.-]*#TMP#g' "$1"; }   # the planned driver's root: /tmp/nfcxx-tmp.*/tmp.*, the same scratch as the bash's
# An object's internal namespace (_INTERNAL_8_NAME_cpp_HASH, EDG's) has a hash that differs from one compile to the next, so
# the objects are compared with the hash of each such name replaced (the same length, so the bytes are the rest).
normobj() {  # normobj FILE OUT
  python3 -c 'import re,sys; d=open(sys.argv[1],"rb").read(); open(sys.argv[2],"wb").write(re.sub(rb"_cpp_[0-9a-f]{8,}", b"_cpp_HASH", d))' "$1" "$2"
}

clear_outputs() { rm -rf "$w/cache" "$w/b.o" "$w/mul2.o" "$w/prog"; }

# case NAME ENVWORDS... -- ARGS...
case_run() {
  local name=$1; shift
  local envs=() args=() seen=0 x
  for x in "$@"; do
    if [ $seen = 0 ] && [ "$x" = -- ]; then seen=1; continue; fi
    if [ $seen = 0 ]; then envs+=("$x"); else args+=("$x"); fi
  done
  local bad=0
  cenv=()
  for x in "${args[@]}"; do case $x in -c|--obfuscate-kernels) cenv=(NFCXX_CU_CACHE="$w/cache" NFCXX_OBFUSCATE_SEED=00ff) ;; esac; done
  for x in "${envs[@]+"${envs[@]}"}"; do case $x in NFCXX_OBFUSCATE*|NFCXX_CUDA*) cenv=(NFCXX_CU_CACHE="$w/cache" NFCXX_OBFUSCATE_SEED=00ff) ;; esac; done

  # 1. the bash
  clear_outputs
  (cd "$w" && run_env "${envs[@]+"${envs[@]}"}" bash "$oracle/nfcxx" "${args[@]}") > "$work/bash.out" 2> "$work/bash.err"; local bst=$?
  rm -rf "$work/bash.cache" "$work/bash.obj"
  [ ! -d "$w/cache" ] || cp -R "$w/cache" "$work/bash.cache"
  for o in b.o mul2.o prog; do [ ! -f "$w/$o" ] || cp "$w/$o" "$work/bash.obj"; done

  # 2. the Ruby device stages alone, against the bash's cache entry
  clear_outputs
  (cd "$w" && run_env "${envs[@]+"${envs[@]}"}" NFCXX_CUDA_LIVE_STOP=finish ruby "$root/scripts/nfcxx-cuda-live.rb" -- "${args[@]}") \
    > "$work/stages.out" 2> "$work/stages.err"; local sst=$?
  if [ -d "$work/bash.cache" ] || [ -d "$w/cache" ]; then
    if [ -d "$work/bash.cache" ] && ! diff -r "$work/bash.cache" "$w/cache" > "$work/stages.diff" 2>&1; then
      bad=1; echo "FAIL $name: the Ruby device stages' cache entry differs from the bash's"; head -6 "$work/stages.diff" | sed 's/^/  /'
    fi
  fi
  if [ "$sst" != 0 ]; then
    if [ "$bst" = 0 ] && [ -d "$work/bash.cache" ]; then bad=1; echo "FAIL $name: the Ruby device stages failed (status $sst)"; head -5 "$work/stages.err" | sed 's/^/  /'; fi
  fi

  # 3. the planned driver
  clear_outputs
  (cd "$w" && run_env "${envs[@]+"${envs[@]}"}" NFCXX_DRIVER_TRACE=1 ruby "$root/scripts/nfcxx.rb" "${args[@]}") \
    > "$work/plan.out" 2> "$work/plan.err"; local pst=$?
  local how; how=$(grep -o 'driver: [a-z-]*' "$work/plan.err" | tail -1)
  case $how in *cuda-plan*|*freestanding-plan*|*pathb-plan*|*gcc-plan*) planned=$((planned + 1)) ;; *) fellback=$((fellback + 1)) ;; esac
  local stages; stages=$(grep -c 'nfcxx-cuda-live: stage' "$work/plan.err")
  # the stage lines are the planned driver's own trace: the planned run's stderr without them is the bash's
  grep -v '^nfcxx-cuda-live: \|^nfcxx: driver:' "$work/plan.err" > "$work/plan.err2"
  norm "$work/bash.err" > "$work/bash.err2"; norm "$work/plan.err2" > "$work/plan.err3"
  [ "$pst" = "$bst" ] || { bad=1; echo "FAIL $name: status planned $pst, bash $bst"; }
  cmp -s "$work/bash.out" "$work/plan.out" || { bad=1; echo "FAIL $name: stdout differs"; }
  cmp -s "$work/bash.err2" "$work/plan.err3" || { bad=1; echo "FAIL $name: stderr differs"; diff "$work/bash.err2" "$work/plan.err3" | head -6 | sed 's/^/  /'; }
  if [ -f "$work/bash.obj" ]; then
    local got=""; for o in b.o mul2.o prog; do [ ! -f "$w/$o" ] || got=$w/$o; done
    if [ -z "$got" ]; then bad=1; echo "FAIL $name: no object"; else
      normobj "$work/bash.obj" "$work/bash.norm"; normobj "$got" "$work/plan.norm"
      cmp -s "$work/bash.norm" "$work/plan.norm" || { bad=1; echo "FAIL $name: the object differs"; }
    fi
  fi
  # the copy and the groups (the cache entry of a -c compile: the rewritten copy with its images, the module files) are the
  # bash's, byte for byte, whichever driver made them
  if [ -d "$work/bash.cache" ] || [ -d "$w/cache" ]; then
    diff -r "$work/bash.cache" "$w/cache" > "$work/plan.cache.diff" 2>&1 || { bad=1; echo "FAIL $name: the copy or the groups differ from the bash's"; head -6 "$work/plan.cache.diff" | sed 's/^/  /'; }
  fi
  if [ $bad = 0 ]; then pass=$((pass + 1)); echo "ok   $name (bash status $bst, $how, $stages stage lines)"; else fail=$((fail + 1)); fi
}

I="-I$CUDA_HOME/include"
case_run c1-obfuscate-o -- -c $I --obfuscate-kernels mul2.cu -o b.o
case_run c2-default-name -- -c $I mul2.cu
case_run c3-defines-opt -- -c $I -DFOO=1 -O2 mul2.cu -o b.o
case_run c4-env-obfuscate NFCXX_OBFUSCATE_KERNELS=1 NFCXX_OBFUSCATE_SEED=00ff -- -c $I mul2.cu -o b.o
case_run c5-ir-opt-off -- -c $I --ir-opt=off mul2.cu -o b.o
case_run c6-promote-unroll-off -- -c $I --unroll=off --promote-slots=off --struct-slots=off mul2.cu -o b.o
case_run c7-jit-ptx NFCXX_CUDA_JIT=1 -- -c $I mul2.cu -o b.o
case_run c8-two-kernels -- -c $I two.cu -o b.o
case_run c9-no-edg-launch NFCXX_CUDA_EDG_LAUNCH=0 -- -c $I mul2.cu -o b.o
case_run c10-emit-hip -- --emit-hip mul2.cu
case_run c11-link-bash -- mul2.cu -o prog

echo "$pass passed, $fail failed; the planned driver answered $planned case(s) itself and handed $fellback to the bash"
[ "$fail" = 0 ]
