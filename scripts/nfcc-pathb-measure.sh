#!/usr/bin/env bash
# How many C files does nfcc's pathb backend build, and why are the others refused (count per reason)?
#   scripts/nfcc-pathb-measure.sh [-o REPORT] FILE.c...        compile each file with `nfcc -c` on NFCXX_BACKEND=pathb
#   NFCC_MEASURE_FLAGS="-Iinc -DX"   options given to every compile
# Prints one line per file (ok, or the refusal) to REPORT (default stdout), then the table: built, and each reason with its
# count. A reason is the first message line with paths, numbers and names inside quotes removed. docs/notes/linux-kernel.md.
set -uo pipefail
root=$(cd "$(dirname "$0")/.." && pwd)
rep=/dev/stdout; [ "${1:-}" != -o ] || { rep=$2; shift 2; }
tmp=$(mktemp -d); trap 'rm -rf "$tmp"' EXIT
: > "$tmp/res"; built=0; total=0
for f in "$@"; do
  total=$((total + 1))
  rc=0; NFCXX_BACKEND=pathb "$root/nfcc" -c ${NFCC_MEASURE_FLAGS:-} "$f" -o "$tmp/o.o" > "$tmp/out" 2>&1 || rc=$?
  if [ $rc = 0 ]; then built=$((built + 1)); echo "ok $f" >> "$tmp/res"
  else
    # the last line that names the refusal: the SSA route's, or the front end's error; paths, quoted names and numbers removed
    msg=$(grep -E 'SSA route:|error|nfcc: error|not supported' "$tmp/out" | tail -1)
    [ -n "$msg" ] || msg=$(grep -v '^ *$' "$tmp/out" | tail -1)
    msg=$(sed -E 's#^pathb-cc: [^ ]*: ##; s#pathb-ssa-build: not emitted: [^:]*: ##; s#^"[^"]*", line [0-9]+: ##; s#[A-Za-z0-9_.+-]*/[A-Za-z0-9_./+-]+##g; s/"[^"]*"/"X"/g; s/'"'"'[^'"'"']*'"'"'/X/g; s/[0-9]+/N/g; s/ +/ /g' <<<"$msg" | cut -c1-120)
    echo "refused($rc) $f: $msg" >> "$tmp/res"
  fi
done
{
  cat "$tmp/res"
  echo; echo "built $built of $total"
  grep '^refused' "$tmp/res" | sed -E 's/^refused\(([0-9]+)\) [^:]*: /\1: /' | sort | uniq -c | sort -rn
} > "$rep"
