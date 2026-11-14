#!/usr/bin/env bash
# Backend measurement (docs/notes/pathb-backend-measurement.md): three kernels built by the Path B default, by
# --backend=gcc and by clang -O2 -fwrapv. Prints the minimum of five runs (TIME on stderr) and the checksum, which
# must match across the three. Needs ./nfcxx built (scripts/setup-edg.sh, setup-qbe.sh, setup-pathb.sh).
set -u
here=$(cd "$(dirname "$0")" && pwd); root=$(cd "$here/../../.." && pwd)
out=${BENCH_OUT:-$root/build/bench-backend}; mkdir -p "$out"
for k in k_float k_int k_branchy; do
  "$root/nfcxx" "$here/$k.cpp" -o "$out/${k}_pathb" 2>"$out/${k}_pathb.log" || { echo "build $k pathb failed"; exit 1; }
  "$root/nfcxx" --backend=gcc "$here/$k.cpp" -o "$out/${k}_gcc" 2>"$out/${k}_gcc.log" || { echo "build $k gcc failed"; exit 1; }
  clang++ -std=c++17 -O2 -fwrapv "$here/$k.cpp" -o "$out/${k}_clang" || { echo "build $k clang failed"; exit 1; }
  for v in pathb gcc clang; do
    best=999; sum=""
    for i in 1 2 3 4 5; do
      sum=$("$out/${k}_$v" 2>"$out/tm.txt"); t=$(awk '/TIME/{print $2}' "$out/tm.txt")
      best=$(awk -v a="$best" -v b="$t" 'BEGIN{print (b<a)?b:a}')
    done
    echo "$k $v min_s=$best checksum: $sum"
  done
done
