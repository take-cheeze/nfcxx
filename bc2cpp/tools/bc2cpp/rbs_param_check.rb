# frozen_string_literal: true

require 'set'
require_relative 'bytecode_ir_ops'
require_relative 'call_site_index'
require_relative 'dynamic_names'
require_relative 'native_names'
require_relative 'closed_world'
require_relative 'nil_narrowing'

# RBS_CHECKED_PARAMS: a class parameter type in an RBS signature is a checked fact, not a seed.
#
# `def m: (Game::State s) -> R` on a method the program defines feeds ClassAnnotations (the receiver class of `s`
# inside the body). Before this check nothing compared it with the callers. Now, for every such parameter:
#
#   * every caller must be visible to the closed world: a name a computed send can reach (DynamicNames.universe),
#     a name outside code can call (outside_call_names), an operator, an aliased name, a packed
#     (`f(*a)`, `f(*a, &b)`) or keyword caller refuses the declaration (TC1014 at the signature); a name nothing
#     calls holds vacuously. Of a POLY name, each definition is checked at every site its arity admits. An
#     `initialize` is checked at its CONSTRUCTOR_POOLS entries and refused
#     when the pool refuses it;
#   * every argument at such a site must trace to the declared class through the reaching definitions of its
#     register (exception edges included): `Klass.new` (an unoverridden constructor of exactly that class), a call
#     whose every definition has a checked `-> C` declaration (DECLARED_RETURN_CHECK; a %a{bc2cpp:hint}
#     one is checked at run time by its compiled body, DECLARED_RETURN_GUARD) or is an attr_reader of a proven slot, a parameter of the enclosing
#     method whose signature declares that class, the same parameter read from a block through GETUPVAR when the
#     method never reassigns it, `self` in a method of a class nothing inherits from, or an ivar every store of
#     which is proven and which no read sees unassigned. A call declared `-> C?` gives "C or nil": the argument
#     then also needs NIL_NARROWING (nil_narrowing.rb) to prove the register non-nil at the call site. Before
#     any of that, an argument that every path proves an instance of exactly the class by a true
#     `x.is_a?(C)` test (IS_A_GUARD, nil_narrowing.rb and CodeGen#is_a_guard_class) is proven.
#     Anything else is TC1013 at the call site's file:line.
#
# A refused or unverified parameter is removed from the annotation tables, so a type check run (which does not
# abort on errors) still never trusts it. Integer / Symbol / Array / Hash parameters are not checked here: their
# consumers re-check the value.
module RbsParamCheck
  MAX_DEPTH = 8

  # A reaching definition proven "C or nil" (a `-> C?` call): the use must also be proven non-nil.
  Nilable = Struct.new(:why)

  # IS_A_GUARD's two closed-world answers for NilNarrowing (CodeGen#is_a_guard_class, #raise_never_returns?).
  IsAGuard = Struct.new(:gen) do
    def is_a_class(irep, idx) = gen.is_a_guard_class(irep, idx)
    def raise_never_returns?(irep, idx) = gen.raise_never_returns?(irep, idx)
  end

  module_function

  # loaded: RbsSignatures.load's result; class_annotations: the merged table RbsSignatures.apply filled;
  # comment_class_args: label -> args the `# bc2cpp:` comments gave (they win and are not checked here).
  # Returns [diagnostics, verified] where verified is a Set of [label, position].
  # outside_names: outside_call_names' result (nil: no outside scan, every declaration is refused);
  # constructor_entries: a CodeGen built with `analysis_only: :constructor_sites` (constructor_entry_sites,
  # constructor_init_target); nil refuses every initialize declaration.
  # declared_returns: DeclaredReturns.from_signatures' entries (CodeGen.declared_returns). Each proves a call's
  # result: DECLARED_RETURN_CHECK aborts the build on a body that does not prove its declaration, and a
  # %a{bc2cpp:hint} one is checked on every return by its compiled body (DECLARED_RETURN_GUARD), which raises
  # instead of returning another type.
  def check(loaded, ireps, registry, class_annotations, comment_class_args:, call_sites:, outside_names:,
            superclass_of:, display_root: nil, applied: nil, constructor_entries: nil, declared_returns: nil)
    ctx = context(loaded, ireps, registry, superclass_of)
    ctx.merge!(ivar_cache: {}, ivar_active: Set.new, nil_cache: {},
               declared: (declared_returns || []).to_h { |e| [e.label, e] },
               nil_unanswerable: ->(name) { constructor_entries.nil_unanswerable?(name) },
               class_guard: IsAGuard.new(constructor_entries))
    ctx.merge!(outside: outside_names, display_root: display_root, call_sites: call_sites, applied: applied,
               class_annotations: class_annotations, comment_class_args: comment_class_args,
               constructor_entries: constructor_entries)
    diags = []
    pending = targets(ctx)
    pending.each do |sig, d, positions|
      refusal = refusal_of(ctx, sig, d)
      next unless refusal

      positions.each { |pos, _cls| drop(ctx, d.irep, pos) }
      listed = positions.map { |p, c| "#{p + 1} (#{c})" }.join(', ')
      diags << diag(sig.loc.file, sig.loc.line, sig.loc.col, 'TC1014',
                    "#{sig.owner}##{sig.name}: parameter type(s) #{listed} refused, not trusted: #{refusal}")
    end
    # A caller's own declared parameter only proves an argument while it is itself kept, so drop to a fixed point.
    loop do
      dropped = false
      ctx[:ivar_cache].clear
      pending.each do |sig, d, positions|
        positions.each do |pos, cls|
          next unless kept?(ctx, d.irep, pos, cls)

          bad = unproven_sites(ctx, sig, d, pos, cls)
          next if bad.empty?

          dropped = true
          drop(ctx, d.irep, pos)
          bad.each do |irep, idx, why|
            diags << diag(display(ctx, irep.file), irep.instructions[idx].lineno.to_i, 1, 'TC1013',
                          "#{sig.owner}##{sig.name} parameter #{pos + 1}: argument not proven #{cls} (#{why}); " \
                          "declared at #{sig.loc.file}:#{sig.loc.line}")
          end
        end
      end
      break unless dropped
    end
    verified = pending.flat_map do |_sig, d, positions|
      positions.filter_map { |pos, cls| [d.irep, pos] if kept?(ctx, d.irep, pos, cls) }
    end
    [diags, verified.to_set]
  end

  def diag(file, line, col, code, message)
    RbsSignatures::Diag.new(file: file, line: line, col: col, severity: 'error', code: code, message: message)
  end

  # The tables every query reads: method owners (`self_of` only for def bodies, never blocks, whose self an
  # instance_exec may change; `owner_of` also for blocks, for lexical constant lookup) and the signature of each body.
  def context(loaded, ireps, registry, superclass_of)
    ctx = { ireps: ireps, registry: registry, subclassed: superclass_of.values.grep(String).to_set,
            dynamic: DynamicNames.universe(ireps), self_of: {}, method_name: {}, owner_of: {}, sig_of: {}, def_of: {},
            aliased: alias_names(ireps), parent: {} }
    defs_by = {}
    registry.each_value do |defs|
      defs.each do |d|
        next unless d.irep

        ctx[:self_of][d.irep] = d.owner
        ctx[:method_name][d.irep] = d.name
        defs_by[[d.owner, d.name.to_s]] = d
      end
    end
    ctx[:owner_of].merge!(ctx[:self_of])
    parent = ctx[:parent]
    ireps.each_value { |irep| (irep.reps || []).each { |child| parent[child] = irep.label } }
    ireps.each_key do |label|
      up = label
      up = parent[up] until up.nil? || ctx[:self_of].key?(up)
      ctx[:owner_of][label] ||= ctx[:self_of][up] if up
    end
    loaded.methods.each_value do |sig|
      d = defs_by[[sig.owner, sig.name]] or next
      ctx[:sig_of][d.irep] = sig
      ctx[:def_of][d.irep] = d
    end
    ctx
  end

  # Both names of every `alias new old` (an ALIAS instruction; `alias_method` spells Symbols, DynamicNames).
  def alias_names(ireps)
    ireps.each_value.with_object(Set.new) do |irep, names|
      irep.each_with_op('ALIAS') do |insn, _index|
        names << insn.sym if insn.sym
        old = insn.first_of(:name)&.value
        names << old if old
      end
    end
  end

  # [irep, index, why] for every caller whose argument at `pos` is not proven `cls`. A caller whose argument count
  # the definition cannot take raises ArgumentError before the body runs, so it proves nothing and needs nothing.
  def unproven_sites(ctx, sig, d, pos, cls)
    req, opt, rest = ctx[:ireps][d.irep].enter&.enter_fields&.first(3)&.map(&:to_i) || [0, 0, 0]
    sites = sig.name == 'initialize' ? constructor_sites(ctx, d) : callers(ctx, sig.name)
    sites.filter_map do |irep, idx, dest, argc|
      next if argc < req || (rest.zero? && argc > req + opt)

      why = trace(ctx, irep, idx, (dest + pos + 1).to_s, cls, 0)
      [irep, idx, why] if why
    end
  end

  # Still a signature-only class fact (a `# bc2cpp:` comment is an unchecked hint, never a proof).
  def kept?(ctx, label, pos, cls)
    ctx[:class_annotations][label]&.args&.[](pos) == cls && !ctx[:comment_class_args][label]&.[](pos)
  end

  # [sig, def, [[position, class], ...]] for every signature whose class parameter reached ClassAnnotations.
  def targets(ctx)
    out = []
    ctx[:sig_of].each do |label, sig|
      d = ctx[:def_of][label]
      ann = ctx[:class_annotations][label]
      positions = sig.args.each_with_index.filter_map do |type, i|
        next unless type.kind == :class && ann && ann.args[i] == type.cls
        next if ctx[:comment_class_args][label]&.[](i)

        [i, type.cls]
      end
      out << [sig, d, positions] unless positions.empty?
    end
    out
  end

  def refusal_of(ctx, sig, d)
    name = sig.name
    return constructor_refusal(ctx, sig, d) if name == 'initialize'
    unless name.match?(/\A[A-Za-z_]/)
      return "#{name} is an operator: VM instructions (ADD, EQ, GETIDX, SETIDX, ...) and natives call it " \
             'without a SEND the call-site index lists'
    end
    return "#{name} is named by an `alias`, so calls of another name may run it" if ctx[:aliased].include?(name)
    if ctx[:dynamic].include?(name)
      return "#{name} is a name a computed send can reach (a Symbol or String literal of it)"
    end
    if ctx[:outside].include?(name)
      return "#{name} is named by an outside-world (native or foreign Ruby) source, which may call it"
    end

    irep, idx, = callers(ctx, name).find { |_irep, _idx, _dest, argc| argc.nil? }
    "a packed (splat) or keyword caller at #{display(ctx, irep.file)}:#{irep.instructions[idx].lineno}" if irep
  end

  # An initialize is entered by `Klass.new` and `super`, never by a SEND of its name. CONSTRUCTOR_POOLS
  # enumerates those entries in the closed world: every `new` whose receiver resolves (a class constant, the class's
  # own class object, a class-object parameter), every explicit `super` in a subclass initialize; and it refuses
  # the body when anything else may enter it (an unresolved `new` the arity admits, `send`/Symbol/alias naming
  # new or initialize, a Ruby `new` or `allocate`, a mixin on Class, a class an outside source spells, a bare `super`).
  # Only mandatory positions are entry-site facts.
  def constructor_refusal(ctx, sig, d)
    entries = ctx[:constructor_entries]
    return 'no closed world: the constructor sites of initialize are not enumerable' unless entries

    _sites, why = entries.constructor_entry_sites(d.irep)
    return "initialize may be entered by a path the closed world does not resolve (CONSTRUCTOR_POOLS: #{why})" if why

    mand = ctx[:ireps][d.irep].enter&.enter_fields&.first.to_i
    late = sig.args.each_index.select { |i| sig.args[i].kind == :class && i >= mand }
    "position(s) #{late.map { |i| i + 1 }.join(', ')} are not mandatory (default code may write them)" unless late.empty?
  end

  # The constructor entries of +d+, less the `new` sites whose receiver traces to one class whose initialize is
  # another body. CONSTRUCTOR_POOLS keys a constant by its last segment (`Game::Map` may be any class named Map);
  # the receiver trace resolves it as the codegen's direct construct and new_why do.
  def constructor_sites(ctx, d)
    gen = ctx[:constructor_entries]
    sites, = gen.constructor_entry_sites(d.irep)
    sites.reject do |irep, idx, _dest, _argc, _owner|
      insn = irep.instructions[idx]
      next false unless insn.sym == 'new' && BytecodeIR::Ops::REGISTER_RECEIVER_SEND.include?(insn.op)

      klass = trace_new_target(irep, idx + 1, insn.reg, {}, 0, nil, owner: ctx[:owner_of][irep.label])
      target = klass && gen.constructor_init_target(klass)
      target && target.irep != d.irep
    end
  end

  # Every name code outside the analysed bytecode can call a Ruby method by: in a native source (comments dropped),
  # a string literal (`"name"`, mrb_intern_lit), an MRB_SYM-family token, or a hook the VM calls implicitly; in a
  # foreign Ruby source the closed world does not compile, any identifier. A C identifier that merely shares the
  # name (a local variable `range`) is not one: a native names a method only through a Symbol.
  def outside_call_names(native_paths, foreign_ruby_paths, compiled_files)
    names = Set.new(ClosedWorld::IMPLICIT_HOOKS)
    Array(native_paths).each do |path|
      text = File.binread(path).gsub(%r{"(?:[^"\\\n]|\\.)*"|'(?:[^'\\\n]|\\.)*'|/\*.*?\*/|//[^\n]*}m) do |tok|
        tok.start_with?('/') ? ' ' : tok
      end
      text.scan(ClosedWorld::C_STRING) { |(lit)| names << lit }
      text.scan(MRB_SYM_TOKEN_RE) { |m, n| names << resolve_mrb_sym_token(m, n) }
    end
    Array(foreign_ruby_paths).each do |path|
      next if compiled_files.include?(path) || compiled_files.include?(File.expand_path(path))

      foreign_ruby_names(File.binread(path)).each { |t| names << t << t.chomp('=').chomp('?').chomp('!') }
    end
    names
  end

  # The words of a foreign Ruby source that can name a method: every code token, and a string or symbol whose whole
  # content is a name (what a computed send could pass on unchanged). Comments and the words inside prose strings
  # are not; `"an exclusive range"` names nothing a send can reach without composing it, which DynamicNames
  # already treats as computed. A source Prism cannot lex cleanly is read bluntly, every word a name.
  def foreign_ruby_names(text)
    blunt = -> { text.scan(/[A-Za-z_]\w*[?!=]?/) }
    lexed = Prism.lex(text.dup.force_encoding(Encoding::UTF_8))
    return blunt.call unless lexed.errors.empty?

    lexed.value.filter_map do |token, _state|
      value = token.value
      case token.type
      when :COMMENT, :EMBDOC_BEGIN, :EMBDOC_LINE, :EMBDOC_END, :__END__ then nil
      when :STRING_CONTENT then value if value.match?(/\A[A-Za-z_]\w*[?!=]?\z/)
      else value[/\A[A-Za-z_]\w*[?!=]?\z/]
      end
    end
  rescue ArgumentError, EncodingError
    blunt.call
  end

  def callers(ctx, name)
    CallSiteIndex.sites(ctx[:call_sites], name)
  end

  # Removes the parameter's class seed, and its IR contract, so nothing downstream reads it.
  def drop(ctx, label, pos)
    if (applied = ctx[:applied])
      [applied.ir_arg_types, applied.ir_arg_elements].each do |table|
        table[label] = table[label].except((pos + 1).to_s).freeze if table[label]
      end
    end
    ann = ctx[:class_annotations][label] or return
    args = ann.args.dup
    args[pos] = nil
    ctx[:class_annotations][label] = ann.class.new(args: args)
  end

  def display(ctx, file)
    root = ctx[:display_root]
    root && file ? file.sub(%r{\A#{Regexp.escape(root)}/?}, '') : file.to_s
  end

  # nil when every definition of `reg` reaching instruction `idx` is proven `cls`, else why not.
  def trace(ctx, irep, idx, reg, cls, depth)
    return 'trace depth' if depth > MAX_DEPTH
    return nil if guarded?(ctx, irep, idx, reg, cls)

    defs, refusal = reaching(irep, idx, reg)
    if defs.nil? || defs.empty?
      return "the reaching definitions are not computable here (#{refusal[:cause] || 'no definition'})"
    end

    nilable = nil
    defs.each do |definition|
      why = if definition.entry? then entry_why(ctx, irep, definition.reg, cls)
            else writer_why(ctx, irep, definition, cls, depth)
            end
      if why.is_a?(Nilable)
        nilable ||= why
        next
      end
      return why if why
    end
    return nil unless nilable
    return nil if NilNarrowing.non_nil?(irep, idx, reg, ctx[:nil_unanswerable], ctx[:nil_cache],
                                        class_guard: ctx[:class_guard])

    "#{nilable.why}, and no test or call nil cannot answer proves R#{reg} non-nil at " \
      "#{display(ctx, irep.file)}:#{irep.instructions[idx].lineno} (NIL_NARROWING)"
  end

  # IS_A_GUARD (NIL_NARROWING): every path to `idx` passes a true `x.is_a?(cls)` of the value `reg` holds, so it is
  # an instance of exactly `cls`. is_a_guard_class only names a class nothing inherits from; the `subclassed` check
  # is the same one the `self` rule makes.
  def guarded?(ctx, irep, idx, reg, cls)
    return false if ctx[:subclassed].include?(cls)

    NilNarrowing.instance_of?(irep, idx, reg, cls, ctx[:nil_unanswerable], ctx[:nil_cache],
                              class_guard: ctx[:class_guard])
  end

  # Every definition that can reach `reg` at `idx`, exception edges included (a call inside a `begin`/`rescue`
  # range reads the register on whatever path got there, normal or handler). A state-bounded query that runs out
  # of states is retried once with a larger bound: the bound limits work, never the answer.
  def reaching(irep, idx, reg)
    [BytecodeIR::DATAFLOW_MAX_STATES, BytecodeIR::DATAFLOW_MAX_STATES * 16].each do |cap|
      refusal = {}
      defs = BytecodeIR.reaching_definitions(irep, idx, reg, through_handlers: true, max_states: cap, refusal: refusal)
      return [defs, refusal] unless defs.nil? && refusal[:cause] == :state_cap
    end
    [nil, { cause: :state_cap }]
  end

  def entry_why(ctx, irep, reg, cls)
    sig = ctx[:sig_of][irep.label]
    unless sig
      owner = ctx[:self_of][irep.label]
      return "R#{reg} is a block parameter or upvar" unless owner

      return "parameter #{reg} of #{owner}##{ctx[:method_name][irep.label]} has no signature"
    end

    type = reg.to_i.positive? ? sig.args[reg.to_i - 1] : nil
    return nil if type && type.kind == :class && type.cls == cls && kept?(ctx, irep.label, reg.to_i - 1, cls)

    "parameter #{reg} of #{sig.owner}##{sig.name} is declared #{type&.text || 'untyped'}"
  end

  def writer_why(ctx, irep, definition, cls, depth)
    insn = irep.instructions[definition.index]
    case insn.op
    when 'LOADSELF'
      owner = ctx[:self_of][irep.label]
      unless owner
        # BLOCK_SELF (codegen_block_self.rb): a block only ever called keeps its method's self.
        gen = ctx[:constructor_entries]
        d, why = gen ? gen.block_self_owner(irep.label) : [nil, 'no closed world']
        return "self (in a block: #{why})" unless d

        owner = d.owner
      end
      return nil if owner == cls && !ctx[:subclassed].include?(cls)

      "self (#{owner})"
    when 'GETIV'
      ivar_why(ctx, irep, insn.ivar, cls, depth)
    when 'GETUPVAR'
      upvar_why(ctx, irep, insn, cls)
    when *BytecodeIR::Ops::SEND
      name = insn.sym
      return new_why(ctx, irep, definition.index, cls) if name == 'new' &&
                                                          BytecodeIR::Ops::REGISTER_RECEIVER_SEND.include?(insn.op)

      entry, body = ctx[:constructor_entries]&.block_return_site(irep, definition.index, insn)
      return block_value_why(ctx, body, name, cls, depth) if entry&.kind == :block_value
      return trace(ctx, irep, definition.index, insn.reg, cls, depth + 1) if entry&.kind == :self

      returns_why(ctx, name, cls, depth)
    else
      "#{insn.op} at #{display(ctx, irep.file)}:#{insn.lineno}"
    end
  end

  # `@name` read in +irep+ is `cls` when every SETIV that can write the slot (CodeGen#ivar_write_sites_of) stores a
  # value proven `cls` and no read can see it unassigned. A store that reads the slot back (`@a = @a`) is assumed
  # `cls` while it is being proven: by induction over the stores executed, no store is the first to write another
  # class. Top-level answers are kept for one round of the fixed point, since they rest on parameters still kept.
  def ivar_why(ctx, irep, name, cls, depth, owner: nil)
    gen = ctx[:constructor_entries]
    return "GETIV @#{name}: no closed world" unless gen && name

    reader = owner || gen.ivar_reader_owner(irep.label)
    sites, why = gen.ivar_write_sites_of(reader, name)
    return "#{owner ? "#{owner}##{name} reads" : 'GETIV'} @#{name} (#{why})" if why

    key = [reader, name, cls]
    cache = ctx[:ivar_cache]
    return cache[key] if cache.key?(key)
    return nil if ctx[:ivar_active].include?(key)

    ctx[:ivar_active] << key
    found = sites.each do |site_irep, idx, reg|
      why = trace(ctx, site_irep, idx, reg.to_s, cls, depth + 1)
      break "@#{name} = (#{why}) at #{display(ctx, site_irep.file)}:#{site_irep.instructions[idx].lineno}" if why
    end
    ctx[:ivar_active].delete(key)
    result = found.is_a?(String) ? found : nil
    # An answer reached under an outer assumption is not kept: that assumption may still fail.
    cache[key] = result if ctx[:ivar_active].empty?
    result
  end

  # A block's GETUPVAR of a slot of the method that created it (`cmd` in `r.each { operand_value(cmd) }`) is that
  # method's parameter when the method never writes the register after entry (Program#may_write?, the model
  # entry_why's reaching definitions use), no nested block SETUPVARs it, and nothing in the build can write a local
  # by name (CodeGen#captured_local_writers_absent?: binding, local_variable_set, eval). The block may run after the
  # method returned; the captured slot still holds the entry value. The parameter must then be a kept declaration.
  def upvar_why(ctx, irep, insn, cls)
    where = "GETUPVAR at #{display(ctx, irep.file)}:#{insn.lineno}"
    index, level = insn.upvar_ref
    return "#{where}: no captured slot" unless index

    label = irep.label
    (level + 1).times do
      label = ctx[:parent][label]
      return "#{where}: the capturing frame is unknown" unless label
    end
    frame = ctx[:ireps][label]
    return "#{where}: a captured slot of a block, not of a method" unless ctx[:self_of].key?(label) && frame

    unless ctx[:constructor_entries].captured_local_writers_absent?
      return "#{where}: a local may be written by name (binding, local_variable_set or eval reachable)"
    end

    reg = index.to_s
    prog = BytecodeIR.for(frame)
    if BytecodeIR.own_upvar_written_regs(frame).include?(reg) || frame.instructions.any? { |i| prog.may_write?(i, reg) }
      return "#{where}: R#{reg} of #{ctx[:self_of][label]}##{ctx[:method_name][label]} is reassigned"
    end

    entry_why(ctx, frame, reg, cls)
  end

  # A checked `[T] ... { ... -> T } -> T` declaration (BLOCK_RETURNS: `RGSS::Profiler.section(...) { ... }`)
  # returns its literal block's value, and the block's exits are plain returns: every RETURN must be proven `cls`.
  def block_value_why(ctx, body, name, cls, depth)
    BytecodeIR.for(body).exits.each do |ex|
      idx = ex.index
      insn = body.instructions[idx]
      return "the block of #{name} at #{display(ctx, body.file)}:#{insn.lineno} exits by #{insn.op}" unless ex.op == 'RETURN'

      why = trace(ctx, body, idx, insn.reg, cls, depth + 1)
      return "the block of #{name} returns (#{why})" if why
    end
    nil
  end

  # `Klass.new(...)` of exactly `cls`, whose `new` nothing in the program overrides.
  def new_why(ctx, irep, idx, cls)
    overrides = ctx[:registry].fetch('new', []).reject { |d| d.owner == '<native>' }
    return "#{overrides.map(&:owner).join(', ')} define new" unless overrides.empty?

    owner = ctx[:owner_of][irep.label]
    found = trace_new_target(irep, idx + 1, irep.instructions[idx].reg, {}, 0, nil, owner: owner)
    found == cls ? nil : "`new` of #{found || 'an unresolved constant'}"
  end

  # A call is `cls` when every definition of its name either has a checked `-> cls` declaration or is an
  # attr_reader whose slot the ivar rule proves `cls` (a call that runs none of them raises NoMethodError and
  # returns nothing). A declaration counts when it is an entry of +declared_returns+: DECLARED_RETURN_CHECK aborts the build when a body does not prove it, and a %a{bc2cpp:hint} one raises at run time instead of
  # returning another type (DECLARED_RETURN_GUARD). A checked `-> cls?` gives a Nilable (the caller then needs
  # NIL_NARROWING at the use).
  def returns_why(ctx, name, cls, depth)
    defs = ctx[:registry].fetch(name, [])
    return "a call to #{name}, which the program does not define" if defs.empty?

    nilable = nil
    defs.each do |d|
      if d.kind == :ivar_accessor && d.irep.nil? && !name.end_with?('=')
        why = ivar_why(ctx, nil, name, cls, depth, owner: d.owner)
        return why if why

        next
      end
      entry = d.irep && ctx[:declared][d.irep]
      if entry && entry.kind == :class && entry.cls == cls
        nilable ||= Nilable.new("#{d.owner}##{name} declares -> #{cls}?") if entry.nilable
        next
      end

      ret = d.irep && ctx[:sig_of][d.irep]&.ret
      if ret && (ret.kind == :class ? ret.cls : ret.optional&.cls) == cls
        return "#{d.owner}##{name}'s -> #{ret.text} is not a checked declaration (no DECLARED_RETURN_CHECK entry)"
      end
      return "#{d.owner}##{name} does not declare -> #{cls}"
    end
    nilable
  end
end
