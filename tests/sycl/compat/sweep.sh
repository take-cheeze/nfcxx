#!/usr/bin/env bash
# Compatibility sweep: how much real SYCL code the lib/sycl headers parse. Compiles every .cpp under a directory that
# includes a SYCL header with `g++ -fsyntax-only` (host path, no kernels run) and groups the first error of each file.
#   tests/sycl/compat/sweep.sh DIR [OUTDIR]
# DIR is untrusted source (for example a clone of oneapi-src/oneapi-samples): files are only parsed, never run.
# Writes OUTDIR/results.tsv (file, status, first error) and prints the summary.
set -uo pipefail
dir=$(cd "$1" && pwd)
root=$(cd "$(dirname "$0")/../../.." && pwd)
out=${2:-$(mktemp -d)}
mkdir -p "$out"
export root out dir
one() {
  f=$1
  d=$(dirname "$f")
  rel=${f#"$dir"/}
  if timeout 60 g++ -std=c++17 -fsyntax-only -w -fmax-errors=1 -I"$root/lib/sycl/include" -I"$d" -I"$d/../include" -I"$d/.." -I"$d/../.." \
       -I"$d/../../common" -I"$d/../../../common" "$f" > "$out/$(echo "$rel" | tr / _).log" 2>&1; then
    printf '%s\tok\t\n' "$rel"
  else
    err=$(grep -m1 -E 'error|fatal' "$out/$(echo "$rel" | tr / _).log" | sed 's/^[^ ]* //' | cut -c1-150)
    printf '%s\tfail\t%s\n' "$rel" "$err"
  fi
}
export -f one
find "$dir" -name '*.cpp' -not -path '*/.git/*' -print0 | xargs -0 grep -lZE '#include *[<"](sycl/sycl.hpp|CL/sycl.hpp)[>"]' 2>/dev/null \
  | xargs -0 -n1 -P"$(nproc)" bash -c 'one "$0"' | sort > "$out/results.tsv"
total=$(wc -l < "$out/results.tsv")
ok=$(grep -c $'\tok\t' "$out/results.tsv")
echo "files including sycl: $total, parse with lib/sycl: $ok"
echo "most common first errors:"
grep $'\tfail\t' "$out/results.tsv" | cut -f3 | sed -E "s/'[^']*'/'X'/g; s/\"[^\"]*\"/\"X\"/g" | sort | uniq -c | sort -rn | head -25
