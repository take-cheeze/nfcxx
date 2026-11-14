#!/usr/bin/env ruby
# Print the path of the C++ VLA runtime for -fsanitize=address (lib/asan/nfcxx_vla_asan.c, docs/notes/asan.md, "C++
# variable-length arrays"), building it first when it is missing or older than its source. The driver links the object
# ahead of libC.a, whose VLA allocator packs small VLAs into one block with no redzones.
# The object is plain C: the host gcc compiles it with -fsanitize=address, and it needs no EDG build.
#   NFCXX_ASAN_DIR=d   where the object is kept (default build/asan)
require "fileutils"

root = File.expand_path("..", File.expand_path(File.dirname($0)))
src = "#{root}/lib/asan/nfcxx_vla_asan.c"
dir = ENV["NFCXX_ASAN_DIR"].to_s.empty? ? "#{root}/build/asan" : ENV["NFCXX_ASAN_DIR"]
out = "#{dir}/nfcxx_vla_asan.o"
if !File.file?(out) || (File.exist?(src) && File.mtime(src) > File.mtime(out))
  FileUtils.mkdir_p(dir)
  tmp = IO.popen(["mktemp", "-d", "#{dir}/.build.XXXXXX"], &:read).sub(/\n+\z/, "")
  exit($?.exitstatus || 1) unless $?.success?
  at_exit { FileUtils.rm_rf(tmp) }
  exit 1 unless system("gcc", "-c", "-O2", "-Wall", "-Wextra", "-fwrapv", "-fPIC", "-fsanitize=address",
                       "-fno-omit-frame-pointer", src, "-o", "#{tmp}/vla.o")
  File.rename("#{tmp}/vla.o", out)   # atomic: concurrent builds each write their own copy
end
puts out
