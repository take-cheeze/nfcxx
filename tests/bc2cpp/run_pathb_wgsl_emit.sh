#!/usr/bin/env bash
# bc2cpp world: scripts/pathb-wgsl-emit.rb, nfcxx's Path B IR to WGSL emitter (1.7K lines of mruby), compiled by bc2cpp as
# a closed world (the script-world build kind, bc2cpp/tools/script_world/) on the mruby fork of the pinned rpg-maker-clone
# (tests/bc2cpp/fetch.sh). The check: for every IR of tests/pathb-ir, the device kernel IR of tests/gpu/sycl, the refused
# and malformed IR of tests/pathb-ir-opt and tests/mruby/pathb-*-edge, plus the usage and error paths, the sealed
# executable's stdout, stderr and exit status are byte-identical to the mruby interpreter's on the same script (an
# uncaught exception, the one case with a backtrace, compares its report without it: compiled code has no line table).
# Prints the best-of-N wall time of the interpreter, the compiled build and CRuby on the benchmark IR, and the speedup of
# the compiled build.
#   PATHB_WGSL_BENCH_IR=file     the IR to time (default tests/pathb-ir/eh_libstdcxx_throw.ir, 3.4 MB: the largest IR the
#                                emitter accepts; it has no SYCL kernel, so the timing measures the parse)
#   PATHB_BENCH_REPEAT=N         runs per runtime, best kept (default 3)
#   SCRIPT_WORLD_MIN_SPEEDUP=X   also fail when the compiled build is under X times the interpreter
#   BC2CPP_RPG_DIR=dir           an existing rpg-maker-clone checkout instead of the pinned one
# Needs Ruby 4.0 with the prism and rbs gems, rake, a C/C++ compiler, bison and make. Without them it prints a skip.
# The frame-local block knob (BC2CPP_STACK_BLOCKS, docs/notes/bc2cpp-migration.md) is left at its default here: the
# world's cases show no divergence without it.
cd "$(dirname "$0")/../.."
root=$PWD
. tests/bc2cpp/fetch.sh
command -v ruby >/dev/null || { echo "SKIP bc2cpp pathb-wgsl-emit: ruby not installed"; exit 0; }
ruby -e 'exit Gem::Version.new(RUBY_VERSION) >= Gem::Version.new("4.0")' ||
  { echo "SKIP bc2cpp pathb-wgsl-emit: needs Ruby 4.0, have $(ruby -e 'print RUBY_VERSION')"; exit 0; }
ruby -e 'require "prism"; require "rbs"' 2>/dev/null || { echo "SKIP bc2cpp pathb-wgsl-emit: the prism and rbs gems are missing"; exit 0; }
command -v rake >/dev/null || { echo "SKIP bc2cpp pathb-wgsl-emit: rake not installed"; exit 0; }

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
  { tail -20 build/bc2cpp/mrbc.log; echo "FAIL bc2cpp pathb-wgsl-emit: building the probe mrbc failed"; exit 1; }

# The cases, one command line each. The runner gives every case an empty stdin.
cases=build/bc2cpp/pathb_wgsl_emit.cases
manifest=build/bc2cpp/pathb_wgsl_emit.man # written by the cases with --manifest (the runner compares only the streams and status)
device=tests/gpu/sycl/vecadd_device.ir    # the one device kernel IR in the repo: WGSL out, with a manifest
{
  for ir in $(find tests/pathb-ir -maxdepth 1 -name '*.ir' | LC_ALL=C sort); do
    echo "$ir"
  done
  echo "$device"
  echo "--narrow-i64 $device"
  echo "--manifest=$manifest $device"
  echo "--narrow-i64 --manifest=$manifest $device"
  echo "--manifest=$manifest tests/pathb-ir-opt/prune.ir" # a refusal (status 3) after the manifest path is set
  echo "tests/pathb-ir-opt/prune.ir"                     # refused: address of function fp_target
  for ir in $(find tests/mruby/pathb-edge tests/mruby/pathb-cil-edge -name '*.ir' | LC_ALL=C sort); do
    echo "$ir" # malformed IR: each one an error (status 1)
  done
  echo "--narrow-i64"                                    # no file: the runner's empty stdin
  echo "-"                                               # stdin, explicitly
  echo "--bogus $device"                                 # the usage line, status 1
  echo "--manifest $device"                              # --manifest without =: the usage line
  echo "!tests/pathb-ir/no_such_file.ir"                 # an uncaught exception: the report without its backtrace
  echo "!--manifest= $device"                            # an empty manifest path: File.open("") raises
} > "$cases"

log=build/bc2cpp/pathb_wgsl_emit.log
bench=${PATHB_WGSL_BENCH_IR:-tests/pathb-ir/eh_libstdcxx_throw.ir}
(env -u LD ruby "$tree/tools/script_world/compiled_run.rb" --script scripts/pathb-wgsl-emit.rb \
  --tail 'rc = main(ARGV)\nexit(rc) if rc != 0\n' --entry 'main(ARGV)' --cases "$cases" --bench "$bench" \
  --repeat "${PATHB_BENCH_REPEAT:-3}" --bench-status 0 --chdir "$root") 2>&1 | tee "$log"
[ "${PIPESTATUS[0]}" = 0 ] || { echo "FAIL bc2cpp pathb-wgsl-emit: the runner failed"; exit 1; }
grep -q -E '^cases: ([0-9]+)/\1 ' "$log" || { echo "FAIL bc2cpp pathb-wgsl-emit: the cases differ"; exit 1; }

speedup=$(sed -nE 's/^bc2cpp speedup over the mruby interpreter: ([0-9.]+)x.*/\1/p' "$log" | head -1)
if [ -n "$speedup" ]; then
  echo "bc2cpp pathb-wgsl-emit: compiled over interpreted mruby: ${speedup}x"
  [ -n "${GITHUB_STEP_SUMMARY:-}" ] && {
    echo "pathb-wgsl-emit.rb, $bench: compiled over interpreted mruby **${speedup}x**"
    sed -nE '/^(mruby|CRuby)/p' "$log" | sed 's/^/- /'
  } >> "$GITHUB_STEP_SUMMARY"
  if [ -n "${SCRIPT_WORLD_MIN_SPEEDUP:-}" ] &&
     awk -v s="$speedup" -v m="$SCRIPT_WORLD_MIN_SPEEDUP" 'BEGIN { exit !(s < m) }'; then
    echo "FAIL bc2cpp pathb-wgsl-emit: speedup ${speedup}x is under SCRIPT_WORLD_MIN_SPEEDUP=${SCRIPT_WORLD_MIN_SPEEDUP}"; exit 1
  fi
fi
echo "PASS bc2cpp pathb-wgsl-emit"
