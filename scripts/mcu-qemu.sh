#!/usr/bin/env bash
# Build Espressif's QEMU fork (the esp32c3 machine, hw/riscv/esp32c3.c) at a pinned commit, for tests/mcu/run.sh.
# Mainline QEMU has no esp32c3 machine. Usage: scripts/mcu-qemu.sh DIR
# Leaves the emulator at DIR/build/qemu-system-riscv32; run tests/mcu/run.sh with QEMU_ESP32C3 set to that path.
# Needs meson, ninja, pkg-config, and the glib, pixman, libslirp and libgcrypt development packages. The commit is the
# cache key of .github/workflows/mcu.yml (the key hashes this file), so change it here and only here.
set -euo pipefail
rev=febae182e132e4055529be423a818225ebddaa3a
# Absolute, before the cd below: a relative DIR would make the final check look in the wrong place.
dir=$(realpath -m "${1:?usage: scripts/mcu-qemu.sh DIR}")
out=$dir/build/qemu-system-riscv32

mkdir -p "$dir"
cd "$dir"
[ -d .git ] || git init -q .
git remote get-url origin >/dev/null 2>&1 || git remote add origin https://github.com/espressif/qemu
git fetch -q --depth 1 origin "$rev"
git checkout -q FETCH_HEAD

# Only the riscv32 system emulator; the rest of the fork is not used.
./configure --target-list=riscv32-softmmu --disable-docs --disable-werror --disable-user --disable-tools \
  --disable-guest-agent
ninja -C build qemu-system-riscv32

"$out" -M help | grep -q esp32c3 || { echo "mcu-qemu: $out has no esp32c3 machine" >&2; exit 1; }
echo "mcu-qemu: $out"
