#!/bin/bash
# Differential test of the link steps: nfcxx's link_records_rm and eccp_cleanup (the thin bash functions of nfcxx, which run
# scripts/nfcxx-link.rb) against tests/nfcxx-link/oracle.sh (their bash originals, verbatim). Each case builds the same
# sandbox twice and runs the same body under the same prelude (set -euo pipefail, as nfcxx has it) once with each set of
# functions. The status, the standard error (its sandbox path normalized) and the files left must be the same.
#
#   bash tests/nfcxx-link/run.sh
set -u
here=$(cd "$(dirname "$0")" && pwd -P)
repo=$(cd "$here/../.." && pwd -P)
work=$(mktemp -d); trap 'rm -rf "$work"' EXIT
ruby_bin=$(command -v ruby)
# the functions as nfcxx has them now (the port is what they call)
sed -n '/^temp_cleanup() {/,/^}/p;/^eccp_cleanup() {/,/^}/p;/^link_records_rm() {/,/^}/p' "$repo/tests/driver-body/nfcxx-bash" > "$work/thin.sh"
[ -s "$work/thin.sh" ] || { echo "nfcxx-link: no link steps in nfcxx" >&2; exit 2; }
# compile_clean is not a function of nfcxx any more: its body call is inlined, and the thin side runs the same gated call of
# scripts/nfcxx-link.rb compile-clean (the oracle keeps its bash loop, compile_clean in oracle.sh). @CC@ in a case stands for the call.
CC_THIN='if [ $compile_only = 1 ] && [ $ncpp -gt 0 ]; then "${RUBY:-ruby}" "$root/scripts/nfcxx-link.rb" compile-clean "$out" ${srcs[@]+"${srcs[@]}"}; fi'

# run WHICH SB SETUP BODY: builds SB, runs BODY in bash with the functions of WHICH (thin or oracle); prints the outcome
run() {
  local which=$1 sb=$2 setup=$3 body=$4 src cc=compile_clean
  src=$here/oracle.sh; if [ "$which" = thin ]; then src=$work/thin.sh; cc=$CC_THIN; fi
  # (no pattern replacement here: the call has &&, which a replacement string would read as a match reference in bash 5.2)
  case $body in *@CC@*) body=${body%%@CC@*}$cc${body#*@CC@} ;; esac
  rm -rf "$sb"; mkdir -p "$sb/sub" "$sb/tmp1/x" "$sb/tmp2" "$sb/tmp3"
  : > "$sb/a.o"; : > "$sb/a.ii"; : > "$sb/b.o"; : > "$sb/b.ii"; : > "$sb/c.ii"; : > "$sb/sub/d.ii"; : > "$sb/.ii"
  ln -s nowhere "$sb/dang.ii"; mkdir "$sb/dir.ii"; : > "$sb/dir.o"
  # the globals nfcxx sets before the link (eccp_dir, eccp_owned and keep_intermediates always; cudatmp and ctmp only when a build made them)
  local prelude="set -euo pipefail; root=$repo; RUBY=$ruby_bin; trace_finish() { :; }; eccp_dir=; eccp_owned=; keep_intermediates=0; source $src"
  local err rc
  err=$( cd "$sb" && bash -c "$prelude; ${setup:+$setup; }$body" 2>&1 >/dev/null ); rc=$?
  err=${err//$sb/<sb>}
  printf 'status %s\nstderr %s\n' "$rc" "$err"
  ( cd "$sb" && find . -mindepth 1 -printf '%y %p %l\n' | sort )
}

pass=0; fail=0
case_() {  # case_ NAME SETUP BODY: the thin functions and the oracle must agree
  local name=$1 setup=$2 body=$3
  local t o
  t=$(run thin "$work/sb-thin" "$setup" "$body")
  o=$(run oracle "$work/sb-oracle" "$setup" "$body")
  if [ "$t" = "$o" ]; then
    pass=$((pass + 1))
  else
    fail=$((fail + 1)); echo "FAIL $name"; echo "--- oracle"; echo "$o"; echo "--- thin"; echo "$t"
  fi
  rm -rf "$work/sb-thin" "$work/sb-oracle"
}

# link_records_rm: the .ii beside each .o of the link
case_ "records: each object's .ii goes, others stay" '' 'files=(a.o b.o c.o); link_records_rm'
case_ "records: a link option and a library are not objects" '' 'files=(a.o -lm x.a -Wl,y.o -Wl,z); link_records_rm'
case_ "records: no files" '' 'files=(); link_records_rm'
case_ "records: files unset" '' 'unset files; link_records_rm'
case_ "records: a .ii that is a directory fails the last object" '' 'files=(dir.o a.o); link_records_rm'
case_ "records: the failing object is not last" '' 'files=(dir.o a.o); link_records_rm; echo after'
case_ "records: a dangling .ii symbolic link is removed" '' 'files=(dang.o); link_records_rm'
case_ "records: an object in a directory" '' 'files=(sub/d.o); link_records_rm'
case_ "records: a file named .o" '' 'files=(.o); link_records_rm'
case_ "records: an object with no .ii" '' 'files=(c.o); link_records_rm'
case_ "records: a non-object last (status 0)" '' 'files=(a.o dir.o b.o x.so); link_records_rm'
# a name rm reads as an option: rm reports it (its own words and status), so the port runs rm for it
case_ "records: --name=value is rm's to report" '' 'files=(--a=b.o); link_records_rm'
case_ "records: --force=value (an option with no argument)" '' 'files=(--force=x.o); link_records_rm'
case_ "records: --fo.o (a long-option prefix)" '' 'files=(--fo.o); link_records_rm'
case_ "records: -i.o (a letter, then the dot)" '' 'files=(-i.o); link_records_rm'
case_ "records: -fi.o (letters that rm takes, then the dot)" '' 'files=(-fi.o); link_records_rm'
case_ "records: -x=y.o (an unknown letter)" '' 'files=(-x=y.o); link_records_rm'
case_ "records: --interactive=value (an optional argument)" '' 'files=(--interactive=x.o); link_records_rm'
case_ "records: --.o" '' 'files=(--.o); link_records_rm'
case_ "records: an option-like name stops the loop after the objects before it" '' 'files=(a.o -x.o b.o); link_records_rm; echo after'
case_ "records: a name with a space" ': > "a b.ii"' 'files=("a b.o"); link_records_rm'
case_ "records: a name ending in .o.o takes its stem" ': > a.o.ii' 'files=(a.o.o); link_records_rm'
case_ "records: a symbolic link to a directory is removed, not followed" 'ln -s sub link.ii' 'files=(link.o); link_records_rm; echo done'
case_ "records: a -- argument is a name, not the end of the list" ': > a.ii' 'files=(-- a.o); link_records_rm'

# eccp_cleanup: the EXIT trap (the status it leaves is the driver's, not the removals')
case_ "cleanup: all three removed" 'keep_intermediates=0; eccp_dir=tmp1; cudatmp=tmp2; ctmp=tmp3' 'trap eccp_cleanup EXIT; exit 5'
case_ "cleanup: keep-intermediates keeps the eccp directory" 'keep_intermediates=1; eccp_dir=tmp1; cudatmp=tmp2; ctmp=tmp3' 'trap eccp_cleanup EXIT; exit 5'
case_ "cleanup: nothing set" 'keep_intermediates=0' 'trap eccp_cleanup EXIT; exit 5'
case_ "cleanup: only the eccp directory" 'keep_intermediates=0; eccp_dir=tmp1' 'trap eccp_cleanup EXIT; exit 5'
case_ "cleanup: only the .cu temporary directory" 'keep_intermediates=0; cudatmp=tmp2' 'trap eccp_cleanup EXIT; exit 5'
case_ "cleanup: a directory that does not exist" 'keep_intermediates=0; eccp_dir=nowhere; ctmp=tmp3' 'trap eccp_cleanup EXIT; exit 5'
case_ "cleanup: keep-intermediates with the other two" 'keep_intermediates=1; cudatmp=tmp2; ctmp=tmp3' 'trap eccp_cleanup EXIT; exit 0'
case_ "cleanup: the status of a failed build is kept" 'keep_intermediates=0; eccp_dir=tmp1' 'trap eccp_cleanup EXIT; false'

# compile_clean: the records of the sources of a -c compile (the first source takes the stem of -o)
case_ "compile-clean: a source's records go" ': > a.ti' 'compile_only=1; ncpp=1; srcs=(a.cc); out=a.o; @CC@; echo after'
case_ "compile-clean: not -c, nothing goes" ': > a.ti' 'compile_only=0; ncpp=1; srcs=(a.cc); out=a.o; @CC@; echo after'
case_ "compile-clean: no C++ sources, nothing goes" ': > a.ti' 'compile_only=1; ncpp=0; srcs=(a.cc); out=a.o; @CC@; echo after'
case_ "compile-clean: the first source takes the stem of -o" ': > b.ti' 'compile_only=1; ncpp=2; srcs=(a.cc b.cc); out=b.o; @CC@; echo after'
case_ "compile-clean: -o without a dot: the sources' own stems" ': > prog.ti' 'compile_only=1; ncpp=1; srcs=(a.cc); out=prog; @CC@; echo after'
case_ "compile-clean: a dot in a directory of -o is the stem (as the bash)" ': > x.ti' 'compile_only=1; ncpp=1; srcs=(a.cc); out=x.d/prog; @CC@; echo after'
case_ "compile-clean: a source with no extension" ': > noext.ti' 'compile_only=1; ncpp=1; srcs=(noext); out=noext.o; @CC@; echo after'
case_ "compile-clean: a source in a directory" ': > sub/d.ti' 'compile_only=1; ncpp=1; srcs=(sub/d.cc); out=d.o; @CC@; echo after'
case_ "compile-clean: a .ti that is a directory fails the step" 'mkdir a.ti' 'compile_only=1; ncpp=2; srcs=(a.cc b.cc); out=a.o; @CC@; echo after'
case_ "compile-clean: a failing first source stops the loop" 'mkdir a.ti; : > b.ii' 'compile_only=1; ncpp=2; srcs=(a.cc b.cc); out=a.o; @CC@; echo after'
case_ "compile-clean: an option-like source is rm's to read" ': > -x.ti' 'compile_only=1; ncpp=1; srcs=(-x.cc); out=-x.o; @CC@; echo after'
case_ "compile-clean: no sources" '' 'compile_only=1; ncpp=1; srcs=(); out=a.o; @CC@; echo after'
case_ "compile-clean: sources unset" '' 'compile_only=1; ncpp=1; unset srcs; out=a.o; @CC@; echo after'

# eccp_cleanup with the eccp directory the Ruby driver made (eccp_owned=1, cudatmp owned): the trap leaves both directories to the
# driver, keeps the status and calls trace_finish. The oracle is the bash before the driver owned the directory, so these cases
# check the thin functions alone.
owned_case() {  # owned_case NAME KEEP BODY WANT_STATUS: the eccp and .cu directories survive, the status is WANT_STATUS
  local name=$1 keep=$2 body=$3 want=$4 sb out rc
  sb=$(mktemp -d "$work/owned.XXXXXX"); mkdir "$sb/eccp" "$sb/cu"
  out=$(cd "$sb" && bash -c "set -euo pipefail; root=$repo; RUBY=$ruby_bin; trace_finish() { echo traced; }; eccp_dir=$sb/eccp; eccp_owned=1; keep_intermediates=$keep; cudatmp=$sb/cu; cudatmp_owned=1; source $work/thin.sh; $body" 2>/dev/null) && rc=0 || rc=$?
  if [ "$rc" = "$want" ] && [ -d "$sb/eccp" ] && [ -d "$sb/cu" ] && [ "$out" = traced ]; then
    pass=$((pass + 1))
  else
    fail=$((fail + 1)); echo "FAIL $name: status $rc (want $want), out [$out], directories: $(ls "$sb" | tr '\n' ' ')"
  fi
}
owned_case "owned: the driver removes the eccp directory (not kept)" 0 'trap eccp_cleanup EXIT; exit 5' 5
owned_case "owned: keep-intermediates" 1 'trap eccp_cleanup EXIT; exit 5' 5
owned_case "owned: the status of a failed build is kept" 0 'trap eccp_cleanup EXIT; false' 1

echo "nfcxx-link: $pass passed, $fail failed"
[ "$fail" = 0 ]
