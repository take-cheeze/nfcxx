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
sed -n '/^eccp_cleanup() {/,/^}/p;/^link_records_rm() {/,/^}/p' "$repo/nfcxx" > "$work/thin.sh"
[ -s "$work/thin.sh" ] || { echo "nfcxx-link: no link steps in nfcxx" >&2; exit 2; }

# run WHICH SB SETUP BODY: builds SB, runs BODY in bash with the functions of WHICH (thin or oracle); prints the outcome
run() {
  local which=$1 sb=$2 setup=$3 body=$4 src
  src=$here/oracle.sh; [ "$which" = thin ] && src=$work/thin.sh
  rm -rf "$sb"; mkdir -p "$sb/sub" "$sb/tmp1/x" "$sb/tmp2" "$sb/tmp3"
  : > "$sb/a.o"; : > "$sb/a.ii"; : > "$sb/b.o"; : > "$sb/b.ii"; : > "$sb/c.ii"; : > "$sb/sub/d.ii"; : > "$sb/.ii"
  ln -s nowhere "$sb/dang.ii"; mkdir "$sb/dir.ii"; : > "$sb/dir.o"
  # the globals nfcxx sets before the link (eccp_dir and keep_intermediates always; cudatmp and ctmp only when a build made them)
  local prelude="set -euo pipefail; root=$repo; RUBY=$ruby_bin; trace_finish() { :; }; eccp_dir=; keep_intermediates=0; source $src"
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

# eccp_cleanup: the EXIT trap (the status it leaves is the driver's, not the removals')
case_ "cleanup: all three removed" 'keep_intermediates=0; eccp_dir=tmp1; cudatmp=tmp2; ctmp=tmp3' 'trap eccp_cleanup EXIT; exit 5'
case_ "cleanup: keep-intermediates keeps the eccp directory" 'keep_intermediates=1; eccp_dir=tmp1; cudatmp=tmp2; ctmp=tmp3' 'trap eccp_cleanup EXIT; exit 5'
case_ "cleanup: nothing set" 'keep_intermediates=0' 'trap eccp_cleanup EXIT; exit 5'
case_ "cleanup: only the eccp directory" 'keep_intermediates=0; eccp_dir=tmp1' 'trap eccp_cleanup EXIT; exit 5'
case_ "cleanup: only the .cu temporary directory" 'keep_intermediates=0; cudatmp=tmp2' 'trap eccp_cleanup EXIT; exit 5'
case_ "cleanup: a directory that does not exist" 'keep_intermediates=0; eccp_dir=nowhere; ctmp=tmp3' 'trap eccp_cleanup EXIT; exit 5'
case_ "cleanup: keep-intermediates with the other two" 'keep_intermediates=1; cudatmp=tmp2; ctmp=tmp3' 'trap eccp_cleanup EXIT; exit 0'
case_ "cleanup: the status of a failed build is kept" 'keep_intermediates=0; eccp_dir=tmp1' 'trap eccp_cleanup EXIT; false'

echo "nfcxx-link: $pass passed, $fail failed"
[ "$fail" = 0 ]
