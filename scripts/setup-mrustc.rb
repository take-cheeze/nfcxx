#!/usr/bin/env ruby
# Build mrustc (thepowersgang/mrustc, the commit pinned below) and its Rust 1.90.0 standard library into
# build/mrustc/src, for scripts/mrustc-nfcc.sh. The first run downloads the rustc 1.90.0 source (about 270 MB) and
# takes a few minutes on 4 cores. Does nothing if the library is built already.
#   FORCE=1        rebuild the compiler and the library
#   PARLEVEL=<n>   parallel jobs (default: the number of CPUs)
# Needs the mrustc build dependencies: a C++14 compiler, GNU make, patch, curl, pkg-config and libz (see its README).
require "etc"
require "fileutils"

$stdout.sync = true
root = File.expand_path("..", File.dirname(__FILE__))
Dir.chdir(root)
work = "#{root}/build/mrustc"
src = "#{work}/src"
# take-cheeze/mrustc, branch nfcxx/mold3-followups: nfcxx/patches (the tracking branch: nfcxx/fixes, upstream
# thepowersgang/mrustc d85e86b plus nfcxx's fixes, plus the open bug PRs, with the fixes that build mold 3: bugs 22 to 41
# of NFCXX-FIXES.md, one commit each), bug 41 redone so that lifted statics stay private (nfcxx/lifted-private), the
# emulated 128-bit multiply from 64-bit halves, and minicargo's OUT_DIR laid out as cargo's. On top of that, branch
# nfcxx/borrowck-scope-end: scope ends in the monomir dump for scripts/mrustc-borrowck.sh (MRUSTC_MMIR_SCOPE_END=1),
# and -Z disable-mir-opt also without inlining after monomorphisation. MRUSTC_REPO overrides the repository.
url = ENV["MRUSTC_REPO"]
url = "https://github.com/take-cheeze/mrustc" if url.nil? || url.empty?
pin = "6c360afd"
jobs = ENV["PARLEVEL"]
jobs = Etc.nprocessors.to_s if jobs.nil? || jobs.empty?

# Runs a command as the script's `set -e` does: when it fails, the script ends with its status.
def run!(*cmd, **opts)
  system(*cmd, **opts)
  status = $?
  exit(status.exitstatus || 1) unless status.success?
end

if ENV["FORCE"] != "1" && File.executable?("#{src}/bin/mrustc") && File.file?("#{src}/output-1.90.0/libstd.rlib.o")
  exit 0
end
unless Dir.exist?("#{src}/.git")
  FileUtils.mkdir_p(work)
  FileUtils.rm_rf(src)
  run!("git", "clone", "--quiet", url, src)
end
run!("git", "-C", src, "checkout", "--quiet", pin)

# The steps of mrustc's build-1.90.0.sh: the compiler, the rustc source, then the libraries (core, alloc, std, ...).
make_env = { "RUSTC_VERSION" => "1.90.0", "MRUSTC_TARGET_VER" => "1.90", "OUTDIR_SUF" => "-1.90.0",
             "MINICARGO_DEFER_CODEGEN" => "1", "PARLEVEL" => jobs }
run!(make_env, "make", "-C", src, "-j#{jobs}")
run!(make_env, "make", "-C", src, "RUSTCSRC")
run!(make_env, "make", "-C", src, "-f", "minicargo.mk", "LIBS")
puts "setup-mrustc: #{src}/bin/mrustc and #{src}/output-1.90.0 built"
