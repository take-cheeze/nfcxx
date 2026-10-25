#!/usr/bin/env ruby
# frozen_string_literal: true

require_relative '../../tools/bc2cpp/irep'
require_relative '../../tools/bc2cpp/bytecode_ir_returns'
require_relative 'check_support'

# Install the guard before any query can populate operand or analysis caches.
module DisassemblyForbidden
  def args = raise('IR query read disassembly args')
  def raw = raise('IR query read raw disassembly')
end

def snapshot(body)
  program = BytecodeIR.for(body)
  types = BytecodeIR::Types.new(body)
  {
    decoded: program.decoded.map(&:to_a),
    successors: program.successor_lists,
    exits: program.exits.map(&:to_a),
    returns: program.exits.map { |e| program.return_sources(e.index, e.reg) },
    values: body.instructions.each_index.map do |index|
      (0...body.nregs).map do |reg|
        [program.reaching_definitions(index, reg)&.map(&:to_a),
         types.exact_at(index, reg)&.to_a]
      end
    end
  }
end

suite = FixtureCheck.new('ir_binary_operands_check')
synthetic = Insn.new(op: 'SEND', args: 'R1 :work n=0')
suite.check('synthetic opcode names normalize to Symbols', synthetic.op == :SEND)
suite.check('method-name operands remain Strings', synthetic.sym == 'work')
synthetic.op = 'SEND0'
suite.check('opcode assignment normalizes without calling a missing Struct setter', synthetic.op == :SEND0)
constant = Insn.new(op: 'GETMCNST', args: 'R1 (R1)::Target')
suite.check('constant-name operands remain Strings', constant.mcnst_name == 'Target')
suite.require_mrbc!
source = <<~RUBY_SOURCE
  def ir_binary_join(flag)
    value = flag ? 3 : 4
    value
  end

  def ir_binary_loop(flag)
    values = []
    while flag
      values << :item
      flag = false
    end
    values
  end

  def ir_binary_rescue
    MissingIrBinaryConstant
  rescue NameError
    nil
  end

  def ir_binary_capture
    value = 7
    [1].map { |item| value + item }
  end
RUBY_SOURCE

suite.compile(source) do |baseline, _, directory|
  # Decode the same bytes again, bypassing disk caches and keeping query caches separate.
  guarded, = load_ireps(RiteImage.new(File.binread(File.join(directory, 'ir_binary_operands.mrb'))), cache: nil)
  suite.check('binary opcode names normalize to Symbols', baseline.values.all? { |body| body.instructions.all? { |i| i.op.is_a?(Symbol) } })
  suite.check('binary method names agree with synthetic name operands', baseline.values.flat_map(&:instructions).select { |i| BytecodeIR::Ops::SEND.include?(i.op) }.all? { |i| i.sym.is_a?(String) })
  guarded.each_value do |body|
    body.instructions.each { |instruction| instruction.extend(DisassemblyForbidden) }
  end
  suite.check('binary fixture includes branches, a back edge, handlers and a closure',
              baseline.values.any? { |b| b.instructions.any? { |i| i.op == :JMPNOT || i.op == :JMPIF } } &&
              baseline.values.any? { |b| b.instructions.any? { |i| i.op == :JMP && i.branch_target < i.addr } } &&
              baseline.values.any? { |b| !b.catch_handlers.empty? } &&
              baseline.values.any? { |b| b.instructions.any? { |i| i.op == :BLOCK } })
  facts = baseline.values.flat_map { |body| snapshot(body).fetch(:values).flatten(1) }
  suite.check('fixture proves Integer and Array values and also refuses unknown values',
              %i[Integer Array].all? { |klass| facts.any? { |_, exact| exact&.first == klass } } &&
              facts.any? { |_, exact| exact.nil? })
  suite.check('fixture exercises reaching definitions with multiple incoming writers',
              facts.any? { |definitions, _| definitions && definitions.size > 1 })
  baseline.each do |label, body|
    suite.check("irep #{label}: cold IR queries agree with disassembly access forbidden",
                snapshot(body) == snapshot(guarded.fetch(label)))
  end
end
suite.finish!
