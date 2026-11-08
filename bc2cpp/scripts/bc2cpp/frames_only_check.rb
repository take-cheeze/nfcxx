#!/usr/bin/env ruby
# frozen_string_literal: true

# FRAMES_ONLY (docs/bc2cpp-vm-free-runtime-plan.md, Phase 5): the archive scripts/bc2cpp/frames_only_archive.bash
# derives has no vm.c, defines every symbol vm.c exported exactly once, and its replacement stays small and holds no
# interpreter. Static; the behaviour is host_sweep.bash on the same directory.
#
#   ruby scripts/bc2cpp/frames_only_check.rb <derived-build-dir>/closed <source-build-dir>/closed
require 'open3'

dst = ARGV.fetch(0) { abort 'usage: frames_only_check.rb <derived closed dir> <source closed dir>' }
src = ARGV.fetch(1) { abort 'usage: frames_only_check.rb <derived closed dir> <source closed dir>' }
lib = File.join(dst, 'lib/libmruby.a')
obj = File.join(dst, 'src/vm_frames.o')
vm = File.join(src, 'src/vm-cxx.o')
abort "missing #{lib}, #{obj} or #{vm}" unless [lib, obj, vm].all? { |f| File.file?(f) }

def run(*cmd)
  out, status = Open3.capture2(*cmd)
  abort "#{cmd.join(' ')} failed" unless status.success?
  out
end

failures = []
members = run('ar', 't', lib).split
failures << 'vm-cxx.o is still in the archive' if members.include?('vm-cxx.o')
failures << 'vm_frames.o is not in the archive' unless members.include?('vm_frames.o')

# Nothing in the link references these (ld --cref on the host link): they have no definition at all, so a new caller fails to
# link instead of reaching a stub. mrb_exec_irep stays (proc.o's Proc#call on a cfunc proc) and raises for an irep proc.
gone = %w[mrb_vm_exec mrb_vm_run mrb_top_run mrb_load_proc mrb_yield_cont mrb_object_exec mrb_stack_extend
          mrb_vm_ci_env_set mrb_vm_ci_proc_set mrb_vm_ci_target_class_set]

# Every other function vm.c exported (weak typeinfo aside) is defined by the replacement.
exported = run('nm', '-g', '--defined-only', vm).lines.filter_map { |l| l.split.last if l.split[1] == 'T' }
defined = run('nm', '-g', '--defined-only', '-S', obj).lines.to_h { |l| f = l.split; [f.last, f[1].to_i(16)] }
missing = exported - gone - defined.keys
failures << "vm_frames.o does not define: #{missing.join(' ')}" unless missing.empty?

archive_defined = run('nm', '-g', '--defined-only', lib).lines.filter_map { |l| l.split.last if l.split[1] == 'T' }
gone.each do |name|
  failures << "#{name} is defined again (it must have no definition)" if archive_defined.include?(name)
end
# Only the mruby-fiber object (not linked) may still name them.
run('nm', '-A', '-u', lib).each_line do |line|
  f = line.split
  next unless f.size == 3 && f[1] == 'U' && gone.include?(f[2])

  owner = f[0][/:([^:]+):[^:]*\z/, 1]
  failures << "#{f[2]} is referenced by #{owner}" unless owner == 'fiber.o'
end

text = run('size', obj).lines.last.split.first.to_i
old = run('size', vm).lines.last.split.first.to_i
puts "vm_frames.o text #{text} bytes (vm-cxx.o #{old}; ceiling 14336), #{exported.size - gone.size} live functions, #{gone.size} undefined"
failures << "vm_frames.o text #{text} bytes exceeds 14336" if text > 13_312

abort failures.map { |f| "frames_only: #{f}" }.join("\n") unless failures.empty?
puts 'frames_only: vm.c replaced, same live exports, no interpreter entry'
