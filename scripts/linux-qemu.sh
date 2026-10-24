#!/usr/bin/env bash
# Build a minimal x86_64 Linux kernel (tinyconfig plus a serial console and an initramfs loader) with a static busybox
# as its only userland, and boot it under qemu-system-x86_64. Usage: scripts/linux-qemu.sh [DIR]   (default build/linux-qemu)
# Writes DIR/bzImage, DIR/initramfs.cpio and the guest's console output to DIR/boot.log. Exits 0 when the guest's init
# prints the marker and the guest reboots, which -no-reboot turns into a QEMU exit.
# The kernel is built with the host gcc: the kernel needs GCC, not nfcc. Needs gcc, make, bc, bison, flex, libelf-dev,
# libssl-dev, cpio, curl, qemu-system-x86 and busybox-static (Debian/Ubuntu package names). The kernel is 6.8 from the
# Ubuntu archive, since kernel.org is not reachable from every sandbox; LINUX_URL overrides the tarball (it must unpack
# to linux-6.8/), BUSYBOX the busybox binary.
set -euo pipefail
dir=$(realpath -m "${1:-build/linux-qemu}")
url=${LINUX_URL:-http://archive.ubuntu.com/ubuntu/pool/main/l/linux/linux_6.8.0.orig.tar.gz}
busybox=${BUSYBOX:-$(command -v busybox)}
marker="minimal linux: boot ok"

mkdir -p "$dir/dl"
tarball=$dir/dl/$(basename "$url")
if [ ! -f "$tarball" ]; then
  curl -fL -o "$tarball.part" "$url"
  mv "$tarball.part" "$tarball"
fi
[ -d "$dir/linux-6.8" ] || tar -xzf "$tarball" -C "$dir"

cd "$dir/linux-6.8"
make -s ARCH=x86_64 tinyconfig
# Only what the boot path needs: a serial console for the output, the initramfs loader, and proc, sysfs and devtmpfs
# for init. Everything else stays off, which is what keeps the image small.
scripts/config --enable 64BIT --enable PRINTK --enable TTY \
  --enable SERIAL_CORE --enable SERIAL_8250 --enable SERIAL_8250_CONSOLE \
  --enable BLK_DEV_INITRD --enable BINFMT_ELF --enable BINFMT_SCRIPT \
  --enable PROC_FS --enable SYSFS --enable TMPFS \
  --enable DEVTMPFS --enable DEVTMPFS_MOUNT --enable MULTIUSER
make -s ARCH=x86_64 olddefconfig
make -s ARCH=x86_64 -j"$(nproc)" bzImage
cp arch/x86/boot/bzImage "$dir/bzImage"

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
log=$dir/boot.log
set +e
timeout 300 qemu-system-x86_64 -accel "$accel" -m 256 -nographic -no-reboot \
  -kernel "$dir/bzImage" -initrd "$dir/initramfs.cpio" -append "console=ttyS0 panic=-1" > "$log" 2>&1
status=$?
set -e
cat "$log"
if [ "$status" -eq 0 ] && grep -qF "$marker" "$log"; then
  echo "linux-qemu: booted ($accel), kernel $dir/bzImage"
else
  echo "linux-qemu: guest did not reach the marker (qemu exit $status), see $log" >&2
  exit 1
fi
