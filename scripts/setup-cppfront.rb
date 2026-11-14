#!/usr/bin/env ruby
# Build cppfront (Herb Sutter's Cpp2 to C++1 translator, Apache 2.0, https://github.com/hsutter/cppfront) into build/cppfront,
# for nfcxx's .cpp2 inputs (experimental: docs/notes/cpp2.md). The source is a shallow clone of the pinned commit (v0.8.2)
# in build/cppfront-src; CPPFRONT_SRC names a checkout to use instead (no clone), CPPFRONT_REPO another remote.
# The pin is not a submodule, so a fresh checkout and CI do not fetch it unless a .cpp2 build asks for it.
# CXX (default c++) builds it; cppfront is one C++20 file, so the host compiler is enough.
require_relative "setup-common"
include SetupCommon

root = root_of(__FILE__)
pin = "66eb614ff7947ed2502227ae55bc686d98868abf"
src = env_or("CPPFRONT_SRC", "#{root}/build/cppfront-src")
out = "#{root}/build/cppfront"

if ENV["CPPFRONT_SRC"].to_s.empty? && !File.file?("#{src}/source/cppfront.cpp")
  must("rm", "-rf", src)
  must("mkdir", "-p", File.dirname(src))
  must("git", "init", "-q", src)
  must("git", "-C", src, "fetch", "-q", "--depth", "1", env_or("CPPFRONT_REPO", "https://github.com/hsutter/cppfront"), pin)
  must("git", "-C", src, "checkout", "-q", "FETCH_HEAD")
end
die("setup-cppfront: no source/cppfront.cpp under #{src}") unless File.file?("#{src}/source/cppfront.cpp")

must("mkdir", "-p", File.dirname(out))
must(env_or("CXX", "c++"), "-std=c++20", "-O2", "-o", "#{out}.tmp", "#{src}/source/cppfront.cpp")
must("mv", "#{out}.tmp", out)
version, = capture("sed", "-n", 's/.*"\(v[0-9.]*\)".*/\1/p', "#{src}/source/version.info")
puts "setup-cppfront: built #{out} from #{src} (#{chomp_all(version)})"
