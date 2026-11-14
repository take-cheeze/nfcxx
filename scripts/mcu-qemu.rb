#!/usr/bin/env ruby
# Build Espressif's QEMU fork (the esp32c3 machine, hw/riscv/esp32c3.c) at a pinned commit, for tests/mcu/run.sh.
# Mainline QEMU has no esp32c3 machine. Usage: scripts/mcu-qemu.rb DIR
# Leaves the emulator at DIR/build/qemu-system-riscv32; run tests/mcu/run.sh with QEMU_ESP32C3 set to that path.
# Needs meson, ninja, pkg-config, and the glib, pixman, libslirp and libgcrypt development packages. The commit is the
# cache key of .github/workflows/mcu.yml (the key hashes this file), so change it here and only here.
require "fileutils"
$stdout.sync = true
$stderr.sync = true

REV = "febae182e132e4055529be423a818225ebddaa3a"

if ARGV[0].to_s.empty?
  warn "#{$PROGRAM_NAME}: 1: usage: scripts/mcu-qemu.rb DIR"
  exit 1
end

# Run a command; a failure ends the script with its status, as set -e does
def run!(*argv, env: {})
  ok = system(env, [argv[0], argv[0]], *argv[1..])
  st = ok.nil? ? 127 : ($?.exitstatus || 128 + $?.termsig)
  exit st unless st.zero?
end

# Absolute, before the cd below: a relative DIR would make the final check look in the wrong place.
dir = IO.popen(["realpath", "-m", ARGV[0]], &:read).chomp
exit 1 unless $?.success?
out = File.join(dir, "build/qemu-system-riscv32")

FileUtils.mkdir_p(dir)
Dir.chdir(dir)
run!("git", "init", "-q", ".") unless Dir.exist?(".git")
system("git", "remote", "get-url", "origin", out: File::NULL, err: File::NULL) or
  run!("git", "remote", "add", "origin", "https://github.com/espressif/qemu")
run!("git", "fetch", "-q", "--depth", "1", "origin", REV)
run!("git", "checkout", "-q", "FETCH_HEAD")

# Only the riscv32 system emulator; the rest of the fork is not used.
run!("./configure", "--target-list=riscv32-softmmu", "--disable-docs", "--disable-werror", "--disable-user",
     "--disable-tools", "--disable-guest-agent")
run!("ninja", "-C", "build", "qemu-system-riscv32")

# "$out" -M help | grep -q esp32c3 (pipefail: the emulator's failure counts too)
begin
  help_out = IO.popen([out, "-M", "help"], &:read)
  help_ok = $?.success?
rescue SystemCallError
  help_out = ""
  help_ok = false
end
unless help_ok && help_out.include?("esp32c3")
  warn "mcu-qemu: #{out} has no esp32c3 machine"
  exit 1
end
puts "mcu-qemu: #{out}"
