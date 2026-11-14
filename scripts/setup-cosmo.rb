#!/usr/bin/env ruby
# Fetches cosmocc (the Cosmopolitan Libc C/C++ toolchain, https://github.com/jart/cosmopolitan) into build/cosmocc, for
# `nfcxx --cosmo` (docs/notes/cosmo.md). Nothing is built from source: the release zip is unpacked as it is.
#   COSMOCC_URL=URL       the zip (default: the 4.0.2 release asset on GitHub; cosmo.zip is not reachable from CI)
#   COSMOCC_SHA256=HEX    checked against the zip (default: the 4.0.2 asset's digest)
#   COSMOCC_DIR=DIR       where it goes (default: build/cosmocc)
require_relative "setup-common"
include SetupCommon

version = "4.0.2"
root = root_of(__FILE__)
url = env_or("COSMOCC_URL", "https://github.com/jart/cosmopolitan/releases/download/#{version}/cosmocc-#{version}.zip")
dir = env_or("COSMOCC_DIR", "#{root}/build/cosmocc")
# the digest of the 4.0.2 asset, as downloaded from the release on 2026-10-31; an empty COSMOCC_SHA256 (an unset repository
# variable) means this one
sha256 = env_or("COSMOCC_SHA256", "85b8c37a406d862e656ad4ec14be9f6ce474c1b436b9615e91a55208aced3f44")
sha256 = env_or("COSMOCC_SHA256", "") unless ENV["COSMOCC_URL"].to_s.empty?

# "$exe" --version | head -1: the first line of its stdout; the status is the command's (pipefail)
def version_line(exe)
  out, status = capture(exe, "--version")
  print out.lines.first.to_s
  exit status_of(status) unless status.success?
end

if File.executable?("#{dir}/bin/cosmocc")
  puts "cosmocc: already at #{dir}/bin/cosmocc"
  version_line("#{dir}/bin/cosmocc")
  exit 0
end

with_tmp do |tmp|
  puts "cosmocc: fetching #{url}"
  must("curl", "-fsSL", "--retry", "3", "-o", "#{tmp}/cosmocc.zip", url)
  if sha256.empty?
    out, status = capture("sha256sum", "#{tmp}/cosmocc.zip")
    exit status_of(status) unless status.success?
    digest = out.lines.map { |line| line.chomp.partition(" ")[0] }.join("\n")
    puts "cosmocc: sha256 of the zip (set COSMOCC_SHA256 to pin it): #{chomp_all(digest)}"
  else
    io = IO.popen(["sha256sum", "-c", "-"], "w")
    io.write("#{sha256}  #{tmp}/cosmocc.zip\n")
    io.close
    exit status_of($?) unless $?.success?
  end
  must("mkdir", "-p", dir)
  must("unzip", "-q", "-o", "#{tmp}/cosmocc.zip", "-d", dir)
  bins = Dir.glob("#{dir}/bin/*").sort
  run("chmod", "+x", *bins, err: File::NULL) unless bins.empty?
  version_line("#{dir}/bin/cosmocc")
end
