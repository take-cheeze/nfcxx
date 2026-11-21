#!/bin/bash
# Golden test of the SYCL dispatch (scripts/nfcxx.rb, which runs the SYCL check and run before the body): ./nfcxx on each argument
# list of cases.txt, in a sandbox holding a fake SYCL header tree (inc/sycl/sycl.hpp, inc/sycl/detail/kernel_desc.hpp). The stdout,
# stderr and status of each case are compared with golden/CASE.{out,err,status}; the sandbox and temporary paths are normalized.
#   bash tests/driver-sycl-dispatch/run.sh            compare
#   bash tests/driver-sycl-dispatch/run.sh --record   write the golden files (taken on the base before a change)
# The goldens cover the dispatch's decisions and the failing two-pass path (this checkout has no EDG build, so a pass records no
# kernels); the passing build is checked by tests/nfcxx-sycl/run.sh.
set -u
here=$(cd "$(dirname "$0")" && pwd -P)
repo=$(cd "$here/../.." && pwd -P)
mode=${1:-compare}
pass=0; fail=0; failed=""
gold=$here/golden
[ "$mode" = --record ] && mkdir -p "$gold"
# the build tool the driver makes on first use is made before the cases (its first build prints to stderr)
ruby "$repo/scripts/nfcxx-ensure-tool.rb" "$repo/tools/cuda-rewrite" "$repo/build/cuda-rewrite" >/dev/null 2>&1 || true

run_case() {  # run_case NAME ARGS...: the normalized outcome of one case, in its own sandbox
  local name=$1; shift
  local sb; sb=$(realpath -m "$(mktemp -d)")
  mkdir -p "$sb/work/inc/sycl/detail" "$sb/work/other" "$sb/work/out" "$sb/tmp"
  local w=$sb/work
  : > "$w/inc/sycl/sycl.hpp"; : > "$w/inc/sycl/detail/kernel_desc.hpp"
  printf 'int k;\n' > "$w/sy.cc"; cp "$w/sy.cc" "$w/sy.cxx"; cp "$w/sy.cc" "$w/sy.c"; cp "$w/sy.cc" "$w/sy.cu"
  printf '#include <sycl/sycl.hpp>\nint k;\n' > "$w/sy.cc"
  printf '#include <sycl/sycl.hpp>\nint k;\n' > "$w/sy.cxx"
  printf '#include <sycl/sycl.hpp>\nmain: () -> int = { return 0; }\n' > "$w/sy.cpp2"
  printf '#include <sycl/sycl.hpp>\nint k;\n' > "$w/sy.c"
  printf '#include <sycl/sycl.hpp>\nint k;\n' > "$w/sy.cu"
  printf 'int k;\n' > "$w/plain.cc"; printf 'int k;\n' > "$w/pre.h"
  (cd "$w" && env -i PATH="/usr/local/bin:/usr/bin:/bin" HOME="$sb" TMPDIR="$sb/tmp" "$repo/nfcxx" "$@" \
     >"$sb/out" 2>"$sb/err"; echo $? > "$sb/status")
  local norm=(-e "s#$sb/tmp/[^ \"/]*#<tmp>#g" -e "s#$repo#<repo>#g" -e "s#$sb#<sb>#g")
  sed "${norm[@]}" "$sb/out" > "$sb/out.n"; sed "${norm[@]}" "$sb/err" > "$sb/err.n"
  if [ "$mode" = --record ]; then
    cp "$sb/out.n" "$gold/$name.out"; cp "$sb/err.n" "$gold/$name.err"; cp "$sb/status" "$gold/$name.status"
  else
    if cmp -s "$sb/out.n" "$gold/$name.out" && cmp -s "$sb/err.n" "$gold/$name.err" && cmp -s "$sb/status" "$gold/$name.status"; then
      pass=$((pass + 1))
    else
      fail=$((fail + 1)); failed+=" $name"
    fi
  fi
  rm -rf "$sb"
}

while IFS= read -r line; do
  case $line in ""|"#"*) continue ;; esac
  read -r -a fields <<< "$line"
  name=${fields[0]}; args=("${fields[@]:1}")
  run_case "$name" "${args[@]}"
done < "$here/cases.txt"

if [ "$mode" = --record ]; then echo "driver-sycl-dispatch: recorded goldens in $gold"; exit 0; fi
echo "driver-sycl-dispatch: $pass passed, $fail failed${failed:+ ($failed )}"
[ "$fail" = 0 ]
