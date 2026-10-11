#!/usr/bin/env ruby
# encoding: UTF-8
# Check that OP_ADD/OP_SUB/OP_MUL preserve the fixnum fastpath, mirror mruby's
# Float/Integer operand cases, and keep dynamic operator dispatch as fallback.

require 'tmpdir'
require_relative '../../tools/bc2cpp/bc2cpp'

SRC = <<~'RUBY'
  module Game
    class MathOps
      def add(left, right); left + right; end
      def sub(left, right); left - right; end
      def mul(left, right); left * right; end
    end
  end
RUBY

failures = []
check = lambda do |what, condition|
  if condition
    puts "  ok  #{what}"
  else
    puts "  FAIL #{what}"
    failures << what
  end
end

Dir.mktmpdir do |dir|
  source = File.join(dir, 'float_math.rb')
  File.write(source, SRC)
  ireps, root_label = compile_ireps(source, 'bc2cpp_float_math', dir)
  order = dfs_order(ireps, root_label)
  registry = build_registry(ireps, root_label)[0]
  # Core Integer#+/-/* are native definitions with no Ruby override: the state in
  # which FIXNUM_ARITHMETIC is admitted (builtin_class_send_safe?).
  %w[+ - *].each do |op|
    registry[op] << MethodDef.new(name: op, owner: '<native>', irep: nil, visibility: :public)
  end
  owners = Set.new(registry.values.flatten.map(&:owner))
  annotations = ElementAnnotations.extract(ireps, registry, owners)
  class_annotations = ClassAnnotations.extract(ireps, registry, owners)
  gen = CodeGen.new(ireps, registry, {}, {}, class_annotations, {}, {}, {}, annotations, {}, {}, Set.new)

  { 'add' => '+', 'sub' => '-', 'mul' => '*' }.each do |method_name, operator|
    method = registry.fetch(method_name).find { |md| md.owner == 'Game::MathOps' }
    irep = ireps.fetch(method.irep)
    opcode = { '+' => 'ADD', '-' => 'SUB', '*' => 'MUL' }.fetch(operator)
    idx = irep.instructions.index { |insn| insn.op == opcode }
    raise "#{method_name}: no #{opcode} instruction found" unless idx

    insn = irep.instructions[idx]
    dest_reg = insn.args[/^R(\d+)/, 1]
    source_reg = insn.args[/\(R(\d+)\)/, 1]
    code = gen.compile_insn(insn, irep, method, idx)
    arithmetic = operator
    overflow = { '+' => 'mrb_int_add_overflow', '-' => 'mrb_int_sub_overflow', '*' => 'mrb_int_mul_overflow' }.fetch(operator)
    check.call("#{opcode} retains the fixnum pair guard, computed overflow-exact (ADR 0279)",
               code.include?("mrb_fixnum_p(r#{dest_reg}) && mrb_fixnum_p(r#{source_reg})") &&
                 code.include?("#{overflow}(mrb_fixnum(r#{dest_reg}), mrb_fixnum(r#{source_reg}), &bc2cpp_z)") &&
                 code.include?('!FIXABLE(bc2cpp_z)') &&
                 !code.include?("mrb_fixnum_value(mrb_fixnum(r#{dest_reg}) #{arithmetic} mrb_fixnum(r#{source_reg}))"))
    check.call("#{opcode} handles Float/Integer with Float/Integer unboxing",
               code.include?("mrb_float_p(r#{dest_reg}) && mrb_integer_p(r#{source_reg})") &&
                 code.include?("mrb_float(r#{dest_reg}) #{arithmetic} mrb_integer(r#{source_reg})"))
    check.call("#{opcode} handles Integer/Float with Integer/Float unboxing",
               code.include?("mrb_integer_p(r#{dest_reg}) && mrb_float_p(r#{source_reg})") &&
                 code.include?("mrb_integer(r#{dest_reg}) #{arithmetic} mrb_float(r#{source_reg})"))
    check.call("#{opcode} handles Float/Float with Float/Float unboxing",
               code.include?("mrb_float_p(r#{dest_reg}) && mrb_float_p(r#{source_reg})") &&
                 code.include?("mrb_float(r#{dest_reg}) #{arithmetic} mrb_float(r#{source_reg})"))
    helper = { '+' => 'mrb_num_add', '-' => 'mrb_num_sub', '*' => 'mrb_num_mul' }.fetch(operator)
    slow = "bc2cpp_slow_#{{ '+' => 'add', '-' => 'sub', '*' => 'mul' }.fetch(operator)}_f(M, r#{dest_reg}, r#{source_reg})"
    check.call("#{opcode} fallback is the NUMERIC_SLOW_PATH helper (bigint and Float receivers, then the by-name call), after the inline tiers",
               code.include?(slow) && code.index(slow) > code.rindex('mrb_float_value(M,') &&
                 !code.include?('mrb_funcall(M,') && !code.include?("#{helper}(M, r#{dest_reg}, r#{source_reg});\n  }") &&
                 !code.include?("mrb_fixnum_p(r#{dest_reg}) && mrb_fixnum_p(r#{source_reg})) {\n    r#{dest_reg} = #{helper}"))
    check.call("#{opcode} boxes Float results inline and leaves the rest to the helper",
               code.include?('mrb_float_value(M,') && !code.include?('mrb_funcall(M,'))
  end
end

if failures.empty?
  puts 'bc2cpp Float arithmetic fastpath check: PASS'
else
  warn "bc2cpp Float arithmetic fastpath check: #{failures.size} failure(s)"
  exit 1
end
