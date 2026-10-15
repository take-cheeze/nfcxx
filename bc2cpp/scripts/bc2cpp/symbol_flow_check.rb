#!/usr/bin/env ruby
# frozen_string_literal: true

# Unit checks for SymbolFlow (tools/bc2cpp/symbol_flow.rb): the finite name set of a constant
# dispatch table, and the premises that reject a table which could hold a non-literal name.
# Each fixture is compiled by mrbc and analysed as a closed world.
#
# Usage: MRBC=path/to/host/mrbc ruby scripts/bc2cpp/symbol_flow_check.rb

require 'set'
require 'tmpdir'
require_relative '../../tools/bc2cpp/irep'
require_relative '../../tools/bc2cpp/symbol_flow'

unless system(MRBC, '--version', out: File::NULL, err: File::NULL)
  puts '  SKIP: no host mrbc (set MRBC)'
  exit 0
end

failures = []
check = lambda do |what, condition|
  puts "  #{condition ? 'ok  ' : 'FAIL'} #{what}"
  failures << what unless condition
end

# The universe of table const in source, or nil when the premises reject it.
def universe_of(source, const)
  Dir.mktmpdir('symbol-flow-check-') do |dir|
    src = File.join(dir, 'fixture.rb')
    File.write(src, source)
    ireps, = compile_ireps([src], 'symbol_flow_check', dir, mrbc: MRBC)
    names = {}
    ireps.each_value do |irep|
      irep.instructions.each do |insn|
        next unless %w[SDEF TDEF METHOD DEF].include?(insn.op)

        target = insn.typed.find { |o| o.kind == :irep }
        names[irep.reps[target.value]] = insn.sym if target && insn.sym && irep.reps[target.value]
      end
    end
    SymbolFlow.dispatch_universes(ireps, names)[const]
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

uni = universe_of(LITERAL_TABLE, 'TABLE')
check.call('a table of literal entries has a finite universe', uni.is_a?(Set))
check.call('the universe holds the literal names', uni&.superset?(Set['_lda', '_sta', 'lit']))

runtime_symbol = LITERAL_TABLE.sub('TABLE[code] = [entry, :lit]', 'TABLE[code] = [entry.to_s.to_sym, :lit]')
check.call('a table fed by to_sym is rejected (P5)', universe_of(runtime_symbol, 'TABLE').nil?)

send_result = LITERAL_TABLE.sub('TABLE[code] = [entry, :lit]', 'TABLE[code] = [entry.size, :lit]')
check.call('a table storing a send result is rejected (P3)', universe_of(send_result, 'TABLE').nil?)

outside_writer = LITERAL_TABLE + <<~'EOS_FIXTURE'
  class Cpu
    def self.poke(code)
      TABLE[code] = [:wait_frame]
    end
  end
EOS_FIXTURE
check.call('a table written from a second method is rejected (P1)', universe_of(outside_writer, 'TABLE').nil?)

if failures.empty?
  puts 'bc2cpp symbol flow check: PASS'
else
  puts "bc2cpp symbol flow check: FAIL (#{failures.size})"
  exit 1
end
