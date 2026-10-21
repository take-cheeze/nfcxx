#!/usr/bin/env ruby
# frozen_string_literal: true

# ARM_PRUNE (tools/bc2cpp/codegen_arm_prune.rb). Stage A counts the instructions no edge reaches, in a graph where a
# decided jump keeps only its taken edge, and leaves the C++ unchanged. Stage B (BC2CPP_PRUNE_ARMS=1) drops that text
# from a method it can prove safe. The fixture has two instructions the decided folds make unreachable (`r += 1 if y`
# with y nil, and the jump that skips it). Stage B needs register flow off (BC2CPP_REGISTER_FLOW=0), because a method
# that register flow captures is refused, so the check sets it for its own compiles. Needs MRBC; without it the check
# prints SKIP and exits 0.
#
#   MRBC=path/to/host/mrbc ruby scripts/bc2cpp/arm_prune_check.rb

require 'set'
require_relative 'check_support'
require_relative '../../tools/bc2cpp/bc2cpp'

suite = FixtureCheck.new('arm_prune_check')
suite.require_mrbc!

SOURCE = <<~'RUBY'
  class Router
    def route(x)
      y = nil
      s = "a"
      z = x ? nil : "a"
      r = 0
      r += 1 if y
      r += 2 if s
      r += 4 if x
      r += 8 unless y
      r += 16 if y.nil?
      r += 32 if z
      r
    end
  end
RUBY

# The generated C++ of Router#route with the given environment settings, restored afterwards.
route_code = lambda do |env|
  previous = env.keys.to_h { |key| [key, ENV[key]] }
  env.each { |key, value| ENV[key] = value }
  suite.compile(SOURCE) do |ireps, root|
    registry = build_registry(ireps, root)[0]
    gen = CodeGen.new(ireps, registry, {}, {}, {}, {}, {}, {}, {}, {}, {}, Set.new)
    method = registry.fetch('route').find { |d| d.owner == 'Router' }
    gen.compile_method(method.irep).fetch(:code)
  end
ensure
  previous.each { |key, value| ENV[key] = value }
end

FLOW_OFF = { 'BC2CPP_REGISTER_FLOW' => '0', 'BC2CPP_PRUNE_ARMS' => '0' }.freeze
STAGE_B = FLOW_OFF.merge('BC2CPP_PRUNE_ARMS' => '1').freeze

plain = route_code.call(FLOW_OFF)
pruned = route_code.call(STAGE_B)
undecided = route_code.call(FLOW_OFF.merge('BC2CPP_DECIDED_BRANCH' => '0'))
undecided_pruned = route_code.call(STAGE_B.merge('BC2CPP_DECIDED_BRANCH' => '0'))

# The goto labels a method uses must each be defined in it.
labels_defined = ->(code) { code.scan(/^  L(\d+):;$/).flatten.to_set }
gotos_used = ->(code) { code.scan(/goto L(\d+);/).flatten.to_set }

puts '== stage A'
suite.check('with stage B off (0) the unreachable arm keeps its text',
            plain.include?('mrb_fixnum(r6), 1, &bc2cpp_z'))
suite.check('stage B is on when the variable is unset (the default)',
            route_code.call(FLOW_OFF.reject { |k, _| k == 'BC2CPP_PRUNE_ARMS' }) == pruned)
suite.check('the stage A count is positive on the fixture',
            CodeGen.arm_prune_stats[:unreachable].to_i.positive?)

puts '== stage B'
suite.check('stage B drops the unreachable `r += 1 if y` arm',
            plain.include?('mrb_fixnum(r6), 1, &bc2cpp_z') && !pruned.include?('mrb_fixnum(r6), 1, &bc2cpp_z'))
suite.check('stage B removes the pruned jump as well',
            plain.scan(/goto L\d+;/).size - pruned.scan(/goto L\d+;/).size == 1)
suite.check('stage B leaves a goto only to a label the method defines',
            (gotos_used.call(pruned) - labels_defined.call(pruned)).empty?)
# Multiset diff of the lines: stage B may only remove lines (the arm's comment, its block and its goto) and add none.
surplus = lambda do |from, minus|
  counts = from.lines.tally
  minus.lines.each { |line| counts[line] = counts.fetch(line, 0) - 1 }
  counts.select { |_, n| n.positive? }
end
removed = surplus.call(plain, pruned)
added = surplus.call(pruned, plain)
suite.check('stage B only removes the pruned lines and adds none',
            added.empty? && removed.values.sum == 3 &&
            removed.keys.all? { |l| l.include?('mrb_fixnum(r6), 1, &bc2cpp_z') || l.include?('// operands proven Fixnum') || l.match?(/goto L\d+;/) })
suite.check('without the decided folds nothing is unreachable, so stage B drops nothing',
            undecided_pruned == undecided)

puts '== declarations'
resolver = CodeGen.allocate
suite.check('a declaration outside every block is refused',
            resolver.send(:arm_prune_declares_outside_block?, 'mrb_value t = r1; r1 = t;'))
suite.check('a declaration inside its own block is not',
            !resolver.send(:arm_prune_declares_outside_block?, '{ mrb_int z; z = 1; r1 = z; }'))
suite.check('unbalanced braces are refused',
            resolver.send(:arm_prune_declares_outside_block?, '{ r1 = 1;'))

suite.finish!
