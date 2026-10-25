#!/usr/bin/env bash
# Build a Rust program with mrustc, and compile the C it emits with nfcxx's C pipeline (cproc -> QBE; scripts/qbe-cc).
# The program's own code and the monomorphised generics it uses go through QBE. Any other crate of the standard library is the
# one mrustc built with gcc (its rlib objects), linked in unchanged, unless MRUSTC_NFCC_CRATES (or MRUSTC_NFCC_CORE)
# names it: those are compiled through the same pipeline (cached in build/mrustc/nfcxx). See docs/notes/mrustc-frontend.md.
#   scripts/mrustc-nfcc.sh prog.rs -o prog [mrustc flags...]
#   MRUSTC=<bin>      mrustc binary (default build/mrustc/src/bin/mrustc, from scripts/setup-mrustc.sh)
#   MRUSTC_STD=<dir>  directory with the standard library objects (default build/mrustc/src/output-1.90.0)
#   MRUSTC_NFCC_CORE=1  compile libcore (MRUSTC_STD's libcore.rlib.c) through nfcxx's pipeline instead of linking gcc's
#   MRUSTC_NFCC_CRATES="core alloc std" (or all) compile those crates the same way (all: every rlib of the link command)
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
  "$root/scripts/mrb" "$root/scripts/mrustc-prep.rb" "$tmp/$name.pp.c" "$tmp/$name.prep.c" "$tmp/$name.tail.s" "$tmp/$name.weak" \
    "$tmp/$name.asm.c"
  NFCXX_C_INPUT=1 "$root/scripts/qbe-cc" -c "$tmp/$name.prep.c" -o "$dir/$name.o"
  if [ -s "$tmp/$name.weak" ]; then
    objcopy --weaken-symbols="$tmp/$name.weak" "$dir/$name.o" "$tmp/$name.weakened.o"
    mv "$tmp/$name.weakened.o" "$dir/$name.o"
  fi
  # The inline asm that mrustc-prep.rb outlined (helpers around each asm statement, which cproc cannot compile) is
  # built by the host C compiler and joined to the tail object.
  if [ -s "$tmp/$name.asm.c" ]; then
    cc -c "$tmp/$name.tail.s" -o "$tmp/$name.tail0.o"
    cc -O1 -c "$tmp/$name.asm.c" -o "$tmp/$name.asm.o"
    ld -r "$tmp/$name.tail0.o" "$tmp/$name.asm.o" -o "$dir/$name.tail.o"
  else
    cc -c "$tmp/$name.tail.s" -o "$dir/$name.tail.o"
  fi
}

# The program: mrustc writes the C (<out>.c) and the gcc command line that links it (<out>_cmd.txt); the gcc binary
# it also builds is not used.
MRUSTC_TARGET_VER=${MRUSTC_TARGET_VER:-1.90} "$mrustc" "$src" -o "$tmp/prog" -L "$std" --edition 2021 ${extra[@]+"${extra[@]}"} >"$tmp/mrustc.log" 2>&1 ||
  { cat "$tmp/mrustc.log" >&2; echo "mrustc-nfcc: mrustc failed" >&2; exit 1; }
[ -f "$tmp/prog.c" ] && [ -f "$tmp/prog_cmd.txt" ] || { echo "mrustc-nfcc: mrustc wrote no C" >&2; exit 1; }
nfcxx_compile "$tmp/prog.c" prog "$tmp"

# The crates to compile through nfcxx: MRUSTC_NFCC_CRATES (a list of core, alloc, std), and core also for
# MRUSTC_NFCC_CORE=1. Each is cached in build/mrustc/nfcxx and rebuilt when its C file or the rewrite scripts are newer.
crates=${MRUSTC_NFCC_CRATES:-}
[ -n "${MRUSTC_NFCC_CORE:-}" ] && crates="core $crates"
# `all`: every rlib of mrustc's link command (the names keep their hashes, e.g. compiler_builtins-0_1_160_Ha2).
if [ "$crates" = all ]; then
  crates=$(tr -d '"' < "$tmp/prog_cmd.txt" | tr ' ' '\n' | grep '\.rlib\.o$' | sed -e 's|.*/lib||' -e 's|\.rlib\.o$||' | tr '\n' ' ')
fi
cache=$root/build/mrustc/nfcxx
# The objects also depend on cproc and QBE: a cache made by other binaries is emptied. The binaries' hash is kept, not
# their times, since scripts/setup-qbe.sh rebuilds them (to the same bytes) on every run.
if [ -n "$crates" ]; then
  mkdir -p "$cache"
  stamp=$(cat "${CPROC_QBE:-$root/build/cproc/cproc-qbe}" "${QBE:-$root/build/qbe/qbe}" | sha256sum | cut -d' ' -f1)
  if [ "$(cat "$cache/toolchain.sha256" 2>/dev/null)" != "$stamp" ]; then
    rm -f "$cache"/*.o
    echo "$stamp" > "$cache/toolchain.sha256"
  fi
fi
core_objs=()
for crate in $crates; do
  c=$std/lib$crate.rlib.c
  [ -f "$c" ] || { echo "mrustc-nfcc: no lib$crate.rlib.c in $std" >&2; exit 1; }
  mkdir -p "$cache"
  if [ ! -f "$cache/$crate.o" ] || [ "$c" -nt "$cache/$crate.o" ] \
     || [ "$root/scripts/mrustc-prep.rb" -nt "$cache/$crate.o" ] || [ "$root/scripts/qbe-prep.rb" -nt "$cache/$crate.o" ]; then
    nfcxx_compile "$c" "$crate" "$cache"
  fi
  core_objs+=("$cache/$crate.o" "$cache/$crate.tail.o")
done

# The link: the program, its tail, the crates compiled here, then mrustc's objects for the rest of the standard library
# and the libraries it names, in mrustc's order (without the rlib objects of the crates replaced).
std_objs=()
while IFS= read -r t; do
  base=${t##*/}
  replaced=""
  for crate in $crates; do [ "$base" = "lib$crate.rlib.o" ] && replaced=1; done
  [ -z "$replaced" ] && std_objs+=("$t")
done < <(tr -d '"' < "$tmp/prog_cmd.txt" | tr ' ' '\n' | grep '\.rlib\.o$' || true)
# The libraries: `-l NAME`, `-L DIR`, and the native archives that build scripts made (blake3's assembly, zstd and
# mimalloc's C in mold 3), which mrustc names by path. The rlib objects' functions call into them through weak
# trampolines (section "Trampolines have weak targets" of docs/notes/mrustc-frontend.md), so a missing archive is
# not a link error but a call to address 0. A weak reference does not pull a member out of an archive either, so
# each archive symbol that the objects built here reference weakly is made undefined (-u) for the link. For the same
# reason a shared library is linked whether or not a strong reference needs it (--no-as-needed): mold 3 calls
# libz only through weak trampolines, and with --as-needed libz.so was not a dependency.
libs=()
while IFS= read -r t; do libs+=("$t"); done < <(tr -d '"' < "$tmp/prog_cmd.txt" | tr ' ' '\n' |
  awk 'prev == "-l" || prev == "-L" { print prev $0 } /\.a$/ && prev != "-o" { print } { prev = $0 }' || true)
archives=()
for t in ${libs[@]+"${libs[@]}"}; do case $t in *.a) archives+=("$t") ;; esac; done
if [ ${#archives[@]} -gt 0 ]; then
  while IFS= read -r s; do libs=("-Wl,-u,$s" "${libs[@]}"); done < <(
    comm -12 <(nm "$tmp/prog.o" "$tmp/prog.tail.o" ${core_objs[@]+"${core_objs[@]}"} 2>/dev/null | awk '$1 == "w" { print $2 }' | sort -u) \
             <(nm --defined-only -g "${archives[@]}" 2>/dev/null | awk 'NF == 3 { print $3 }' | sort -u))
fi
[ ${#libs[@]} -eq 0 ] || libs=(-Wl,--push-state,--no-as-needed "${libs[@]}" -Wl,--pop-state)
grep -q '\.rlib\.o' "$tmp/prog_cmd.txt" || { echo "mrustc-nfcc: no standard library objects in $tmp/prog_cmd.txt" >&2; exit 1; }
"$root/scripts/qbe-cc" -o "$out" "$tmp/prog.o" "$tmp/prog.tail.o" ${core_objs[@]+"${core_objs[@]}"} \
  ${std_objs[@]+"${std_objs[@]}"} ${libs[@]+"${libs[@]}"}
