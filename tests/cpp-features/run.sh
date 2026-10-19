#!/usr/bin/env bash
# Observational coverage report: feature gaps are data, infrastructure errors fail.
set -euo pipefail
cd "$(dirname "$0")/../.."
out=${FEATURE_OUT:-build/cpp-features/results}
routes=${FEATURE_ROUTES:-'qbe gcc pathb'}
driver=${FEATURE_CXX:-$PWD/nfcxx}
limit=${FEATURE_TIMEOUT:-60}
mkdir -p "$out"
out=$(cd "$out" && pwd)
mkdir "$out/.lock" 2>/dev/null || { echo "report directory is already in use: $out" >&2; exit 1; }
trap 'rm -rf "$out/.lock"' EXIT
command -v timeout >/dev/null || { echo 'cpp-features: GNU timeout is required' >&2; exit 1; }
for route in $routes; do
  case $route in qbe|gcc|pathb|host) ;; *) echo "unknown route: $route" >&2; exit 1 ;; esac
done
# A missing/broken toolchain must not turn every feature into a reported gap.
printf 'int main() { return 0; }\n' > "$out/.lock/smoke.cpp"
for route in $routes; do
  flags=(); compiler="$driver"
  if [ "$route" = host ]; then compiler=${HOST_CXX:-g++}; else flags=("--backend=$route"); fi
  env NFCXX_PATH=a NFCXX_BACKEND=qbe timeout -k 5 "$limit" "$compiler" "${flags[@]}" \
    -std=c++11 -pthread "$out/.lock/smoke.cpp" -o "$out/.lock/program" > "$out/$route-smoke.log" 2>&1 && \
    timeout -k 5 "$limit" "$out/.lock/program" >> "$out/$route-smoke.log" 2>&1 || {
      echo "toolchain smoke check failed for $route: see $out/$route-smoke.log" >&2; exit 1;
    }
done
printf 'probe\tstandard\troute\tstatus\tcompile_exit\trun_exit\n' > "$out/results.tsv"
failed=0
for source in tests/cpp-features/cpp*/*.cpp; do
  probe=$(basename "$source" .cpp)
  std=$(sed -n 's,^// STD: ,,p' "$source")
  want=$(sed -n 's,^// EXPECT: ,,p' "$source")
  [[ $std =~ ^c\+\+(11|14|17|20|23|26|29)$ && $want =~ ^[0-9]+$ && $want -le 255 ]] || {
    echo "invalid metadata: $source" >&2; exit 1;
  }
  for route in $routes; do
    dir="$out/$probe/$route"; mkdir -p "$dir"
    rm -f "$dir/program"
    flags=(); compiler="$driver"
    if [ "$route" = host ]; then compiler=${HOST_CXX:-g++}; else flags=("--backend=$route"); fi
    # Clear inherited route selection, including for the front-end-only check.
    compile=0
    env NFCXX_PATH=a NFCXX_BACKEND=qbe timeout -k 5 "$limit" "$compiler" "${flags[@]}" \
      "-std=$std" -pthread "$source" -o "$dir/program" > "$dir/compile.log" 2>&1 || compile=$?
    run=-; status=pass
    case $compile in
      0)
        run=0
        timeout -k 5 "$limit" "$dir/program" > "$dir/run.log" 2>&1 || run=$?
        if [ "$run" = 124 ] || [ "$run" = 137 ]; then status=run-timeout
        elif [ "$run" -gt 128 ]; then status=run-crash
        elif [ "$run" != "$want" ]; then status=wrong-result; fi ;;
      124|137) status=compile-timeout ;;
      125|126|127) echo "cannot invoke compiler for $route: see $dir/compile.log" >&2; exit 1 ;;
      *)
        if [ "$compile" -gt 128 ]; then status=compile-crash
        elif [ "$route" = host ]; then status=host-rejected
        else
          front=0
          env NFCXX_PATH=a NFCXX_BACKEND=gcc timeout -k 5 "$limit" "$driver" --backend=gcc --emit-c \
            "-std=$std" -pthread "$source" -o "$dir/frontend.c" > "$dir/frontend.log" 2>&1 || front=$?
          case $front in
            0) status=route-rejected ;;
            124|137) status=frontend-timeout ;;
            125|126|127) echo "cannot invoke front end: see $dir/frontend.log" >&2; exit 1 ;;
            *) if [ "$front" -gt 128 ]; then status=frontend-crash; else status=frontend-rejected; fi ;;
          esac
        fi ;;
    esac
    printf '%s\t%s\t%s\t%s\t%s\t%s\n' "$probe" "$std" "$route" "$status" "$compile" "$run" >> "$out/results.tsv"
    [ "$status" = pass ] || failed=1
    echo "$probe $route: $status" >&2
  done
done
echo "Results and diagnostics: $out" >&2
if [ "${FEATURE_REQUIRE_PASS:-0}" = 1 ]; then exit "$failed"; fi
