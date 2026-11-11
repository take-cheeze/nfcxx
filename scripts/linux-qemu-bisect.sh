#!/usr/bin/env bash
# After `KCC=nfcc QBE_TRY='*' scripts/linux-qemu.sh` builds a kernel that does not boot: find the objects from the qbe
# backend that break it, without compiling anything. Every moved object ("qbe SRC" in DIR/qbe-try.log) has a gcc twin
# in DIR/out-nfcc (a KCC=nfcc build, the gcc backend, same configuration); a set of them is put back, the kernel is
# linked again and booted, and the set is halved until one object is left -- then that object stays gcc and the
# search goes on, until the kernel boots. Prints each culprit; DIR/out-nfcc-qbe is left as it was (qbe objects).
#   DIR=build/linux-qemu (the default)
set -euo pipefail
root=$(cd "$(dirname "$0")/.." && pwd)
dir=${DIR:-$root/build/linux-qemu}
q=$dir/out-nfcc-qbe g=$dir/out-nfcc src=$dir/src/linux-6.8
work=$(mktemp -d); trap 'rm -rf "$work"' EXIT
[ -f "$dir/qbe-try.log" ] && [ -d "$g" ] || { echo "linux-qemu-bisect: needs $dir/qbe-try.log and the gcc build $g" >&2; exit 2; }
grep '^qbe ' "$dir/qbe-try.log" | awk '{print $2}' | sed "s|^$src/||; s/\\.c\$/.o/" > "$work/moved"
while read -r o; do [ -f "$q/$o.qbe" ] || cp "$q/$o" "$q/$o.qbe"; done < "$work/moved"

# boot LIST: the objects in LIST from qbe, the other moved ones from gcc; GOOD when the guest reaches the marker
boot() {
  local o
  declare -A keep=()
  while read -r o; do keep[$o]=1; done < "$1"
  while read -r o; do
    if [ -n "${keep[$o]:-}" ]; then cp "$q/$o.qbe" "$q/$o"; else cp "$g/$o" "$q/$o"; fi
    touch "$q/$o"
  done < "$work/moved"
  NFCXX_BACKEND=gcc NFCXX_GCC_PASSTHROUGH=1 make -C "$src" O="$q" ARCH=x86_64 CC="$root/nfcc" -s -j"$(nproc)" bzImage \
    > "$work/make.log" 2>&1 || { echo MAKEFAIL; return; }
  timeout 150 qemu-system-x86_64 -accel tcg -m 256 -nographic -no-reboot -kernel "$q/arch/x86/boot/bzImage" \
    -initrd "$dir/initramfs.cpio" -append "console=ttyS0 panic=-1" > "$work/boot.log" 2>&1 || true
  if grep -qF "minimal linux: boot ok" "$work/boot.log"; then echo GOOD; else echo BAD; fi
}

cp "$work/moved" "$work/suspects"
: > "$work/culprits"
[ "$(boot "$work/suspects")" = BAD ] || { echo "linux-qemu-bisect: the kernel boots with every moved object"; exit 0; }
while :; do
  cp "$work/suspects" "$work/cur"
  while [ "$(wc -l < "$work/cur")" -gt 1 ]; do
    n=$(wc -l < "$work/cur")
    head -n $((n / 2)) "$work/cur" > "$work/a"; tail -n +$((n / 2 + 1)) "$work/cur" > "$work/b"
    if [ "$(boot "$work/a")" = BAD ]; then cp "$work/a" "$work/cur"
    elif [ "$(boot "$work/b")" = BAD ]; then cp "$work/b" "$work/cur"
    else echo "linux-qemu-bisect: $n objects break the boot only together:"; cat "$work/cur"; break 2; fi
  done
  cat "$work/cur" | tee -a "$work/culprits"
  grep -vxF -f "$work/culprits" "$work/moved" > "$work/suspects"
  [ "$(boot "$work/suspects")" = BAD ] || break
done
while read -r o; do cp "$q/$o.qbe" "$q/$o"; touch "$q/$o"; done < "$work/moved"
