#!/usr/bin/env bash
# Real-world check: SDCC 4.6.0 (GPL-2.0-or-later) compiled by nfcc. The release tarball is fetched from SourceForge and
# checked against its SHA-256; it is unpacked into build/realworld/sdcc, not vendored.
#   1. Configure with the host compiler for the mcs51 port only (the others are excluded to keep the build short), and
#      build the reference compiler, src/sdcc, with gcc.
#   2. Rebuild src/sdcc from the same sources with nfcc (gcc backend). The bundled gcc libcpp (support/cpp) is not
#      built by nfcc: its configure rejects nfcc's probes. The preprocessor sdcpp is the host build, found on PATH.
#   3. Compile every support/regression/tests/*.c that the reference accepts for -mmcs51 with both compilers, and
#      compare the assembly byte for byte.
#   NFCXX_BACKEND=gcc|qbe   (default: both)
cd "$(dirname "$0")/../.."
root=$PWD; work=$root/build/realworld
ver=4.6.0
url="https://downloads.sourceforge.net/project/sdcc/sdcc/$ver/sdcc-src-$ver.tar.bz2"
sum=5fd6a93e5997ce01756868fe35e441095cfb637894a80c262514a634094973b6   # sdcc-src-4.6.0.tar.bz2
src=$work/sdcc
mkdir -p "$work"
if [ ! -f "$src/configure" ]; then
  tar_file=$work/sdcc-src-$ver.tar.bz2
  if [ ! -f "$tar_file" ] || [ "$(sha256sum "$tar_file" | cut -d' ' -f1)" != "$sum" ]; then
    curl -sSL -o "$tar_file" "$url" || { echo "SKIP sdcc: download failed"; exit 0; }
  fi
  if [ "$(sha256sum "$tar_file" | cut -d' ' -f1)" != "$sum" ]; then
    echo "FAIL sdcc: $tar_file does not match its SHA-256"; exit 1
  fi
  rm -rf "$src" && mkdir -p "$src" && tar -xjf "$tar_file" -C "$src" --strip-components=1 || exit 1
fi

jobs=${SDCC_JOBS:-4}
fail=0
cd "$src" || exit 1
if [ ! -f Makefile ]; then
  ./configure CC=gcc CXX=g++ --disable-doc --disable-ucsim --disable-sdcc-ucsim \
    --disable-z80-port --disable-z180-port --disable-r2k-port --disable-r2ka-port --disable-r3ka-port \
    --disable-r4k-port --disable-r5k-port --disable-r6k-port --disable-sm83-port --disable-tlcs90-port \
    --disable-ez80-port --disable-z80n-port --disable-r800-port --disable-ds390-port --disable-ds400-port \
    --disable-pic14-port --disable-pic16-port --disable-hc08-port --disable-s08-port --disable-stm8-port \
    --disable-pdk13-port --disable-pdk14-port --disable-pdk15-port --disable-mos6502-port \
    --disable-mos65c02-port --disable-f8-port --disable-f8l-port > "$work/sdcc-configure.log" 2>&1 ||
    { echo "FAIL sdcc: configure"; tail -5 "$work/sdcc-configure.log"; exit 1; }
fi
if ! make -j"$jobs" > "$work/sdcc-ref-build.log" 2>&1; then
  echo "FAIL sdcc: reference build with gcc"; grep -m5 -E "error|Error" "$work/sdcc-ref-build.log"; exit 1
fi
# The driver finds its preprocessor by its own name (sdcc -> sdcpp), so the copy keeps the name sdcc.
ref=$work/sdcc-ref/sdcc
mkdir -p "$(dirname "$ref")" && cp src/sdcc "$ref" || exit 1

# Compare the assembly. The preprocessor is the host build in support/cpp/gcc (see above).
base_path=$PATH
export PATH=$src/support/cpp/gcc:$src/bin:$PATH
export SDCC_HOME=$src
tests=$src/support/regression/tests
fwk=$src/support/regression/fwk/include
dev=$src/device/include
out=$(mktemp -d); trap 'rm -rf "$out"' EXIT
compare_one() {
  # $nfc: the nfcc-built compiler of the back end being checked; the variables are exported before the call.
  f=$1; b=$(basename "$f" .c)
  if ! timeout 120 "$ref" -mmcs51 --std-c99 -I"$fwk" -I"$dev" -S -o "$out/h-$b.asm" "$f" > /dev/null 2>&1; then
    echo "skip $b (reference rejects it)"; return 0
  fi
  if ! timeout 120 "$nfc" -mmcs51 --std-c99 -I"$fwk" -I"$dev" -S -o "$out/n-$b.asm" "$f" > "$out/n-$b.log" 2>&1; then
    echo "FAIL nfcc rejects $b"; return 1
  fi
  if cmp -s "$out/h-$b.asm" "$out/n-$b.asm"; then echo "same $b"; return 0; fi
  echo "FAIL assembly differs: $b"; return 1
}
export -f compare_one
export ref nfc fwk dev out
# Every test the reference accepts for mcs51, in name order (the list is fixed, so a run is repeatable).
backends=${NFCXX_BACKEND:-"gcc qbe"}
for b in $backends; do
  # The nfcc build: the compiler proper (src/), objects from scratch, on this back end.
  make -C src clean > /dev/null 2>&1
  # The build uses the original PATH: the support/cpp/gcc wrappers (as, cpp) are for the comparison below.
  if ! PATH=$base_path NFCXX_BACKEND=$b make -C src -j"$jobs" sdcc CC="$root/nfcc" > "$work/sdcc-nfcc-$b.log" 2>&1; then
    echo "FAIL $b sdcc: nfcc build of src/sdcc"; grep -m5 -E "error|Error" "$work/sdcc-nfcc-$b.log"; fail=1; continue
  fi
  export nfc=$src/src/sdcc
  results=$(ls "$tests"/*.c | xargs -P"$jobs" -I{} bash -c 'compare_one "$@"' _ {})
  same=$(grep -c '^same ' <<<"$results"); skip=$(grep -c '^skip ' <<<"$results"); bad=$(grep -c '^FAIL ' <<<"$results")
  grep '^FAIL ' <<<"$results" | head -20
  echo "$b sdcc mcs51: $same compared identical, $skip skipped (reference rejects), $bad differ or fail"
  if [ "$bad" -ne 0 ] || [ "$same" -eq 0 ]; then fail=1; fi
done
exit $fail
