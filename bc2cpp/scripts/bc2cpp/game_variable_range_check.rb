#!/usr/bin/env ruby
# encoding: UTF-8
# Check guarded Fixnum specialization for integer expressions in the game
# variable range, including the fallback for values that bypass the clamp.

require 'tmpdir'
require_relative '../../tools/bc2cpp/bc2cpp'

SRC = <<~'RUBY'
  module Game
    class Variables
      def [](id); @data[id] || 0; end
      def add(a, b); self[a] + self[b]; end
      def sub(a, b); self[a] - self[b]; end
      def mul(a, b); self[a] * self[b]; end
      def div(a, b); self[a] / self[b]; end
      def add_one(a); self[a] + 1; end
      def add_chain(a, b, c); (self[a] + self[b]) + self[c]; end
      def generic_add(left, right); left + right; end
    end
    class Other
      def [](id); id; end
      def add(a, b); self[a] + self[b]; end
    end
  end
RUBY

failures = []
check = lambda do |what, condition|
  if condition
    puts "  ok  #{what}"
  else
    warn "  FAIL #{what}"
    failures << what
  end
end

Dir.mktmpdir do |dir|
  source = File.join(dir, 'game_variable_range.rb')
  File.write(source, SRC)
  ireps, root = compile_ireps(source, 'bc2cpp_game_variable_range', dir)
  order = dfs_order(ireps, root)
  registry = build_registry(ireps, root)[0]
  owners = Set.new(registry.values.flatten.map(&:owner))
  annotations = ElementAnnotations.extract(ireps, registry, owners)
  class_annotations = ClassAnnotations.extract(ireps, registry, owners)
  gen = CodeGen.new(ireps, registry, {}, {}, class_annotations, {}, {}, {}, annotations, {}, {}, Set.new)

  { 'add' => 'ADD', 'sub' => 'SUB', 'mul' => 'MUL', 'div' => 'DIV' }.each do |method_name, opcode|
    method = registry.fetch(method_name).find { |md| md.owner == 'Game::Variables' }
    irep = ireps.fetch(method.irep)
    idx = irep.instructions.index { |insn| insn.op == opcode }
    raise "#{method_name}: no #{opcode} instruction" unless idx

    code = gen.compile_insn(irep.instructions[idx], irep, method, idx)
    check.call("#{opcode} guards both values against the game variable range",
               code.include?('GUARDED_GAME_VARIABLE_RANGE') && code.include?('mrb_fixnum_p') &&
                 code.include?('-9999999') && code.include?('9999999'))
    check.call("#{opcode} keeps the ordinary operator fallback", code.include?('mrb_funcall(M,'))
  end

  div = registry.fetch('div').find { |md| md.owner == 'Game::Variables' }
  div_irep = ireps.fetch(div.irep)
  div_code = gen.compile_insn(div_irep.instructions.find { |insn| insn.op == 'DIV' }, div_irep, div,
                              div_irep.instructions.index { |insn| insn.op == 'DIV' })
  check.call('DIV guard excludes zero before the Fixnum helper', div_code.include?('mrb_fixnum(r') &&
             div_code.include?('!= 0'))

  mul = registry.fetch('mul').find { |md| md.owner == 'Game::Variables' }
  mul_irep = ireps.fetch(mul.irep)
  mul_idx = mul_irep.instructions.index { |insn| insn.op == 'MUL' }
  mul_code = gen.compile_insn(mul_irep.instructions[mul_idx], mul_irep, mul, mul_idx)
  check.call('MUL checks product overflow before boxing it as a Fixnum',
             mul_code.include?('MRB_FIXNUM_MAX') && mul_code.include?('MRB_FIXNUM_MIN /'))

  add_one = registry.fetch('add_one').find { |md| md.owner == 'Game::Variables' }
  add_one_irep = ireps.fetch(add_one.irep)
  addi_idx = add_one_irep.instructions.index { |insn| insn.op == 'ADDI' }
  raise 'add_one: no ADDI instruction' unless addi_idx
  addi_code = gen.compile_insn(add_one_irep.instructions[addi_idx], add_one_irep, add_one, addi_idx)
  check.call('ADDI guards the game variable input and its result interval',
             addi_code.include?('GUARDED_GAME_VARIABLE_RANGE') && addi_code.include?('mrb_fixnum_p'))

  chain = registry.fetch('add_chain').find { |md| md.owner == 'Game::Variables' }
  chain_irep = ireps.fetch(chain.irep)
  additions = chain_irep.instructions.each_index.select { |i| chain_irep.instructions[i].op == 'ADD' }
  raise 'add_chain: expected two ADD instructions' unless additions.size == 2
  second_add = chain_irep.instructions[additions.last]
  chained_code = gen.compile_insn(second_add, chain_irep, chain, additions.last)
  check.call('a guarded addition result can feed a later guarded Fixnum operation',
             chained_code.include?('GUARDED_GAME_VARIABLE_RANGE') &&
               chained_code.include?('-19999998') && chained_code.include?('19999998'))

  generic = registry.fetch('generic_add').find { |md| md.owner == 'Game::Variables' }
  generic_irep = ireps.fetch(generic.irep)
  generic_idx = generic_irep.instructions.index { |insn| insn.op == 'ADD' }
  generic_code = gen.compile_insn(generic_irep.instructions[generic_idx], generic_irep, generic, generic_idx)
  check.call('unbounded arguments do not receive the game range specialization',
             !generic_code.include?('GUARDED_GAME_VARIABLE_RANGE'))

  other = registry.fetch('add').find { |md| md.owner == 'Game::Other' }
  other_irep = ireps.fetch(other.irep)
  other_idx = other_irep.instructions.index { |insn| insn.op == 'ADD' }
  other_code = gen.compile_insn(other_irep.instructions[other_idx], other_irep, other, other_idx)
  check.call('other indexed classes do not inherit the game-variable range',
             !other_code.include?('GUARDED_GAME_VARIABLE_RANGE'))
end

if failures.empty?
  puts 'bc2cpp game variable range check: PASS'
else
  warn "bc2cpp game variable range check: #{failures.size} failure(s)"
  exit 1
end
