#!/bin/bash
# scripts/nfcc-args.rb (the Ruby response-file expansion) must expand the arguments exactly as nfcc's bash add_arg does
# (taken from nfcc in the repository, lines of die and of the expanded array and add_arg). For each case, the same arguments
# (NUL-separated) and the same exit status. The cases are response files with whitespace, quotes, escapes, nested files,
# an unreadable file, an empty file, and a loop.
#   bash tests/nfcc-args/run.sh
repo=$(cd "$(dirname "$0")/../.." && pwd)
work=$(mktemp -d); trap 'rm -rf "$work"' EXIT
cd "$work" || exit 1
# the bash side: the frozen expansion (die, expanded and add_arg, as nfcc had them before the port)
cp "$repo/tests/nfcc-args/oracle-add-arg.sh" bash-add.sh
cat >> bash-add.sh <<'SH'
for a in "$@"; do add_arg "$a" 0; done
for x in "${expanded[@]}"; do printf '%s\0' "$x"; done
SH
printf 'simple a b\n' > r1.rsp
printf 'a "b c" '"'"'d e'"'"' f\\ g\n' > r2.rsp
printf '"quoted \\"inner\\" x"\n' > r3.rsp
printf 'x\n@r1.rsp\ny\n' > nested.rsp
printf '@loop.rsp\n' > loop.rsp
: > empty.rsp
printf 'tab\there\r\nnewline\x0cformfeed\x0bvtab\n' > ws.rsp
printf 'trail\\' > trail.rsp
printf 'a""b ""\n' > emptyq.rsp
printf 'plain\n' > nd.rsp; chmod 000 nd.rsp
pass=0; fail=0
run_case() {  # run_case NAME ARG...
  local name=$1; shift
  bash bash-add.sh "$@" > "b.out" 2>/dev/null; bs=$?
  ruby "$repo/scripts/nfcc-args.rb" "$@" > "r.out" 2>/dev/null; rs=$?
  if [ "$bs" = "$rs" ] && cmp -s b.out r.out; then pass=$((pass + 1)); echo "pass $name (status $bs, $(tr '\0' '|' < r.out | wc -c) bytes)"
  else fail=$((fail + 1)); echo "FAIL $name: status bash=$bs ruby=$rs"; diff <(tr '\0' '\n' < b.out) <(tr '\0' '\n' < r.out) | head -6; fi
}
run_case plain-args x y z
run_case simple @r1.rsp
run_case quotes-escapes @r2.rsp
run_case nested-quoted @r3.rsp
run_case nested-files x @nested.rsp
run_case empty-file @empty.rsp
run_case whitespace-kinds @ws.rsp
run_case trailing-backslash @trail.rsp
run_case empty-quotes @emptyq.rsp
run_case missing-file @nope.rsp
run_case loop-file @loop.rsp
run_case not-at-prefix plain-@r1.rsp
echo "passed $pass, failed $fail"
[ "$fail" = 0 ]
