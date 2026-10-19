#!/usr/bin/env ruby
# frozen_string_literal: true

# Join soundness of the literal walks: a question asked of the textually last writer of a register
# answers for one arm of a join only. Each case compiles a snippet by mrbc and asserts the answer for EVERY path
# (the splat unroll uses a hand-built irep: mrbc lowers a `*` splat through ARYCAT, so it never shows the
# literal-ARRAY arm the walk reads).
#
# Usage: MRBC=path/to/host/mrbc ruby scripts/bc2cpp/ir_join_soundness_check.rb

require 'set'
require 'tmpdir'
require_relative '../../tools/bc2cpp/irep'
require_relative '../../tools/bc2cpp/bytecode_ir'
require_relative '../../tools/bc2cpp/dynamic_names'
require_relative '../../tools/bc2cpp/ivar_layout'
require_relative '../../tools/bc2cpp/codegen'
%w[codegen_keyword_send codegen_numeric_ivars codegen_numeric_returns].each do |file|
  require_relative "../../tools/bc2cpp/#{file}"
end

unless ENV['MRBC'] && system(ENV['MRBC'], '--version', out: File::NULL, err: File::NULL)
  puts '  SKIP: no host mrbc (set MRBC)'
  exit 0
end
MRBC_PATH = ENV.fetch('MRBC')

failures = []
check = lambda do |what, condition|
  puts "  #{condition ? 'ok  ' : 'FAIL'} #{what}"
  failures << what unless condition
end

# The ireps (label => Irep) of +source+ compiled by mrbc, yielded to the block.
def compiled(source)
  Dir.mktmpdir('ir-join-soundness-') do |dir|
    src = File.join(dir, 'fixture.rb')
    File.write(src, source)
    ireps, = compile_ireps([src], 'ir_join_soundness', dir, mrbc: MRBC_PATH)
    yield ireps
  end
end

# The one method body of a single-method +source+ (its irep is the only one with instructions beyond TDEF/RETURN).
def method_irep(source)
  compiled(source) { |ireps| ireps.values.max_by { |irep| irep.instructions.size } }
end

# Index of the first instruction of +irep+ whose op is +op+ (a String, or a Regexp) and whose symbol is +sym+ (or
# whose ivar is +ivar+). Implicit-self sends are SSEND/SSENDB, so a call site is matched by /SEND/.
def index_of(irep, op, sym: nil, ivar: nil)
  irep.instructions.index do |insn|
    (op.is_a?(Regexp) ? insn.op.match?(op) : insn.op == op) && (sym.nil? || insn.sym == sym) && (ivar.nil? || insn.ivar == ivar)
  end
end

gen = CodeGen.allocate

# --- 1. Splat unroll (codegen_keyword_send.rb splat_array_literal_regs) -------------------------------------------
def hand_insn(addr, op, args)
  Insn.new(lineno: 1, addr: addr, op: op, args: args, raw: "#{op} #{args}")
end

def hand_irep(list)
  Irep.new(label: 'splat_join', nlocals: 2, nregs: 8, pool: [], syms: [], reps: [], lv: nil,
           instructions: list, file: 'splat_join.rb', catch_handlers: [])
end

# `a = c ? [1, 2] : [3]; f(*a)` with the array in R5, the splat register of `SSEND R4 :f n=*`. Each arm's ARRAY
# writes R5 and both reach the send; the textually last one is `[3]`.
joined = hand_irep([
  hand_insn(0, 'JMPNOT', "R1\t12"),
  hand_insn(4, 'ARRAY', "R5\t2"),
  hand_insn(8, 'JMP', '16'),
  hand_insn(12, 'ARRAY', "R5\t1"),
  hand_insn(16, 'SSEND', "R4\t:f\tn=*")
])
check.call('splat unroll: an ARRAY that only one arm of a join writes is not the splat (was: unrolled to 1 element)',
           gen.splat_array_literal_regs(joined, 4, '5').nil?)

single = hand_irep([
  hand_insn(0, 'ARRAY', "R5\t2"),
  hand_insn(4, 'SSEND', "R4\t:f\tn=*")
])
check.call('splat unroll: a single reaching literal still unrolls to its two elements',
           gen.splat_array_literal_regs(single, 1, '5')&.size == 2)

# mrbc lowers both `f(*(c ? [1, 2] : [3]))` and `f(*a)` through LOADNIL + ARYCAT: the walk refuses, so the splat
# stays dynamic. Pins that the refusal is what mrbc output gets.
compiled(<<~'RUBY') do |ireps|
  def t(c)
    f(*(c ? [1, 2] : [3]))
  end
  def u(c)
    a = c ? [1, 2] : [3]
    f(*a)
  end
RUBY
  splats = ireps.values.flat_map do |irep|
    irep.instructions.each_index.filter_map { |idx| [irep, idx] if irep.instructions[idx].op == 'SSEND' && irep.instructions[idx].n_spec == '*' }
  end
  check.call('mrbc splat of a join: both sends are n=* splats (fixture sanity)', splats.size == 2)
  check.call('mrbc splat of a join: refused, so the splat stays dynamic',
             splats.all? { |irep, idx| gen.splat_array_literal_regs(irep, idx, (irep.instructions[idx].reg.to_i + 1).to_s).nil? })
end

# --- 2. Literal-argument guards at a join ------------------------------------------------------------------------
ivar_mixed = method_irep(<<~'RUBY')
  class K
    def m(c, k)
      instance_variable_set(c ? k : :@a, 1)
    end
  end
RUBY
ivar_site = index_of(ivar_mixed, /SEND/, sym: 'instance_variable_set')
check.call('ivar name: a join of a parameter and a literal is not a literal name (was: literal)',
           gen.literal_ivar_argument?(ivar_mixed, ivar_site, ivar_mixed.instructions[ivar_site]) == false)

ivar_both = method_irep(<<~'RUBY')
  class K
    def m(c)
      instance_variable_set(c ? :@a : :@b, 1)
    end
  end
RUBY
both_site = index_of(ivar_both, /SEND/, sym: 'instance_variable_set')
check.call('ivar name: a join of two literal @names stays literal (unchanged)',
           gen.literal_ivar_argument?(ivar_both, both_site, ivar_both.instructions[both_site]) == true)

block_mixed = method_irep(<<~'RUBY')
  class K
    def m(c, b)
      instance_eval(&(c ? b : ->() { 1 }))
    end
  end
RUBY
block_site = index_of(block_mixed, /SEND/, sym: 'instance_eval')
check.call('block: a join of a LAMBDA and a parameter block is not literal (was: literal)',
           gen.literal_block_argument?(block_mixed, block_site, block_mixed.instructions[block_site]) == false)

block_both = method_irep(<<~'RUBY')
  class K
    def m(c)
      instance_eval(&(c ? ->() { 1 } : ->() { 2 }))
    end
  end
RUBY
both_block_site = index_of(block_both, /SEND/, sym: 'instance_eval')
check.call('block: a join of two LAMBDAs stays literal (unchanged)',
           gen.literal_block_argument?(block_both, both_block_site, block_both.instructions[both_block_site]) == true)

alias_mixed = method_irep(<<~'RUBY')
  class K
    def m(c, k)
      alias_method(c ? k : :old_name, :new_name)
    end
  end
RUBY
check.call('aliased names: a join of a parameter and a literal name refuses (was: the literal arm only)',
           gen.aliased_operand_names(alias_mixed).nil?)

alias_both = method_irep(<<~'RUBY')
  class K
    def m(c)
      alias_method(c ? :old_one : :old_two, :new_name)
    end
  end
RUBY
check.call('aliased names: a join of two literal names keeps both names (was: the textually last arm only)',
           gen.aliased_operand_names(alias_both) == Set['old_one', 'old_two', 'new_name'] ||
           gen.aliased_operand_names(alias_both) == Set[:old_one, :old_two, :new_name])

compiled(<<~'RUBY') do |ireps|
  class K
    def m(c, k)
      send(c ? k : :foo)
    end
  end
RUBY
  check.call('dynamic names: a send whose name joins a parameter with a literal is computed (was: literal)',
             DynamicNames.analyze(ireps)[1] == true)
end

compiled(<<~'RUBY') do |ireps|
  class K
    def m(c)
      send(c ? :foo : :bar)
    end
  end
RUBY
  check.call('dynamic names: a send whose name is one of two literals is not computed (unchanged)',
             DynamicNames.analyze(ireps)[1] == false)
end

# --- 3. Fixnum-or-nil declaration tolerance (ivar_layout.rb readable_but_other) -----------------------------------
ivar_str = method_irep(<<~'RUBY')
  class K
    def m(c)
      x = c ? "s" : nil
      @f = x
    end
  end
RUBY
setiv = index_of(ivar_str, 'SETIV', ivar: 'f')
check.call('readable_but_other: a join of a STRING and nil is readable as another type (was: tolerated)',
           IvarLayout.readable_but_other(ivar_str, setiv, ivar_str.instructions[setiv].regs.first) == true)

if failures.empty?
  puts 'bc2cpp ir join soundness check: PASS'
else
  puts "bc2cpp ir join soundness check: FAIL (#{failures.size})"
  exit 1
end
