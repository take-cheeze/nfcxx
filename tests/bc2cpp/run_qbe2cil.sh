#!/usr/bin/env bash
# bc2cpp world: scripts/qbe2cil.rb, nfcxx's QBE SSA to CIL fragment translator (the mruby port of the Python original),
# compiled by bc2cpp as a closed world (the script-world build kind, bc2cpp/tools/script_world/) on the mruby fork of the
# pinned rpg-maker-clone (tests/bc2cpp/fetch.sh). The check: every fixture of tests/mruby/qbe2cil (accepted programs, with
# their assembly tail where one exists, and the refused and malformed ones) and the SSA of tests/eh-unwind, the usage and
# missing-file paths. The fragment is written to /dev/stdout, so the sealed executable's stdout (the fragment), stderr and
# exit status are byte-identical to the mruby interpreter's on the same script.
#   QBE2CIL_BENCH_SSA=file       the SSA to time (default tests/mruby/qbe2cil/real_virtual_dispatch.ssa, 8.7 KB: the timing is
#                                dominated by process startup)
#   PATHB_BENCH_REPEAT=N         runs per runtime, best kept (default 3)
#   SCRIPT_WORLD_MIN_SPEEDUP=X   also fail when the compiled build is under X times the interpreter
#   BC2CPP_RPG_DIR=dir           an existing rpg-maker-clone checkout instead of the pinned one
# Needs Ruby 4.0 with the prism and rbs gems, rake, a C/C++ compiler, bison and make. Without them it prints a skip.
cd "$(dirname "$0")/../.."
root=$PWD
. tests/bc2cpp/fetch.sh
command -v ruby >/dev/null || { echo "SKIP bc2cpp qbe2cil: ruby not installed"; exit 0; }
ruby -e 'exit Gem::Version.new(RUBY_VERSION) >= Gem::Version.new("4.0")' ||
  { echo "SKIP bc2cpp qbe2cil: needs Ruby 4.0, have $(ruby -e 'print RUBY_VERSION')"; exit 0; }
ruby -e 'require "prism"; require "rbs"' 2>/dev/null || { echo "SKIP bc2cpp qbe2cil: the prism and rbs gems are missing"; exit 0; }
command -v rake >/dev/null || { echo "SKIP bc2cpp qbe2cil: rake not installed"; exit 0; }

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
  { tail -20 build/bc2cpp/mrbc.log; echo "FAIL bc2cpp qbe2cil: building the probe mrbc failed"; exit 1; }

# The cases, one command line each. The runner gives every case an empty stdin.
cases=build/bc2cpp/qbe2cil.cases
{
  for f in $(find tests/mruby/qbe2cil tests/eh-unwind -name '*.ssa' | LC_ALL=C sort); do
    n=$(basename "$f" .ssa)
    tail=${f%.ssa}.tail.s; [ -f "$tail" ] || tail=-
    echo "$f $tail $n /dev/stdout"
  done
  echo "tests/mruby/qbe2cil/e_ops.ssa - e_ops"                       # no output path: the usage line, status 1
  echo "tests/mruby/qbe2cil/no_such_file.ssa - nope /dev/stdout"     # a missing file: an error, status 1
} > "$cases"

log=build/bc2cpp/qbe2cil.log
bench=${QBE2CIL_BENCH_SSA:-tests/mruby/qbe2cil/real_virtual_dispatch.ssa}
(env -u LD ruby "$tree/tools/script_world/compiled_run.rb" --script scripts/qbe2cil.rb \
  --tail 'rc = main(ARGV)\nexit(rc) if rc != 0\n' --entry 'main(ARGV)' --cases "$cases" --bench "$bench - bench /dev/stdout" \
  --repeat "${PATHB_BENCH_REPEAT:-3}" --bench-status 0 --chdir "$root") 2>&1 | tee "$log"
[ "${PIPESTATUS[0]}" = 0 ] || { echo "FAIL bc2cpp qbe2cil: the runner failed"; exit 1; }
grep -q -E '^cases: ([0-9]+)/\1 ' "$log" || { echo "FAIL bc2cpp qbe2cil: the cases differ"; exit 1; }

speedup=$(sed -nE 's/^bc2cpp speedup over the mruby interpreter: ([0-9.]+)x.*/\1/p' "$log" | head -1)
if [ -n "$speedup" ]; then
  echo "bc2cpp qbe2cil: compiled over interpreted mruby: ${speedup}x"
  [ -n "${GITHUB_STEP_SUMMARY:-}" ] && {
    echo "qbe2cil.rb, $bench: compiled over interpreted mruby **${speedup}x**"
    sed -nE '/^(mruby|CRuby)/p' "$log" | sed 's/^/- /'
  } >> "$GITHUB_STEP_SUMMARY"
  if [ -n "${SCRIPT_WORLD_MIN_SPEEDUP:-}" ] &&
     awk -v s="$speedup" -v m="$SCRIPT_WORLD_MIN_SPEEDUP" 'BEGIN { exit !(s < m) }'; then
    echo "FAIL bc2cpp qbe2cil: speedup ${speedup}x is under SCRIPT_WORLD_MIN_SPEEDUP=${SCRIPT_WORLD_MIN_SPEEDUP}"; exit 1
  fi
fi
echo "PASS bc2cpp qbe2cil"
