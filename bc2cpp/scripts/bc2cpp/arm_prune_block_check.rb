#!/usr/bin/env ruby
# frozen_string_literal: true

# ARM_PRUNE stage A for block bodies (tools/bc2cpp/codegen_arm_prune.rb, ADR 0535). The fixture's block bodies are walked
# by the standalone block emitter at register offset 0, where a decided jump is decided: the body of `decided_in_block`
# has its `r = 1 if x` arm unreachable (x is nil), and the body of `ret_in_block` has the jump after its RETURN_BLK
# unreachable. Stage A only counts them, so the generated C++ is the same with the measurement on or off.
# Needs MRBC; without it the check prints SKIP and exits 0.
#
#   MRBC=path/to/host/mrbc ruby scripts/bc2cpp/arm_prune_block_check.rb

require 'set'
require_relative 'check_support'
require_relative '../../tools/bc2cpp/bc2cpp'

suite = FixtureCheck.new('arm_prune_block_check')
suite.require_mrbc!

SOURCE = <<~'RUBY'
  class Blk
    def decided_in_block(a)
      a.each { |v| x = nil; r = 1 if x; r }
    end
    def ret_in_block(a)
      a.each { |v| return v if v }
      nil
    end
    def plain_block(a)
      a.map { |v| v * 2 }
    end
    def lit_dead
      [1, 2].each { |v| x = nil; r = 1 if x; r }
    end
    def lit_each
      s = 0
      [1, 2, 3].each { |v| s += v }
      s
    end
  end
RUBY

# The generated C++ of every Blk method, and the block-body records stage A made while generating them.
generate = lambda do |env|
  previous = env.keys.to_h { |key| [key, ENV[key]] }
  env.each { |key, value| ENV[key] = value }
  CodeGen.arm_prune_blocks.clear
  suite.compile(SOURCE) do |ireps, root|
    registry = build_registry(ireps, root)[0]
    gen = CodeGen.new(ireps, registry, {}, {}, {}, {}, {}, {}, {}, {}, {}, Set.new)
    code = registry.values.flatten.select { |d| d.owner == 'Blk' }.sort_by(&:name).map do |d|
      gen.compile_method(d.irep).fetch(:code)
    end
    [code.join("\n"), CodeGen.arm_prune_blocks.dup]
  end
ensure
  previous.each { |key, value| ENV[key] = value }
end

on_code, on_records = generate.call('BC2CPP_PRUNE_ARMS' => '0')
off_code, off_records = generate.call('BC2CPP_PRUNE_ARMS' => '0', 'BC2CPP_PRUNE_BLOCKS' => '0')

puts '== stage A on block bodies'
suite.check('stage A counts the unreachable arm of the decided block body (`r = 1 if x`, x nil)',
            on_records.values.any? { |r| r && r[:unreachable] == Set[4] && r[:instructions] == 6 })
suite.check('stage A counts the body whose jump follows its RETURN_BLK as unreachable',
            on_records.values.count { |r| r && r[:unreachable].any? } == 2)
suite.check('stage A refuses no block body in the fixture',
            on_records.values.none?(&:nil?))
suite.check('stage A also records an inlined body, at its enclosing frame offset (not decided there)',
            on_records.keys.any? { |(_label, offset)| offset.positive? } &&
              on_records.select { |(_label, offset), _| offset.positive? }.values.all? { |r| r && r[:unreachable].empty? })
suite.check('the measurement changes no generated C++ (BC2CPP_PRUNE_BLOCKS=0 gives the same output)',
            on_code == off_code)
suite.check('with the measurement off nothing is recorded', off_records.empty?)

suite.finish!
