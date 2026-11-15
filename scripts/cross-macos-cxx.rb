#!/usr/bin/env ruby
# cross-macos-cxx.rb: the C++ compiler for the cross path's preprocess and dependency scan (nfcxx -M). It targets Darwin
# arm64 and drops the host's include directories (-nostdinc, -nostdinc++): the host's /usr/include, with glibc's
# features.h, must not leak into a macOS compile. nfcxx passes the cross include directories itself (NFCXX_SYS_INCLUDES).
$stdout.sync = true
$stderr.sync = true

# $(clang -print-resource-dir): the output with its trailing newlines removed; a clang that cannot be started leaves
# it empty, after the shell's "not found" message (the original's line 5)
resource =
  begin
    `clang -print-resource-dir`.sub(/\n+\z/, "")
  rescue Errno::ENOENT
    warn "#{$PROGRAM_NAME}: 5: clang: not found"
    ""
  end

# exec clang++ ...: the process is replaced, so the exit status is clang++'s
argv = ["--target=arm64-apple-darwin", "-nostdinc", "-nostdinc++", "-isystem", "#{resource}/include", *ARGV]
begin
  Kernel.exec(["clang++", "clang++"], *argv)
rescue Errno::ENOENT
  warn "#{$PROGRAM_NAME}: 5: exec: clang++: not found"
  exit 127
rescue Errno::EACCES
  warn "#{$PROGRAM_NAME}: 5: exec: clang++: Permission denied"
  exit 126
end
