#!/usr/bin/env bash
# Build a minimal x86_64 Linux kernel (tinyconfig plus a serial console and an initramfs loader) with a static busybox
# as its only userland, and boot it under qemu-system-x86_64. Usage: [KCC=gcc|nfcc] scripts/linux-qemu.sh [DIR]
# (default build/linux-qemu). Writes DIR/bzImage-$KCC, DIR/initramfs.cpio and the guest's console output to
# DIR/boot-$KCC.log. Exits 0 when the guest's init prints the marker and the guest reboots, which -no-reboot turns into
# a QEMU exit.
#   KCC=gcc   (default) the host gcc builds the kernel.
#   KCC=nfcc  nfcc builds every C file (CC=nfcc): its gcc backend with NFCXX_GCC_PASSTHROUGH=1, so the kernel's codegen
#             options (-mcmodel=kernel, -mno-red-zone, -mno-sse, ...) reach gcc. The boot banner must then name nfcc.
#             This is the starting point for moving files to the qbe backend (docs/notes/linux-kernel.md).
#   QBE_TRY="PATTERN ..."  with KCC=nfcc: try each matching C file on the qbe backend too, and keep the qbe object when
#             it matches the gcc one (scripts/qbe-try); '*' tries every file. The build goes to DIR/out-nfcc-qbe, and
#             DIR/qbe-try.log says, file by file, which backend's object is in the kernel and why.
# Needs gcc, make, bc, bison, flex, libelf-dev, libssl-dev, cpio, curl, qemu-system-x86 and busybox-static
# (Debian/Ubuntu package names). The kernel is 6.8 from the Ubuntu archive, since kernel.org is not reachable from
# every sandbox; LINUX_URL overrides the tarball (it must unpack to linux-6.8/), BUSYBOX the busybox binary.
set -euo pipefail
nfcxx=$(cd "$(dirname "$0")/.." && pwd)
dir=$(realpath -m "${1:-build/linux-qemu}")
url=${LINUX_URL:-http://archive.ubuntu.com/ubuntu/pool/main/l/linux/linux_6.8.0.orig.tar.gz}
busybox=${BUSYBOX:-$(command -v busybox)}
kcc=${KCC:-gcc}
marker="minimal linux: boot ok"

case $kcc in
  gcc)  cc=gcc ;;
  nfcc) cc=$nfcxx/nfcc; export NFCXX_BACKEND=gcc NFCXX_GCC_PASSTHROUGH=1 ;;
  *) echo "linux-qemu: KCC must be gcc or nfcc, not '$kcc'" >&2; exit 2 ;;
esac

mkdir -p "$dir/dl" "$dir/src"
tarball=$dir/dl/$(basename "$url")
if [ ! -f "$tarball" ]; then
  curl -fL -o "$tarball.part" "$url"
  mv "$tarball.part" "$tarball"
fi
[ -d "$dir/src/linux-6.8" ] || tar -xzf "$tarball" -C "$dir/src"

# One pristine source tree, an output tree per compiler (O=), so the gcc and nfcc builds do not mix.
src=$dir/src/linux-6.8 out=$dir/out-$kcc
tag=$kcc
if [ -n "${QBE_TRY:-}" ]; then
  [ "$kcc" = nfcc ] || { echo "linux-qemu: QBE_TRY needs KCC=nfcc" >&2; exit 2; }
  tag=nfcc-qbe out=$dir/out-nfcc-qbe
  export NFCXX_QBE_TRY=$QBE_TRY NFCXX_QBE_LOG=$dir/qbe-try.log
  rm -f "$NFCXX_QBE_LOG"
  # the symbols a gcc-built kernel defines in init sections (.init.*, .exit.*, .meminit.*): qbe-try refuses a qbe
  # object whose lasting code references one of them where gcc's object does not (the kernel's modpost would refuse
  # the link); without a gcc-built vmlinux.o it takes every undefined symbol for one
  for ref in "$dir/out-nfcc/vmlinux.o" "$dir/out-gcc/vmlinux.o"; do
    [ -f "$ref" ] || continue
    { readelf -SW "$ref"; echo "@@SYMS"; readelf -sW "$ref"; } | awk '
      /^@@SYMS/ { syms = 1; next }
      !syms && /^ *\[ *[0-9]+\]/ { line = $0; sub(/^ *\[ */, "", line); split(line, f, /[] ]+/); sec[f[1]] = f[2]; next }
      syms && $1 ~ /^[0-9]+:$/ && NF >= 8 && sec[$7] ~ /^\.(init|exit|meminit|memexit)(\.|$)/ { print $8 }' |
      sort -u > "$dir/init-syms.txt"
    export NFCXX_QBE_INITSYMS=$dir/init-syms.txt
    # and the symbols it defines for other objects (global or weak), with those of the libraries the final link takes
    # members from (memset is in arch/x86/lib/lib.a): a qbe object may call one where gcc's inlined it away (memset,
    # memcpy, __kmalloc) -- the link has it
    nm -g --defined-only "$ref" $(ls "${ref%/vmlinux.o}"/lib/lib.a "${ref%/vmlinux.o}"/arch/x86/lib/lib.a 2>/dev/null) 2>/dev/null |
      awk 'NF == 3 { print $3 }' | sort -u > "$dir/kernel-syms.txt"
    export NFCXX_QBE_KSYMS=$dir/kernel-syms.txt
    break
  done
  rm -rf "$out"   # every object must go through qbe-try, so nothing is reused from an earlier build
fi
kmake() { make -C "$src" O="$out" ARCH=x86_64 CC="$cc" "$@"; }
mkdir -p "$out"
kmake -s tinyconfig
# Only what the boot path needs: a serial console for the output, the initramfs loader, and proc, sysfs and devtmpfs
# for init. Everything else stays off, which is what keeps the image small.
"$src/scripts/config" --file "$out/.config" --enable 64BIT --enable PRINTK --enable TTY \
  --enable SERIAL_CORE --enable SERIAL_8250 --enable SERIAL_8250_CONSOLE \
  --enable BLK_DEV_INITRD --enable BINFMT_ELF --enable BINFMT_SCRIPT \
  --enable PROC_FS --enable SYSFS --enable TMPFS \
  --enable DEVTMPFS --enable DEVTMPFS_MOUNT --enable MULTIUSER
kmake -s olddefconfig
kmake -s -j"$(nproc)" bzImage
cp "$out/arch/x86/boot/bzImage" "$dir/bzImage-$tag"

# The initramfs is busybox plus one /init script; busybox --install creates the applet links the script uses.
root=$dir/initramfs
rm -rf "$root"
mkdir -p "$root/bin" "$root/proc" "$root/sys" "$root/dev"
cp "$busybox" "$root/bin/busybox"
cat > "$root/init" <<EOF
#!/bin/busybox sh
/bin/busybox --install -s /bin
mount -t proc proc /proc
mount -t sysfs sysfs /sys
echo "$marker"
uname -a
reboot -f
EOF
chmod +x "$root/init"
(cd "$root" && find . | cpio -o -H newc --owner=0:0 --quiet) > "$dir/initramfs.cpio"

accel=tcg
[ -w /dev/kvm ] && accel=kvm
log=$dir/boot-$tag.log
set +e
timeout 300 qemu-system-x86_64 -accel "$accel" -m 256 -nographic -no-reboot \
  -kernel "$dir/bzImage-$tag" -initrd "$dir/initramfs.cpio" -append "console=ttyS0 panic=-1" > "$log" 2>&1
status=$?
set -e
cat "$log"
if [ "$status" -ne 0 ] || ! grep -qF "$marker" "$log"; then
  echo "linux-qemu: guest did not reach the marker (qemu exit $status), see $log" >&2
  exit 1
fi
# The banner names the compiler that built the kernel (scripts/cc-version.sh asked it for --version).
if [ "$kcc" = nfcc ] && ! grep -q "Linux version .*(nfcc " "$log"; then
  echo "linux-qemu: the kernel booted but its banner does not name nfcc, see $log" >&2
  exit 1
fi
if [ -n "${QBE_TRY:-}" ]; then
  echo "linux-qemu: $(grep -c '^qbe ' "$NFCXX_QBE_LOG") of $(wc -l < "$NFCXX_QBE_LOG") C files tried are in the kernel from the qbe backend ($NFCXX_QBE_LOG)"
fi
echo "linux-qemu: booted ($accel, KCC=$kcc${QBE_TRY:+, QBE_TRY}), kernel $dir/bzImage-$tag"
