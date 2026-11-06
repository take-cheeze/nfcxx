# frozen_string_literal: true

require_relative 'bytecode_ir_containers'

require_relative 'declared_constants'
require_relative 'declared_returns'
require_relative 'codegen_sealed_containers'

# CodeGen: DECLARED_RETURN_CHECK.
#
# Modular checking of RBS return declarations (DeclaredReturns entries): assume every declaration, check every body
# against them, abort when one fails. Then the declarations are a sound addition to the greatest fixpoints:
#
#   compute_fixnum_return_names / compute_array_return_names / compute_class_return_names seed the names
#   declared_return_facts admits, and the fixpoints never drop them (they are checked here instead);
#   check_declared_returns, once those fixpoints are final, verifies every return path of every declared definition
#   with the predicates the proofs use. Calls to other declared names are proven by THEIR declarations, through the
#   seeded sets, so a recursive or mutually recursive pair checks like the fixpoint's own induction.
#
# A return path is
#   * `RETURN R` of the method body (explicit `return` and the implicit last expression alike), each reaching
#     definition of R separately (return_value_sources): a nil one is a nil path;
#   * `RETNIL` (an empty body, `return`), `RETSELF`, `RETTRUE`, `RETFALSE`;
#   * `RETURN_BLK R` in any nested block (a `return` from inside a block);
#   * a `break` in a nested block: it replaces the value of the call that took the block, so a path whose value is a
#     block-carrying send's result is refused when the subtree breaks.
# Every path must prove: :fixnum by fixnum_proof_source? / proven_fixnum_operand?, :array by trace_new_target ==
# Array or proven_array_source, :class by trace_new_target == C (the exact class; `C?` also takes nil paths, and an
# `@h[k]` read of a sealed Hash ivar whose stored values are all exactly C, SEALED_HASH_IVAR in
# codegen_sealed_containers.rb). A path the checker cannot prove is a TC1010 error at its Ruby file:line.
#
# The closed-world preconditions of the proofs hold for the name-level fact (declared_return_facts): every registry
# definition of the name has a bytecode body and the same declaration; no native or foreign Ruby defines it; no alias,
# define_method, undef or computed-name send can install or rename it (an error: such a declaration cannot hold);
# a POLY name also needs ClosedWorld#name_fully_visible?. A declaration whose name fails a non-error precondition
# is still checked per definition and adds no fact.
#
# DECLARED_RETURN_GUARD: a %a{bc2cpp:hint} declaration is checked at run time instead. Its compiled body is wrapped
# (declared_return_guard_wrap): every value the method returns, by any path (a `return`, the last expression, a
# block's `return` caught at the frame, the entry specialization, the Fiber hand-off to the interpreter), passes one
# check of the declared kind before the caller sees it, and a mismatch raises BC2cppHintViolation naming the method
# and the type. There is no by-name fallback. The declaration then enters the same fact sets as a statically checked
# one, under the same closed-world preconditions; bc2cpp.rb aborts a run that trusted it without compiling the guard
# (DeclaredReturns.guard_failures).
class CodeGen
  class << self
    # [DeclaredReturns::Entry] for this build (nil: none), and the root diagnostics are relative to.
    # declared_return_hint_refusals: DeclaredReturns.hint_refusals, the hinted declarations no body can carry.
    attr_accessor :declared_returns, :declared_return_root, :declared_return_hint_refusals
  end

  # The checked declarations: statically checked ones and the runtime-checked %a{bc2cpp:hint} ones.
  def declared_return_entries
    @declared_return_entries ||= (self.class.declared_returns || []).select { |e| @ireps[e.label] }
  end

  # The runtime-checked declarations that need their compiled check (DECLARED_RETURN_GUARD). A hint whose name admits
  # no fact (refused as info: another definition outside the program also defines it, such as native `inspect`) is
  # relied on by nothing, so its body keeps no check and the build does not require one. An error refusal still does.
  def declared_return_hints
    declared_return_entries.select { |e| e.hint && declared_return_refusal(e.name)&.first != 'info' }
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
    core = entries.select(&:hint).filter_map { |e| @owner_of[e.label] }.select(&:core)
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

  # Runs once the return fixpoints are final. Diagnostics are hashes in RbsSignatures::Diag's shape.
  def check_declared_returns
    @declared_return_diagnostics = []
    @declared_return_report = []
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
      if refusal
        message = refusal.first == 'error' ? "cannot be checked: #{refusal.last}" : "#{refusal.last}; no return fact"
        loc = entry.loc
        @declared_return_diagnostics << declared_return_diag(loc.file, loc.line, loc.col, refusal.first,
                                                             "#{entry.key} -> #{entry.text}: #{message}")
      end
      how = entry.hint ? 'runtime-checked (%a{bc2cpp:hint})' : 'checked'
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
    case kind
    when :fixnum then "mrb_fixnum_p(#{var})"
    when :array then "mrb_array_p(#{var})"
    when :string then "mrb_string_p(#{var})"
    when :bool then "mrb_true_p(#{var}) || mrb_false_p(#{var})"
    when :nil then "mrb_nil_p(#{var})"
    when :hash then "mrb_hash_p(#{var})"
    when :symbol then "mrb_symbol_p(#{var})"
    when :float then "mrb_float_p(#{var})"
    when :module then "mrb_obj_is_kind_of(M, #{var}, mrb_module_get(M, \"#{cls}\"))"
    when :union then cls.map { |k, c, n| "(#{declared_return_condition(k, c, n, var)})" }.join(' || ')
    when :class
      exact = exact_class_guard(owner_class_ptr_expr(cls), var)
      nilable ? "mrb_nil_p(#{var}) || #{exact}" : exact
    else raise "DECLARED_RETURN_GUARD: no runtime check for kind #{kind.inspect}"
    end
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

  # DECLARED_RETURN_GUARD: `code` (one compile_method result) with every exit of `impl_name` checked against the
  # runtime-checked declaration of `label`, or `code` unchanged when it has none. The body's definition becomes
  # `static inline <impl>_unguarded`, and `<impl>` itself (the one name every caller, direct call or entry wrapper,
  # reaches) calls it and checks the value, so each exit of the body is covered without rewriting its returns. The
  # entry wrapper's Fiber hand-off to the interpreter (FIBER_BODY_GUARD) returns past `<impl>` and is checked
  # where it returns. A body with no definition to wrap (an `#error` stub) is left alone: bc2cpp.rb refuses it.
  def declared_return_guard_wrap(label, code, impl_name)
    entry = declared_return_guard(label)
    return code unless entry && !code.include?('#error')

    head = /^mrb_value #{Regexp.escape(impl_name)}\(([^)]*)\) \{$/
    heads = code.scan(head)
    raise "DECLARED_RETURN_GUARD: #{entry.key}: #{heads.size} definitions of #{impl_name}, expected one" unless heads.size == 1

    params = heads.first.first
    names = params.split(',').map { |p| p.strip[/(\w+)\z/, 1] }
    guarded = "#{impl_name}_unguarded"
    out = code.sub(head) { "static inline mrb_value #{guarded}(#{params}) {" }
    out << "mrb_value #{impl_name}(#{params}) {\n" \
           "  mrb_value bc2cpp_declared_ret = #{guarded}(#{names.join(', ')});\n" \
           "#{declared_return_guard_statement(entry, 'bc2cpp_declared_ret')}" \
           "  return bc2cpp_declared_ret;\n}\n\n"
  end
end
