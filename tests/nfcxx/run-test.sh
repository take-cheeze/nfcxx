#!/usr/bin/env bash
# The runner (scripts/nfcxx-run.rb) runs a plan for real. For the corpus lines that give the port a RUN or EXEC plan, the
# commands the runner runs (against a fake driver that logs its argv) must be the commands the oracle prints
# (tests/nfcxx/option-state.sh). The rest checks the plan format and the runner's behaviour: the exit status, the first
# failure, CP, LN, CAT, arguments with spaces, the environment, and the working directory.
#   tests/nfcxx/run-test.sh     prints the counts; exits nonzero on a failure
cd "$(dirname "$0")/../.."
root=$PWD
run=scripts/nfcxx-run.rb
work=$(mktemp -d); trap 'rm -rf "$work"' EXIT
pass=0; fail=0

check() {
  if [ "$1" = "$2" ]; then pass=$((pass + 1)); else fail=$((fail + 1)); echo "FAIL $3"; echo "  want: [$2]"; echo "  got:  [$1]"; fi
}

# a fake driver: logs its own path and its argv, one line, tab-separated; exits 0
fake=$work/fake
log=$work/log
mkdir -p "$fake/build"
for prog in "$fake/nfcxx" "$fake/build/nfcbundle"; do
  cat > "$prog" <<EOF
#!/bin/sh
printf '%s' "\$0" >> "$log"
for a in "\$@"; do printf '\t%s' "\$a" >> "$log"; done
printf '\n' >> "$log"
EOF
  chmod +x "$prog"
done

# the corpus lines with RUN or EXEC plans (their steps are the -fsyntax-only re-run and the --bundle-* re-runs)
corpus_lines=(
  "-fsyntax-only x.cpp"
  "-c x.cpp -fsyntax-only -o out.o"
  "-fsyntax-only -o"
  "-fsyntax-only -E x.cpp"
  "-fsyntax-only -DA=1 -O2 -fsyntax-only x.cpp"
  "-c x.cpp --bundle-libs"
  "x.cpp --bundle-libs"
  "-o prog x.cpp --bundle-libs --bundle-exclude=libfoo.so,libbar"
  "--bundle-libs --bundle-add=libtorch_cuda.so -Lfoo -L bar x.cpp"
  "--bundle-libs -o out.bin x.cpp -fsyntax-only"
)
for line in "${corpus_lines[@]}"; do
  grep -qxF -- "$line" tests/nfcxx/loop-cases.txt || { echo "FAIL corpus line not in loop-cases.txt: $line"; fail=$((fail + 1)); }
done

# the oracle's commands, as the runner's log writes them: ROOT for the repository (the driver nfcxx is "nfcxx" in the oracle),
# TMP for the temporary directory, and tabs between the words
oracle_commands() {
  local -a words
  read -r -a words <<< "$1"
  tests/nfcxx/option-state.sh "${words[@]}" 2>&1 | sed -E -e 's/^(RUN|EXEC) //' -e 's/^nfcxx( |$)/ROOT\/nfcxx\1/' | tr ' ' '\t'
}

for line in "${corpus_lines[@]}"; do
  read -r -a words <<< "$line"
  rm -f "$log"
  want=$(oracle_commands "$line")
  ruby "$run" --root="$fake" --tmp="$work/tmp" -- "${words[@]}" > "$work/out" 2>&1; st=$?
  got=$(sed -e "s|$fake|ROOT|g" -e "s|$work/tmp|TMP|g" "$log" 2>/dev/null)
  check "$st:$got" "0:$want" "corpus: $line"
done

# --emit-plan: tab-separated, placeholders kept, the port's own argv
got=$(ruby "$run" --emit-plan -- -fsyntax-only x.cpp)
check "$got" "$(printf 'RUN\tnfcxx\t-c\tx.cpp\t-o\tTMP/x.o')" "emit-plan: -fsyntax-only"
got=$(ruby "$run" --emit-plan -- --bundle-libs -o out.bin x.cpp -fsyntax-only 2>&1)
check "$got" "$(printf 'RUN\tnfcxx\t-c\t--bundle-libs\t-o\tTMP/x.o\tx.cpp')" "emit-plan: bundle option is a port argument"

# a plan file written by --emit-plan runs the same as the port's plan (the plan format round trip)
ruby "$run" --emit-plan -- x.cpp --bundle-libs > "$work/plan.tsv"
rm -f "$log"
ruby "$run" --root="$fake" --tmp="$work/tmp" --plan="$work/plan.tsv" > "$work/out" 2>&1; st=$?
got=$(sed -e "s|$fake|ROOT|g" -e "s|$work/tmp|TMP|g" "$log")
check "$st:$got" "0:$(oracle_commands "x.cpp --bundle-libs")" "plan file: round trip of the port's plan"

# a plan whose ordinary arguments give state, not a plan: refused
ruby "$run" -- -c a.cpp > /dev/null 2> "$work/err"; st=$?
check "$st" "2" "refused: arguments with no plan (status)"
check "$(grep -c 'no plan' "$work/err")" "1" "refused: arguments with no plan (message)"

# exit status: the failing command's status is the runner's; EXEC ends the plan with its status
printf 'RUN\tsh\t-c\texit 7\n' > "$work/p1"
ruby "$run" --plan="$work/p1"; st=$?
check "$st" "7" "exit: RUN status propagates"
printf 'EXEC\tsh\t-c\texit 5\n' > "$work/p2"
ruby "$run" --plan="$work/p2"; st=$?
check "$st" "5" "exit: EXEC status propagates"
printf 'EXEC\ttrue\n' > "$work/p3"
ruby "$run" --plan="$work/p3"; st=$?
check "$st" "0" "exit: EXEC success is 0"

# first failure stops the plan
marker=$work/marker
printf 'RUN\tsh\t-c\texit 3\nRUN\ttouch\t%s\n' "$marker" > "$work/p4"
ruby "$run" --plan="$work/p4"; st=$?
check "$st:$(test -e "$marker" && echo made || echo absent)" "3:absent" "first failure: later commands do not run"
printf 'EXEC\tsh\t-c\texit 4\nRUN\ttouch\t%s\n' "$marker" > "$work/p5"
ruby "$run" --plan="$work/p5"; st=$?
check "$st:$(test -e "$marker" && echo made || echo absent)" "4:absent" "first failure: EXEC ends the plan"
printf 'RUN\ttrue\nRUN\ttouch\t%s\n' "$marker" > "$work/p6"
ruby "$run" --plan="$work/p6"; st=$?
check "$st:$(test -e "$marker" && echo made || echo absent)" "0:made" "success: every command runs"

# a command that cannot be started: 127
printf 'RUN\tno-such-program-nfcxx-run\n' > "$work/p7"
ruby "$run" --plan="$work/p7" 2> /dev/null; st=$?
check "$st" "127" "missing program: status 127"

# CP, CAT, LN, with names that hold spaces
mkdir -p "$work/with space"
printf 'hello world\n' > "$work/with space/src file.txt"
printf 'CP\t%s\t%s\nLN\t-s\t%s\t%s\nCAT\t%s\n' \
  "$work/with space/src file.txt" "$work/with space/copy file.txt" \
  "$work/with space/copy file.txt" "$work/link here" "$work/link here" > "$work/p8"
got=$(ruby "$run" --plan="$work/p8"); st=$?
check "$st:$got" "0:hello world" "CP, LN and CAT: the copy is read through the link"
check "$(readlink "$work/link here")" "$work/with space/copy file.txt" "LN -s: the link points at the target"
check "$(cat "$work/with space/copy file.txt")" "hello world" "CP: the copy has the content"

# a CP whose source is missing stops the plan with status 1
printf 'CP\t%s\t%s\nRUN\ttouch\t%s\n' "$work/absent" "$work/x" "$marker.2" > "$work/p9"
ruby "$run" --plan="$work/p9" 2> /dev/null; st=$?
check "$st:$(test -e "$marker.2" && echo made || echo absent)" "1:absent" "CP failure stops the plan"

# arguments with spaces (and an empty one) reach the program as they are
printf 'RUN\tROOT/nfcxx\ta b\t\tc  d\t"e"\n' > "$work/p10"
rm -f "$log"
ruby "$run" --root="$fake" --plan="$work/p10"; st=$?
check "$st:$(sed -e "s|$fake|ROOT|" "$log")" "0:$(printf 'ROOT/nfcxx\ta b\t\tc  d\t"e"')" "spaces: arguments survive, empty argument kept"

# the environment: --env in both forms
printf 'RUN\tsh\t-c\tprintf %%s "$FOO$BAR"\n' > "$work/p11"
got=$(ruby "$run" --env FOO=foo --env=BAR=bar --plan="$work/p11"); st=$?
check "$st:$got" "0:foobar" "env: --env NAME=VALUE and --env=NAME=VALUE reach the commands"
ruby "$run" --env NOEQ --plan="$work/p11" 2> /dev/null; st=$?
check "$st" "2" "env: a variable with no = is refused"

# the working directory
mkdir -p "$work/cd"
printf 'relative\n' > "$work/cd/rel.txt"
printf 'CAT\trel.txt\n' > "$work/p12"
got=$(ruby "$run" --chdir="$work/cd" --plan="$work/p12"); st=$?
check "$st:$got" "0:relative" "chdir: relative paths are taken from the directory"

# the plan is checked before it runs: a bad line means nothing runs
printf 'RUN\ttouch\t%s\nBOGUS\tx\n' "$marker.3" > "$work/p13"
ruby "$run" --plan="$work/p13" 2> /dev/null; st=$?
check "$st:$(test -e "$marker.3" && echo made || echo absent)" "2:absent" "bad plan: refused before any command runs"

# the runner's own usage errors
ruby "$run" --bogus -- x.cpp 2> /dev/null; st=$?
check "$st" "2" "usage: unknown option"
ruby "$run" > /dev/null 2>&1; st=$?
check "$st" "2" "usage: no plan and no port arguments"

echo "$pass passed, $fail failed"
[ "$fail" = 0 ]
