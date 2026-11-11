#!/usr/bin/env bash
# bc2cpp world: scripts/mrustc-prep.rb, nfcxx's rewrite of mrustc's C for cproc (atomic statement expressions, asserts,
# attributes, weak data, init_array sections, outlined inline asm: 700 lines of text processing in mruby), compiled by
# bc2cpp as a closed world (the script-world build kind, bc2cpp/tools/script_world/) on the mruby fork of the pinned
# rpg-maker-clone (tests/bc2cpp/fetch.sh). The script writes four files, so each case sends one of them to /dev/stdout
# (the others go to /dev/null): the C, the tail assembly, the weak-symbol list and the asm helper C. The inputs are
# tests/bc2cpp/mrustc-prep: one C file with every form the rewrite handles and one error input per refusal. The sealed
# executable's stdout, stderr and exit status are byte-identical to the mruby interpreter's on the same script.
# Prints the best-of-N wall time of the interpreter, the compiled build and CRuby on the benchmark input (the
# all-forms file repeated), and the speedup of the compiled build.
#   PATHB_BENCH_REPEAT=N         runs per runtime, best kept (default 3)
#   SCRIPT_WORLD_MIN_SPEEDUP=X   also fail when the compiled build is under X times the interpreter
#   BC2CPP_RPG_DIR=dir           an existing rpg-maker-clone checkout instead of the pinned one
# Needs Ruby 4.0 with the prism and rbs gems, rake, a C/C++ compiler, bison and make. Without them it prints a skip.
cd "$(dirname "$0")/../.."
root=$PWD
. tests/bc2cpp/fetch.sh
command -v ruby >/dev/null || { echo "SKIP bc2cpp mrustc-prep: ruby not installed"; exit 0; }
ruby -e 'exit Gem::Version.new(RUBY_VERSION) >= Gem::Version.new("4.0")' ||
  { echo "SKIP bc2cpp mrustc-prep: needs Ruby 4.0, have $(ruby -e 'print RUBY_VERSION')"; exit 0; }
ruby -e 'require "prism"; require "rbs"' 2>/dev/null || { echo "SKIP bc2cpp mrustc-prep: the prism and rbs gems are missing"; exit 0; }
command -v rake >/dev/null || { echo "SKIP bc2cpp mrustc-prep: rake not installed"; exit 0; }

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
  { tail -20 build/bc2cpp/mrbc.log; echo "FAIL bc2cpp mrustc-prep: building the probe mrbc failed"; exit 1; }

# The cases, one command line each. The runner gives every case an empty stdin.
cases=build/bc2cpp/mrustc_prep.cases
fx=tests/bc2cpp/mrustc-prep
{
  for c in $(find $fx -name '*.c' | LC_ALL=C sort); do
    echo "$c /dev/stdout /dev/null /dev/null /dev/null"   # the C
    echo "$c /dev/null /dev/stdout /dev/null /dev/null"   # the tail assembly
    echo "$c /dev/null /dev/null /dev/stdout /dev/null"   # the weak list
    echo "$c /dev/null /dev/null /dev/null /dev/stdout"   # the asm helpers
  done
  echo "$fx/all.c /dev/stdout /dev/null /dev/null"        # no asm output given: refused when asm was outlined
  echo "$fx/empty.c /dev/stdout /dev/null /dev/null"      # none outlined: written without it
  echo "$fx/all.c /dev/null"                              # the usage line, status 2
  echo ""                                                 # the usage line again
  echo "!$fx/no_such_file.c /dev/null /dev/null /dev/null" # an uncaught exception: the report without its backtrace
} > "$cases"

# The benchmark input: the all-forms file repeated.
bench_in=build/bc2cpp/mrustc_prep_bench.c
: > "$bench_in"
i=0; while [ $i -lt ${PATHB_PREP_BENCH_COPIES:-400} ]; do cat $fx/all.c >> "$bench_in"; i=$((i+1)); done

log=build/bc2cpp/mrustc_prep.log
bench="$bench_in /dev/null /dev/null /dev/null /dev/null"
(env -u LD ruby "$tree/tools/script_world/compiled_run.rb" --script scripts/mrustc-prep.rb \
  --tail 'rc = main(ARGV)\nexit(rc) if rc != 0\n' --entry 'main(ARGV)' --cases "$cases" --bench "$bench" \
  --repeat "${PATHB_BENCH_REPEAT:-3}" --bench-status 0 --chdir "$root") 2>&1 | tee "$log"
[ "${PIPESTATUS[0]}" = 0 ] || { echo "FAIL bc2cpp mrustc-prep: the runner failed"; exit 1; }
grep -q -E '^cases: ([0-9]+)/\1 ' "$log" || { echo "FAIL bc2cpp mrustc-prep: the cases differ"; exit 1; }

speedup=$(sed -nE 's/^bc2cpp speedup over the mruby interpreter: ([0-9.]+)x.*/\1/p' "$log" | head -1)
if [ -n "$speedup" ]; then
  echo "bc2cpp mrustc-prep: compiled over interpreted mruby: ${speedup}x"
  [ -n "${GITHUB_STEP_SUMMARY:-}" ] && {
    echo "mrustc-prep.rb, $bench: compiled over interpreted mruby **${speedup}x**"
    sed -nE '/^(mruby|CRuby)/p' "$log" | sed 's/^/- /'
  } >> "$GITHUB_STEP_SUMMARY"
  if [ -n "${SCRIPT_WORLD_MIN_SPEEDUP:-}" ] &&
     awk -v s="$speedup" -v m="$SCRIPT_WORLD_MIN_SPEEDUP" 'BEGIN { exit !(s < m) }'; then
    echo "FAIL bc2cpp mrustc-prep: speedup ${speedup}x is under SCRIPT_WORLD_MIN_SPEEDUP=${SCRIPT_WORLD_MIN_SPEEDUP}"; exit 1
  fi
fi
echo "PASS bc2cpp mrustc-prep"
