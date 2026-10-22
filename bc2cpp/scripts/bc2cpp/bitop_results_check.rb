#!/usr/bin/env ruby
# frozen_string_literal: true

# BITOP_RESULTS: `Integer & | ^ Integer` is claimed INT only for
# INT operands. `<<` and `>>` stay OTHER, and so does any operand of another class.
#
# Host only (no mrbc): the real CodeGen#numeric_send_on_number, driven directly and
# through NumericFlow.states on hand-built bytecode, so the rule is checked as the
# dataflow uses it. The kill switch BC2CPP_BITOP_RESULTS=0 must restore OTHER.
#
# Usage: ruby scripts/bc2cpp/bitop_results_check.rb

require 'set'
require_relative '../../tools/bc2cpp/irep'
require_relative '../../tools/bc2cpp/bytecode_ir'
require_relative '../../tools/bc2cpp/numeric_flow'
require_relative '../../tools/bc2cpp/codegen_numeric_returns'

failures = []
check = lambda do |what, condition|
  puts "  #{condition ? 'ok  ' : 'FAIL'} #{what}"
  failures << what unless condition
end

NF = NumericFlow
INT = NF::INT
FLT = NF::FLT
NIL_ = NF::NIL
OTHER = NF::OTHER

def insn(addr, op, args)
  Insn.new(lineno: 1, addr: addr, op: op, args: args, raw: "#{op} #{args}")
end

def irep_of(list, nregs: 8)
  Irep.new(label: "bitop#{list.hash}", nregs: nregs, instructions: list, catch_handlers: [], reps: [], pool: [])
end

# The CodeGen answer for a SEND-family result, one receiver bit at a time, as numeric_send_mask joins it.
# Registers the test seeds on entry (R2 receiver, R3 argument) come from +entry+.
class BitopOracle
  attr_accessor :entry

  def initialize(codegen)
    @codegen = codegen
    @entry = {}
  end

  def entry_mask(_irep, reg) = @entry.fetch(reg, NumericFlow::OTHER)
  def const_mask(_insn) = NumericFlow::OTHER
  def ivar_slots(_irep) = []
  def ivar_entry_mask(_irep, _name) = NumericFlow::OTHER
  def ivar_fact_mask(_irep, _name) = NumericFlow::OTHER
  def upvar_mask(_irep, _insn) = NumericFlow::OTHER
  def pool_mask(_irep, _insn) = NumericFlow::OTHER
  def op_native?(_sym) = true
  def nil_raises?(_sym) = true

  def send_mask(_irep, _index, insn, state)
    recv = state[insn.reg.to_i]
    return NumericFlow::OTHER unless recv
    return NumericFlow::OTHER if (recv & ~(INT | FLT)).nonzero?

    argc = insn.plain_fixed_argc? ? insn.argc : nil
    mask = 0
    [INT, FLT].each do |bit|
      mask |= @codegen.send(:numeric_send_on_number, bit, insn.sym, argc, insn, state) if (recv & bit).nonzero?
    end
    mask
  end
end

codegen = CodeGen.allocate
# numeric_nil_raises? is defined by another CodeGen file this check does not load; the `%` regression
# case only reads it, and nil raises on every operator the test uses.
def codegen.numeric_nil_raises?(_name) = true
oracle = BitopOracle.new(codegen)

# The table answer for `bit OP arg` (argc 1) or `bit OP` (argc 0). The argument is state[reg + 1], i.e. state[3].
def on_number(codegen, op, bit, arg, argc: 1)
  send_insn = argc == 1 ? insn(0, 'SEND', "R2\t:#{op}\tn=1") : insn(0, 'SEND0', "R2\t:#{op}")
  codegen.send(:numeric_send_on_number, bit, op, argc, send_insn, [0, 0, 0, arg])
end

# The dataflow answer for `recv OP arg`: R2 and R3 hold the masks on entry, the result is read at RETURN.
def send_result(oracle, op, recv_mask, arg_mask)
  oracle.entry = { 2 => recv_mask, 3 => arg_mask }
  irep = irep_of([insn(0, 'SEND', "R2\t:#{op}\tn=1"), insn(4, 'RETURN', 'R2')])
  states = NumericFlow.states(irep, oracle, Set.new)
  states && states[1][2]
end

puts '-- BITOP_RESULTS (host)'
ENV.delete('BC2CPP_BITOP_RESULTS')
%w[& | ^].each do |op|
  check.call("INT #{op} INT is INT", on_number(codegen, op, INT, INT) == INT)
  check.call("INT #{op} FLT is OTHER", on_number(codegen, op, INT, FLT) == OTHER)
  check.call("INT #{op} NIL is OTHER", on_number(codegen, op, INT, NIL_) == OTHER)
  check.call("INT #{op} OTHER is OTHER", on_number(codegen, op, INT, OTHER) == OTHER)
  check.call("FLT #{op} INT is OTHER (Float has no bit operators)", on_number(codegen, op, FLT, INT) == OTHER)
  check.call("INT #{op} unreached operand yields no value", on_number(codegen, op, INT, 0) == 0)
end
%w[<< >>].each do |op|
  check.call("INT #{op} INT stays OTHER (no range proof)", on_number(codegen, op, INT, INT) == OTHER)
end
check.call('a zero-argument & is not claimed', on_number(codegen, '&', INT, INT, argc: 0) == OTHER)
check.call('Integer % Integer keeps its arithmetic result (no regression)', on_number(codegen, '%', INT, INT) == INT)

# Dataflow level: the result register is what a later instruction reads.
check.call('the dataflow of INT & INT is INT', send_result(oracle, '&', INT, INT) == INT)
check.call('the dataflow of INT ^ INT is INT', send_result(oracle, '^', INT, INT) == INT)
check.call('the dataflow of INT & FLT is OTHER', send_result(oracle, '&', INT, FLT) == OTHER)
check.call('the dataflow of INT | NIL is OTHER', send_result(oracle, '|', INT, NIL_) == OTHER)
check.call('the dataflow of INT << INT is OTHER', send_result(oracle, '<<', INT, INT) == OTHER)
check.call('the dataflow of a union INT|FLT & INT joins the INT arm with the FLT arm (OTHER)',
           send_result(oracle, '&', INT | FLT, INT) == (INT | OTHER))

# Kill switch: BC2CPP_BITOP_RESULTS=0 restores the OTHER answer master gives.
ENV['BC2CPP_BITOP_RESULTS'] = '0'
begin
  check.call('kill switch off: INT & INT is OTHER again', on_number(codegen, '&', INT, INT) == OTHER)
  check.call('kill switch off: the dataflow of INT ^ INT is OTHER', send_result(oracle, '^', INT, INT) == OTHER)
  check.call('kill switch off: Integer % Integer is unchanged', on_number(codegen, '%', INT, INT) == INT)
ensure
  ENV.delete('BC2CPP_BITOP_RESULTS')
end

# With MRBC: the generated code of a closed-world fixture. Each operand is INT-proven (literals and an ivar only
# ever set to an Integer), so `+` and `*` on the bit results must lose their dynamic-send else (the core body
# path, NUMERIC_OPERAND_PROOF). A fixture argument would not prove it. BC2CPP_BITOP_RESULTS=0 must keep the else.
FIXTURE = <<~'RUBY'
  module BitopProbe
    class Bits
      def arithmetic
        n = 6
        (n & 3) + (n | 8) * 2
      end
    end
  end
RUBY

if ENV['MRBC']
  require_relative 'fixture_runtime'
  require 'tmpdir'

  # The generated body of Bits#arithmetic, from its comment to the end of its impl (the fall-through raise).
  arithmetic = lambda do |switch|
    previous = ENV.fetch('BC2CPP_BITOP_RESULTS', nil)
    if switch
      ENV['BC2CPP_BITOP_RESULTS'] = switch
    else
      ENV.delete('BC2CPP_BITOP_RESULTS')
    end
    begin
      Dir.mktmpdir('bitop') do |dir|
        code, _err = Bc2cppFixtureRuntime.generate(FIXTURE, dir)
        code[%r{// BitopProbe::Bits#arithmetic .*?fell off the end of its body"\);\n\}\n}m].to_s
      end
    ensure
      if previous
        ENV['BC2CPP_BITOP_RESULTS'] = previous
      else
        ENV.delete('BC2CPP_BITOP_RESULTS')
      end
    end
  end

  puts '-- BITOP_RESULTS (fixture, MRBC)'
  on = arithmetic.call(nil)
  off = arithmetic.call('0')
  check.call('the generated method was found in both arms', !on.empty? && !off.empty?)
  check.call('INT-proven bit results: + and * take the core body (no dynamic-send else)',
             on.include?('NUMERIC_OPERAND_PROOF :+') && on.include?('NUMERIC_OPERAND_PROOF :*'))
  check.call('kill switch off: + and * keep the FIXNUM_ARITHMETIC slow-path else',
             off.include?('FIXNUM_ARITHMETIC :+') && off.include?('FIXNUM_ARITHMETIC :*') &&
             !off.include?('NUMERIC_OPERAND_PROOF :+'))
end

if failures.empty?
  puts 'bitop_results_check: ok'
else
  warn "bitop_results_check: #{failures.size} failure(s)"
  exit 1
end
