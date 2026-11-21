#!/usr/bin/env ruby
# Path B long double support library (be/nfcxx_ldrt.c, docs/notes/pathb-longdouble.md), with the personality wrapper of the
# zero-cost exception tables (be/nfcxx_ehrt.c, docs/notes/pathb-zero-cost-eh.md: a member only such a program pulls in,
# through its DW.ref.__nfcxx_personality_v0). Prints the path of libnfcxxld.a,
# building it with the host C compiler first when it is missing or older than its source. Every Path B link step adds
# the archive after its objects: $(scripts/pathb-ldrt.rb) (the archive only pulls in the helpers a program calls).
# PATHB_LDRT_OUT: build somewhere else (default build/pathb-ldrt).
# NFCXX_LDRT_X86=1: the x86-64 variant of the checked float-to-integer conversions (saturating, as gcc on x86-64, instead of
# the abort), built into build/pathb-ldrt-x86 unless PATHB_LDRT_OUT is set. Only the stage-2 front end links it
# (scripts/selfhost-cpfe.sh); user programs keep the trap.
require "fileutils"
require "rbconfig"
require "rbconfig"

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
ehsrc = "#{root}/be/nfcxx_ehrt.c"
lib = "#{out}/libnfcxxld.a"
# rebuilt when a source is newer, and when an archive of before the wrapper lacks its member
stale = !File.file?(lib) || [src, ehsrc].any? { |f| File.exist?(f) && File.mtime(f) > File.mtime(lib) } ||
        !IO.popen(["ar", "t", lib], &:read).split("\n").include?("nfcxx_ehrt.o")
if stale
  FileUtils.mkdir_p(out)
  tmp = IO.popen(["mktemp", "-d", "#{out}/.tmp.XXXXXX"], &:read).sub(/\n+\z/, "")
  exit($?.exitstatus || 1) unless $?.success?
  at_exit { FileUtils.rm_rf(tmp) }
  # -ffunction-sections: one helper per archive member would be better, but one object keeps the link line trivial
  run!(cc_bin, "-O2", "-fno-strict-aliasing", "-fPIC", *defines, "-c", "-o", "#{tmp}/nfcxx_ldrt.o", src)
  run!(cc_bin, "-O2", "-fPIC", "-c", "-o", "#{tmp}/nfcxx_ehrt.o", ehsrc)
  run!("ar", "rcs", "#{tmp}/libnfcxxld.a", "#{tmp}/nfcxx_ldrt.o", "#{tmp}/nfcxx_ehrt.o")
  File.rename("#{tmp}/libnfcxxld.a", lib)
end

# A Path B harness with zero-cost exception handling (scripts/setup-pathb.sh writes eh-tables next to its cpfe) links the
# Itanium C++ ABI runtime of libstdc++ (docs/notes/pathb-zero-cost-eh.md). Every Path B link names EDG's libC.a after this
# archive and ahead of libstdc++ (the frames mode's order: libC.a's EH runtime must win there); in this mode libstdc++ must
# provide the C++ ABI, its EH runtime, RTTI and operator new instead. So the script prints a GNU ld input script in place of
# the archive (as glibc's libc.so is one): INPUT puts the archive, libstdc++ and libgcc_s at this position of the link
# line, and libC.a after it then gives only what is still undefined (the lowering's helpers: the VLA pool, C99 complex
# arithmetic). Not for cosmo (its own C++ runtime) or macOS (ld64 reads no linker scripts).
cpfe = env("PATHB_CPFE") || "#{root}/build/pathb/cmake/bin/cpfe"
if File.file?(File.join(File.dirname(cpfe), "eh-tables")) && !cc_bin.include?("cosmocc") &&
   RbConfig::CONFIG["host_os"] !~ /darwin/
  script = "#{out}/libnfcxxld-eh.ld"
  text = "/* nfcxx: scripts/pathb-ldrt.rb, a Path B link with exception tables (docs/notes/pathb-zero-cost-eh.md) */\n" \
         "INPUT ( #{lib} -lstdc++ -lgcc_s )\n"
  unless File.file?(script) && File.read(script) == text
    File.write("#{script}.#{$$}", text)
    File.rename("#{script}.#{$$}", script)
  end
  lib = script
end
puts lib
