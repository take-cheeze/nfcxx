#!/usr/bin/env bash
# bc2cpp world: scripts/pathb-structure.rb, nfcxx's Path B structurizer (260 lines of mruby), compiled by bc2cpp as a closed
# world (the script-world build kind, bc2cpp/tools/script_world/) on the mruby fork of the pinned rpg-maker-clone
# (tests/bc2cpp/fetch.sh); the script, pathb-egraph.rb and pathb-ssa.rb, which it loads, are bundled into the one script
# the world takes (tests/bc2cpp/bundle_script.rb). The check: the first functions of every stage 2 golden and SSA case
# (tests/pathb-ir, tests/pathb-ssa/cases, tests/pathb-egraph/cases), converted by pathb-ssa.rb and optimized by
# pathb-egraph.rb on the host, one function to a file, structured; an empty file and a missing file; no arguments (an
# empty standard input). The sealed executable's stdout, stderr and exit status are byte-identical to the mruby
# interpreter's on the same script. Prints the best-of-N wall time of the interpreter, the compiled build and CRuby on the
# benchmark function, and the speedup of the compiled build.
#   PATHB_STRUCTURE_BENCH_SRC=file  the function to time (default the largest function of the inputs)
#   PATHB_BENCH_REPEAT=N         runs per runtime, best kept (default 3)
#   SCRIPT_WORLD_MIN_SPEEDUP=X   also fail when the compiled build is under X times the interpreter
#   BC2CPP_RPG_DIR=dir           an existing rpg-maker-clone checkout instead of the pinned one
# Needs Ruby 4.0 with the prism and rbs gems, rake, a C/C++ compiler, bison and make. Without them it prints a skip.
cd "$(dirname "$0")/../.."
root=$PWD
. tests/bc2cpp/fetch.sh
command -v ruby >/dev/null || { echo "SKIP bc2cpp pathb-structure: ruby not installed"; exit 0; }
ruby -e 'exit Gem::Version.new(RUBY_VERSION) >= Gem::Version.new("4.0")' ||
  { echo "SKIP bc2cpp pathb-structure: needs Ruby 4.0, have $(ruby -e 'print RUBY_VERSION')"; exit 0; }
ruby -e 'require "prism"; require "rbs"' 2>/dev/null || { echo "SKIP bc2cpp pathb-structure: the prism and rbs gems are missing"; exit 0; }
command -v rake >/dev/null || { echo "SKIP bc2cpp pathb-structure: rake not installed"; exit 0; }

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
  { tail -20 build/bc2cpp/mrbc.log; echo "FAIL bc2cpp pathb-structure: building the probe mrbc failed"; exit 1; }

# The cases, one command line each. The runner gives every case an empty stdin.
in=build/bc2cpp/pathb_structure_in
rm -rf "$in"; mkdir -p "$in"
# One function to a file: the optimizer's output for the first four functions of each module.
ruby -e '
  require "./scripts/pathb-egraph"
  dir = ARGV.shift
  ARGV.each do |ir|
    ssa, = IO.popen(["ruby", "scripts/pathb-ssa.rb", ir], err: File::NULL) { |io| [io.read] }
    next if ssa.nil? || ssa.empty?
    read_forms(ssa).select { |f| head(f) == "ssa-function" }.first(4).each_with_index do |f, i|
      out, = PathbEgraph.optimize_fn(PathbEgraph.parse_fn(f))
      File.write(File.join(dir, "#{File.basename(ir, ".ir")}.#{i}.ssa"), PathbEgraph.render(out) + "\n")
    end
  end' "$in" $(find tests/pathb-ir tests/pathb-ssa/cases tests/pathb-egraph/cases -maxdepth 1 -name '*.ir' | LC_ALL=C sort) ||
  { echo "FAIL bc2cpp pathb-structure: making the inputs failed"; exit 1; }
: > "$in/empty.ssa"
cases=build/bc2cpp/pathb_structure.cases
{
  for f in $(find "$in" -name '*.ssa' | LC_ALL=C sort); do echo "$f"; done
  echo "$in/no_such_file.ssa"                        # a missing file: the message, status 1
  echo "-"                                           # standard input, empty here: the usage line, status 1
} > "$cases"

# The script world takes one file: the script and the scripts it loads with require_relative, bundled.
bundle=build/bc2cpp/pathb-structure.bundle.rb
ruby tests/bc2cpp/bundle_script.rb "$bundle" scripts/pathb-structure.rb scripts/pathb-ssa.rb scripts/pathb-egraph.rb || { echo "FAIL bc2cpp pathb-structure: bundling failed"; exit 1; }

log=build/bc2cpp/pathb_structure.log
bench=${PATHB_STRUCTURE_BENCH_SRC:-$(ls -S build/bc2cpp/pathb_structure_in/*.ssa | head -1)}
(env -u LD ruby "$tree/tools/script_world/compiled_run.rb" --script "$bundle" \
  --tail 'rc = main(ARGV)\nexit(rc) if rc != 0\n' --entry 'main(ARGV)' --cases "$cases" --bench "$bench" \
  --repeat "${PATHB_BENCH_REPEAT:-3}" --bench-status 0 --chdir "$root") 2>&1 | tee "$log"
[ "${PIPESTATUS[0]}" = 0 ] || { echo "FAIL bc2cpp pathb-structure: the runner failed"; exit 1; }
grep -q -E '^cases: ([0-9]+)/\1 ' "$log" || { echo "FAIL bc2cpp pathb-structure: the cases differ"; exit 1; }

speedup=$(sed -nE 's/^bc2cpp speedup over the mruby interpreter: ([0-9.]+)x.*/\1/p' "$log" | head -1)
if [ -n "$speedup" ]; then
  echo "bc2cpp pathb-structure: compiled over interpreted mruby: ${speedup}x"
  [ -n "${GITHUB_STEP_SUMMARY:-}" ] && {
    echo "pathb-structure.rb, $bench: compiled over interpreted mruby **${speedup}x**"
    sed -nE '/^(mruby|CRuby)/p' "$log" | sed 's/^/- /'
  } >> "$GITHUB_STEP_SUMMARY"
  if [ -n "${SCRIPT_WORLD_MIN_SPEEDUP:-}" ] &&
     awk -v s="$speedup" -v m="$SCRIPT_WORLD_MIN_SPEEDUP" 'BEGIN { exit !(s < m) }'; then
    echo "FAIL bc2cpp pathb-structure: speedup ${speedup}x is under SCRIPT_WORLD_MIN_SPEEDUP=${SCRIPT_WORLD_MIN_SPEEDUP}"; exit 1
  fi
fi
echo "PASS bc2cpp pathb-structure"
