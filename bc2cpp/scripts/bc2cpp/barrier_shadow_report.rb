#!/usr/bin/env ruby
# frozen_string_literal: true

# Reports whether the Fixnum proof's exception barriers (ctx[:catch_targets],
# ctx[:protected]) could be derived from BytecodeIR handler edges without
# changing a decision (ADR 0250 addendum "Barrier shadow"):
#
#   1. synthetic handlers: the corner cases where the edge-derived sets differ
#      from the address-range sets, printed as concrete examples;
#   2. the real closed-world wio build with tools/bc2cpp/fixnum_barrier_shadow.rb
#      preloaded, comparing old and shadow answers for every barrier query.
#
# Usage: MRBC=path/to/host/mrbc ruby scripts/bc2cpp/barrier_shadow_report.rb
# Exits 1 on any real-build difference. Not part of CI: the synthetic classes
# below differ by design, which is why the barriers were not migrated.

require 'open3'
require 'set'
require 'shellwords'
require 'tmpdir'
require_relative '../../tools/bc2cpp/compiled_gems'
require_relative '../../tools/bc2cpp/nomethod_reviewed_probe'
require_relative '../../tools/bc2cpp/irep'
require_relative '../../tools/bc2cpp/bytecode_ir'
require_relative '../../tools/bc2cpp/fixnum_barrier_shadow'

ROOT = File.expand_path('../..', __dir__)

def insn(addr, op, args)
  Insn.new(lineno: 1, addr: addr, op: op, args: args, raw: "#{op} #{args}")
end

INSNS = [insn(0, 'LOADI', "R1\t1"), insn(4, 'SEND', "R2\t:f\t0"), insn(8, 'MOVE', "R3\tR1"),
         insn(12, 'RETURN', 'R3')].freeze

def synthetic(name, handler)
  program = BytecodeIR::Program.new(Irep.new(label: name, instructions: INSNS, catch_handlers: [handler]))
  addrs = INSNS.map(&:addr)
  old_catch = program.handler_target_addrs & addrs
  old_prot = program.handler_protected_addrs(inclusive_end: true) & addrs
  new_catch = FixnumBarrierShadow.catch_target_addrs(program)
  new_prot = FixnumBarrierShadow.protected_addrs(program)
  puts "  #{name}: #{handler.to_h}"
  [[:catch_targets, old_catch, new_catch], [:protected, old_prot, new_prot]].each do |kind, old, new|
    loosen = (old - new).to_a.sort
    tighten = (new - old).to_a.sort
    puts "    #{kind}: same" if loosen.empty? && tighten.empty?
    puts "    #{kind}: edge-derived would LOOSEN (unsafe) at #{loosen}" unless loosen.empty?
    puts "    #{kind}: edge-derived would TIGHTEN at #{tighten}" unless tighten.empty?
  end
end

puts 'synthetic handlers'
synthetic('ordinary', CatchHandler.new(type: :rescue, begin_addr: 4, end_addr: 8, target: 12))
synthetic('unresolved target', CatchHandler.new(type: :rescue, begin_addr: 4, end_addr: 8, target: 99))
synthetic('empty range', CatchHandler.new(type: :rescue, begin_addr: 4, end_addr: 4, target: 12))
synthetic('range without instruction', CatchHandler.new(type: :ensure, begin_addr: 5, end_addr: 7, target: 12))

srcs = closed_world_mrblib_srcs(ROOT)
native_srcs = Dir["#{ROOT}/mruby-rgss/src/*.cxx"] + core_native_srcs("#{ROOT}/3rd/mruby") +
              external_gem_native_srcs(ROOT)
env = {
  'MRBC' => ENV['MRBC'] || 'mrbc',
  'OUT_SYMBOL' => 'barrier_shadow',
  'ONLY_OWNERS' => BC2CPP_COMPILED_GEMS.values.flat_map { |g| g[:owners] }.join(','),
  'NATIVE_SRCS' => Shellwords.join(native_srcs),
  'FOREIGN_RUBY_SRCS' => Shellwords.join(foreign_mrblib_srcs(ROOT)),
  'BC2CPP_CLOSED_WORLD' => '1',
  'BC2CPP_BUILD_NAME' => 'wio',
  'BC2CPP_BUILD_GEMS' => Shellwords.join(NomethodReviewedProbe.wio_gems(ROOT).map { |n, d| "#{n}=#{d}" }),
  NomethodReviewed::ALLOW_ENV => 'allow'
}
puts 'real closed-world build'
Dir.mktmpdir do |dir|
  env['OUT_DIR'] = dir
  env['BC2CPP_BARRIER_SHADOW_REPORT'] = File.join(dir, 'report')
  cmd = [RbConfig.ruby, "-r#{ROOT}/tools/bc2cpp/fixnum_barrier_shadow.rb", "#{ROOT}/tools/bc2cpp/bc2cpp.rb", *srcs]
  _out, err, status = Open3.capture3(env, *cmd)
  abort "bc2cpp.rb failed (exit #{status.exitstatus}):\n#{err[-4000..]}" unless status.success?

  report = Dir[File.join(dir, 'report.*')].map { |f| File.read(f) }.max_by(&:size)
  puts report
  exit(report.include?("query differences: 0\n") && report.include?("context set differences: 0\n") ? 0 : 1)
end
