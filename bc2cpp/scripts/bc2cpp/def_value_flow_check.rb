#!/usr/bin/env ruby
# frozen_string_literal: true

require_relative 'check_support'
require_relative '../../tools/bc2cpp/irep'
require_relative '../../tools/bc2cpp/closed_world'

suite = FixtureCheck.new('def_value_flow_check')

def fixture(rows, handlers: [])
  insns = rows.each_with_index.map do |(op, args), index|
    Insn.new(lineno: 1, addr: index * 4, op: op, args: args, raw: "#{op} #{args}")
  end
  Irep.new(label: 'body', instructions: insns, reps: %w[first second], pool: [], syms: [],
           nlocals: 1, nregs: 12, catch_handlers: handlers)
end

def unknown?(rows, registered: %w[first second], handlers: [])
  irep = fixture(rows, handlers: handlers)
  registry = { 'target' => registered.map { |label| MethodDef.new(name: 'target', owner: 'Box', irep: label) } }
  world = ClosedWorld.new(ireps: { irep.label => irep }, registry: registry, class_decls: {}, walked: Set.new,
                          native_paths: [], ruby_paths: [])
  world.instance_variable_get(:@unknown_defs).include?('target')
end

method = ['METHOD', 'R2 I[0]']
define = ['DEF', 'R1 :target (R2)']
suite.check('straight-line METHOD is registered', !unknown?([method, define]))
suite.check('unrelated nearer METHOD cannot replace actual body',
            unknown?([method, ['METHOD', 'R8 I[1]'], define], registered: ['second']))
suite.check('unrelated unregistered METHOD does not hide registered body',
            !unknown?([method, ['METHOD', 'R8 I[1]'], define], registered: ['first']))
suite.check('MOVE chain reaches the original method value',
            !unknown?([['METHOD', 'R7 I[0]'], ['MOVE', 'R6 R7'], ['MOVE', 'R2 R6'], define]))
suite.check('overwritten method register refuses', unknown?([method, ['LOADNIL', 'R2 (nil)'], define]))
suite.check('entry value refuses despite unrelated registered METHOD', unknown?([['METHOD', 'R8 I[0]'], define]))
suite.check('missing child refuses', unknown?([['METHOD', 'R2 I[9]'], define]))
suite.check('unregistered actual body refuses', unknown?([method, define], registered: ['second']))
join = [['JMPIF', 'R0 012'], method, ['JMP', '016'], ['METHOD', 'R2 I[0]'], define]
suite.check('join agreeing on body is registered', !unknown?(join))
different = join.map(&:dup)
different[3] = ['METHOD', 'R2 I[1]']
suite.check('different registered bodies at join refuse attribution', unknown?(different))
unknown_arm = join.map(&:dup)
unknown_arm[3] = ['LOADNIL', 'R2 (nil)']
suite.check('unknown join arm refuses', unknown?(unknown_arm))
loop_rows = [method, ['JMPIF', 'R0 016'], ['NOP', ''], ['JMP', '004'], define]
suite.check('loop preserving method value is registered', !unknown?(loop_rows))
loop_rows[2] = ['LOADNIL', 'R2 (nil)']
suite.check('loop overwriting method value refuses', unknown?(loop_rows))
handler = CatchHandler.new(type: :rescue, begin_addr: 4, end_addr: 12, target: 16)
rescued = [method, ['NOP', ''], ['NOP', ''], ['JMP', '020'], define, ['STOP', '']]
suite.check('handler preserves the method value when every incoming path agrees',
            !unknown?(rescued, handlers: [handler]))
rescued[2] = ['LOADNIL', 'R2 (nil)']
suite.check('handler observes every possible prior writer', unknown?(rescued, handlers: [handler]))
compiler_available = ENV['MRBC'] || ENV.fetch('PATH', '').split(File::PATH_SEPARATOR).any? do |directory|
  File.executable?(File.join(directory, 'mrbc'))
end
if compiler_available
  suite.require_mrbc!
  suite.compile('class Box; def target; 7; end; end') do |ireps|
    registry = {}
    ireps.each_value do |irep|
      irep.instructions.each do |insn|
        next unless %w[TDEF SDEF].include?(insn.op)

        registry[insn.sym] = [MethodDef.new(name: insn.sym, owner: 'Box', irep: irep.reps[insn.block_index])]
      end
    end
    world = ClosedWorld.new(ireps: ireps, registry: registry, class_decls: {}, walked: Set.new,
                            native_paths: [], ruby_paths: [])
    suite.check('binary compiler fixture retains registered direct definitions',
                registry.key?('target') && !world.instance_variable_get(:@unknown_defs).include?('target'))
  end
else
  puts '  SKIP binary compiler fixture: set MRBC or put mrbc on PATH'
end
suite.finish!
