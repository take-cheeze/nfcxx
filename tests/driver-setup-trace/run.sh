#!/bin/bash
# The two bash pieces moved to scripts/nfcxx-setup.rb (B3): the -isystem include list (sys-include) and the host C++ headers
# span (host-headers). Checked against the original bash on main: the include list words for moves 0 and 1, and the span's
# record (its name, category, pid and unit; the times differ between runs).
#   bash tests/driver-setup-trace/run.sh
here=$(cd "$(dirname "$0")" && pwd -P); repo=$(cd "$here/../.." && pwd -P)
pass=0; fail=0
work=$(mktemp -d); trap 'rm -rf "$work"' EXIT
cd "$repo" || exit 1
git show origin/main:nfcxx > "$work/nfcxx-main" 2>/dev/null || git show HEAD:nfcxx > "$work/nfcxx-main"
sed -n '/^ecp_args() {/,/^}/p' "$work/nfcxx-main" > "$work/ecp_args.sh"
[ -s "$work/ecp_args.sh" ] || { echo "driver-setup-trace: ecp_args not found in main's ./nfcxx"; exit 1; }

# 1. the include list
dirs_cases=("/usr/include" "/usr/include /opt/x" "rel/dir" "/a b/c")
for moves in 0 1; do
  for dirs in "${dirs_cases[@]}"; do
    read -r -a arr <<< "$dirs"
    want=$(bash -c 'root='"$repo"'; RUBY=ruby; source '"$work"'/ecp_args.sh; moves='"$moves"'; sys_inc=(); ecp_args "$@"; for d in ${ecp_list[@]+"${ecp_list[@]}"}; do sys_inc+=("--sys_include=$d"); done; printf "%s\n" "${sys_inc[@]+"${sys_inc[@]}"}"' _ "${arr[@]}")
    got=$(ruby "$repo/scripts/nfcxx-setup.rb" sys-include "$moves" -- "${arr[@]}" | tr '\0' '\n')
    if [ "$want" = "$got" ]; then pass=$((pass + 1)); else fail=$((fail + 1)); echo "FAIL sys-include moves=$moves dirs=[$dirs]"; diff <(echo "$want") <(echo "$got") | head -4; fi
  done
done

# 2. the host C++ headers span: the record the bash trace_end writes, against the Ruby record
pend_b="$work/pend-b"; pend_r="$work/pend-r"; : > "$pend_b"; : > "$pend_r"
bash -c '
  set -euo pipefail
  root='"$repo"'; RUBY=ruby; export RUBY
  source "$root/scripts/trace.sh"
  export NFCXX_TRACE=1 NFCXX_TRACE_PENDING='"$pend_b"' NFCXX_TRACE_UNIT=u1 NFCXX_TRACE_OWNER=
  t=$(trace_start)
  eval "$(ruby "$root/scripts/nfcxx-freestanding-setup.rb" plan freestanding=0 gnu= sys=Linux root="$root")" >/dev/null
  trace_end "$t" "host C++ headers" driver
' >/dev/null 2>&1
bash -c 'root='"$repo"'; export NFCXX_TRACE=1 NFCXX_TRACE_PENDING='"$pend_r"' NFCXX_TRACE_UNIT=u1; ruby "$root/scripts/nfcxx-setup.rb" host-headers freestanding=0 gnu= sys=Linux root="$root" bash_pid=$$ >/dev/null' 2>/dev/null
fields() { tr '\0' '\n' < "$1" | awk 'NR%6==3||NR%6==4||NR%6==0||NR%6==5{printf "%s|", $0} NR%6==0{print ""}'; }
if [ -s "$pend_b" ] && [ -s "$pend_r" ] && [ "$(tr '\0' '\n' < "$pend_b" | sed -n 3p)" = "host C++ headers" ] && [ "$(tr '\0' '\n' < "$pend_r" | sed -n 3p)" = "host C++ headers" ] && [ "$(tr '\0' '\n' < "$pend_b" | sed -n 4p)" = "$(tr '\0' '\n' < "$pend_r" | sed -n 4p)" ] && [ "$(tr '\0' '\n' < "$pend_r" | sed -n 6p)" = "u1" ]; then
  pass=$((pass + 1))
else
  fail=$((fail + 1)); echo "FAIL host-headers span record"; echo "bash: $(fields "$pend_b")"; echo "ruby: $(fields "$pend_r")"
fi

echo "driver-setup-trace: $pass passed, $fail failed"
[ $fail = 0 ]
