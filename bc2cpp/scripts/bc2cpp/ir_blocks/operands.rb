#!/usr/bin/env ruby
# frozen_string_literal: true

# IR_BLOCK_OPERANDS: the block and yield analyses read registers through BytecodeIR reaching
# definitions. Real mrbc fixtures for the shapes the textual-predecessor walks answered wrongly: a join, a block
# reached through a local, a nested block's SETUPVAR and the receiver of `x[i]`.
#
# Usage: MRBC=path/to/mrbc ruby scripts/bc2cpp/ir_blocks_check.rb

require 'set'

ENV['BC2CPP_SIG_DIRS'] = ''
require_relative '../../../tools/bc2cpp/bc2cpp'

failures = []
check = lambda do |what, condition|
  puts "  #{condition ? 'ok  ' : 'FAIL'} #{what}"
  failures << what unless condition
end

# [BlockSelfWorld result, YieldReach, the YieldReach node of method `m`] for +source+.
analyze = lambda do |source|
  Bc2cppIrBlockFixtures.compile(source, 'operands') do |ireps, root|
    registry, superclass_of, = build_registry(ireps, root)
    labels = registry.each_with_object({}) { |(name, defs), out| defs.each { |d| out[d.irep] = [d.owner, name] if d.irep } }
    world = BlockSelfWorld.analyze(ireps: ireps, method_labels: labels, superclass_of: superclass_of)
    reach = YieldReach.new(ireps: ireps, sound: true, opaque_names: Set.new, native_names: Set.new)
    [world, reach, reach.nodes.values.find { |n| n.kind == :method && n.name == 'm' }]
  end
end

world, = analyze.call("class A; def m(o); o.instance_exec { 1 }; end; end\n")
check.call('an adjacent literal block at a rebinder is rebound and the world holds', world.holds? && world.rebound.size == 1)

world, = analyze.call("class A; def m(o); b = -> { 1 }; o.instance_exec(&b); end; end\n")
check.call('a lambda reached through a local is a literal rebinder site', world.holds? && world.rebound.size == 1)

world, = analyze.call("class A; def m(o, c); b = c ? -> { 1 } : -> { 2 }; o.instance_exec(&b); end; end\n")
check.call('both lambdas of a join are rebound', world.holds? && world.rebound.size == 2)

world, = analyze.call("class A; def m(o, &blk); o.instance_exec(&blk); end; end\n")
check.call('a block parameter at a rebinder still fails the world fact', !world.holds?)

world, = analyze.call(<<~RUBY)
  class A
    def m(o, &blk)
      name = :foo
      [1].each { name = o.pick }
      o.send(name, &blk)
    end
  end
RUBY
check.call("a nested block's SETUPVAR refutes the computed-send name proof",
           !world.holds? && world.why.to_s.include?('not a literal block'))

_, _, node = analyze.call("class A; def m(c, &blk); b = c ? blk : nil; @x = b; end; end\n")
check.call('a block stored through a conditional assignment is captured', node&.captured == true)

_, _, node = analyze.call("class A; def m(&blk); blk.call; @x = 1; end; end\n")
check.call('a block only called is not captured', node&.captured == false)

_, _, node = analyze.call("class A; def m(pr); pr[1]; end; end\n")
check.call('`pr[i]` on a parameter may run a Proc', node&.proc_call == true)

_, _, node = analyze.call("class A; def m; a = [1, 2]; i = 0; a[i]; end; end\n")
check.call('`a[i]` on an Array literal runs none', node&.proc_call == false)

_, reach, node = analyze.call("class A; def m; e = Enumerator; e.new { |y| y << 1 }; end; end\n")
check.call('a generator literal block through a constant local builds an enumerator',
           node && reach.builds_enumerator?(node.label) && reach.nodes.values.count(&:generator) == 1)

if failures.empty?
  puts 'ir_block_operands_check: all checks passed'
else
  warn "ir_block_operands_check: #{failures.size} failure(s)"
  exit 1
end
