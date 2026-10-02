# frozen_string_literal: true

require 'shellwords'
require_relative 'foreign_definers'
require_relative 'frozen_tables'
require_relative 'integer_constants'
require_relative 'native_expression_devirt'

# CodeGen: FROZEN_TABLES (docs/adr/0306). Feeds FrozenTables' kinds into the NumericFlow fixpoint:
# `LITERAL.freeze` gets the kind of its literal, `table[i]` / `first` / `last` / `sample` / `size`
# read the kind back.
#
# The proof is on only when:
#   - the program is a closed world with no global refusal and no per-instance singleton can exist (a
#     `def table.[]` would redirect the read), and no name installer has a computed name;
#   - for each name a read uses, mruby's own native Array/Hash method is the one a call reaches
#     (frozen_table_name_refusal).
# The literal's slots are read from the bytecode through reaching definitions, never from the flow.
class CodeGen
  FROZEN_TABLE_ANCESTORS = %w[Enumerable Object Kernel BasicObject Basic_object].freeze
  FROZEN_TABLE_CORE_PATH = %r{/3rd/mruby/(?:src|mrbgems)/}
  FROZEN_TABLE_NAMES = %w[freeze [] first last sample size length].freeze

  attr_reader :frozen_tables_refusal

  # Builds @frozen_tables (a FrozenTables::Registry) or leaves it nil with @frozen_tables_refusal
  # saying why. Runs after setup_lcf_rows (the bit ranges must not overlap).
  def setup_frozen_tables
    @frozen_tables = nil
    @frozen_table_sites = {}
    @frozen_table_name_safe = {}
    @frozen_tables_refusal = frozen_tables_refusal_reason
    return if @frozen_tables_refusal

    registry = FrozenTables::Registry.new
    @ireps.each do |label, irep|
      irep.instructions.each_with_index do |insn, idx|
        next unless insn.op == 'SEND0' && insn.sym == 'freeze'

        shape = frozen_table_literal_shape(irep, idx, insn, registry)
        @frozen_table_sites[[label, idx]] = shape.bit if shape
      end
    end
    @frozen_tables = registry unless registry.shapes.empty?
  end

  def frozen_tables_model
    @frozen_tables
  end

  # The kind `LITERAL.freeze` at SEND0 +index+ evaluates to, 0 when the site is not a tracked one.
  def frozen_table_freeze_site(irep, index)
    @frozen_table_sites && @frozen_table_sites[[irep.label, index]]
  end

  # Result class set of a SEND-family call whose receiver set holds table kinds (+bits+): the kind
  # reads below, OTHER for every other name.
  def frozen_table_send_mask(bits, name, argc)
    result = 0
    @frozen_tables.each_shape_in(bits) do |shape|
      result |= frozen_table_send_on(shape, name, argc)
    end
    result
  end

  # The class set of GETIDX/GETIDX0: the table kinds' reads joined with what the LCF model says
  # about the other bits. Unchanged (lcf_index_mask) when the receiver holds no table kind.
  def element_index_mask(irep, index, insn, state)
    return lcf_index_mask(irep, index, insn, state) unless @frozen_tables

    recv_reg = insn.op == 'GETIDX0' ? insn.regs[1].to_i : insn.reg.to_i
    recv = state[recv_reg]
    tables = recv ? @frozen_tables.tables(recv) : 0
    return lcf_index_mask(irep, index, insn, state) if tables.zero?

    key_reg = insn.reg.to_i + 1
    key = insn.op == 'GETIDX0' ? 0 : frozen_table_literal_key(irep, index, key_reg)
    key_int = insn.op == 'GETIDX0' || state[key_reg] == NumericFlow::INT
    # No index value yet (the fixpoint grows from empty): the result must not be OTHER.
    return 0 if state[key_reg]&.zero? && insn.op != 'GETIDX0'

    result = 0
    @frozen_tables.each_shape_in(tables) do |shape|
      klass = shape.array? ? 'Array' : 'Hash'
      result |= frozen_table_name_safe?('[]', klass) ? @frozen_tables.read(shape, key, key_int) : NumericFlow::OTHER
    end
    rest = recv & ~tables
    result | frozen_table_other_index(rest, irep, index, insn)
  end

# 'Array' | 'Hash' when the numeric flow proves +reg+ at +idx+ holds only frozen literals of that one
# container (a kind is exactly an Array or Hash literal, never a subclass or nil).
def frozen_table_exact_class(irep, idx, reg)
  return nil unless @frozen_tables && @closed_world&.exact_instances_singleton_free?

  mask = numeric_raw_mask(irep, idx, reg.to_s, true)
  return nil unless mask.is_a?(Integer) && mask.positive? && (mask & ~@frozen_tables.mask).zero?

  containers = []
  @frozen_tables.each_shape_in(mask) { |shape| containers << shape.container }
  containers.uniq.one? ? (containers.first == :array ? 'Array' : 'Hash') : nil
end

  # Slice of the diagnostic: one line per tracked literal shape.
  def frozen_tables_report
    return [] unless @frozen_tables

    counts = @frozen_table_sites.values.tally
    @frozen_tables.shapes.map { |s| "  FROZENTABLE #{@frozen_tables.name(s.bit)} (#{counts.fetch(s.bit, 0)} sites)" }.sort
  end

  private

  def frozen_table_other_index(rest, irep, index, insn)
    return 0 if rest.zero?
    return NumericFlow::OTHER unless @lcf_rows&.lcf_bits(rest)&.nonzero?

    lcf_key = insn.op == 'GETIDX0' ? 0 : lcf_literal_key(irep, index, insn.reg.to_i + 1)
    @lcf_rows.index(rest, lcf_key, nil_raises: numeric_nil_raises?('[]'))
  end

  def frozen_table_send_on(shape, name, argc)
    klass = shape.array? ? 'Array' : 'Hash'
    return NumericFlow::OTHER unless argc == 0 && frozen_table_name_safe?(name, klass)

    case name
    when 'size', 'length' then NumericFlow::INT
    when 'freeze' then shape.bit
    when 'first', 'last', 'sample' then shape.array? ? @frozen_tables.end_read(shape, name) : NumericFlow::OTHER
    else NumericFlow::OTHER
    end
  end

  def frozen_tables_refusal_reason
    return 'disabled by BC2CPP_FROZEN_TABLES=0' if ENV['BC2CPP_FROZEN_TABLES'] == '0'

    cw = @closed_world
    return 'no closed world' unless cw
    # Without the outside-source scans (an analysis-only CodeGen) no proof the numeric facts use is on either.
    return 'no outside-source scan' unless @foreign_method_names && @outside_const_names
    return 'closed world refused globally' unless cw.global_refusal.nil?
    return 'instances may gain singleton methods' unless cw.exact_instances_singleton_free?
    return 'a method installer has a computed name' if symbol_installed_names.nil?
    # The gates of ADR 0301's constant pools: a table is read through a constant and a `freeze` is folded.
    return 'BC2CPP_CLASS_POOLS withdraws the exact-class proofs' unless class_pools_enabled?
    return 'a const_missing can answer a failed constant lookup' unless const_missing_free?
    return 'freeze is not only Kernel#freeze' unless kernel_freeze_only?
    return 'LCF object kinds overlap the table kinds' if @lcf_rows && @lcf_rows.kinds.size > 256

    nil
  end

  # The shape of the literal a `freeze` at SEND0 +idx+ receives, or nil. Only a literal built by a
  # single ARRAY / HASH op qualifies (a literal grown by ARYPUSH/HASHADD/ARYCAT is another writer).
  def frozen_table_literal_shape(irep, idx, insn, registry)
    defs = BytecodeIR.reaching_definitions(irep, idx, insn.reg.to_s)
    return nil unless defs && defs.size == 1 && !defs.first.entry?

    at = defs.first.index
    lit = irep.instructions[at]
    return nil unless %w[ARRAY HASH].include?(lit.op) && lit.regs.size == 1
    # The literal's own `.freeze`, back to back: any other instruction in between could hand the
    # still-mutable array to code that changes its slots.
    return nil unless at + 1 == idx && lit.reg == insn.reg

    n = lit.uint_operand
    return nil unless n

    container = lit.op == 'ARRAY' ? :array : :hash
    return nil unless frozen_table_name_safe?('freeze', container == :array ? 'Array' : 'Hash')

    base = lit.reg.to_i
    stride = container == :array ? 1 : 2
    slot_regs = (0...n).map { |k| (base + stride * k + (container == :array ? 0 : 1)).to_s }
    slots = slot_regs.map { |r| frozen_table_slot_mask(irep, at, r) }
    keys = container == :hash ? frozen_table_hash_keys(irep, at, base, n) : nil
    registry.intern(container, slots, keys)
  end

  def frozen_table_hash_keys(irep, at, base, n)
    keys = (0...n).map { |k| frozen_table_literal_key(irep, at, base + 2 * k) }
    keys.all? ? keys : nil
  end

  # The literal Integer or Symbol register +reg+ holds when instruction +at+ reads it, else nil.
  def frozen_table_literal_key(irep, at, reg)
    defs = BytecodeIR.reaching_definitions(irep, at, reg.to_s)
    return nil unless defs && defs.size == 1 && !defs.first.entry?

    writer = irep.instructions[defs.first.index]
    return writer.sym&.to_sym if writer.op == 'LOADSYM'

    writer.op.start_with?('LOADI') ? frozen_table_loadi(writer) : nil
  end

  # The Integer a LOADI* op loads: `LOADI_n` / `LOADI__1` print it in parentheses, the others as an operand.
  def frozen_table_loadi(writer)
    return IntegerConstants.loadi_value(writer) if writer.imm_operand

    text = writer.paren_value
    text&.match?(/\A-?\d+\z/) ? text.to_i : nil
  end

  # The class set one literal slot has, from the writing op alone. OTHER for everything the literal
  # does not state (a Symbol, a call result, a constant not proven Integer).
  def frozen_table_slot_mask(irep, at, reg)
    defs = BytecodeIR.reaching_definitions(irep, at, reg)
    return NumericFlow::OTHER unless defs && defs.size == 1 && !defs.first.entry?

    writer = irep.instructions[defs.first.index]
    case writer.op
    when /\ALOADI/ then NumericFlow::INT
    when 'LOADL' then frozen_table_pool_mask(irep, writer)
    when 'STRING' then NumericFlow::STR
    when 'LOADNIL' then NumericFlow::NIL
    when 'ARRAY' then NumericFlow::ARR
    when 'HASH' then NumericFlow::HSH
    when 'RANGE_INC', 'RANGE_EXC' then NumericFlow::RNG
    when 'GETCONST', 'GETMCNST'
      name = writer.const_name
      name && @integer_constants&.include?(name) ? NumericFlow::INT : NumericFlow::OTHER
    else NumericFlow::OTHER
    end
  end

  def frozen_table_pool_mask(irep, writer)
    entry = writer.pool_index && irep.pool[writer.pool_index.to_i]
    return NumericFlow::OTHER unless entry.is_a?(Hash)

    case entry[:type]
    when :float then NumericFlow::FLT
    when :int32, :int64, :bigint then NumericFlow::INT
    else NumericFlow::OTHER
    end
  end

  def frozen_table_name_safe?(name, klass)
    key = [name, klass]
    return @frozen_table_name_safe[key] if @frozen_table_name_safe.key?(key)

    @frozen_table_name_safe[key] = frozen_table_name_refusal(name, klass).nil?
  end

  # nil, or why a call of +name+ on a exactly-+klass+ (Array or Hash) literal may not be mruby's own
  # method. Core natives are the semantics the shape rules assume (see the ADR); what can change them is a
  # Ruby or native definition on the receiver's ancestors, an installer, a prepend or an unknown mixin.
  def frozen_table_name_refusal(name, klass)
    world = @closed_world
    return :no_world unless world && @frozen_tables_refusal.nil?
    return :installed if symbol_installed_names.include?(name)
    return :no_core_native unless builtin_class_send_safe?(name, [klass])

    owners = frozen_table_owners(klass, name)
    return :foreign_ruby unless world.nil_foreign_definition_free?(name, owners)
    return :foreign_ruby if owners.any? { |owner| ForeignDefiners.defines?(frozen_table_foreign_paths, owner, name) }
    return :ruby_definition if (@registry[name] || []).any? { |d| d.irep && owners.include?(d.owner) }

    frozen_table_native_refusal(name, owners)
  end

# The classes whose definition of +name+ runs before mruby's native one. Array and Hash define
# `[]`/`first`/`size`/... themselves, so only they and what they prepend can shadow those; Kernel#freeze
# is shadowed from anywhere on the chain.
def frozen_table_owners(klass, name)
  chain = name == 'freeze'
  found = Set.new(chain ? [klass] + FROZEN_TABLE_ANCESTORS : [klass])
  queue = found.to_a
  until queue.empty?
    owner = queue.shift
    mixed = Array(@prepended_modules[owner]) + (chain ? Array(@included_modules[owner]) : [])
    mixed.each { |mod| queue << mod if found.add?(mod) }
  end
  found.to_a
end

  # The foreign Ruby this run was told about (the closed world reads the build's own list as well).
  def frozen_table_foreign_paths
    @frozen_table_foreign_paths ||= Shellwords.split(ENV.fetch('FOREIGN_RUBY_SRCS', ''))
  end

  # Registrations of the table names by native code outside mruby's own sources (the build's other
  # gems, a fixture's extra source): [registrations, opaque owners] as NativeExpressionDevirt scans them.
  def frozen_table_outside_registrations
    @frozen_table_outside_registrations ||= begin
      paths = Shellwords.split(ENV.fetch('NATIVE_SRCS', ''))
      FROZEN_TABLE_NAMES.each { |n| paths.concat(@closed_world.native_paths_spelling(n)) }
      NativeExpressionDevirt.scan_class_registrations(paths.uniq.reject { |path| path.match?(FROZEN_TABLE_CORE_PATH) })
    end
  end

  # A native outside mruby's own sources that registers +name+ on one of +owners+, or on a class the
  # scan cannot name, may replace the core method.
  def frozen_table_native_refusal(name, owners)
    registrations, opaque = frozen_table_outside_registrations
    named = registrations.fetch(name, []).map { |entry| entry[:owner]&.fetch(:class_name, nil) } + opaque.fetch(name, [])
    return :unresolved_native_owner if named.any?(&:nil?)

    :native_on_ancestor if named.any? { |owner| owners.include?(owner) }
  end
end
