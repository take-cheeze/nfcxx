#!/usr/bin/env bash
# Ruby 3.3 YARV bytecode -> Path B IR (tools/yarvbc), end to end, for the first subset.
#
# Each program is compiled to its binary iseq (RubyVM::InstructionSequence.compile(src).to_binary, by the ruby 3.3 here),
# lowered (yarvbc_lower), emitted to QBE IL by scripts/pathb-qbe-emit.rb (run under CRuby: the emitter is plain Ruby), assembled
# by QBE, linked with the runtime of tests/mrbbc/runtime (the value tags, the integer helpers, the driver), and run. Three
# kinds of program:
#   lower/*.rb       the value the program returns (its last line is one expression) is printed the way p prints it. The
#                    reference is ruby on the same file with that last line replaced by p(...).
#   lower/rterr/*.rb an uncaught runtime error: the exit status is 1, and the message line of ruby's stderr (its first line:
#                    ruby adds the backtrace after it) equals ours after the last ": ". Nothing is printed on stdout.
#   lower/err/*.rb   a program with a construct the producer does not lower yet. It is refused: yarvbc_lower exits 3, writes
#                    "refused:" on stderr and nothing on stdout. A refused program never reaches the emitter.
# A binary of another iseq format (not Ruby 3.3's) is refused the same way, checked on a patched copy of a lower/ program.
#
#   tests/yarv/lower/run.sh
# Exit 77 (skip) when ruby is not 3.3, or QBE is missing.
set -u
root=$(cd "$(dirname "$0")/../../.." && pwd)
src=$root/tools/yarvbc
rt=$root/tests/mrbbc/runtime
dir=$root/tests/yarv/lower
RUBY=${RUBY:-ruby}
QBE=${QBE:-$root/build/qbe/qbe}
emit=$root/scripts/pathb-qbe-emit.rb
work=$(mktemp -d "${TMPDIR:-/tmp}/yarvbc-lower.XXXXXX")
trap 'rm -rf "$work"' EXIT

if ! "$RUBY" -e 'exit(RUBY_VERSION.start_with?("3.3.") ? 0 : 1)' 2>/dev/null; then
  echo "yarvbc-lower: skipped (needs ruby 3.3 for the reference and the binary iseqs, as $RUBY)"
  exit 77
fi
if [ ! -x "$QBE" ]; then
  echo "yarvbc-lower: skipped (needs QBE at $QBE)"
  exit 77
fi

c++ -std=c++17 -O1 -Wall -Wextra -Werror -I"$src" -o "$work/lower" "$src/yarv_ibf.cpp" "$src/yarv_lower.cpp" \
  "$root/tools/common/stack_slots.cpp" "$src/yarvbc_lower_main.cpp" || exit 1
cc -std=c99 -Wall -Wextra -Werror -c -o "$work/mrbrt.o" "$rt/mrbrt.c" || exit 1
cc -std=c99 -Wall -Wextra -Werror -c -o "$work/driver.o" "$rt/driver.c" || exit 1

# compile SRC OUT: the binary iseq of the program (ruby 3.3's to_binary).
compile() {
  "$RUBY" -e 'File.binwrite(ARGV[1], RubyVM::InstructionSequence.compile(File.read(ARGV[0])).to_binary)' "$1" "$2"
}

# build SRC NAME: the program binary in $work/NAME, or the failing step's message on stdout (status 1).
build() {
  local rb=$1 base=$2
  compile "$rb" "$work/$base.yarb" > /dev/null 2>&1 || { echo "ruby refused the program"; return 1; }
  "$work/lower" "$work/$base.yarb" > "$work/$base.ir" 2> "$work/$base.err" \
    || { echo "lowering: $(cat "$work/$base.err")"; return 1; }
  "$RUBY" "$emit" "$work/$base.ir" > "$work/$base.ssa" 2> "$work/$base.err" \
    || { echo "emitter: $(cat "$work/$base.err")"; return 1; }
  "$QBE" "$work/$base.ssa" > "$work/$base.s" 2> "$work/$base.err" || { echo "qbe: $(cat "$work/$base.err")"; return 1; }
  cc -o "$work/$base" "$work/$base.s" "$work/mrbrt.o" "$work/driver.o" || { echo "link"; return 1; }
}

# value_ref SRC OUT: SRC with its last line replaced by p(LAST), the reference program.
value_ref() {
  local rb=$1 out=$2 last
  last=$(tail -n 1 "$rb")
  head -n -1 "$rb" > "$out"
  printf 'p(%s)\n' "$last" >> "$out"
}

fail=0
n=0
for rb in "$dir"/*.rb; do
  base=$(basename "$rb" .rb)
  if ! msg=$(build "$rb" "$base"); then echo "FAIL $base: $msg"; fail=1; continue; fi
  value_ref "$rb" "$work/$base.ref.rb"
  got=$("$work/$base") || { echo "FAIL $base: the program exited with status $?"; fail=1; continue; }
  want=$("$RUBY" "$work/$base.ref.rb") || { echo "FAIL $base: the reference failed"; fail=1; continue; }
  n=$((n + 1))
  if [ -z "$want" ] || [ "$got" != "$want" ]; then
    echo "FAIL $base: got [$got], ruby gives [$want]"
    fail=1
  fi
done

nr=0
for rb in "$dir"/rterr/*.rb; do
  base=rterr_$(basename "$rb" .rb)
  if ! msg=$(build "$rb" "$base"); then echo "FAIL $base: $msg"; fail=1; continue; fi
  "$work/$base" > "$work/$base.out" 2> "$work/$base.stderr"; status=$?
  "$RUBY" "$rb" > "$work/$base.mout" 2> "$work/$base.mstderr"; mstatus=$?
  got=$(head -n 1 "$work/$base.stderr" | sed -E 's/.*: //')
  want=$(head -n 1 "$work/$base.mstderr" | sed -E 's/.*: //')
  nr=$((nr + 1))
  if [ "$status" -ne 1 ] || [ "$mstatus" -ne 1 ] || [ -z "$want" ] || [ "$got" != "$want" ] || [ -s "$work/$base.out" ]; then
    echo "FAIL $base: got [$got] (status $status), ruby gives [$want] (status $mstatus)"
    fail=1
  fi
done

ne=0
for rb in "$dir"/err/*.rb; do
  base=err_$(basename "$rb" .rb)
  compile "$rb" "$work/$base.yarb" > /dev/null 2>&1 || { echo "FAIL $base: ruby refused the program"; fail=1; continue; }
  "$work/lower" "$work/$base.yarb" > "$work/$base.out" 2> "$work/$base.err"; status=$?
  ne=$((ne + 1))
  if [ "$status" -ne 3 ] || ! grep -q '^refused: ' "$work/$base.err" || [ -s "$work/$base.out" ]; then
    echo "FAIL $base: status $status, stderr [$(head -n 1 "$work/$base.err")]"
    fail=1
  fi
done

# the format: a binary whose header says another Ruby format version is refused (exit 3, nothing on stdout)
ng=0
compile "$dir/not.rb" "$work/format.yarb"
"$RUBY" -e 'b = File.binread(ARGV[0]); b.setbyte(8, b.getbyte(8) - 1); File.binwrite(ARGV[1], b)' \
  "$work/format.yarb" "$work/format_old.yarb"
"$work/lower" "$work/format_old.yarb" > "$work/format.out" 2> "$work/format.err"; status=$?
ng=$((ng + 1))
if [ "$status" -ne 3 ] || ! grep -q '^refused: iseq format 3.2 ' "$work/format.err" || [ -s "$work/format.out" ]; then
  echo "FAIL format: status $status, stderr [$(head -n 1 "$work/format.err")]"
  fail=1
fi

if [ "$fail" -ne 0 ]; then
  echo "yarvbc-lower: FAILED"
  exit 1
fi
echo "yarvbc-lower: $n programs match ruby 3.3; $nr runtime errors match ruby; $ne programs refused (exit 3); $ng format version refused"
