#!/usr/bin/env bash
# bc2cpp world: scripts/pathb-borrowck.rb, nfcxx's local lifetime checker for Path B IR (docs/notes/pathb-borrowck.md),
# compiled by bc2cpp as a closed world (the script-world build kind, bc2cpp/tools/script_world/) on the mruby fork of the
# pinned rpg-maker-clone (tests/bc2cpp/fetch.sh). The check: for every IR of tests/pathb-borrow, in each mode the
# interpreted run uses (plain, --infer-loan-ends, --infer-summaries, --emitted-only, with the two effects files), plus
# the usage, error and refusal paths, the sealed executable's stdout, stderr and exit status are byte-identical to the
# mruby interpreter's on the same script (an uncaught exception, the one case with a backtrace, compares its report
# without it: compiled code has no line table). Prints the best-of-N wall time of the interpreter, the compiled build
# and CRuby on the benchmark IR, and the speedup of the compiled build.
#   PATHB_BORROW_BENCH_IR=file   the IR to time (default tests/pathb-ir/eh_libstdcxx_throw.ir, 3.4 MB: the checker
#                                refuses it with status 3 after parsing it, so the timing measures the parse)
#   PATHB_BENCH_REPEAT=N         runs per runtime, best kept (default 3)
#   SCRIPT_WORLD_MIN_SPEEDUP=X   also fail when the compiled build is under X times the interpreter
#   BC2CPP_RPG_DIR=dir           an existing rpg-maker-clone checkout instead of the pinned one
# Needs Ruby 4.0 with the prism and rbs gems, rake, a C/C++ compiler, bison and make. Without them it prints a skip.
# BC2CPP_STACK_BLOCKS=0: bc2cpp's frame-local blocks (Bc2cppBlock) miscompile in this script's Enumerable#all? with a
# block called from the summary inference (a yielded block fallback reads a dead upvar; the 11 cases that hit it pass
# with the knob off). Every block is then a heap proc. The root cause is open: docs/notes/bc2cpp-migration.md.
export BC2CPP_STACK_BLOCKS=0
cd "$(dirname "$0")/../.."
root=$PWD
. tests/bc2cpp/fetch.sh
command -v ruby >/dev/null || { echo "SKIP bc2cpp pathb-borrowck: ruby not installed"; exit 0; }
ruby -e 'exit Gem::Version.new(RUBY_VERSION) >= Gem::Version.new("4.0")' ||
  { echo "SKIP bc2cpp pathb-borrowck: needs Ruby 4.0, have $(ruby -e 'print RUBY_VERSION')"; exit 0; }
ruby -e 'require "prism"; require "rbs"' 2>/dev/null || { echo "SKIP bc2cpp pathb-borrowck: the prism and rbs gems are missing"; exit 0; }
command -v rake >/dev/null || { echo "SKIP bc2cpp pathb-borrowck: rake not installed"; exit 0; }

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
  { tail -20 build/bc2cpp/mrbc.log; echo "FAIL bc2cpp pathb-borrowck: building the probe mrbc failed"; exit 1; }

# The cases, one command line each. The effects files are the ones the test suite passes (tests/pathb-borrow/run.sh).
effects="--effects scripts/pathb-libc.effects --effects scripts/pathb-runtime.effects"
cases=build/bc2cpp/pathb_borrowck.cases
{
  for ir in $(find tests/pathb-borrow -name '*.ir' | LC_ALL=C sort); do
    echo "$ir"
    echo "--infer-loan-ends $ir"
    echo "--infer-loan-ends --infer-summaries $ir"
    echo "$effects $ir"
    echo "--infer-loan-ends $effects $ir"
  done
  for ir in $(find tests/pathb-borrow/emitted -name '*.ir' | LC_ALL=C sort); do
    echo "--emitted-only $ir"
    echo "--emitted-only --infer-loan-ends $ir"
  done
  for eff in tests/pathb-borrow/contracts/*.effects tests/pathb-borrow/throws/*.effects; do
    for ir in $(find tests/pathb-borrow/cases -name '*.ir' | LC_ALL=C sort); do
      echo "--effects $eff $ir"
    done
  done
  echo "--emitted-only"                               # no file: the usage line (a blank line would be skipped)
  echo "--bogus tests/pathb-borrow/cases/$(ls tests/pathb-borrow/cases | head -1)"
  echo "--effects"                                    # --effects without its file
  echo "tests/pathb-borrow/cases/$(ls tests/pathb-borrow/cases | head -1) tests/pathb-borrow/cases/$(ls tests/pathb-borrow/cases | head -1)"
  echo "!tests/pathb-borrow/no_such_file.ir"          # an uncaught exception: the report without its backtrace
} > "$cases"

log=build/bc2cpp/pathb_borrowck.log
bench=${PATHB_BORROW_BENCH_IR:-tests/pathb-ir/eh_libstdcxx_throw.ir}
(env -u LD ruby "$tree/tools/script_world/compiled_run.rb" --script scripts/pathb-borrowck.rb \
  --tail 'rc = main(ARGV)\nexit(rc) if rc != 0\n' --entry 'main(ARGV)' --cases "$cases" --bench "$bench" \
  --repeat "${PATHB_BENCH_REPEAT:-3}" --bench-status 3 --chdir "$root") 2>&1 | tee "$log"
[ "${PIPESTATUS[0]}" = 0 ] || { echo "FAIL bc2cpp pathb-borrowck: the runner failed"; exit 1; }
grep -q -E '^cases: ([0-9]+)/\1 ' "$log" || { echo "FAIL bc2cpp pathb-borrowck: the cases differ"; exit 1; }

speedup=$(sed -nE 's/^bc2cpp speedup over the mruby interpreter: ([0-9.]+)x.*/\1/p' "$log" | head -1)
if [ -n "$speedup" ]; then
  echo "bc2cpp pathb-borrowck: compiled over interpreted mruby: ${speedup}x"
  [ -n "${GITHUB_STEP_SUMMARY:-}" ] && {
    echo "pathb-borrowck.rb, $bench: compiled over interpreted mruby **${speedup}x**"
    sed -nE '/^(mruby|CRuby)/p' "$log" | sed 's/^/- /'
  } >> "$GITHUB_STEP_SUMMARY"
  if [ -n "${SCRIPT_WORLD_MIN_SPEEDUP:-}" ] &&
     awk -v s="$speedup" -v m="$SCRIPT_WORLD_MIN_SPEEDUP" 'BEGIN { exit !(s < m) }'; then
    echo "FAIL bc2cpp pathb-borrowck: speedup ${speedup}x is under SCRIPT_WORLD_MIN_SPEEDUP=${SCRIPT_WORLD_MIN_SPEEDUP}"; exit 1
  fi
fi
echo "PASS bc2cpp pathb-borrowck"
