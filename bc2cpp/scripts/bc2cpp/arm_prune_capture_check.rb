#!/usr/bin/env ruby
# frozen_string_literal: true

# ARM_PRUNE stage B with register flow on (the default). An empty captured set is still truthy, so flow on used to refuse
# every method; now a method with no captured register is accepted, and a method with one is refused only by the emitter
# it really uses (a block-fallback glue, or an inlined loop's guard). The refusal set is pinned per method below, and a
# refused method must compile to the same text with stage B on or off. Needs MRBC; without it the check prints SKIP.
#
#   MRBC=path/to/host/mrbc ruby scripts/bc2cpp/arm_prune_capture_check.rb

require 'set'
require_relative 'check_support'
require_relative '../../tools/bc2cpp/bc2cpp'

suite = FixtureCheck.new('arm_prune_capture_check')
suite.require_mrbc!

SOURCE = <<~'RUBY'
  class Cap
    def route(x)
      y = nil
      s = "a"
      r = 0
      r += 1 if y
      r += 2 if s
      r += 4 if x
      r += 8 unless y
      r
    end

    def plain(x)
      n = 0
      y = nil
      z = nil
      n += 1 if y
      n += 2 if z
      n + x
    end

    def captured_branch(x)
      n = 0
      y = nil
      x.each { |v| n += v } if y
      n += 1 if y
      n
    end

    def captured_loop(x)
      n = 0
      y = nil
      loop do
        n += 1
        break if n > x
      end
      n += 1 if y
      n
    end
  end
RUBY

METHODS = %w[route plain captured_branch captured_loop].freeze

# Each method's refusal counts and C++, compiled with the given environment (nil unsets a variable). Restored afterwards.
compile_all = lambda do |env|
  previous = env.keys.to_h { |key| [key, ENV[key]] }
  env.each { |key, value| ENV[key] = value }
  results = {}
  suite.compile(SOURCE) do |ireps, root|
    registry = build_registry(ireps, root)[0]
    METHODS.each do |name|
      CodeGen.arm_prune_refusals.clear
      gen = CodeGen.new(ireps, registry, {}, {}, {}, {}, {}, {}, {}, {}, {}, Set.new)
      label = registry.fetch(name).find { |d| d.owner == 'Cap' }.irep
      code = gen.compile_method(label).fetch(:code)
      captured = RegisterFlow.captured_registers(ireps.fetch(label))
      results[name] = { code: code, refusals: CodeGen.arm_prune_refusals.dup, captured: captured.to_a.sort }
    end
  end
  results
ensure
  previous.each { |key, value| ENV[key] = value }
end

FLOW_ON_STAGE_B = { 'BC2CPP_PRUNE_ARMS' => nil, 'BC2CPP_REGISTER_FLOW' => nil }.freeze
FLOW_ON_NO_B = { 'BC2CPP_PRUNE_ARMS' => '0', 'BC2CPP_REGISTER_FLOW' => nil }.freeze

on = compile_all.call(FLOW_ON_STAGE_B)
off = compile_all.call(FLOW_ON_NO_B)

# Multiset diff of the lines: stage B may only remove lines and add none.
surplus = lambda do |from, minus|
  counts = from.lines.tally
  minus.lines.each { |line| counts[line] = counts.fetch(line, 0) - 1 }
  counts.select { |_, n| n.positive? }
end
gotos_used = ->(code) { code.scan(/goto L(\d+);/).flatten.to_set }
labels_defined = ->(code) { code.scan(/^  L(\d+):;$/).flatten.to_set }

puts '== refusal set'
suite.check('the captured sets are empty for the methods without a nested block',
            on['route'][:captured].empty? && on['plain'][:captured].empty?)
suite.check('the captured sets name the nested block\'s registers for the captured methods',
            on['captured_branch'][:captured].any? && on['captured_loop'][:captured].any?)
refused_on = METHODS.to_h { |name| [name, on[name][:refusals]] }
suite.check('the refusal set is the one pinned here: only the captured methods are refused',
            refused_on == { 'route' => {}, 'plain' => {}, 'captured_branch' => { ineligible: 1 },
                            'captured_loop' => { ineligible: 1 } })
suite.check('stage B off counts no refusal',
            METHODS.all? { |name| off[name][:refusals].empty? })

puts '== accepted methods'
%w[route plain].each do |name|
  added = surplus.call(on[name][:code], off[name][:code])
  removed = surplus.call(off[name][:code], on[name][:code])
  suite.check("#{name}: stage B only removes lines and adds none",
              added.empty? && removed.values.sum.positive?)
  suite.check("#{name}: every goto left in the pruned text lands on a label it defines",
              (gotos_used.call(on[name][:code]) - labels_defined.call(on[name][:code])).empty?)
end
arm = /mrb_int_add_overflow\(mrb_fixnum\(r\d+\), 1, &bc2cpp_z\)/
suite.check('route: the unreachable `r += 1 if y` arm is gone',
            !arm.match?(on['route'][:code]) && arm.match?(off['route'][:code]))

puts '== refused methods'
%w[captured_branch captured_loop].each do |name|
  suite.check("#{name}: the refused method compiles to the same text with stage B on or off",
              on[name][:code] == off[name][:code])
end

puts '== declarations'
resolver = CodeGen.allocate
CodeGen.arm_prune_refusals.clear
suite.check('a declaration in the held texts keeps them, and counts a declaration refusal',
            resolver.send(:arm_prune_decide, { 3 => "  mrb_value t = r1;\n" }) == false &&
            CodeGen.arm_prune_refusals[:declaration] == 1)
suite.check('held texts with no declaration may be dropped',
            resolver.send(:arm_prune_decide, { 3 => "  r1 = r2;\n" }) == true)

suite.finish!
