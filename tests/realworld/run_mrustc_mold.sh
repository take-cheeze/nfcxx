#!/usr/bin/env bash
# mold 3 (the Rust linker, rui314/mold v3.0.0) built by mrustc's minicargo, then used as the linker of a C program.
# minicargo builds mold-cli for x86_64 only (`--no-default-features --features x86_64`) from a `cargo vendor` of mold's
# lock file, every crate's C through gcc (mrustc's own backend). The binary must report its version and link a program
# that prints the expected output. Needs scripts/setup-mrustc.sh, cargo (cargo vendor) and network access; a cold run
# takes about an hour on 4 cores (mold's two crates are most of it). docs/notes/mrustc-frontend.md, "mold 3".
#   tests/realworld/run_mrustc_mold.sh
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
