#!/usr/bin/env bash
# mold 3 (the Rust linker, rui314/mold v3.0.0) built by mrustc's minicargo, then used as the linker of a C program.
# minicargo builds mold-cli for x86_64 only (`--no-default-features --features x86_64`) from a `cargo vendor` of mold's
# lock file, every crate's C through gcc (mrustc's own backend). The binary must report its version and link a program
# that prints the expected output. Needs scripts/setup-mrustc.sh, cargo (cargo vendor) and network access; a cold run
# takes about an hour on 4 cores (mold's two crates are most of it). docs/notes/mrustc-frontend.md, "mold 3".
# With --pipeline, mold is then built again with every crate through nfcxx's pipeline (scripts/mrustc-nfcc.sh, cproc
# and QBE, the inline asm outlined; about 7 minutes more, needs scripts/setup-qbe.sh),
# and that binary must link the same program, and a C program with compressed debug sections (zlib, zstd).
#   tests/realworld/run_mrustc_mold.sh [--pipeline]
set -euo pipefail
cd "$(dirname "$0")/../.."
root=$PWD
tag=v3.0.0
pin=8de38c35a2df16a25f7ff87ac3ad07156a925beb   # the commit of v3.0.0
std=$root/build/mrustc/src/output-1.90.0
mrustc_bin=$root/build/mrustc/src/bin
work=$root/build/mrustc/realworld/mold
src=$work/src
out=$work/out

if [ ! -d "$src/.git" ]; then
  rm -rf "$src"; mkdir -p "$work"
  git clone -q --depth 1 --branch "$tag" https://github.com/rui314/mold.git "$src"
fi
[ "$(git -C "$src" rev-parse HEAD)" = "$pin" ] || { echo "FAIL mold: $tag is not $pin" >&2; exit 1; }
[ -d "$work/vendor" ] || (cd "$src" && cargo vendor --locked -q "$work/vendor" > /dev/null)
mkdir -p "$out"
# minicargo looks for core and the other std crates in its output directory, so the library output is copied there.
[ -f "$out/libstd.rlib.o" ] || cp -r "$std/." "$out/"
# minicargo writes mrustc's configuration dump into the working directory, so it runs in the build directory.
if ! (cd "$work" && MRUSTC_TARGET_VER=1.90 "$mrustc_bin/minicargo" "$src/cli" --vendor-dir "$work/vendor" --output-dir "$out" \
      --no-default-features --features x86_64 > "$work/minicargo.log" 2>&1); then
  tail -20 "$work/minicargo.log" >&2
  echo "FAIL mold: minicargo"; exit 1
fi
# mold's build script writes mold-wrapper.so (`mold -run`) beside the first ancestor named `build`, which is the root here.
rm -f "$root/mold-wrapper.so"

bin=$work/bin
mkdir -p "$bin"
ln -sf "$out/mold" "$bin/ld.mold"
"$out/mold" --version | grep -q '^mold 3.0.0 ' || { echo "FAIL mold: --version"; exit 1; }
printf '#include <stdio.h>\n#include <math.h>\nint main(void) { printf("%%.6f\\n", sqrt(2.0)); return 0; }\n' > "$work/hello.c"
PATH=$bin:$PATH cc -fuse-ld=mold "$work/hello.c" -lm -o "$work/hello"
got=$("$work/hello")
readelf -p .comment "$work/hello" | grep -q 'mold 3.0.0' || { echo "FAIL mold: hello was not linked by mold"; exit 1; }
[ "$got" = 1.414214 ] || { echo "FAIL mold: hello printed $got"; exit 1; }
echo "ok   mold 3.0.0 (minicargo, x86_64): links a C program"

[ "${1:-}" = --pipeline ] || exit 0
# The crates of mold's link, as mrustc's link command names their objects (lib<crate>.rlib.o).
crates=$(tr -d '"' < "$out/mold_cmd.txt" | tr ' ' '\n' | grep '\.rlib\.o$' | sed -e 's|.*/lib||' -e 's|\.rlib\.o$||' | tr '\n' ' ')
ext() { local f; f=$(ls "$out"/lib"$1"-*.rlib | head -1); echo "$2=$f"; }
# The binary and the library are both crate `mold`; minicargo tags the binary, as it is passed here when its log
# has the command (a run with nothing to rebuild does not print it, and the tag does not reach the binary's C).
tag=()
tag_bin=$(grep 'cli/main.rs' "$work/minicargo.log" | grep -o -- '--crate-tag [^ ]*' | head -1 | cut -d' ' -f2 || true)
[ -z "$tag_bin" ] || tag=(--crate-tag "$tag_bin")
if ! MRUSTC_NFCC_CRATES="$crates" MRUSTC_STD=$out scripts/mrustc-nfcc.sh "$src/cli/main.rs" -o "$work/mold-nfcc" \
     --edition 2024 --crate-name mold --crate-type bin ${tag[@]+"${tag[@]}"} --cfg debug_assertions -O \
     --cfg 'feature="x86_64"' --cfg 'feature="dep:mold-target-x86_64"' \
     --extern "$(ext mimalloc mimalloc)" --extern "$(ext mold mold)" --extern "$(ext mold_target_x86_64 mold_target_x86_64)" \
     > "$work/nfcc.log" 2>&1; then
  grep -v -E 'deaddead|Assembler messages' "$work/nfcc.log" | tail -20 >&2
  echo "FAIL mold: the pipeline build"; exit 1
fi
nbin=$work/nbin
mkdir -p "$nbin"
ln -sf "$work/mold-nfcc" "$nbin/ld.mold"
"$work/mold-nfcc" --version | grep -q '^mold 3.0.0 ' || { echo "FAIL mold (pipeline): --version"; exit 1; }
for c in none zlib zstd; do
  rm -f "$work/hello-$c"
  PATH=$nbin:$PATH cc -g -fuse-ld=mold -Wl,--compress-debug-sections=$c "$work/hello.c" -lm -o "$work/hello-$c"
  got=$("$work/hello-$c")
  readelf -p .comment "$work/hello-$c" | grep -q 'mold 3.0.0' || { echo "FAIL mold (pipeline): hello-$c was not linked by mold"; exit 1; }
  [ "$got" = 1.414214 ] || { echo "FAIL mold (pipeline): hello-$c printed $got"; exit 1; }
  [ $c = none ] || readelf -t "$work/hello-$c" | grep -A3 '\.debug_info' | grep -q COMPRESSED ||
    { echo "FAIL mold (pipeline): hello-$c has no compressed .debug_info"; exit 1; }
done
echo "ok   mold 3.0.0 (nfcxx pipeline, every crate): links a C program, compressed debug sections"
