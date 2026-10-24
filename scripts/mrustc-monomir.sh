#!/usr/bin/env bash
# Build a Rust program with mrustc and compile the monomir output with nfcxx's monomir route
# (monomir-to-pathb.rb -> pathb-qbe-emit.rb -> QBE; scripts/qbe-cc to link).
# The program's own code and the monomorphised generics it uses go through QBE. The rest of the
# standard library is the one mrustc built with gcc (its rlib objects), linked in unchanged.
# This mirrors scripts/mrustc-nfcc.sh (the C route) with the same arguments and environment.
#   scripts/mrustc-monomir.sh prog.rs -o prog [mrustc flags...]
#   MRUSTC=<bin>      mrustc binary (default build/mrustc/src/bin/mrustc, from scripts/setup-mrustc.sh)
#   MRUSTC_STD=<dir>  directory with the standard library objects (default build/mrustc/src/output-1.90.0)
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
[ -n "$src" ] && [ -n "$out" ] || { echo "usage: scripts/mrustc-monomir.sh prog.rs -o prog [mrustc flags...]" >&2; exit 2; }
case $src in /*) ;; *) src=$start/$src ;; esac
case $out in /*) ;; *) out=$start/$out ;; esac
[ -x "$mrustc" ] && [ -f "$std/libstd.rlib.o" ] || { echo "mrustc-monomir: no mrustc or standard library; run scripts/setup-mrustc.sh" >&2; exit 1; }

tmp=$(mktemp -d)
# MRUSTC_NFCC_KEEP=1 keeps the intermediate files (the mir, the Path B IR, the QBE) for debugging.
[ -n "${MRUSTC_NFCC_KEEP:-}" ] || trap 'rm -rf "$tmp"' EXIT

# The program: mrustc writes the monomir dump (<out>.mir); the binary it also builds is not used.
MRUSTC_TARGET_VER=${MRUSTC_TARGET_VER:-1.90} "$mrustc" "$src" -o "$tmp/prog" -L "$std" --edition 2021 \
  -C codegen-type=monomir ${extra[@]+"${extra[@]}"} >"$tmp/mrustc.log" 2>&1 ||
  { cat "$tmp/mrustc.log" >&2; echo "mrustc-monomir: mrustc failed" >&2; exit 1; }
[ -f "$tmp/prog.mir" ] || { echo "mrustc-monomir: mrustc wrote no mir" >&2; exit 1; }
ruby "$root/scripts/monomir-to-pathb.rb" "$tmp/prog.mir" "$tmp/prog.ir" ||
  { echo "mrustc-monomir: monomir-to-pathb failed" >&2; exit 1; }
"$root/scripts/mrb" "$root/scripts/pathb-qbe-emit.rb" "$tmp/prog.ir" > "$tmp/prog.qbe" ||
  { echo "mrustc-monomir: pathb-qbe-emit failed" >&2; exit 1; }
sed -i 's/__DOLLAR__/$/g' "$tmp/prog.qbe"
"$root/build/qbe/qbe" "$tmp/prog.qbe" -o "$tmp/prog.s" ||
  { echo "mrustc-monomir: qbe failed" >&2; exit 1; }
"$root/scripts/mrb" "$root/scripts/pathb-qbe-emit.rb" --append-weak "$tmp/prog.qbe" "$tmp/prog.s"
as "$tmp/prog.s" -o "$tmp/prog.o" || { echo "mrustc-monomir: as failed" >&2; exit 1; }

# mrustc records the exact crate dependencies in the dump, including non-std crates
# supplied with --extern. Their objects use the same symbols as the monomir output.
crate_objs=()
while IFS= read -r crate; do
  [ -f "$crate" ] || { echo "mrustc-monomir: no crate object $crate" >&2; exit 1; }
  crate_objs+=("$crate")
done < <(ruby -ne 'puts $1 + ".o" if /^crate "(.*)\.mir";$/ =~ $_' "$tmp/prog.mir")
[ ${#crate_objs[@]} -gt 0 ] || { echo "mrustc-monomir: no crate dependencies in mir" >&2; exit 1; }
"$root/scripts/qbe-cc" -o "$out" "$tmp/prog.o" "${crate_objs[@]}" \
  -lutil -lrt -lpthread -lm -ldl -lc -lgcc_s -latomic
