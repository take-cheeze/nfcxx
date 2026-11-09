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
  pending = ->(bodies) { bodies.values.flat_map(&:instructions).all? { |insn| insn.instance_variable_get(:@disassembly_decoder) } }
  suite.check('binary decoding leaves diagnostic text deferred', pending.call(baseline) && pending.call(guarded))
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
  suite.check('registers are Integers internally (nil only when the op has no leading register)',
              baseline.values.all? do |b|
                b.instructions.all? do |i|
                  (i.reg.nil? || i.reg.is_a?(Integer)) && i.regs.all?(Integer)
                end
              end)
  baseline.each do |label, body|
    suite.check("irep #{label}: cold IR queries agree with disassembly access forbidden",
                snapshot(body) == snapshot(guarded.fetch(label)))
  end
  suite.check('typed queries do not materialize diagnostic text', pending.call(baseline) && pending.call(guarded))
  image = RiteImage.new(File.binread(File.join(directory, 'ir_binary_operands.mrb')))
  cache = File.join(directory, 'decoded-cache')
  load_ireps(image, cache: cache)
  restored, = load_ireps(image, cache: cache)
  suite.check('decoded-tree cache preserves deferred text recipes', pending.call(restored))
  text_snapshot = ->(bodies) { bodies.transform_values { |body| body.instructions.map { |insn| [insn.args, insn.raw] } } }
  suite.check('cache-restored recipes reproduce every diagnostic string', text_snapshot.call(restored) == text_snapshot.call(baseline))
  first = baseline.values.first.instructions.first
  suite.check('materialized args and raw strings are reused', first.args.equal?(first.args) && first.raw.equal?(first.raw))
end

pool = [RiteBinary::PoolEntry.new(:str, "line\nlater\0tail".b),
        RiteBinary::PoolEntry.new(:str, "\xff".b), RiteBinary::PoolEntry.new(:int32, 4)]
rite = RiteBinary::RiteIrep.new(nlocals: 3, nregs: 4, iseq: "\0" * 30, pool: pool, syms: ['ready'], lv: ['a', 'b'],
                               debug_files: [RiteBinary::DebugFile.new(0, 'text.rb', 2, [0, 1].pack('CC'))])
decoder = InsnDecoder::Decoder.new(rite)
build = ->(op, values) { decoder.send(:build, op, values, 3, 0) }
schema_rite = rite.dup
schema_rite.pool = Array.new(3) { RiteBinary::PoolEntry.new(:str, 'example'.b) }
schema_rite.syms = %w[ready work]
schema_decoder = InsnDecoder::Decoder.new(schema_rite)
suite.check('every opcode renders operands consistent with its typed schema',
            InsnDecoder::FORMATS.all? do |op, format|
              values = Array.new(format.delete('Z').length, 1)
              insn = schema_decoder.send(:build, op, values, 3, 0)
              parsed = OperandSchema.parse(insn.op, insn.args)
              parsed && parsed.map(&:to_a) == insn.typed.map(&:to_a)
            end)
array = build.call(:ARRAY2, [1, 2, 3])
suite.check('ARRAY2 keeps its normalized opcode and exact diagnostic spelling',
            array.op == :ARRAY && array.raw == "    1 000 ARRAY\t\tR1\tR2\t3\t; R1:a R2:b")
frozen_string = build.call(:FSTRING, [1, 0])
suite.check('FSTRING diagnostics keep their opcode and truncate newline pool comments',
            frozen_string.op == :STRING && frozen_string.frozen_literal &&
            frozen_string.raw == "    1 000 FSTRING\tR1\tL[0]\t; line")
binary_string = build.call(:STRING, [1, 1])
suite.check('invalid UTF-8 pool comments are scrubbed on demand', binary_string.raw.valid_encoding? && binary_string.raw.include?("\ufffd"))
error = build.call(:ERR, [0])
suite.check('ERR eagerly decodes its text-typed operand and keeps lazy disassembly',
            error.typed.map(&:to_a) == [[:rest, 'line']] && error.instance_variable_get(:@disassembly_decoder) && error.args == 'line')
error_slot = build.call(:ERR, [2])
suite.check('non-string ERR slots keep single-tab padding', error_slot.raw == "    1 000 ERR\tL[2]")
copy = Marshal.load(Marshal.dump(build.call(:LOADI16, [1, 0xffff])))
copy.freeze
suite.check('unrendered instructions survive Marshal and freezing', copy.args == "R1\t-1\t; R1:a" && copy.frozen?)
written = build.call(:LOADNIL, [1])
written.args = 'custom args'
suite.check('assigning one text field preserves the other original field', written.args == 'custom args' && written.raw == "    1 000 LOADNIL\tR1\t(nil)\t; R1:a")
bad_pool = begin
  build.call(:STRING, [1, 2])
  false
rescue RuntimeError => e
  e.message == 'bc2cpp: pool 2 is not a string'
end
suite.check('invalid string pool slots still fail before text is requested', bad_pool)
suite.finish!
