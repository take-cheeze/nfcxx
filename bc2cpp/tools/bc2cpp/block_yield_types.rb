# frozen_string_literal: true

require 'set'
require_relative 'bytecode_ir'
require_relative 'block_self'

# BLOCK_YIELD_TYPES: the classes of the values a Ruby method yields to its block, which the candidate emitter writes as
# the block type `{ (T1..Tn) -> untyped }` (type_check_rbs.rb). The proof is the method's own yield sites, so it needs
# nothing from the caller: a block is only ever called by the method that yields to it, and every value it receives is
# an argument of one of these sites.
#
# A method is typed only when every condition holds; otherwise the result carries a reason and the block stays untyped:
#   * a plain yielder (BlockSelf): the block is only called, never kept, passed on or read from a closure, and no
#     `super` or argument forwarding passes it on, so each call of the block is one of the yield sites below;
#   * no `&blk` parameter, and no `yield` inside a nested block (its block register is a captured slot, which this
#     pass does not follow; such a method is left untyped rather than traced through the capture);
#   * no `call` on the block register (a splatted or keyword yield compiles to a SEND `call`, whose arguments are not
#     the plain positionals of a BLKCALL);
#   * every BLKCALL yields the same number of arguments n, and the classes of every yielded argument are known at its
#     site: an entry value of a required positional takes the parameter's inferred type, any other value the
#     numeric-flow classes of its site (see CodeGen#bytecode_ir_yield_block_types). A position whose classes differ
#     between sites is the union of them, and a position with an unknown class is untyped.
# The result is nil when the method yields nothing (there is no block to type).
module BlockYieldTypes
  CALL_OPS = %w[SEND SEND0 SENDB SSEND SSEND0 SSENDB].freeze

  module_function

  # +value_class+ is ->(irep, index, register) { classes or nil }: the classes of the value +register+ holds at +index+,
  # nil when that is not proven.
  # Returns nil (no yield), { arity:, params: [[class, ...], ...] } (one sorted class list per yielded position; an empty
  # list is an unknown class), or { reason: } when the method is not typed.
  def proven(irep, ireps, value_class:)
    return { reason: 'has no body' } unless irep

    fields = (irep.enter&.enter_fields || []).map(&:to_i) + [0] * 7
    req, opt, rest, post, key, kdict, block_flag = fields.first(7)
    return { reason: 'takes a block parameter' } if block_flag.positive?

    why = BlockSelf.plain_yielder_why(irep, ireps)
    return { reason: why } if why

    blk = (1 + req + opt + rest + post + (key.positive? || kdict.positive? ? 1 : 0)).to_s
    program = BytecodeIR.for(irep)
    yields = []
    program.each_source do |insn, idx|
      case insn.op
      when 'BLKCALL'
        argc = insn.typed.find { |operand| operand.kind == :int }&.value
        return { reason: 'yields an unknown number of arguments' } unless argc && insn.reg

        yields << [idx, insn.reg.to_i, argc]
      when *CALL_OPS
        next unless insn.sym.to_s == 'call' && insn.reg && holds_block?(program, idx, insn.reg.to_s, blk)

        return { reason: 'yields through Proc#call' }
      end
    end
    # A `yield` in a nested block is a BLKCALL of that child body, which the scan above does not reach.
    nested = nested_yield_why(irep, ireps)
    return { reason: nested } if nested
    return nil if yields.empty?

    arities = yields.map(&:last).uniq
    return { reason: 'yields different numbers of arguments' } unless arities.one?

    arity = arities.first
    params = Array.new(arity) { Set.new }
    unknown = Array.new(arity, false)
    yields.each do |idx, reg, _argc|
      arity.times do |k|
        classes = value_class.call(irep, idx, reg + 1 + k)
        if classes.nil? || classes.empty?
          unknown[k] = true
        else
          classes.each { |klass| params[k] << klass.to_s }
        end
      end
    end
    { arity: arity, params: params.each_with_index.map { |set, k| unknown[k] ? [] : set.to_a.sort } }
  end

  # Does the block register hold a Proc at +index+? Unknown reaching definitions count as holding one, so the refusal
  # is the conservative answer.
  def holds_block?(program, index, reg, blk)
    defs = program.reaching_definitions(index, reg, through_handlers: true, shared: true)
    return true if defs.nil?

    defs.any? do |df|
      if df.entry?
        df.reg.to_s == blk
      else
        %w[BLKPUSH GETUPVAR].include?(program.source_at(df.index).op)
      end
    end
  end

  # nil when no child body of +irep+ (at any depth) yields, else why.
  def nested_yield_why(irep, ireps, seen = Set.new)
    irep.reps.each do |label|
      next unless seen.add?(label)

      child = ireps[label] or return 'has a nested block with no body'
      return 'yields from a nested block' if BytecodeIR.for(child).instructions_with_op('BLKCALL').any?

      why = nested_yield_why(child, ireps, seen)
      return why if why
    end
    nil
  end
end
