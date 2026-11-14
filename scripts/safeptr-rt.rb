#!/usr/bin/env ruby
# Print the path of the -fsafe-pointers runtime (lib/safeptr/nfcxx_safeptr.c, docs/notes/safe-pointers.md), building it
# first when it is missing or older than its source. The driver links the object ahead of everything else: it defines
# malloc and free, so every heap block of the program (libstdc++'s included) is in its object table.
#   NFCXX_SAFEPTR_DIR=d   where the object is kept (default build/safeptr)
require "fileutils"

root = File.expand_path("..", File.expand_path(File.dirname($0)))
src = "#{root}/lib/safeptr/nfcxx_safeptr.c"
dir = ENV["NFCXX_SAFEPTR_DIR"].to_s.empty? ? "#{root}/build/safeptr" : ENV["NFCXX_SAFEPTR_DIR"]
out = "#{dir}/nfcxx_safeptr.o"
if !File.file?(out) || (File.exist?(src) && File.mtime(src) > File.mtime(out))
  FileUtils.mkdir_p(dir)
  tmp = IO.popen(["mktemp", "-d", "#{dir}/.build.XXXXXX"], &:read).sub(/\n+\z/, "")
  exit($?.exitstatus || 1) unless $?.success?
  at_exit { FileUtils.rm_rf(tmp) }
  # -ftls-model=initial-exec: the checks read thread-local caches on every call; the general-dynamic model -fPIC picks
  # would make each read a call of __tls_get_addr. The runtime is only linked into executables (Path B cannot link a
  # -shared object: its code is not position-independent), where initial-exec is always valid.
  exit 1 unless system("gcc", "-c", "-O2", "-Wall", "-Wextra", "-fPIC", "-ftls-model=initial-exec", "-fno-builtin",
                       "-pthread", src, "-o", "#{tmp}/sp.o")
  File.rename("#{tmp}/sp.o", out)   # atomic: concurrent builds each write their own copy
end
puts out
