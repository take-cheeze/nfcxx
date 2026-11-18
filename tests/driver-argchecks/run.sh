#!/bin/bash
# scripts/nfcxx-argchecks.rb check must refuse what the bash checks after the argument loop refuse, with the same message on
# standard error and status 2, and must print nothing and succeed where they pass. The bash block below is copied verbatim from
# nfcxx (the -E stdin check, the -x language check, the -MD/-MMD check), run over every combination of the state those lines test,
# with the planner's call from nfcxx run over the same state. Stdout, stderr and status must match in each case.
#   bash tests/driver-argchecks/run.sh
here=$(cd "$(dirname "$0")" && pwd -P); repo=$(cd "$here/../.." && pwd -P)
root=$repo
work=$(mktemp -d); trap 'rm -rf "$work"' EXIT
pass=0; fail=0

# the bash checks, verbatim from nfcxx (they read stdin_src, xlang, depmode and compile_only from the caller)
bash_checks() {
if [ $stdin_src = 1 ]; then
  echo "nfcxx: a source on stdin is supported only with -E" >&2; exit 2
fi
case $xlang in ""|c++|none) ;; *) echo "nfcxx: -x $xlang: only C++ sources (use nfcc for C)" >&2; exit 2 ;; esac
if [ -n "$depmode" ] && [ $compile_only = 0 ]; then
  echo "nfcxx: $depmode needs -c (dependency files are written for a compile only)" >&2; exit 2
fi
}

# the planner, as nfcxx calls it (the same line, with the same variables)
ruby_checks() {
"${RUBY:-ruby}" "$root/scripts/nfcxx-argchecks.rb" check stdin_src="$stdin_src" xlang="$xlang" depmode="$depmode" compile_only="$compile_only" || exit $?
}

n=0
for stdin_src in 0 1; do
for xlang in "" c++ none c fortran "a=b"; do
for depmode in "" -MD -MMD; do
for compile_only in 0 1; do
  n=$((n + 1))
  name="stdin_src=$stdin_src xlang=[$xlang] depmode=[$depmode] compile_only=$compile_only"
  ( bash_checks ) > "$work/b.out" 2> "$work/b.err"; echo $? > "$work/b.rc"
  ( ruby_checks ) > "$work/r.out" 2> "$work/r.err"; echo $? > "$work/r.rc"
  if cmp -s "$work/b.out" "$work/r.out" && cmp -s "$work/b.err" "$work/r.err" && cmp -s "$work/b.rc" "$work/r.rc"; then
    pass=$((pass + 1))
  else
    fail=$((fail + 1))
    echo "FAIL $name"
    echo "  bash:   rc=$(cat "$work/b.rc") stderr=[$(cat "$work/b.err")] stdout=[$(cat "$work/b.out")]"
    echo "  planner: rc=$(cat "$work/r.rc") stderr=[$(cat "$work/r.err")] stdout=[$(cat "$work/r.out")]"
  fi
done; done; done; done

echo "driver-argchecks: $pass passed, $fail failed"
[ "$fail" = 0 ]
