#!/usr/bin/env bash
# scripts/driver-options.rb (parse_wp_option, the Ruby port of nfcc's wp_option) must give the same state and the same
# refusal as nfcc's bash wp_option for every -Wp option of tests/nfcc/wp-options.txt. The bash function is taken from nfcc
# itself (from its "wp_option() {" line to the closing brace), so the check follows the driver, not a copy.
cd "$(dirname "$0")/../.."
root=$PWD
tmp=$(mktemp -d); trap 'rm -rf "$tmp"' EXIT
pass=0; fail=0
ok() { echo "ok   $1"; pass=$((pass + 1)); }
bad() { echo "FAIL $1: $2"; fail=$((fail + 1)); }

# The bash side: die, the state globals, the function as nfcc has it, then the state printed in the Ruby port's format.
{
  echo 'die() { echo "nfcc: error: $*" >&2; exit 1; }'
  echo 'pp=(); depmode=""; dfile=""; dts=(); dp=0'
  awk '/^wp_option\(\) \{/ { on = 1 } on { print } on && /^\}/ { exit }' "$root/nfcc"
  echo 'wp_option "$1"'
  echo 'for x in "${pp[@]+"${pp[@]}"}"; do printf "pp %s\n" "$x"; done'
  echo '[ -z "$depmode" ] || printf "depmode %s\n" "$depmode"'
  echo '[ -z "$dfile" ] || printf "dfile %s\n" "$dfile"'
  echo 'for ((i = 0; i < ${#dts[@]}; i += 2)); do printf "dt %s %s\n" "${dts[i]}" "${dts[i+1]}"; done'
  echo '[ "$dp" != 1 ] || printf "dp 1\n"'
} > "$tmp/bash_wp.sh"
grep -q '^wp_option() {' "$tmp/bash_wp.sh" || { bad setup "cannot find wp_option in nfcc"; echo "0 passed, 1 failed"; exit 1; }

run_bash() { bash "$tmp/bash_wp.sh" "$1" 2>"$tmp/err_b" ; }
run_ruby() { ruby "$root/scripts/driver-options.rb" "$1" 2>"$tmp/err_r" ; }

cases=0
while IFS= read -r option; do
  case $option in ''|'#'*) continue ;; esac
  cases=$((cases + 1))
  bout=$(run_bash "$option"; echo "rc=$?")
  rout=$(run_ruby "$option"; echo "rc=$?")
  berr=$(cat "$tmp/err_b")
  rerr=$(cat "$tmp/err_r")
  if [ "$bout" = "$rout" ] && [ "$berr" = "$rerr" ]; then
    ok "$option"
  else
    bad "$option" "bash: $(printf '%s' "$bout" | tr '\n' '|') $berr / ruby: $(printf '%s' "$rout" | tr '\n' '|') $rerr"
  fi
done < tests/nfcc/wp-options.txt

echo "$pass passed, $fail failed ($cases cases)"
[ "$fail" = 0 ]
