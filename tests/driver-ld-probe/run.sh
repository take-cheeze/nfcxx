#!/bin/bash
# scripts/nfcxx-loop.rb --shell --probe-ld must give the statements the bash probe of nfcxx gives with --ld-available= (the probe
# copied verbatim below): the same -fuse-ld= programs found, for each argument list and PATH.   bash tests/driver-ld-probe/run.sh
here=$(cd "$(dirname "$0")" && pwd -P); repo=$(cd "$here/../.." && pwd -P)
pass=0; fail=0
bash_probe() {   # the driver's probe, verbatim: sets loop_ld from the arguments
  loop_ld=""
  for loop_a in "$@"; do
    case $loop_a in
      -fuse-ld=*) loop_n=${loop_a#-fuse-ld=}
                  if [ -n "$loop_n" ] && command -v "ld.$loop_n" >/dev/null 2>&1; then loop_ld+="$loop_n,"; fi ;;
    esac
  done
}
cases=(
  "-c m.cpp -fuse-ld=bfd"
  "-c m.cpp -fuse-ld=gold -fuse-ld=lld -fuse-ld=nosuch"
  "-c m.cpp -fuse-ld="
  "m.cpp -fuse-ld=bfd -fuse-ld=bfd -o p"
  "-c m.cpp -Wl,--as-needed"
  "-c m.cpp -fuse-ld=mold"
  "-c m.cpp -fuse-ld=ld.bfd"
  "m.cpp -fuse-ld=lld -fuse-ld=gold"
)
for cmd in "${cases[@]}"; do
  eval "args=($cmd)"
  bash_probe "${args[@]}"
  want=$(ruby "$repo/scripts/nfcxx-loop.rb" --shell --ld-available="$loop_ld" -- "${args[@]}" 2>&1; echo "rc=$?")
  got=$(ruby "$repo/scripts/nfcxx-loop.rb" --shell --probe-ld -- "${args[@]}" 2>&1; echo "rc=$?")
  if [ "$want" = "$got" ]; then pass=$((pass + 1)); else fail=$((fail + 1)); echo "FAIL [$cmd] (bash ld_available=$loop_ld)"; diff <(echo "$want") <(echo "$got") | head -4; fi
done
# a PATH with no ld programs: the probe finds none, as command -v does (ruby is called by its full path, so PATH can be empty)
PATH_EMPTY=$(mktemp -d); RUBYBIN=$(command -v ruby); BASHBIN=$(command -v bash)
eval "args=(-c m.cpp -fuse-ld=bfd)"
want=$(env PATH="$PATH_EMPTY" "$BASHBIN" -c "$(declare -f bash_probe); bash_probe ${args[*]}; '$RUBYBIN' '$repo/scripts/nfcxx-loop.rb' --shell --ld-available=\"\$loop_ld\" -- ${args[*]}" 2>&1; echo "rc=$?")
got=$(env PATH="$PATH_EMPTY" "$RUBYBIN" "$repo/scripts/nfcxx-loop.rb" --shell --probe-ld -- "${args[@]}" 2>&1; echo "rc=$?")
rm -rf "$PATH_EMPTY"
if [ "$want" = "$got" ]; then pass=$((pass + 1)); else fail=$((fail + 1)); echo "FAIL empty PATH"; echo "$want"; echo "$got"; fi
echo "driver-ld-probe: $pass passed, $fail failed"
[ $fail = 0 ]
