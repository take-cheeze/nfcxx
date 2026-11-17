#!/bin/bash
# scripts/nfcxx-instantiate.rb plan must give the same inst_opts, or the same refusal (message and status), as the bash in nfcxx
# (copied verbatim below), for each --instantiate value and host. uname is stubbed.   bash tests/driver-instantiate/run.sh
here=$(cd "$(dirname "$0")" && pwd -P); repo=$(cd "$here/../.." && pwd -P)
pass=0; fail=0
uname() { if [ "$1" = -s ]; then echo "$SYS"; else echo "$MACH"; fi; }
bash_rules() {
inst_opts=()
case $instantiate in
  auto) ;;
  used)
    inst_opts=(--no_auto_instantiation -tused)
    [ "$(uname -s)" = Darwin ] || inst_opts+=(--c_to_obj_option -ffunction-sections --c_to_obj_option -fdata-sections
                                              --c_to_obj_option -Wl,--gc-sections) ;;
  *) echo "nfcxx: --instantiate (NFCXX_INSTANTIATE) is auto or used (got $instantiate)" >&2; exit 2 ;;
esac
}
for ins in auto used bogus ""; do for sys in Linux Darwin; do
  want=$( SYS=$sys MACH=x86_64 instantiate=$ins; ( bash_rules; printf '%s\n' "${inst_opts[*]}" ) 2>&1; echo "status=$?" )
  got=$( SYS=$sys MACH=x86_64; out=$(ruby "$repo/scripts/nfcxx-instantiate.rb" plan instantiate="$ins" sys="$sys" 2>&1); rc=$?
         if [ $rc = 0 ]; then eval "$out"; printf '%s\n' "${inst_opts[*]}"; else echo "$out"; fi; echo "status=$rc" )
  if [ "$want" = "$got" ]; then pass=$((pass + 1)); else fail=$((fail + 1)); echo "FAIL instantiate=[$ins] sys=$sys"; echo "  bash: $want"; echo "  ruby: $got"; fi
done; done
echo "driver-instantiate: $pass passed, $fail failed"
[ $fail = 0 ]
