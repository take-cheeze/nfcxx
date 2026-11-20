#!/bin/bash
# Differential test of the Path B dispatch of the Ruby driver (scripts/nfcxx.rb): each argument list runs through the bash driver
# (nfcxx) and through the Ruby entry, in the same directory (the diagnostics name it), and the two must agree on the status, the
# standard output and error, and the files. The Ruby entry's route line (NFCXX_DRIVER_TRACE=1: "nfcxx: driver: ROUTE") is checked
# too; a planned Path B route is "pathb-plan", the bash's own route is "bash".
#
# The cases are the lines of the CASES list below ("ROUTE | ARGS"). In this environment QBE rejects -V, so pathb-cc fails on every
# source and the Path B plan falls back to gcc through its CHECK line (the bash's own rule: the same message, then the driver is
# run again with NFCXX_BACKEND=gcc). The real Path B success route is not run here; the stub section below checks the runner's
# CHECK and STORE kinds directly, which the success and failure routes both use.
#
#   bash tests/driver-pathb-dispatch/run.sh
set -u
here=$(cd "$(dirname "$0")" && pwd -P)
repo=$(cd "$here/../.." && pwd -P)
work=$(mktemp -d); trap 'rm -rf "$work"' EXIT
scratch=$work/dir   # the directory of both sides (the same path: the diagnostics name it)
pass=0; fail=0

# the fixtures of a case: a.cpp (main) and b.cpp compile, bad.cpp does not (#error), c.c is C
fixtures() {
  rm -rf "$scratch"; mkdir -p "$scratch"
  printf 'int add(int a, int b) { return a + b; }\nint main() { return add(1, 2) - 3; }\n' > "$scratch/a.cpp"
  printf 'int twice(int a) { return 2 * a; }\n' > "$scratch/b.cpp"
  printf '#error boom\n' > "$scratch/bad.cpp"
  printf 'int one(void) { return 1; }\n' > "$scratch/c.c"
}

check() {  # check NAME WANT GOT
  if [ "$2" = "$3" ]; then pass=$((pass + 1)); else fail=$((fail + 1)); echo "FAIL $1"; echo "  want: [$2]"; echo "  got:  [$3]"; fi
}

# runs one side of a case in the scratch directory; its results go to $res: status, stdout, stderr (stderr.cmp: the Ruby entry's
# route line left out), route (the Ruby entry's), and the files (dir)
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
  if [ "$side" = ruby ]; then
    sed -n 's/^nfcxx: driver: //p' "$res/stderr" | head -1 > "$res/route"
    grep -v '^nfcxx: driver: ' "$res/stderr" > "$res/stderr.cmp" || true
  else
    cp "$res/stderr" "$res/stderr.cmp"
  fi
}

# the placeholders for the clock readings and process ids (the same as tests/nfcxx-trace/run.sh)
normalize() {
  sed -e 's/"ts":[0-9]*/"ts":N/g' -e 's/"dur":[0-9]*/"dur":N/g' -e 's/"pid":[0-9]*/"pid":P/g' \
      -e 's/^[0-9][0-9]*\.[0-9][0-9][0-9][0-9][0-9][0-9]\t/S.SSSSSS\t/' "$1"
}

# the files of a side match the other side's: the same names, the same bytes (a trace or a time log: the same after the
# normalization of the clock readings and process ids). ccache's directory ~/.cache is left out: the bash's pathb-cc creates it
# under this HOME, and the Ruby driver's runs of pathb-cc do not (a ccache effect of the parent process; no output, status or
# object differs)
compare_files() {  # compare_files BASH_DIR RUBY_DIR NAME
  local a=$1 b=$2 f
  check "$3 files" "$(cd "$a" && ls -A | grep -v '^[.]cache$' | tr '\n' ' ')" "$(cd "$b" && ls -A | grep -v '^[.]cache$' | tr '\n' ' ')"
  for f in $(cd "$a" && ls -A | grep -v '^[.]cache$'); do
    [ -f "$b/$f" ] || continue
    if cmp -s "$a/$f" "$b/$f"; then pass=$((pass + 1))
    elif diff <(normalize "$a/$f") <(normalize "$b/$f") > /dev/null; then pass=$((pass + 1))
    else fail=$((fail + 1)); echo "FAIL $3: file $f differs"; fi
  done
}

CASES=(
  "pathb-plan | -c a.cpp"
  "pathb-plan | --backend=pathb -c a.cpp"
  "pathb-plan | -c bad.cpp"
  "pathb-plan | --backend=pathb -c bad.cpp"
  "pathb-plan | -c a.cpp b.cpp"
  "pathb-plan | a.cpp -o prog"
  "pathb-plan | --backend=pathb a.cpp -o prog"
  "pathb-plan | a.cpp b.cpp -o prog"
  "pathb-plan | a.cpp bad.cpp -o prog"
  "pathb-plan | --backend=pathb a.cpp bad.cpp -o prog"
  "pathb-plan | --time-log=l.txt a.cpp -o prog"
  "pathb-plan | -E a.cpp"
  "pathb-plan | --backend=pathb -fsanitize=address a.cpp -o prog"
  "pathb-plan | -c c.c"
  "pathb-plan | --trace=t.json --time-log=l.txt -c a.cpp"
  "pathb-plan | --trace=t.json a.cpp -o prog"
  "pathb-plan | --time-log=l.txt a.cpp -o prog"
  "pathb-plan | --trace=t.json -c bad.cpp"
  "bash | --cache=cachedir -c a.cpp"
  "bash | -shared a.cpp -o lib.so"
  "bash | --backend=gcc -c a.cpp"
)

n=0
for line in "${CASES[@]}"; do
  n=$((n + 1))
  route=${line%%|*}; route=${route// /}
  read -r -a args <<< "${line#*|}"
  name="$route:${line#*|}"
  run_side bash "${args[@]}"
  bres=$res
  run_side ruby "${args[@]}"
  rres=$res
  check "$name route" "$route" "$(cat "$rres/route")"
  check "$name status" "$(cat "$bres/status")" "$(cat "$rres/status")"
  check "$name stdout" "$(cat "$bres/stdout")" "$(cat "$rres/stdout")"
  check "$name stderr" "$(cat "$bres/stderr.cmp")" "$(cat "$rres/stderr.cmp")"
  compare_files "$bres/dir" "$rres/dir" "$name"
done

# the runner's CHECK and STORE kinds (scripts/nfcxx-run.rb), with the bash's rule for each: a zero status goes on; exit ends the
# plan with the status (no message); gcc prints BEFORE, the status and AFTER on standard error and runs its command (the plan's
# status is the command's); STORE with no entry runs nothing; a failed store does not stop the plan
runner=$repo/scripts/nfcxx-run.rb
plans=$work/plans; mkdir -p "$plans"
printf 'RUN\tsh\t-c\texit 0\nCHECK\texit\nRUN\techo\tafter\n' > "$plans/ok.txt"
printf 'RUN\tsh\t-c\texit 3\nCHECK\texit\nRUN\techo\tnot-reached\n' > "$plans/exit.txt"
printf 'RUN\tsh\t-c\texit 4\nCHECK\tgcc\tBEFORE:\t(after)\tenv\tX=1\techo\tgcc-form\nRUN\techo\tnot-reached\n' > "$plans/gcc.txt"
printf 'RUN\tsh\t-c\texit 0\nCHECK\tgcc\tBEFORE:\t(after)\tenv\tX=1\techo\tnot-reached\n' > "$plans/gcc-ok.txt"
printf 'RUN\tsh\t-c\texit 5\nRUN\techo\tnot-reached\n' > "$plans/no-check.txt"
printf 'START\tv\nRUN\tsh\t-c\texit 6\nSPANF\tv\tn\tc\tu\nCHECK\texit\nRUN\techo\tnot-reached\n' > "$plans/spanf.txt"
printf 'STORE\tmissing.o\t\t\nRUN\techo\tstored-nothing\n' > "$plans/store-empty.txt"
printf 'STORE\tmissing.o\tentry-dir\t\nRUN\techo\tafter-store\n' > "$plans/store-missing.txt"
runner_case() {  # runner_case NAME PLAN WANT_STATUS WANT_STDOUT WANT_STDERR
  local out err st
  out=$(cd "$work" && ruby "$runner" --root="$repo" --plan="$plans/$2" 2> "$work/err"); st=$?
  err=$(cat "$work/err")
  check "$1 status" "$3" "$st"
  check "$1 stdout" "$4" "$out"
  check "$1 stderr" "$5" "$err"
}
runner_case "plan with exit CHECK, status 0" ok.txt 0 "after" ""
runner_case "plan with a failing RUN and exit CHECK" exit.txt 3 "" ""
runner_case "plan with a failing RUN and gcc CHECK" gcc.txt 0 "gcc-form" "BEFORE:4(after)"
runner_case "gcc CHECK with a zero status goes on" gcc-ok.txt 0 "" ""
runner_case "a failing RUN with no CHECK stops the plan" no-check.txt 5 "" ""
runner_case "a span after a failing RUN is recorded, then the CHECK" spanf.txt 6 "" ""
runner_case "STORE with no entry runs nothing" store-empty.txt 0 "stored-nothing" ""
out=$(cd "$work" && ruby "$runner" --root="$repo" --plan="$plans/store-missing.txt" 2> "$work/err"); st=$?
check "STORE of a missing object: status" 0 "$st"
check "STORE of a missing object: stdout" "after-store" "$out"
check "STORE of a missing object: the store's note names it" 1 "$(grep -c 'missing.o' "$work/err")"

echo "driver-pathb-dispatch: $pass passed, $fail failed"
[ $fail = 0 ]
