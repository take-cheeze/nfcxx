#!/usr/bin/env bash
# bc2cpp world: scripts/llvm-to-pathb.rb, nfcxx's LLVM IR text (.ll) to Path B IR translator, compiled by bc2cpp as a
# closed world (the script-world build kind, bc2cpp/tools/script_world/) on the mruby fork of the pinned rpg-maker-clone
# (tests/bc2cpp/fetch.sh). The inputs are the .ll files of tests/llvm-pathb/cases (clang-18 -O0, or -O1 with `// OPT: 1`)
# and of tools/wasm-explorer/examples, each plain and with --wasm; the refusal and malformed-input paths; the usage paths;
# and an uncaught exception (a missing file). For every case the sealed executable's stdout, stderr and exit status are
# byte-identical to the mruby interpreter's on the same script (the uncaught case compares its report without the
# backtrace: compiled code has no line table). Prints the best-of-N wall time of the interpreter, the compiled build and
# CRuby on the benchmark input, and the speedup of the compiled build.
#   LLVM_PATHB_BENCH_REPEAT=N    runs per runtime, best kept (default 3)
#   SCRIPT_WORLD_MIN_SPEEDUP=X   also fail when the compiled build is under X times the interpreter
#   BC2CPP_RPG_DIR=dir           an existing rpg-maker-clone checkout instead of the pinned one
#   CLANG=clang-18               the clang that compiles the cases to .ll (default clang-18)
# The benchmark is a generated C file of 1500 small functions (about 4.5 MB of .ll, 4.1 MB of IR): the largest input the
# translator accepts that the repository has no file for. Needs Ruby 4.0 with the prism and rbs gems, rake, clang-18, a
# C/C++ compiler, bison and make. Without them it prints a skip.
cd "$(dirname "$0")/../.."
root=$PWD
. tests/bc2cpp/fetch.sh
command -v ruby >/dev/null || { echo "SKIP bc2cpp llvm-to-pathb: ruby not installed"; exit 0; }
ruby -e 'exit Gem::Version.new(RUBY_VERSION) >= Gem::Version.new("4.0")' ||
  { echo "SKIP bc2cpp llvm-to-pathb: needs Ruby 4.0, have $(ruby -e 'print RUBY_VERSION')"; exit 0; }
ruby -e 'require "prism"; require "rbs"' 2>/dev/null || { echo "SKIP bc2cpp llvm-to-pathb: the prism and rbs gems are missing"; exit 0; }
command -v rake >/dev/null || { echo "SKIP bc2cpp llvm-to-pathb: rake not installed"; exit 0; }
clang=${CLANG:-clang-18}
command -v "$clang" >/dev/null || { echo "SKIP bc2cpp llvm-to-pathb: $clang not installed"; exit 0; }

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
  { tail -20 build/bc2cpp/mrbc.log; echo "FAIL bc2cpp llvm-to-pathb: building the probe mrbc failed"; exit 1; }

# The inputs, generated from the repository's C cases the way tests/llvm-pathb/run.sh compiles them.
dir=build/bc2cpp/llvm_to_pathb
rm -rf "$dir"; mkdir -p "$dir/bad"
for c in tests/llvm-pathb/cases/*.c; do
  n=$(basename "$c" .c)
  opt=-O0; grep -q '^// OPT: *1' "$c" && opt=-O1
  "$clang" "$opt" -w -S -emit-llvm -fno-discard-value-names -o "$dir/$n.ll" "$c" ||
    { echo "FAIL bc2cpp llvm-to-pathb: $clang rejected $c"; exit 1; }
done
# Malformed and refused variants of one case: a function that is not closed, a 32-bit triple, module asm, a top-level
# line the translator does not know, and an empty file.
head -n 30 "$dir/arith.ll" > "$dir/bad/unclosed.ll"
sed 's/^target triple.*/target triple = "i386-unknown-linux-gnu"/' "$dir/arith.ll" > "$dir/bad/triple32.ll"
{ printf 'module asm "nop"\n'; cat "$dir/arith.ll"; } > "$dir/bad/asm.ll"
{ cat "$dir/arith.ll"; echo 'frobnicate'; } > "$dir/bad/toplevel.ll"
: > "$dir/bad/empty.ll"
# The benchmark: 1500 small functions with loops, arrays and branches, in the subset the translator covers.
ruby - 1500 > "$dir/bench.c" <<'RUBY'
n = Integer(ARGV[0])
out = ["static long tab[64];"]
(1..n).each do |i|
  out << "static long g#{i}[16];"
  out << "long f#{i}(long a, long b) {"
  out << "  long s = #{i};"
  out << "  for (int k = 0; k < 16; k++) { g#{i}[k] = a * k + b + #{i}; s += g#{i}[k] ^ (s >> 3); }"
  out << "  if (s > #{i * 7}) s -= b; else s += a << 2;"
  out << "  tab[#{i % 64}] = s + (long)(unsigned char)(s & 255);"
  out << "  return s;"
  out << "}"
end
out << "int main(void) {"
out << "  long t = 0;"
(1..n).each { |i| out << "  t += f#{i}(#{i % 13}, #{i % 7});" }
out << "  return (int)(t & 127);"
out << "}"
puts out
RUBY
"$clang" -O0 -w -S -emit-llvm -fno-discard-value-names -o "$dir/bench.ll" "$dir/bench.c" ||
  { echo "FAIL bc2cpp llvm-to-pathb: $clang rejected the benchmark source"; exit 1; }

# The cases, one command line each. A line starting with `!` is an uncaught exception (a missing file).
cases=build/bc2cpp/llvm_to_pathb.cases
{
  for ll in $(find "$dir" -maxdepth 1 -name '*.ll' ! -name bench.ll | LC_ALL=C sort) tools/wasm-explorer/examples/*.ll; do
    echo "$ll"
    echo "--wasm $ll"
  done
  for ll in $(find "$dir/bad" -name '*.ll' | LC_ALL=C sort); do
    echo "$ll"
  done
  echo "--wasm"                                       # no file: the usage line (a blank line would be skipped)
  echo "--wasm $dir/arith.ll $dir/arith.ll"           # two files: the usage line
  echo "$dir/arith.ll --wasm $dir/arith.ll"           # the usage line again, with the flag between
  echo "!$dir/no_such_file.ll"                       # an uncaught exception: the report without its backtrace
} > "$cases"

log=build/bc2cpp/llvm_to_pathb.log
(env -u LD ruby "$tree/tools/script_world/compiled_run.rb" --script scripts/llvm-to-pathb.rb \
  --tail 'rc = main(ARGV)\nexit(rc) if rc != 0\n' --entry 'main(ARGV)' --cases "$cases" --bench "$dir/bench.ll" \
  --repeat "${LLVM_PATHB_BENCH_REPEAT:-3}" --bench-status 0 --chdir "$root") 2>&1 | tee "$log"
[ "${PIPESTATUS[0]}" = 0 ] || { echo "FAIL bc2cpp llvm-to-pathb: the runner failed"; exit 1; }
grep -q -E '^cases: ([0-9]+)/\1 ' "$log" || { echo "FAIL bc2cpp llvm-to-pathb: the cases differ"; exit 1; }

speedup=$(sed -nE 's/^bc2cpp speedup over the mruby interpreter: ([0-9.]+)x.*/\1/p' "$log" | head -1)
if [ -n "$speedup" ]; then
  echo "bc2cpp llvm-to-pathb: compiled over interpreted mruby: ${speedup}x"
  [ -n "${GITHUB_STEP_SUMMARY:-}" ] && {
    echo "llvm-to-pathb.rb, $dir/bench.ll: compiled over interpreted mruby **${speedup}x**"
    sed -nE '/^(mruby|CRuby)/p' "$log" | sed 's/^/- /'
  } >> "$GITHUB_STEP_SUMMARY"
  if [ -n "${SCRIPT_WORLD_MIN_SPEEDUP:-}" ] &&
     awk -v s="$speedup" -v m="$SCRIPT_WORLD_MIN_SPEEDUP" 'BEGIN { exit !(s < m) }'; then
    echo "FAIL bc2cpp llvm-to-pathb: speedup ${speedup}x is under SCRIPT_WORLD_MIN_SPEEDUP=${SCRIPT_WORLD_MIN_SPEEDUP}"; exit 1
  fi
fi
echo "PASS bc2cpp llvm-to-pathb"
