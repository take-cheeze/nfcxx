#!/usr/bin/env ruby
# Install TinyGo (https://tinygo.org, a Go compiler built on LLVM) into build/tinygo, for the wasm explorer's Go language
# (docs/notes/wasm-explorer.md): `tinygo build -o prog.ll` writes the LLVM IR that scripts/llvm-to-pathb.rb translates.
# The release is the pinned linux-amd64 tarball, checked against its SHA-256. TinyGo runs the Go toolchain (go, 1.22 to
# 1.25 for this release), which must be on PATH. Does nothing if the pinned version is installed already.
#   FORCE=1   download again
# Exit status: 0 installed (or up to date); 3 cannot be installed here (not linux-amd64, or no download); 1 failed.
require_relative "setup-common"
include SetupCommon

root = root_of(__FILE__)
version = "0.39.0"
sha256 = "a119801579ef0a7a4f3ee285f0caf55241eaa9e115154c2028b696770b47a846"
url = "https://github.com/tinygo-org/tinygo/releases/download/v#{version}/tinygo#{version}.linux-amd64.tar.gz"
out = "#{root}/build/tinygo"

installed = File.executable?("#{out}/bin/tinygo") && chomp_all(read_or_empty("#{out}/.version")) == version
exit 0 if ENV["FORCE"].to_s.empty? && installed

platform = chomp_all(capture("uname", "-s")[0]) + "-" + chomp_all(capture("uname", "-m")[0])
die("setup-tinygo: only linux-amd64 is pinned", 3) unless platform == "Linux-x86_64"

with_tmp do |tmp|
  die("setup-tinygo: cannot download #{url}", 3) unless run("curl", "-fsSL", "-o", "#{tmp}/tinygo.tar.gz", url).success?

  io = IO.popen(["sha256sum", "-c", "--quiet", "-"], "w")
  io.write("#{sha256}  #{tmp}/tinygo.tar.gz\n")
  io.close
  die("setup-tinygo: checksum mismatch") unless $?.success?

  must("tar", "-xzf", "#{tmp}/tinygo.tar.gz", "-C", tmp)
  must("rm", "-rf", out)
  must("mkdir", "-p", "#{root}/build")
  must("mv", "#{tmp}/tinygo", out)
  File.write("#{out}/.version", "#{version}\n")
  puts "setup-tinygo: #{out}/bin/tinygo #{version}"
end
