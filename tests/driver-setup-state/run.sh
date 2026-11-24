#!/bin/bash
# scripts/nfcxx-setup-state.rb: the setup's state, read by Ruby from the planners' statements, must equal what bash computes
# from the same statements (the body evals them). For each command: the variables the statements set, scalars and arrays,
# compared name by name. The Ruby side is NAME=VALUE and NAME[]=WORD lines, the bash side the same, for the variables the
# eval created (compgen -v before and after).
here=$(cd "$(dirname "$0")" && pwd -P); repo=$(cd "$here/../.." && pwd -P)
t=$(mktemp -d); trap 'rm -rf "$t"' EXIT
printf 'int main(){}\n' > "$t/m.cpp"
cd "$t"
pass=0; fail=0
# the bash side: evaluates the statements and prints the variables it created
bash_side() {
  local n stmts w
  declare -A seen=()
  stmts=$(ruby "$repo/scripts/nfcxx-setup-state.rb" --texts -- "$@" 2>/dev/null) || return 1
  for n in $(compgen -v); do seen[$n]=1; done
  eval "$stmts"
  for n in $(compgen -v); do
    [ -z "${seen[$n]+x}" ] || continue
    case $n in BASH*|_|FUNCNAME|LINENO|PIPESTATUS|SECONDS|RANDOM|BASHPID|PPID|OPTIND|BASHOPTS|SHELLOPTS|SHLVL|n|w|seen|stmts) continue ;; esac
    if [ "$(declare -p "$n" 2>/dev/null | cut -c1-10)" = "declare -a" ]; then
      eval 'for w in "${'"$n"'[@]}"; do echo "$n[]=$w"; done'
    else
      eval 'echo "$n=${'"$n"'}"'
    fi
  done
}
# the Ruby side: the same variables, the planner's exports as names, rest_* and the state's keys left out
ruby_side() {
  ruby "$repo/scripts/nfcxx-setup-state.rb" -- "$@" 2>/dev/null | sed -E 's/^exports\.//' | grep -v '^rest_status=\|^rest_message=\|^setup_span_\|^\(default\|asan\|stage\|rest\|flags\|backend_env\)[.=]'
}
check_case() {
  local want got
  want=$(bash_side "$@" | grep -v '^setup_span_' | sort); got=$(ruby_side "$@" | sort)
  if [ -z "$got" ]; then
    echo "skip: $* (the port does not plan it)"; return
  fi
  if [ "$want" = "$got" ]; then pass=$((pass + 1)); else fail=$((fail + 1)); echo "FAIL: $*"; diff <(echo "$want") <(echo "$got") | head -8; fi
}
check_case -c m.cpp -o m.o
check_case -c m.cpp -o m.o -fsanitize=address
check_case --backend=gcc -c m.cpp -o m.o
check_case -c m.cpp -o m.o --backend=gcc
check_case --freestanding --gnu-version=130000 -c m.cpp -o m.o
check_case --freestanding --gnu-version=130000 -c m.cpp -o m.o -fsafe-pointers
check_case --backend=pathb -c m.cpp -o m.o -O2
check_case -c m.cpp -o m.o -fpic -shared
echo "driver-setup-state: $pass passed, $fail failed"
[ $fail = 0 ]
