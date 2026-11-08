#!/usr/bin/env ruby
# frozen_string_literal: true

# FRAMES_ONLY (docs/bc2cpp-vm-free-runtime-plan.md, Phase 5): the closed libmruby.a links tools/bc2cpp/runtime/vm_frames.cxx
# in place of mruby's vm.c (tools/bc2cpp/native_vm_build.rb). It defines the 21 functions the link uses, and the ten that
# nothing references (the interpreter entries among them) have no definition, so a new caller fails to link. Static.
#
#   ruby scripts/bc2cpp/frames_only_check.rb <closed-build-dir>   (the one holding lib/libmruby.a)
require 'open3'

dir = ARGV.fetch(0) { abort 'usage: frames_only_check.rb <closed-build-dir>' }
lib = File.join(dir, 'lib/libmruby.a')
abort "missing #{lib}" unless File.file?(lib)

def run(*cmd)
  out, status = Open3.capture2(*cmd)
  abort "#{cmd.join(' ')} failed" unless status.success?
  out
end

live = %w[mrb_ci_bidx mrb_ci_nregs mrb_env_unshare mrb_exec_irep mrb_f_public_send mrb_f_send mrb_funcall mrb_funcall_argv
          mrb_funcall_id mrb_funcall_send mrb_funcall_with_block mrb_funcall_with_method mrb_mod_module_eval
          mrb_obj_instance_eval mrb_protect_error mrb_vm_ci_env mrb_vm_ci_env_clear mrb_vm_ci_target_class mrb_yield
          mrb_yield_argv mrb_yield_with_class]
gone = %w[mrb_vm_exec mrb_vm_run mrb_top_run mrb_load_proc mrb_yield_cont mrb_object_exec mrb_stack_extend
          mrb_vm_ci_env_set mrb_vm_ci_proc_set mrb_vm_ci_target_class_set]

failures = []
members = run('ar', 't', lib).split
failures << 'vm-cxx.o is in the archive: vm.c is linked' if members.include?('vm-cxx.o')
failures << 'vm_frames.o is not in the archive' unless members.include?('vm_frames.o')

defined = run('nm', '-g', '--defined-only', lib).lines.filter_map { |l| l.split.last if l.split[1] == 'T' }
failures << "not defined: #{(live - defined).join(' ')}" unless (live - defined).empty?
gone.each { |name| failures << "#{name} is defined (it must have no definition)" if defined.include?(name) }

# Only the mruby-fiber object (never pulled into the link) may still name them.
run('nm', '-A', '-u', lib).each_line do |line|
  f = line.split
  next unless f.size == 3 && f[1] == 'U' && gone.include?(f[2])

  owner = f[0][/:([^:]+):[^:]*\z/, 1]
  failures << "#{f[2]} is referenced by #{owner}" unless owner == 'fiber.o'
end

abort failures.map { |f| "frames_only: #{f}" }.join("\n") unless failures.empty?
puts "frames_only: vm_frames.o replaces vm.c; #{live.size} live functions, #{gone.size} undefined"
