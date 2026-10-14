#!/usr/bin/env ruby
# frozen_string_literal: true

require 'set'
require_relative '../../tools/bc2cpp/irep'
require_relative '../../tools/bc2cpp/ir_block_captures'

def instruction(index, op, args)
  Insn.new(lineno: 1, addr: index * 4, op: op, args: args, raw: "#{op} #{args}")
end

def check(name, condition)
  raise name unless condition

  puts "ok #{name}"
end

child = Irep.new(label: 'block', nlocals: 2, instructions: [instruction(0, 'ENTER', '1:0:0:0:0:0:0:0 (0x0)'),
  instruction(1, 'GETUPVAR', "R2\t1\t0"), instruction(2, 'MOVE', "R3\tR2"), instruction(3, 'RETURN', 'R3')])
parent = Irep.new(label: 'method', nlocals: 2, reps: ['block'], instructions: [
  instruction(0, 'ENTER', '0:0:0:0:0:0:0:0 (0x0)'), instruction(1, 'LOADSYM', 'R1 :captured'),
  instruction(2, 'ARRAY', "R2\t0"), instruction(3, 'BLOCK', "R3\tI[0]"),
  instruction(4, 'SENDB', "R2\t:map\tn=0"), instruction(5, 'RETURN', 'R2')])
tree = { 'method' => parent, 'block' => child }
parent.tree = tree
child.tree = tree
build = lambda do |**options|
  IrBlockCaptures.new(parent: parent, child: child, producer_index: 3, call_index: 4,
                      parent_analysis: BytecodeIR::Types.new(parent), ireps: tree, **options)
end
check('arbitrary block calls lack a synchronous invocation proof', build.call.fact_at(3, '3').nil?)
fact = build.call(invocation_safe: true).fact_at(3, '3')
check('immediate stable capture survives a block MOVE', fact && fact.classes == Set[:Symbol] && !fact.declared?)
child.instructions[1] = instruction(1, 'GETUPVAR', "R2\t1\t1")
check('non-immediate environment remains unknown', build.call(invocation_safe: true).fact_at(3, '3').nil?)
child.instructions[1] = instruction(1, 'SETUPVAR', "R2\t1\t0")
check('a block capture writer is refused', build.call(invocation_safe: true).fact_at(3, '3').nil?)
child.instructions[1] = instruction(1, 'SEND0', "R2\t:opaque")
check('opaque effects in the block are refused', build.call(invocation_safe: true).fact_at(3, '3').nil?)
puts 'block capture checks passed'

if ENV['MRBC']
  require 'tmpdir'
  Dir.mktmpdir('ir-block-captures') do |directory|
    path = File.join(directory, 'fixture.rb')
    File.write(path, <<~SOURCE)
      def stable
        captured = :held
        [1].map { |element| captured }
      end
      def unstable
        captured = :held
        [1].map { |element| captured = element }
      end
      def conditional(captured)
        [1].map { |element| captured }
      end
    SOURCE
    ireps = load_ireps(run_mrbc([path], 'captures', directory)).first
    methods = ireps.values.select { |body| body.instructions.any? { |insn| insn.op == 'SENDB' } }
    methods.each do |body|
      call_index = body.instructions.index { |insn| insn.op == 'SENDB' }
      producer_index = body.instructions.index { |insn| insn.op == 'BLOCK' }
      block = ireps[body.reps[body.instructions[producer_index].block_index]]
      capture_index = block.instructions.index { |insn| insn.op == 'GETUPVAR' }
      next unless capture_index

      declared = body.enter.enter_fields.first == 1
      analysis = BytecodeIR::Types.new(body, declared_args: declared ? { '1' => Set[:String] } : {})
      resolver = IrBlockCaptures.new(parent: body, child: block, call_index: call_index, producer_index: producer_index,
                                     parent_analysis: analysis, ireps: ireps, invocation_safe: true)
      return_index = block.instructions.index { |insn| insn.op == 'RETURN' }
      fact = resolver.fact_at(return_index, block.instructions[return_index].reg)
      check('real mrbc stable capture preserves provenance', fact && fact.classes == Set[declared ? :String : :Symbol] && fact.declared? == declared)
      check('declared capture keeps its argument contract', fact.contracts == ['argument:R1']) if declared
    end
    writer = ireps.values.find { |body| body.instructions.any? { |insn| insn.op == 'SETUPVAR' } }
    writer_parent = methods.find { |body| body.reps.include?(writer.label) }
    call_index = writer_parent.instructions.index { |insn| insn.op == 'SENDB' }
    producer_index = writer_parent.instructions.index { |insn| insn.op == 'BLOCK' }
    resolver = IrBlockCaptures.new(parent: writer_parent, child: writer, call_index: call_index, producer_index: producer_index,
                                   parent_analysis: BytecodeIR::Types.new(writer_parent), ireps: ireps, invocation_safe: true)
    check('real mrbc capture mutation remains unknown', resolver.fact_at(writer.instructions.length - 1, '1').nil?)
  end
else
  puts 'SKIP mrbc capture fixtures (set MRBC)'
end
