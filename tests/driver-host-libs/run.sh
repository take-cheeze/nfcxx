#!/bin/bash
# scripts/nfcxx-host-libs.rb plan must set posix_def, pb_cxx_libs and pb_atomic_lib as the bash in nfcxx does (copied verbatim
# below), for each host and freestanding setting. uname is stubbed.   bash tests/driver-host-libs/run.sh
here=$(cd "$(dirname "$0")" && pwd -P); repo=$(cd "$here/../.." && pwd -P)
pass=0; fail=0
uname() { if [ "$1" = -s ]; then echo "$SYS"; else echo "$MACH"; fi; }
bash_rules() {
  posix_def=(-D_POSIX_SOURCE); [ "$(uname -s)" = Darwin ] && posix_def=(-D_DARWIN_C_SOURCE -U__BLOCKS__)
  if [ "$(uname -s)" = Darwin ]; then pb_cxx_libs="-lc++"; pb_atomic_lib=""; else pb_cxx_libs="-lstdc++ -lgcc_s"; pb_atomic_lib="-latomic"; fi
  [ $freestanding = 0 ] || { [ "$sys" = Darwin ] || pb_cxx_libs=""; pb_atomic_lib=""; }   # macOS: libc++ (the tables' personality)
}
state() { printf 'posix=%s cxx=[%s] atomic=[%s]\n' "$(printf '%s|' ${posix_def[@]+"${posix_def[@]}"})" "$pb_cxx_libs" "$pb_atomic_lib"; }
for sys in Linux Darwin FreeBSD; do for fs in 0 1; do
  want=$( SYS=$sys MACH=x86_64 freestanding=$fs; bash_rules; state )
  got=$( SYS=$sys MACH=x86_64 freestanding=$fs; eval "$(ruby "$repo/scripts/nfcxx-host-libs.rb" plan sys=$sys freestanding=$fs)"; state )
  if [ "$want" = "$got" ]; then pass=$((pass + 1)); else fail=$((fail + 1)); echo "FAIL sys=$sys freestanding=$fs"; echo "  bash: $want"; echo "  ruby: $got"; fi
done; done
echo "driver-host-libs: $pass passed, $fail failed"
[ $fail = 0 ]
