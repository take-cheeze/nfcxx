#!/usr/bin/env bash
# Measures the cost of one enter/exit pair of the profiler runtime, with the TSC clock and with CLOCK_MONOTONIC, and
# with profiling off. Prints the numbers; it does not pass or fail on them (they depend on the machine).
set -eu
cd "$(dirname "$0")/../.."
out=build/prof
mkdir -p "$out"
cc=${CC:-gcc}
$cc -std=c11 -O2 -Wall -Wextra -Werror -pthread -Ilib/prof lib/prof/nfcxx_prof.c lib/prof/nfcxx_machine.c tests/prof/overhead.c -lm -o "$out/overhead"
n=${PAIRS:-2000000}
echo "off:       $(env -u NFCXX_PROFILE "$out/overhead" "$n")"
echo "tsc:       $(NFCXX_PROFILE=/dev/null "$out/overhead" "$n")"
echo "monotonic: $(NFCXX_PROFILE=/dev/null NFCXX_PROFILE_CLOCK=monotonic "$out/overhead" "$n")"
