#!/bin/bash
# Differential test of the driver's trace and time log (--trace=FILE, --time-log=FILE) on the Path B routes: each case runs
# through the bash driver (nfcxx) and through the Ruby entry (scripts/nfcxx.rb), in the same directory (the diagnostics name
# it), and the two must agree on the status, the standard output and error, the files, and their contents. The trace file and
# the time log are compared after the clock readings and the process ids are replaced by placeholders (as tests/trace/run.sh
# does); other files must be identical. The route is checked too: the Ruby entry's "nfcxx: driver:" line (NFCXX_DRIVER_TRACE=1)
# names the path it ran.
#
# The cases are in tests/nfcxx-trace/cases.txt, one "ROUTE | ARGS" per line. ROUTE is the route the Ruby entry takes:
#   pathb-plan      the Path B port plans the arguments and the runner runs the plan
#   pathb-fallback  the same, and the plan fails under the default backend: the bash runs the arguments again (its standard
#                   error is not compared: the diagnostics of the failed compile come from both runs, as they do without a trace)
#   plan            the loop port's plan (the bash runs the commands)
#   bash            the ports refuse the arguments: the bash runs them
#
#   bash tests/nfcxx-trace/run.sh
set -u
here=$(cd "$(dirname "$0")" && pwd -P)
repo=$(cd "$here/../.." && pwd -P)
work=$(mktemp -d); trap 'rm -rf "$work"' EXIT
scratch=$work/dir   # the directory of both sides (the same path: the diagnostics name it)
pass=0; fail=0

# the fixtures of a case: a.cpp and b.cpp compile (main is in a.cpp), bad.cpp does not (#error), c.c is C
fixtures() {
  rm -rf "$scratch"; mkdir -p "$scratch"
  printf 'int add(int a, int b) { return a + b; }\nint main() { return add(1, 2) - 3; }\n' > "$scratch/a.cpp"
  printf 'int twice(int a) { return 2 * a; }\n' > "$scratch/b.cpp"
  printf '#error boom\n' > "$scratch/bad.cpp"
  printf 'int one(void) { return 1; }\n' > "$scratch/c.c"
}

# the placeholders for the clock readings and process ids (the same as tests/trace/run.sh)
normalize() {
  sed -e 's/"ts":[0-9]*/"ts":N/g' -e 's/"dur":[0-9]*/"dur":N/g' -e 's/"pid":[0-9]*/"pid":P/g' \
      -e 's/^[0-9][0-9]*\.[0-9][0-9][0-9][0-9][0-9][0-9]\t/S.SSSSSS\t/' "$1"
}

# runs one side of a case in the scratch directory; its results go to $res: status, stdout, stderr, the files (dir)
run_side() {  # run_side SIDE ARGS...
  local side=$1; shift
  res=$work/res/$n/$side
  mkdir -p "$res"
  fixtures
  if [ "$side" = bash ]; then
    (cd "$scratch" && env -i PATH="$PATH" HOME="$scratch" "$repo/nfcxx" "$@" > "$res/stdout" 2> "$res/stderr")
  else
    (cd "$scratch" && env -i PATH="$PATH" HOME="$scratch" NFCXX_DRIVER_TRACE=1 ruby "$repo/scripts/nfcxx.rb" "$@" \
       > "$res/stdout" 2> "$res/stderr")
  fi
  echo $? > "$res/status"
  mv "$scratch" "$res/dir"
  # the route line of the Ruby entry, which the stderr comparison leaves out
  if [ "$side" = ruby ]; then
    sed -n 's/^nfcxx: driver: //p' "$res/stderr" | head -1 > "$res/route"
    grep -v '^nfcxx: driver: ' "$res/stderr" > "$res/stderr.cmp" || true
  else
    cp "$res/stderr" "$res/stderr.cmp"
  fi
}

check() {  # check NAME WANT GOT
  if [ "$2" = "$3" ]; then pass=$((pass + 1)); else fail=$((fail + 1)); echo "FAIL $1"; echo "  want: [$2]"; echo "  got:  [$3]"; fi
}

# the files of a side match the other side's: the same names, the same contents (the text of a trace or a log after the
# normalization; any other file byte for byte)
compare_files() {  # compare_files BASH_DIR RUBY_DIR
  local a=$1 b=$2 f
  check "$1 files" "$(cd "$a" && ls -A | tr '\n' ' ')" "$(cd "$b" && ls -A | tr '\n' ' ')"
  for f in $(cd "$a" && ls -A); do
    [ -f "$b/$f" ] || continue
    if cmp -s "$a/$f" "$b/$f"; then
      pass=$((pass + 1))
    elif diff <(normalize "$a/$f") <(normalize "$b/$f") > "$work/diff"; then
      pass=$((pass + 1))
    else
      fail=$((fail + 1)); echo "FAIL $name: file $f"; sed 's/^/  /' "$work/diff" | head -20
    fi
  done
}

n=0
while IFS= read -r line; do
  case $line in ""|\#*) continue ;; esac
  n=$((n + 1))
  route=${line%%|*}; route=${route// /}
  argline=${line#*|}
  read -r -a args <<< "$argline"
  name="$route:$argline"
  run_side bash "${args[@]}"
  bres=$res
  run_side ruby "${args[@]}"
  rres=$res
  # pathb-fallback is a planned route too (the driver's line names it pathb-plan)
  want=$route; [ "$route" = pathb-fallback ] && want=pathb-plan
  check "$name route" "$want" "$(cat "$rres/route")"
  check "$name status" "$(cat "$bres/status")" "$(cat "$rres/status")"
  check "$name stdout" "$(cat "$bres/stdout")" "$(cat "$rres/stdout")"
  # a pathb-fallback case's standard error is left out (see the header)
  [ "$route" = pathb-fallback ] || check "$name stderr" "$(cat "$bres/stderr.cmp")" "$(cat "$rres/stderr.cmp")"
  compare_files "$bres/dir" "$rres/dir"
done < "$here/cases.txt"

echo "trace-plan: $pass passed, $fail failed ($n cases)"
[ $fail = 0 ]
