#!/usr/bin/env bash
# mruby RITE reader (tools/mrbbc/mrb_rite.cpp, the dump tool mrbbc_dump) against mrbc 4.0.0.
#
# Every corpus program (tests/mrbbc/corpus/*.rb, plus one generated with more than 255 locals, which mrbc widens with an
# EXT1 prefix) is compiled with mrbc in four modes: default (LVAR section), -g (DBG section), --remove-lv (no LVAR),
# and -g with --remove-lv. Each file must:
#   - be read by mrbbc_dump with exit status 0 (header, every section, the irep tree and every instruction decode, and
#     no bytes after the END footer);
#   - be run to exit status 0 by the pinned mruby interpreter (build/mruby-tool/bin/mruby), so the file is a real RITE
#     file that mruby also accepts.
# Malformed files (truncated at several lengths, an extra byte, a wrong magic, a wrong format version, an unknown section
# name, a corrupted opcode) must be refused with exit status 1 and a message, never accepted.
#
#   tests/mrbbc/reader/run.sh
# Exit 77 (skip) when mrbc or the reference interpreter is missing.
set -u
root=$(cd "$(dirname "$0")/../../.." && pwd)
src=$root/tools/mrbbc
corpus=$root/tests/mrbbc/corpus
MRBC=${MRBC:-$root/build/mruby-tool/out/host/mrbc/bin/mrbc}
MRUBY=${MRUBY:-$root/build/mruby-tool/bin/mruby}
work=${TMPDIR:-/tmp}/mrbbc-reader.$$
mkdir -p "$work"
trap 'rm -rf "$work"' EXIT

if [ ! -x "$MRBC" ] || [ ! -x "$MRUBY" ]; then
  echo "mrbbc-reader: skipped (needs mrbc at $MRBC and the mruby interpreter at $MRUBY)"
  exit 77
fi

c++ -std=c++17 -O1 -Wall -Wextra -Werror -I"$src" -o "$work/dump" "$src/mrb_rite.cpp" "$src/mrbbc_dump.cpp" || exit 1

# A program that needs more than 255 registers: 200 locals, then a right-nested sum 100 levels deep, where each level
# keeps its left operand in a temporary register. The registers past 255 are widened by mrbc with an EXT1 prefix.
: > "$work/many_locals.rb"
for i in $(seq 1 200); do echo "v$i = $i" >> "$work/many_locals.rb"; done
pre=; post=
for i in $(seq 1 100); do pre="$pre""v$i + ("; post=")$post"; done
echo "x = ${pre}v101${post}" >> "$work/many_locals.rb"
echo "x" >> "$work/many_locals.rb"

fail=0
n=0
for rb in "$corpus"/*.rb "$work/many_locals.rb"; do
  base=$(basename "$rb" .rb)
  for mode in default dbg nolv dbg_nolv; do
    rite=$work/$base.$mode.rite
    flags=
    case $mode in
      dbg) flags=-g ;;
      nolv) flags=--remove-lv ;;
      dbg_nolv) flags="-g --remove-lv" ;;
    esac
    # shellcheck disable=SC2086
    if ! "$MRBC" $flags -o "$rite" "$rb" 2> "$work/mrbc.err"; then
      echo "FAIL $base ($mode): mrbc refused the program: $(cat "$work/mrbc.err")"
      fail=1
      continue
    fi
    n=$((n + 1))
    if ! "$work/dump" "$rite" > "$work/$base.$mode.txt" 2> "$work/err.txt"; then
      echo "FAIL $base ($mode): the reader refused a file mrbc wrote: $(cat "$work/err.txt")"
      fail=1
      continue
    fi
    if ! grep -q '^decoded [0-9]* instructions$' "$work/$base.$mode.txt"; then
      echo "FAIL $base ($mode): no instruction count in the listing"
      fail=1
    fi
    if ! "$MRUBY" "$rite" > /dev/null 2> "$work/run.err"; then
      echo "FAIL $base ($mode): the mruby interpreter refused the file: $(cat "$work/run.err")"
      fail=1
    fi
  done
done

# The widened instructions of the many-locals program are decoded (EXT1 prefix and its widened operands).
if ! grep -q '(EXT1)' "$work/many_locals.default.txt"; then
  echo "FAIL many_locals: no EXT1-widened instruction in the listing (the widened form was not produced)"
  fail=1
fi

# Malformed input: every one must be refused with status 1 and a message on stderr.
rite=$work/arith.default.rite
size=$(wc -c < "$rite")
refuse() {  # refuse NAME FILE: the reader must exit 1 with a message
  local name=$1 file=$2
  "$work/dump" "$file" > /dev/null 2> "$work/neg.err"
  local st=$?
  if [ "$st" -ne 1 ] || [ ! -s "$work/neg.err" ]; then
    echo "FAIL refuse $name: status $st, stderr [$(cat "$work/neg.err")]"
    fail=1
  fi
  m=$((m + 1))
}
m=0
for cut in 0 1 7 19 20 21 40 $((size / 2)) $((size - 9)) $((size - 1)); do
  head -c "$cut" "$rite" > "$work/cut.rite"
  refuse "truncated at $cut" "$work/cut.rite"
done
cp "$rite" "$work/extra.rite"; printf 'x' >> "$work/extra.rite"; refuse "trailing byte" "$work/extra.rite"
{ printf 'XITE'; tail -c +5 "$rite"; } > "$work/magic.rite"; refuse "bad magic" "$work/magic.rite"
{ head -c 4 "$rite"; printf '03'; tail -c +7 "$rite"; } > "$work/version.rite"; refuse "format 03.00" "$work/version.rite"
# The IREP section's identifier replaced: the section is unknown, so the file is refused at its header.
{ head -c 20 "$rite"; printf 'XXXX'; tail -c +25 "$rite"; } > "$work/section.rite"; refuse "unknown section" "$work/section.rite"
# An opcode byte outside the table: the first instruction of the IREP section's iseq (its offset is found by search).
# The iseq starts after the 12-byte section header, the 10-byte record header and the 2-byte catch count, 4-byte ilen.
off=$((20 + 12 + 10 + 2 + 4))
{ head -c "$off" "$rite"; printf '\377'; tail -c +$((off + 2)) "$rite"; } > "$work/opcode.rite"
refuse "opcode 255" "$work/opcode.rite"
[ "$m" -ge 14 ] || { echo "FAIL: only $m malformed inputs were checked"; fail=1; }

if [ "$fail" -ne 0 ]; then
  echo "mrbbc-reader: FAILED"
  exit 1
fi
echo "mrbbc-reader: $n RITE files read and run by mruby; $m malformed inputs refused"
