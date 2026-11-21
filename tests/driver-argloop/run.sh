#!/bin/bash
# The argument loop's state handoff (docs/notes/driver-body-port.md, item 1): for each argument list of cases.txt, the driver's
# stdout, stderr and status must be the golden (golden/NN.txt, the list's line number order). The lists cover a refused
# argument, a value option given last (set -u), an unknown -fuse-ld, plain compiles, -c with -o, -E, --emit-hip, --cache=,
# a .cu input and a .cpp2 input. The directory, the tool root, the bash's error location and the per-run names are normalized,
# and ninja's progress lines are dropped. The tools (build/) are built on the first run: record after a run that built them.
#   bash tests/driver-argloop/run.sh            compare
#   bash tests/driver-argloop/run.sh --record   write the golden (only on the tree whose behaviour is the reference)
here=$(cd "$(dirname "$0")" && pwd -P); repo=$(cd "$here/../.." && pwd -P)
mode=check; [ "${1:-}" = --record ] && mode=record
pass=0; fail=0; n=0
norm() {  # the tool root, the scratch directory, the oracle's temporary program and its line, and the names that vary per run:
  # the stamp of an emitted file, the cpp2 cache key (a hash of the file), and the driver's temporary names
  sed -e "s|$repo|ROOT|g" -e "s|$1|TMP|g" \
      -e 's|[^ ]*/nfcxx-oracle[^ ]*\.sh: line [0-9]*:|ORACLE: line N:|g' \
      -e 's|[A-Z][a-z][a-z] [A-Z][a-z][a-z] [ 0-9][0-9] [0-9:]\{8\} 20[0-9][0-9]|DATE|g' \
      -e 's|cpp2/[0-9a-f]\{16\}/|cpp2/KEY/|g' \
      -e 's|nfcxx-tmp\.[A-Za-z0-9]*|nfcxx-tmp.X|g' -e 's|nfcxx-plan[A-Za-z0-9.]*|nfcxx-plan.X|g' \
      -e '/^ninja: Entering directory/d' -e '/^\[[0-9]*\/[0-9]*\] /d'
}
while IFS= read -r line; do
  case $line in ''|'#'*) continue ;; esac
  n=$((n + 1)); g=$here/golden/$(printf '%02d' "$n").txt
  work=$(mktemp -d "${TMPDIR:-/tmp}/argloop.XXXXXX")
  ( cd "$work" && mkdir tt && printf 'int main() { return 0; }\n' > m.cpp && printf '__global__ void k() {}\n' > k.cu \
      && printf 'int main() { return 0; }\n' > p.cpp2 )
  read -r -a words <<< "$line"
  args=(); for w in "${words[@]}"; do w=${w//CACHE/$work/cache}; w=${w//LOG/$work/cache.log}; args+=("$w"); done
  got=$( cd "$work" && TMPDIR="$work/tt" "$repo/nfcxx" "${args[@]}" 2> "$work/err" > "$work/out"; echo "status=$?" > "$work/rc"
         echo "== $line"; echo "-- stdout"; cat "$work/out"; echo "-- stderr"; cat "$work/err"; cat "$work/rc" )
  got=$(printf '%s\n' "$got" | norm "$work")
  if [ $mode = record ]; then printf '%s\n' "$got" > "$g"
  elif [ "$got" = "$(cat "$g" 2>/dev/null)" ]; then pass=$((pass + 1))
  else fail=$((fail + 1)); echo "FAIL $n: $line"; diff <(printf '%s\n' "$got") "$g" | head -20; fi
  rm -rf "$work"
done < "$here/cases.txt"
if [ $mode = record ]; then echo "recorded $n golden files"; exit 0; fi
echo "driver-argloop: $pass passed, $fail failed"
[ "$fail" = 0 ]
