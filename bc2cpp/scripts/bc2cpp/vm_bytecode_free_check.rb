#!/usr/bin/env ruby
# frozen_string_literal: true

# VM/bytecode free test for the closed build.
# Runs the native fiber check (compiled Fiber programs on an mruby without mruby-fiber, with the C++ Fiber as the whole
# Fiber) and verifies the closed build's bytecode inventory.

require 'open3'
require 'fileutils'

ROOT = File.expand_path('../..', __dir__)

puts '== vm/bytecode free check =='

# Run the native fiber check
env = ENV.to_h
# CI also runs native_fiber_check directly in parallel; the no-fiber mruby it builds is shared through this directory.
env['BC2CPP_NOFIBER_BUILD_DIR'] ||= File.join(ROOT, 'build-vm-bytecode-free')
output, status = Open3.capture2e(env, 'ruby', File.join(ROOT, 'scripts/bc2cpp/native_fiber_check.rb'), chdir: ROOT)
File.write('/tmp/vm_bytecode_free_check.log', output)
STDOUT.puts output
STDOUT.flush
unless status.success?
  abort "native_fiber_check failed:\n#{output.lines.last(40).join}"
end
# The wrapper is the closed build's gate: a skipped behavioural half is not a pass.
abort 'native_fiber_check skipped its behavioural half (no full-core or no-fiber mruby)' if output.include?('SKIP')

puts '  native fiber check passed (compiled Fiber programs run on an mruby without mruby-fiber)'

# The closed build's libmruby has no mruby-fiber: the C++ Fiber is its only Fiber.
closed_lib = File.join(ROOT, 'build-closed-bc2cpp/closed/lib/libmruby.a')
if File.exist?(closed_lib)
  fiber_syms, = Open3.capture2('nm', '-A', '--defined-only', closed_lib)
  fiber_syms = fiber_syms.lines.grep(/\bmrb_fiber_/)
  abort "closed libmruby defines mrb_fiber_* symbols:\n#{fiber_syms.first(10).join}" unless fiber_syms.empty?
  puts '  closed libmruby: no mrb_fiber_* symbols'
end

# Also verify closed build artifacts if they exist
inventory_path = File.join(ROOT, 'build-closed-bc2cpp/closed/bytecode-inventory.json')
if File.exist?(inventory_path)
  require 'json'
  inv = JSON.parse(File.read(inventory_path))
  abort 'native_fiber_check_passed false in inventory' unless inv['native_fiber_check_passed']
  abort 'retained bytecode instruction arrays in source' unless inv['retained_source_instruction_arrays']&.empty?
  abort 'retained bytecode instruction arrays in archive' unless inv['retained_archive_instruction_arrays']&.empty?
  abort 'retained host bytecode instruction arrays' unless inv['retained_host_instruction_arrays']&.empty?
  puts "  closed build inventory: #{inv['native_continuation_programs']} native programs, 0 bytecode arrays"
end

puts 'vm/bytecode free check: PASS'
