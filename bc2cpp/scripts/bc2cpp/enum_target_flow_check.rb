#!/usr/bin/env ruby
# frozen_string_literal: true

require_relative 'check_support'
require_relative '../../tools/bc2cpp/irep'
require_relative '../../tools/bc2cpp/call_site_index'

suite = FixtureCheck.new('enum_target_flow_check')

def enum_fixture(rows, handlers: [], pool: [])
  instructions = rows.each_with_index.map do |(op, args), index|
    Insn.new(lineno: 1, addr: index * 4, op: op, args: args, raw: "#{op} #{args}")
  end
  Irep.new(label: 'enum', instructions: instructions, pool: pool, reps: [], nlocals: 1, nregs: 12,
           catch_handlers: handlers)
end

def enum_index(irep)
  CallSiteIndex.build({ irep.label => irep })
end

send_name = ['SSEND', 'R1 :to_enum n=2']
join = [['JMPIF', 'R0 012'], ['LOADSYM', 'R2 :first'], ['JMP', '016'], ['LOADSYM', 'R2 :second'], send_name]
irep = enum_fixture(join)
index = enum_index(irep)
suite.check('different join symbols both receive the forwarded caller',
            %w[first second].all? { |name| index[name] == [[irep, 4, 2, 1]] })
suite.check('finite alternatives do not poison unrelated names', CallSiteIndex.sites(index, 'other').empty?)
suite.check('singleton API refuses multiple alternatives', CallSiteIndex.enum_target(irep, 4, irep.instructions[4], 2).nil?)
join[3] = ['LOADSYM', 'R2 :first']
irep = enum_fixture(join)
suite.check('agreeing join symbols deduplicate caller', enum_index(irep)['first'].size == 1)
suite.check('singleton API accepts agreeing joins', CallSiteIndex.enum_target(irep, 4, irep.instructions[4], 2) == 'first')
join[3] = ['MOVE', 'R2 R8']
index = enum_index(enum_fixture(join))
suite.check('one unknown join arm preserves unknown fanout',
            index['first'].empty? && CallSiteIndex.sites(index, 'anything').size == 1)
join[3] = ['LOADNIL', 'R2 (nil)']
index = enum_index(enum_fixture(join))
suite.check('one non-Symbol join arm preserves unknown fanout',
            index['first'].empty? && CallSiteIndex.sites(index, 'anything').size == 1)
irep = enum_fixture([['LOADSYM', 'R7 :first'], ['MOVE', 'R6 R7'], ['MOVE', 'R2 R6'], send_name])
suite.check('name aliases resolve to original symbol', enum_index(irep)['first'].size == 1)
irep = enum_fixture([['LOADSYM', 'R2 :first'], ['LOADSYM', 'R8 :unrelated'], send_name])
suite.check('unrelated nearer symbols do not change target', enum_index(irep)['first'].size == 1)
irep = enum_fixture([['LOADSYM', 'R2 :first'], ['LOADNIL', 'R2 (nil)'], send_name])
suite.check('overwritten symbol is unknown', enum_index(irep)[CallSiteIndex::UNKNOWN_TARGET].size == 1)
irep = enum_fixture([['SYMBOL', 'R2 L[0]'], send_name], pool: ['odd name'])
suite.check('pooled symbol preserves full name', enum_index(irep)['odd name'].size == 1)
irep = enum_fixture([['STRING', 'R2 L[0]'], send_name], pool: ['first'])
suite.check('mutable string names stay unknown', enum_index(irep)[CallSiteIndex::UNKNOWN_TARGET].size == 1)
loop_rows = [['LOADSYM', 'R2 :first'], ['JMPIF', 'R0 016'], ['NOP', ''], ['JMP', '004'], send_name]
suite.check('loop preserving symbol has finite target', enum_index(enum_fixture(loop_rows))['first'].size == 1)
loop_rows[2] = ['MOVE', 'R2 R8']
suite.check('loop clobber keeps unknown fanout', enum_index(enum_fixture(loop_rows))[CallSiteIndex::UNKNOWN_TARGET].size == 1)
handler = CatchHandler.new(type: :rescue, begin_addr: 4, end_addr: 12, target: 16)
rescued = [['LOADSYM', 'R2 :first'], ['NOP', ''], ['NOP', ''], ['JMP', '020'], send_name, ['STOP', '']]
suite.check('handler preserves symbols common to all predecessors',
            enum_index(enum_fixture(rescued, handlers: [handler]))['first'].size == 1)
rescued[2] = ['LOADSYM', 'R2 :second']
index = enum_index(enum_fixture(rescued, handlers: [handler]))
suite.check('handler alternative names all receive caller', %w[first second].all? { |name| index[name].size == 1 })
packed = [['LOADSYM', 'R2 :first'], ['ARRAY', 'R2 1'], ['MOVE', 'R8 R2'],
          ['SSEND', 'R7 :mutate n=1'], ['SSEND', 'R1 :to_enum n=*']]
index = enum_index(enum_fixture(packed))
suite.check('packed array passed through an alias is conservative',
            index['first'].empty? && index[CallSiteIndex::UNKNOWN_TARGET].size == 1)
irep = enum_fixture([['SSEND0', 'R1 :enum_for']])
suite.check('default target remains each with no arguments', enum_index(irep)['each'] == [[irep, 0, 2, 0]])
irep = enum_fixture([['LOADSYM', 'R2 :first'], ['SSEND', 'R1 :enum_for n=1|nk=1']])
suite.check('keywords preserve target but refuse positional arity', enum_index(irep)['first'] == [[irep, 1, 2, nil]])

compiler_available = ENV['MRBC'] || ENV.fetch('PATH', '').split(File::PATH_SEPARATOR).any? do |directory|
  File.executable?(File.join(directory, 'mrbc'))
end
if compiler_available
  suite.require_mrbc!
  suite.compile('def run(c); name = c ? :first : :second; enum_for(name, 1); end') do |ireps|
    index = CallSiteIndex.build(ireps)
    suite.check('binary compiler join records every target', %w[first second].all? { |name| index[name].size == 1 })
    suite.check('binary compiler join preserves forwarded arity', %w[first second].all? { |name| index[name].first.last == 1 })
    suite.check('binary compiler join has no unknown fanout', index[CallSiteIndex::UNKNOWN_TARGET].empty?)
  end
else
  puts '  SKIP binary compiler fixture: set MRBC or put mrbc on PATH'
end
suite.finish!
