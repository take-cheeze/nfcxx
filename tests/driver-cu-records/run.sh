#!/bin/bash
# The records of the frozen body's cu_prepare (the state_put block) against scripts/nfcxx-cu-records.rb: for each command, the body
# runs (the RUBY wrapper keeps the records the body sends to scripts/nfcxx-cu-cpp2-prepare.rb) and the planner gives the records
# from the same arguments. The root, the temporary directory and the body's pid are normalized. A command that does not reach
# cu_prepare (no .cu input before the link) is not in the list.
#   bash tests/driver-cu-records/run.sh
here=$(cd "$(dirname "$0")" && pwd -P); repo=$(cd "$here/../.." && pwd -P)
pass=0; fail=0
work=$(mktemp -d); trap 'rm -rf "$work"' EXIT
cap=$work/cap; mkdir -p "$cap"
cat > "$work/rubycap" <<WRAP
#!/bin/bash
case "\$*" in *nfcxx-cu-cpp2-prepare.rb*) cat > "$cap/\$\$.rec" ;; esac
exec ruby "\$@"
WRAP
chmod +x "$work/rubycap"
cd "$work" || exit 1
printf '__global__ void k(int*p){p[0]=1;}\nint main(){return 0;}\n' > a.cu
printf '__global__ void j(int*p){p[0]=2;}\n' > b.cu
norm() { tr '\0' '\n' | sed -e "s,$repo,@ROOT@,g" -e 's,/tmp/nfcxx-tmp\.[^/]*/tmp\.[^/]*,@TMP@,g' -e 's/^v[0-9][0-9]*$/v@PID@/;'; }
check() {  # check NAME ARGS...: the body's records against the planner's, for one command
  local name=$1; shift
  rm -f "$cap"/*.rec
  env RUBY="$work/rubycap" "$repo/nfcxx" "$@" > /dev/null 2> /dev/null
  local rec; rec=$(ls "$cap"/*.rec 2>/dev/null | head -1)
  if [ -z "$rec" ]; then fail=$((fail + 1)); echo "FAIL $name: the body sent no cu records"; return; fi
  local pid; pid=$(basename "$rec" .rec)
  local tmpdir; tmpdir=$(tr '\0' '\n' < "$rec" | sed -n '/^ktmp$/{n;s/^v//p;}')
  local want got
  want=$(norm < "$rec" | sed "s/^v$pid\$/v@PID@/")
  got=$(ruby "$repo/scripts/nfcxx-cu-records.rb" "$repo" "$tmpdir" "$pid" -- "$@" 2>/dev/null | norm | sed "s/^v$pid\$/v@PID@/")
  if [ "$want" = "$got" ]; then pass=$((pass + 1)); echo "ok   $name"
  else fail=$((fail + 1)); echo "FAIL $name"; diff <(echo "$want") <(echo "$got") | head -8; fi
}
check link-one a.cu -o x
check link-two a.cu b.cu -o x
check link-define a.cu -DFOO=1 -I. -o x
check link-promote a.cu -o x --promote-slots=off --unroll=off
check link-obfuscate a.cu --obfuscate-kernels -o x
echo "driver-cu-records: $pass passed, $fail failed"
[ "$fail" = 0 ]
