#!/usr/bin/env bash
# bc2cpp world: scripts/pathb-ssa.rb, nfcxx's Path B SSA converter (1.3K lines of mruby), compiled by bc2cpp as a closed
# world (the script-world build kind, bc2cpp/tools/script_world/) on the mruby fork of the pinned rpg-maker-clone
# (tests/bc2cpp/fetch.sh). The check: every stage 2 golden (tests/pathb-ir) and SSA case (tests/pathb-ssa/cases) with
# --check, the golden cases run with their --run arguments (tests/pathb-ssa/cases/*.args), the converted print of a
# sample, the usage and missing-file paths, and an uncaught exception. The sealed executable's stdout, stderr and exit
# status are byte-identical to the mruby interpreter's on the same script (an uncaught exception compares its report
# without the backtrace: compiled code has no line table). Prints the best-of-N wall time of the interpreter, the compiled
# build and CRuby on the benchmark IR, and the speedup of the compiled build.
#   PATHB_SSA_BENCH_IR=file      the IR to time (default tests/pathb-ir/eh_libstdcxx_throw.ir, 3.4 MB)
#   PATHB_BENCH_REPEAT=N         runs per runtime, best kept (default 3)
#   SCRIPT_WORLD_MIN_SPEEDUP=X   also fail when the compiled build is under X times the interpreter
#   BC2CPP_RPG_DIR=dir           an existing rpg-maker-clone checkout instead of the pinned one
# Needs Ruby 4.0 with the prism and rbs gems, rake, a C/C++ compiler, bison and make. Without them it prints a skip.
cd "$(dirname "$0")/../.."
root=$PWD
. tests/bc2cpp/fetch.sh
command -v ruby >/dev/null || { echo "SKIP bc2cpp pathb-ssa: ruby not installed"; exit 0; }
ruby -e 'exit Gem::Version.new(RUBY_VERSION) >= Gem::Version.new("4.0")' ||
  { echo "SKIP bc2cpp pathb-ssa: needs Ruby 4.0, have $(ruby -e 'print RUBY_VERSION')"; exit 0; }
ruby -e 'require "prism"; require "rbs"' 2>/dev/null || { echo "SKIP bc2cpp pathb-ssa: the prism and rbs gems are missing"; exit 0; }
command -v rake >/dev/null || { echo "SKIP bc2cpp pathb-ssa: rake not installed"; exit 0; }

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
  { tail -20 build/bc2cpp/mrbc.log; echo "FAIL bc2cpp pathb-ssa: building the probe mrbc failed"; exit 1; }

# The cases, one command line each. The runner gives every case an empty stdin.
cases=build/bc2cpp/pathb_ssa.cases
{
  for ir in $(find tests/pathb-ir tests/pathb-ssa/cases -maxdepth 1 -name '*.ir' | LC_ALL=C sort); do
    echo "--check $ir"
  done
  for ir in $(find tests/pathb-ssa/cases -maxdepth 1 -name '*.ir' | LC_ALL=C sort); do
    a=${ir%.ir}.args
    [ -f "$a" ] || continue
    while read -r line; do
      [ -z "$line" ] && continue
      inp=${line%%=>*}
      echo "--run $inp $ir"
    done < "$a"
  done
  for ir in $(find tests/pathb-ir -maxdepth 1 -name '*.ir' | LC_ALL=C sort | head -20); do
    echo "$ir"
  done
  echo "tests/pathb-ssa/cases/addr_taken.ir"
  echo "--bogus tests/pathb-ir/abi_struct.ir"          # an unknown flag is not a mode: the last argument is still read as the file
  echo "--check"                                       # no file: the usage line, status 1
  echo "!tests/pathb-ir/no_such_file.ir"               # an uncaught exception: the report without its backtrace
} > "$cases"

log=build/bc2cpp/pathb_ssa.log
bench=${PATHB_SSA_BENCH_SRC:-tests/gpu/sycl/vecadd.cpp}
(env -u LD ruby "$tree/tools/script_world/compiled_run.rb" --script scripts/pathb-ssa.rb \
  --tail 'if $PROGRAM_NAME == __FILE__\n  rc = main(ARGV)\n  exit(rc) if rc != 0\nend\n' --entry 'main(ARGV)' --cases "$cases" --bench "--check $bench" \
  --repeat "${PATHB_BENCH_REPEAT:-3}" --bench-status 0 --chdir "$root") 2>&1 | tee "$log"
[ "${PIPESTATUS[0]}" = 0 ] || { echo "FAIL bc2cpp pathb-ssa: the runner failed"; exit 1; }
grep -q -E '^cases: ([0-9]+)/\1 ' "$log" || { echo "FAIL bc2cpp pathb-ssa: the cases differ"; exit 1; }

speedup=$(sed -nE 's/^bc2cpp speedup over the mruby interpreter: ([0-9.]+)x.*/\1/p' "$log" | head -1)
if [ -n "$speedup" ]; then
  echo "bc2cpp pathb-ssa: compiled over interpreted mruby: ${speedup}x"
  [ -n "${GITHUB_STEP_SUMMARY:-}" ] && {
    echo "pathb-ssa.rb, $bench: compiled over interpreted mruby **${speedup}x**"
    sed -nE '/^(mruby|CRuby)/p' "$log" | sed 's/^/- /'
  } >> "$GITHUB_STEP_SUMMARY"
  if [ -n "${SCRIPT_WORLD_MIN_SPEEDUP:-}" ] &&
     awk -v s="$speedup" -v m="$SCRIPT_WORLD_MIN_SPEEDUP" 'BEGIN { exit !(s < m) }'; then
    echo "FAIL bc2cpp pathb-ssa: speedup ${speedup}x is under SCRIPT_WORLD_MIN_SPEEDUP=${SCRIPT_WORLD_MIN_SPEEDUP}"; exit 1
  fi
fi
echo "PASS bc2cpp pathb-ssa"
