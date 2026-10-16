# frozen_string_literal: true

require_relative 'bytecode_ir'

# Finite symbol sets for constant dispatch tables, for yield_reach.rb.
#
# A dynamic send `send(*TABLE[i])` may name any method, so yield_reach must assume the worst
# there. When every value stored in TABLE is literal, the names the send can reach form a known
# finite set, and yield_reach can record the send as calls to exactly those names.
#
# dispatch_universes returns { constant_name => Set<String> } for each constant whose premises hold,
# checked on the bytecode. Other constants are absent and keep the unknown-call treatment.
#
#   P1  the constant has one SETCONST, in a class-body irep (the class irep), and every SETIDX that
#       stores into it is in one method (the writer), possibly inside blocks of that method.
#   P2  the constant's GETCONST values never escape: each is used only as the base of GETIDX or
#       SETIDX, along every path. An alias could otherwise write the table unseen.
#   P3  every value a SETIDX stores is literal (literal_reg?), along every path that reaches it.
#   P4  every call of the writer, by name, is in the class irep, with one arity, and every argument
#       is literal. The writer's parameters are then literal, and the writer never writes them.
#   P5  the class irep and the writer create no symbol at run time (INTERN, to_sym, intern).
#
# Reads are reaching-definition checks over the bytecode control-flow graph (exception handlers
# included), so a value is literal only if every write that can reach the read is literal.
# The universe is every LOADSYM symbol of the class irep and the writer's irep, which covers every
# symbol P3 allows into the table.
module SymbolFlow
  # Loads of a symbol, integer, nil, boolean or self: the values a literal table can hold.
  LITERAL_LOAD = /\ALOAD(SYM|I\w*|L|NIL|T|F|SELF|TRUE|FALSE)\z/.freeze
  # Operations that read registers but write none of their first operand.
  READ_ONLY_OPS = %w[JMP JMPIF JMPNOT JMPNIL RETURN RETURN_BLK NOP STOP SETIDX SETIV SETCONST
                     SETUPVAR SETGV SETMCNST].freeze
  # Core methods that add their argument to their receiver.
  MUTATORS = %w[<< push].freeze
  SYMBOL_SENDS = %w[to_sym intern].freeze

  # ireps: the irep tree. parents: child label => parent label. params: method label => Set of
  # literal parameter registers. literal_consts: constants whose stored values are literal.
  # user_methods: names the program defines (so core MUTATORS may be shadowed).
  Ctx = Struct.new(:ireps, :parents, :params, :literal_consts, :user_methods, :preds, keyword_init: true)

  module_function

  # names: method irep label => method name. Returns { const => Set<String> }.
  def dispatch_universes(ireps, names)
    parents = parent_map(ireps)
    user_methods = names.values.to_set
    setconsts = Hash.new { |h, k| h[k] = [] }
    getconsts = Hash.new { |h, k| h[k] = [] }
    setidxs = []
    ireps.each do |label, irep|
      irep.instructions.each_with_index do |insn, idx|
        case insn.op
        when 'SETCONST' then setconsts[insn.const_name] << label if insn.const_name
        when 'GETCONST' then getconsts[insn.const_name] << [label, idx] if insn.const_name
        when 'SETIDX' then setidxs << [label, idx]
        end
      end
    end
    preds = ireps.transform_values { |irep| predecessors(irep) }

    result = {}
    setconsts.each do |const, class_labels|
      next unless class_labels.size == 1 # P1

      class_label = class_labels.first
      writes = setidxs.select { |label, idx| table_base_of?(ireps[label], idx, const, preds[label]) }
      writers = writes.map { |label, _| enclosing_method(label, parents, names) }.uniq
      next unless writers.size == 1 && writers.first && writers.first != class_label # P1

      writer = writers.first
      next unless getconsts[const].all? { |label, idx| only_table_base?(ireps[label], idx) } # P2

      lits = literal_constants(ireps, parents, preds, class_label, const, user_methods)
      arity = writer_arity(ireps, parents, preds, names[writer], class_label, lits, user_methods)
      next unless arity # P4
      next unless writer_params_unwritten?(ireps[writer], arity) # P4

      ctx = Ctx.new(ireps: ireps, parents: parents, preds: preds, user_methods: user_methods,
                    params: { writer => (1..arity).map(&:to_s).to_set }, literal_consts: lits)
      next unless writes.all? { |label, idx| literal_store?(ctx, label, idx) } # P3

      class_ireps = [class_label] + inner_labels(ireps, class_label, parents)
      writer_ireps = [writer] + inner_labels(ireps, writer, parents)
      next unless (class_ireps + writer_ireps).all? { |l| symbol_free?(ireps[l]) } # P5

      result[const] = symbols_of((class_ireps + writer_ireps).map { |l| ireps[l] })
    end
    result
  end

  def parent_map(ireps)
    parents = {}
    ireps.each { |label, irep| (irep.reps || []).each { |child| parents[child] = label if child } }
    parents
  end

  # Labels of every irep nested under label (blocks, recursively).
  def inner_labels(ireps, label, parents)
    ireps.keys.select { |l| l != label && ancestors(l, parents).include?(label) }
  end

  def ancestors(label, parents)
    out = []
    cur = parents[label]
    while cur
      out << cur
      cur = parents[cur]
    end
    out
  end

  # The method irep a label belongs to: itself, or the nearest ancestor that is a named method.
  def enclosing_method(label, parents, names)
    return label if names.key?(label)

    ancestors(label, parents).find { |a| names.key?(a) }
  end

  # Predecessor lists of an irep's instructions, exception handlers included.
  def predecessors(irep)
    bir = BytecodeIR.for(irep)
    preds = Array.new(irep.instructions.size) { [] }
    irep.instructions.size.times do |i|
      bir.successors_of(i, include_handlers: true).each { |s| preds[s] << i if s && s < preds.size }
    end
    preds
  end

  # Whether instruction insn writes register reg.
  def writes_reg?(insn, reg)
    insn.regs.first == reg && !READ_ONLY_OPS.include?(insn.op)
  end

  # The writes to reg that can reach the start of instruction idx, and whether the entry of the irep
  # can reach idx with reg unwritten (a parameter, or an uninitialized value).
  def reaching_writes(irep, preds, idx, reg)
    found = []
    entry = false
    seen = Set.new
    stack = preds[idx].dup
    stack << :entry if idx.zero?
    until stack.empty?
      n = stack.pop
      if n == :entry
        entry = true
        next
      end
      next unless seen.add?(n)

      if writes_reg?(irep.instructions[n], reg)
        found << n
      else
        stack.concat(preds[n])
        entry = true if n.zero? && preds[n].empty? # the entry instruction itself
      end
    end
    [found, entry]
  end

  # The SETIDX at idx stores into a table whose base register holds only GETCONST const.
  def table_base_of?(irep, idx, const, preds)
    reg = irep.instructions[idx].regs.first
    found, entry = reaching_writes(irep, preds, idx, reg)
    !entry && found.size == 1 && irep.instructions[found.first].op == 'GETCONST' &&
      irep.instructions[found.first].const_name == const
  end

  # The GETCONST at idx is used only as the base of GETIDX or SETIDX, on every path from it. Any other
  # read of the register is an escape; a write to it ends the path, unless the write reads it too.
  def only_table_base?(irep, idx)
    reg = irep.instructions[idx].regs.first
    bir = BytecodeIR.for(irep)
    stack = bir.successors_of(idx, include_handlers: true).dup
    seen = Set.new
    until stack.empty?
      n = stack.pop
      next if n.nil? || !seen.add?(n)

      insn = irep.instructions[n]
      if %w[GETIDX SETIDX].include?(insn.op) && insn.regs.first == reg
        return false if insn.regs.drop(1).include?(reg) # the table as an index or value
        next if insn.op == 'GETIDX' # the element replaces the table in reg: this path ends

        stack.concat(bir.successors_of(n, include_handlers: true))
        next
      end
      if insn.regs.first == reg && !READ_ONLY_OPS.include?(insn.op)
        return false if insn.regs.drop(1).include?(reg) # overwritten from itself: treat as an escape

        next # overwritten: this path ends
      end
      return false if insn.regs.include?(reg) # read by another op

      stack.concat(bir.successors_of(n, include_handlers: true))
    end
    true
  end

  # The GETCONST at idx is used only as the base of GETIDX or SETIDX, on every path. A later read of
  # the register as any other operand, or a write that is not the table's own, ends a path.
  def only_table_base?(irep, idx)
    reg = irep.instructions[idx].regs.first
    bir = BytecodeIR.for(irep)
    stack = bir.successors_of(idx, include_handlers: true).dup
    seen = Set.new
    until stack.empty?
      n = stack.pop
      next if n.nil? || !seen.add?(n)

      insn = irep.instructions[n]
      if %w[GETIDX SETIDX].include?(insn.op) && insn.regs.first == reg
        # The base is read; a GETIDX also overwrites reg, so its path ends there.
        next unless insn.regs[1..].to_a.include?(reg) == false
        next if insn.op == 'GETIDX'
      end
      return false if insn.regs.drop(1).include?(reg) || (insn.regs.first == reg && !%w[GETIDX SETIDX].include?(insn.op) && !READ_ONLY_OPS.include?(insn.op) && n != idx)
      next if insn.regs.first == reg && !READ_ONLY_OPS.include?(insn.op) && !%w[GETIDX SETIDX].include?(insn.op)

      stack.concat(bir.successors_of(n, include_handlers: true))
    end
    true
  end

  # The constant a splat argument register holds at idx, when it is built only as LOADNIL and
  # ARYCAT of GETIDX of GETCONST (`*TABLE[i]`). nil otherwise.
  def splat_table(irep, preds, idx, reg)
    writers, entry = reaching_writes(irep, preds, idx, reg)
    return nil if entry || writers.empty?

    tables = writers.map do |n|
      insn = irep.instructions[n]
      next :nil if insn.op == 'LOADNIL'
      next nil unless insn.op == 'ARYCAT' && insn.regs.first == reg

      src, src_entry = reaching_writes(irep, preds, n, insn.regs[1])
      next nil if src_entry || src.size != 1

      get = irep.instructions[src.first]
      next nil unless get.op == 'GETIDX'

      base, base_entry = reaching_writes(irep, preds, src.first, get.regs.first)
      next nil if base_entry || base.size != 1

      getc = irep.instructions[base.first]
      getc.op == 'GETCONST' ? getc.const_name : nil
    end
    return nil if tables.any?(&:nil?)

    consts = tables.reject { |t| t == :nil }.uniq
    consts.size == 1 ? consts.first : nil
  end

  # The GETCONST at idx is used only as the base of GETIDX or SETIDX, on every path.
  def only_table_base?(irep, idx)
    reg = irep.instructions[idx].regs.first
    bir = nil
    stack = [idx]
    seen = Set.new
    until stack.empty?
      n = stack.pop
      succs = (bir ||= BytecodeIR.for(irep)).successors_of(n, include_handlers: true)
      succs.each do |s|
        next if s.nil? || !seen.add?(s)

        insn = irep.instructions[s]
        if insn.regs.include?(reg) && !READ_ONLY_OPS.include?(insn.op) && insn.regs.first != reg
          return false # read by a non-table op (for instance as an argument)
        end
        if %w[GETIDX SETIDX].include?(insn.op) && insn.regs.first == reg
          next if insn.op == 'SETIDX' # base read, value unchanged
          next # GETIDX reads the base and overwrites reg: this path ends
        elsif insn.regs.include?(reg) && (insn.regs.drop(1).include?(reg) || READ_ONLY_OPS.include?(insn.op))
          return false
        end
        stack << s unless writes_reg?(insn, reg)
      end
    end
    true
  end

  # Constants other than const whose stored value is literal, from SETCONST in the class irep.
  def literal_constants(ireps, parents, preds, class_label, const, user_methods)
    lits = Set.new
    ireps[class_label].instructions.each_with_index do |insn, idx|
      next unless insn.op == 'SETCONST' && insn.const_name && insn.const_name != const

      ctx = Ctx.new(ireps: ireps, parents: parents, preds: preds, params: {}, literal_consts: Set.new,
                    user_methods: user_methods)
      lits << insn.const_name if literal_reg?(ctx, class_label, idx, insn.regs.last, Set.new)
    end
    lits
  end

  def literal_store?(ctx, label, idx)
    literal_reg?(ctx, label, idx, ctx.ireps[label].instructions[idx].regs.last, Set.new)
  end

  # Whether register reg, as read at idx in irep label, holds only literal values along every path.
  # visiting holds (label, idx, reg) reads being checked; meeting one again is a cycle through writes,
  # which adds no value of its own, so it counts as literal (greatest fixpoint).
  def literal_reg?(ctx, label, idx, reg, visiting)
    return false if reg.nil?

    key = [label, idx, reg]
    return true if visiting.include?(key)

    irep = ctx.ireps[label]
    writers, entry = reaching_writes(irep, ctx.preds[label], idx, reg)
    if entry
      method = enclosing_method(label, ctx.parents, ctx.params.transform_values { true }) || label
      return false unless ctx.params.fetch(method, Set.new).include?(reg)
    end

    visiting = visiting | [key]
    writers.all? { |n| literal_writer?(ctx, label, n, visiting) } && mutations_literal?(ctx, label, idx, visiting)
  end

  # Whether the instruction at index n of irep label, which writes a register, produces only literal values.
  def literal_writer?(ctx, label, n, visiting)
    insn = ctx.ireps[label].instructions[n]
    rec = ->(at, r) { literal_reg?(ctx, label, at, r, visiting) }
    case insn.op
    when LITERAL_LOAD then true
    when 'ARRAY' then (0...int_operand(insn).to_i).all? { |k| rec.call(n, (element_start(insn) + k).to_s) }
    when 'HASH' then (0...(2 * int_operand(insn).to_i)).all? { |k| rec.call(n, (element_start(insn) + k).to_s) }
    when 'MOVE', 'AREF' then rec.call(n, insn.regs[1])
    when 'ARYCAT', 'ARYPUSH', 'HASHADD' then rec.call(n, insn.regs.first) && rec.call(n, insn.regs[1])
    when 'GETIDX' then rec.call(n, insn.regs.first) # an element of a literal container, whatever the index
    when 'GETCONST' then ctx.literal_consts.include?(insn.const_name)
    when 'GETUPVAR' then upvalue_literal?(ctx, label, insn, n, visiting)
    else false
    end
  end

  # A GETUPVAR reads register `index` of the irep `level + 1` levels up, as of the point where the
  # enclosing irep's block is created. Flow-insensitive over that irep: every write there is literal.
  def upvalue_literal?(ctx, label, insn, idx, visiting)
    index, level = insn.upvar_ref
    return false unless index

    target = label
    (level + 1).times { target = ctx.parents[target] }
    return false unless target

    target_irep = ctx.ireps[target]
    writes = (0...target_irep.instructions.size).select { |n| writes_reg?(target_irep.instructions[n], index.to_s) }
    return ctx.params.fetch(target, Set.new).include?(index.to_s) if writes.empty?

    writes.all? { |n| literal_writer?(ctx, target, n, visiting) }
  end

  # Mutations of arrays by core MUTATORS at points that reach idx: their arguments must be literal.
  def mutations_literal?(ctx, label, idx, visiting)
    irep = ctx.ireps[label]
    irep.instructions.each_index.all? do |n|
      insn = irep.instructions[n]
      next true unless insn.op =~ /SEND/ && MUTATORS.include?(insn.sym)
      return false if ctx.user_methods.include?(insn.sym)

      literal_reg?(ctx, label, n, (insn.regs.first.to_i + 1).to_s, visiting)
    end
  end

  # P4: every call of the method name is in the class irep, with one arity and literal arguments.
  def writer_arity(ireps, parents, preds, name, class_label, lits, user_methods)
    return nil unless name

    calls = []
    ireps.each do |label, irep|
      irep.instructions.each_with_index do |insn, idx|
        calls << [label, idx, insn] if insn.op =~ /SEND/ && insn.sym == name
      end
    end
    return nil if calls.empty? || calls.any? { |label, _, _| label != class_label }

    arities = calls.map { |_, _, insn| insn.n_spec.to_i }.uniq
    return nil unless arities.size == 1

    arity = arities.first
    ctx = Ctx.new(ireps: ireps, parents: parents, preds: preds, params: {}, literal_consts: lits,
                  user_methods: user_methods)
    ok = calls.all? do |label, idx, insn|
      first = insn.regs.first.to_i
      (1..arity).all? { |k| literal_reg?(ctx, label, idx, (first + k).to_s, Set.new) }
    end
    ok ? arity : nil
  end

  # The writer's parameters are never written in the writer, so each holds only what its call sites pass.
  def writer_params_unwritten?(irep, arity)
    written = irep.instructions.map { |insn| insn.regs.first }.compact
    (1..arity).none? { |k| written.include?(k.to_s) }
  end

  # ARRAY a b n and HASH a b n read their elements from register b (a when only one register is named).
  def element_start(insn)
    (insn.regs.size >= 2 ? insn.regs[1] : insn.regs.first).to_i
  end

  def int_operand(insn)
    insn.typed.find { |operand| operand.kind == :int }&.value
  end

  # P5: no symbol is created at run time.
  def symbol_free?(irep)
    irep.instructions.none? do |insn|
      insn.op == 'INTERN' || (insn.op =~ /SEND/ && SYMBOL_SENDS.include?(insn.sym))
    end
  end

  def symbols_of(ireps)
    syms = Set.new
    ireps.each do |irep|
      irep.instructions.each { |insn| syms << insn.sym if insn.op == 'LOADSYM' && insn.sym }
    end
    syms
  end
end
