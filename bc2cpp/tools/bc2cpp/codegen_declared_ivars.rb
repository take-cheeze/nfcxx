# frozen_string_literal: true

require 'set'

# CodeGen: DECLARED_IVAR_GUARD and DECLARED_IVAR_PROOF.
#
# An RBS `@x: T` (or `attr_reader x: T`) declaration of a program class is a fact nothing proves. For T = Integer, Float,
# Symbol or an exact program class (and `T?`) it is checked where the slot is written instead:
#
# DECLARED_IVAR_GUARD   every store a compiled body makes to the slot (SETIV, and an inlined `x=`) tests the declared kind
#                       first and raises BC2cppDeclarationViolation through bc2cpp_declared_ivar_violation, naming the
#                       ivar and the type. A store whose value the flow already proves gets no test (DECLARED_IVAR_PROVEN
#                       marker). `bool` stays unchecked by design, as for parameters and returns. BC2CPP_DECLARATION_GUARD=0
#                       drops the guards with the other plain declarations.
# DECLARED_IVAR_PROOF   once no store can bypass those guards, the declared kind is the slot's class pool (setup_class_pools:
#                       a fixed seed, like a declared parameter's), so a `get_ivar`-origin receiver is a proven one. The
#                       preconditions, all about stores the guards cannot see:
#                         * the slot's NUMERIC_IVAR_PROOF group has no writer outside its SETIV sites (not structural: no
#                           attr_writer, native store, reflection, rebinder, unowned irep);
#                         * every irep that touches the name belongs to the declaring class or one of its descendants, so
#                           the declaration covers every instance the family's slot lives on, and no other class of the
#                           family declares the name;
#                         * every method that stores to the slot is compiled with its guard in this run (a method left
#                           `#error`, and so interpreted, runs unguarded: declared_ivar_writer_failures aborts the run,
#                           as DECLARED_RETURN_GUARD does). BC2CPP_DECLARED_IVAR_PROOF=0 keeps the guards and drops the seed.
class CodeGen
  class << self
    # { [owner, name without @] => RbsParamCheck::IvarGuard } for this build (nil: none).
    attr_accessor :declared_ivars
  end

  # The declaration `name` of `klass` or its nearest declaring ancestor, or nil.
  def declared_ivar_entry(klass, name)
    table = self.class.declared_ivars
    return nil if table.nil? || table.empty? || klass.nil?

    name = name.to_s
    k = klass
    64.times do
      return nil unless k.is_a?(String)

      entry = table[[k, name]]
      return entry if entry

      k = @superclass_of[k]
    end
    nil
  end

  # The C++ test that `var` (an mrb_value) has the declared kind. Integer is any Integer (mrb_integer_p, or a bignum:
  # mrb_bigint_p is FALSE in a build without them), not mrb_fixnum_p: the RBS type includes a bignum, and the class
  # pool's Integer bit does too.
  def declared_ivar_condition(entry, var)
    cond = case entry.kind
           when :float then "mrb_float_p(#{var})"
           when :integer then "(mrb_integer_p(#{var}) || mrb_bigint_p(#{var}))"
           when :symbol then "mrb_symbol_p(#{var})"
           else exact_class_guard(owner_class_ptr_expr(entry.cls), var)
           end
    entry.nilable ? "mrb_nil_p(#{var}) || (#{cond})" : cond
  end

  # Does a flow mask (NumericFlow bits) put the stored value inside the declared kind?
  def declared_ivar_proven?(entry, mask)
    bits = declared_arg_bits(entry.cls, entry.kind, entry.nilable)
    !bits.zero? && mask.is_a?(Integer) && !mask.zero? && (mask & ~bits).zero?
  end

  # DECLARED_IVAR_GUARD: the statement checking the value `src` (a register name, an mrb_value) a store puts into
  # `name` of a `klass` instance, '' when the slot has no checked declaration. +mask+: the flow's class set of `src`
  # at the store, when known.
  def declared_ivar_store_guard(klass, name, src, mask = nil)
    entry = declared_ivar_entry(klass, name)
    return '' unless entry
    return "  /* DECLARED_IVAR_PROVEN #{entry.key} */\n" if mask && declared_ivar_proven?(entry, mask)

    quote = ->(text) { text.gsub(/["\\]/) { |c| "\\#{c}" } }
    "  if (mrb_unlikely(!(#{declared_ivar_condition(entry, src)}))) " \
      "bc2cpp_declared_ivar_violation(M, #{src}, \"#{quote.call(entry.key)}\", \"#{quote.call(entry.text)}\"); " \
      "/* DECLARED_IVAR_GUARD #{entry.key} */\n"
  end

  # The guard of the SETIV at +idx+ of +irep+ (self's slot), proven away when the flow already shows the declared kind.
  def declared_ivar_setiv_guard(insn, irep, owner_def, idx, reg_offset)
    return '' if self.class.declared_ivars.nil? || self.class.declared_ivars.empty? || owner_def.nil?

    klass = owner_def.owner
    return '' unless declared_ivar_entry(klass, insn.ivar)

    src = insn.regs.first
    mask = idx && irep ? exact_flow_mask(irep, idx, unshift_proof_reg(src, reg_offset)) : nil
    declared_ivar_store_guard(klass, insn.ivar, RegName[src], mask)
  end

  # DECLARED_IVAR_PROOF: { [family, name] => [entry, class bits] } of the declarations whose guarded stores make the
  # declared kind the slot's class pool (see the file comment for the preconditions).
  def declared_ivar_seeds
    return @declared_ivar_seeds if @declared_ivar_seeds

    @declared_ivar_seeds = {}
    table = self.class.declared_ivars
    return @declared_ivar_seeds if table.nil? || table.empty? || ENV['BC2CPP_DECLARED_IVAR_PROOF'] == '0' ||
                                   @numeric_ivar_disabled || @numeric_ivar_groups.nil?

    by_slot = table.values.group_by { |e| [numeric_family(e.owner), e.name] }
    by_slot.each do |key, entries|
      next unless entries.size == 1

      group = @numeric_ivar_groups[key]
      next unless group && !group.structural && !group.checked

      entry = entries.first
      bits = declared_arg_bits(entry.cls, entry.kind, entry.nilable)
      next if bits.zero?

      touchers = group.readers.map { |label| numeric_irep_owner[label]&.owner }
      next unless touchers.all? { |owner| declared_ivar_inherits?(owner, entry.owner) }

      @declared_ivar_seeds[key] = [entry, bits]
    end
    @declared_ivar_seeds
  end

  # Is +owner+ a class equal to or descending from +ancestor+ (through superclass links only)?
  def declared_ivar_inherits?(owner, ancestor)
    k = owner
    64.times do
      return false unless k.is_a?(String)
      return true if k == ancestor

      k = @superclass_of[k]
    end
    false
  end

  # The compiled methods a seeded slot's trust depends on, as failure messages: each method that stores to it must be
  # compiled in this run (or by another gem's run), without `#error`. +live+: the labels the run keeps (nil: all).
  def declared_ivar_writer_failures(compiled, only_owners, other_owners, live: nil)
    by_label = compiled.each_with_object({}) { |m, h| h[m[:label]] ||= m if m[:label] }
    declared_ivar_seeds.flat_map do |(_family, _name), (entry, _bits)|
      writers = @numeric_ivar_groups.fetch([numeric_family(entry.owner), entry.name]).sites.filter_map do |irep, _idx, _reg|
        numeric_irep_owner[irep.label]
      end.uniq
      writers.filter_map do |d|
        next if live && !live.include?(d.irep)

        where = "#{entry.key} is trusted as declared (DECLARED_IVAR_PROOF) because every store is checked, but"
        if only_owners && !only_owners.include?(d.owner)
          next if other_owners&.include?(d.owner)

          next "#{where} no compiled gem of this build compiles #{d.owner}##{d.name}, which stores to it"
        end
        m = by_label[d.irep]
        next "#{where} this run does not compile #{d.owner}##{d.name}, which stores to it" unless m
        next "#{where} #{d.owner}##{d.name}, which stores to it, does not compile (it would run interpreted and unchecked)" if m[:unsupported] || m[:code].include?('#error')
      end
    end
  end

  # One line per declared slot: guarded, and trusted (seeded) or not.
  def declared_ivar_report
    table = self.class.declared_ivars
    return [] if table.nil? || table.empty?

    seeded = declared_ivar_seeds.values.map { |entry, _| entry.key }.to_set
    table.values.sort_by(&:key).map do |e|
      "  DECLARED_IVAR #{e.key}: #{e.text}, #{seeded.include?(e.key) ? 'guarded stores, pool seeded' : 'guarded stores'}"
    end
  end
end
