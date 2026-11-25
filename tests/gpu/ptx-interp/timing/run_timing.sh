#!/usr/bin/env bash
# Checks of the timing model in ptxi (the header of ptxi.c describes it): --timing, --sms, --issue, --bw, --lat and
# --l1. CPU only. The estimates below are derived by hand from the model: a warp (32 threads) issues each instruction as
# often as its busiest lane steps through it, a barrier leaves every waiting warp at the latest arrival, a block takes
# the largest of its warp times, issue slots and bytes, and the blocks of an SM run one after another.
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

# 3. The barrier makes the warp wait for the latest arrival. The two threads are one warp. Thread 1's predicated load
#    (pc 6, 400 cycles) is issued by the warp, so the epoch before the barrier costs 24 (six alu) + 400 + 20 (bar.sync)
#    = 444, and thread 0 leaves the barrier at 444. Then the warp issues the shared load (pc 8) and thread 0's predicated
#    load (pc 9): 444 + 400 + 400 + 4 (ret) = 1248. This is the value the per-thread model gave too.
#    Without the barrier the warp issues three global loads, one per predicated side and the shared one: 24 + 3 x 400
#    + 4 (ret) = 1228. The per-thread model gave 832 (each thread's own two loads), because it did not pay the other
#    side of the predicated load in the same warp. Divergence is serialized, so the warp pays for all three.
bw=barwait.ptx
with=$(cycles "$bw" barwait --grid 1 --block 2 ptr:2)
sed '/bar.sync 0;/d' "$bw" > "$out/barwait_nobarrier.ptx"
without=$(cycles "$out/barwait_nobarrier.ptx" barwait --grid 1 --block 2 ptr:2)
expect_eq "barrier: the warp waits for the slow arrival" "$with" 1248
expect_eq "no barrier: the warp pays for both sides of the predicated loads" "$without" 1228

# 3b. Divergent if/else in one warp. Thread 0 runs the then side (two global loads, pc 6 and 7), thread 1 the else side
#     (one global load, pc 8). The per-lane-max model gave 832: thread 0's own path, 24 (six alu) + 400 + 400 + 4 (its
#     off else-load) + 4 (ret). The warp issues every instruction of both sides once: 24 + 400 (pc 6) + 400 (pc 7)
#     + 400 (pc 8) + 4 (ret) = 1228. The difference is 396: the else side's 400-cycle load, less the 4-cycle off slot
#     the per-lane model charged thread 0 for it.
div=divergent.ptx
div_est=$(cycles "$div" divergent --grid 1 --block 2 ptr:2)
expect_eq "divergent if/else: the warp pays for both sides" "$div_est" 1228

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

# 5. Issue width. 1024 threads are 32 warps, and each runs the same 18 instructions (mov, 16 adds, ret). The issue slots (32 x 18) are the
#    bound at --issue 4 and at --issue 8, and the critical path is shorter than both, so halving the rate doubles the
#    estimate exactly.
i4=$(cycles alu_chain.ptx alu_chain --grid 1 --block 1024 --issue 4)
i8=$(cycles alu_chain.ptx alu_chain --grid 1 --block 1024 --issue 8)
expect_eq "issue width: halving the rate doubles the estimate" "$i4" "$((2 * i8))"

# 6. Bandwidth. Each of the 1024 threads stores 4 bytes: 4096 bytes in one block. At 1 byte per cycle that is 4096
#    cycles, at 2 it is 2048, and the critical path (about 430 cycles) is shorter than both.
b1=$(cycles store_all.ptx store_all --grid 1 --block 1024 ptr:1024 --bw 1)
b2=$(cycles store_all.ptx store_all --grid 1 --block 1024 ptr:1024 --bw 2)
b16=$(cycles store_all.ptx store_all --grid 1 --block 1024 ptr:1024 --bw 16)
expect_eq "bandwidth: 4096 bytes at 1 byte per cycle" "$b1" 4096
expect_eq "bandwidth: 4096 bytes at 2 bytes per cycle" "$b2" 2048
[ "$b16" -lt "$b2" ] || { echo "bandwidth: the critical path should bound a fast memory system, got $b16" >&2; exit 1; }
echo "bandwidth: the critical path bounds a fast memory system ok ($b16)"

# 7. Bad --lat is refused (exit 2) and an unknown class is not silently ignored.
status=0; "$out/ptxi" "$ex" "${exargs[@]}" --lat dram=5 > /dev/null 2>&1 || status=$?
[ "$status" -eq 2 ] || { echo "--lat dram=5: expected exit 2, got $status" >&2; exit 1; }
echo "unknown latency class refused (exit 2)"

# 6. The L1. l1line.ptx: every thread loads a[tid.x] and stores it to b[tid.x]. Thirty-two threads read 128 bytes, one
#    cache line. A thread's clock is the same on every path except its load: six ALU instructions (24), the store
#    (global, 400) and ret (4), so 428 plus the load. A load that misses costs global (400), so a thread that misses
#    reaches 828; a load that hits costs l1 (30), so a thread that hits reaches 458.
#    One block of 32 threads: its slowest thread is the one that missed, so the estimate is 828 (the hits are hidden
#    behind it). Two blocks on one SM: the first load of the line anywhere in the schedule is the only miss, so one
#    block has a miss (828) and the other hits on all 32 loads (458), and the blocks run one after another: 1286.
#    Without the cache both blocks miss: 2 x 828 = 1656. With --lat l1=100 the all-hit block takes 24 + 100 + 400 + 4 =
#    528, so 828 + 528 = 1356.
lf=l1line.ptx
l1one=$(cycles "$lf" l1line --grid 1 --block 32 ptr:32 ptr:32 --l1 262144)
expect_eq "L1, one block of 32 threads: the missing thread is the critical path" "$l1one" 828
l1two=$(cycles "$lf" l1line --grid 2 --block 32 ptr:32 ptr:32 --l1 262144)
expect_eq "L1, two blocks on one SM: one miss, then a block of hits: 828 + 458" "$l1two" 1286
l1none=$(cycles "$lf" l1line --grid 2 --block 32 ptr:32 ptr:32)
expect_eq "no L1 (default): both blocks miss: 2 x 828" "$l1none" 1656
l1zero=$(cycles "$lf" l1line --grid 2 --block 32 ptr:32 ptr:32 --l1 0)
expect_eq "--l1 0 is the same as no option" "$l1zero" 1656
l1lat=$(cycles "$lf" l1line --grid 2 --block 32 ptr:32 ptr:32 --l1 262144 --lat l1=100)
expect_eq "--lat l1=100: the hit block is 24 + 100 + 400 + 4 = 528" "$l1lat" 1356

# Two blocks under 50 random schedules: each schedule has 64 loads of the line, one miss and 63 hits, so each gives 1286.
rnd_stderr=$("$out/ptxi" "$lf" l1line --grid 2 --block 32 ptr:32 ptr:32 --l1 262144 --random 50 --seed 3 --timing 2>&1 >/dev/null)
want="timing: 1286 cycles estimated (2 blocks on 1 SMs, 50 schedules)"
[ "$rnd_stderr" = "$want" ] || { echo "L1, random schedules: got '$rnd_stderr', want '$want'" >&2; exit 1; }
echo "L1, 50 random schedules: one estimate ok"

# Each SM has its own cache. Three one-thread blocks on two SMs: blocks 0 and 2 share SM 0, block 1 is alone on SM 1. On
# SM 0 the first load of the line misses (828) and the second hits (458), whichever block runs first: 1286. SM 1 is 828.
# The estimate is the larger, 1286, over all 90 schedules (the interleavings of three threads with two loads each). A
# cache shared by both SMs would give a range (916 to 1286), so this checks the per-SM keying.
sm_stderr=$("$out/ptxi" "$lf" l1line --grid 3 --block 1 ptr:32 ptr:32 --sms 2 --l1 262144 --explore --timing 2>&1 >/dev/null)
want="timing: 1286 cycles estimated (3 blocks on 2 SMs, 90 schedules)"
[ "$sm_stderr" = "$want" ] || { echo "L1, per-SM caches: got '$sm_stderr', want '$want'" >&2; exit 1; }
echo "L1, per-SM caches over every schedule: one estimate ok"

# Eviction. evict.ptx: one thread loads a[0], a[32] (the next line), then a[0] again, so 4 + 400 + 400 + 400 + 4 = 1208
# with no cache or with a one-line L1 (the second load evicts the first line). With two lines, a[0] and a[32] have
# different indices, so the third load hits: 4 + 400 + 400 + 30 + 4 = 838.
ev=evict.ptx
ev_none=$(cycles "$ev" evict ptr:64)
expect_eq "no L1: three loads at global latency" "$ev_none" 1208
ev_one=$(cycles "$ev" evict ptr:64 --l1 128)
expect_eq "one-line L1: the second load evicts the first, three misses" "$ev_one" 1208
ev_two=$(cycles "$ev" evict ptr:64 --l1 256)
expect_eq "two-line L1: the third load hits" "$ev_two" 838

# A size that is not a multiple of the 128-byte line is refused (exit 2).
status=0; "$out/ptxi" "$lf" l1line --grid 1 --block 32 ptr:32 ptr:32 --l1 100 > /dev/null 2>&1 || status=$?
[ "$status" -eq 2 ] || { echo "--l1 100: expected exit 2, got $status" >&2; exit 1; }
echo "--l1 100 refused (exit 2)"
echo "timing model: ok"
