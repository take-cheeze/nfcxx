#!/usr/bin/env bash
# Scheduling and synchronization checks for ptxi (the header of ptxi.c describes the modes): the megakernel of
# arXiv:2611.04447 section 4.2 explored over every schedule, its non-atomic mutant, a barrier exchange with and
# without the barrier, a thread that exits before a barrier, a barrier deadlock, the schedule cap and the step limit.
# CPU only: no GPU and no CUDA are needed. Every outcome set is exact, so the checks compare whole sets.
set -euo pipefail
cd "$(dirname "$0")"
out=$(mktemp -d)
trap 'rm -rf "$out"' EXIT
gcc -std=c11 -O2 -Wall -Wextra -Werror -pedantic -o "$out/ptxi" ptxi.c

# outcome_set ARGS...: the sorted outcome values of an exhaustive search (ptxi must exit 0).
outcome_set() {
  local got
  got=$("$out/ptxi" "$@" --explore) || { echo "ptxi exited $? on: $*" >&2; exit 1; }
  printf '%s\n' "$got" | sed -n 's/^outcome [0-9]*: //p' | sort
}

# expect NAME WANT ARGS...: the outcome set must be exactly WANT (one outcome per line).
expect() {
  local name=$1 want=$2
  shift 2
  local got
  got=$(outcome_set "$@")
  if [ "$got" != "$(printf '%s\n' "$want" | sort)" ]; then
    echo "$name: outcomes differ from the expected set; got:" >&2
    printf '%s\n' "$got" >&2
    exit 1
  fi
  echo "$name: ok"
}

# caught NAME WANT ARGS...: the mutant's outcome set must differ from the correct one, WANT.
caught() {
  local name=$1 want=$2
  shift 2
  local got
  got=$(outcome_set "$@")
  if [ "$got" = "$(printf '%s\n' "$want" | sort)" ]; then
    echo "mutant $name was not caught" >&2
    exit 1
  fi
  echo "mutant $name caught: $(printf '%s' "$got" | tr '\n' ';')"
}

mega=(megakernel --grid 2 --block 1 ptr:1 ptr:1 ptr:1 --dump 0 --dump 1 --dump 2)

# The paper's claim: every schedule of the megakernel ends with (x, y, counter) = (1, 2, 2), so the counter is 2 and
# x, y hold the two items, in every interleaving.
expect "megakernel, every schedule" $'2 | 1 | 2' "$(pwd)/sched/megakernel.ptx" "${mega[@]}"

# The mutant reads and writes the counter without the atomic. Two threads can both read 0: both take item A, and the
# counter ends at 1 with y never written. The search must find that schedule.
sed 's/atom\.global\.relaxed\.gpu\.add\.u32 %r0, \[%rd0\], 1;/ld.global.u32 %r0, [%rd0]; add.u32 %r2, %r0, 1; st.global.u32 [%rd0], %r2;/' \
  sched/megakernel.ptx > "$out/megakernel_nonatomic.ptx"
caught "megakernel without the atomic" $'2 | 1 | 2' "$out/megakernel_nonatomic.ptx" "${mega[@]}"

# Random scheduling reaches only the correct outcome too (seeded, so the result is fixed).
got=$("$out/ptxi" "$(pwd)/sched/megakernel.ptx" "${mega[@]}" --random 200 --seed 7)
[ "$(printf '%s\n' "$got" | sed -n 's/^outcome [0-9]*: //p')" = "2 | 1 | 2" ] || { echo "megakernel random: unexpected outcomes: $got" >&2; exit 1; }
echo "megakernel, 200 random schedules: ok"

# With the barrier, the exchange reads the other thread's store in every schedule.
ex=(exchange --grid 1 --block 2 ptr:2 ptr:2 --dump 1)
expect "barrier exchange, every schedule" "2 1" "$(pwd)/sched/exchange.ptx" "${ex[@]}"

# Without the barrier the sequentially consistent schedules give three outcomes, and (0, 0) none. Checking the exact set
# also shows the search reaches every one of them.
sed '/bar.sync 0;/d' sched/exchange.ptx > "$out/exchange_nobarrier.ptx"
expect "exchange without the barrier (SC outcomes)" $'0 1\n2 0\n2 1' "$out/exchange_nobarrier.ptx" "${ex[@]}"
caught "exchange without the barrier" "2 1" "$out/exchange_nobarrier.ptx" "${ex[@]}"

# The default (sequential) mode runs the exchange as before: thread 0 to its barrier, then thread 1 through it.
default_out=$("$out/ptxi" "$(pwd)/sched/exchange.ptx" "${ex[@]}")
[ "$default_out" = $'2\n1' ] || { echo "exchange default mode: expected 2 and 1, got: $default_out" >&2; exit 1; }
echo "exchange, default mode: ok"

# An exited thread does not hold a barrier back: thread 1 passes it in every schedule.
expect "barrier after an exit" "7" "$(pwd)/sched/bar_exit.ptx" bar_exit --grid 1 --block 2 ptr:1 --dump 0

# Threads waiting at different barriers can never be released: a deadlock, exit 4.
status=0
"$out/ptxi" "$(pwd)/sched/bar_mismatch.ptx" bar_mismatch --grid 1 --block 2 > /dev/null 2> "$out/err" || status=$?
[ "$status" -eq 4 ] && grep -q deadlock "$out/err" || { echo "deadlock: expected exit 4 with a deadlock message, got $status: $(cat "$out/err")" >&2; exit 1; }
echo "barrier deadlock detected (exit 4)"

# The schedule cap: one schedule of the exchange is not the whole search, so the run must say so (exit 5).
status=0
"$out/ptxi" "$out/exchange_nobarrier.ptx" "${ex[@]}" --explore --max-schedules 1 > /dev/null 2>&1 || status=$?
[ "$status" -eq 5 ] || { echo "schedule cap: expected exit 5, got $status" >&2; exit 1; }
echo "incomplete exploration reported (exit 5)"

# The step limit stops a schedule that runs too long (exit 4).
status=0
"$out/ptxi" "$(pwd)/sched/megakernel.ptx" "${mega[@]}" --max-steps 5 > /dev/null 2>&1 || status=$?
[ "$status" -eq 4 ] || { echo "step limit: expected exit 4, got $status" >&2; exit 1; }
echo "step limit enforced (exit 4)"
