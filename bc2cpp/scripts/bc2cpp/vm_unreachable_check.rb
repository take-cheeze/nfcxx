#!/usr/bin/env ruby
# frozen_string_literal: true

# VM_UNREACHABLE (docs/bc2cpp-vm-free-runtime-plan.md, Phase 5): the closed libmruby.a has no bytecode interpreter
# loop, and the only objects that can start one are the ones measured to (host sweep: zero starts). Static, so it
# needs no patched mruby. Counts only go down as the phases land.
#
#   ruby scripts/bc2cpp/vm_unreachable_check.rb <generated-closed-build-dir>
require 'open3'

dir = ARGV.fetch(0) { abort 'usage: vm_unreachable_check.rb <closed-build-dir (the one holding lib/libmruby.a)>' }
lib = File.join(dir, 'lib/libmruby.a')
vm = File.join(dir, 'src/vm_frames.o')
abort "missing #{lib} or #{vm}" unless File.file?(lib) && File.file?(vm)

def run(*cmd)
  out, status = Open3.capture2(*cmd)
  abort "#{cmd.join(' ')} failed" unless status.success?
  out
end

failures = []
# The closed build links vm_frames.o (tools/bc2cpp/runtime/vm_frames.cxx), not vm.c: no interpreter loop and no mrb_vm_exec.
failures << 'mrb_vm_exec is defined' if run('nm', '-g', '--defined-only', vm).include?(' mrb_vm_exec')
text = run('size', vm).lines.last.split.first.to_i
puts "vm_frames.o text #{text} bytes (ceiling 14336)"
failures << "vm_frames.o text #{text} bytes exceeds 14336" if text > 14_336

# Objects that reference an entry able to start bytecode. Measured on the sweep: only proc.o (Proc#call on a cfunc
# proc) reaches mrb_exec_irep, and its irep branch never runs. A new referencing object is a new way into the VM.
entries = %w[mrb_vm_exec mrb_vm_run mrb_top_run mrb_exec_irep mrb_yield_cont mrb_object_exec mrb_protect_error]
# mrb_protect_error is the VM's exception boundary: mruby core C and gem_init.o keep it, compiled code uses the typed
# catch (bc2cpp_protect, the entry header's bc2cpp_entry_call), so a compiled gem object referencing it is a regression.
allowed = { 'mrb_exec_irep' => %w[proc.o], 'mrb_vm_exec' => %w[fiber.o], 'mrb_vm_run' => %w[fiber.o], 'mrb_top_run' => %w[fiber.o],
            'mrb_yield_cont' => %w[fiber.o], 'mrb_object_exec' => %w[fiber.o], 'mrb_protect_error' => %w[array.o bigint.o gem_init.o] }
users = Hash.new { |h, k| h[k] = [] }
current = nil
run('nm', '-u', lib).each_line do |line|
  line = line.strip
  current = line.chomp(':') if line.end_with?(':')
  name = line.split.last
  users[name] << current if line.start_with?('U ') && entries.include?(name)
end
entries.each do |name|
  extra = users[name].uniq - allowed.fetch(name)
  puts "#{name}: referenced by #{users[name].uniq.join(' ').then { |s| s.empty? ? 'nothing' : s }}"
  failures << "#{name} is referenced by #{extra.join(', ')}" unless extra.empty?
end

abort failures.map { |f| "vm_unreachable: #{f}" }.join("\n") unless failures.empty?
puts 'vm_unreachable: no interpreter loop, no new bytecode entry'
