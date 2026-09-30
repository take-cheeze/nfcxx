# frozen_string_literal: true

# ARG_SHAPES (docs/adr/0265): direct calls for the argument shapes the
# mandatory/optional-only gates leave to dispatch. Callee side: a rest
# parameter (`def f(a, *r)`) and a block parameter (`&blk`, or a `yield`). Caller
# side: a literal block on a resolved callee, and a splat whose length is known
# (literal) or switched on (runtime).
#
# Prepended to CodeGen so it wraps compile_send's shared helpers
# (pure_mandatory_or_optional_arity?, optional_arity, direct_call_args,
# dynamic_dispatch_line) instead of editing every branch that uses them.
module ArgShapeCalls
  # Past any real call: the unbounded upper bound of a rest callee's arity.
  REST_ARGC_MAX = 0x7fff

  # Names that read the calling frame's state and that compiled code does not
  # model: a compiled callee that calls one sees the caller's frame, not its own.
  # `block_given?` and its alias `iterator?` (one cfunc in kernel.c) are modelled
  # (BLOCK_SEMANTICS, ADR 0266): they read the `bc2cpp_blk` parameter, see
  # compile_block_given.
  BLOCK_GIVEN_NAMES = %w[block_given? iterator?].freeze
  FRAME_READING_NAMES = %w[binding].freeze

  # `block_given?` / `iterator?` as a bare self call, at any block depth. Over-approximates
  # for a nested def, which only costs an unused block parameter.
  def block_given_reads?(irep, seen = Set.new.compare_by_identity)
    return false unless seen.add?(irep)
    return true if calls_block_given?(irep)

    (irep.reps || []).any? do |label|
      child = label && @ireps[label]
      child && block_given_reads?(child, seen)
    end
  end

  def calls_block_given?(irep)
    BytecodeIR.for(irep).instructions_with_op('SSEND0').any? { |insn| BLOCK_GIVEN_NAMES.include?(insn.sym) }
  end

  # `block_given?` is this frame's block being non-nil. A frame whose wrapper
  # does not extract the block (yields_block_param?, a declared `&blk`) cannot
  # answer it, so the method stays interpreted rather than answer false.
  # `insn` is already shifted into an inlined block body's register window, so
  # its register is used as is (a second `+ reg_offset` names an undeclared r<N>).
  def compile_block_given(insn)
    return "  #error unhandled block_given? -- this frame's block is not extracted (BLOCK_SEMANTICS)\n" unless @blk_param_name

    "  r#{insn.reg} = mrb_bool_value(!mrb_nil_p(#{@blk_param_name}));\n"
  end

  # The wrapper of this method extracts `bc2cpp_blk` (see compile_method).
  def frame_block_available?(irep)
    pure_mandatory_arity?(irep) || block_param_arity?(irep)
  end

  # Only mruby's own native `block_given?` and `iterator?` exist: a Ruby definition of
  # either name would be an ordinary method call.
  def block_given_modelled?
    BLOCK_GIVEN_NAMES.all? { |name| (@registry[name] || []).all? { |definition| definition.irep.nil? } }
  end

  # A block-taking callee is only sound as a frame-less direct call when its
  # body cannot observe the frame: no zsuper/super (they forward the block) and
  # no frame-reading self call, at any block depth.
  def block_transparent_callee?(irep, seen = Set.new.compare_by_identity)
    return true unless seen.add?(irep)
    return false if irep.instructions.any? { |insn| %w[SUPER ARGARY].include?(insn.op) }
    return false unless (self_call_targets(irep) & FRAME_READING_NAMES).empty?

    (irep.reps || []).all? do |label|
      child = label && @ireps[label]
      child.nil? || block_transparent_callee?(child, seen)
    end
  end

  # compile_method extracts `bc2cpp_blk` for a yield-only method: the
  # signature and the call sites must agree on this one predicate.
  def yields_block_param?(irep, regions = nil)
    return false unless pure_mandatory_arity?(irep)
    return true if irep.instructions.any? { |insn| insn.op == 'BLKPUSH' && insn.paren_value == '0' }
    return true if block_given_modelled? && block_given_reads?(irep)

    (regions || recognize_block_fallback_regions(irep, blk_available: true)).any? { |region| region[:needs_blk] }
  end

  # Whether the callee's `_impl` has a trailing `bc2cpp_blk` parameter.
  def takes_block_param?(irep)
    @takes_block_param_cache ||= {}.compare_by_identity
    @takes_block_param_cache.fetch(irep) do
      @takes_block_param_cache[irep] = block_param_arity?(irep) || yields_block_param?(irep) || optional_block_callee?(irep)
    end
  end

  # Only inside compile_send: the other users of the gate build their own
  # argument lists and cannot marshal a rest array or a block.
  # An unguarded by-name MONO to one of the new shapes is refused: the registry
  # does not list core Ruby-level definitions (`sort` in Enumerable), so a
  # unique name proves no receiver class. The send is compiled again without
  # by-name MONO, leaving the guarded, typed and self resolutions.
  def compile_send(*args, **kwargs)
    saved = [@extended_callee_shapes, @extended_shape_used, @no_by_name_mono]
    @extended_callee_shapes = true
    @extended_shape_used = false
    code = super
    if @extended_shape_used && !kwargs[:self_implicit] && code.include?("  // MONO :")
      @no_by_name_mono = true
      @call_block_direct_calls = 0 if @call_block_expr
      code = super
    end
    code
  ensure
    @extended_callee_shapes, @extended_shape_used, @no_by_name_mono = saved
  end

  def monomorphic_target(name)
    @no_by_name_mono ? nil : super
  end

  def pure_mandatory_or_optional_arity?(irep)
    ok = super || (@extended_callee_shapes &&
                   (block_only_callee?(irep) || rest_only_callee?(irep) || optional_block_callee?(irep)))
    ok && (!(@call_block_expr || takes_block_param?(irep)) || block_transparent_callee?(irep))
  end

  def optional_arity(irep)
    @extended_callee_shapes && rest_only_callee?(irep) ? REST_ARGC_MAX : super
  end

  # ENTER n:o:0:0:0:0:1:0 with the optional jump table compile_method models (CORE_BLOCK_OPT):
  # `any?(pattern = NONE, &block)`. Its `_impl` takes the optionals, then the block, then
  # `bc2cpp_given_opt`, which is the order direct_call_args builds.
  def optional_block_callee?(irep)
    !optional_block_arg_table(irep).nil?
  end

  # ENTER 1:0:0:0:0:0:1:0: mandatory positionals plus `&blk` only.
  def block_only_callee?(irep)
    enter = irep.enter
    return false unless enter

    _mand, opt, rest, post, kw, kwrest, block, noblock = enter.enter_fields
    block.positive? && [opt, rest, post, kw, kwrest, noblock].all?(&:zero?)
  end

  # ENTER 1:0:1:0:0:0:B:0: mandatory positionals plus `*rest` (and `&blk`).
  def rest_only_callee?(irep)
    enter = irep.enter
    return false unless enter

    _mand, opt, rest, post, kw, kwrest, _block, noblock = enter.enter_fields
    rest.positive? && [opt, post, kw, kwrest, noblock].all?(&:zero?)
  end

  # The `_impl` signature is mandatory..., rest Array, `bc2cpp_blk`, in that
  # order (compile_method). The rest Array is built fresh per call, as ENTER does.
  def direct_call_args(target, argv, impl)
    @call_block_direct_calls += 1 if @call_block_expr
    t_irep = @ireps.fetch(target.irep)
    rest = rest_only_callee?(t_irep)
    return super unless rest || takes_block_param?(t_irep)

    @extended_shape_used = true

    mand = mandatory_arity(t_irep)
    # The base implementation pads optionals up to optional_arity, which is
    # unbounded for a rest callee: it sees the plain shape.
    saved = @extended_callee_shapes
    @extended_callee_shapes = false
    begin
      head, note = super(target, rest ? argv.first(mand) : argv, impl)
    ensure
      @extended_callee_shapes = saved
    end
    head = head.dup
    if rest
      extra = argv.drop(mand)
      head << if extra.empty?
                'mrb_ary_new(M)'
              else
                "({ mrb_value bc2cpp_rest[] = { #{extra.join(', ')} }; " \
                  "mrb_ary_new_from_values(M, #{extra.size}, bc2cpp_rest); })"
              end
    end
    head.insert(mand + (rest ? 1 : positional_optional_count(t_irep)), @call_block_expr || 'mrb_nil_value()') if takes_block_param?(t_irep)
    [head, note]
  end

  def positional_optional_count(irep)
    irep.enter ? irep.enter.enter_fields[1] : 0
  end

  # With a literal block in flight every dispatch this site emits must carry
  # it; a block-less funcall would silently drop the block.
  def dynamic_dispatch_line(d, recv, name, argv)
    return super unless @call_block_expr

    args = argv.empty? ? 'NULL' : 'bc2cpp_blk_argv'
    call = "r#{d} = mrb_funcall_with_block(M, #{recv}, mrb_intern_cstr(M, \"#{name}\"), #{argv.size}, #{args}, " \
           "#{@call_block_expr});"
    return "#{call}\n" if argv.empty?

    "{ mrb_value bc2cpp_blk_argv[] = { #{argv.join(', ')} }; #{call} }\n"
  end

  # A chain arm calls `_impl(M, recv, args)` with no block slot.
  def poly_candidates(name, n, **options)
    candidates = super
    return candidates unless candidates

    kept = candidates.reject { |target| target.irep && takes_block_param?(@ireps.fetch(target.irep)) }
    kept.empty? ? nil : kept
  end

  # Native arms and outlined tables know nothing of the block.
  def native_core_entries(name, arity)
    @call_block_expr ? [] : super
  end

  def native_direct_plan(name, arity, closed_world_site:)
    @call_block_expr ? nil : super
  end

  def compile_poly_small_n(*args, **kwargs)
    @call_block_expr ? nil : super
  end

  def compile_poly_table(*args, **kwargs)
    @call_block_expr ? nil : super
  end

  def compile_keywordless_call(**kwargs)
    @call_block_expr ? nil : super
  end

  # A nested compile (compiles_clean? -> compile_method) is a different call
  # site: it must not inherit this one's block.
  def with_fresh_method_state
    saved = [@call_block_expr, @call_block_direct_calls, @extended_callee_shapes, @no_by_name_mono, @call_block_region]
    @call_block_expr = nil
    @call_block_direct_calls = 0
    @extended_callee_shapes = false
    @no_by_name_mono = false
    @call_block_region = nil
    super
  ensure
    @call_block_expr, @call_block_direct_calls, @extended_callee_shapes, @no_by_name_mono, @call_block_region = saved if saved
  end

  # ARG_SHAPES_BLOCK: the SENDB `region` (a literal block already built into
  # `block_expr`) as a call compile_send resolves to compiled code, or nil to
  # keep dispatch. compile_send runs as if for a plain send with the block
  # threaded through; the result is accepted only when every direct call in it
  # went through direct_call_args (so carries the block) and no block-less
  # dynamic call remains.
  def compile_direct_block_send(region, block_expr, owner_def)
    with_private_poly_diag_cache { compile_direct_block_send_body(region, block_expr, owner_def) }
  end

  # An attempt that is dropped must not leave its diagnostic reasons behind: a
  # reason cached mid-compile of the callee itself says "unclean" for a method
  # that is fine once it finishes.
  def with_private_poly_diag_cache
    saved = @poly_diagnostic_reason_cache
    @poly_diagnostic_reason_cache = {}
    yield
  ensure
    @poly_diagnostic_reason_cache = saved
  end

  def compile_direct_block_send_body(region, block_expr, owner_def)
    irep = region[:parent_irep]
    return nil unless irep && owner_def

    idx = irep.instructions.index { |insn| insn.addr == region[:sendb_addr] }
    return nil unless idx

    insn = Insn.synthetic(region[:self_implicit] ? 'SSEND' : 'SEND',
                          "R#{region[:dest_reg]} :#{region[:name]} n=#{region[:n]}")
    saved = [@call_block_expr, @call_block_direct_calls, @call_block_region]
    @call_block_expr = block_expr
    @call_block_direct_calls = 0
    @call_block_region = region
    begin
      code = compile_send(insn, self_implicit: region[:self_implicit], irep: irep, idx: idx, owner_def: owner_def)
      accepted = direct_block_code?(code, @call_block_direct_calls)
    ensure
      @call_block_expr, @call_block_direct_calls, @call_block_region = saved
    end
    accepted ? code : nil
  end

  def direct_block_code?(code, direct_calls)
    return false if direct_calls.zero?

    live = code.lines.reject { |line| line.lstrip.start_with?('//') }.join
    live.scan('_impl(M').size == direct_calls && !live.match?(/\bmrb_funcall(_argv|_id)?\(/) &&
      !live.include?('#error')
  end

  # ARG_SHAPES_SPLAT: a splat call site (`f(*a)`) with a resolved target. A
  # literal-sized splat is an ordinary n-argument call; a runtime-sized one
  # switches on the Array length into the same calls, dynamic for any other
  # length (which is where an ArgumentError comes from).
  def compile_splat_send(insn, self_implicit:, irep:, idx:, name:, d:, owner_def: nil)
    if irep && idx && owner_def && insn.n_spec == '*' && insn.nk_spec.nil?
      direct = compile_splat_direct(insn, self_implicit: self_implicit, irep: irep, idx: idx, name: name, d: d,
                                          owner_def: owner_def)
      return direct if direct
    end
    super
  end

  SPLAT_SWITCH_MAX_ARMS = 8

  def compile_splat_direct(insn, self_implicit:, irep:, idx:, name:, d:, owner_def:)
    return nil unless %w[SEND SSEND].include?(insn.op)

    args_reg = d.to_i + 1
    literal = splat_array_literal_regs(irep, idx, args_reg.to_s)
    return splat_send_with(name, d, self_implicit, irep, idx, owner_def, literal, 'literal-sized splat') if literal

    counts = splat_arities(name)
    return nil if counts.empty?

    ary = "bc2cpp_splat_ary_#{d}"
    arms = counts.filter_map do |k|
      locals = (0...k).map { |i| "bc2cpp_splat_#{d}_#{i}" }
      code = splat_send_with(name, d, self_implicit, irep, idx, owner_def, locals, nil)
      next unless code

      "    case #{k}: {\n" \
        "#{locals.each_with_index.map { |l, i| "      mrb_value #{l} = RARRAY_PTR(#{ary})[#{i}];\n" }.join}" \
        "#{code.lines.map { |line| "      #{line}" }.join}" \
        "      break;\n    }\n"
    end
    return nil if arms.empty?

    recv = self_implicit ? 'self' : "r#{d}"
    "  // SPLAT n=* :#{name} runtime-sized: direct arms for argument counts #{counts.join('/')} " \
      "(mrb_ary length), dynamic dispatch for any other length\n" \
      "  {\n" \
      "    mrb_value #{ary} = r#{args_reg};\n" \
      "    switch (RARRAY_LEN(#{ary})) {\n" \
      "#{arms.join}" \
      "    default:\n" \
      "      r#{d} = bc2cpp_funcall_argv(M, #{recv}, mrb_intern_cstr(M, \"#{name}\"), RARRAY_LEN(#{ary}), " \
      "RARRAY_PTR(#{ary}));\n" \
      "    }\n" \
      "  }\n"
  end

  # The compile_send code for `name` with `argv` as its arguments, when it
  # reaches compiled code; nil when it would only dispatch.
  def splat_send_with(name, d, self_implicit, irep, idx, owner_def, argv, note)
    insn = Insn.synthetic(self_implicit ? 'SSEND' : 'SEND', "R#{d} :#{name} n=#{argv.size}")
    code = with_private_poly_diag_cache do
      compile_send(insn, self_implicit: self_implicit, irep: irep, idx: nil, owner_def: owner_def,
                         call_arguments: argv, trace_idx: idx, trace_reg_offset: 0)
    end
    return nil unless code.include?('_impl(M') && !code.include?('#error')

    note ? "  // SPLAT n=* :#{name} unrolled from a #{note}\n#{code}" : code
  end

  # Argument counts some bytecode definition of `name` accepts.
  def splat_arities(name)
    counts = (@registry[name] || []).select(&:irep).flat_map do |definition|
      t_irep = @ireps.fetch(definition.irep)
      mand = mandatory_arity(t_irep)
      max = rest_only_callee?(t_irep) ? mand + 4 : mand + positional_optional_count(t_irep)
      (mand..max).to_a
    end
    counts.uniq.sort.first(SPLAT_SWITCH_MAX_ARMS)
  end
end

CodeGen.prepend(ArgShapeCalls)
