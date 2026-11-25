#!/usr/bin/env bash
# Checks of the timing model in ptxi (the header of ptxi.c describes it): --timing, --sms and --lat. CPU only.
# The estimates below are derived by hand from the model: each thread's clock adds the latency of each instruction it
# issues, a barrier leaves every waiting thread at the latest arrival, a block takes its largest clock, and the blocks
# of an SM run one after another.
set -euo pipefail
cd "$(dirname "$0")"
out=$(mktemp -d)
trap 'rm -rf "$out"' EXIT
gcc -std=c11 -O2 -Wall -Wextra -Werror -pedantic -o "$out/ptxi" ../ptxi.c

# cycles FILE ARGS...: the estimate, read from the stderr line of --timing (ptxi must exit 0).
cycles() {
  local f=$1
  local line
  line=$("$out/ptxi" "$f" "${@:2}" --timing 2>&1 >/dev/null) || { echo "ptxi failed on: $*" >&2; exit 1; }
  printf '%s\n' "$line" | sed -n 's/^timing: \([0-9]*\) cycles.*/\1/p'
}
expect_eq() {
  local name=$1 got=$2 want=$3
  if [ "$got" != "$want" ]; then echo "$name: got $got, want $want" >&2; exit 1; fi
  echo "$name: ok ($got)"
}

ex=../sched/exchange.ptx
exargs=(exchange --grid 1 --block 2 ptr:2 ptr:2 --dump 1)

# 1. Latency is charged per instruction: each thread of the exchange kernel issues three global accesses (a store, a
#    load and a store), so the default 400-cycle global latency raised to 500 adds exactly 3 x 100.
base=$(cycles "$ex" "${exargs[@]}")
slow=$(cycles "$ex" "${exargs[@]}" --lat global=500)
expect_eq "exchange: 3 global accesses on the path" "$((slow - base))" 300

# 2. Blocks are independent: with one SM the 8 identical blocks run one after another, with 8 SMs they run side by side.
one=$(cycles "$ex" exchange --grid 8 --block 2 ptr:16 ptr:16 --sms 1)
eight=$(cycles "$ex" exchange --grid 8 --block 2 ptr:16 ptr:16 --sms 8)
expect_eq "8 blocks on 1 SM is 8 times one block" "$one" "$((8 * eight))"

# 3. The barrier makes a thread wait for the latest arrival. Thread 0 arrives at 48 cycles, thread 1 at 444 (its load
#    is 400 cycles). With the barrier thread 0 leaves at 444 and then does two loads: 444 + 800 + 4 (ret) = 1248. Without
#    it, each thread does its own two loads: 832 for both. The block estimate is the maximum over the threads.
bw=barwait.ptx
with=$(cycles "$bw" barwait --grid 1 --block 2 ptr:2)
sed '/bar.sync 0;/d' "$bw" > "$out/barwait_nobarrier.ptx"
without=$(cycles "$out/barwait_nobarrier.ptx" barwait --grid 1 --block 2 ptr:2)
expect_eq "barrier: the waiting thread pays for the slow arrival" "$with" 1248
expect_eq "no barrier: each thread pays only its own loads" "$without" 832

# 4. Schedules. A kernel whose path does not depend on the schedule gives one estimate over every schedule: the barrier
#    exchange, the barrier kernel, and the atomic megakernel of run_sched.sh. The megakernel without its atomic takes
#    different paths (its loop runs a different number of times), so the explorer reports the range of its estimates.
ex_stderr=$("$out/ptxi" "$ex" "${exargs[@]}" --explore --timing 2>&1 >/dev/null)
case "$ex_stderr" in *" to "*) echo "exchange: estimate varies: $ex_stderr" >&2; exit 1 ;; esac
echo "exchange, every schedule: one estimate ok"
bw_stderr=$("$out/ptxi" "$bw" barwait --grid 1 --block 2 ptr:2 --explore --timing 2>&1 >/dev/null)
case "$bw_stderr" in *" to "*) echo "barwait: estimate varies: $bw_stderr" >&2; exit 1 ;; esac
echo "barrier kernel, every schedule: one estimate ok"
mega=(megakernel --grid 2 --block 1 ptr:1 ptr:1 ptr:1 --dump 0 --dump 1 --dump 2)
mg_stderr=$("$out/ptxi" ../sched/megakernel.ptx "${mega[@]}" --explore --timing 2>&1 >/dev/null)
case "$mg_stderr" in *" to "*) echo "megakernel: estimate varies: $mg_stderr" >&2; exit 1 ;; esac
echo "megakernel with the atomic, every schedule: one estimate ok"
sed 's/atom\.global\.relaxed\.gpu\.add\.u32 %r0, \[%rd0\], 1;/ld.global.u32 %r0, [%rd0]; add.u32 %r2, %r0, 1; st.global.u32 [%rd0], %r2;/' \
  ../sched/megakernel.ptx > "$out/megakernel_nonatomic.ptx"
na_stderr=$("$out/ptxi" "$out/megakernel_nonatomic.ptx" "${mega[@]}" --explore --timing 2>&1 >/dev/null)
want="timing: 2472 to 2476 cycles over 20 schedules (2 blocks on 1 SMs)"
[ "$na_stderr" = "$want" ] || { echo "megakernel without the atomic: got '$na_stderr', want '$want'" >&2; exit 1; }
echo "megakernel without the atomic: the range over the schedules ok"

# 5. Bad --lat is refused (exit 2) and an unknown class is not silently ignored.
status=0; "$out/ptxi" "$ex" "${exargs[@]}" --lat dram=5 > /dev/null 2>&1 || status=$?
[ "$status" -eq 2 ] || { echo "--lat dram=5: expected exit 2, got $status" >&2; exit 1; }
echo "unknown latency class refused (exit 2)"
echo "timing model: ok"
