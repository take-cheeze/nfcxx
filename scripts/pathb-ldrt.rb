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

# A Path B harness with zero-cost exception handling (scripts/setup-pathb.sh writes eh-tables next to its cpfe) links the
# Itanium C++ ABI runtime of libstdc++ (docs/notes/pathb-zero-cost-eh.md). Every Path B link names EDG's libC.a after this
# archive and ahead of libstdc++ (the frames mode's order: libC.a's EH runtime must win there); in this mode libstdc++ must
# provide the C++ ABI, its EH runtime, RTTI and operator new instead. So the script prints a GNU ld input script in place of
# the archive (as glibc's libc.so is one): INPUT puts the archive, the lowering's helpers, libstdc++ and libgcc_s at this
# position of the link line. The helpers (the VLA pool, C99 complex arithmetic, and the abort message they print) are
# libC.a's own members, copied into libnfcxxedg.a with their symbols weak: libC.a after the script then gives nothing, and a link that does not
# name it (g++ x.o $(scripts/pathb-ldrt.rb)) has everything. Not for cosmo (its own C++ runtime) or macOS (ld64 reads no
# linker scripts).
EDG_HELPERS = %w[vla_alloc.o c99_complex.o error.o].freeze

# libnfcxxedg.a in out: the EDG_HELPERS members of the harness's libC.a, or nil when there is no libC.a
def edg_helpers(root, out)
  libc = File.join(env("EDG_LIB") || File.join(env("EDG_BUILD") || "#{root}/build/edg", "lib"), "libC.a")
  return nil unless File.file?(libc)

  lib = "#{out}/libnfcxxedg.a"
  return lib if File.file?(lib) && File.mtime(lib) >= File.mtime(libc)

  members = IO.popen(["ar", "t", libc], &:read).split("\n") & EDG_HELPERS
  return nil if members.empty?

  tmp = IO.popen(["mktemp", "-d", "#{out}/.edg.XXXXXX"], &:read).sub(/\n+\z/, "")
  exit($?.exitstatus || 1) unless $?.success?
  at_exit { FileUtils.rm_rf(tmp) }

  Dir.chdir(tmp) do
    run!("ar", "x", libc, *members)
    # weak: a strong definition elsewhere in the link wins wherever it is (the VLA runtime of an ASan link,
    # scripts/asan-vla.rb, comes after this script on the line, where libC.a's members were never pulled in)
    members.each { |m| run!("objcopy", "--weaken", m) }
    run!("ar", "rcs", "libnfcxxedg.a", *members)
  end
  File.rename("#{tmp}/libnfcxxedg.a", lib)
  lib
end

cpfe = env("PATHB_CPFE") || "#{root}/build/pathb/cmake/bin/cpfe"
if File.file?(File.join(File.dirname(cpfe), "eh-tables")) && !cc_bin.include?("cosmocc") &&
   IO.popen(["uname", "-s"], &:read).chomp != "Darwin"
  # named .a: the drivers pass a .a to the link as it is (GNU ld reads a link script whatever its name)
  script = "#{out}/libnfcxxld-eh.a"
  helpers = edg_helpers(root, out)
  text = "/* nfcxx: scripts/pathb-ldrt.rb, a Path B link with exception tables (docs/notes/pathb-zero-cost-eh.md) */\n" \
         "INPUT ( #{lib}#{helpers ? " #{helpers}" : ""} -lstdc++ -lgcc_s )\n"
  unless File.file?(script) && File.read(script) == text
    File.write("#{script}.#{$$}", text)
    File.rename("#{script}.#{$$}", script)
  end
  lib = script
end
puts lib
