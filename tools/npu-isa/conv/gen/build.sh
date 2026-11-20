#!/bin/sh
# build.sh <kernel.ll> <carrier.blob> <out.blob> [entry]
# Compiles/assembles/links the typed LLVM IR with MoviTools (wine), extracts .text from the ELF,
# and patches it into the carrier blob's shave.text slot.
set -e
LL="$1"; CAR="$2"; OUT="$3"; ENTRY="${4:-generated_0}"
W="$HOME/.wine-movi/drive_c/movi"
N="$(basename "$LL")"
cp "$LL" "$W/kern/$N"
rm -f "$W/host/out/shave_main.elf"
WINEPREFIX=$HOME/.wine-movi WINEDEBUG=-all wine 'C:\movi\host\movitest.exe' 'C:\movi\MVC_DEPEND' 'C:\movi\host\out' \
  'C:\movi\host\shave_kernel.ld' "C:\\movi\\kern\\$N" "$ENTRY" ${TARGET:-5000xx} ir
python3 "$HOME/ov-eval/mkext.py" "$W/host/out/shave_main.elf" "$W/host/out/text.bin"
python3 "$HOME/ov-eval/patch_raw.py" "$CAR" "$W/host/out/text.bin" "$OUT"
