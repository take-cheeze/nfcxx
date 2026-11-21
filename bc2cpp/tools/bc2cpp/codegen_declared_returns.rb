# frozen_string_literal: true

require_relative 'bytecode_ir'
require_relative 'bytecode_ir_containers'

require_relative 'numeric_flow'
require_relative 'declared_constants'
require_relative 'declared_returns'
require_relative 'codegen_sealed_containers'
require_relative 'codegen_declared_ivars'
require_relative 'codegen_declared_elements'

# CodeGen: DECLARED_RETURN_CHECK and DECLARED_RETURN_GUARD.
#
# A declared return (`Integer`, `Array`, `C`, `C?`) is a fact: compute_*_return_names seed it (declared_return_facts)
# and no body is proven against it. So the declaring body is wrapped (declared_return_guard_wrap): every value it
# returns passes one check of the declared kind, and a mismatch raises BC2cppDeclarationViolation naming the method
# and the type. A plain declaration the return proofs already prove (declared_return_proven?) gets no check, and
# BC2CPP_DECLARATION_GUARD=0 drops the plain ones; a %a{bc2cpp:hint} one is always checked. A declared parameter class
# is checked on entry the same way (DECLARED_PARAM_GUARD).
#
# The facts keep the closed-world preconditions in declared_return_refusal (no alias, define_method or undef of the
# name, no outside definition, every definition declared alike). bc2cpp.rb aborts a run that trusted a guarded
# declaration without compiling its guard (DeclaredReturns.guard_failures).
class CodeGen
  class << self
    # [DeclaredReturns::Entry] for this build (nil: none), and the root diagnostics are relative to.
    # declared_return_hint_refusals: DeclaredReturns.hint_refusals, the hinted declarations no body can carry.
    attr_accessor :declared_returns, :declared_return_root, :declared_return_hint_refusals
    # label => [[position, class, key, text], ...]: the declared parameter classes the bodies trust (DECLARED_PARAM_GUARD).
    attr_accessor :declared_params
    # label => [[name, class, key, text, kind, nilable], ...]: RbsParamCheck.keyword_guards (DECLARED_KEYWORD_PARAM).
    attr_accessor :declared_keywords
  end

  # The checked declarations: statically checked ones and the runtime-checked %a{bc2cpp:hint} ones.
  def declared_return_entries
    @declared_return_entries ||= (self.class.declared_returns || []).select { |e| @ireps[e.label] }
  end

  # The declarations that need their compiled check (DECLARED_RETURN_GUARD): every %a{bc2cpp:hint} one, and every plain
  # one that adds a fact and whose body the return proofs do not already prove (BC2CPP_DECLARATION_GUARD=0 leaves the
  # plain ones unchecked). A declaration whose name admits no name-wide fact (refused as info) is still read per
  # definition (DECLARED_DEF_RETURN), so it is checked the same way when that reading can use it
  # (declared_def_return_checkable?); otherwise nothing relies on it, and its body keeps no check. An error refusal
  # still keeps the hinted one's.
  def declared_return_hints
    return @declared_return_hints if @declared_return_hints

    list = declared_return_entries.select do |e|
      refusal = declared_return_refusal(e.name)
      if refusal&.first == 'info'
        declared_def_return_checkable?(e) && (e.hint || (DeclaredReturns.guard? && !declared_return_proven_exact?(e)))
      else
        e.hint || (DeclaredReturns.guard? && refusal.nil? && !declared_return_proven_exact?(e))
      end
    end
    @declared_return_hints = list if @declared_returns_final # earlier probes run before the return sets are final
    list
  end

  # A plain declaration whose every return path the return proofs already prove, given the other declared names (each
  # guarded or proven the same way), so the declaration adds nothing to check. Only once the sets are final.
  def declared_return_proven?(entry)
    return false unless @declared_returns_final

    d = @owner_of[entry.label]
    irep = d && @ireps[d.irep]
    return false unless irep

    case entry.kind
    when :fixnum then !entry.nilable && fixnum_return_analyzable?(irep) && fixnum_return_sites_proven?(d)
    when :array then !entry.nilable && fixnum_return_analyzable?(irep) && array_return_sites_proven?(d)
    when :class
      # The class proof tolerates nil paths, so it proves `C?` only.
      proof = ->(n, owner) { (@class_return_names || {})[n] if self_call_reaches_def?(n, owner) }
      entry.nilable && class_return_analyzable?(irep) && class_return_sites_proven(d, proof) == entry.cls
    else false
    end
  end

  # declared_return_proven? strong enough for the exact-class flow. ARRAY_RETURN_PROOF may rest on a ClassLayout hint
  # (its consumers keep an mrb_array_p tripwire), so an Array declaration it proves still needs its guard.
  def declared_return_proven_exact?(entry)
    !DECLARED_CORE_KIND_CLASS.key?(entry.kind) && declared_return_proven?(entry)
  end

  # The runtime-checked declaration of the body `label` compiles, or nil.
  def declared_return_guard(label)
    @declared_return_guards ||= declared_return_hints.to_h { |e| [e.label, e] }
    @declared_return_guards[label]
  end

  # name -> [entries] of the definitions declared with `kind`.
  def declared_return_by_name
    @declared_return_by_name ||= declared_return_entries.group_by(&:name)
  end

  # Why +name+ carries no fact: [severity, reason], or nil when it may. An error is a precondition that makes the
  # declaration itself untrustworthy (another body can be installed under the name at run time); an info is one the
  # proofs keep and that still lets each definition be checked.
  def declared_return_refusal(name)
    @declared_return_refusals ||= {}
    return @declared_return_refusals[name] if @declared_return_refusals.key?(name)

    @declared_return_refusals[name] = compute_declared_return_refusal(name)
  end

  def compute_declared_return_refusal(name)
    installed = symbol_installed_names
    return ['error', 'the program installs or renames methods with computed names'] if installed.nil?
    if installed.include?(name) || numeric_aliased_names.include?(name)
      return ['error', "`#{name}` is aliased, defined with define_method or undefined at run time"]
    end
    return ['info', "outside Ruby or native code also defines `#{name}`"] if @foreign_method_names.include?(name)

    defs = return_table_definitions(name) # ADR 0333: a registry placeholder the closed world rules out is no body
    entries = declared_return_by_name[name] || []
    # DECLARED_RETURN_GUARD: a core body is compiled without the closed world and may run interpreted (CORE_BLOCK
    # guards), so no guard can be relied on there.
    core = entries.select { |e| e.hint || DeclaredReturns.guard? }.filter_map { |e| @owner_of[e.label] }.select(&:core)
    unless core.empty?
      return ['error', "#{core.map(&:owner).sort.join(', ')}##{name} is a core method, which a run-time check " \
                       'in its compiled body cannot cover (it may run interpreted)']
    end
    unless defs.all? { |d| d.irep && @ireps[d.irep] }
      return ['info', "`#{name}` also has a native or accessor definition"]
    end

    undeclared = defs.reject { |d| entries.any? { |e| e.owner == d.owner && e.label == d.irep } }
    unless undeclared.empty?
      missing = undeclared.map(&:owner).sort.join(', ')
      return ['info', "POLY `#{name}`: #{missing} not declared (checked per definition)"]
    end
    if entries.map { |e| [e.kind, e.cls, e.nilable] }.uniq.size > 1
      return ['info', "POLY `#{name}`: the definitions declare different types (checked per definition)"]
    end
    # The refusal is memoized program-wide, and the first call can come from a core body's compile, which hides
    # @closed_world (compile_method); name visibility is a whole-program fact, so read that body's program world.
    world = @closed_world || @core_program_world
    if defs.size > 1 && !world&.name_fully_visible?(name)
      return ['info', "POLY `#{name}` is not fully visible to the closed world (checked per definition)"]
    end

    # FIXNUM_RETURN_PROOF's own precondition: it refuses any name a program spells as a literal.
    if entries.first.kind == :fixnum && numeric_dynamically_named?(name)
      return ['info', "`#{name}` is spelled as a literal name, which FIXNUM_RETURN_PROOF refuses"]
    end

    nil
  end

  # The facts the declarations add: :fixnum and :array a Set of names, :class a name -> class Hash.
  def declared_return_facts(kind)
    @declared_return_facts ||= {}
    @declared_return_facts[kind] ||= begin
      admitted = declared_return_by_name.select do |name, entries|
        entries.first.kind == kind && declared_return_refusal(name).nil? && !(kind == :fixnum && entries.first.nilable)
      end
      kind == :class ? admitted.transform_values { |entries| entries.first.cls } : admitted.keys.to_set
    end
  end

  # EXACT_DECLARED_RETURN: the exact-class flow's mask of a call of +name+ whose declaration is checked at run time, or
  # nil. The guard raises on a mismatch, so a value that comes back IS what the declaration says: `-> Foo` is exactly
  # Foo (the guard is the exact class test), `-> Float` a Float, `-> Integer` a Fixnum, `-> Symbol`, `bool`, `nil` the
  # immediate classes (their bits exist only under immediate_class_bits_enabled?), `-> Array`, `-> Hash`, `-> String`
  # the core class (declared_kind_mask). Applied only when every definition of
  # the name is declared alike (declared_return_refusal), each one's guard is emitted (declared_return_guard) or its
  # body is proven (declared_return_proven?), and the class is a program class nothing derives from, as RBS_CHECKED_PARAMS
  # trusts one (the `subclassed` rule of rbs_param_check.rb). Otherwise the declaration stays the ceiling it was.
  # BC2CPP_EXACT_DECLARED_RETURNS=0 turns it off.
  def declared_exact_return_mask(name)
    return nil unless @declared_returns_final && ENV['BC2CPP_EXACT_DECLARED_RETURNS'] != '0'

    @declared_exact_return ||= {}
    @declared_exact_return[name] = declared_exact_return_spec(name) unless @declared_exact_return.key?(name)
    spec = @declared_exact_return[name]
    return nil unless spec

    declared_kind_mask(*spec)
  end

  # The core class a container or String declaration's guard tests the kind of (mrb_array_p, mrb_hash_p, mrb_string_p).
  DECLARED_CORE_KIND_CLASS = { array: 'Array', array_of: 'Array', hash: 'Hash', hash_of: 'Hash', string: 'String' }.freeze

  # The exact-class mask a checked declaration of [kind, cls, nilable] gives its call's result, or nil. A container or
  # String guard admits a subclass instance, so it is the exact core class only while the build has no subclass of
  # it (core_class_subclass_free?); the flow already requires singleton-free instances (compute_return_classes).
  def declared_kind_mask(kind, cls, nilable)
    bit = case kind
          when :fixnum then NumericFlow::INT
          when :float then NumericFlow::FLT
          when :nil then NumericFlow::NIL
          when :symbol then immediate_class_bits_enabled? ? numeric_class_bit('Symbol') : nil
          when :class then RETURN_CORE_CLASS.key(cls) || numeric_class_bit(cls)
          when *DECLARED_CORE_KIND_CLASS.keys
            core = DECLARED_CORE_KIND_CLASS.fetch(kind)
            RETURN_CORE_CLASS.key(core) if block_core_world && @native_name_sources && core_class_subclass_free?(core)
          end
    bit && (nilable ? bit | NumericFlow::NIL : bit)
  end

  # DECLARED_DEF_RETURN: the exact-class mask of a call already resolved to the one definition +definition+
  # (return_class_scoped_send_mask: the receiver's exact class and its closed-world lookup), read from that
  # definition's own declaration, or nil. No other definition can answer the call, so the name-wide agreement of
  # declared_exact_return_mask is not needed. The declaration must still be checked where it is defined: its guard is
  # compiled into that body (declared_return_guard; bc2cpp.rb aborts a run that leaves it out) or the return proofs
  # prove it. An error refusal (another body can be installed under the name at run time) keeps it out.
  # BC2CPP_DECLARED_DEF_RETURNS=0 turns it off.
  def declared_def_return_mask(definition)
    return nil unless @declared_returns_final && definition&.irep && declared_def_returns_enabled?

    entry = declared_return_entry_at(definition.irep)
    return nil unless entry && entry.owner == definition.owner && declared_def_return_spec?(entry)
    return nil if declared_return_refusal(entry.name)&.first == 'error'
    return nil unless declared_return_guard(entry.label) || declared_return_proven_exact?(entry)

    declared_kind_mask(entry.kind, entry.cls, entry.nilable)
  end

  def declared_def_returns_enabled?
    ENV['BC2CPP_DECLARED_DEF_RETURNS'] != '0'
  end

  def declared_return_entry_at(label)
    (@declared_return_at ||= declared_return_entries.to_h { |e| [e.label, e] })[label]
  end

  # The kinds DECLARED_DEF_RETURN reads, with declared_exact_return_spec's limits: a nilable immediate is left out, and
  # a class must be an instance class nothing in the program derives from (an exact class test admits no subclass).
  def declared_def_return_spec?(entry)
    case entry.kind
    when :fixnum, :float, :symbol, :nil then !entry.nilable
    when :class
      klass = entry.cls
      # A core body's compile hides @closed_world (compile_method); the class graph is the program's, as for the refusal.
      world = @closed_world || @core_program_world
      !RETURN_BITLESS_CLASSES.include?(klass) && world &&
        (world.instance_class?(klass) || NATIVE_WRAPPER_CLASS_ACCESSORS.key?(klass)) &&
        !(@declared_subclassed ||= @superclass_of.values.grep(String).to_set).include?(klass)
    else DECLARED_CORE_KIND_CLASS.key?(entry.kind)
    end
  end

  # An info-refused declaration DECLARED_DEF_RETURN can read (a kind it reads). Its guard is then held to the contract
  # of every other one (DeclaredReturns.guard_failures: the body some gem of the build compiles carries it). The
  # choice is the whole program's, never one gem's: it is made before SHARED_GENERATION forks the units.
  def declared_def_return_checkable?(entry)
    declared_def_returns_enabled? && declared_def_return_spec?(entry)
  end

  # [kind, class, nilable] when +name+ may be read as an exact result (declared_exact_return_mask), or nil.
  def declared_exact_return_spec(name)
    entries = declared_return_by_name[name]
    return nil if entries.nil? || entries.empty? || declared_return_refusal(name)

    guarded = entries.all? { |e| @ireps[e.label] && @owner_of[e.label] && (declared_return_guard(e.label) || declared_return_proven_exact?(e)) }
    return nil unless guarded

    entry = entries.first
    spec = [entry.kind, entry.cls, entry.nilable]
    return nil unless entries.all? { |e| [e.kind, e.cls, e.nilable] == spec }

    case entry.kind
    when :fixnum, :float then entry.nilable ? nil : spec
    when :symbol, :nil then entry.nilable ? nil : spec
    when *DECLARED_CORE_KIND_CLASS.keys then spec
    when :class
      klass = entry.cls
      return nil if RETURN_BITLESS_CLASSES.include?(klass) || !instance_class?(klass)
      return nil if (@declared_subclassed ||= @superclass_of.values.grep(String).to_set).include?(klass)
      return nil unless native_table_name_visible?(name, klass)

      spec
    end
  end

  # Runs once the return fixpoints are final. Diagnostics are hashes in RbsSignatures::Diag's shape.
  def check_declared_returns
    @declared_return_diagnostics = []
    @declared_return_report = []
    # The return sets are final here: the guard list (declared_return_hints) is decided from now on.
    @declared_returns_final = true
    @declared_return_hints = nil
    @declared_return_guards = nil
    @declared_exact_return = nil
    # The proofs run on the closed world's outside-source scan, a required bc2cpp input.
    if @foreign_method_names.nil? && !declared_return_entries.empty?
      raise 'DECLARED_RETURN_CHECK: no outside-source scan; bc2cpp compiles closed-world programs only (ADR 0466)'
    end
    # A hinted declaration no compiled body can carry: an error, never an unchecked hint.
    (self.class.declared_return_hint_refusals || []).each do |r|
      @declared_return_diagnostics << declared_return_diag(r[:loc].file, r[:loc].line, r[:loc].col, 'error',
                                                           "#{r[:key]} -> #{r[:text]}: %a{bc2cpp:hint} cannot be " \
                                                           "checked at run time: #{r[:why]}")
      @declared_return_report << "  DECLARED_RET #{r[:key]} -> #{r[:text]}: FAILED (runtime check refused)"
    end
    declared_return_entries.each do |entry|
      refusal = declared_return_refusal(entry.name)
      guarded = declared_return_guard(entry.label)
      if refusal
        fact = guarded ? 'no name-wide return fact (checked in its body)' : 'no return fact'
        message = refusal.first == 'error' ? "cannot be checked: #{refusal.last}" : "#{refusal.last}; #{fact}"
        loc = entry.loc
        @declared_return_diagnostics << declared_return_diag(loc.file, loc.line, loc.col, refusal.first,
                                                             "#{entry.key} -> #{entry.text}: #{message}")
      end
      how = if entry.hint then 'runtime-checked (%a{bc2cpp:hint})'
            elsif refusal then guarded ? 'runtime-checked per definition' : 'declared'
            elsif !guarded && declared_return_proven?(entry) then 'proven'
            elsif DeclaredReturns.guard? then 'runtime-checked'
            else 'trusted'
            end
      status = if refusal.nil? then "#{how}, fact #{entry.kind}"
               elsif refusal.first == 'info' then "#{how}, no fact"
               else 'FAILED'
               end
      @declared_return_report << "  DECLARED_RET #{entry.key} -> #{entry.text}: #{status}"
    end
    check_block_returns
    @declared_return_diagnostics
  end

  def declared_return_diagnostics
    @declared_return_diagnostics || []
  end

  def declared_return_report
    @declared_return_report || []
  end

  def declared_return_diag(file, line, col, severity, message)
    { file: file, line: line, col: col, severity: severity, code: DeclaredReturns::CODE, message: message }
  end

  def declared_return_relative(path)
    root = self.class.declared_return_root
    root ? path.to_s.sub(%r{\A#{Regexp.escape(root)}/?}, '') : path.to_s
  end

  def declared_array_plus_safe?
    return @declared_array_plus_safe if defined?(@declared_array_plus_safe)

    @declared_array_plus_safe = DeclaredConstants.array_plus_safe?(@registry, @superclass_of, @prepended_modules,
                                                                   @unknown_mixins)
  end

  # DeclaredConstants.range_to_a_safe? (the predicate lives there so the declared check can read it too).
  def range_to_a_safe?
    return @range_to_a_safe if defined?(@range_to_a_safe)

    @range_to_a_safe = DeclaredConstants.range_to_a_safe?(@registry, @included_modules, @prepended_modules,
                                                          @unknown_mixins)
  end

  # The C++ test that `var` has the declared kind (see declared_return_guard_statement). A :union is the members' tests
  # joined by `||`: one linear test per member (UNION_LINEAR, DeclaredReturns.kind_of).
  def declared_return_condition(kind, cls, nilable, var)
    base =
      case kind
      when :fixnum then "mrb_fixnum_p(#{var})"
      when :array then "mrb_array_p(#{var})"
      when :string then "mrb_string_p(#{var})"
      when :nil then "mrb_nil_p(#{var})"
      when :hash then "mrb_hash_p(#{var})"
      when :symbol then "mrb_symbol_p(#{var})"
      when :float then "mrb_float_p(#{var})"
      when :module then "mrb_obj_is_kind_of(M, #{var}, mrb_module_get(M, \"#{cls}\"))"
      when :union then return cls.map { |k, c, n| "(#{declared_return_condition(k, c, n, var)})" }.join(' || ')
      when :bool then "(mrb_true_p(#{var}) || mrb_false_p(#{var}))"
      when :hash_of
        # Every key and value is tested with its element kind; mrb_hash_foreach stops at the first failure.
        # The callback is capture-less (a C function pointer), so the result comes back through p_.
        kk, vk = cls
        key = declared_return_condition(kk[0], kk[1], kk[2], 'k_')
        val = declared_return_condition(vk[0], vk[1], vk[2], 'v_')
        "(mrb_hash_p(#{var}) && ([&]() { bool ok_ = true; mrb_hash_foreach(M, RHASH(#{var}), " \
          "[](mrb_state* M_, mrb_value k_, mrb_value v_, void* p_) -> int { (void)M_; " \
          "if (!((#{key}) && (#{val}))) { *static_cast<bool*>(p_) = false; return 1; } return 0; }, &ok_); " \
          "return ok_; }()))"
      when :array_of
        # Every element is tested with the element kind; the loop runs in the expression, with M in scope.
        ek, ec, en = cls
        elem = declared_return_condition(ek, ec, en, 'e_')
        "(mrb_array_p(#{var}) && ([&]() { mrb_value a_ = #{var}; mrb_int n_ = RARRAY_LEN(a_); " \
          "for (mrb_int i_ = 0; i_ < n_; ++i_) { mrb_value e_ = mrb_ary_ref(M, a_, i_); if (!(#{elem})) return false; } " \
          "return true; }()))"
      when :class
        exact = exact_class_guard(owner_class_ptr_expr(cls), var)
        return nilable ? "mrb_nil_p(#{var}) || #{exact}" : exact
      else raise "DECLARED_RETURN_GUARD: no runtime check for kind #{kind.inspect}"
      end
    # A nilable simple kind admits nil before its test (`Integer?`).
    nilable ? "mrb_nil_p(#{var}) || (#{base})" : base
  end

  # DECLARED_RETURN_GUARD: the C++ statement that checks `var` against the runtime-checked declaration `entry` and
  # raises on a mismatch. The kinds test exactly what their facts let a consumer assume: a Fixnum (an unchecked
  # mrb_fixnum is allowed on a FIXNUM_RETURN_PROOF result, so Integer is not enough), an Array (mrb_array_p, the
  # ARRAY_RETURN_PROOF tripwire's own test), an instance of exactly C (the class return fixpoint's exact class, by
  # the class-equality test the receiver guards use) or, for `C?`, nil.
  def declared_return_guard_statement(entry, var)
    cond = declared_return_condition(entry.kind, entry.cls, entry.nilable, var)
    quote = ->(text) { text.gsub(/["\\]/) { |c| "\\#{c}" } }
    "  if (mrb_unlikely(!(#{cond}))) bc2cpp_declared_return_violation(M, #{var}, \"#{quote.call(entry.key)}\", " \
      "\"#{quote.call(entry.text)}\"); #{DeclaredReturns.guard_marker(entry)}\n"
  end

  # DECLARED_PARAM_GUARD: the C++ statements that check the declared class of each trusted parameter of `label`, given
  # the impl's parameter names (M, self, then the positionals), or "" when it has none.
  def declared_param_guard_statements(label, names, types = [])
    declared_param_guards(label).filter_map do |pos, cls, key, text, kind = :class, nilable = false, optional = nil|
      var = names[2 + pos]
      next unless var
      # An unboxed specialization (`mrb_int id`, `mrb_float f`) already carries the kind: its callers box-check it.
      next unless (types[2 + pos] || 'mrb_value') == 'mrb_value'

      # VALUE_KIND: a Float, Integer (fixnum) or Symbol parameter tests the value's kind (the same tests a declared
      # return uses); a program class tests its exact class. `T?` also admits nil.
      cond = case kind
             when :float then declared_return_condition(:float, cls, false, var)
             when :integer then declared_return_condition(:fixnum, cls, false, var)
             when :symbol then declared_return_condition(:symbol, cls, false, var)
             when :array, :hash, :string then declared_return_condition(kind, cls, false, var)
             else exact_class_guard(owner_class_ptr_expr(cls), var)
             end
      cond = "mrb_nil_p(#{var}) || (#{cond})" if nilable
      # DECLARED_OPTIONAL_PARAM: an omitted optional holds its default (RbsParamCheck.optional_defaults), not a value.
      if optional
        raise "DECLARED_PARAM_GUARD: #{key} arg #{pos + 1}: no bc2cpp_given_opt in #{names.join(', ')}" unless names.include?('bc2cpp_given_opt')

        cond = "bc2cpp_given_opt <= #{optional} || (#{cond})"
      end
      "  if (mrb_unlikely(!(#{cond}))) bc2cpp_declared_param_violation(M, #{var}, \"#{key}\", #{pos + 1}, \"#{text}\"); " \
        "/* DECLARED_PARAM_GUARD #{key} arg #{pos + 1} */\n"
    end.join
  end

  # The declared parameter guards of `label` this build keeps: a core container or String kind only where its kind test
  # is its exact class (declared_core_kind_kept?, as for an ivar declaration).
  def declared_param_guards(label)
    (self.class.declared_params&.[](label) || []).select do |_pos, cls, _key, _text, kind = :class, *|
      !RbsParamCheck::CORE_IVAR_KINDS.key?(kind) || declared_core_kind_kept?(cls)
    end
  end

  # DECLARED_KEYWORD_PARAM: the keyword guards of `label` this build keeps (as declared_param_guards), by name.
  def declared_keyword_guards(label)
    @declared_keyword_guards ||= {}
    @declared_keyword_guards[label] ||= (self.class.declared_keywords&.[](label) || []).select do |_name, cls, _key, _text, kind, _nilable|
      !RbsParamCheck::CORE_IVAR_KINDS.key?(kind) || declared_core_kind_kept?(cls)
    end.to_h { |guard| [guard.first, guard] }
  end

  # The class bits KARG `insn` of `irep` leaves in its register, or nil: the declared kind, which the check right after
  # the KARG (declared_keyword_guard_statement) holds the given value to.
  def declared_keyword_bits(irep, insn)
    _name, cls, _key, _text, kind, nilable = declared_keyword_guards(irep.label)[insn.sym.to_s]
    return nil unless kind

    bit = declared_arg_bits(cls, kind, nilable)
    bit.zero? ? nil : bit
  end

  # The C++ statement that checks KARG `insn`'s register `var` against its declared keyword type, or ''.
  def declared_keyword_guard_statement(irep, insn, var)
    name, cls, key, text, kind, nilable = declared_keyword_guards(irep.label)[insn.sym.to_s]
    return '' unless name

    cond = case kind
           when :float, :symbol, :array, :hash, :string then declared_return_condition(kind, cls, false, var)
           when :integer then declared_return_condition(:fixnum, cls, false, var)
           else exact_class_guard(owner_class_ptr_expr(cls), var)
           end
    cond = "mrb_nil_p(#{var}) || (#{cond})" if nilable
    "  if (mrb_unlikely(!(#{cond}))) bc2cpp_declared_keyword_violation(M, #{var}, \"#{key}\", \"#{text}\"); " \
      "#{DeclaredReturns.keyword_guard_marker(key, name)}\n"
  end

  # label => guards for every label (declared_param_guards), what the class pools, the call-site report and the
  # optional guard contract read.
  def declared_params_kept
    @declared_params_kept ||= (self.class.declared_params || {}).each_key.to_h { |label| [label, declared_param_guards(label)] }
  end

  # DECLARED_RETURN_GUARD: `code` (one compile_method result) with every exit of `impl_name` checked against the
  # declaration of `label`, and every trusted declared parameter class checked on entry (DECLARED_PARAM_GUARD), or
  # `code` unchanged when it has neither. The body's definition becomes
  # `static inline <impl>_unguarded`, and `<impl>` itself (the one name every caller, direct call or entry wrapper,
  # reaches) checks the parameters, calls it and checks the value, so each exit of the body is covered without
  # rewriting its returns. The entry wrapper's Fiber hand-off to the interpreter (FIBER_BODY_GUARD) returns past
  # `<impl>` and is checked where it returns. A body with no definition to wrap (an `#error` stub) is left alone:
  # bc2cpp.rb refuses it.
  def declared_return_guard_wrap(label, code, impl_name)
    entry = declared_return_guard(label)
    return code if code.include?('#error')

    head = /^mrb_value #{Regexp.escape(impl_name)}\(([^)]*)\) \{$/
    params = code.scan(head).first&.first
    names = params&.split(',')&.map { |p| p.strip[/(\w+)\z/, 1] }
    types = params ? params.split(',').map { |p| p.strip.sub(/\s*\w+\z/, '').strip } : []
    checks = names ? declared_param_guard_statements(label, names, types) : ''
    return code unless entry || !checks.empty?

    heads = code.scan(head)
    raise "DECLARED_RETURN_GUARD: #{entry&.key || label}: #{heads.size} definitions of #{impl_name}, expected one" unless heads.size == 1

    guarded = "#{impl_name}_unguarded"
    out = code.sub(head) { "static inline mrb_value #{guarded}(#{params}) {" }
    out << "mrb_value #{impl_name}(#{params}) {\n#{checks}" \
           "  mrb_value bc2cpp_declared_ret = #{guarded}(#{names.join(', ')});\n"
    out << declared_return_guard_statement(entry, 'bc2cpp_declared_ret') if entry
    out << "  return bc2cpp_declared_ret;\n}\n\n"
  end
end
