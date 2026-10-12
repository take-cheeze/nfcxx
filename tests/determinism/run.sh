#!/usr/bin/env bash
# Determinism: compile each file with nfcxx -c, RUNS times (default 2; default file tests/cases/qbe_gnu_forms.cpp,
# or the files given as arguments), and require every object to be byte-identical to the first.
# EDG used to name temporaries "__T<heap address>", so objects differed between runs; the EDG fix
# (nfcxx/temp-name-counter) numbers them per translation unit. Run with EDG_BUILD/EDG_BASE pointing
# at an older EDG build to see the failure.
cd "$(dirname "$0")/../.."
runs=${RUNS:-2}
files=("$@")
[ ${#files[@]} -eq 0 ] && files=(tests/cases/qbe_gnu_forms.cpp)
export NFCXX_BACKEND=${NFCXX_BACKEND:-qbe}
fail=0; tmp=$(mktemp -d); trap 'rm -rf "$tmp"' EXIT
for f in "${files[@]}"; do
  name=$(basename "$f" .cpp); same=1
  for i in $(seq 1 "$runs"); do
    if ! ./nfcxx -c "$f" -o "$tmp/$name.$i.o" 2>"$tmp/err"; then
      echo "FAIL (compile) $f"; head -5 "$tmp/err"; fail=1; same=0; break
    fi
    if [ "$i" -gt 1 ] && ! cmp -s "$tmp/$name.1.o" "$tmp/$name.$i.o"; then
      echo "FAIL $f: run $i differs from run 1 ($(cmp -l "$tmp/$name.1.o" "$tmp/$name.$i.o" | wc -l) bytes)"
      same=0; fail=1; break
    fi
  done
  [ $same -eq 1 ] && echo "ok   $f ($runs identical objects)"
done
exit $fail
