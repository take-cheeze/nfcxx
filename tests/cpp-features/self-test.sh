#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/../.."
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
cat > "$tmp/checklist.md" <<'EOF'
## <a id="cpp11" href="#cpp11">C++11</a>
| N2347: [forward enum](/lang/cpp11/scoped_enum.md#forward) | | 4.6 | 3.1 | partial | |
| N2347: [scoped enum](/lang/cpp11/scoped_enum.md) | | 4.4 | 2.9 | | 2012 |
## <a id="cpp17" href="#cpp17">C++17</a>
| P0136R1: [inheritance][P0136R1] | | 7 | 3.9 | No | 2017 |
[P0136R1]: https://example.test/p0136r1.html
## <a id="cpp23" href="#cpp23">C++23</a>
| P2718R0: [range for](lang/cpp23/lifetime.md) | | 15 | 20 | - | - |
EOF
scripts/mrb scripts/cpp-feature-checklist.rb "$tmp/checklist.md" > "$tmp/checklist.tsv"
[ "$(wc -l < "$tmp/checklist.tsv")" -eq 5 ]
grep -q '^cpp11-N2347-scoped_enum-forward' "$tmp/checklist.tsv"
grep -q '^cpp17-P0136R1-paper' "$tmp/checklist.tsv"
cat "$tmp/checklist.md" "$tmp/checklist.md" > "$tmp/duplicate.md"
if scripts/mrb scripts/cpp-feature-checklist.rb "$tmp/duplicate.md" > /dev/null 2>&1; then
  echo 'duplicate checklist row was accepted' >&2; exit 1
fi
printf 'bad input\n' > "$tmp/invalid.md"
if scripts/mrb scripts/cpp-feature-checklist.rb "$tmp/invalid.md" > /dev/null 2>&1; then
  echo 'empty checklist was accepted' >&2; exit 1
fi
cat > "$tmp/compiler" <<'EOF'
#!/usr/bin/env bash
set -eu
front=0; out=; src=
while [ "$#" -gt 0 ]; do
  case $1 in
    --emit-c) front=1 ;;
    -o) shift; out=$1 ;;
    *.cpp) src=$1 ;;
  esac
  shift
done
case $src in
  *N1653*) exit 2 ;;
  *N1720*) [ "$front" = 1 ] || exit 2 ;;
  *N1757*) exit 139 ;;
  *N1791*) exit 124 ;;
esac
code=0
case $src in *N1811*) code=1 ;; *N1984*) code=124 ;; *N1986*) code=139 ;; esac
printf '#!/usr/bin/env bash\nexit %s\n' "$code" > "$out"
chmod +x "$out"
EOF
chmod +x "$tmp/compiler"
FEATURE_CXX="$tmp/compiler" FEATURE_ROUTES=gcc FEATURE_OUT="$tmp/results" tests/cpp-features/run.sh > "$tmp/log" 2>&1
for status in pass frontend-rejected route-rejected compile-crash compile-timeout wrong-result run-timeout run-crash; do
  grep -q $'\t'"$status"$'\t' "$tmp/results/results.tsv" || { echo "missing $status" >&2; exit 1; }
done
if FEATURE_REQUIRE_PASS=1 FEATURE_CXX="$tmp/compiler" FEATURE_ROUTES=gcc FEATURE_OUT="$tmp/strict" tests/cpp-features/run.sh > /dev/null 2>&1; then
  echo 'strict mode accepted failures' >&2; exit 1
fi
if FEATURE_CXX="$tmp/missing" FEATURE_ROUTES=gcc FEATURE_OUT="$tmp/missing-results" tests/cpp-features/run.sh > /dev/null 2>&1; then
  echo 'missing compiler passed smoke check' >&2; exit 1
fi
printf 'probe\tstandard\troute\tstatus\tcompile_exit\trun_exit\ncpp11-N2347-scoped_enum\tc++11\tqbe\tpass\t0\t0\n' > "$tmp/report.tsv"
scripts/mrb scripts/cpp-feature-report.rb "$tmp/checklist.tsv" "$tmp/report.tsv" > "$tmp/report.md"
grep -q 'pass | not-run | not-run' "$tmp/report.md"
cat "$tmp/report.tsv" "$tmp/report.tsv" > "$tmp/bad-results.tsv"
if scripts/mrb scripts/cpp-feature-report.rb "$tmp/checklist.tsv" "$tmp/bad-results.tsv" > /dev/null 2>&1; then
  echo 'invalid results were accepted' >&2; exit 1
fi
echo 'cpp-features parser, report and runner checks passed'
