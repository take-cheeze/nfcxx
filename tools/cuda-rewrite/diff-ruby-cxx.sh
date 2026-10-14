#!/usr/bin/env bash
# Differential check: scripts/cuda-rewrite.rb (reference) against build/cuda-rewrite (the C++ port).
# Compares stdout, stderr and exit code of both, in host mode and --device mode, on the test sources and the
# ggml-cuda sources. Prints one line per file; exits 1 if any file differs (or the C++ tool is not built).
# Usage: tools/cuda-rewrite/diff-ruby-cxx.sh [-I DIR]... [FILE.cu]...   (default: the test corpus below)
set -u
root=$(cd "$(dirname "$0")/../.." && pwd)
mrb=${MRB:-$root/build/mruby-tool/bin/mruby}
cxx=${CXX_REWRITE:-$root/build/cuda-rewrite}
[ -x "$cxx" ] || { echo "diff: $cxx not built"; exit 1; }
incs=(); files=()
while [ $# -gt 0 ]; do
  case $1 in -I) incs+=("-I$2"); shift 2 ;; *) files+=("$1"); shift ;; esac
done
if [ ${#files[@]} -eq 0 ]; then
  shopt -s nullglob
  files=("$root"/tests/cuda/rewrite/*.cu "$root"/tests/cuda/launch/*.cu "$root"/tests/cuda/devunit/src/*.cu
         "$root"/tests/cuda/intrinsics/*.cu "$root"/tests/cuda/samples/*/*.cu)
fi
tmp=$(mktemp -d); trap 'rm -rf "$tmp"' EXIT
bad=0; n=0
for f in "${files[@]}"; do
  for mode in host device; do
    extra=(); [ $mode = device ] && extra=(--device)
    "$mrb" "$root/scripts/cuda-rewrite.rb" "${incs[@]}" "${extra[@]}" "$f" > "$tmp/r.out" 2> "$tmp/r.err"; re=$?
    "$cxx" "${incs[@]}" "${extra[@]}" "$f" > "$tmp/c.out" 2> "$tmp/c.err"; ce=$?
    n=$((n+1))
    if [ $re != $ce ] || ! cmp -s "$tmp/r.out" "$tmp/c.out" || ! cmp -s "$tmp/r.err" "$tmp/c.err"; then
      echo "DIFF $mode $f (exit ruby=$re cxx=$ce)"; bad=$((bad+1))
    else
      echo "same $mode $f"
    fi
  done
done
echo "compared $n runs, $bad differ"
[ $bad = 0 ]
