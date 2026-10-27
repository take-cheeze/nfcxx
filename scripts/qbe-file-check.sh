#!/usr/bin/env bash
# qbe-file-check.sh [DIR] [OBJ]: one kernel file's compile through qbe-try, with the kernel's own flags, in seconds (no
# kernel build, no boot). DIR is a linux-qemu build directory (default build/linux-qemu, whose out-nfcc has the flags
# of every object); OBJ is the object's path relative to out-nfcc (default arch/x86/kernel/head64.o). It prints the
# verdict of qbe-try: qbe, or gcc with the reason. The object itself is not kept.
set -euo pipefail
root=$(cd "$(dirname "$0")/.." && pwd)
dir=$(realpath -m "${1:-$root/build/linux-qemu}")
obj=${2:-arch/x86/kernel/head64.o}
out=$dir/out-nfcc
cmdfile=$out/$(dirname "$obj")/.$(basename "$obj").cmd
[ -f "$cmdfile" ] || { echo "qbe-file-check: no compile flags for $obj in $out (build the kernel first)" >&2; exit 2; }
src=$(sed -n '1s/^savedcmd_[^ ]* := //p' "$cmdfile" | tr ' ' '\n' | grep '\.c$' | tail -1)
read -ra w <<< "$(sed -n '1s/^savedcmd_[^ ]* := //p' "$cmdfile" | sed 's/ *; *\.\/tools.*//')"
args=()
for ((i = 1; i < ${#w[@]}; i++)); do
  case ${w[i]} in
    -c|-Wp,-MMD,*|*.c|--hacks=*|--static-call|--uaccess) ;;
    -o) i=$((i+1)) ;;
    *) args+=("${w[i]}") ;;
  esac
done
tmp=$(mktemp -d); trap 'rm -rf "$tmp"' EXIT
(cd "$out" && NFCXX_BACKEND=gcc NFCXX_GCC_PASSTHROUGH=1 NFCXX_QBE_TRY='*' NFCXX_QBE_LOG="$tmp/log" \
  NFCXX_QBE_KSYMS="$dir/kernel-syms.txt" NFCXX_QBE_INITSYMS="$dir/init-syms.txt" \
  "$root/nfcc" "${args[@]}" -c "$src" -o "$tmp/out.o") || true
echo "verdict: $(cat "$tmp/log" 2>/dev/null || echo 'no verdict (the compile failed)')"
