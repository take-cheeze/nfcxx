#!/usr/bin/env ruby
# frozen_string_literal: true

# FRAME_FREE (tools/bc2cpp/native_frame_use.rb): mrb_call_direct against the same native called through a pushed frame,
# in the closed libmruby.a: the same result, exception and backtrace length, the same frame depth afterwards, a frame
# below the callee of a nested send, and no frame for a call that returns. frame_free_raise_check.cxx holds the cases.
#
#   ruby scripts/bc2cpp/frame_free_raise_check.rb <closed-build-dir>   (the one holding lib/libmruby.a)
require 'open3'
require 'tmpdir'

dir = ARGV.fetch(0) { abort 'usage: frame_free_raise_check.rb <closed-build-dir>' }
lib = File.join(dir, 'lib/libmruby.a')
abort "missing #{lib}" unless File.file?(lib)

root = File.expand_path('../..', __dir__)
world = ENV.fetch('BC2CPP_WORLD_ROOT', File.expand_path('../..', root))
source = File.join(__dir__, 'frame_free_raise_check.cxx')
Dir.mktmpdir('frame_free_raise_check') do |tmp|
  exe = File.join(tmp, 'check')
  # Only the core runs (the check's own mrb_init_mrbgems): the gems' natives stay unreferenced, so their libraries are
  # not linked.
  cmd = [ENV.fetch('CXX', 'c++'), '-std=gnu++17', '-O1', "-I#{File.join(dir, 'include')}",
         "-I#{File.join(world, '3rd/mruby/include')}", source, '-o', exe, '-Wl,--gc-sections',
         '-Wl,--unresolved-symbols=ignore-all', lib, '-lm', '-lpthread']
  out, status = Open3.capture2e(*cmd)
  abort "frame_free_raise_check: build failed\n#{out}" unless status.success?
  out, status = Open3.capture2e(exe)
  puts out
  abort 'frame_free_raise_check: FAILED' unless status.success?
end
