#!/usr/bin/env bash
# Build a Rust program with mrustc, and compile the C it emits with nfcxx's C pipeline (cproc -> QBE; scripts/qbe-cc).
# The program's own code and the monomorphised generics it uses go through QBE. The rest of the standard library is the
# one mrustc built with gcc (its rlib objects), linked in unchanged, unless MRUSTC_NFCC_CORE=1, which also compiles
# libcore through the same pipeline (cached in build/mrustc/nfcxx). See docs/notes/mrustc-frontend.md.
#   scripts/mrustc-nfcc.sh prog.rs -o prog [mrustc flags...]
#   MRUSTC=<bin>      mrustc binary (default build/mrustc/src/bin/mrustc, from scripts/setup-mrustc.sh)
#   MRUSTC_STD=<dir>  directory with the standard library objects (default build/mrustc/src/output-1.90.0)
#   MRUSTC_NFCC_CORE=1  compile libcore (MRUSTC_STD's libcore.rlib.c) through nfcxx's pipeline instead of linking gcc's
#   MRUSTC_NFCC_KEEP=1  keep the intermediate files, for debugging
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
# MRUSTC_NFCC_KEEP=1 keeps the intermediate files (the mrustc C, the preprocessed and rewritten C, the tails) for debugging.
[ -n "${MRUSTC_NFCC_KEEP:-}" ] || trap 'rm -rf "$tmp"' EXIT


# nfcxx_compile C NAME DIR: compiles mrustc's C file C into DIR/NAME.o, and its assembly tail (the helpers, and the
# trampolines of asm-labelled externs) into DIR/NAME.tail.o. Data symbols mrustc marks weak are weakened in NAME.o.
nfcxx_compile() {
  local c=$1 name=$2 dir=$3
  # Not -undef: that makes glibc drop every GNU attribute (aligned, packed, weak), which the rewrites rely on. qbe-cc
  # preprocesses again, with -undef, and the file then has no headers left to undefine anything.
  cc -E -P -D__CPROC__ "$c" > "$tmp/$name.pp.c"
  "$root/scripts/mrb" "$root/scripts/mrustc-prep.rb" "$tmp/$name.pp.c" "$tmp/$name.prep.c" "$tmp/$name.tail.s" "$tmp/$name.weak"
  NFCXX_C_INPUT=1 "$root/scripts/qbe-cc" -c "$tmp/$name.prep.c" -o "$dir/$name.o"
  if [ -s "$tmp/$name.weak" ]; then
    objcopy --weaken-symbols="$tmp/$name.weak" "$dir/$name.o" "$tmp/$name.weakened.o"
    mv "$tmp/$name.weakened.o" "$dir/$name.o"
  fi
  cc -c "$tmp/$name.tail.s" -o "$dir/$name.tail.o"
}

# The program: mrustc writes the C (<out>.c) and the gcc command line that links it (<out>_cmd.txt); the gcc binary
# it also builds is not used.
MRUSTC_TARGET_VER=${MRUSTC_TARGET_VER:-1.90} "$mrustc" "$src" -o "$tmp/prog" -L "$std" --edition 2021 ${extra[@]+"${extra[@]}"} >"$tmp/mrustc.log" 2>&1 ||
  { cat "$tmp/mrustc.log" >&2; echo "mrustc-nfcc: mrustc failed" >&2; exit 1; }
[ -f "$tmp/prog.c" ] && [ -f "$tmp/prog_cmd.txt" ] || { echo "mrustc-nfcc: mrustc wrote no C" >&2; exit 1; }
nfcxx_compile "$tmp/prog.c" prog "$tmp"

# libcore, when asked for. Cached: rebuilt when its C file or the rewrite scripts are newer than the object.
core_objs=()
if [ -n "${MRUSTC_NFCC_CORE:-}" ]; then
  [ -f "$std/libcore.rlib.c" ] || { echo "mrustc-nfcc: no libcore.rlib.c in $std" >&2; exit 1; }
  cache=$root/build/mrustc/nfcxx
  mkdir -p "$cache"
  if [ ! -f "$cache/libcore.o" ] || [ "$std/libcore.rlib.c" -nt "$cache/libcore.o" ] \
     || [ "$root/scripts/mrustc-prep.rb" -nt "$cache/libcore.o" ] || [ "$root/scripts/qbe-prep.rb" -nt "$cache/libcore.o" ]; then
    nfcxx_compile "$std/libcore.rlib.c" libcore "$cache"
  fi
  core_objs=("$cache/libcore.o" "$cache/libcore.tail.o")
fi

# The link: the program, its tail, libcore if compiled here, then mrustc's objects for the rest of the standard library
# and the libraries it names, in mrustc's order (without libcore.rlib.o when it is replaced).
std_objs=()
while IFS= read -r t; do
  case $t in */libcore.rlib.o) [ -z "${MRUSTC_NFCC_CORE:-}" ] && std_objs+=("$t") ;; *) std_objs+=("$t") ;; esac
done < <(tr -d '"' < "$tmp/prog_cmd.txt" | tr ' ' '\n' | grep '\.rlib\.o$' || true)
libs=()
while IFS= read -r t; do libs+=("$t"); done < <(tr -d '"' < "$tmp/prog_cmd.txt" | tr ' ' '\n' | awk 'prev == "-l" { print "-l" $0 } { prev = $0 }' || true)
[ ${#std_objs[@]} -gt 0 ] || { echo "mrustc-nfcc: no standard library objects in $tmp/prog_cmd.txt" >&2; exit 1; }
"$root/scripts/qbe-cc" -o "$out" "$tmp/prog.o" "$tmp/prog.tail.o" ${core_objs[@]+"${core_objs[@]}"} \
  ${std_objs[@]+"${std_objs[@]}"} ${libs[@]+"${libs[@]}"}
