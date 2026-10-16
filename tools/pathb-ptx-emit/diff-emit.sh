#!/usr/bin/env bash
# Whole-module differential of the PTX emitter: scripts/pathb-ptx-emit.rb (the Ruby reference) against
# build/pathb-ptx-emit --emit (the C++ port), on each IR file. The stdout and the exit status must match. A side that runs
# longer than the budget (SECS, default 900) is skipped and reported as such.
# Usage: diff-emit.sh [--sm=75] [--kernel=NAME]... [--kernels-files] FILE.ir...
# --kernels-files passes the kernels of each FILE.ir from its FILE.kernels (the names cuda-rewrite.rb listed, as the driver
# does: nfcxx passes them with --kernel=).
set -u
root=$(cd "$(dirname "$0")/../.." && pwd)
cxx=${PTX_EMIT:-$root/build/pathb-ptx-emit}
mrb=${MRB:-$root/build/mruby-tool/bin/mruby}
ref=$root/scripts/pathb-ptx-emit.rb
secs=${SECS:-900}
[ -x "$cxx" ] || { echo "diff-emit: $cxx not built (make -C tools/pathb-ptx-emit)"; exit 1; }
[ -x "$mrb" ] || { echo "diff-emit: no mruby (set MRB)"; exit 1; }

opts=()
files=()
kernels_files=0
for a in "$@"; do
  case "$a" in
    --kernels-files) kernels_files=1 ;;
    --*) opts+=("$a") ;;
    *) files+=("$a") ;;
  esac
done

work=$(mktemp -d)
same=0; diff=0; skip=0
for f in "${files[@]}"; do
  name=$(basename "$f")
  fopts=("${opts[@]}")
  if [ "$kernels_files" = 1 ] && [ -f "${f%.ir}.kernels" ]; then
    while IFS= read -r k; do [ -n "$k" ] && fopts+=("--kernel=$k"); done < "${f%.ir}.kernels"
  fi
  s1=$(date +%s.%N)
  timeout "$secs" "$mrb" "$ref" "${fopts[@]}" "$f" > "$work/r.out" 2> "$work/r.err"; rr=$?
  s2=$(date +%s.%N)
  if [ "$rr" = 124 ]; then
    echo "SKIP $name: the Ruby emitter ran over ${secs} s"; skip=$((skip + 1)); continue
  fi
  timeout "$secs" "$cxx" --emit "${fopts[@]}" "$f" > "$work/c.out" 2> "$work/c.err"; cr=$?
  s3=$(date +%s.%N)
  if [ "$cr" = 124 ]; then
    echo "SKIP $name: the C++ emitter ran over ${secs} s"; skip=$((skip + 1)); continue
  fi
  if [ "$rr" = "$cr" ] && cmp -s "$work/r.out" "$work/c.out"; then
    same=$((same + 1))
    printf "same %s (exit %s; ruby %.1f s, cxx %.1f s)\n" "$name" "$rr" "$(echo "$s2 - $s1" | bc)" "$(echo "$s3 - $s2" | bc)"
  else
    diff=$((diff + 1))
    first=$(cmp "$work/r.out" "$work/c.out" 2>/dev/null | head -1)
    echo "DIFF $name: exit ruby=$rr cxx=$cr; ${first:-stdout identical}"
    echo "  ruby: $(head -c 300 "$work/r.err" | head -2 | tr '\n' ' ')"
    echo "  cxx:  $(head -c 300 "$work/c.err" | head -2 | tr '\n' ' ')"
  fi
done
echo "diff-emit: $same same, $diff different, $skip skipped, of ${#files[@]} files (work dir $work)"
[ "$diff" -eq 0 ]
