#!/bin/bash
# Differential test of scripts/ecp-arg.rb against tests/nfcxx-ecp-arg/oracle.sh (nfcxx's ecp_arg and abs_path, verbatim). Each
# argument is answered both ways in a sandbox with files and directories, from the same working directory; the answers must
# be the same.
#
#   bash tests/nfcxx-ecp-arg/run.sh
set -u
here=$(cd "$(dirname "$0")" && pwd -P)
repo=$(cd "$here/../.." && pwd -P)
ruby_bin=$(command -v ruby)
work=$(mktemp -d); trap 'rm -rf "$work"' EXIT
sb=$work/sb; mkdir -p "$sb/sub/deep" "$sb/inc" "$sb/lib"
: > "$sb/a.so"; : > "$sb/sub/b.o"; : > "$sb/sub/d.d"; : > "$sb/sub/deep/x"

args=(
  "-Iinc" "-I" "-Iinc/none" "-Isub" "-L" "-Llib" "-Lnone" "-Wl," "-Wl,"
  "-Wl,a.so" "-Wl,a.so," "-Wl,,a.so" "-Wl,a,,b" "-Wl,a,,b,," "-Wl,,"
  "-Wl,--version-script=a.so" "-Wl,--version-script=none.map" "-Wl,-T,a.so"
  "-Wl,-soname=libx.so" "-Wl,--soname=libx.so" "-Wl,-soname,a.so" "-Wl,-h,a.so" "-Wl,-h,a.so,a.so"
  "-Wl,--dependency-file=sub/d.d" "-Wl,--dependency-file=nodir/x.d" "-Wl,--dependency-file=" "-Wl,--dependency-file=sub"
  "-Wl,-Map=out.map" "-Wl,--Map=sub/out.map" "-Wl,-rpath,sub" "-Wl,-E"
  "a.so" "sub" "sub/deep/x" "./sub/../a.so" "nothere.c" "" "." ".." "-O2" "--foo=bar"
  "name=a.so" "name=nothere" "-DX=sub" "-Wl,x=sub/d.d"
)

pass=0; fail=0
cd "$sb"
for a in "${args[@]}"; do
  bash_out=$(bash -c 'source "$1"; ecp_arg "$2"' bash "$here/oracle.sh" "$a" 2>&1); bs=$?
  ruby_out=$("$ruby_bin" "$repo/scripts/ecp-arg.rb" "$a" 2>&1); rs=$?
  if [ "$bash_out" = "$ruby_out" ] && [ "$bs" = "$rs" ]; then
    pass=$((pass + 1))
  else
    fail=$((fail + 1)); echo "FAIL [$a]"; echo "  bash ($bs): $bash_out"; echo "  ruby ($rs): $ruby_out"
  fi
done
echo "ecp-arg: $pass passed, $fail failed"
[ $fail = 0 ]
