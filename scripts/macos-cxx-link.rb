#!/usr/bin/env ruby
# macos-cxx-link.rb SRC.cpp OUT [NFCXX_OPTION...]: a Mach-O arm64 link of one C++ source from this Linux host, with the prelinker run
# (template instances are generated and compiled through the Darwin C path). The cross EDG base (build/edg-base-cross,
# llvm-nm for Mach-O) and build/cross-macos.env must be in place (scripts/setup-cross-macos.sh). Not run: nothing is executed.
require "fileutils"
$stdout.sync = true
$stderr.sync = true

root = File.expand_path("..", File.dirname($PROGRAM_NAME))
if ARGV.size < 2
  warn "#{$PROGRAM_NAME}: #{ARGV.empty? ? '$1' : '$2'}: unbound variable"
  exit 1
end
src_arg, out = ARGV[0], ARGV[1]
extra = ARGV[2..]   # nfcxx options for both steps, e.g. -I DIR and -DNAME=VALUE

def run_status(env, *argv)
  ok = system(env, [argv[0], argv[0]], *argv[1..])
  return 127 if ok.nil?

  $?.exitstatus || (128 + $?.termsig)
end

# . "$root/build/cross-macos.env": the file is sourced by a shell; its three variables are read back from one
envf = File.join(root, "build/cross-macos.env")
exit 1 unless File.file?(envf)
sourcing = <<~'SH'
  . "$1" || exit 1
  for v in NFCXX_MACOS_CLEANROOM NFCXX_LIBCXX NFCXX_MACOS_SYSROOT; do
    eval "[ -n \"\${$v+x}\" ]" || exit 1
  done
  printf '%s\0%s\0%s\0' "$NFCXX_MACOS_CLEANROOM" "$NFCXX_LIBCXX" "$NFCXX_MACOS_SYSROOT"
SH
vals = IO.popen(["bash", "-c", sourcing, "bash", envf], &:read)
exit 1 unless $?.success?
cleanroom, libcxx, sysroot = vals.split("\0", -1)

# src=$(cd "$(dirname "$1")" && pwd)/$(basename "$1"): a missing directory leaves the first part empty (the assignment
# takes the status of its last substitution, so the script goes on)
dir = File.dirname(src_arg)
src = "#{Dir.exist?(dir) ? File.expand_path(dir) : ''}/#{File.basename(src_arg)}"

work = `mktemp -d`.chomp
exit 1 unless $?.success?

begin
  Dir.chdir(work) do
    sysincl = "#{cleanroom}/cxx:#{libcxx}:#{sysroot}"
    cc = File.join(root, "scripts/cross-macos-cc.rb")
    cxx = File.join(root, "scripts/cross-macos-cxx.sh")
    link = File.join(root, "scripts/cross-macos-link.rb")
    nfcxx = File.join(root, "nfcxx")

    # 1. compile: the object and its .ii/.ti records (the template requests) beside it; the Darwin C path compiles the C
    st = run_status({ "NFCXX_CC" => cc, "NFCXX_CXX" => cxx, "NFCXX_SYS_INCLUDES" => sysincl },
                    nfcxx, "-c", *extra, src, "-o", "tl.o")
    exit st unless st.zero?

    # 2. link: the prelinker reads tl.ii/.ti, compiles the instances through NFCXX_CC, and eccp links with the stub linker
    dialect = ENV["NFCXX_LINK_DIALECT"].to_s
    dialect = cxx if dialect.empty?
    st = run_status({ "NFCXX_CC" => cc, "NFCXX_CXX" => dialect, "NFCXX_SYS_INCLUDES" => sysincl,
                      "EDG_OBJ_TO_EXEC_LINKER" => link },
                    nfcxx, *extra, "tl.o", "-o", "exe")
    exit st unless st.zero?

    FileUtils.mkdir_p(File.dirname(out))
    st = run_status({}, "cp", "exe", out)
    exit st unless st.zero?
  end
ensure
  FileUtils.rm_rf(work)
end
