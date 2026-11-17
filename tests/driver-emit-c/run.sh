#!/bin/bash
# Differential test of nfcxx's --emit-c include list: the bash lines verbatim (before the port) against
# scripts/nfcxx-emit-c.rb inc, for host and freestanding runs, relative and absolute -I options, a -I that does not exist,
# a bare -I, and a symbolic link. The elements must be the same, in the same order.
#   bash tests/driver-emit-c/run.sh
set -u
here=$(cd "$(dirname "$0")" && pwd -P)
repo=$(cd "$here/../.." && pwd -P)
work=$(mktemp -d); trap 'rm -rf "$work"' EXIT
pass=0; fail=0

# abs_path, as the driver defines it
abs_path() {
  local d b
  d=$(dirname "$1"); b=$(basename "$1")
  if (cd "$d" 2>/dev/null); then (cd "$d" && printf '%s/%s\n' "$(pwd -P)" "$b")
  else printf '%s\n' "$1"; fi
}
# the bash lines of the --emit-c block, verbatim (root, base, freestanding, sys_inc and files are set by the case)
bash_inc() {
  inc=(${sys_inc[@]+${sys_inc[@]+"${sys_inc[@]}"}} --sys_include="$base/include"); [ $freestanding = 1 ] && inc=("-I$root/lib")
  for x in ${files[@]+${files[@]+"${files[@]}"}}; do case $x in -I?*) inc=("-I$(abs_path "${x#-I}")" ${inc[@]+${inc[@]+"${inc[@]}"}}) ;; esac; done
  printf '%s\0' ${inc[@]+"${inc[@]}"}
}

mkdir -p "$work/real/sub" "$work/target"; ln -s "$work/target" "$work/link"
# case_ NAME: the variables freestanding, base, root, sys_inc and files are set by the caller
case_() {
  local name=$1 b t
  b=$(cd "$work" && bash_inc | od -An -c)
  t=$(cd "$work" && ruby "$repo/scripts/nfcxx-emit-c.rb" inc "$base" "$root" "$freestanding" \
        -- ${sys_inc[@]+"${sys_inc[@]}"} -- ${files[@]+"${files[@]}"} | od -An -c)
  if [ "$b" = "$t" ]; then pass=$((pass + 1)); echo "ok   $name"
  else fail=$((fail + 1)); echo "FAIL $name"; echo "  bash: $b"; echo "  port: $t"; fi
}

freestanding=0; base=/edg; root=/repo; sys_inc=(); files=()
case_ "host, no -I"
sys_inc=(--sys_include=/usr/include); files=()
case_ "host with a system directory"
files=(-Ireal -I/abs/dir)
case_ "relative and absolute -I, in order"
files=(-Ireal/sub -Ilink -I"$work/real/nonexistent" -DX=1 -Ifoo/)
case_ "a relative -I to a subdirectory, a symbolic link, a missing directory, a macro, a trailing slash"
files=(-I)
case_ "a bare -I (not a directory option)"
freestanding=1; sys_inc=(--sys_include=/usr/include); files=(-Ireal)
case_ "freestanding: the library replaces the system directories"
freestanding=0; files=(-I/x -I//y)
case_ "a root-level -I"

echo "driver-emit-c: $pass passed, $fail failed"
[ "$fail" = 0 ]
