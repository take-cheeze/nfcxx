#!/usr/bin/env ruby
# C compiler for the macOS arm64 cross C++ link (scripts/macos-cxx-link.rb): clang for arm64-apple-darwin against the
# clean-room headers in NFCXX_MACOS_SYSROOT, which emits Mach-O objects. It is EDG_C_TO_OBJ_COMPILER (NFCXX_CC) for the
# compile of the prelinker's template instances. Options that only gcc takes are dropped here.
$stdout.sync = true
$stderr.sync = true

sysroot = ENV["NFCXX_MACOS_SYSROOT"].to_s
if sysroot.empty?
  warn "#{$PROGRAM_NAME}: line 6: NFCXX_MACOS_SYSROOT: set NFCXX_MACOS_SYSROOT to the clean-room include directory"
  exit 1
end

DROPPED = %w[-fkeep-static-functions -fwrapv -fno-strict-aliasing -fgnu89-inline].freeze
args = ARGV.reject { |a| DROPPED.include?(a) }

# The front end emits the standard streams as extern globals named stdin, stdout and stderr; Darwin's libc names them
# __stdinp and friends (the stdio.h macros in the clean-room headers do the same).
resource = begin
  `clang -print-resource-dir`.sub(/\n+\z/, "")
rescue SystemCallError
  ""
end

argv = ["clang", "--target=arm64-apple-darwin", "-nostdinc", "-isystem", sysroot,
        "-isystem", "#{resource}/include", "-Dstdin=__stdinp", "-Dstdout=__stdoutp", "-Dstderr=__stderrp", *args]
begin
  Kernel.exec([argv[0], argv[0]], *argv[1..])
rescue SystemCallError => e
  warn "clang: #{e.message}"
  exit 127
end
