#!/usr/bin/env ruby
# frozen_string_literal: true

# VM/bytecode free test for bc2cpp native-only runtime.
# Runs the native fiber check and verifies bytecode-free properties.

require 'open3'
require 'fileutils'

ROOT = File.expand_path('../..', __dir__)

puts '== vm/bytecode free check =='

# Run the comprehensive native fiber check
env = ENV.to_h
# CI also runs native_fiber_check directly in parallel.
env['BC2CPP_NATIVE_BUILD_DIR'] ||= File.join(ROOT, 'build-vm-bytecode-free')
output, status = Open3.capture2e(env, 'ruby', File.join(ROOT, 'scripts/bc2cpp/native_fiber_check.rb'), chdir: ROOT)
File.write('/tmp/vm_bytecode_free_check.log', output)
STDOUT.puts output
STDOUT.flush
unless status.success?
  abort "native_fiber_check failed:\n#{output.lines.last(40).join}"
end

puts '  native fiber check passed (bytecode-free native runtime verified)'

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
