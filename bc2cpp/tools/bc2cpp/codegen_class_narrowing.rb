# frozen_string_literal: true

require_relative 'numeric_flow'

# CLASS_NARROWING (ADR 0375): occurrence typing for the exact-class flow. A branch on the boolean of a class test
# (`x.is_a?(C)`, `kind_of?`, `instance_of?`, `C === x` and so `case x when C`, `x.nil?` and `!x` as a value,
# `x.respond_to?(:m)`, `x.class == C`) narrows the tested variable's class set on each edge, so the receivers
# dominated by the test see a smaller proven set. NumericFlow keeps the bookkeeping (which register holds which test, aimed at which variables, and
# when a rewrite or a call forgets it); this file decides what a test means in the closed world, and
# ClassNarrowingGuard checks the claim at run time.
#
# BC2CPP_CLASS_NARROWING=0 turns it all off.
class CodeGen
  # What a test says about a class set. +verdict(name)+ is whether an instance of exactly class +name+ passes:
  # true, false, or nil when the world does not say. NumericFlow calls #narrow on every edge.
  class ClassTest
    attr_reader :kind, :klass

    def initialize(codegen, kind, klass)
      @cg = codegen
      @kind = kind
      @klass = klass
      @partitions = {}
    end

    # The bits of +mask+ that survive the edge where the test is +truth+. Bits whose class is not named (OTHER,
    # EXC, CHECKED, object kinds, a class bit with no verdict) pass both edges, except that OTHER becomes the
    # exact instance set of a test that proves one (`positive`).
    def narrow(mask, truth)
      pass, fail = partition
      rest = mask & ~(pass | fail)
      kept = mask & (truth ? pass : fail)
      positive = truth && rest.anybits?(NumericFlow::OTHER) ? @cg.class_test_positive(self) : nil
      if positive
        rest &= ~NumericFlow::OTHER
        kept |= positive
      end
      kept | rest
    end

    private

    # [bits passing, bits failing], redone when a class bit is allocated.
    def partition
      @partitions[@cg.numeric_class_bit_count] ||= @cg.class_test_partition(self)
    end
  end

  CLASS_TEST_CORE_BITS = { NumericFlow::INT => 'Integer', NumericFlow::FLT => 'Float', NumericFlow::ARR => 'Array',
                           NumericFlow::HSH => 'Hash', NumericFlow::STR => 'String', NumericFlow::RNG => 'Range',
                           NumericFlow::NIL => 'NilClass' }.freeze
  # The mrb_state field holding each core class, for the run-time membership check.
  CLASS_TEST_CORE_FIELDS = { 'Integer' => 'integer_class', 'Float' => 'float_class', 'Array' => 'array_class',
                             'Hash' => 'hash_class', 'String' => 'string_class', 'Range' => 'range_class' }.freeze
  # Superclass chains of the core classes a bit stands for (Object and above are never the tested class).
  CLASS_TEST_CORE_CHAIN = { 'Integer' => %w[Integer Numeric], 'Float' => %w[Float Numeric], 'Array' => %w[Array],
                            'Hash' => %w[Hash], 'String' => %w[String], 'Range' => %w[Range],
                            'NilClass' => %w[NilClass] }.freeze
  # A core class a test can name, and the bits of its instances (when no subclass exists, see
  # compute_class_test_positive). Numeric has no instance of its own: it is the union of its subclasses.
  CLASS_TEST_CORE_POSITIVE = { 'Integer' => NumericFlow::INT, 'Float' => NumericFlow::FLT, 'Array' => NumericFlow::ARR,
                               'Hash' => NumericFlow::HSH, 'String' => NumericFlow::STR, 'Range' => NumericFlow::RNG,
                               'NilClass' => NumericFlow::NIL, 'Numeric' => NumericFlow::INT | NumericFlow::FLT }.freeze
  # Core classes with no bit: a test names them only to reject the classes that have one.
  CLASS_TEST_BITLESS_CORE = %w[Symbol TrueClass FalseClass Proc Exception StandardError].freeze
  # Stands for the class object `x.class` returns: not a test itself, the left side of `x.class == C`.
  CLASS_OF = Object.new.freeze
  # More than this many classes and the set stops being a useful proof (ADR 0352 stops at eight for a receiver).
  CLASS_TEST_MAX_CLASSES = 16
  # The classes mruby's own natives register each tested name on (kernel.c, object.c, class.c).
  CLASS_TEST_NATIVE_OWNERS = { 'is_a?' => %w[Kernel], 'kind_of?' => %w[Kernel], 'instance_of?' => %w[Kernel],
                               'nil?' => %w[Kernel NilClass], '!' => %w[BasicObject], 'raise' => %w[Kernel],
                               'respond_to?' => %w[Kernel], 'class' => %w[Kernel] }.freeze

  def class_narrowing_enabled?
    ENV['BC2CPP_CLASS_NARROWING'] != '0' && @native_results_ready && !@closed_world.nil? && !@native_name_sources.nil? &&
      @closed_world.global_refusal.nil? && @closed_world.exact_instances_singleton_free? && guard_violation_enabled?
  end

  def numeric_class_bit_count
    (@numeric_class_bits || {}).size
  end

  # [subject offset (0 = the receiver, 1 = the first argument), ClassTest] for the SEND at +index+, or nil.
  def class_test_for(irep, index, insn)
    return nil unless class_narrowing_enabled?

    @class_tests ||= {}
    key = [irep.label, index]
    return @class_tests[key] if @class_tests.key?(key)

    @class_tests[key] = compute_class_test(irep, index, insn)
  end

  def compute_class_test(irep, index, insn)
    name = insn.sym
    return nil if insn.n_spec == '*' || insn.nk_spec

    argc = insn.op == 'SEND0' ? 0 : insn.n_spec.to_i
    case name
    when 'is_a?', 'kind_of?', 'instance_of?'
      return nil unless argc == 1 && insn.op == 'SEND' && class_test_name_safe?(name)

      klass = class_test_constant(irep, index, insn.reg.to_i + 1)
      klass && [0, class_test_object(name == 'instance_of?' ? :instance_of : :kind_of, klass)]
    when '==='
      return nil unless argc == 1 && insn.op == 'SEND' && eqq_direct_safe?

      klass = class_test_constant(irep, index, insn.reg.to_i)
      klass && [1, class_test_object(:kind_of, klass)]
    when 'nil?'
      argc.zero? && class_test_name_safe?(name) ? [0, class_test_object(:nil, nil)] : nil
    when '!'
      argc.zero? && class_test_name_safe?(name) ? [0, class_test_object(:falsy, nil)] : nil
    when 'class'
      argc.zero? && insn.op == 'SEND0' && class_test_name_safe?(name) ? [0, CLASS_OF] : nil
    when 'respond_to?'
      return nil unless argc == 1 && insn.op == 'SEND' && class_test_name_safe?(name) && respond_to_missing_absent?

      meth = irep.walk_dominating_writers(index - 1, (insn.reg.to_i + 1).to_s, use: index, follow_moves: true) do |writer|
        writer.sym if writer.op == 'LOADSYM'
      end
      meth.is_a?(String) ? [0, class_test_object(:responds, meth)] : nil
    end
  end

  # `EQ` of a class-of register and a class constant (`x.class == C`) is the instance_of test, while `==` on class
  # objects is identity: no Ruby definition on Module, Class, Object, Kernel or any singleton, none installed by name,
  # and no module mixed into them (Comparable#== is mruby's own, which only the classes that include it see).
  def class_eq_test(irep, index, insn, marker)
    return nil unless marker.equal?(CLASS_OF) && class_narrowing_enabled? && class_object_eq_safe?

    klass = class_test_constant(irep, index, insn.paren_reg.to_i)
    klass && class_test_object(:instance_of, klass)
  end

  CLASS_OBJECT_OWNERS = %w[Module Class Object Kernel BasicObject].freeze

  def class_object_eq_safe?
    return @class_object_eq_safe if defined?(@class_object_eq_safe)

    @class_object_eq_safe = compute_class_object_eq_safe
  end

  def compute_class_object_eq_safe
    installed = symbol_installed_names
    return false if installed.nil? || installed.include?('==') || @closed_world.unknown_def?('==')
    return false unless CLASS_OBJECT_OWNERS.all? { |owner| @closed_world.core_native_arm_safe?('==', owner) }
    return false if @registry.fetch('==', []).any? { |d| d.owner.end_with?('.singleton') || CLASS_OBJECT_OWNERS.include?(d.owner) }

    mixed = CLASS_OBJECT_OWNERS.any? do |owner|
      !Array(@included_modules[owner]).empty? || !Array(@prepended_modules[owner]).empty? || @unknown_mixins.include?(owner)
    end
    return false if mixed

    registrations, opaque = NativeExpressionDevirt.class_registrations(@closed_world.native_paths_spelling('=='))
    unnamed = opaque.fetch('==', [])
    # BasicObject#== (mrb_obj_equal_m) is identity; every other registration is on a class whose instances are not
    # class objects.
    unnamed.none? { |owner| owner.nil? || CLASS_OBJECT_OWNERS.include?(owner) } &&
      registrations.fetch('==', []).none? do |entry|
        owner = entry[:owner]&.fetch(:class_name, nil)
        CLASS_OBJECT_OWNERS.include?(owner) && !(owner == 'BasicObject' && entry[:function] == 'mrb_obj_equal_m')
      end
  end

  # Where the flow recorded the test of the instruction at +index+ (a register, or nil for an ivar): the guard of
  # an EQ site reads it, since EQ has no receiver of its own.
  def note_class_test(irep, index, codes, slots, _pred)
    reg_code = codes.find { |code| code > slots }
    (@class_test_subjects ||= {})[[irep.label, index]] = reg_code && reg_code - slots - 1
  end

  def class_test_object(kind, klass)
    @class_test_objects ||= {}
    @class_test_objects[[kind, klass]] ||= ClassTest.new(self, kind, klass)
  end

  # Every definition `name` can reach is the audited core one: no Ruby definition, alias, undef or computed
  # install anywhere, only the registrations above, and (but for `!`, which BasicObject has) no BasicObject
  # subclass, whose `is_a?` would be a method_missing. The test then answers the class question and nothing else.
  def class_test_name_safe?(name)
    @class_test_name_safe ||= {}
    return @class_test_name_safe[name] if @class_test_name_safe.key?(name)

    world = block_core_world
    safe = !world.nil? && (name == '!' ? world.ownerless_native_dispatch_safe?(name) : world.kernel_native_dispatch_safe?(name))
    @class_test_name_safe[name] = safe && name_unrebound?(name) && class_test_native_owners?(name)
  end

  def class_test_native_owners?(name)
    paths = @closed_world.native_paths_spelling(name)
    return false if paths.empty?

    registrations, opaque = NativeExpressionDevirt.class_registrations(paths)
    entries = registrations.fetch(name, [])
    opaque.fetch(name, []).empty? && !entries.empty? &&
      entries.all? { |entry| CLASS_TEST_NATIVE_OWNERS.fetch(name).include?(entry[:owner]&.fetch(:class_name, nil)) }
  end

  # `raise` never returns: Kernel#raise (kernel.c mrb_f_raise) is the only definition, so the flow has no normal
  # successor after it and `raise X unless x.is_a?(C)` narrows x for the rest of the method.
  def class_narrowing_noreturn_call?(_irep, _index, insn)
    return false unless insn.sym == 'raise' && (insn.op == 'SSEND' || insn.op == 'SSEND0') && class_narrowing_enabled?

    @class_narrowing_raise = class_test_name_safe?('raise') unless defined?(@class_narrowing_raise)
    @class_narrowing_raise
  end

  # The class the constant in register +reg+ of the SEND at +index+ names, as a full class name: a core class
  # this file models, or a declared class whose constant identity is stable. A module or anything else is nil.
  def class_test_constant(irep, index, reg)
    name = irep.agreed_constant_name(index, reg.to_s)
    return nil unless name

    if CLASS_TEST_CORE_POSITIVE.key?(name) || CLASS_TEST_BITLESS_CORE.include?(name)
      return @closed_world.core_constant_plain?(name) ? name : nil
    end

    owner = constant_object_owner(irep, index, reg, numeric_owner_of(irep)&.owner)
    owner if owner && @closed_world.class_declared?(owner) && @closed_world.instance_class?(owner)
  end

  # Superclass chain (full names) of exactly class +name+, or nil when the world does not pin it down.
  def class_test_chain(name)
    return CLASS_TEST_CORE_CHAIN[name] if CLASS_TEST_CORE_CHAIN.key?(name)

    chain = []
    cur = name
    while cur.is_a?(String)
      return nil if chain.include?(cur) || chain.size > 64

      chain << cur
      parent = @closed_world.class_parent(cur)
      return nil if parent.nil?
      return chain if parent == :none

      cur = parent
    end
    nil
  end

  def class_test_verdict(test, name)
    case test.kind
    when :nil then name == 'NilClass'
    # `!x` holds for nil and false, the falsy classes (FalseClass's bit is 0 when immediate class bits are off).
    when :falsy then name == 'NilClass' || name == 'FalseClass'
    when :instance_of then name == test.klass
    when :responds then class_test_responds_verdict(name, test.klass)
    else class_test_chain(name)&.include?(test.klass)
    end
  end

  # `respond_to?(:meth)` is false for a class no definition of meth reaches, and the closed world never says it is
  # true (a private definition, or a name some installer defines, still answers false or true at run time).
  def class_test_responds_verdict(name, meth)
    answers = call_facts_answers
    judged = CLASS_TEST_CORE_CHAIN.key?(name) || (@closed_world.class_declared?(name) && answers.user_instance?(name))
    judged && !answers.answers?(name, meth) ? false : nil
  end

  # [passing bits, failing bits] over the bits that name a class today.
  def class_test_partition(test)
    pass = 0
    fail = 0
    named = CLASS_TEST_CORE_BITS.merge((@numeric_class_bits || {}).to_h { |klass, bit| [bit, klass] })
    named.each do |bit, name|
      verdict = class_test_verdict(test, name)
      if verdict then pass |= bit
      elsif verdict == false then fail |= bit
      end
    end
    [pass, fail]
  end

  # The bits of every instance that passes +test+, when they are all known, else nil (an unknown value that
  # passes stays unknown). Used to replace OTHER on the edge where the test holds.
  def class_test_positive(test)
    @class_test_positive ||= {}
    key = [test.kind, test.klass, numeric_class_bit_count]
    return @class_test_positive[key] if @class_test_positive.key?(key)

    @class_test_positive[key] = compute_class_test_positive(test)
  end

  def compute_class_test_positive(test)
    return NumericFlow::NIL if test.kind == :nil
    return nil if test.kind == :falsy
    return class_test_responds_positive(test.klass) if test.kind == :responds

    klass = test.klass
    if CLASS_TEST_CORE_POSITIVE.key?(klass)
      return nil if klass == 'Numeric' && test.kind == :instance_of

      # `instance_of?` is exact; `is_a?` also passes a subclass, so none may exist in Ruby or in a native source.
      return CLASS_TEST_CORE_POSITIVE[klass] if test.kind == :instance_of || core_class_subclass_free?(klass)

      return nil
    end
    return nil if CLASS_TEST_BITLESS_CORE.include?(klass)
    return numeric_class_bit(klass) if test.kind == :instance_of

    hierarchy = @closed_world.class_hierarchy(klass)
    return nil unless hierarchy && hierarchy[:wild].empty?

    classes = [klass] + hierarchy[:descendants].to_a
    return nil unless classes.size <= CLASS_TEST_MAX_CLASSES &&
                      classes.all? { |k| @closed_world.class_declared?(k) && @closed_world.instance_class?(k) }

    classes.reduce(0) { |mask, k| mask | numeric_class_bit(k) }
  end

  # The bits of every class that may answer `respond_to?(:meth)`, when each of them has one.
  def class_test_responds_positive(meth)
    answers = call_facts_answers
    members = answers.members(meth)
    return nil if members.nil? || members.size > CLASS_TEST_MAX_CLASSES

    members.reduce(0) do |mask, name|
      bit = CLASS_TEST_CORE_BITS.key(name)
      if bit
        return nil unless name == 'NilClass' || core_class_subclass_free?(name)

        mask | bit
      elsif @closed_world.class_declared?(name) && answers.user_instance?(name) && @closed_world.instance_class?(name)
        mask | numeric_class_bit(name)
      else
        return nil
      end
    end
  end

  CLASS_TEST_NUMERIC_FAMILY = %w[Numeric Integer Float].freeze

  # Every instance of +klass+ is exactly that class: the closed world declares no subclass (ClosedWorld#
  # native_subclass_free?) and no native source of the build creates one (mrb_define_class... with the class as
  # its superclass, which that scan does not read).
  def core_class_subclass_free?(klass)
    @core_class_subclass_free ||= {}
    return @core_class_subclass_free[klass] if @core_class_subclass_free.key?(klass)

    names = klass == 'Numeric' ? CLASS_TEST_NUMERIC_FAMILY : [klass]
    @core_class_subclass_free[klass] = @closed_world.native_subclass_free?(names) && names.none? { |name| native_subclass_defined?(name) }
  end

  CLASS_TEST_SUPER_FIELDS = { 'Integer' => 'integer_class', 'Float' => 'float_class', 'Array' => 'array_class',
                              'Hash' => 'hash_class', 'String' => 'string_class', 'Range' => 'range_class',
                              'Numeric' => 'numeric_class', 'NilClass' => 'nil_class' }.freeze

  # A native source creates a class whose superclass argument names +name+: `mrb_define_class*` or
  # `mrb_class_new` with the mrb_state field, `MRB_SYM(Name)` or the literal name as that argument.
  def native_subclass_defined?(name)
    field = CLASS_TEST_SUPER_FIELDS.fetch(name)
    token = /\b#{field}\b|MRB_SYM\(#{name}\)|"#{name}"/
    paths = @native_name_sources.values.flatten.uniq
    paths.any? do |path|
      text = SourceText.read(path, 'native_subclass_defined?') or next false
      text.scan(/\bmrb_(?:define_class\w*|class_new\w*)\s*\(([^;]*);/m).any? do |(call)|
        last = call.rpartition(',').last
        last.match?(token) || call.match?(/mrb_class_get\w*\s*\([^()]*#{token}/)
      end
    end
  end
end

# The run-time half of CLASS_NARROWING: where a test narrows its subject, the compiled code checks after the test
# that the subject's class is in the set the proof assumes on the edge it took, and raises a guard violation
# (ADR 0290) otherwise. A wrong closed-world fact then fails at the test, not as a call into the wrong body.
module ClassNarrowingGuard
  def compile_send(insn, **kwargs)
    code = super
    plan = class_narrowing_guard_plan(insn, kwargs) unless code.include?('#error')
    plan ? class_narrowing_guarded(code, insn, kwargs, plan) : code
  end

  # `x.class == C`: EQ has no receiver, so the subject is the register the flow recorded for the test.
  def compile_insn(insn, irep, owner_def, idx = nil, reg_offset = 0)
    code = super
    return code unless insn.op == 'EQ' && irep && idx && !code.include?('#error')

    plan = class_eq_guard_plan(irep, idx)
    plan ? class_eq_guarded(code, insn, reg_offset, plan) : code
  end

  # { claims: [[truth, expression, member?]...], offset:, name: } or nil. A claim says what the class of the subject
  # is on the edge the test took: a member of the narrowed set when that set names only classes, else (an unknown
  # part stays) not one of the classes the narrowing dropped.
  def class_narrowing_guard_plan(insn, kwargs)
    return nil unless class_narrowing_enabled? && (insn.op == 'SEND' || insn.op == 'SEND0')

    irep = kwargs[:irep]
    site = kwargs[:idx] || kwargs[:trace_idx]
    return nil unless irep && site

    original = irep.instructions[site]
    return nil unless original && original.op == insn.op && original.sym == insn.sym

    test = class_test_for(irep, site, original)
    return nil unless test && test[1].respond_to?(:narrow)
    # `nil?` and `!` are computed in the generated code (`mrb_nil_p`, `mrb_test`) from the very value they narrow: the
    # test is its own check.
    return nil if test[1].kind == :nil || test[1].kind == :falsy

    claims = class_narrowing_claims(test[1], exact_flow_mask(irep, site, original.reg.to_i + test[0]))
    claims.empty? ? nil : { claims: claims, offset: test[0], name: insn.sym }
  end

  def class_eq_guard_plan(irep, idx)
    return nil unless class_narrowing_enabled?

    # The flow records the subject when it reaches the instruction: make sure it has run.
    exact_flow_mask(irep, idx, irep.instructions[idx].reg)
    mask_reg = (@class_test_subjects || {})[[irep.label, idx]]
    return nil unless mask_reg

    test = class_eq_site_test(irep, idx)
    claims = test && class_narrowing_claims(test, exact_flow_mask(irep, idx, mask_reg))
    claims.nil? || claims.empty? ? nil : { claims: claims, reg: mask_reg }
  end

  # The instance_of test the EQ at +idx+ stands for, rebuilt from its constant operand.
  def class_eq_site_test(irep, idx)
    insn = irep.instructions[idx]
    klass = class_test_constant(irep, idx, insn.paren_reg.to_i)
    klass && class_test_object(:instance_of, klass)
  end

  def class_narrowing_claims(test, mask)
    return [] unless mask.is_a?(Integer) && mask.positive?

    [true, false].filter_map do |truth|
      narrowed = test.narrow(mask, truth)
      next if narrowed == mask

      member = class_narrowing_membership(narrowed, 'cn_subject')
      next [truth, member, true] if member

      dropped = class_narrowing_membership(mask & ~narrowed, 'cn_subject')
      [truth, dropped, false] if dropped
    end
  end

  # A C++ condition that is true when the class of +subject+ is one of the classes of +mask+, or nil when the mask
  # holds a bit that names no class the generated code can compare (OTHER, EXC, CHECKED, an object kind).
  def class_narrowing_membership(mask, subject)
    parts = []
    rest = mask
    CodeGen::CLASS_TEST_CORE_BITS.each do |bit, name|
      next unless mask.anybits?(bit)

      rest &= ~bit
      field = CodeGen::CLASS_TEST_CORE_FIELDS[name]
      parts << (field ? "mrb_obj_class(M, #{subject}) == M->#{field}" : "mrb_nil_p(#{subject})")
    end
    (@numeric_class_bits || {}).each do |klass, bit|
      next unless mask.anybits?(bit)
      return nil unless @closed_world.class_declared?(klass)

      rest &= ~bit
      parts << "#{owner_class_ptr_expr(klass)} == mrb_obj_class(M, #{subject})"
    end
    rest.zero? ? (parts.empty? ? 'false' : parts.join(' || ')) : nil
  end

  # The C++ that fails when a claim does not hold; +violation+ is the line raising it.
  def class_narrowing_arms(d, plan, violation)
    plan[:claims].map do |truth, expr, member|
      broken = member ? "!(#{expr})" : "(#{expr})"
      "  if (#{truth ? '' : '!'}mrb_test(r#{d}) && #{broken}) {\n    #{violation}  }\n"
    end.join
  end

  def class_narrowing_guarded(code, insn, kwargs, plan)
    d = insn.reg
    n = insn.op == 'SEND0' ? 0 : insn.n_spec.to_i
    recv = kwargs[:call_receiver] || "r#{d}"
    argv = kwargs[:call_arguments] || (1..n).map { |k| "r#{d.to_i + k}" }
    subject = plan[:offset].zero? ? recv : argv.fetch(0)
    violation = guard_violation_line(d, 'cn_recv', plan[:name], argv, 'CLASS_NARROWING')
    "  // CLASS_NARROWING_GUARD :#{plan[:name]} -- the proof narrows the subject on each edge; check it ran as assumed\n" \
      "  {\n  mrb_value cn_recv = #{recv};\n  mrb_value cn_subject = #{subject};\n#{code}#{class_narrowing_arms(d, plan, violation)}  }\n"
  end

  def class_eq_guarded(code, insn, reg_offset, plan)
    d = insn.reg
    # The answer a dispatch of the violated site would give: `subject.class == C`.
    violation = "r#{d} = mrb_bool_value(mrb_equal(M, bc2cpp_guard_violation_named(M, cn_subject, \"class\", " \
                "\"@@SITE@@ (CLASS_NARROWING)\", 0), cn_operand)); #{NomethodReviewed.violation_marker('class')}\n"
    "  // CLASS_NARROWING_GUARD :== -- the proof narrows the subject on each edge; check it ran as assumed\n" \
      "  {\n  mrb_value cn_subject = r#{plan[:reg] + reg_offset};\n  mrb_value cn_operand = r#{insn.paren_reg};\n" \
      "#{code}#{class_narrowing_arms(d, plan, violation)}  }\n"
  end
end

CodeGen.prepend(ClassNarrowingGuard)
