#!/usr/bin/env ruby
# Builds build/onnxsim/libnfconnxsim.so: onnxsim's C++ reverse-mode differentiator (graph_grad.cpp, qat_graph_builder.cpp) with the onnx
# it pins and a C ABI shim (scripts/onnxsim/nfc_onnxsim.cpp), for lib/uop/nfcuop_onnxgrad.cpp to dlopen (docs/notes/uop-autodiff.md).
# Needs cmake, a C++17 compiler, git, and the protobuf headers (apt: cmake protobuf-compiler libprotobuf-dev), ~10 min.
# The source is onnxsim master at $onnxsim_rev, with the onnx submodule at the commit that master pins, $onnx_rev. Both are fetched
# by commit hash: git checks every object against its hash, so the commit is the pin (no tarball to verify). Bump both together.
#   JOBS=<n>   build parallelism (default: all cores)
# Prints the path of the library; exits 0 at once when it is already built from these commits.
require "digest"
require "etc"
require "fileutils"

$stdout.sync = true
ONNXSIM_REV = "21f95fd13fae374827e6cdd836987eeff32ebfea"
ONNX_REV = "281e5e6accfd6113fd57d819ce47f32a937bb106"

# Runs a command as the script's `set -e` does: when it fails, the script ends with its status.
def run!(*cmd, **opts)
  system(*cmd, **opts)
  status = $?
  exit(status.exitstatus || 1) unless status.success?
end

# the commit DIR has checked out (git rev-parse HEAD)
def head_of(dir)
  IO.popen(["git", "-C", dir, "rev-parse", "HEAD"], &:read).chomp
end

# cp SRC DST: a failed copy ends the script with cp's status, as under `set -e`
def cp!(src, dst)
  FileUtils.cp(src, dst)
rescue SystemCallError
  warn "cp: cannot stat '#{src}': No such file or directory"
  exit 1
end

# fetch REPO COMMIT DIR: the commit checked out at DIR, exactly (its output goes to stderr, as the script's does)
def fetch(repo, commit, dir)
  FileUtils.rm_rf(dir)
  FileUtils.mkdir_p(dir)
  run!("git", "-C", dir, "init", "-q")
  run!("git", "-C", dir, "fetch", "-q", "--depth", "1", repo, commit, out: $stderr)
  run!("git", "-C", dir, "checkout", "-q", "FETCH_HEAD", out: $stderr)
  return if head_of(dir) == commit

  warn "fetch #{repo}: got #{head_of(dir)}, wanted #{commit}"
  exit 1
end

root = File.expand_path("..", File.dirname(__FILE__))
Dir.chdir(root)
out = "build/onnxsim"
FileUtils.mkdir_p(out)
stamp = "#{out}/built-#{ONNXSIM_REV}-#{ONNX_REV}-#{Digest::SHA256.file("scripts/onnxsim/nfc_onnxsim.cpp").hexdigest[0, 12]}"
if File.file?(stamp) && File.file?("#{out}/libnfconnxsim.so")
  puts "#{root}/#{out}/libnfconnxsim.so"
  exit 0
end

fetch("https://github.com/onnxsim/onnxsim", ONNXSIM_REV, "#{out}/src")
fetch("https://github.com/onnxsim/onnx", ONNX_REV, "#{out}/src/third_party/onnx")
FileUtils.rm_rf(["#{out}/src/.git", "#{out}/src/third_party/onnx/.git"])
run!("cmake", "-S", "scripts/onnxsim", "-B", "#{out}/b", "-G", "Ninja", "-DONNXSIM_SRC=#{root}/#{out}/src",
     "-DCMAKE_BUILD_TYPE=Release", out: $stderr)
jobs = ENV["JOBS"]
jobs = Etc.nprocessors.to_s if jobs.nil? || jobs.empty?
run!("cmake", "--build", "#{out}/b", "--target", "nfconnxsim", "-j", jobs, out: $stderr)
cp!("#{out}/b/libnfconnxsim.so", "#{out}/libnfconnxsim.so")
Dir.glob("#{out}/built-*").each { |f| FileUtils.rm_f(f) }
FileUtils.touch(stamp)
puts "#{root}/#{out}/libnfconnxsim.so"
