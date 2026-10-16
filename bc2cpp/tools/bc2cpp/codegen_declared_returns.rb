# frozen_string_literal: true

require_relative 'declared_returns'

# CodeGen: DECLARED_RETURN_CHECK (docs/adr/0455).
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
# Array or proven_array_source, :class by trace_new_target == C (the exact class; `C?` also takes nil paths). A path
# the checker cannot prove is a TC1010 error at its Ruby file:line.
#
# The closed-world preconditions of the proofs hold for the name-level fact (declared_return_facts): every registry
# definition of the name has a bytecode body and the same declaration; no native or foreign Ruby defines it; no alias,
# define_method, undef or computed-name send can install or rename it (an error: such a declaration cannot hold);
# a POLY name also needs ClosedWorld#name_fully_visible?. A declaration whose name fails a non-error precondition
# is still checked per definition and adds no fact.
class CodeGen
  class << self
    # [DeclaredReturns::Entry] for this build (nil: none), and the root diagnostics are relative to.
    attr_accessor :declared_returns, :declared_return_root
  end

  DECLARED_RETURN_TERMINALS = %w[RETNIL RETSELF RETTRUE RETFALSE STOP].freeze

  # The checked declarations; %a{bc2cpp:hint} ones are only listed (declared_return_hints).
  def declared_return_entries
    @declared_return_entries ||= (self.class.declared_returns || []).select { |e| @ireps[e.label] && !e.hint }
  end

  def declared_return_hints
    (self.class.declared_returns || []).select(&:hint)
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
    unless defs.all? { |d| d.irep && @ireps[d.irep] }
      return ['info', "`#{name}` also has a native or accessor definition"]
    end

    entries = declared_return_by_name[name] || []
    undeclared = defs.reject { |d| entries.any? { |e| e.owner == d.owner && e.label == d.irep } }
    unless undeclared.empty?
      missing = undeclared.map(&:owner).sort.join(', ')
      return ['info', "POLY `#{name}`: #{missing} not declared (checked per definition)"]
    end
    if entries.map { |e| [e.kind, e.cls, e.nilable] }.uniq.size > 1
      return ['info', "POLY `#{name}`: the definitions declare different types (checked per definition)"]
    end
    if defs.size > 1 && !(@closed_world&.name_fully_visible?(name))
      return ['info', "POLY `#{name}` is not fully visible to the closed world (checked per definition)"]
    end

    # FIXNUM_RETURN_PROOF's own precondition (ADR 0279): it refuses any name a program spells as a literal.
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
    # The proofs run on the closed world's outside-source scan, a required bc2cpp input (ADR 0466).
    if @foreign_method_names.nil? && !declared_return_entries.empty?
      raise 'DECLARED_RETURN_CHECK: no outside-source scan; bc2cpp compiles closed-world programs only (ADR 0466)'
    end
    declared_return_hints.each do |entry|
      @declared_return_report << "  DECLARED_RET #{entry.key} -> #{entry.text}: " \
                                 'unchecked hint (%a{bc2cpp:hint}), no fact'
    end
    declared_return_entries.each do |entry|
      refusal = declared_return_refusal(entry.name)
      failures = declared_return_failures(entry)
      failures.each { |f| @declared_return_diagnostics << f }
      if refusal
        message = refusal.first == 'error' ? "cannot be checked: #{refusal.last}" : "#{refusal.last}; no return fact"
        loc = entry.loc
        @declared_return_diagnostics << declared_return_diag(loc.file, loc.line, loc.col, refusal.first,
                                                             "#{entry.key} -> #{entry.text}: #{message}")
      end
      status = if failures.empty? && refusal.nil? then "checked, fact #{entry.kind}"
               elsif failures.empty? && refusal.first == 'info' then 'checked, no fact'
               else 'FAILED'
               end
      @declared_return_report << "  DECLARED_RET #{entry.key} -> #{entry.text}: #{status}"
    end
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
      line = ir.instructions[idx]&.lineno || 0
      out << declared_return_diag(declared_return_relative(ir.file), line, 1, 'error',
                                  "#{entry.key}: declared -> #{entry.text} (#{entry.loc.file}:#{entry.loc.line}), " \
                                  "but #{why}")
    end
    irep.instructions.each_with_index do |insn, idx|
      case insn.op
      when 'RETURN', 'RETURN_BLK'
        why = declared_return_value_failure(entry, d, irep, idx, insn.reg, breaks)
        flag.call(irep, idx, why) if why
      when 'RETNIL'
        flag.call(irep, idx, 'a path returns nil') unless entry.nilable && entry.kind == :class
      when 'RETSELF'
        flag.call(irep, idx, 'a path returns self') unless declared_self_is?(entry, d)
      when *DECLARED_RETURN_TERMINALS
        flag.call(irep, idx, "a path ends with #{insn.op}")
      end
    end
    declared_block_returns(irep).each do |child, idx, insn|
      why = declared_return_value_failure(entry, d, child, idx, insn.reg, breaks)
      flag.call(child, idx, "a `return` inside a block: #{why}") if why
    end
    out
  end

  # [child irep, index, insn] of every RETURN_BLK below +irep+ (a `return` from a block leaves the method).
  def declared_block_returns(irep, seen = Set.new, acc = [])
    (irep.reps || []).each do |label|
      next unless seen.add?(label)

      child = @ireps[label]
      next unless child

      child.instructions.each_with_index { |insn, idx| acc << [child, idx, insn] if insn.op == 'RETURN_BLK' }
      declared_block_returns(child, seen, acc)
    end
    acc
  end

  def declared_subtree_breaks?(irep, seen = Set.new)
    (irep.reps || []).any? do |label|
      next false unless seen.add?(label)

      child = @ireps[label]
      child && (child.instructions.any? { |i| i.op == 'BREAK' } || declared_subtree_breaks?(child, seen))
    end
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

      return "the value returned at line #{ir.instructions[idx].lineno} has a definition the checker cannot follow " \
             '(an argument, a rescue edge, a block-written local or an unaudited instruction)'
    end
    sources.each do |src|
      if src == :nil
        next if entry.nilable && entry.kind == :class

        return 'a path returns nil'
      end
      w, r = src
      writer = ir.instructions[w]
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
    writer = ir.instructions[w]
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

      traced ? "#{what} is a #{traced}, not exactly #{entry.cls}" : "#{what} is not a proven #{entry.cls}"
    end
  end

  # 'Array' when the write of `r` at `w` is an Array: the array proof's own predicates, or `a + b` whose left operand is
  # an Array on every reaching definition (Array#+ always answers a new Array; no program `+` on Array or a subclass,
  # no prepend). Else the class trace_new_target names, or nil.
  def declared_array_source(d, ir, w, r, depth)
    traced = declared_traced_class(nil, d, ir, w + 1, r, declared_hop_dominance(ir, w))
    return 'Array' if traced == 'Array' || declared_array_scan(d, ir, w + 1, r)

    writer = ir.instructions[w]
    return traced unless writer.op == 'ADD' && depth < FIXNUM_PROOF_MAX_DEPTH && declared_array_plus_safe?

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

    @declared_array_plus_safe = builtin_class_send_safe?('+', ['Array']) &&
                                (@registry['+'] || []).none? { |md| md.irep && strict_subclass?(md.owner, 'Array') }
  end

  # The writer at `w` is a reaching definition already; every deeper hop must dominate (ADR 0198).
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
end
