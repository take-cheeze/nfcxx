#!/usr/bin/env bash
# bc2cpp world: scripts/cil-link.rb, nfcxx's CIL linker (the mruby port of cil-link.py), compiled by bc2cpp as a closed
# world (the script-world build kind, bc2cpp/tools/script_world/) on the mruby fork of the pinned rpg-maker-clone
# (tests/bc2cpp/fetch.sh). The world has no JSON, no popen and no Process, so the script carries its own JSON parser and
# the check runs the linker with --il-only: the CIL text goes to stdout (no ilasm, C shim or launcher). The fragments it
# links are made first by the host Ruby from the fixtures of tests/mruby/cil-link and tests/eh-unwind (cil-link.rb) and of
# tests/pathb-ir (pathb-cil-emit.rb), next to tests/mruby/cil-link's hand-written ones; the cases are every fragment on
# its own, a few pairs, and the refused inputs (usage, missing, malformed, duplicate definitions). Stdout, stderr and the
# exit status of the sealed executable are byte-identical to the mruby interpreter's on the same script.
#   CIL_LINK_BENCH_FRAGMENT=file the fragment to time (default the largest of the generated ones)
#   PATHB_BENCH_REPEAT=N         runs per runtime, best kept (default 3)
#   SCRIPT_WORLD_MIN_SPEEDUP=X   also fail when the compiled build is under X times the interpreter
#   BC2CPP_RPG_DIR=dir           an existing rpg-maker-clone checkout instead of the pinned one
# Needs Ruby 4.0 with the prism and rbs gems, rake, a C/C++ compiler, bison and make. Without them it prints a skip.
cd "$(dirname "$0")/../.."
root=$PWD
. tests/bc2cpp/fetch.sh
command -v ruby >/dev/null || { echo "SKIP bc2cpp cil-link: ruby not installed"; exit 0; }
ruby -e 'exit Gem::Version.new(RUBY_VERSION) >= Gem::Version.new("4.0")' ||
  { echo "SKIP bc2cpp cil-link: needs Ruby 4.0, have $(ruby -e 'print RUBY_VERSION')"; exit 0; }
ruby -e 'require "prism"; require "rbs"' 2>/dev/null || { echo "SKIP bc2cpp cil-link: the prism and rbs gems are missing"; exit 0; }
command -v rake >/dev/null || { echo "SKIP bc2cpp cil-link: rake not installed"; exit 0; }

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
  { tail -20 build/bc2cpp/mrbc.log; echo "FAIL bc2cpp cil-link: building the probe mrbc failed"; exit 1; }

# The fragments, from the host Ruby (a fixture the translator refuses has none).
frags=build/bc2cpp/cil_link
rm -rf "$frags"; mkdir -p "$frags"
for f in $(find tests/mruby/qbe2cil tests/eh-unwind -name '*.ssa' | LC_ALL=C sort); do
  n=$(basename "$f" .ssa)
  tail=${f%.ssa}.tail.s; [ -f "$tail" ] || tail=-
  ruby scripts/qbe2cil.rb "$f" "$tail" "$n" "$frags/q-$n.json" >/dev/null 2>&1 || rm -f "$frags/q-$n.json"
done
for f in $(find tests/pathb-ir tests/mruby/pathb-cil-edge -name '*.ir' | LC_ALL=C sort); do
  n=$(basename "$f" .ir)
  ruby scripts/pathb-cil-emit.rb "$f" "$frags/p-$n.json" >/dev/null 2>&1 || rm -f "$frags/p-$n.json"
done
printf '{"tu": "broken", "functions": [' > "$frags/broken.json"
printf '[1, 2' > "$frags/truncated.json"
[ -n "$(ls "$frags"/*.json 2>/dev/null)" ] || { echo "FAIL bc2cpp cil-link: no fragments were made"; exit 1; }

# The cases, one command line each. The runner gives every case an empty stdin.
cases=build/bc2cpp/cil-link.cases
{
  for f in $(ls "$frags"/[qp]-*.json | LC_ALL=C sort) tests/mruby/cil-link/*.json; do
    echo "--il-only -o build/bc2cpp/cil_link/out $f"
  done
  set -- $(ls "$frags"/q-*.json | LC_ALL=C sort | head -3)
  [ $# -ge 2 ] && echo "--il-only -o build/bc2cpp/cil_link/out $1 $2"    # two units: calls across them, or a duplicate main
  [ $# -ge 3 ] && echo "--il-only -o build/bc2cpp/cil_link/out $1 $2 $3"
  echo "--il-only -o build/bc2cpp/cil_link/out tests/mruby/cil-link/bigint.json tests/mruby/cil-link/bigint.json" # defined twice
  echo "--il-only tests/mruby/cil-link/bigint.json"                       # no -o
  echo "--il-only tests/mruby/cil-link/bigint.json -o"                    # -o without a name
  echo "--il-only -o build/bc2cpp/cil_link/out"                           # no fragments
  echo "--il-only -o build/bc2cpp/cil_link/out $frags/no_such_file.json"  # a missing fragment
  echo "--il-only -o build/bc2cpp/cil_link/out $frags/broken.json"
  echo "--il-only -o build/bc2cpp/cil_link/out $frags/truncated.json"
  echo "--il-only -o build/bc2cpp/cil_link/out -O2 -lm tests/mruby/cil-link/bigint.json" # link options are ignored
} > "$cases"

log=build/bc2cpp/cil-link.log
bench=${CIL_LINK_BENCH_FRAGMENT:-$(ls -S "$frags"/[qp]-*.json | head -1)}
(env -u LD ruby "$tree/tools/script_world/compiled_run.rb" --script scripts/cil-link.rb \
  --tail 'rc = main(ARGV)\nexit(rc) if rc != 0\n' --entry 'main(ARGV)' --cases "$cases" --bench "--il-only -o build/bc2cpp/cil_link/out $bench" \
  --repeat "${PATHB_BENCH_REPEAT:-3}" --bench-status 0 --chdir "$root") 2>&1 | tee "$log"
[ "${PIPESTATUS[0]}" = 0 ] || { echo "FAIL bc2cpp cil-link: the runner failed"; exit 1; }
grep -q -E '^cases: ([0-9]+)/\1 ' "$log" || { echo "FAIL bc2cpp cil-link: the cases differ"; exit 1; }

speedup=$(sed -nE 's/^bc2cpp speedup over the mruby interpreter: ([0-9.]+)x.*/\1/p' "$log" | head -1)
if [ -n "$speedup" ]; then
  echo "bc2cpp cil-link: compiled over interpreted mruby: ${speedup}x"
  [ -n "${GITHUB_STEP_SUMMARY:-}" ] && {
    echo "cil-link.rb, $bench: compiled over interpreted mruby **${speedup}x**"
    sed -nE '/^(mruby|CRuby)/p' "$log" | sed 's/^/- /'
  } >> "$GITHUB_STEP_SUMMARY"
  if [ -n "${SCRIPT_WORLD_MIN_SPEEDUP:-}" ] &&
     awk -v s="$speedup" -v m="$SCRIPT_WORLD_MIN_SPEEDUP" 'BEGIN { exit !(s < m) }'; then
    echo "FAIL bc2cpp cil-link: speedup ${speedup}x is under SCRIPT_WORLD_MIN_SPEEDUP=${SCRIPT_WORLD_MIN_SPEEDUP}"; exit 1
  fi
fi
echo "PASS bc2cpp cil-link"
