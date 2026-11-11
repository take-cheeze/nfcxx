#!/usr/bin/env bash
# bc2cpp world: scripts/strip-atomic.rb, nfcxx's _Atomic stripper for cproc (preprocessed C on stdin, C on stdout), compiled by bc2cpp as a closed world (the script-world build kind,
# bc2cpp/tools/script_world/) on the mruby fork of the pinned rpg-maker-clone (tests/bc2cpp/fetch.sh). The check: fixtures with nested parentheses, bare keywords, identifier look-alikes, unbalanced input, CRLF and UTF-8, each given on stdin;
# The sealed executable's stdout, stderr and exit status are byte-identical to the mruby interpreter's on every case.
# Prints the best-of-N wall time of the interpreter, the compiled build and CRuby on the benchmark input, and the speedup
# of the compiled build.
#   STRIP_ATOMIC_BENCH=file   the benchmark input (default build/bc2cpp/strip_atomic/bench.c (the fixtures repeated))
#   PATHB_BENCH_REPEAT=N         runs per runtime, best kept (default 3)
#   SCRIPT_WORLD_MIN_SPEEDUP=X   also fail when the compiled build is under X times the interpreter
#   BC2CPP_RPG_DIR=dir           an existing rpg-maker-clone checkout instead of the pinned one
# Needs Ruby 4.0 with the prism and rbs gems, rake, a C/C++ compiler, bison and make. Without them it prints a skip.
cd "$(dirname "$0")/../.."
root=$PWD
. tests/bc2cpp/fetch.sh
command -v ruby >/dev/null || { echo "SKIP bc2cpp strip-atomic: ruby not installed"; exit 0; }
ruby -e 'exit Gem::Version.new(RUBY_VERSION) >= Gem::Version.new("4.0")' ||
  { echo "SKIP bc2cpp strip-atomic: needs Ruby 4.0, have $(ruby -e 'print RUBY_VERSION')"; exit 0; }
ruby -e 'require "prism"; require "rbs"' 2>/dev/null || { echo "SKIP bc2cpp strip-atomic: the prism and rbs gems are missing"; exit 0; }
command -v rake >/dev/null || { echo "SKIP bc2cpp strip-atomic: rake not installed"; exit 0; }

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
  { tail -20 build/bc2cpp/mrbc.log; echo "FAIL bc2cpp strip-atomic: building the probe mrbc failed"; exit 1; }

# The cases, one command line each. A first word `<FILE` gives the run FILE as stdin (compiled_run.rb).
cases=build/bc2cpp/strip_atomic.cases
mkdir -p build/bc2cpp/strip_atomic
bench_in=build/bc2cpp/strip_atomic/bench.c
if [ ! -s "$bench_in" ]; then
  for i in $(seq 1 3000); do cat tests/bc2cpp/strip_atomic/basic.c tests/bc2cpp/strip_atomic/nested.c tests/bc2cpp/strip_atomic/lookalikes.c tests/bc2cpp/strip_atomic/crlf.c; done > "$bench_in"
fi
{
  for f in $(find tests/bc2cpp/strip_atomic -maxdepth 1 -name '*.c' | LC_ALL=C sort); do
    echo "<$f" # the fixture on stdin; the script reads stdin and writes stdout as bytes
  done
  echo ""                                           # (skipped: a blank line)
  echo "<tests/bc2cpp/strip_atomic/basic.c extra args"                  # arguments are ignored
} > "$cases"

log=build/bc2cpp/strip_atomic.log
bench=${STRIP_ATOMIC_BENCH:-<build/bc2cpp/strip_atomic/bench.c}
(env -u LD ruby "$tree/tools/script_world/compiled_run.rb" --script scripts/strip-atomic.rb \
  --tail 'rc = main(ARGV)\nexit(rc) if rc != 0\n' --entry 'main(ARGV)' --cases "$cases" --bench "$bench" \
  --repeat "${PATHB_BENCH_REPEAT:-3}" --bench-status 0 --chdir "$root") 2>&1 | tee "$log"
[ "${PIPESTATUS[0]}" = 0 ] || { echo "FAIL bc2cpp strip-atomic: the runner failed"; exit 1; }
grep -q -E '^cases: ([0-9]+)/\1 ' "$log" || { echo "FAIL bc2cpp strip-atomic: the cases differ"; exit 1; }

speedup=$(sed -nE 's/^bc2cpp speedup over the mruby interpreter: ([0-9.]+)x.*/\1/p' "$log" | head -1)
if [ -n "$speedup" ]; then
  echo "bc2cpp strip-atomic: compiled over interpreted mruby: ${speedup}x"
  [ -n "${GITHUB_STEP_SUMMARY:-}" ] && {
    echo "strip-atomic.rb, $bench: compiled over interpreted mruby **${speedup}x**"
    sed -nE '/^(mruby|CRuby)/p' "$log" | sed 's/^/- /'
  } >> "$GITHUB_STEP_SUMMARY"
  if [ -n "${SCRIPT_WORLD_MIN_SPEEDUP:-}" ] &&
     awk -v s="$speedup" -v m="$SCRIPT_WORLD_MIN_SPEEDUP" 'BEGIN { exit !(s < m) }'; then
    echo "FAIL bc2cpp strip-atomic: speedup ${speedup}x is under SCRIPT_WORLD_MIN_SPEEDUP=${SCRIPT_WORLD_MIN_SPEEDUP}"; exit 1
  fi
fi
echo "PASS bc2cpp strip-atomic"
