# frozen_string_literal: true

require 'set'
require_relative 'integer_constants'

# COMPUTED_SEND_EXPANSION (ADR 0303): the finite set of method names a computed-name
# `send(name, ...)` can carry, when the program makes it provable.
#
# Two sources, both read off reaching definitions of the name register (BytecodeIR), so a join
# of branches (`case`/`when`, `?:`) is covered and an unmodelled write refuses:
#   * a literal: every definition reaching the name is a LOADSYM / SYMBOL;
#   * a table: the definition is `TABLE[i]` (GETIDX) and every definition of the receiver is a
#     GETCONST/GETMCNST of a bare constant name that SymbolTables proves is a frozen Array or
#     Hash literal of Symbol literals. The element may also be nil (an index or key outside the
#     table), which `send` rejects with a TypeError; `nilable` records it.
module ComputedSendNames
  # A proof: `names` (Array, first-seen order) and whether the value may be nil.
  Names = Struct.new(:names, :nilable, :source, keyword_init: true)

  # Names the expansion declines: `name=` and operators would need the keyword/operator spelling
  # compile_send keeps for real call sites.
  PLAIN_NAME = /\A[A-Za-z_][A-Za-z0-9_]*[?!]?\z/
  MAX_NAMES = 24

  # The name set of the register `reg` read at instruction `idx` of `irep`, or nil when it is not
  # provably a finite set of plain Symbols. +tables+ is SymbolTables.analyze's result.
  def self.names_at(irep, idx, reg, tables)
    defs = reaching(irep, idx, reg) or return nil
    names = []
    nilable = false
    sources = Set.new
    defs.each do |definition|
      insn = irep.instructions[definition.index]
      case insn.op
      when 'LOADSYM', 'SYMBOL'
        literal = symbol_literal(irep, insn) or return nil
        names << literal
        sources << :literal
      when 'GETIDX'
        found = table_names(irep, definition.index, insn, tables) or return nil
        names.concat(found)
        nilable = true
        sources << :table
      else
        return nil
      end
    end
    names.uniq!
    return nil if names.empty? || names.size > MAX_NAMES || !names.all? { |n| n.match?(PLAIN_NAME) }

    Names.new(names: names, nilable: nilable, source: sources.to_a.sort.join('+'))
  end

  def self.reaching(irep, idx, reg)
    defs = BytecodeIR.reaching_definitions(irep, idx, reg.to_s)
    return nil if defs.nil? || defs.empty? || defs.any?(&:entry?)

    defs
  end

  # LOADSYM :a names its symbol; SYMBOL (what %i[a b] and :"a b" compile to) reads the pool.
  def self.symbol_literal(irep, insn)
    return insn.sym if insn.op == 'LOADSYM'

    entry = irep.pool[insn.pool_index.to_i]
    entry if entry.is_a?(String)
  end

  # `TABLE[i]`: the receiver register of the GETIDX at +index+ must come only from constants
  # SymbolTables admitted.
  def self.table_names(irep, index, insn, tables)
    return nil if tables.nil? || tables.empty?

    receivers = reaching(irep, index, insn.reg) or return nil
    sets = receivers.map do |definition|
      load = irep.instructions[definition.index]
      bare = case load.op
             when 'GETCONST', 'GETMCNST' then load.const_name
             end
      bare && tables[bare]
    end
    return nil if sets.any?(&:nil?)

    sets.flat_map(&:to_a)
  end

  # Bare constant name -> Set of the Symbol names every definition of it holds, for the names
  # whose every definition is `[:a, :b].freeze` or `{k => :a}.freeze` (Symbol literals as the
  # elements / values). Keyed by bare name like IntegerConstants, with its four poison sources:
  # a definition of another shape, a CLASS/MODULE of the name, a native mrb_define_const /
  # mrb_const_set / mrb_define_class and a foreign Ruby source. A runtime const_set,
  # remove_const or autoload refuses every table (same hole list as IntegerConstants).
  module SymbolTables
    CONST_REBINDERS = %w[const_set remove_const autoload].freeze

    def self.analyze(ireps, native_paths, foreign_paths)
      return {} if native_paths.nil? || foreign_paths.nil?
      return {} if rebinder?(ireps)

      defs = Hash.new { |h, k| h[k] = [] }
      poisoned = Set.new
      ireps.each_value do |irep|
        irep.instructions.each_with_index do |insn, idx|
          case insn.op
          when 'SETCONST', 'SETMCNST'
            name = insn.const_name or next
            defs[name] << definition_names(irep, idx, insn.regs.last)
          when 'CLASS', 'MODULE'
            poisoned << insn.sym_token if insn.sym_token
          end
        end
      end
      poisoned.merge(IntegerConstants.native_defined_const_names(native_paths))
      poisoned.merge(IntegerConstants.foreign_const_names(foreign_paths))
      defs.each_with_object({}) do |(name, found), tables|
        next if poisoned.include?(name) || found.empty? || found.any?(&:nil?)

        tables[name] = found.flatten.to_set.freeze
      end
    end

    def self.rebinder?(ireps)
      ireps.each_value.any? do |irep|
        irep.instructions.any? { |insn| insn.op.include?('SEND') && CONST_REBINDERS.include?(insn.sym) }
      end
    end

    # The symbols of the frozen literal the constant is assigned from `reg`, or nil.
    def self.definition_names(irep, idx, reg)
      frozen = ComputedSendNames.reaching(irep, idx, reg)
      return nil unless frozen&.size == 1

      call = irep.instructions[frozen.first.index]
      return nil unless %w[SEND SEND0].include?(call.op) && call.sym == 'freeze' && call.n_spec.to_i.zero? && !call.nk_spec

      literal = ComputedSendNames.reaching(irep, frozen.first.index, call.reg)
      return nil unless literal&.size == 1

      container = irep.instructions[literal.first.index]
      case container.op
      when 'ARRAY' then element_names(irep, literal.first.index, container.reg.to_i, container.uint_operand.to_i, 1, 0)
      when 'HASH' then element_names(irep, literal.first.index, container.reg.to_i, container.uint_operand.to_i * 2, 2, 1)
      end
    end

    # `count` registers from +first+; every +stride+-th starting at +offset+ is an element whose
    # definitions must all be Symbol literals (a Hash's keys are never read).
    def self.element_names(irep, at, first, count, stride, offset)
      return nil unless count.positive?

      names = []
      (offset...count).step(stride) do |k|
        defs = ComputedSendNames.reaching(irep, at, (first + k).to_s) or return nil
        defs.each do |definition|
          insn = irep.instructions[definition.index]
          return nil unless %w[LOADSYM SYMBOL].include?(insn.op)

          literal = ComputedSendNames.symbol_literal(irep, insn) or return nil
          names << literal
        end
      end
      names
    end
  end
end
