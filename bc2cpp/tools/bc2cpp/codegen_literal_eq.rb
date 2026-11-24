# frozen_string_literal: true

require_relative 'numeric_flow'

# LITERAL_EQ_IDENTITY: `x == lit` (OP_EQ) for a literal Symbol, nil, true or false is the identity test of the two
# words. OP_EQ answers identity first; past it, the answer is x's `==` with the literal as argument, and
# literal_eq_identity_safe? proves that every `==` the world can reach answers false then. `lit == x` with an
# immediate literal on the left is Symbol#==, nil's, true's or false's, all identity. For a Fixnum literal N the
# only other `==` that can answer true is Float#== (Integer#== of a heap Integer or a bigint never equals a Fixnum),
# so a Fixnum x is the word test, a Float x the compare with N (bc2cpp_eq_lit_num), and anything else false; when the
# flow proves x no Float, the word test alone. BC2CPP_LITERAL_EQ_IDENTITY=0 keeps the full compare.
class CodeGen
  # The native `==` bodies that answer false for an argument that is not identical and is a Symbol, nil, true, false
  # or a Fixnum the receiver does not equal (src/*.c of the pinned mruby): each tests the argument's type or class
  # first, or is identity. Integer#== and Float#== answer true for an equal Integer, which the Fixnum case rules out
  # for Integer by identity and for Float by the operand proof.
  LITERAL_EQ_FALSE_BODIES = %w[
    mrb_obj_equal_m mrb_str_equal_m mrb_int_equal_m mrb_flo_equal_m mrb_ary_eq_m mrb_hash_equal_m range_eq proc_eql
    mrb_struct_equal time_eq method_eql set_equal fiber_eq
  ].freeze
  # The classes whose native `==` the registration scan cannot name, read by hand: Rect, Color and Tone
  # (mruby-rgss/src/lib.cxx *_eq_native_body), OnigRegexp (onig_regexp_equal), Fiber (fiber_eq, until its ROM table
  # names it) and Data (mrb_data_equal) each answer false unless the argument is of the receiver's class or identical.
  LITERAL_EQ_OPAQUE_OWNERS = %w[Rect Color Tone OnigRegexp Fiber Data].freeze
  # The core classes that include Comparable, whose Comparable#== (mrblib/compar.rb, `(self <=> other).equal?(0)`)
  # their instances reach only through Numeric, the one without a native `==` of its own; a Numeric's `<=>` is the
  # native Kernel#<=> (no program `<=>` or `equal?`), which answers 0 only for an identical argument.
  LITERAL_EQ_COMPARABLE_CORE = %w[String Symbol Numeric Integer Float Time Comparable].freeze

  def literal_eq_identity_on?
    ENV['BC2CPP_LITERAL_EQ_IDENTITY'] != '0'
  end

  # The C text of the compare at +idx+, or nil to keep compile_cmp's chain.
  def literal_eq_identity(irep, idx, d, s, owner_def, reg_offset)
    return nil unless literal_eq_identity_on? && irep && idx && literal_eq_identity_safe?

    left = exact_literal(irep, idx, unshift_proof_reg(d, reg_offset))
    right = exact_literal(irep, idx, unshift_proof_reg(s, reg_offset))
    kind = if right && LITERAL_EQ_IMMEDIATE.include?(right.klass)
             right.klass
           elsif left && LITERAL_EQ_IMMEDIATE.include?(left.klass)
             left.klass
           elsif right&.klass == :Integer && literal_eq_fixnum?(right.value)
             literal_eq_not_float?(irep, idx, unshift_proof_reg(d, reg_offset), owner_def) ? :Integer : :Numeric
           end
    return nil unless kind

    note = "  // LITERAL_EQ_IDENTITY #{kind} -- every == the world reaches answers identity for this literal\n"
    return "#{note}  r#{d} = mrb_bool_value(BC2CPP_SAME_WORD(r#{d}, r#{s}));\n" unless kind == :Numeric

    "#{note}  r#{d} = mrb_fixnum_p(r#{d}) ? mrb_bool_value(BC2CPP_SAME_WORD(r#{d}, r#{s})) : bc2cpp_eq_lit_num(r#{d}, r#{s});\n"
  end

  LITERAL_EQ_IMMEDIATE = %i[Symbol NilClass TrueClass FalseClass].freeze

  # A Fixnum on every target: 31-bit word boxing.
  def literal_eq_fixnum?(value)
    value.is_a?(Integer) && value.between?(-0x3fff_ffff, 0x3fff_ffff)
  end

  # The flow's class set of +reg+ is known and holds no Float: OTHER is any value the flow does not name, a Float
  # among them, and CHECKED a pool only a runtime check backs.
  def literal_eq_not_float?(irep, idx, reg, owner_def)
    mask = numeric_raw_mask(irep, idx, reg, owner_def)
    mask.is_a?(Integer) && mask.positive? && mask.nobits?(NumericFlow::FLT | NumericFlow::OTHER | NumericFlow::CHECKED)
  end

  # No Ruby `==`, `===`, `<=>` or `equal?` in the program, no install of `==`, every native `==` is one of
  # LITERAL_EQ_FALSE_BODIES, and outside Ruby defines `==` only on Comparable, which no program class reaches.
  def literal_eq_identity_safe?
    return @literal_eq_identity_safe if defined?(@literal_eq_identity_safe)

    @literal_eq_identity_safe = literal_eq_identity_refusal.nil?
  end

  # Why the world does not prove literal_eq_identity_safe?, or nil.
  def literal_eq_identity_refusal
    return :eq_defs unless eqq_literal_devirt_safe?
    return :cmp_rebound unless eqq_name_unrebound?('<=>')
    return :cmp_defs unless %w[<=> equal?].all? { |name| (@registry[name] || []).all? { |d| d.owner == '<native>' } }
    return :unknown_mixins unless @unknown_mixins.empty?
    return nil unless @closed_world
    return :unknown_def if @closed_world.unknown_def?('==') || @closed_world.unknown_def?('<=>')

    registrations, opaque = NativeExpressionDevirt.class_registrations(@closed_world.native_paths_spelling('=='))
    unread = opaque.fetch('==', []).reject { |owner| LITERAL_EQ_OPAQUE_OWNERS.include?(owner) }
    return "opaque native #{unread.join(',')}" unless unread.empty?

    bodies = registrations.fetch('==', []).map { |entry| entry[:function] }
    unaudited = bodies.reject { |function| LITERAL_EQ_FALSE_BODIES.include?(function) }
    return "native #{unaudited.uniq.join(',')}" unless unaudited.empty?

    paths = @closed_world.outside_ruby_definer_paths('==')
    unless paths.empty?
      definers = ForeignDefiners.scan(paths)
      return :outside_wild unless definers.wild.empty?

      others = definers.names.select { |owner, names| owner != 'Comparable' && names.include?('==') }.keys
      return "outside #{others.join(',')}" unless others.empty?
    end
    literal_eq_comparable_unreached? ? nil : :comparable
  end

  # No class but the audited core ones has Comparable among its lookup owners.
  def literal_eq_comparable_unreached?
    owners = (@superclass_of.keys + @included_modules.keys + @prepended_modules.keys).uniq
    owners.all? do |owner|
      LITERAL_EQ_COMPARABLE_CORE.include?(owner) || !method_resolution_owners([owner]).include?('Comparable')
    end
  end
end
