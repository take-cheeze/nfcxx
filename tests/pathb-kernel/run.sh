#!/usr/bin/env bash
# Reductions of the Linux 6.8 kernel files that nfcc's Path B backend refused (docs/notes/linux-kernel.md, "Path B"):
# each tests/pathb-kernel/*.c is compiled with the host gcc and with `NFCXX_BACKEND=pathb nfcc -c`; both programs
# must build, and the Path B one must exit with the status gcc's does (the oracle is gcc, not a number in the file).
# Needs the Path B harness (scripts/setup-edg.sh, setup-qbe.sh, setup-pathb.sh).
cd "$(dirname "$0")/../.."
root=$PWD
tmp=$(mktemp -d); trap 'rm -rf "$tmp"' EXIT
fail=0
for f in tests/pathb-kernel/*.c; do
  n=$(basename "$f" .c)
  gcc -w -O0 "$f" -o "$tmp/gcc" 2>"$tmp/err" || { echo "FAIL $n: gcc: $(head -3 "$tmp/err")"; fail=1; continue; }
  "$tmp/gcc"; want=$?
  if ! NFCXX_BACKEND=pathb "$root/nfcc" -c "$f" -o "$tmp/pb.o" 2>"$tmp/err"; then
    echo "FAIL $n: nfcc: $(head -3 "$tmp/err")"; fail=1; continue
  fi
  gcc "$tmp/pb.o" -o "$tmp/pb" 2>"$tmp/err" || { echo "FAIL $n: link: $(head -3 "$tmp/err")"; fail=1; continue; }
  "$tmp/pb"; got=$?
  if [ "$got" = "$want" ]; then echo "ok   $n (exit $got)"; else echo "FAIL $n: gcc exits $want, Path B $got"; fail=1; fi
done
exit $fail
