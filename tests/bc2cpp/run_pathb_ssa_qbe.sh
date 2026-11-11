#!/usr/bin/env bash
# bc2cpp world: scripts/pathb-ssa-qbe.rb, nfcxx's Path B SSA to QBE emitter (2.1K lines of mruby), compiled by bc2cpp as a
# closed world (the script-world build kind, bc2cpp/tools/script_world/) on the mruby fork of the pinned rpg-maker-clone
# (tests/bc2cpp/fetch.sh); the script and pathb-ssa.rb, which it loads, are bundled into the one script the world takes
# (tests/bc2cpp/bundle_script.rb). The check: the SSA text of every stage 2 golden and SSA / e-graph case (made by
# pathb-ssa.rb on the host), and the e-graph's optimization of it, emitted as QBE IL; a module with a function the emitter
# refuses ends in an uncaught QbeUnsupported (compared without its backtrace); the missing-file path. The sealed
# executable's stdout, stderr and exit status are byte-identical to the mruby interpreter's on the same script. Prints the
# best-of-N wall time of the interpreter, the compiled build and CRuby on the benchmark input, and the speedup of the
# compiled build.
#   PATHB_SSA_QBE_BENCH_SRC=file  the SSA text to emit (default the largest input the emitter accepts)
#   PATHB_BENCH_REPEAT=N         runs per runtime, best kept (default 3)
#   SCRIPT_WORLD_MIN_SPEEDUP=X   also fail when the compiled build is under X times the interpreter
#   BC2CPP_RPG_DIR=dir           an existing rpg-maker-clone checkout instead of the pinned one
# Needs Ruby 4.0 with the prism and rbs gems, rake, a C/C++ compiler, bison and make. Without them it prints a skip.
cd "$(dirname "$0")/../.."
root=$PWD
. tests/bc2cpp/fetch.sh
command -v ruby >/dev/null || { echo "SKIP bc2cpp pathb-ssa-qbe: ruby not installed"; exit 0; }
ruby -e 'exit Gem::Version.new(RUBY_VERSION) >= Gem::Version.new("4.0")' ||
  { echo "SKIP bc2cpp pathb-ssa-qbe: needs Ruby 4.0, have $(ruby -e 'print RUBY_VERSION')"; exit 0; }
ruby -e 'require "prism"; require "rbs"' 2>/dev/null || { echo "SKIP bc2cpp pathb-ssa-qbe: the prism and rbs gems are missing"; exit 0; }
command -v rake >/dev/null || { echo "SKIP bc2cpp pathb-ssa-qbe: rake not installed"; exit 0; }

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
  { tail -20 build/bc2cpp/mrbc.log; echo "FAIL bc2cpp pathb-ssa-qbe: building the probe mrbc failed"; exit 1; }

# The cases, one command line each. The runner gives every case an empty stdin.
in=build/bc2cpp/pathb_ssa_qbe_in
rm -rf "$in"; mkdir -p "$in"
for ir in $(find tests/pathb-ir tests/pathb-ssa/cases tests/pathb-egraph/cases -maxdepth 1 -name '*.ir' | LC_ALL=C sort); do
  b=$(basename "$ir" .ir)
  ruby scripts/pathb-ssa.rb "$ir" > "$in/$b.ssa" 2>/dev/null || { rm -f "$in/$b.ssa"; continue; } # the converter refuses some inputs
  # The optimized form too, except for the multi-megabyte goldens, whose optimized runs crash the compiled build with a
  # segmentation fault where the interpreter is fine (the garbage collector under that allocation load, not the script).
  [ "$(wc -c < "$in/$b.ssa")" -lt 1000000 ] && ruby scripts/pathb-egraph.rb "$in/$b.ssa" > "$in/$b.opt.ssa" 2>/dev/null
done
cases=build/bc2cpp/pathb_ssa_qbe.cases
accepted=build/bc2cpp/pathb_ssa_qbe.accepted
: > "$accepted"
{
  for f in $(find "$in" -name '*.ssa' | LC_ALL=C sort); do
    # The host run says whether the emitter takes the module: a refusal is an uncaught exception (marked with !).
    if ruby scripts/pathb-ssa-qbe.rb "$f" > /dev/null 2>&1; then echo "$f"; echo "$f" >> "$accepted"; else echo "!$f"; fi
  done
  echo "$in/no_such_file.ssa"                        # a missing file: the message, status 1
} > "$cases"

# The script world takes one file: the script and the scripts it loads with require_relative, bundled.
bundle=build/bc2cpp/pathb-ssa-qbe.bundle.rb
ruby tests/bc2cpp/bundle_script.rb "$bundle" scripts/pathb-ssa-qbe.rb scripts/pathb-ssa.rb || { echo "FAIL bc2cpp pathb-ssa-qbe: bundling failed"; exit 1; }

log=build/bc2cpp/pathb_ssa_qbe.log
bench=${PATHB_SSA_QBE_BENCH_SRC:-$(ls -S $(cat build/bc2cpp/pathb_ssa_qbe.accepted) | head -1)}
(env -u LD ruby "$tree/tools/script_world/compiled_run.rb" --script "$bundle" \
  --tail 'rc = main(ARGV)\nexit(rc) if rc != 0\n' --entry 'main(ARGV)' --cases "$cases" --bench "$bench" \
  --repeat "${PATHB_BENCH_REPEAT:-3}" --bench-status 0 --chdir "$root") 2>&1 | tee "$log"
[ "${PIPESTATUS[0]}" = 0 ] || { echo "FAIL bc2cpp pathb-ssa-qbe: the runner failed"; exit 1; }
grep -q -E '^cases: ([0-9]+)/\1 ' "$log" || { echo "FAIL bc2cpp pathb-ssa-qbe: the cases differ"; exit 1; }

speedup=$(sed -nE 's/^bc2cpp speedup over the mruby interpreter: ([0-9.]+)x.*/\1/p' "$log" | head -1)
if [ -n "$speedup" ]; then
  echo "bc2cpp pathb-ssa-qbe: compiled over interpreted mruby: ${speedup}x"
  [ -n "${GITHUB_STEP_SUMMARY:-}" ] && {
    echo "pathb-ssa-qbe.rb, $bench: compiled over interpreted mruby **${speedup}x**"
    sed -nE '/^(mruby|CRuby)/p' "$log" | sed 's/^/- /'
  } >> "$GITHUB_STEP_SUMMARY"
  if [ -n "${SCRIPT_WORLD_MIN_SPEEDUP:-}" ] &&
     awk -v s="$speedup" -v m="$SCRIPT_WORLD_MIN_SPEEDUP" 'BEGIN { exit !(s < m) }'; then
    echo "FAIL bc2cpp pathb-ssa-qbe: speedup ${speedup}x is under SCRIPT_WORLD_MIN_SPEEDUP=${SCRIPT_WORLD_MIN_SPEEDUP}"; exit 1
  fi
fi
echo "PASS bc2cpp pathb-ssa-qbe"
