#!/usr/bin/env ruby
# frozen_string_literal: true

require_relative '../../tools/bc2cpp/irep'
require_relative '../../tools/bc2cpp/integer_constants'
require_relative '../../tools/bc2cpp/integer_constant_ranges'
require_relative '../../tools/bc2cpp/codegen_numeric_proof'
require_relative '../../tools/bc2cpp/codegen_block_fallback'
require_relative '../../tools/bc2cpp/codegen_resumable'
require_relative '../../tools/bc2cpp/type_facts'
require_relative 'check_support'

suite = FixtureCheck.new('typed_immediates_check')
make = ->(op, args) { Insn.new(op: op, args: args, addr: 0) }
[
  [:LOADI8, 'R1 0', 0],
  [:LOADINEG, 'R1 -17', -17],
  [:LOADI16, 'R1 -32768', -32768],
  [:LOADI32, 'R1 2147483647', 2_147_483_647],
  [:LOADI32, 'R1 -2147483648', -2_147_483_648],
  [:ADDI, 'R1 0', 0],
  [:SUBI, 'R1 255', 255]
].each do |op, args, expected|
  insn = make.call(op, args)
  value = BytecodeIR::OperandModel.imm_operand(insn)
  suite.check("#{op} #{expected} remains an Integer", value.is_a?(Integer) && value == expected)
  suite.check("#{op} #{expected} memoized accessor agrees", insn.imm_operand.equal?(value) && insn.imm_operand.equal?(value))
end
[
  [:LOADI_0, 'R1 (0)'], [:LOADI__1, 'R1 (-1)'], [:MOVE, 'R1 R2'], [:LOADNIL, 'R1 (nil)']
].each do |op, args|
  suite.check("#{op} has no separate immediate", BytecodeIR::OperandModel.imm_operand(make.call(op, args)).nil?)
end
suite.check('printed parenthesized register keeps its textual API', make.call(:LOADSELF, 'R1 (R0)').paren_value == 'R0')
suite.check('zero is not confused with an absent literal', IntegerConstants.loadi_value(make.call(:LOADI8, 'R1 0')) == 0)
suite.check('negative literals keep their value', IntegerConstantRanges.literal(make.call(:LOADINEG, 'R1 -17')) == -17)
suite.check('wide positive literal still refuses target-independent Fixnum proof', IntegerConstants.loadi_value(make.call(:LOADI32, 'R1 2147483647')).nil?)
suite.check('wide negative literal still refuses target-independent Fixnum proof', IntegerConstantRanges.literal(make.call(:LOADI32, 'R1 -2147483648')).nil?)
cg = CodeGen.allocate
[0, -17, 255, 1_073_741_823].each do |value|
  suite.check("Integer #{value} emits the same overflow tier as its spelling", cg.fixnum_exact_tier('+', '1', value) == cg.fixnum_exact_tier('+', '1', value.to_s))
end
suite.check('register-expression rhs passes the register, a literal its boxed value',
            cg.fixnum_exact_tier('+', '1', 'r2').include?('bc2cpp_fixnum_add(r1, r2, r1)') &&
              cg.fixnum_exact_tier('+', '1', 7).include?('bc2cpp_fixnum_add(r1, mrb_fixnum_value(7), r1)'))

optional_body = Irep.new(label: 'optional', file: 'primitive_fixture.rb', nregs: 3, nlocals: 2,
                         lv: ['value'], catch_handlers: [], reps: [], pool: [], instructions: [
                           Insn.new(op: :ENTER, args: '0:1:0:0:0:0:0:0 (0x20)', addr: 0),
                           Insn.new(op: :RETNIL, args: '', addr: 1)
                         ])
optional_def = MethodDef.new(name: 'optional', owner: 'PrimitiveProbe', irep: optional_body.label)
contracts = Struct.new(:ir_optional_types, :ir_keyword_types, :ir_block_signatures, :ir_return_types)
                  .new({ optional_body.label => { 1 => Set[:Integer] } }, {}, {}, {})
context = TypeFacts::Ctx.new(ireps: { optional_body.label => optional_body }, registry: { 'optional' => [optional_def] },
                             signature_contracts: contracts, annotations: {}, class_annotations: {}, element_annotations: {})
report_gen = Object.new
report_gen.define_singleton_method(:fixnum_return_names) { Set.new }
report_gen.define_singleton_method(:array_return_names) { Set.new }
report_gen.define_singleton_method(:bytecode_ir_optional_argument_classes) { |_definition, _register| Set[:String] }
optional_row = TypeFacts.method_row(context, report_gen, optional_def, ->(_path) { [] }, nil)['optional_params'].first
suite.check('optional signature lookup uses Integer register keys', optional_row['type'] == 'Integer' && optional_row['source'] == 'signature')

fiber_body = Irep.new(label: 'fiber', nregs: 3, nlocals: 1, catch_handlers: [], reps: [], pool: [], instructions: [
                       Insn.new(op: :GETCONST, args: 'R1 Fiber', addr: 0),
                       Insn.new(op: :SEND, args: 'R1 :yield n=0', addr: 1)
                     ])
cg.define_singleton_method(:resumable_yield_site) { |_insn| :intercepted_yield }
suite.check('resumable yield receiver uses an Integer register',
            cg.resumable_intercept(fiber_body.instructions.last, fiber_body, nil, 1, 0) == :intercepted_yield)
shifted_yield = Insn.new(op: :SEND, args: 'R4 :yield n=0', addr: 1)
suite.check('inlined resumable yields subtract the numeric register offset',
            cg.resumable_intercept(shifted_yield, fiber_body, nil, 1, 3) == :intercepted_yield)
suite.check('an unrelated receiver does not become a Fiber yield',
            cg.resumable_intercept(shifted_yield, fiber_body, nil, 1, 0).nil?)

if ENV['MRBC']
  suite.require_mrbc!
  suite.compile("class TypedImmediateProbe\n def plus(value); value + 17; end\n def minus(value); value - 17; end\n def negative; -32768; end\nend\n") do |ireps, _root, _dir|
    instructions = ireps.values.flat_map(&:instructions)
    numeric = instructions.select { |insn| insn.typed[1]&.kind == :int && insn.reg }
    suite.check('binary decoder fixture has arithmetic and load immediates', numeric.any? { |i| i.op == :ADDI } && numeric.any? { |i| i.op == :SUBI } && numeric.any? { |i| BytecodeIR::Ops::LOADI_OPS.include?(i.op) })
    suite.check('binary immediate values retain decoded Integer identity', numeric.all? { |i| BytecodeIR::OperandModel.imm_operand(i).equal?(i.typed[1].value) })
  end
end
suite.finish!
