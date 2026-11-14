#!/usr/bin/env ruby
# Build mold 3 (the Rust linker, https://github.com/rui314/mold) into build/mold/bin: mold and ld.mold, so that
#   PATH="$PWD/build/mold/bin:$PATH" NFCXX_LD=mold ./nfcxx ...
# links with it. The source is the v3.0.0 tag, checked against the pinned commit below; the build is cargo's
# (Rust 1.95 or newer, and network access for its crates, including the mimalloc_rust git dependency).
require_relative "setup-common"
include SetupCommon

root = root_of(__FILE__)
tag = "v3.0.0"
pin = "8de38c35a2df16a25f7ff87ac3ad07156a925beb" # the commit of v3.0.0
src = "#{root}/build/mold-src"

die("setup-mold: cargo not found (install Rust 1.95 or newer)") unless command?("cargo")
must("rm", "-rf", src)
must("mkdir", "-p", "#{root}/build")
must("git", "clone", "-q", "--depth", "1", "--branch", tag, "https://github.com/rui314/mold.git", src)
head, = capture("git", "-C", src, "rev-parse", "HEAD")
die("setup-mold: #{tag} is not #{pin}") unless chomp_all(head) == pin
must("cargo", "build", "--release", "-p", "mold-cli", chdir: src, out: File::NULL)

must("mkdir", "-p", "#{root}/build/mold/bin")
must("install", "-m", "755", "#{src}/target/release/mold", "#{root}/build/mold/bin/mold")
must("ln", "-sf", "mold", "#{root}/build/mold/bin/ld.mold")
must("rm", "-rf", src)
must("#{root}/build/mold/bin/mold", "--version")
