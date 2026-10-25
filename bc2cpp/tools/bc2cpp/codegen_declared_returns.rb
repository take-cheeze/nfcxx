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

  DECLARED_RETURN_TERMINALS = %i[true false stop].freeze

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
      # DECLARED_RETURN_GUARD: the compiled body checks every returned value; nothing is proven statically.
      failures = entry.hint ? [] : declared_return_failures(entry)
      failures.each { |f| @declared_return_diagnostics << f }
      if refusal
        message = refusal.first == 'error' ? "cannot be checked: #{refusal.last}" : "#{refusal.last}; no return fact"
        loc = entry.loc
        @declared_return_diagnostics << declared_return_diag(loc.file, loc.line, loc.col, refusal.first,
                                                             "#{entry.key} -> #{entry.text}: #{message}")
      end
      how = entry.hint ? 'runtime-checked (%a{bc2cpp:hint})' : 'checked'
      status = if failures.empty? && refusal.nil? then "#{how}, fact #{entry.kind}"
               elsif failures.empty? && refusal.first == 'info' then "#{how}, no fact"
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

  # Unproven return paths of one declared definition, as diagnostics at their Ruby lines.
  def declared_return_failures(entry)
    d = @owner_of[entry.label]
    irep = @ireps[entry.label]
    return [] unless d && irep

    breaks = declared_subtree_breaks?(irep)
    out = []
    flag = lambda do |ir, idx, why|
      line = BytecodeIR.for(ir).source_at(idx)&.lineno || 0
      out << declared_return_diag(declared_return_relative(ir.file), line, 1, 'error',
                                  "#{entry.key}: declared -> #{entry.text} (#{entry.loc.file}:#{entry.loc.line}), " \
                                  "but #{why}")
    end
    BytecodeIR.for(irep).exits.each do |exit|
      idx = exit.index
      case exit.kind
      when :value, :block_return
        why = declared_return_value_failure(entry, d, irep, idx, exit.reg&.to_s, breaks)
        flag.call(irep, idx, why) if why
      when :nil
        flag.call(irep, idx, 'a path returns nil') unless entry.nilable && entry.kind == :class
      when :self
        flag.call(irep, idx, 'a path returns self') unless declared_self_is?(entry, d)
      when *DECLARED_RETURN_TERMINALS
        flag.call(irep, idx, "a path ends with #{exit.op}")
      end
    end
    # A `return` from a block leaves the method.
    BytecodeIR.nested_exits(irep, :block_return).each do |child, exit|
      why = declared_return_value_failure(entry, d, child, exit.index, exit.reg&.to_s, breaks)
      flag.call(child, exit.index, "a `return` inside a block: #{why}") if why
    end
    out
  end

  def declared_subtree_breaks?(irep)
    BytecodeIR.nested_exit?(irep, :break)
  end

  # `self` is exactly C only in a class with no subclass that is not a module or a singleton.
  def declared_self_is?(entry, d)
    entry.kind == :class && d.owner == entry.cls && !d.owner.end_with?('.singleton') &&
      @known_owners.none? { |k| strict_subclass?(k, d.owner) } && @superclass_of.key?(d.owner)
  end

  # nil when the value of `reg` at the return `idx` of `ir` proves the declaration, else why not.
  def declared_return_value_failure(entry, d, ir, idx, reg, breaks)
    return 'the returned register is unknown' unless reg

    sources = return_value_sources(ir, idx, reg)
    unless sources
      return nil if declared_whole_value_proven?(entry, d, ir, idx, reg)

      return "the value returned at line #{BytecodeIR.for(ir).source_at(idx).lineno} has a definition the checker cannot follow " \
             '(an argument, a rescue edge, a block-written local or an unaudited instruction)'
    end
    sources.each do |src|
      if src == :nil
        next if entry.nilable && entry.kind == :class

        return 'a path returns nil'
      end
      w, r = src
      writer = BytecodeIR.for(ir).source_at(w)
      if breaks && %w[SENDB SSENDB].include?(writer.op)
        return "a block passed to `#{writer.sym}` (line #{writer.lineno}) may `break`, replacing the call's value"
      end

      why = declared_source_failure(entry, d, ir, w, r)
      return why if why
    end
    nil
  end

  # A whole-register proof for a return whose reaching definitions return_value_sources does not list (an entry
  # argument, for one): the proofs' own operand predicates, which handle those themselves.
  def declared_whole_value_proven?(entry, d, ir, idx, reg)
    case entry.kind
    when :fixnum then proven_fixnum_operand?(ir, idx, reg, d)
    when :array
      dominated = ->(w_idx, use_idx, r) { return_write_dominates?(ir, w_idx, use_idx, r) }
      straightline_return_reg?(ir, idx, reg) &&
        (declared_traced_class(entry, d, ir, idx, reg, dominated) == 'Array' || declared_array_scan(d, ir, idx, reg))
    when :class
      declared_traced_class(entry, d, ir, idx, reg, nil) == entry.cls
    end
  end

  # nil when the write of `r` at `w` proves the declaration, else why not.
  def declared_source_failure(entry, d, ir, w, r)
    writer = BytecodeIR.for(ir).source_at(w)
    what = "the value written at line #{writer.lineno} (#{writer.op}#{writer.sym ? " :#{writer.sym}" : ''})"
    case entry.kind
    when :fixnum
      return nil if fixnum_proof_source?(ir, w, writer, r, d, 0)

      "#{what} is not a proven Fixnum"
    when :array
      traced = declared_array_source(d, ir, w, r, 0)
      return nil if traced == 'Array'

      traced ? "#{what} is a #{traced}, not an Array" : "#{what} is not a proven Array"
    when :class
      traced = declared_traced_class(entry, d, ir, w + 1, r, declared_hop_dominance(ir, w))
      return nil if traced == entry.cls
      return "#{what} is a #{traced}, not exactly #{entry.cls}" if traced

      # SEALED_HASH_IVAR: `@h[k]` answers a stored value or nil, so only a `C?` declaration may take it.
      if entry.nilable && writer.op == :GETIDX && writer.reg == r
        why = sealed_hash_read_failure(ir, w, entry.cls, declared_sealed_value_prover(entry))
        return why ? "#{what} is not a proven #{entry.cls} (#{why})" : nil
      end
      "#{what} is not a proven #{entry.cls}"
    end
  end

  # Proves one value a sealed Hash literal stores is exactly the declared class: the same class trace, in the
  # storing method's frame.
  def declared_sealed_value_prover(entry)
    lambda do |site, idx, reg|
      sd = numeric_irep_owner[site.label]
      next 'a store outside a method' unless sd

      dominated = ->(w_idx, use_idx, hop) { return_write_dominates?(site, w_idx, use_idx, hop) }
      traced = declared_traced_class(entry, sd, site, idx, reg, dominated)
      traced == entry.cls ? nil : "#{traced ? "a #{traced}" : 'a value'}, not a proven #{entry.cls}"
    end
  end

  # 'Array' when the write of `r` at `w` is an Array: the array proof's own predicates, or `a + b` whose left operand is
  # an Array on every reaching definition (Array#+ always answers a new Array; no program `+` on Array or a subclass,
  # no prepend). Else the class trace_new_target names, or nil.
  def declared_array_source(d, ir, w, r, depth)
    traced = declared_traced_class(nil, d, ir, w + 1, r, declared_hop_dominance(ir, w))
    return 'Array' if traced == 'Array' || declared_array_scan(d, ir, w + 1, r)

    writer = BytecodeIR.for(ir).source_at(w)
    return traced unless writer.op == :ADD && depth < FIXNUM_PROOF_MAX_DEPTH && declared_array_plus_safe?

    sources = return_value_sources(ir, w, writer.reg)
    return traced unless sources && !sources.empty? && sources.none?(:nil)

    sources.all? { |sw, sr| declared_array_source(d, ir, sw, sr, depth + 1) == 'Array' } ? 'Array' : traced
  end

  # proven_array_source without the unchecked `# bc2cpp: -> Array` comment seeds: a call proves an Array through
  # ARRAY_RETURN_PROOF, which holds the checked declarations.
  def declared_array_scan(d, ir, idx, reg)
    receiver_class = ->(pin_idx, pin) { block_fallback_receiver_class(ir, pin_idx, pin.reg, d.owner) }
    proven_array_source_scan(ir, idx, reg, @registry, nil, ->(n) { @array_return_names.include?(n) },
                             receiver_class: receiver_class)
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

  # The writer at `w` is a reaching definition already; every deeper hop must dominate.
  def declared_hop_dominance(ir, w)
    ->(w_idx, use_idx, hop) { (w_idx == w && use_idx == w + 1) || return_write_dominates?(ir, w_idx, use_idx, hop) }
  end

  # trace_new_target with the method's facts, the class return fixpoint (seeded with the declarations) for self and
  # explicit calls, and no unchecked `-> C` comment annotation.
  def declared_traced_class(_entry, d, ir, idx, reg, dominated)
    method_level = ir.label == d.irep
    trace_new_target(ir, idx, reg, @class_layout[d.owner], method_level ? mandatory_arity(ir) : 0,
                     method_level ? @class_annotations[ir.label]&.args : nil, owner: d.owner,
                     class_layout: @class_layout, registry: @registry, container_constants: @container_constants,
                     ret_class_proof: ->(n, o) { class_return_for_self_call(n, o) },
                     method_return_class: ->(n) { class_return_for_dispatch(n) }, dominated: dominated)
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
      exact = "mrb_obj_class(M, #{var}) == #{owner_class_ptr_expr(cls)}"
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
    out = out.gsub(/return (bc2cpp_core_interpreted\(M, self, \d+\));/) do
      "{ mrb_value bc2cpp_declared_ret = #{Regexp.last_match(1)};\n" \
        "#{declared_return_guard_statement(entry, 'bc2cpp_declared_ret')}  return bc2cpp_declared_ret; }"
    end
    out << "mrb_value #{impl_name}(#{params}) {\n" \
           "  mrb_value bc2cpp_declared_ret = #{guarded}(#{names.join(', ')});\n" \
           "#{declared_return_guard_statement(entry, 'bc2cpp_declared_ret')}" \
           "  return bc2cpp_declared_ret;\n}\n\n"
  end
end
