#!/usr/bin/env bash
# nfcc's wp_option, when build/driver-options exists (wp_option_sealed: the sealed scripts/driver-options.rb), must set the
# same variables and refuse the same options as its bash fallback, for every option of tests/nfcc/wp-options.txt. Both are
# taken from nfcc itself. The fallback runs with root pointing at a directory without build/driver-options; the sealed run
# uses this tree. Skipped (exit 0) when build/driver-options has not been made (tests/bc2cpp/run_driver_options.sh does that).
cd "$(dirname "$0")/../.."
root=$PWD
if [ ! -x "$root/build/driver-options" ]; then echo "SKIP nfcc sealed -Wp: no build/driver-options"; exit 0; fi
tmp=$(mktemp -d); trap 'rm -rf "$tmp"' EXIT
pass=0; fail=0
ok() { echo "ok   $1"; pass=$((pass + 1)); }
bad() { echo "FAIL $1: $2"; fail=$((fail + 1)); }

{
  echo 'die() { echo "nfcc: error: $*" >&2; exit 1; }'
  awk '/^wp_option_sealed\(\) \{/ { on = 1 } on { print } on && /^\}/ { exit }' "$root/nfcc"
  awk '/^wp_option\(\) \{/ { on = 1 } on { print } on && /^\}/ { exit }' "$root/nfcc"
  echo 'pp=(); depmode=""; dfile=""; dts=(); dp=0'
  echo 'wp_option "$1"'
  echo 'for x in "${pp[@]+"${pp[@]}"}"; do printf "pp %s\n" "$x"; done'
  echo '[ -z "$depmode" ] || printf "depmode %s\n" "$depmode"'
  echo '[ -z "$dfile" ] || printf "dfile %s\n" "$dfile"'
  echo 'for ((i = 0; i < ${#dts[@]}; i += 2)); do printf "dt %s %s\n" "${dts[i]}" "${dts[i+1]}"; done'
  echo '[ "$dp" != 1 ] || printf "dp 1\n"'
} > "$tmp/wp.sh"

# The same script with root set to the tree (sealed) or to a place with no build/driver-options (bash).
sed 's|^wp_option "\$1"|root=$1; wp_option "$2"|' "$tmp/wp.sh" > "$tmp/wp_root.sh"
run() { bash "$tmp/wp_root.sh" "$1" "$2" 2>&1; echo "rc=$?"; }

while IFS= read -r option; do
  case $option in ''|'#'*) continue ;; esac
  sealed=$(run "$root" "$option")
  fallback=$(run /nonexistent "$option")
  if [ "$sealed" = "$fallback" ]; then ok "$option"; else bad "$option" "sealed: $(printf '%s' "$sealed" | tr '\n' '|') / bash: $(printf '%s' "$fallback" | tr '\n' '|')"; fi
done < tests/nfcc/wp-options.txt
echo "$pass passed, $fail failed"
[ "$fail" = 0 ]
