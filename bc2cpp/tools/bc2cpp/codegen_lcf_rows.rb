# frozen_string_literal: true

require_relative 'lcf_row_flow'

# CodeGen: LCF_ROW_FLOW (docs/adr/0294). Feeds LcfRowFlow's object kinds into the NumericFlow fixpoint and
# reads them back as unguarded exact receiver classes.
#
# The proof is on only when the program is exactly what lcf_row_flow.rb models:
#   - a closed world with no global refusal, where LCF::Database, LCF::Array1D and LCF::Array2D have no
#     subclass and no outside file touches them, no per-instance singleton can exist, `new` is the standard
#     constructor and the class constants are stable, so a bit means "exactly that class";
#   - `LCF::File#[]`, `Array1D#[]`, `Array2D#[]` and `Array2D#[]=` are each defined once, so the bodies
#     the model describes are the ones a call runs;
#   - nothing can write the ivars the model relies on (`@root @data @decoded @schema @sym2idx`) behind the
#     compiler's back (reflection, a native or foreign spelling of the name).
class CodeGen
  LCF_ROW_MRBLIB = File.expand_path('../../mruby-lcf/mrblib', __dir__)
  LCF_ROW_OWNERS = %w[LCF::Database LCF::Array1D LCF::Array2D].freeze
  LCF_ROW_DEFS = { '[]' => %w[LCF::File LCF::Array1D LCF::Array2D], '[]=' => %w[LCF::Array2D] }.freeze
  LCF_ROW_IVARS = %w[root data decoded schema sym2idx].freeze

  attr_reader :lcf_rows_refusal

  # Builds @lcf_rows (an LcfRowFlow::Model) or leaves it nil with @lcf_rows_refusal saying why. Needs the
  # numeric ivar prerequisites, so it runs after setup_numeric_ivar_groups.
  def setup_lcf_rows
    @lcf_rows = nil
    @lcf_rows_refusal = lcf_rows_refusal_reason
    @lcf_rows = LcfRowFlow.model(LCF_ROW_MRBLIB) unless @lcf_rows_refusal
  end

  def lcf_rows_model
    @lcf_rows
  end

  # The result class set of GETIDX/GETIDX0: what LcfRowFlow says for a receiver carrying an LCF kind,
  # OTHER for anything else (the existing behaviour).
  def lcf_index_mask(irep, index, insn, state)
    return NumericFlow::OTHER unless @lcf_rows

    recv = state[insn.op == 'GETIDX0' ? insn.regs[1].to_i : insn.reg.to_i]
    return NumericFlow::OTHER unless recv
    # No value yet (the fixpoint grows from empty): the result must not be OTHER, which never shrinks.
    return 0 if recv.zero?
    return NumericFlow::OTHER unless @lcf_rows.lcf_bits(recv).nonzero?

    key = insn.op == 'GETIDX0' ? 0 : lcf_literal_key(irep, index, insn.reg.to_i + 1)
    @lcf_rows.index(recv, key, nil_raises: numeric_nil_raises?('[]'))
  end

  # The mask of `Klass.new(...)` for a file class, nil when the send is not one.
  def lcf_new_mask(irep, index, insn)
    return nil unless @lcf_rows && insn.sym == 'new'

    klass = record_new_class(irep, index, insn)
    klass && @lcf_rows.file_bit(klass)
  end

  # [class, nilable] when the flow proves +reg+ at +idx+ is exactly one LCF kind, or that kind or nil
  # where nil only raises for +name+ (the caller tests for it); else nil.
  def lcf_exact_receiver(irep, idx, reg, owner_def, name)
    return nil unless @lcf_rows && irep && idx && reg

    mask = numeric_raw_mask(irep, idx, reg.to_s, owner_def)
    return nil unless mask.is_a?(Integer)

    nilable = mask.anybits?(NumericFlow::NIL)
    return nil if nilable && !numeric_nil_raises?(name)

    klass = @lcf_rows.exact_owner(mask & ~NumericFlow::NIL)
    klass && [klass, nilable]
  end

  # The definition a call of +name+ on an exactly-+klass+ receiver runs, from the registry alone: the walk
  # up the superclass chain passes only classes no outside file can touch (closed_world_exact_target also
  # refuses a name spelled in any native source, which `[]` always is). nil when the answer is not one
  # bytecode definition.
  def lcf_exact_target(name, klass)
    cw = @closed_world
    return nil unless @lcf_rows && cw && !devirt_blocked_name?(name)
    return nil if symbol_installed_names.nil? || symbol_installed_names.include?(name)

    seen = Set.new
    current = klass
    loop do
      return nil unless seen.add?(current) && cw.untouched_class?(current) && cw.stable_class_constant?(current)
      return nil if @unknown_mixins.include?(current) || !Array(@prepended_modules[current]).empty?

      here = @registry.fetch(name, []).select { |d| d.owner == current }
      return (here.one? && here.first.irep ? here.first : nil) unless here.empty?

      mixed = Array(@included_modules[current])
      return nil if @registry.fetch(name, []).any? { |d| mixed.include?(d.owner) }

      current = @superclass_of[current]
      return nil unless current.is_a?(String)
    end
  end

  private

  def lcf_rows_refusal_reason
    cw = @closed_world
    return 'no closed world' unless cw
    return 'numeric ivar proof unavailable' if numeric_ivar_prerequisites_missing? || @numeric_ivar_disabled
    return 'closed world refused globally' unless cw.global_refusal.nil?
    return 'schema sources missing' unless File.exist?(File.join(LCF_ROW_MRBLIB, 'schema.rb'))

    missing = (LCF_ROW_OWNERS + ['LCF::File']).reject { |o| cw.class_declared?(o) }
    return "no #{missing.join(', ')} in the program" unless missing.empty?

    LCF_ROW_OWNERS.each do |o|
      return "#{o} has a subclass or is touched from outside" unless cw.exact_class?(o) && cw.untouched_class?(o)
      return "#{o} constant is not stable" unless cw.stable_class_constant?(o)
    end
    return 'LCF::File is touched from outside' unless cw.untouched_class?('LCF::File')
    return 'instances may gain singleton methods' unless cw.exact_instances_singleton_free?
    return 'new/allocate is redefined' unless cw.standard_constructor_lookup?

    LCF_ROW_DEFS.each do |name, owners|
      owners.each do |owner|
        found = (@registry[name] || []).count { |d| d.owner == owner && d.irep }
        return "#{owner}##{name} is not defined exactly once" unless found == 1
      end
    end
    bad = LCF_ROW_IVARS.select { |n| numeric_ivar_poisoned_names.include?(n) }
    return "ivar #{bad.join(', ')} is written by name outside the compiler's view" unless bad.empty?

    nil
  end

  # The literal Symbol a GETIDX key register holds, nil when there is not exactly one definition.
  def lcf_literal_key(irep, index, key_reg)
    defs = BytecodeIR.reaching_definitions(irep, index, key_reg.to_s)
    return nil unless defs && defs.size == 1 && !defs.first.entry?

    writer = irep.instructions[defs.first.index]
    writer.op == 'LOADSYM' ? writer.sym&.to_sym : nil
  end
end
