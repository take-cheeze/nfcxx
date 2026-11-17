#!/bin/bash
# scripts/nfcxx-freestanding-setup.rb plan must leave the driver with the same extra, sys_inc, hosted_libs and gnu as the bash block
# of nfcxx (copied verbatim below, with stub trace spans), for each freestanding setting, gnu value and host.
#   bash tests/driver-freestanding/run.sh
here=$(cd "$(dirname "$0")" && pwd -P); repo=$(cd "$here/../.." && pwd -P)
pass=0; fail=0
block() {
if [ $freestanding = 1 ]; then
  extra=(--no_standard_includes "-I$root/lib")
  [ -n "$gnu" ] || gnu=130000
else
  t=$(trace_start)
  while IFS= read -r d; do [ -n "$d" ] && sys_inc+=("--sys_include=$d"); done < <("${RUBY:-ruby}" "$root/scripts/host-sys.rb" host_sys_includes)
  trace_end "$t" "host C++ headers" driver
  hosted_libs=(--c_to_obj_lib=m)
  [ "$(uname -s)" = Darwin ] && hosted_libs+=(--c_to_obj_lib=c++)
  if [ -z "$gnu" ]; then
    gnu=$("${RUBY:-ruby}" "$root/scripts/host-sys.rb" host_gnu_version)
  fi
fi
}
trace_start() { echo 0; }
trace_end() { :; }
uname() { if [ "$1" = -s ]; then echo "$SYS"; else echo "$MACH"; fi; }
state() { printf 'extra=%s\nsys=%s\nlibs=%s\ngnu=%s\n' "$(printf '%s|' ${extra[@]+"${extra[@]}"})" "$(printf '%s|' ${sys_inc[@]+"${sys_inc[@]}"})" "$(printf '%s|' ${hosted_libs[@]+"${hosted_libs[@]}"})" "$gnu"; }
for fs in 0 1; do for gnu0 in "" 130000; do for sys in Linux Darwin; do
  root=$repo
  want=$( SYS=$sys MACH=x86_64 freestanding=$fs gnu=$gnu0 root=$root; extra=(); sys_inc=(); hosted_libs=(); block; state )
  got=$( SYS=$sys MACH=x86_64 freestanding=$fs gnu=$gnu0 root=$root; extra=(); sys_inc=(); hosted_libs=(); eval "$(ruby "$repo/scripts/nfcxx-freestanding-setup.rb" plan freestanding=$fs gnu="$gnu0" sys=$sys root=$root)"; state )
  if [ "$want" = "$got" ]; then pass=$((pass + 1)); else fail=$((fail + 1)); echo "FAIL fs=$fs gnu=[$gnu0] sys=$sys"; echo "$want"; echo "--"; echo "$got"; fi
done; done; done
echo "driver-freestanding: $pass passed, $fail failed"
[ $fail = 0 ]
