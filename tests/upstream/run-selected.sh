#!/usr/bin/env bash
# Reviewed cross-suite programs. This is not a general dg/lit directive adapter.
set -euo pipefail
cd "$(dirname "$0")/../.."
root=$PWD; snapshot=$root/build/testsuite-snapshots
out=${UPSTREAM_OUT:-$snapshot/selected-results}
routes=${UPSTREAM_ROUTES:-'qbe gcc pathb'}
manifest=${UPSTREAM_MANIFEST:-tests/upstream/reviewed.tsv}
host=${HOST_CXX:-g++}; limit=${UPSTREAM_TIMEOUT:-60}
mkdir -p "$out"; out=$(cd "$out" && pwd)
mkdir "$out/.lock" 2>/dev/null || { echo "results already in use: $out" >&2; exit 1; }
trap 'rm -rf "$out/.lock"' EXIT
for route in $routes; do case $route in qbe|gcc|pathb) ;; *) exit 1 ;; esac; done
printf 'int main() { return 0; }\n' > "$out/.lock/smoke.cpp"
for route in host $routes; do
  compiler=$root/nfcxx; flags=("--backend=$route")
  if [ "$route" = host ]; then compiler=$host; flags=(); fi
  env NFCXX_PATH=a NFCXX_BACKEND=qbe timeout -k 5 "$limit" "$compiler" "${flags[@]}" \
    -std=c++11 "$out/.lock/smoke.cpp" -o "$out/.lock/smoke" > "$out/$route-smoke.log" 2>&1
  timeout -k 5 "$limit" "$out/.lock/smoke" >> "$out/$route-smoke.log" 2>&1
done
printf 'suite\tid\tstandard\troute\tstatus\tcompile_exit\trun_exit\n' > "$out/results.tsv"
cp "$manifest" "$out/reviewed.tsv"
cp tests/upstream/git-snapshots.tsv "$out/"
"$host" --version > "$out/host.txt"
git rev-parse HEAD > "$out/nfcxx.commit"
fail=0
while IFS=$'\t' read -r suite id std relative oracle review; do
  [ "$suite" = suite ] && continue
  case $oracle in exit|stdout) ;; *) echo "unknown oracle: $oracle" >&2; exit 1 ;; esac
  source=$snapshot/$relative
  test -f "$source"
  includes=()
  case $suite in
    libcxx) includes=(-I "$snapshot/clang/libcxx/test/support") ;;
    libstdcxx) includes=(-I "$snapshot/gcc/libstdc++-v3/testsuite/util") ;;
  esac
  dir=$out/$suite-$id; mkdir -p "$dir"
  timeout -k 5 "$limit" "$host" "${includes[@]}" "-std=$std" "$source" -o "$dir/host" > "$dir/host-compile.log" 2>&1
  timeout -k 5 "$limit" "$dir/host" > "$dir/host.out" 2> "$dir/host.err"
  for route in $routes; do
    compile=0; run=-; status=pass
    env NFCXX_PATH=a NFCXX_BACKEND=qbe timeout -k 5 "$limit" "$root/nfcxx" "--backend=$route" \
      "${includes[@]}" "-std=$std" "$source" -o "$dir/$route" > "$dir/$route-compile.log" 2>&1 || compile=$?
    case $compile in
      0)
        run=0
        timeout -k 5 "$limit" "$dir/$route" > "$dir/$route.out" 2> "$dir/$route.err" || run=$?
        if [ "$run" = 124 ] || [ "$run" = 137 ]; then status=run-timeout
        elif [ "$run" -gt 128 ]; then status=run-crash
        elif [ "$run" != 0 ]; then status=wrong-exit
        elif [ "$oracle" = stdout ] && ! cmp -s "$dir/host.out" "$dir/$route.out"; then status=output-mismatch; fi ;;
      124|137) status=compile-timeout ;;
      125|126|127) echo "cannot invoke route $route" >&2; exit 1 ;;
      *) # eccp reports a failed C compile as 129 and prints the C compiler's status first: only a status above 128 is a crash.
        backend=$(sed -n 's,.*returned an exit status of \([0-9][0-9]*\)$,\1,p' "$dir/$route-compile.log" | tail -1)
        if [ "$compile" -gt 128 ] && { [ "$compile" -ne 129 ] || [ "${backend:-0}" -gt 128 ]; }; then status=compile-crash
        else status=compile-rejected; fi ;;
    esac
    printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\n' "$suite" "$id" "$std" "$route" "$status" "$compile" "$run" >> "$out/results.tsv"
    [ "$status" = pass ] || fail=1
    echo "$suite $id $route: $status"
  done
done < "$manifest"
if [ "${UPSTREAM_REQUIRE_PASS:-0}" = 1 ]; then exit "$fail"; fi
