#!/bin/bash
# scripts/nfcxx-host-cflags.rb plan must add the same cflags and files as the bash host rules of nfcxx (copied verbatim below),
# for every backend, freestanding setting and host. uname is stubbed by the case.   bash tests/driver-host/run.sh
here=$(cd "$(dirname "$0")" && pwd -P); repo=$(cd "$here/../.." && pwd -P)
root=/case/root
pass=0; fail=0
# the bash rules, verbatim from tests/driver-body/nfcxx-oracle.sh (the uname function is the stub)
bash_rules() {
  [ $backend = pathb ] && [ $freestanding = 0 ] && [ "$(uname -s)" = Darwin ] && cflags+=(-include "$root/lib/pathb/clang_macros.h" -I "$root/lib/pathb/darwin-include")
  [ $backend = pathb ] && [ $freestanding = 0 ] && [ "$(uname -s)" = Darwin ] && [ "$(uname -m)" = arm64 ] && cflags+=(-D_LIBCPP_ABI_ALTERNATE_STRING_LAYOUT)
  [ $backend = pathb ] && [ $freestanding = 0 ] && [ "$(uname -s)" = Linux ] && { [ "$(uname -m)" = aarch64 ] || [ "$(uname -m)" = arm64 ]; } && cflags+=(-I "$root/lib/pathb/linux-aarch64-include")
  [ $freestanding = 0 ] && [ "$(uname -s)" = Linux ] && { [ "$(uname -m)" = aarch64 ] || [ "$(uname -m)" = arm64 ]; } && { cflags+=(-D__AARCH64EL__=1); files+=(-D__AARCH64EL__=1); }
}
for backend in gcc pathb; do for fs in 0 1; do for sys in Linux Darwin FreeBSD; do for mach in x86_64 aarch64 arm64; do
  uname() { if [ "$1" = -s ]; then echo "$SYS"; else echo "$MACH"; fi; }
  want=$( SYS=$sys MACH=$mach backend=$backend freestanding=$fs; cflags=(); files=(); bash_rules; printf '%s|' "${cflags[@]+"${cflags[@]}"}"; echo; printf '%s|' "${files[@]+"${files[@]}"}" )
  got=$( SYS=$sys MACH=$mach root=$root; cflags=(); files=(); eval "$(ruby "$repo/scripts/nfcxx-host-cflags.rb" plan backend=$backend freestanding=$fs sys=$sys mach=$mach root=$root)"; printf '%s|' "${cflags[@]+"${cflags[@]}"}"; echo; printf '%s|' "${files[@]+"${files[@]}"}" )
  if [ "$want" = "$got" ]; then pass=$((pass + 1)); else fail=$((fail + 1)); echo "FAIL backend=$backend freestanding=$fs sys=$sys mach=$mach"; echo "  bash: $want"; echo "  ruby: $got"; fi
done; done; done; done
echo "driver-host: $pass passed, $fail failed"
[ $fail = 0 ]
