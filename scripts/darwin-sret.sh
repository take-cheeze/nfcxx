#!/usr/bin/env bash
# Print the path of the object that bridges the arm64 indirect-result convention for the exported libc++ functions that
# return a class by value (scripts/darwin-sret-symbols.txt). On AArch64 such a result goes through x8, but EDG's C
# prototype for the function passes the result pointer as the first argument (x0). A thunk per function moves x0 to x8,
# shifts the integer arguments down one register and branches to the real function. The C compilers rename the calls
# to the thunks (build/darwin-sret/rename.sed), so the rename and the object always come from this script.
# Prints nothing off macOS. Limit: a function with more than seven integer arguments would also need its stack arguments
# moved, which the thunks do not do (none of the listed functions has one).
set -euo pipefail
root=$(cd "$(dirname "$0")/.." && pwd)
[ "$(uname -s)" = Darwin ] || exit 0
list=$root/scripts/darwin-sret-symbols.txt
dir=$root/build/darwin-sret
out=$dir/darwin-sret.o
if [ ! -f "$out" ] || [ "$list" -nt "$out" ] || [ "$0" -nt "$out" ]; then
  mkdir -p "$dir"
  tmp=$(mktemp -d "$dir/.build.XXXXXX"); trap 'rm -rf "$tmp"' EXIT
  tbd=$(xcrun --sdk macosx --show-sdk-path)/usr/lib/libc++.1.tbd
  names=$(grep -v '^#' "$list" | grep -v '^$')
  : > "$tmp/thunks.s"; : > "$tmp/rename.sed"
  echo "	.text" >> "$tmp/thunks.s"
  for n in $names; do
    # the symbol must be exported by libc++, or the thunk would branch to nothing
    if ! grep -qF "_$n" "$tbd"; then echo "darwin-sret: $n is not exported by libc++ ($tbd)" >&2; exit 1; fi
    cat >> "$tmp/thunks.s" <<ASM
	.globl	___nfcxx_sret_$n
	.p2align	2
___nfcxx_sret_$n:
	mov	x8, x0
	mov	x0, x1
	mov	x1, x2
	mov	x2, x3
	mov	x3, x4
	mov	x4, x5
	mov	x5, x6
	mov	x6, x7
	b	_$n
ASM
    # extended regular expressions (sed -E, both GNU and BSD): the identifier after a non-identifier character or at a line start
    # (only the leading character is matched, so neighbouring occurrences do not overlap)
    echo "s/(^|[^A-Za-z0-9_])$n/\\1__nfcxx_sret_$n/g" >> "$tmp/rename.sed"
  done
  cc -c -o "$tmp/darwin-sret.o" "$tmp/thunks.s"
  mv -f "$tmp/rename.sed" "$dir/rename.sed"
  mv -f "$tmp/darwin-sret.o" "$out"
fi
printf '%s\n' "$out"
