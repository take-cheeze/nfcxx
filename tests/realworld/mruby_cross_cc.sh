#!/usr/bin/env bash
# CC and LD for mruby's cross build (cross_macos.sh mruby). "-c x.c -o x.o" compiles with qbe-cc to arm64 Darwin assembly
# and assembles it with llvm-mc. A link line goes to ld64.lld against the clean-room libSystem stub. Flags that only
# matter to a host build (dependency files, optimisation, warnings, PIC) are dropped, as qbe-cc drops them.
# Needs the environment of build/cross-macos.env (NFCXX_MACOS_CLEANROOM, NFCXX_MACOS_SYSROOT) and MRUBY_CROSS_ROOT.
set -euo pipefail
root=${MRUBY_CROSS_ROOT:?set MRUBY_CROSS_ROOT to the repository root}
# rake's variables must not reach qbe-cc: its mruby tool build (scripts/setup-mruby.sh) reads MRUBY_CONFIG and MRUBY_BUILD_DIR
unset MRUBY_CONFIG MRUBY_BUILD_DIR MRUBY_CC MRUBY_LD
# the LLVM 18 tools (ld64.lld) are under /usr/lib/llvm-18/bin on the Linux host, not on PATH
[ -d /usr/lib/llvm-18/bin ] && PATH=/usr/lib/llvm-18/bin:$PATH
mode=link; src=""; out=""; objs=(); fl=(); tmp=$(mktemp -d); trap 'rm -rf "$tmp"' EXIT
args=("$@")
for ((i = 0; i < ${#args[@]}; i++)); do
  a=${args[i]}
  case $a in
    -c) mode=compile ;;
    -E) mode=preprocess ;;
    -o) out=${args[++i]} ;;
    -MF|-MT|-MQ) i=$((i + 1)) ;;
    -M*|-g*|-O*|-w|-W*|-f*|-pipe|-m*|-pthread|-l*|-L*) ;;
    -D?*|-I?*|-U?*|-std=*) fl+=("$a") ;;
    -D|-I|-U) fl+=("$a" "${args[++i]}") ;;
    *.c) src=$a ;;
    *.o|*.a) objs+=("$a") ;;
    *) ;;
  esac
done
if [ "$mode" = preprocess ]; then
  # mruby's presym scan reads the preprocessed text for symbol names; the host preprocessor gives the same text here
  [ -n "$src" ] && [ -n "$out" ] || { echo "mruby_cross_cc: preprocess needs a .c input and -o" >&2; exit 2; }
  cc -E ${fl[@]+"${fl[@]}"} "$src" -o "$out"
elif [ "$mode" = compile ]; then
  [ -n "$src" ] && [ -n "$out" ] || { echo "mruby_cross_cc: compile needs a .c input and -o" >&2; exit 2; }
  NFCXX_C_INPUT=1 "$root/scripts/qbe-cc" -S "$src" -o "$tmp/x.s" ${fl[@]+"${fl[@]}"} >/dev/null
  llvm-mc -triple=arm64-apple-darwin -filetype=obj "$tmp/x.s" -o "$out"
else
  [ -n "$out" ] || { echo "mruby_cross_cc: link needs -o" >&2; exit 2; }
  ld64.lld -arch arm64 -platform_version macos 11.0 11.0 -o "$out" ${objs[@]+"${objs[@]}"} \
    -L "$root/tests/macos-sysroot/lib" -lSystem
fi
