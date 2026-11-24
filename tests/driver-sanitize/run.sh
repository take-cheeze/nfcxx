#!/bin/bash
# scripts/nfcxx-sanitize.rb must answer what nfcxx's bash validation did (the block copied verbatim from tests/driver-body/nfcxx-oracle.sh)
# for each -fsanitize= value and host kind: the same status and the same message.   bash tests/driver-sanitize/run.sh
here=$(cd "$(dirname "$0")" && pwd -P); repo=$(cd "$here/../.." && pwd -P)
root=$repo; pass=0; fail=0
bash_check() {   # bash_check SANITIZE FREESTANDING: the bash block, verbatim
  local sanitize=$1 freestanding=$2
  (
    if [ -n "$sanitize" ]; then
      IFS=, read -ra sz <<< "$sanitize"
      for c in ${sz[@]+"${sz[@]}"}; do
        case $c in
          undefined|signed-integer-overflow|integer-divide-by-zero|shift|bounds|null|unreachable|return|float-cast-overflow) ;;
          *) echo "nfcxx: -fsanitize=$c is not supported (implemented: undefined, signed-integer-overflow, integer-divide-by-zero, shift, bounds, null, unreachable, return, float-cast-overflow)" >&2; exit 2 ;;
        esac
      done
      [ $freestanding = 0 ] || { echo "nfcxx: -fsanitize needs Path B, which compiles hosted programs only" >&2; exit 2; }
    fi
  )
}
for s in "" undefined bounds "undefined,bounds" "signed-integer-overflow,shift,null,unreachable,return,float-cast-overflow,integer-divide-by-zero" \
         address "undefined,address" "bounds," ",bounds" "bounds,,null" "thread" "null," "undefined,foo" "shift"; do
  for fs in 0 1; do
    want=$(bash_check "$s" "$fs" 2>&1); wrc=$?
    got=$("${RUBY:-ruby}" "$root/scripts/nfcxx-sanitize.rb" check "$s" "$fs" 2>&1); grc=$?
    if [ "$wrc" = "$grc" ] && [ "$want" = "$got" ]; then pass=$((pass + 1)); else
      fail=$((fail + 1)); echo "FAIL [$s] freestanding=$fs: bash $wrc [$want] ruby $grc [$got]"; fi
  done
done
echo "driver-sanitize: $pass passed, $fail failed"
[ $fail = 0 ]
