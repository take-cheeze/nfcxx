#!/usr/bin/env ruby
# encoding: UTF-8
# Exercise integer/float OP_DIV lowering and Float-literal `/` devirtualization.

require 'tmpdir'
require_relative '../../tools/bc2cpp/bc2cpp'

SRC = <<~'RUBY'
  module Game
    class DivisionOps
      def divide(left, right); left / right; end
      def float_literal_divide(right); 1.5 / right; end
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
  source = File.join(dir, 'division.rb')
  File.write(source, SRC)
  ireps, root_label = compile_ireps(source, 'bc2cpp_division', dir)
  order = dfs_order(ireps, root_label)
  registry = build_registry(ireps, root_label)[0]
  registry['/'] ||= []
  registry['/'] << MethodDef.new(name: '/', owner: '<native>', irep: nil, visibility: :public)
  owners = Set.new(registry.values.flatten.map(&:owner))
  annotations = ElementAnnotations.extract(ireps, registry, owners)
  class_annotations = ClassAnnotations.extract(ireps, registry, owners)
  gen = CodeGen.new(ireps, registry, {}, {}, class_annotations, {}, {}, {}, annotations, {}, {}, Set.new)

  div_method = registry.fetch('divide').find { |md| md.owner == 'Game::DivisionOps' }
  div_irep = ireps.fetch(div_method.irep)
  div_insn = div_irep.instructions.find { |insn| insn.op == 'DIV' }
  raise 'divide: no DIV instruction' unless div_insn

  code = gen.compile_insn(div_insn, div_irep, div_method, div_irep.instructions.index(div_insn))
  check.call('Integer/Integer uses mruby floor division (including its zero and overflow errors)',
             code.include?('mrb_div_int_value(M, mrb_integer('))
  check.call('all mixed Integer/Float operand orders are lowered',
             code.include?('MRB_TT_INTEGER && mrb_type(') && code.scan('mrb_div_float(').size >= 3)
  check.call('Float results are boxed and unsupported values leave `/` to the NUMERIC_SLOW_PATH helper (which dispatches them)',
             code.include?('mrb_float_value(M, mrb_div_float(') && code.include?('bc2cpp_slow_div(M, '))
  check.call('unknown receivers use an exact Float guard before the Float division body',
             code.include?('mrb_type(') && code.include?('MRB_TT_FLOAT') &&
               code.include?('mrb_div_float(') && code.include?('bc2cpp_slow_div(M, '))

  float_method = registry.fetch('float_literal_divide').find { |md| md.owner == 'Game::DivisionOps' }
  float_irep = ireps.fetch(float_method.irep)
  float_div = float_irep.instructions.find { |insn| insn.op == 'DIV' }
  raise 'float_literal_divide: no DIV instruction' unless float_div

  send_code = gen.compile_insn(float_div, float_irep, float_method, float_irep.instructions.index(float_div))
  check.call('Float literal receiver emits the guarded Float division path',
             send_code.include?('FLOAT_DIV_RECEIVER') && send_code.include?('MRB_TT_FLOAT') &&
               send_code.include?('mrb_div_float('))
  check.call('Complex operands skip the Float body and take the helper, which dispatches them',
             send_code.include?('MRB_USE_COMPLEX') && send_code.include?('bc2cpp_slow_div(M, '))
end

if failures.empty?
  puts 'bc2cpp division fastpath check: PASS'
else
  warn "bc2cpp division fastpath check: #{failures.size} failure(s)"
  exit 1
end
