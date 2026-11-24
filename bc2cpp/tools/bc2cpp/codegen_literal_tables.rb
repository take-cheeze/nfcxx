# frozen_string_literal: true

require 'set'
require_relative 'bytecode_ir'
require_relative 'reg_name'
require_relative 'symbol_cache'

# LITERAL_TABLES: a Hash or Array literal whose elements are compile-time constants (Integers, presym-spelled Symbols,
# String literals that are not frozen, nil/true/false, nested such literals) and constant reads (GETCONST, GETMCNST,
# LAMBDA: kept as they are, their values handed over) is one const word table in flash plus one call of the shared
# builder (bc2cpp_lit_build, symbol_cache.rb's prelude), instead of one load per element and one mrb_hash_set per pair.
# The builder makes what the instructions made: a fresh Hash/Array per container, a fresh String per String literal,
# pairs inserted in source order with mrb_hash_set.
#
# Soundness (literal_table_refusals): the tree's instructions are skipped, so a register one of them writes keeps its
# old value in the C++. The plan stands only when no emitted instruction can read such a register before an emitted
# write: the walk runs in instruction order from the writes, stopping at a jump target, a branch or any instruction
# whose reads are not listed in literal_table_effect; a register below nlocals (a local a block may capture) is never
# skipped; a body with catch handlers is refused. A kept constant read must reach the root with no emitted write of
# its register in between. A Hash key is a scalar literal or a flat Array of them (literal_table_key?).
# Kill switch: BC2CPP_LITERAL_TABLES=0.
class CodeGen
  LiteralNode = Struct.new(:kind, :idx, :value, :children, :reg, :parent)
  LiteralPlan = Struct.new(:skip, :glue) do
    def empty?
      glue.empty?
    end
  end

  LITERAL_TABLE_SCALARS = %i[int sym str nil true false].freeze
  # The builder's word format (bc2cpp_lit_node): bit 15 clear is a presym id; otherwise the top nibble is the tag
  # and the low 12 bits its operand.
  LITERAL_TABLE_LIMIT = 0x1000
  LITERAL_TABLE_MIN_NODES = 4
  LITERAL_TABLE_EMPTY = LiteralPlan.new(Set.new.freeze, {}.freeze).freeze

  def literal_tables_enabled?
    ENV['BC2CPP_LITERAL_TABLES'] != '0'
  end

  # LITERAL_WALK: the refusal walk steps over the class body's own instructions (class_body_literal_effect) instead of
  # stopping at them. Kill switch: BC2CPP_LITERAL_WALK=0.
  def literal_walk_enabled?
    ENV['BC2CPP_LITERAL_WALK'] != '0'
  end

  # The plan for one body: `skip` (instruction indices emitted as nothing) and `glue` (root index => C++ text).
  # `claimed` (addr, index) marks instructions another emitter owns; `freeze_send` admits the class body's
  # `literal.freeze`. `effect` (insn, index) gives [reads, writes] of an instruction the caller emits itself (or nil),
  # for the refusal walk only: the trees still stop at it.
  def literal_table_plan(irep, claimed: nil, freeze_send: false, effect: nil)
    return LITERAL_TABLE_EMPTY unless literal_tables_enabled?

    program = BytecodeIR.for(irep)
    return LITERAL_TABLE_EMPTY if program.handlers?

    forbidden = Set.new
    loop do
      roots = literal_table_trees(irep, program, claimed, forbidden)
      return LITERAL_TABLE_EMPTY if roots.empty?

      bad = literal_table_refusals(irep, program, roots, claimed, freeze_send, effect)
      return literal_table_finish(roots) if bad.empty?

      forbidden.merge(bad)
    end
  end

  private

  # Container trees of straight-line runs: a register's node is the literal it holds since the last jump target or
  # unmodelled instruction. A container consumes its operands' nodes, so no node has two parents.
  def literal_table_trees(irep, program, claimed, forbidden)
    targets = program.branch_target_addrs
    state = {}
    containers = []
    program.each_source do |insn, idx|
      # A jump target keeps its own text (and label); another emitter's instruction is not modelled.
      if targets.include?(insn.addr) || claimed&.call(insn.addr, idx)
        state.clear
        next
      end
      a = insn.reg
      if (leaf = literal_table_leaf(irep, insn, idx))
        state[a] = leaf
        next
      end

      case insn.op
      when :GETCONST, :LAMBDA
        state[a] = LiteralNode.new(:dyn, idx, nil, nil, a)
      when :GETMCNST
        # A proved Integer member (literal_table_const_int) is a leaf; the scope read before it stays an instruction.
        state[a] = if state[a]&.kind != :dyn then nil
                   elsif (value = literal_table_const_int(insn.mcnst_name)) then LiteralNode.new(:int, idx, value)
                   else LiteralNode.new(:dyn, idx, nil, nil, a)
                   end
      when :HASH, :ARRAY
        regs = literal_table_operands(insn)
        unless regs
          state.clear
          next
        end
        nodes = regs.map { |r| state[r] }
        regs.each { |r| state.delete(r) }
        node = nil
        if nodes.all? && !forbidden.include?(idx) && nodes.size < 2 * LITERAL_TABLE_LIMIT &&
           (insn.op == :ARRAY || nodes.each_slice(2).all? { |k, _| literal_table_key?(k) })
          node = LiteralNode.new(insn.op == :HASH ? :hash : :array, idx, nil, nodes, a)
          nodes.each { |child| child.parent = node }
          containers << node
        end
        state[a] = node
      when :ARYPUSH
        state[a] = literal_table_push(state, containers, insn, idx, forbidden)
      else
        state.clear
      end
    end
    # A table pays a call and its pointers: below LITERAL_TABLE_MIN_NODES the instructions are as small.
    containers.select { |node| node.parent.nil? && literal_table_members(node).size >= LITERAL_TABLE_MIN_NODES }
  end

  # LITERAL_PUSH_CHUNKS: mrbc builds an Array literal past its register window as ARRAY, then `ARYPUSH Ra n` per chunk
  # of loads. A chunk of static nodes joins the literal still in Ra: the ARYPUSH becomes the root and the instructions
  # it grows (the ARRAY, earlier ARYPUSHes) are skipped members (`value`). nil when the chunk is not static.
  def literal_table_push(state, containers, insn, idx, forbidden)
    a = insn.reg
    base = state[a]
    n = insn.uint_operand
    return nil unless n && base&.kind == :array && base.parent.nil? && !forbidden.include?(idx)

    regs = ((a + 1)..(a + n)).to_a
    nodes = regs.map { |r| state[r] }
    regs.each { |r| state.delete(r) }
    return nil unless nodes.all? && base.children.size + nodes.size < LITERAL_TABLE_LIMIT

    grown = LiteralNode.new(:array, idx, [*base.value, base.idx], base.children + nodes, a)
    grown.children.each { |child| child.parent = grown }
    containers.delete(base)
    containers << grown
    grown
  end

  # A Hash key the table may hold: a scalar literal, or (LITERAL_ARRAY_KEYS) an Array literal of non-String scalars.
  # An Array key's `hash`/`eql?` may be Ruby, but the builder makes the same mrb_hash_set calls in the same order on
  # equal, fully built keys and values; only when the later pairs' fresh objects are allocated differs, which no Ruby
  # code can reach. Kill switch: BC2CPP_LITERAL_ARRAY_KEYS=0.
  def literal_table_key?(node)
    return true if LITERAL_TABLE_SCALARS.include?(node.kind)

    ENV['BC2CPP_LITERAL_ARRAY_KEYS'] != '0' && node.kind == :array &&
      node.children.all? { |child| LITERAL_TABLE_SCALARS.include?(child.kind) && child.kind != :str }
  end

  # The registers a HASH or ARRAY reads, in order; nil for a shape not modelled.
  def literal_table_operands(insn)
    a = insn.reg
    if insn.op == :HASH
      n = insn.uint_operand
      n && (a...(a + (2 * n))).to_a
    else
      three = insn.src_and_literal
      src = three ? three[0].to_i : a
      n = three ? three[1].to_i : insn.uint_operand
      n && (src...(src + n)).to_a
    end
  end

  # A static leaf for a constant load (the value compile_insn would load), or nil.
  def literal_table_leaf(irep, insn, idx)
    case insn.op
    when :LOADNIL then LiteralNode.new(:nil, idx)
    when :LOADTRUE then LiteralNode.new(:true, idx)
    when :LOADFALSE then LiteralNode.new(:false, idx)
    when :LOADSYM
      name = insn.sym_token
      # A quoted or escaped spelling (QUOTED_SYMBOL) is not the name itself.
      return nil unless name&.match?(/\A[^"\\]*\z/)

      macro = SymbolCache.presym_macro("\"#{name}\"")
      macro && LiteralNode.new(:sym, idx, macro)
    when :GETCONST
      value = literal_table_const_int(insn.const_name)
      value && LiteralNode.new(:int, idx, value)
    when :STRING
      entry = irep.pool.fetch(insn.pool_index.to_i)
      # A frozen literal (FROZEN_LITERALS) is one persistent object, which compile_insn reads; it stays an instruction.
      return nil if !entry.is_a?(String) || (insn.frozen_literal && frozen_literals_enabled?)

      LiteralNode.new(:str, idx, entry)
    else
      return nil unless BytecodeIR::Ops::LOADI_OPS.include?(insn.op)

      lit = insn.paren_value || BytecodeIR::OperandModel.imm_operand(insn)
      value = Integer(lit.to_s, exception: false)
      value && value.between?(-0x8000_0000, 0x7fff_ffff) ? LiteralNode.new(:int, idx, value) : nil
    end
  end

  # LITERAL_CONST_INTS: the value compile_insn loads for a constant INTEGER_CONSTANT_VALUE_PROOF proved (its GETCONST
  # or GETMCNST is that fixnum and nothing else), when it fits a table word; nil otherwise. Kill switch:
  # BC2CPP_LITERAL_CONST_INTS=0.
  def literal_table_const_int(name)
    return nil if ENV['BC2CPP_LITERAL_CONST_INTS'] == '0'

    value = self.class.integer_constant_values&.[](name)
    value.is_a?(Integer) && value.between?(-0x8000_0000, 0x7fff_ffff) ? value : nil
  end

  # [reads, writes] of an instruction the refusal walk may step over, or nil (its reads are not known). An emitted
  # instruction's C++ reads exactly these registers.
  def literal_table_effect(insn, freeze_send)
    a = insn.reg
    op = insn.op
    if BytecodeIR::Ops::LOADI_OPS.include?(op) ||
       %i[LOADNIL LOADTRUE LOADFALSE LOADSYM LOADSELF LOADL STRING SYMBOL GETCONST LAMBDA].include?(op)
      [[], [a]]
    elsif op == :GETMCNST || (freeze_send && op == :SEND0 && insn.sym.to_s == 'freeze')
      [[a], [a]]
    elsif op == :MOVE
      d, s = insn.regs.first(2)
      [[s.to_i], [d.to_i]]
    elsif %i[SETCONST SETGV SETIV SETCV].include?(op)
      [[a], []]
    elsif %i[HASH ARRAY].include?(op)
      regs = literal_table_operands(insn)
      regs && [regs, [a]]
    elsif op == :NOP
      [[], []]
    end
  end

  # Root indices whose plan is unsound (see the file comment); empty when every plan stands.
  def literal_table_refusals(irep, program, roots, claimed, freeze_send, outer_effect = nil)
    nlocals = irep.nlocals.to_i
    member_root = {}
    root_at = {}
    bad = Set.new
    roots.each do |root|
      root_at[root.idx] = root
      literal_table_members(root).each { |node| member_root[node.idx] = root.idx }
      counts = literal_table_counts(root)
      bad << root.idx if counts.any? { |c| c >= LITERAL_TABLE_LIMIT }
    end
    member_root.each { |idx, root| bad << root if program.source_at(idx).reg < nlocals }
    targets = program.branch_target_addrs
    live = {}
    fail_all = lambda do
      bad.merge(live.values)
      live.clear
    end
    program.each_source do |insn, idx|
      fail_all.call if targets.include?(insn.addr) && !live.empty?
      if (root = member_root[idx])
        live[insn.reg] = root
        next
      end
      if (root = root_at[idx])
        # The kept constant reads it hands over: no emitted write of their register since they ran.
        literal_table_dyn_nodes(root).each do |dyn|
          clobbered = ((dyn.idx + 1)...idx).any? do |i|
            !member_root.key?(i) && literal_table_effect(program.source_at(i), freeze_send)&.last&.include?(dyn.reg)
          end
          bad << root.idx if clobbered
        end
        live.delete(root.reg)
        next
      end
      case insn.op
      when :RETURN
        bad << live[insn.reg] if live.key?(insn.reg)
        live.clear
        next
      when :RETNIL, :STOP
        live.clear
        next
      end
      effect = outer_effect && literal_walk_enabled? && outer_effect.call(insn, idx)
      effect ||= claimed&.call(insn.addr, idx) ? nil : literal_table_effect(insn, freeze_send)
      unless effect
        fail_all.call
        next
      end
      reads, writes = effect
      reads.each { |r| bad << live[r] if live.key?(r) }
      writes.each { |r| live.delete(r) }
    end
    bad.merge(live.values)
    bad
  end

  # Every node a root's table replaces: its containers and static leaves, not the root itself or a kept read.
  def literal_table_members(root, out = [])
    Array(root.value).each { |grown| out << LiteralNode.new(:grown, grown, nil, nil, root.reg) } if root.kind == :array
    root.children.each do |child|
      next if child.kind == :dyn

      out << child
      literal_table_members(child, out) if child.children
    end
    out
  end

  def literal_table_dyn_nodes(root, out = [])
    root.children.each do |child|
      out << child if child.kind == :dyn
      literal_table_dyn_nodes(child, out) if child.children
    end
    out
  end

  # [strings, kept reads] of one table: each indexes a 12-bit operand.
  def literal_table_counts(root)
    strings = 0
    walk = lambda do |node|
      strings += 1 if node.kind == :str
      node.children&.each { |child| walk.call(child) }
    end
    walk.call(root)
    [strings, literal_table_dyn_nodes(root).size]
  end

  def literal_table_finish(roots)
    skip = Set.new
    glue = {}
    roots.each do |root|
      literal_table_members(root).each { |node| skip << node.idx }
      glue[root.idx] = literal_table_glue(root)
    end
    LiteralPlan.new(skip.freeze, glue.freeze)
  end

  def literal_table_glue(root)
    words = []
    strings = []
    dyn = []
    encode = lambda do |node|
      case node.kind
      when :sym then words << "(uint16_t)#{node.value}"
      when :int
        if node.value.between?(0, LITERAL_TABLE_LIMIT - 1)
          words << format('0x%04x', 0x8000 | node.value)
        else
          bits = node.value & 0xffff_ffff
          words << '0x9000' << format('0x%04x', bits & 0xffff) << format('0x%04x', bits >> 16)
        end
      when :hash, :array
        count = node.kind == :hash ? node.children.size / 2 : node.children.size
        words << format('0x%04x', (node.kind == :hash ? 0xa000 : 0xb000) | count)
        node.children.each { |child| encode.call(child) }
      when :str
        words << format('0x%04x', 0xc000 | strings.size)
        strings << "BC2CPP_LIT_STR(#{c_string_literal(node.value)})"
      when :dyn
        words << format('0x%04x', 0xd000 | dyn.size)
        dyn << RegName[node.reg]
      when :nil then words << '0xe000'
      when :true then words << '0xe001'
      when :false then words << '0xe002'
      end
    end
    encode.call(root)
    out = +"  {\n"
    out << "    static const uint16_t bc2cpp_lit[] = { #{words.join(', ')} };\n"
    out << "    static const Bc2cppLitStr bc2cpp_lit_s[] = { #{strings.join(', ')} };\n" unless strings.empty?
    out << "    const mrb_value bc2cpp_lit_d[] = { #{dyn.join(', ')} };\n" unless dyn.empty?
    strs = strings.empty? ? 'nullptr' : 'bc2cpp_lit_s'
    out << "    #{RegName[root.reg]} = bc2cpp_lit_build(M, bc2cpp_lit, #{strs}, #{dyn.empty? ? 'nullptr' : 'bc2cpp_lit_d'});\n"
    out << "  }\n"
  end
end
