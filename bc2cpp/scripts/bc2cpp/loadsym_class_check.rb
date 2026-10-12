#!/usr/bin/env ruby
# frozen_string_literal: true

# LOADSYM_CLASS (docs/adr/0428): a Symbol literal in a register carries the Symbol class bit in the numeric flow,
# the bit a Symbol slot of a frozen table already carries (ADR 0424), and a kind_of test against Symbol decides that
# bit (the one-class chain of class_test_chain). Every other consumer of the numeric masks keeps refusing or
# treating the bit as an ordinary class bit (docs/bc2cpp-symbol-class.md).
#
# 1. Host (CRuby, no mrbc): a hand-built `LOADSYM R1 :a; RETURN R1` through NumericFlow with the numeric oracle's
#    literal mask, which is the Symbol bit with the switch on and OTHER with BC2CPP_LOADSYM_CLASS=0; the oracle
#    method itself (NumericOracle#literal_class_mask); the class-test verdicts a Symbol bit gets from its chain.
# 2. Generated code (MRBC): a closed-world fixture. The facts report names a Symbol-returning method SYM (NUMRET),
#    and the numeric proofs of Integer-narrowed values are unchanged by the bit; an arithmetic on a Symbol keeps the
#    guarded send. BC2CPP_LOADSYM_CLASS=0 names the same method OTHER.
#
# Usage: ruby scripts/bc2cpp/loadsym_class_check.rb                       (host section)
#        MRBC=path/to/mrbc ruby scripts/bc2cpp/loadsym_class_check.rb   (adds the generated-code section)

require 'tmpdir'
require_relative '../../tools/bc2cpp/irep'
require_relative '../../tools/bc2cpp/bytecode_ir'
require_relative '../../tools/bc2cpp/numeric_flow'
require_relative '../../tools/bc2cpp/codegen_frozen_tables'
require_relative '../../tools/bc2cpp/codegen_class_narrowing'
require_relative '../../tools/bc2cpp/codegen_numeric_proof'

failures = []
check = lambda do |what, condition|
  puts "  #{condition ? 'ok  ' : 'FAIL'} #{what}"
  failures << what unless condition
end

NF = NumericFlow
SYM = 1 << NF::CLASS_BIT_BASE
INT = NF::INT
OTHER = NF::OTHER
NIL_ = NF::NIL

# The closed world as the chain reads it: no class_parent for Symbol (the closed world does not name its superclass).
class ClosedWorldStub
  def class_parent(_name) = nil
end

# Only the state the numeric flow reads from a CodeGen: the Symbol bit, the class bits the chain names, the world.
def codegen(symbol_bit: SYM)
  cg = CodeGen.allocate
  cg.instance_variable_set(:@frozen_symbol_bit, symbol_bit)
  cg.instance_variable_set(:@numeric_class_bits, { 'Symbol' => SYM })
  cg.instance_variable_set(:@closed_world, ClosedWorldStub.new)
  cg
end

# The oracle NumericFlow asks about a literal; every other fact is the empty answer.
class LiteralOracle
  def initialize(bit)
    @bit = bit
  end

  def literal_class_mask(insn) = insn.op == 'LOADSYM' ? @bit : nil
  def entry_mask(_irep, _reg) = OTHER
  def const_mask(_insn) = OTHER
  def ivar_slots(_irep) = []
  def ivar_entry_mask(_irep, _name) = OTHER
  def ivar_fact_mask(_irep, _name) = OTHER
  def upvar_mask(_irep, _insn) = OTHER
  def pool_mask(_irep, _insn) = OTHER
  def op_native?(_sym) = false
  def nil_raises?(_sym) = false
  def send_mask(_irep, _index, _insn, _state) = OTHER
end

def symbol_program
  irep = Irep.new(label: 'sym', nregs: 4, nlocals: 1)
  rows = [['LOADSYM', 'R1 :a'], ['RETURN', 'R1']]
  irep.instructions = rows.each_with_index.map do |(op, args), address|
    Insn.new(lineno: 1, addr: address, op: op, args: args, raw: "#{op} #{args}")
  end
  irep
end

def loadsym_mask(bit)
  irep = symbol_program
  states = NumericFlow.states(irep, LiteralOracle.new(bit), [])
  states && states[1] && states[1][1]
end

# ---------------------------------------------------------------------------
puts '-- host: the numeric flow reads a LOADSYM register as the Symbol bit'
check.call('a LOADSYM register holds the Symbol bit when the numeric oracle gives it', loadsym_mask(SYM) == SYM)
check.call('without a literal mask (switch off, no bit) it holds OTHER', loadsym_mask(nil) == OTHER)

cg = codegen
oracle = CodeGen::NumericOracle.new(cg)
loadsym = symbol_program.instructions[0]
loadtrue = Insn.new(lineno: 1, addr: 0, op: 'LOADTRUE', args: 'R1', raw: 'LOADTRUE R1')
check.call('CodeGen::NumericOracle gives LOADSYM the Symbol bit', oracle.literal_class_mask(loadsym) == SYM)
check.call('CodeGen::NumericOracle gives TrueClass and FalseClass literals no bit here', oracle.literal_class_mask(loadtrue).nil?)
check.call('no Symbol bit allocated: LOADSYM is OTHER', CodeGen::NumericOracle.new(codegen(symbol_bit: nil)).literal_class_mask(loadsym).nil?)

def with_loadsym_switch(value)
  saved = ENV.fetch('BC2CPP_LOADSYM_CLASS', nil)
  value.nil? ? ENV.delete('BC2CPP_LOADSYM_CLASS') : ENV['BC2CPP_LOADSYM_CLASS'] = value
  yield
ensure
  saved.nil? ? ENV.delete('BC2CPP_LOADSYM_CLASS') : ENV['BC2CPP_LOADSYM_CLASS'] = saved
end

with_loadsym_switch('0') do
  check.call('BC2CPP_LOADSYM_CLASS=0: the numeric oracle gives LOADSYM no bit', oracle.literal_class_mask(loadsym).nil?)
  check.call('BC2CPP_LOADSYM_CLASS=0: a Symbol class test keeps the bit on both edges (no chain)',
             CodeGen::ClassTest.new(cg, :kind_of, 'Symbol').narrow(SYM, false) == SYM &&
             CodeGen::ClassTest.new(cg, :kind_of, 'Symbol').narrow(SYM, true) == SYM)
end
with_loadsym_switch(nil) do
  check.call('the switch defaults on', cg.loadsym_class_enabled?)
  check.call('a Symbol chain is exactly [Symbol]', cg.class_test_chain('Symbol') == ['Symbol'])
  integer = CodeGen::ClassTest.new(cg, :kind_of, 'Integer')
  check.call('is_a?(Integer) on INT|SYM: the truth edge drops Symbol', integer.narrow(INT | SYM, true) == INT)
  check.call('is_a?(Integer) on INT|SYM: the falsy edge keeps Symbol and drops Integer',
             integer.narrow(INT | SYM, false) == SYM)
  symbol = CodeGen::ClassTest.new(cg, :kind_of, 'Symbol')
  check.call('is_a?(Symbol) on INT|SYM: the truth edge keeps Symbol only', symbol.narrow(INT | SYM, true) == SYM)
  check.call('is_a?(Symbol) on SYM|NIL: the falsy edge keeps nil', symbol.narrow(SYM | NIL_, false) == NIL_)
  check.call('is_a?(Symbol) on SYM: the falsy edge proves no value (0)', symbol.narrow(SYM, false) == 0)
  check.call('an OTHER mask keeps OTHER through is_a?(Symbol) (Symbol has no positive class)',
             symbol.narrow(OTHER | SYM, true) == SYM | OTHER)
  check.call('is_a?(Numeric) drops Symbol and keeps Integer',
             CodeGen::ClassTest.new(cg, :kind_of, 'Numeric').narrow(SYM | INT, true) == INT)
end

# ---------------------------------------------------------------------------
puts '-- generated code (host mrbc)'
if ENV['MRBC']
  require_relative 'fixture_runtime'
  FIXTURE = <<~RUBY
    module LsTables
      NAMES = [:a, :b, :c].freeze
    end

    class LsUse
      def pick_sym; :a; end
      def pick_or_int(c); c ? :a : 1; end
      def narrow_int(c); x = pick_or_int(c); if x.is_a?(Integer) then x + 1 else 0 end; end
      def arith_sym; x = pick_sym; x + 1; end
      def cmp(c); v = c ? :a : :b; v ? 3 : 4; end
      def tab(i); (LsTables::NAMES[i] || 0); end
    end
  RUBY
  OWNERS = %w[LsTables LsUse].freeze
  SLOW = ->(src, dir, env: {}) do
    saved = env.to_h { |k, _| [k, ENV.fetch(k, nil)] }
    env.each { |k, v| ENV[k] = v }
    begin
      Bc2cppFixtureRuntime.generate(src, dir, closed: true, only_owners: OWNERS)
    ensure
      saved.each { |k, v| v ? ENV[k] = v : ENV.delete(k) }
    end
  end

  Dir.mktmpdir('loadsym_class') do |root|
    on_code, on_err = SLOW.call(FIXTURE, File.join(root, 'on'))
    off_code, off_err = SLOW.call(FIXTURE, File.join(root, 'off'), env: { 'BC2CPP_LOADSYM_CLASS' => '0' })
    check.call('the Symbol-returning method is named SYM in the facts report', on_err.include?('NUMRET pick_sym (SYM)'))
    check.call('BC2CPP_LOADSYM_CLASS=0 names it OTHER (no NUMRET for it)',
               !off_err.include?('NUMRET pick_sym') && off_err.include?('RETCLASS pick_sym (Symbol)'))
    arith_on = on_code[/\/\/ LsUse#arith_sym.*?\n\}\n/m].to_s
    check.call('an arithmetic on a Symbol keeps the guarded send (no NUMERIC_OPERAND_PROOF)',
               !arith_on.empty? && !arith_on.include?('NUMERIC_OPERAND_PROOF'))
    check.call('the Integer-narrowed value keeps its numeric proof with the bit on',
               on_code.scan('NUMERIC_OPERAND_PROOF').size >= off_code.scan('NUMERIC_OPERAND_PROOF').size)
    check.call('the on run generates the fixture', !on_code.empty?)
  end
else
  puts '  SKIP generated code: set MRBC'
end

if failures.empty?
  puts 'bc2cpp loadsym class check: PASS'
else
  warn "bc2cpp loadsym class check: #{failures.size} failure(s)"
  exit 1
end
