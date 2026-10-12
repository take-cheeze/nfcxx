#!/usr/bin/env bash
# The float-to-integer checks of the runtime (be/nfcxx_ldrt.c), both variants. The default archive traps on an
# out-of-range value (user programs); the x86-64 variant (NFCXX_LDRT_X86=1, used by the stage-2 front end) gives the x86-64
# result. The expected values are the ones gcc gives on x86-64 (checked against gcc in the commit that added this).
cd "$(dirname "$0")/../.."
tmp=$(mktemp -d); trap 'rm -rf "$tmp"' EXIT
want='f128 0: int=2147483647 long=9223372036854775807 uint=4294967295 ulong=18446744073709551615
f128 1: int=-2147483648 long=-9223372036854775808 uint=0 ulong=0
f128 2: int=2147483647 long=9223372036854775807 uint=4294967295 ulong=18446744073709551615
f128 3: int=2147483647 long=3000000000 uint=3000000000 ulong=3000000000
f128 4: int=0 long=0 uint=0 ulong=0
ld 0: int=-2147483648 long=-9223372036854775808
ld 1: int=-2147483648 long=-9223372036854775808
ld 2: int=-2147483648 long=-9223372036854775808'
fail=0
x86=$(NFCXX_LDRT_X86=1 scripts/pathb-ldrt) && def=$(scripts/pathb-ldrt)
cc -O1 -o "$tmp/x86" tests/float-to-int/helpers.c "$x86" -lstdc++ -lquadmath -lm -latomic || { echo "FAIL build x86"; exit 1; }
got=$("$tmp/x86")
if [ "$got" = "$want" ]; then echo "ok   x86-64 variant"; else echo "FAIL x86-64 variant"; diff <(echo "$want") <(echo "$got"); fail=1; fi
# The default archive: the same program aborts on the first out-of-range value.
cc -O1 -o "$tmp/def" tests/float-to-int/helpers.c "$def" -lstdc++ -lquadmath -lm -latomic || { echo "FAIL build default"; exit 1; }
"$tmp/def" >/dev/null 2>&1; rc=$?
if [ $rc -eq 134 ]; then echo "ok   default archive traps (exit 134)"; else echo "FAIL default archive exit $rc, want 134"; fail=1; fi
# Folded constants (EDG's constant folder, through the gcc backend so the folded values are printed): gcc's values.
want_fold='127 255 65535 32767 0 255 65535 4294967295
0 18446744073709551615 0 4294967295 18446744073709551615 0 18446744073709551615 0'
NFCXX_BACKEND=gcc ./nfcxx tests/float-to-int/fold.cpp -o "$tmp/fold" >/dev/null 2>&1 || { echo "FAIL build fold.cpp"; exit 1; }
got_fold=$("$tmp/fold")
if [ "$got_fold" = "$want_fold" ]; then echo "ok   folded out-of-range conversions match gcc"; else echo "FAIL folded conversions"; diff <(echo "$want_fold") <(echo "$got_fold"); fail=1; fi
echo "$fail failures"
exit $fail
