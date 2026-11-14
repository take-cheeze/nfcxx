#!/usr/bin/env ruby
# Install the Emscripten SDK (emsdk) into build/emsdk, at a pinned release, for the browser build of the Path B front end
# (PATHB_EMSCRIPTEN=1 scripts/setup-pathb.sh; docs/notes/pathb-wasm-frontend.md). Then, in the shell that builds:
#   source build/emsdk/emsdk_env.sh
# Does nothing if the pinned release is installed already.
require_relative "setup-common"
include SetupCommon

root = root_of(__FILE__)
version = env_or("EMSDK_VERSION", "6.0.13")
dir = "#{root}/build/emsdk"

unless File.executable?("#{dir}/emsdk")
  must("mkdir", "-p", "#{root}/build")
  must("git", "clone", "-q", "--depth", "1", "https://github.com/emscripten-core/emsdk.git", dir)
end
if chomp_all(read_or_empty("#{dir}/.nfcxx-version")) != version
  must("#{dir}/emsdk", "install", version)
  must("#{dir}/emsdk", "activate", version)
  File.write("#{dir}/.nfcxx-version", "#{version}\n")
end
puts "setup-emsdk: emsdk #{version} in #{dir} (source #{dir}/emsdk_env.sh)"
