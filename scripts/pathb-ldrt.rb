#!/usr/bin/env ruby
# Path B long double support library (be/nfcxx_ldrt.c, docs/notes/pathb-longdouble.md). Prints the path of libnfcxxld.a,
# building it with the host C compiler first when it is missing or older than its source. Every Path B link step adds
# the archive after its objects: $(scripts/pathb-ldrt.rb) (the archive only pulls in the helpers a program calls).
# PATHB_LDRT_OUT: build somewhere else (default build/pathb-ldrt).
# NFCXX_LDRT_X86=1: the x86-64 variant of the checked float-to-integer conversions (saturating, as gcc on x86-64, instead of
# the abort), built into build/pathb-ldrt-x86 unless PATHB_LDRT_OUT is set. Only the stage-2 front end links it
# (scripts/selfhost-cpfe.sh); user programs keep the trap.
require "fileutils"

# A variable that is unset or empty is nil (bash's ${VAR:-default}).
def env(name)
  v = ENV[name]
  v.nil? || v.empty? ? nil : v
end

# Runs a command; a failure ends the script with its status (bash's set -e).
def run!(*cmd)
  return if system(*cmd)
  exit($?.exitstatus || 1)
end

root = File.expand_path("..", File.expand_path(File.dirname($0)))
out = env("PATHB_LDRT_OUT") || "#{root}/build/pathb-ldrt"
defines = []
if ENV["NFCXX_LDRT_X86"] == "1"
  out = env("PATHB_LDRT_OUT") || "#{root}/build/pathb-ldrt-x86"
  defines = ["-DNFCXX_FLOAT_TO_INT_X86"]
end
# NFCXX_GCC names cosmocc with --cosmo: the archive is cosmo's own (build/pathb-ldrt-cosmo), built by that compiler.
cc_bin = env("NFCXX_GCC") || "cc"
out = env("PATHB_LDRT_OUT") || "#{root}/build/pathb-ldrt-cosmo" if cc_bin.include?("cosmocc")
src = "#{root}/be/nfcxx_ldrt.c"
lib = "#{out}/libnfcxxld.a"
if !File.file?(lib) || (File.exist?(src) && File.mtime(src) > File.mtime(lib))
  FileUtils.mkdir_p(out)
  tmp = IO.popen(["mktemp", "-d", "#{out}/.tmp.XXXXXX"], &:read).sub(/\n+\z/, "")
  exit($?.exitstatus || 1) unless $?.success?
  at_exit { FileUtils.rm_rf(tmp) }
  # -ffunction-sections: one helper per archive member would be better, but one object keeps the link line trivial
  run!(cc_bin, "-O2", "-fno-strict-aliasing", "-fPIC", *defines, "-c", "-o", "#{tmp}/nfcxx_ldrt.o", src)
  run!("ar", "rcs", "#{tmp}/libnfcxxld.a", "#{tmp}/nfcxx_ldrt.o")
  File.rename("#{tmp}/libnfcxxld.a", lib)
end
puts lib
