#!/usr/bin/env bash
# Build a Rust program with mrustc, and compile the C it emits with nfcxx's C pipeline (cproc -> QBE; scripts/qbe-cc).
# The program's own code and the monomorphised generics it uses go through QBE. The standard library is the one
# mrustc built with gcc (its rlib objects), which is linked in unchanged. See docs/notes/mrustc-frontend.md.
#   scripts/mrustc-nfcc.sh prog.rs -o prog [mrustc flags...]
#   MRUSTC=<bin>      mrustc binary (default build/mrustc/src/bin/mrustc, from scripts/setup-mrustc.sh)
#   MRUSTC_STD=<dir>  directory with the standard library objects (default build/mrustc/src/output-1.90.0)
# The edition defaults to 2021 (pass --edition to override it; mrustc's own default is 2015).
set -euo pipefail
start=$PWD
cd "$(dirname "$0")/.."
root=$PWD
mrustc=${MRUSTC:-$root/build/mrustc/src/bin/mrustc}
std=${MRUSTC_STD:-$root/build/mrustc/src/output-1.90.0}

# The arguments are paths of the caller's directory, so they are made absolute before the cd above has any effect.
src="" out="" extra=()
while [ $# -gt 0 ]; do
  case $1 in
    -o) out=${2:?-o needs a file}; shift 2 ;;
    *.rs) src=$1; shift ;;
    *) extra+=("$1"); shift ;;
  esac
done
[ -n "$src" ] && [ -n "$out" ] || { echo "usage: scripts/mrustc-nfcc.sh prog.rs -o prog [mrustc flags...]" >&2; exit 2; }
case $src in /*) ;; *) src=$start/$src ;; esac
case $out in /*) ;; *) out=$start/$out ;; esac
[ -x "$mrustc" ] && [ -f "$std/libstd.rlib.o" ] || { echo "mrustc-nfcc: no mrustc or standard library; run scripts/setup-mrustc.sh" >&2; exit 1; }

tmp=$(mktemp -d)
# MRUSTC_NFCC_KEEP=1 keeps the intermediate files (the mrustc C, the preprocessed and rewritten C, the tail) for debugging.
[ -n "${MRUSTC_NFCC_KEEP:-}" ] || trap 'rm -rf "$tmp"' EXIT
# mrustc writes the C (<out>.c) and the gcc command line that links it (<out>_cmd.txt); the gcc binary it also
# builds is not used.
MRUSTC_TARGET_VER=${MRUSTC_TARGET_VER:-1.90} "$mrustc" "$src" -o "$tmp/prog" -L "$std" --edition 2021 ${extra[@]+"${extra[@]}"} >"$tmp/mrustc.log" 2>&1 ||
  { cat "$tmp/mrustc.log" >&2; echo "mrustc-nfcc: mrustc failed" >&2; exit 1; }
[ -f "$tmp/prog.c" ] && [ -f "$tmp/prog_cmd.txt" ] || { echo "mrustc-nfcc: mrustc wrote no C" >&2; exit 1; }

# The preprocessing of scripts/qbe-cc's hand-written C mode: the host's target macros (not the GCC identity ones), then
# -undef. Headers mrustc includes (<stdatomic.h>, <stdint.h>, ...) are expanded here, before the rewrite needs them.
cc -dM -E -x c /dev/null | grep -Ev '^#define (__GNUC|__GNUG|__GXX|__VERSION__|__OPTIMIZE|__GCC_|__SSE|__MMX|__AVX|__FLT(16|32|64|128)|__SIZEOF_(INT128|FLOAT)|__STDC_|__STRICT_ANSI__|__pic__|__PIC__|__pie__|__PIE__|__CET__|__HAVE_SPECULATION|__BFLT16|__DEC|__BLOCKS__|__USER_LABEL_PREFIX__|__REGISTER_PREFIX__|__NO_INLINE__|__tune|__code_model|__k8|__znver|__amd64|__MMX|__SEG|__FXSR|__SSP|__GXX|__LDBL_|__SIZEOF_LONG_DOUBLE__)' > "$tmp/defs.h"
cc -E -P -undef -D__CPROC__ -include "$tmp/defs.h" "$tmp/prog.c" > "$tmp/pp.c"
"$root/scripts/mrb" "$root/scripts/mrustc-prep.rb" "$tmp/pp.c" "$tmp/prep.c" "$tmp/tail.s"
NFCXX_C_INPUT=1 "$root/scripts/qbe-cc" -c "$tmp/prep.c" -o "$tmp/prog.o"

# The link: the program, the assembly tail (symbols named by asm labels, see mrustc-prep.rb), then mrustc's own
# objects for the standard library and the libraries it names, in its order.
objs=("$tmp/prog.o")
if [ -s "$tmp/tail.s" ]; then
  cc -c "$tmp/tail.s" -o "$tmp/tail.o"
  objs+=("$tmp/tail.o")
fi
std_objs=()
while IFS= read -r t; do std_objs+=("$t"); done < <(tr -d '"' < "$tmp/prog_cmd.txt" | tr ' ' '\n' | grep '\.rlib\.o$' || true)
libs=()
while IFS= read -r t; do libs+=("$t"); done < <(tr -d '"' < "$tmp/prog_cmd.txt" | tr ' ' '\n' | awk 'prev == "-l" { print "-l" $0 } { prev = $0 }' || true)
[ ${#std_objs[@]} -gt 0 ] || { echo "mrustc-nfcc: no standard library objects in $tmp/prog_cmd.txt" >&2; exit 1; }
"$root/scripts/qbe-cc" -o "$out" ${objs[@]+"${objs[@]}"} ${std_objs[@]+"${std_objs[@]}"} ${libs[@]+"${libs[@]}"}
