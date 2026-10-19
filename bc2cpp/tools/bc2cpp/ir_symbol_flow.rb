# frozen_string_literal: true

require 'set'
require_relative 'bytecode_ir'

# SYMBOL_FLOW (ADR 0450, ADR 0499): finite symbol sets for constant dispatch tables, for yield_reach.rb.
#
# A dynamic send `send(*TABLE[i])` may name any method, so yield_reach must assume the worst there. When every
# value stored in TABLE is literal, the names the send can reach form a known finite set, and yield_reach records
# the send as calls to exactly those names.
#
# Values propagate along BytecodeIR's reaching definitions (handler edges included, MOVE chains followed): the
# symbol set of a register at a read is the union over the definitions that reach it, and a definition the model
# cannot account for (a refused query, a send result, an unlisted op) makes the set unknown. The premises:
#
#   P1  the constant has one SETCONST, in a class-body irep (the class irep), and every SETIDX whose base may hold
#       its GETCONST value is in one method (the writer), possibly inside blocks of that method.
#   P2  every read of a GETCONST value is the base of GETIDX or SETIDX (table_uses). No MCNST names the constant,
#       and neither it nor the writer is spelled as a Symbol or String anywhere (no `const_get(:T)`, `send(:op)`).
#   P3  every value a table SETIDX stores has a known symbol set.
#   P4  every call of the writer, by name, is in the class irep, with one plain arity that the writer's ENTER takes
#       as required parameters only. Each parameter's set is the union of its arguments' sets.
#   P5  the class irep and the writer create no symbol at run time (INTERN, to_sym, intern), and mutate a literal
#       container only through SETIDX or a core MUTATOR whose stored values are known (folded into every set).
#
# The universe of a table is the union of the sets of its stored values.
module IrSymbolFlow
  # Loads of a symbol, integer, nil, boolean or self: the values a literal table can hold.
  LITERAL_LOAD = /\ALOAD(SYM|I\w*|L|NIL|T|F|SELF|TRUE|FALSE)\z/.freeze
  SEND_OPS = %w[SEND SEND0 SENDB SSEND SSEND0 SSENDB].freeze
  # Core methods that add their arguments to their receiver.
  MUTATORS = %w[<< push].freeze
  # Core container methods that store values other than through MUTATORS: their arguments are not followed.
  OTHER_MUTATORS = %w[append concat unshift prepend insert replace fill []= store merge! update map! collect!
                      flatten! push_all].freeze
  SYMBOL_SENDS = %w[to_sym intern].freeze
  EMPTY = Set.new.freeze

  # params: writer label => { register => Set of names }. literal_consts: constant => Set of names.
  # user_methods: names the program defines (so core MUTATORS may be shadowed).
  Ctx = Struct.new(:ireps, :parents, :params, :literal_consts, :user_methods, :mutation_sites, keyword_init: true)

  module_function

  # names: method irep label => method name. Returns { const => Set<String> }.
  def dispatch_universes(ireps, names)
    parents = parent_map(ireps)
    index = site_index(ireps)
    user_methods = names.values.to_set
    result = {}
    index[:setconst].each do |const, class_labels|
      next unless class_labels.size == 1 # P1
      next if index[:mcnst].include?(const) || index[:spelled].include?(const) # P2

      class_label = class_labels.first
      writes = table_writes(ireps, index[:getconst][const]) or next # P2
      writers = writes.map { |label, _| enclosing_method(label, parents, names) }.uniq
      next unless writers.size == 1 && writers.first && writers.first != class_label # P1

      writer = writers.first
      next if index[:spelled].include?(names[writer]) # P2

      base = Ctx.new(ireps: ireps, parents: parents, params: {}, literal_consts: {}, user_methods: user_methods,
                     mutation_sites: {})
      base.literal_consts = literal_constants(base, index, class_label, const)
      params = writer_params(base, index, names[writer], class_label, ireps[writer]) or next # P4

      class_ireps = [class_label] + inner_labels(ireps, class_label, parents)
      writer_ireps = [writer] + inner_labels(ireps, writer, parents)
      next unless (class_ireps + writer_ireps).all? { |l| symbol_free?(ireps[l]) } # P5

      ctx = base.dup
      ctx.params = { writer => params }
      universe = Set.new
      ok = writes.all? do |label, idx| # P3
        set = values_at(ctx, label, idx, setidx_value_reg(ireps[label].instructions[idx]), Set.new)
        set && universe.merge(set)
      end
      result[const] = universe.freeze if ok
    end
    result
  end

  # The constant a splat argument register holds at idx, when it is built only as `*TABLE[i]`: ARYCAT onto nil
  # of GETIDX of GETCONST. nil otherwise.
  def splat_table(irep, idx, reg)
    defs = reaching(irep, idx, reg) or return nil
    consts = defs.map do |d|
      return nil if d.entry?

      insn = irep.instructions[d.index]
      next :nil if insn.op == 'LOADNIL'
      return nil unless insn.op == 'ARYCAT'

      onto = reaching(irep, d.index, insn.reg) or return nil
      return nil unless onto.all? { |o| !o.entry? && irep.instructions[o.index].op == 'LOADNIL' }

      get = single_def(irep, d.index, (insn.reg.to_i + 1).to_s, 'GETIDX') or return nil
      getc = single_def(irep, get, irep.instructions[get].reg, 'GETCONST') or return nil
      irep.instructions[getc].const_name or return nil
    end
    found = consts.reject { |c| c == :nil }.uniq
    found.size == 1 ? found.first : nil
  end

  # The index of the one definition of reg at idx when it is an op instruction, else nil.
  def single_def(irep, idx, reg, op)
    defs = reaching(irep, idx, reg)
    return nil unless defs&.size == 1 && !defs.first.entry?

    irep.instructions[defs.first.index].op == op ? defs.first.index : nil
  end

  # Reaching definitions across handler edges. The cap scales with the irep so a long class body still answers.
  def reaching(irep, idx, reg, follow_moves: true)
    cap = [BytecodeIR::DATAFLOW_MAX_STATES, irep.instructions.size * 4].max
    BytecodeIR.reaching_definitions(irep, idx, reg.to_s, through_handlers: true, follow_moves: follow_moves,
                                                         max_states: cap)
  end

  # One pass over every irep's instructions: SETCONST and GETCONST sites by name, names any MCNST op uses, writer
  # call candidates by name, and names spelled as data.
  def site_index(ireps)
    index = { setconst: Hash.new { |h, k| h[k] = [] }, getconst: Hash.new { |h, k| h[k] = [] },
              sends: Hash.new { |h, k| h[k] = [] }, mcnst: Set.new, spelled: Set.new }
    ireps.each do |label, irep|
      BytecodeIR.for(irep).instructions.each do |instruction|
        insn = instruction.source
        case insn.op
        when 'SETCONST' then index[:setconst][insn.const_name] << label if insn.const_name
        when 'GETCONST' then index[:getconst][insn.const_name] << [label, instruction.index] if insn.const_name
        when 'GETMCNST', 'SETMCNST' then index[:mcnst] << insn.const_name if insn.const_name
        when 'LOADSYM' then index[:spelled] << insn.sym if insn.sym
        when 'SYMBOL', 'STRING'
          entry = irep.pool[insn.pool_index.to_i]
          index[:spelled] << entry if entry.is_a?(String)
        when *SEND_OPS then index[:sends][insn.sym] << [label, instruction.index] if insn.sym
        end
      end
    end
    index
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

  # P1/P2: the table SETIDX sites of every GETCONST of the constant, or nil when a value escapes.
  def table_writes(ireps, getconsts)
    getconsts.each_with_object([]) do |(label, idx), writes|
      found = table_uses(ireps[label], idx) or return nil
      found.each { |n| writes << [label, n] }
    end.uniq
  end

  # The SETIDX instructions that store into the value the GETCONST at idx loads, or nil when that value may be read
  # any other way: as another operand or a send's receiver, copied by MOVE, or captured by a nested block. An
  # element a GETIDX reads from it may only be splatted (ARYCAT's source) or indexed in turn.
  def table_uses(irep, idx)
    reg = irep.instructions[idx].reg
    uses = reg && value_reads(irep, idx, reg) or return nil
    uses.each_with_object([]) do |n, writes|
      insn = irep.instructions[n]
      return nil unless insn.reg == reg

      case insn.op
      when 'SETIDX' then writes << n
      when 'GETIDX' then return nil unless element_reads_splat_only?(irep, n, reg)
      else return nil
      end
    end
  end

  def element_reads_splat_only?(irep, idx, reg)
    uses = value_reads(irep, idx, reg) or return false
    uses.all? do |n|
      insn = irep.instructions[n]
      (insn.op == 'ARYCAT' && insn.reg.to_i + 1 == reg.to_i) || (insn.op == 'GETIDX' && insn.reg == reg)
    end
  end

  # Ops that write R[a] on every normal exit (vm.c), so the value an earlier write left there is gone. Ops that
  # write no register, only maybe write it (a callee frame above a send) or mutate R[a] in place are absent.
  KILLS_LEAD = Set['MOVE', 'LOADL', 'LOADSYM', 'LOADNIL', 'LOADSELF', 'LOADTRUE', 'LOADFALSE', 'GETGV', 'GETSV',
                   'GETIV', 'GETCV', 'GETCONST', 'GETMCNST', 'GETUPVAR', 'GETIDX', 'GETIDX0', 'SETIDX', 'SSEND',
                   'SSEND0', 'SSENDB', 'SEND', 'SEND0', 'SENDB', 'SUPER', 'BLKCALL', 'ADD', 'ADDI', 'SUB', 'SUBI',
                   'MUL', 'DIV', 'EQ', 'LT', 'LE', 'GT', 'GE', 'ARRAY', 'ARRAY2', 'AREF', 'INTERN', 'SYMBOL',
                   'STRING', 'HASH', 'LAMBDA', 'BLOCK', 'METHOD', 'RANGE_INC', 'RANGE_EXC', 'OCLASS', 'CLASS',
                   'MODULE', 'EXEC', 'DEF', 'TDEF', 'SDEF', 'SCLASS', 'TCLASS'].freeze

  # Instructions that may read the value instruction idx leaves in reg: a forward walk over normal and handler
  # edges that stops at a write of reg (except along that write's own handler edges, raised before it). The
  # backward reaching definitions cannot answer this, since a callee frame below reg makes them refuse. nil when
  # the edges do not resolve, or a nested block reads reg.
  def value_reads(irep, idx, reg)
    program = BytecodeIR.for(irep)
    return nil unless program.resolved? && program.handlers_resolved?
    captured = captured_regs(irep) or return nil
    return nil if captured.include?(reg)

    seen = Set.new
    out = []
    work = program.instructions[idx].successors.dup
    until work.empty?
      n = work.pop
      next unless seen.add?(n)

      insn = program.instructions[n].source
      out << n if reads(irep, insn).include?(reg.to_i)
      kills = (KILLS_LEAD.include?(insn.op) || insn.op.start_with?('LOADI')) && insn.reg == reg
      work.concat(kills ? program.raise_targets.fetch(n, []) : program.successors_of(n, include_handlers: true))
    end
    out
  end

  # Registers of irep that a nested block reads with GETUPVAR (the level that reaches irep only), or nil when the
  # irep tree is not known.
  def captured_regs(irep)
    return Set.new if Array(irep.reps).empty?
    return nil unless irep.tree

    out = Set.new
    collect_captures(irep.tree, irep, 1, out)
    out
  end

  def collect_captures(tree, irep, depth, out)
    Array(irep.reps).each do |label|
      child = tree[label] or next
      BytecodeIR.for(child).instructions.each do |instruction|
        insn = instruction.source
        next unless insn.op == 'GETUPVAR'

        index, level = insn.upvar_ref
        out << index.to_s if index && level == depth - 1
      end
      collect_captures(tree, child, depth + 1, out)
    end
  end

  # Registers insn may read (vm.c, ops.h). Ops not listed read every register from their lowest named one up.
  def reads(irep, insn)
    regs = insn.regs.map(&:to_i)
    a = regs.first
    case insn.op
    when /\ALOAD/, 'GETGV', 'GETSV', 'GETIV', 'GETCV', 'GETCONST', 'GETUPVAR', 'STRING', 'SYMBOL', 'LAMBDA',
         'BLOCK', 'METHOD', 'OCLASS', 'TCLASS', 'TDEF', 'ENTER', 'NOP', 'STOP', 'JMP', 'JMPUW' then []
    when 'MOVE', 'AREF', 'GETIDX0' then regs.drop(1)
    when 'RETURN', 'RETURN_BLK', 'BREAK', 'JMPIF', 'JMPNOT', 'JMPNIL', 'SETGV', 'SETSV', 'SETIV', 'SETCV',
         'SETCONST', 'SETUPVAR', 'INTERN', 'ARYSPLAT', 'SCLASS', 'MODULE', 'EXEC', 'ADDI', 'SUBI', 'ADDILV', 'SUBILV'
      [a]
    when 'GETIDX', 'ADD', 'SUB', 'MUL', 'DIV', 'EQ', 'LT', 'LE', 'GT', 'GE', 'ARYCAT', 'STRCAT', 'HASHCAT',
         'RANGE_INC', 'RANGE_EXC', 'SETMCNST'
      [a, a + 1]
    when 'SETIDX' then [a, a + 1, a + 2]
    when 'ARRAY', 'ARRAY2' then element_regs(insn, 1)
    when 'HASH' then element_regs(insn, 2)
    when *SEND_OPS
      # R[a] (the receiver), then n arguments or one splat Array, then the block for the B forms.
      args = if insn.op.end_with?('0') then 0
             elsif insn.plain_fixed_argc? then insn.argc
             elsif insn.pure_splat? then 1
             end
      return (a...[irep.nregs.to_i, a + 1].max).to_a unless args

      (a..(a + args + (insn.op.end_with?('B') ? 1 : 0))).to_a
    else regs.empty? ? [] : (regs.min...[irep.nregs.to_i, regs.max + 1].max).to_a
    end
  end

  # ARRAY a n reads R[a]..R[a+n-1] (ARRAY a b n, ARRAY2's spelling, from R[b]); HASH a n reads R[a]..R[a+2n-1].
  def element_regs(insn, per)
    regs = insn.regs.map(&:to_i)
    first = regs.size >= 2 ? regs[1] : regs.first
    (first...(first + (per * int_operand(insn).to_i))).to_a
  end

  # Constants other than const whose one binding is a SETCONST of a literal value in the class irep, with their sets.
  def literal_constants(ctx, index, class_label, const)
    irep = ctx.ireps[class_label]
    BytecodeIR.for(irep).instructions.each_with_object({}) do |instruction, lits|
      insn = instruction.source
      name = insn.op == 'SETCONST' && insn.const_name
      next unless name && name != const && index[:setconst][name].size == 1 && !index[:mcnst].include?(name)

      set = values_at(ctx, class_label, instruction.index, insn.regs.last, Set.new)
      lits[insn.const_name] = set if set
    end
  end

  # P4: register => Set of names for the writer's parameters, or nil.
  def writer_params(ctx, index, name, class_label, writer_irep)
    return nil unless name

    calls = index[:sends][name]
    return nil if calls.empty? || calls.any? { |label, _| label != class_label }

    insns = calls.map { |label, idx| ctx.ireps[label].instructions[idx] }
    return nil unless insns.all?(&:plain_fixed_argc?)

    arities = insns.map(&:argc).uniq
    return nil unless arities.size == 1 && required_only?(writer_irep, arities.first)

    params = Hash.new { |h, k| h[k] = Set.new }
    calls.zip(insns).each do |(label, idx), insn|
      (1..arities.first).each do |k|
        set = values_at(ctx, label, idx, (insn.reg.to_i + k).to_s, Set.new) or return nil
        params[(k).to_s].merge(set)
      end
    end
    params.default_proc = nil
    params
  end

  # The writer's ENTER takes exactly arity required parameters and nothing else.
  def required_only?(irep, arity)
    enter = BytecodeIR.for(irep).instruction_at(0)&.source
    return false unless enter&.op == 'ENTER'

    fields = enter.enter_fields.first(7).map(&:to_i)
    fields.size == 7 && fields[0] == arity && fields[1..].all?(&:zero?)
  end

  # The symbol set of register reg as read at idx in irep label, or nil when it is not provably literal.
  # visiting holds (label, idx, reg) reads being computed; meeting one again is a cycle through definitions,
  # which adds no value of its own (greatest fixpoint).
  def values_at(ctx, label, idx, reg, visiting)
    return nil if reg.nil?

    key = [label, idx, reg.to_s]
    return EMPTY if visiting.include?(key)

    irep = ctx.ireps[label]
    defs = reaching(irep, idx, reg) or return nil
    visiting = visiting | [key]
    out = Set.new
    defs.each do |d|
      set = d.entry? ? ctx.params.dig(label, d.reg) : definition_values(ctx, label, d.index, visiting)
      return nil unless set

      out.merge(set)
    end
    mutated = mutation_values(ctx, label, visiting) or return nil
    out.merge(mutated)
  end

  # The symbol set the instruction at n of irep label produces, or nil.
  def definition_values(ctx, label, n, visiting)
    insn = ctx.ireps[label].instructions[n]
    reg = insn.reg.to_i
    case insn.op
    when 'LOADSYM' then insn.sym ? Set[insn.sym] : nil
    when LITERAL_LOAD then EMPTY
    when 'ARRAY', 'ARRAY2' then union(ctx, label, n, element_regs(insn, 1), visiting)
    when 'HASH' then union(ctx, label, n, element_regs(insn, 2), visiting)
    when 'ARYCAT' then union(ctx, label, n, [reg, reg + 1], visiting)
    when 'ARYPUSH', 'HASHADD'
      width = insn.op == 'HASHADD' ? 2 * insn.uint_operand.to_i : insn.uint_operand.to_i
      union(ctx, label, n, (reg..(reg + width)), visiting)
    when 'MOVE', 'AREF', 'GETIDX0' then values_at(ctx, label, n, insn.regs[1], visiting)
    when 'GETIDX' then values_at(ctx, label, n, insn.reg, visiting) # an element, whatever the index
    when 'GETCONST' then ctx.literal_consts[insn.const_name]
    when 'GETUPVAR' then upvalue_values(ctx, label, insn, visiting)
    end
  end

  def union(ctx, label, n, regs, visiting)
    regs.each_with_object(Set.new) do |r, out|
      set = values_at(ctx, label, n, r.to_s, visiting) or return nil
      out.merge(set)
    end
  end

  # A GETUPVAR reads register `index` of the irep `level + 1` levels up, at any time after the block is made:
  # flow-insensitive over that irep, the union of every write there (and the writer's parameter set). A register
  # another nested block writes (SETUPVAR) is unknown.
  def upvalue_values(ctx, label, insn, visiting)
    index, level = insn.upvar_ref
    return nil unless index

    target = label
    (level + 1).times { target = ctx.parents[target] }
    return nil unless target

    target_irep = ctx.ireps[target]
    reg = index.to_s
    return nil if BytecodeIR.own_upvar_written_regs(target_irep).include?(reg)

    program = BytecodeIR.for(target_irep)
    out = Set.new
    param = ctx.params.dig(target, reg)
    out.merge(param) if param
    writes = program.instructions.select { |i| program.may_write?(i.source, reg) }
    return nil if writes.empty? && !param

    writes.each do |w|
      set = definition_values(ctx, target, w.index, visiting)
      return nil unless set && w.source.reg == reg # a side write (a callee frame) is not followed

      out.merge(set)
    end
    out
  end

  # P5: the names a literal container of irep label can gain after it is built: the stored values of every SETIDX
  # and core MUTATOR there. nil when one is unknown, a MUTATOR may be user code, or another mutator is called.
  def mutation_values(ctx, label, visiting)
    key = [:mutations, label]
    return EMPTY if visiting.include?(key)

    visiting = visiting | [key]
    sites = mutation_sites(ctx, label) or return nil
    sites.each_with_object(Set.new) do |(n, r), out|
      set = values_at(ctx, label, n, r, visiting) or return nil
      out.merge(set)
    end
  end

  # [[index, register]] of the values irep label stores into containers, or false when one is not followed.
  def mutation_sites(ctx, label)
    ctx.mutation_sites.fetch(label) do
      sites = []
      BytecodeIR.for(ctx.ireps[label]).instructions.each do |instruction|
        regs = mutation_regs(ctx, instruction.source)
        unless regs
          sites = false
          break
        end
        regs.each { |r| sites << [instruction.index, r] }
      end
      ctx.mutation_sites[label] = sites
    end
  end

  # The registers whose values insn stores into a container, [] when it stores none, nil when it may store
  # values not followed.
  def mutation_regs(ctx, insn)
    case insn.op
    when 'SETIDX' then [setidx_value_reg(insn)]
    when 'ASET' then nil
    when *SEND_OPS
      return [] unless MUTATORS.include?(insn.sym) || OTHER_MUTATORS.include?(insn.sym)
      return nil if OTHER_MUTATORS.include?(insn.sym) || ctx.user_methods.include?(insn.sym)
      return nil unless insn.plain_fixed_argc?

      (1..insn.argc).map { |k| (insn.reg.to_i + k).to_s }
    else []
    end
  end

  # SETIDX a stores R[a+2].
  def setidx_value_reg(insn)
    (insn.reg.to_i + 2).to_s
  end

  def int_operand(insn)
    insn.typed.reverse.find { |operand| operand.kind == :int }&.value
  end

  # P5: no symbol is created at run time.
  def symbol_free?(irep)
    BytecodeIR.for(irep).instructions.none? do |instruction|
      insn = instruction.source
      insn.op == 'INTERN' || (SEND_OPS.include?(insn.op) && SYMBOL_SENDS.include?(insn.sym))
    end
  end
end
