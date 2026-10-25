#!/usr/bin/env ruby
# frozen_string_literal: true

# Unit checks for IrSymbolFlow: the finite name set of a
# constant dispatch table, and the premises that reject a table which could hold a non-literal name. Each fixture
# is compiled by mrbc and analysed as a closed world.
#
# Usage: MRBC=path/to/host/mrbc ruby scripts/bc2cpp/symbol_flow_check.rb

require 'set'
require_relative 'check_support'
require_relative '../../tools/bc2cpp/irep'
require_relative '../../tools/bc2cpp/ir_symbol_flow'

suite = FixtureCheck.new('symbol_flow_check')
suite.require_mrbc!

check = suite.method(:check)

def compiled(suite, source)
  suite.compile(source) do |ireps|
    names = {}
    ireps.each_value do |irep|
      irep.instructions.each do |insn|
        next unless %i[SDEF TDEF METHOD DEF].include?(insn.op)

        target = insn.typed.find { |o| o.kind == :irep }
        names[irep.reps[target.value]] = insn.sym if target && insn.sym && irep.reps[target.value]
      end
    end
    yield ireps, names
  end
end

# The universe of table const in source, or nil when the premises reject it.
def universe_of(suite, source, const)
  compiled(suite, source) { |ireps, names| IrSymbolFlow.dispatch_universes(ireps, names)[const] }
end

# The table each `send(*...)` splat send of source reads, in instruction order.
def splat_tables(suite, source)
  compiled(suite, source) do |ireps, _|
    ireps.values.flat_map do |irep|
      irep.instructions.each_with_index.filter_map do |insn, idx|
        next unless insn.sym == 'send' && insn.n_spec == '*'

        [IrSymbolFlow.splat_table(irep, idx, (insn.reg.to_i + 1).to_s)]
      end
    end.flatten(1)
  end
end

LITERAL_TABLE = <<~'EOS_FIXTURE'
  class Cpu
    TABLE = []
    def self.op(code, entry)
      TABLE[code] = [entry, :lit]
    end
    op(1, :_lda)
    op(2, :_sta)
    def self.run(code)
      send(*TABLE[code])
    end
  end
EOS_FIXTURE

uni = universe_of(suite, LITERAL_TABLE, 'TABLE')
check.call('a table of literal entries has a finite universe', uni.is_a?(Set))
check.call('the universe is exactly the stored names', uni == Set['_lda', '_sta', 'lit'])
check.call('`send(*TABLE[i])` reads TABLE', splat_tables(suite, LITERAL_TABLE) == ['TABLE'])

runtime_symbol = LITERAL_TABLE.sub('TABLE[code] = [entry, :lit]', 'TABLE[code] = [entry.to_s.to_sym, :lit]')
check.call('a table fed by to_sym is rejected (P5)', universe_of(suite, runtime_symbol, 'TABLE').nil?)

send_result = LITERAL_TABLE.sub('TABLE[code] = [entry, :lit]', 'TABLE[code] = [entry.size, :lit]')
check.call('a table storing a send result is rejected (P3)', universe_of(suite, send_result, 'TABLE').nil?)

outside_writer = LITERAL_TABLE + <<~'EOS_FIXTURE'
  class Cpu
    def self.poke(code)
      TABLE[code] = [:wait_frame]
    end
  end
EOS_FIXTURE
check.call('a table written from a second method is rejected (P1)', universe_of(suite, outside_writer, 'TABLE').nil?)

# Each of these lets :evil into the table where the premises do not look.
argument = LITERAL_TABLE.sub('send(*TABLE[code])', 'fill(TABLE); send(*TABLE[code])')
check.call('a table passed as an argument is rejected (P2)', universe_of(suite, argument, 'TABLE').nil?)
receiver = LITERAL_TABLE.sub('send(*TABLE[code])', 'TABLE.push([:evil]); send(*TABLE[code])')
check.call('a table that is a send receiver is rejected (P2)', universe_of(suite, receiver, 'TABLE').nil?)
scoped = LITERAL_TABLE.sub('send(*TABLE[code])', 'Cpu::TABLE.clear; send(*TABLE[code])')
check.call('a table read as Cpu::TABLE is rejected (P2)', universe_of(suite, scoped, 'TABLE').nil?)
element = LITERAL_TABLE.sub('send(*TABLE[code])', 'TABLE[code][0] = :evil; send(*TABLE[code])')
check.call('a table whose element is written is rejected (P2)', universe_of(suite, element, 'TABLE').nil?)
spelled = LITERAL_TABLE.sub('send(*TABLE[code])', 'send(:op, code, :evil); send(*TABLE[code])')
check.call('a writer named as data is rejected (P2)', universe_of(suite, spelled, 'TABLE').nil?)

splat_call = LITERAL_TABLE.sub('op(2, :_sta)', 'args = [2, :_sta]; op(*args)')
check.call('a splat call of the writer is rejected (P4)', universe_of(suite, splat_call, 'TABLE').nil?)
mutated = LITERAL_TABLE.sub('TABLE[code] = [entry, :lit]', 'row = [entry]; row.concat([:x]); TABLE[code] = row')
check.call('an entry mutated by a non-core mutator is rejected (P5)', universe_of(suite, mutated, 'TABLE').nil?)
pushed = LITERAL_TABLE.sub('TABLE[code] = [entry, :lit]', 'row = [entry]; row << :pushed; TABLE[code] = row')
check.call('an entry grown by << keeps a finite universe', universe_of(suite, pushed, 'TABLE') == Set['_lda', '_sta', 'pushed'])

prefixed = LITERAL_TABLE.sub('send(*TABLE[code])', 'send(:wait, *TABLE[code])')
check.call('`send(:name, *TABLE[i])` is not a table send', splat_tables(suite, prefixed) == [nil])

suite.finish!
