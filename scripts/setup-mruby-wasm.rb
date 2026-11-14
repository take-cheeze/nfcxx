#!/usr/bin/env ruby
# The mruby interpreter of scripts/mrb (scripts/mruby-tool-config.rb), built with Emscripten (scripts/mruby-wasm-config.rb), for the
# browser: build/mruby-wasm/out/wasm/bin/mruby.js and mruby.wasm. Uses the pinned mruby source of scripts/setup-mruby.sh and
# Emscripten on PATH (scripts/setup-emsdk.sh, then source build/emsdk/emsdk_env.sh).
#   FORCE=1   build again
require "etc"
require "fileutils"

$stdout.sync = true
root = File.expand_path("..", File.dirname(__FILE__))
work = "#{root}/build/mruby-wasm"
out = "#{work}/out/wasm/bin/mruby.js"
exit 0 if (ENV["FORCE"].nil? || ENV["FORCE"].empty?) && File.file?(out)

# Whether NAME is an executable on PATH (command -v NAME)
def on_path?(name)
  (ENV["PATH"] || "").split(":").any? { |d| File.file?(File.join(d, name)) && File.executable?(File.join(d, name)) }
end

# Runs a command as the script's `set -e` does: when it fails, the script ends with its status.
def run!(*cmd, **opts)
  system(*cmd, **opts)
  status = $?
  exit(status.exitstatus || 1) unless status.success?
end

# cp SRC DST: a failed copy ends the script with cp's status, as under `set -e`
def cp!(src, dst)
  FileUtils.cp(src, dst)
rescue SystemCallError
  warn "cp: cannot stat '#{src}': No such file or directory"
  exit 1
end

unless on_path?("emcc")
  warn "setup-mruby-wasm: emcc is not on PATH (scripts/setup-emsdk.sh)"
  exit 1
end
run!({ "FORCE" => "" }, "#{root}/scripts/setup-mruby.sh")     # the pinned source (and the host interpreter)
src = "#{root}/build/mruby-tool/src"
rake = on_path?("rake") ? ["rake"] : ["ruby", "-rrake", "-e", "Rake.application.run(ARGV)", "--"]
FileUtils.mkdir_p(work)
cp!("#{root}/scripts/mruby-wasm-config.rb", "#{work}/build_config.rb")
log = "#{work}/build.log"
jobs = Etc.nprocessors
built = Dir.exist?(src) && system({ "MRUBY_CONFIG" => "#{work}/build_config.rb", "MRUBY_BUILD_DIR" => "#{work}/out" },
                                   *rake, "-j#{jobs}", "all", chdir: src, out: log, err: [:child, :out])
unless built
  File.readlines(log).last(20).each { |l| $stderr.write(l) } if File.file?(log)
  warn "setup-mruby-wasm: build failed (#{log})"
  exit 1
end
unless File.file?(out)
  warn "setup-mruby-wasm: #{out} was not built"
  exit 1
end
puts "setup-mruby-wasm: #{out} (#{File.size("#{work}/out/wasm/bin/mruby.wasm")} bytes of wasm)"
