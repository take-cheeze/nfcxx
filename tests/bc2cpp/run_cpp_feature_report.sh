#!/usr/bin/env bash
# bc2cpp world: scripts/cpp-feature-report.rb, nfcxx's cpp-features report generator (checklist and probe results to the Markdown matrix), compiled by bc2cpp as a closed world (the script-world build kind,
# bc2cpp/tools/script_world/) on the mruby fork of the pinned rpg-maker-clone (tests/bc2cpp/fetch.sh). The check: the matrix for valid inputs (including a `|` in a version cell), each invalid-result error path, the usage and missing-file paths;
# The sealed executable's stdout, stderr and exit status are byte-identical to the mruby interpreter's on every case.
# Prints the best-of-N wall time of the interpreter, the compiled build and CRuby on the benchmark input, and the speedup
# of the compiled build.
#   CPP_FEATURE_REPORT_BENCH=file   the benchmark input (default tests/bc2cpp/cpp_feature/checklist.tsv tests/bc2cpp/cpp_feature/results.tsv)
#   PATHB_BENCH_REPEAT=N         runs per runtime, best kept (default 3)
#   SCRIPT_WORLD_MIN_SPEEDUP=X   also fail when the compiled build is under X times the interpreter
#   BC2CPP_RPG_DIR=dir           an existing rpg-maker-clone checkout instead of the pinned one
# Needs Ruby 4.0 with the prism and rbs gems, rake, a C/C++ compiler, bison and make. Without them it prints a skip.
cd "$(dirname "$0")/../.."
root=$PWD
. tests/bc2cpp/fetch.sh
command -v ruby >/dev/null || { echo "SKIP bc2cpp cpp-feature-report: ruby not installed"; exit 0; }
ruby -e 'exit Gem::Version.new(RUBY_VERSION) >= Gem::Version.new("4.0")' ||
  { echo "SKIP bc2cpp cpp-feature-report: needs Ruby 4.0, have $(ruby -e 'print RUBY_VERSION')"; exit 0; }
ruby -e 'require "prism"; require "rbs"' 2>/dev/null || { echo "SKIP bc2cpp cpp-feature-report: the prism and rbs gems are missing"; exit 0; }
command -v rake >/dev/null || { echo "SKIP bc2cpp cpp-feature-report: rake not installed"; exit 0; }

bc2cpp_fetch; status=$?
[ "$status" = 2 ] && exit 0 # a fetch failure is a network fault, not a result (fetch.sh printed why)
[ "$status" = 0 ] || exit 1
echo "bc2cpp: this tree, world rpg-maker-clone $(git -C "$bc2cpp_root" rev-parse --short HEAD), mruby fork $(git -C "$bc2cpp_root/3rd/mruby" rev-parse --short HEAD)"
tree=$root/bc2cpp
export BC2CPP_TREE_ROOT=$tree BC2CPP_WORLD_ROOT=$bc2cpp_root

mkdir -p build/bc2cpp
jobs=$(nproc 2>/dev/null || echo 4)
# The world's host mrbc, from the optcarrot probe's build config (as run_optcarrot.sh does).
(cd "$bc2cpp_root/3rd/mruby" && env -u LD MRUBY_CONFIG="$tree/tools/optcarrot_probe/mruby_build_config.rb" \
  rake -j"$jobs") > build/bc2cpp/mrbc.log 2>&1 ||
  { tail -20 build/bc2cpp/mrbc.log; echo "FAIL bc2cpp cpp-feature-report: building the probe mrbc failed"; exit 1; }

# The cases, one command line each. A first word `<FILE` gives the run FILE as stdin (compiled_run.rb).
cases=build/bc2cpp/cpp_feature_report.cases
{
  echo "tests/bc2cpp/cpp_feature/checklist.tsv tests/bc2cpp/cpp_feature/results.tsv"
  echo "tests/bc2cpp/cpp_feature/checklist_pipe.tsv tests/bc2cpp/cpp_feature/results_pipe.tsv"   # a `|` in a version cell becomes &#124;
  echo "tests/bc2cpp/cpp_feature/checklist.tsv tests/bc2cpp/cpp_feature/results_pipe.tsv"
  for f in short unknown_key unknown_route duplicate; do
    echo "tests/bc2cpp/cpp_feature/checklist.tsv tests/bc2cpp/cpp_feature/results_$f.tsv" # each one an error: a message on stderr, status 1
  done
  echo "tests/bc2cpp/cpp_feature/checklist.tsv"                          # the usage line, status 1
  echo "tests/bc2cpp/cpp_feature/checklist.tsv tests/bc2cpp/cpp_feature/results.tsv extra"   # the usage line
  echo "tests/bc2cpp/cpp_feature/no_such.tsv tests/bc2cpp/cpp_feature/results.tsv"            # a missing file: main reports it, status 1
  echo "tests/bc2cpp/cpp_feature/checklist.tsv tests/bc2cpp/cpp_feature/no_such.tsv"
} > "$cases"

log=build/bc2cpp/cpp_feature_report.log
bench=${CPP_FEATURE_REPORT_BENCH:-"tests/bc2cpp/cpp_feature/checklist.tsv tests/bc2cpp/cpp_feature/results.tsv"}
(env -u LD ruby "$tree/tools/script_world/compiled_run.rb" --script scripts/cpp-feature-report.rb \
  --tail 'rc = main(ARGV)\nexit(rc) if rc != 0\n' --entry 'main(ARGV)' --cases "$cases" --bench "$bench" \
  --repeat "${PATHB_BENCH_REPEAT:-3}" --bench-status 0 --chdir "$root") 2>&1 | tee "$log"
[ "${PIPESTATUS[0]}" = 0 ] || { echo "FAIL bc2cpp cpp-feature-report: the runner failed"; exit 1; }
grep -q -E '^cases: ([0-9]+)/\1 ' "$log" || { echo "FAIL bc2cpp cpp-feature-report: the cases differ"; exit 1; }

speedup=$(sed -nE 's/^bc2cpp speedup over the mruby interpreter: ([0-9.]+)x.*/\1/p' "$log" | head -1)
if [ -n "$speedup" ]; then
  echo "bc2cpp cpp-feature-report: compiled over interpreted mruby: ${speedup}x"
  [ -n "${GITHUB_STEP_SUMMARY:-}" ] && {
    echo "cpp-feature-report.rb, $bench: compiled over interpreted mruby **${speedup}x**"
    sed -nE '/^(mruby|CRuby)/p' "$log" | sed 's/^/- /'
  } >> "$GITHUB_STEP_SUMMARY"
  if [ -n "${SCRIPT_WORLD_MIN_SPEEDUP:-}" ] &&
     awk -v s="$speedup" -v m="$SCRIPT_WORLD_MIN_SPEEDUP" 'BEGIN { exit !(s < m) }'; then
    echo "FAIL bc2cpp cpp-feature-report: speedup ${speedup}x is under SCRIPT_WORLD_MIN_SPEEDUP=${SCRIPT_WORLD_MIN_SPEEDUP}"; exit 1
  fi
fi
echo "PASS bc2cpp cpp-feature-report"
