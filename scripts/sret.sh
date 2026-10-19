#!/usr/bin/env bash
# Print the path of the object that bridges the indirect-result convention for the exported library functions that return a
# class by value (scripts/sret-darwin-symbols.txt for libc++ on macOS, scripts/sret-linux-symbols.txt for libstdc++ on Linux
# aarch64). On AArch64 such a result goes through x8, but EDG's C prototype for the function passes the result pointer as the
# first argument (x0). A thunk per function moves x0 to x8, shifts the integer arguments down one register and branches to the
# real function. The C compilers rename the calls to the thunks (rename.sed next to the object), so the rename and the object
# always come from this script. Prints nothing elsewhere (x86-64 and other hosts pass the result pointer in the first argument).
# Cross mode (NFCXX_MACOS_SYSROOT set, a Linux host building for macOS arm64): the Mach-O thunks are built with llvm-mc in
# build/sret-cross. The export check needs the SDK, which the cross host does not have, so the names are taken from the list
# and the Mac's linker resolves them: a name the library does not export is an undefined symbol on the Mac, not a silent call.
# Limit: a function with more than seven integer arguments would also need its stack arguments moved; none of the listed
# functions has one.
set -euo pipefail
root=$(cd "$(dirname "$0")/.." && pwd)
cross=0
if [ -n "${NFCXX_MACOS_SYSROOT:-}" ]; then
  cross=1; list=$root/scripts/sret-darwin-symbols.txt; prefix=_
else
  case "$(uname -s)-$(uname -m)" in
    Darwin-*)
      list=$root/scripts/sret-darwin-symbols.txt; prefix=_ ;;
    Linux-aarch64)
      list=$root/scripts/sret-linux-symbols.txt; prefix= ;;
    *) exit 0 ;;
  esac
fi
dir=$root/build/sret; [ "$cross" = 1 ] && dir=$root/build/sret-cross
out=$dir/sret.o; [ "$cross" = 1 ] && out=$dir/sret-macos.o
if [ ! -f "$out" ] || [ "$list" -nt "$out" ] || [ "$0" -nt "$out" ]; then
  mkdir -p "$dir"
  tmp=$(mktemp -d "$dir/.build.XXXXXX"); trap 'rm -rf "$tmp"' EXIT
  names=$(grep -v '^#' "$list" | grep -v '^$')
  if [ "$cross" = 1 ]; then
    check() { true; }
  elif [ -n "$prefix" ]; then
    # the export table: the symbol must be exported by the library, or the thunk would branch to nothing
    exports=$(xcrun --sdk macosx --show-sdk-path)/usr/lib/libc++.1.tbd
    check() { grep -qF "_$1" "$exports"; }
  else
    lib=$(realpath "$(cc -print-file-name=libstdc++.so.6)")
    exports=$tmp/exports.txt; nm -D --defined-only "$lib" | awk '{split($3, a, "@"); print a[1]}' > "$exports"
    check() { grep -qxF "$1" "$exports"; }
  fi
  : > "$tmp/thunks.s"; : > "$tmp/rename.sed"
  if [ -z "$prefix" ]; then printf '\t.section .note.GNU-stack,"",%%progbits\n' >> "$tmp/thunks.s"; fi
  printf '\t.text\n' >> "$tmp/thunks.s"
  for n in $names; do
    if ! check "$n"; then echo "sret: $n is not exported by its library ($exports)" >&2; exit 1; fi
    thunk=__nfcxx_sret_$n
    {
      printf '\t.globl\t%s%s\n' "$prefix" "$thunk"
      [ -n "$prefix" ] || printf '\t.type\t%s%s,%%function\n' "$prefix" "$thunk"
      printf '\t.p2align\t2\n'
      printf '%s%s:\n' "$prefix" "$thunk"
      printf '\tmov\tx8, x0\n\tmov\tx0, x1\n\tmov\tx1, x2\n\tmov\tx2, x3\n\tmov\tx3, x4\n\tmov\tx4, x5\n\tmov\tx5, x6\n\tmov\tx6, x7\n'
      printf '\tb\t%s%s\n' "$prefix" "$n"
    } >> "$tmp/thunks.s"
    # extended regular expressions (sed -E, both GNU and BSD): the identifier after a non-identifier character or at a line start
    # (only the leading character is matched, so neighbouring occurrences do not overlap)
    echo "s/(^|[^A-Za-z0-9_])$n/\\1$thunk/g" >> "$tmp/rename.sed"
  done
  if [ "$cross" = 1 ]; then
    llvm-mc -triple=arm64-apple-darwin -filetype=obj -o "$tmp/sret.o" "$tmp/thunks.s"
  else
    cc -c -o "$tmp/sret.o" "$tmp/thunks.s"
  fi
  mv -f "$tmp/rename.sed" "$dir/rename.sed"
  mv -f "$tmp/sret.o" "$out"
fi
printf '%s\n' "$out"
