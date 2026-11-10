#!/usr/bin/env bash
# bc2cpp world: scripts/sycl-rewrite.rb, nfcxx's SYCL device-side rewrite (the first slice of the SYCL front end), compiled
# by bc2cpp as a closed world (the script-world build kind, bc2cpp/tools/script_world/) on the mruby fork of the pinned
# rpg-maker-clone (tests/bc2cpp/fetch.sh). The check: the accepted and refused SYCL sources of tests/gpu/sycl, the usage
# and missing-file paths, the sealed executable's stdout, stderr and exit status are byte-identical to the mruby
# interpreter's on the same script. Prints the best-of-N wall time of the interpreter, the compiled build and
# CRuby on the benchmark source, and the speedup of the compiled build.
#   SYCL_REWRITE_BENCH_SRC=file  the source to time (default tests/gpu/sycl/vecadd.cpp, 1 KB: the timing is dominated by
#                                process startup, so this checks the sealed build runs, not how fast it is)
#   PATHB_BENCH_REPEAT=N         runs per runtime, best kept (default 3)
#   SCRIPT_WORLD_MIN_SPEEDUP=X   also fail when the compiled build is under X times the interpreter
#   BC2CPP_RPG_DIR=dir           an existing rpg-maker-clone checkout instead of the pinned one
# Needs Ruby 4.0 with the prism and rbs gems, rake, a C/C++ compiler, bison and make. Without them it prints a skip.
cd "$(dirname "$0")/../.."
root=$PWD
. tests/bc2cpp/fetch.sh
command -v ruby >/dev/null || { echo "SKIP bc2cpp sycl-rewrite: ruby not installed"; exit 0; }
ruby -e 'exit Gem::Version.new(RUBY_VERSION) >= Gem::Version.new("4.0")' ||
  { echo "SKIP bc2cpp sycl-rewrite: needs Ruby 4.0, have $(ruby -e 'print RUBY_VERSION')"; exit 0; }
ruby -e 'require "prism"; require "rbs"' 2>/dev/null || { echo "SKIP bc2cpp sycl-rewrite: the prism and rbs gems are missing"; exit 0; }
command -v rake >/dev/null || { echo "SKIP bc2cpp sycl-rewrite: rake not installed"; exit 0; }

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
  { tail -20 build/bc2cpp/mrbc.log; echo "FAIL bc2cpp sycl-rewrite: building the probe mrbc failed"; exit 1; }

# The cases, one command line each. The runner gives every case an empty stdin.
cases=build/bc2cpp/sycl_rewrite.cases
{
  for src in $(find tests/gpu/sycl -maxdepth 1 -name '*.cpp' | LC_ALL=C sort); do
    echo "$src" # accepted (vecadd, vecadd_device) or refused (refuse_2d, refuse_none, status 3)
  done
  echo "--bogus tests/gpu/sycl/vecadd.cpp"        # the usage line, status 1
  echo "-"                                         # stdin as the source: a usage error (no file), status 1
  echo "tests/gpu/sycl/no_such_file.cpp"          # a missing file: main reports it and returns status 1
} > "$cases"

log=build/bc2cpp/sycl_rewrite.log
bench=${SYCL_REWRITE_BENCH_SRC:-tests/gpu/sycl/vecadd.cpp}
(env -u LD ruby "$tree/tools/script_world/compiled_run.rb" --script scripts/sycl-rewrite.rb \
  --tail 'rc = main(ARGV)\nexit(rc) if rc != 0\n' --entry 'main(ARGV)' --cases "$cases" --bench "$bench" \
  --repeat "${PATHB_BENCH_REPEAT:-3}" --bench-status 0 --chdir "$root") 2>&1 | tee "$log"
[ "${PIPESTATUS[0]}" = 0 ] || { echo "FAIL bc2cpp sycl-rewrite: the runner failed"; exit 1; }
grep -q -E '^cases: ([0-9]+)/\1 ' "$log" || { echo "FAIL bc2cpp sycl-rewrite: the cases differ"; exit 1; }

speedup=$(sed -nE 's/^bc2cpp speedup over the mruby interpreter: ([0-9.]+)x.*/\1/p' "$log" | head -1)
if [ -n "$speedup" ]; then
  echo "bc2cpp sycl-rewrite: compiled over interpreted mruby: ${speedup}x"
  [ -n "${GITHUB_STEP_SUMMARY:-}" ] && {
    echo "sycl-rewrite.rb, $bench: compiled over interpreted mruby **${speedup}x**"
    sed -nE '/^(mruby|CRuby)/p' "$log" | sed 's/^/- /'
  } >> "$GITHUB_STEP_SUMMARY"
  if [ -n "${SCRIPT_WORLD_MIN_SPEEDUP:-}" ] &&
     awk -v s="$speedup" -v m="$SCRIPT_WORLD_MIN_SPEEDUP" 'BEGIN { exit !(s < m) }'; then
    echo "FAIL bc2cpp sycl-rewrite: speedup ${speedup}x is under SCRIPT_WORLD_MIN_SPEEDUP=${SCRIPT_WORLD_MIN_SPEEDUP}"; exit 1
  fi
fi
echo "PASS bc2cpp sycl-rewrite"
