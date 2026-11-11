# frozen_string_literal: true

# Class-scope annotations (bc2cpp/tools/mrbc_rb/annotations.rb) attached to a decoded irep tree: the exact lexical scope facts
# the Ruby emitter knew while compiling. When an Irep carries them (Irep#class_scope), BytecodeIR.class_body_path /
# class_bodies and the scope consumers read them instead of re-deriving by dataflow; trees from mrbc (or a cache) have none and
# keep the dataflow. BC2CPP_CLASS_SCOPE=0 ignores the annotations.
#
# Annotations are never cached: IrepCache stores only the decoded tree (keyed by the image bytes), and the emitter, which runs
# before every load, hands a fresh table that is attached after the cache fetch, so a cached tree is never mixed with a
# stale table and the cache key needs no annotation component.
module ClassScope
  OPENERS = %i[CLASS MODULE SCLASS].freeze

  module_function

  def enabled? = ENV['BC2CPP_CLASS_SCOPE'] != '0'

  # Attaches +annotations+ (MrbcRb::Annotations structure, nil for none) to +ireps+ (label => Irep, root +root_label+). Returns
  # true when attached; a table that does not match the decoded code (size, an op at a recorded pc) is dropped whole.
  def attach(ireps, root_label, annotations)
    return false unless annotations && enabled?

    order = dfs_order(ireps, root_label)
    records = annotations[:ireps]
    return reject('irep count', order.size, records.size) unless records.size == order.size

    normalized = []
    order.each_with_index do |label, i|
      ops, error = normalize(ireps.fetch(label), records[i])
      return reject(error, label, i) if error

      normalized << ops
    end
    order.each_with_index { |label, i| ireps.fetch(label).class_scope = records[i].merge(labels: order, ops: normalized[i]) }
    true
  end

  def reject(why, *detail)
    warn "[bc2cpp] class-scope annotations dropped (#{why} #{detail.join(' ')})" if ENV['BC2CPP_CLASS_SCOPE_VERBOSE']
    false
  end

  # [ops keyed by the decoded instruction's address, error]: a recorded pc names the instruction (an EXT prefix not folded into
  # its instruction makes the real one start a byte later); an op that is not the decoded one is an error String.
  def normalize(irep, record)
    return [{}, nil] if record[:ops].empty?

    by_addr = {}
    irep.instructions.each { |insn| by_addr[insn.addr] = insn }
    ops = {}
    record[:ops].each do |pc, op|
      insn = by_addr[pc]
      insn = by_addr[pc + 1] if insn && %i[EXT1 EXT2 EXT3].include?(insn.op)
      return [nil, "pc #{pc} #{op[:op]} vs #{insn&.op.inspect}"] unless insn && insn.op == op[:op]

      ops[insn.addr] = op
    end
    [ops, nil]
  end

  # The op record of +insn+ (an Insn of +irep+); nil when the irep has no annotation or none for it.
  def op_at(irep, insn)
    scope = irep.class_scope
    scope && scope[:ops][insn.addr]
  end

  # label of the body irep of annotation record +op+ of +irep+ (nil: none).
  def body_label(irep, op)
    index = op[:body_irep]
    index && irep.class_scope[:labels][index]
  end

  # The lexical scope string of the LexicalConsts model for an irep: the qualified name of the innermost class/module when every
  # entry of its cref is a plain `class X` / `module X` (the chain of a lexical lookup is then exactly its `::` prefixes), "" at
  # top level, :unknown when any entry is a compact path, a `::`-rooted or dynamic one or a singleton class.
  def lexical_scope(irep)
    cref = irep.class_scope[:cref]
    return '' if cref.empty?

    cref.all? { |e| e[:outer] == :lexical && e[:path] } ? cref.last[:path] : :unknown
  end
end
