# frozen_string_literal: true

# CodeGen: blocks that stay procs, and fiber safety.

class CodeGen
  # BLOCK_CFUNC_FALLBACK_SUPPORT: recognize BLOCK/SENDB(SSENDB) regions not
  # claimed by a named inliner (compile_method filters by `suppressed`). Any
  # method name qualifies; the gate is that the block BODY can run standalone
  # (block_fallback_safe?). vm.c OP_SENDB puts the block at `a + c + 1`, so a
  # BLOCK at `dest + n + 1` is the layout checked (see
  # EXPLICIT_ARGS_BLOCK_FALLBACK_SUPPORT below). recognize_lambda_fallback_regions
  # is the LAMBDA sibling.
  #
  # block_fallback_region_has_return_blk?, NESTED_BLOCK_FALLBACK_SUPPORT: does
  # the region's body contain a RETURN_BLK at any depth, including inside its own
  # nested regions? needs_return_catch needs the whole-subtree answer; a nested
  # `return` always throws bc2cpp_method_return and must find the top-level
  # catch.
  def block_fallback_region_has_return_blk?(region)
    block_irep = region[:block_irep]
    return true if block_irep.instructions.any? { |i| i.op == 'RETURN_BLK' }

    # DEEP_UPVAR_CAPTURE_SUPPORT: `available_upvars` must be the same set
    # emit_proc_fallback_fn will use for this body; a pre-scan recognizing fewer
    # nested regions could miss a RETURN_BLK and leave the throw uncaught
    # (std::terminate). One shared expression.
    recognize_block_fallback_regions(block_irep, available_upvars: region[:upvars] || [])
      .any? { |nregion| block_fallback_region_has_return_blk?(nregion) }
  end

  # DEEP_UPVAR_CAPTURE_SUPPORT: every enclosing-scope register this irep needs,
  # including those only its nested blocks reference, as [level, index] pairs
  # (level as GETUPVAR/SETUPVAR count it, 0 = the immediately enclosing scope).
  # A block that references nothing itself must still capture what a nested
  # block needs: in quads_from_quarters the outer `2.times do |j|` has no
  # GETUPVAR while the inner one reads the method's `quarters`/`out` at level 1,
  # which resolves through the outer block's captured pointers. So a child's
  # [l, x] contributes [l - 1, x] here for l >= 1 (level 0 is this irep's own
  # locals), recursively.
  # Every child irep is walked, not only those that will be compiled: an extra
  # capture costs an unused slot, a missing one is a dangling C++ name. A region
  # that then needs a pointer its frame cannot supply is declined by the
  # recognizer (stays `#error`); named inliners claim their sites first.
  # nil means not modelable. MAX_UPVAR_NEST_DEPTH only guards pathological
  # graphs.
  MAX_UPVAR_NEST_DEPTH = 16

  def block_upvar_needs(irep, depth = 0)
    return nil if depth > MAX_UPVAR_NEST_DEPTH

    needs = []
    irep.instructions.each do |insn|
      next unless %w[GETUPVAR SETUPVAR].include?(insn.op)

      _reg, upvar_idx, level = insn.args.split(/\s+/)
      return nil unless upvar_idx =~ /\A\d+\z/ && level =~ /\A\d+\z/

      needs << [level.to_i, upvar_idx.to_i]
    end
    (irep.reps || []).each do |child_label|
      child = child_label && @ireps[child_label]
      next unless child

      child_needs = block_upvar_needs(child, depth + 1)
      return nil if child_needs.nil?

      child_needs.each { |(l, x)| needs << [l - 1, x] if l >= 1 }
    end
    needs.uniq.sort
  end

  # BLOCK_FALLBACK_YIELD_SUPPORT: which enclosing frames' received blocks does
  # this irep (or anything nested) need for its `yield`s? LCF::Array2D#each:
  #
  #     irep (method each)  nregs=4 nlocals=2      -- R1 is the block slot
  #       GETIV R2 @data / SEND0 R2 :size
  #       BLOCK R3 I[0] / SENDB R2 :times n=0
  #     irep (block |i|)    nregs=8 nlocals=4  R1:i  R3:v
  #       ...
  #       BLKPUSH  R4  0:0:0:0 (1)     ; <-- lv == 1
  #       BLKCALL  R4  2
  #
  # versus a method's own `yield` (`BLKPUSH R2 0:0:0:0 (0)`, lv == 0). vm.c
  # OP_BLKPUSH decodes `lv=(b>>0)&0xf`, then `if (lv == 0) stack = regs + 1; else
  # { struct REnv *e = uvenv(mrb, lv-1); ... stack = e->stack + 1; }`, so lv
  # names a frame like GETUPVAR's level. codegen_yield computes lv by walking out
  # to the first METHOD scope:
  #
  #     int lv = 0; codegen_scope *s2 = s;
  #     while (!s2->mscope) { lv++; s2 = s2->prev; if (!s2) break; }
  #
  # so inside a block lv >= 1 and always lands on the enclosing method (a yield
  # outside a method is a SyntaxError).
  # Returns the sorted set of levels this frame must supply, with
  # block_upvar_needs' propagation (a child's l becomes l - 1 for l >= 1; a
  # child's l == 0 is a nested def's own block). nil means an unparsable BLKPUSH.
  def block_blk_needs(irep, depth = 0)
    return nil if depth > MAX_UPVAR_NEST_DEPTH

    needs = []
    irep.instructions.each do |insn|
      next unless insn.op == 'BLKPUSH'

      lv = insn.args[/\((\d+)\)\s*\z/, 1]
      return nil unless lv

      needs << lv.to_i
    end
    (irep.reps || []).each do |child_label|
      child = child_label && @ireps[child_label]
      next unless child

      child_needs = block_blk_needs(child, depth + 1)
      return nil if child_needs.nil?

      child_needs.each { |l| needs << l - 1 if l >= 1 }
    end
    needs.uniq.sort
  end

  # FIBER_NEW_BLOCK_UNSAFE_SUPPORT: `Fiber.new { ... }` must never go through
  # BLOCK_FALLBACK. mruby-fiber's init_fiber raises FiberError for a cfunc-backed
  # RProc (MRB_PROC_CFUNC_P), and removing that check would not help: fiber
  # resume saves/restores a bytecode pc in the proc's irep
  # (`mrb_vm_exec(mrb, c->ci->proc, c->ci->pc)`, and init_fiber reads
  # `p->body.irep->nregs`), which a cfunc proc does not have. So the region is
  # not admitted; the unclaimed BLOCK/SENDB gets `#error` and the method stays
  # interpreted (tools/optcarrot_probe/README.md, Optcarrot::PPU#run).
  # Matches a bare `GETCONST ... Fiber` in the receiver register, following
  # MOVEs only. A miss only means the site is treated as before. Generic name
  # because calls_fiber_yield? reuses it for a plain SEND receiver.
  def fiber_const_receiver?(irep, call_idx, dest_reg)
    reg = dest_reg
    (call_idx - 1).downto(0) do |i|
      insn = irep.instructions[i]
      case insn.op
      when 'MOVE'
        d, s = insn.args.scan(/R(\d+)/).flatten
        next unless d == reg

        reg = s
      when 'GETCONST'
        d = insn.args[/^R(\d+)/, 1]
        next unless d == reg

        return insn.args.split(/\s+/)[1] == 'Fiber'
      else
        d = insn.args[/^R(\d+)/, 1]
        return false if d == reg
      end
    end
    false
  end

  # FIBER_YIELD_UNSAFE_SUPPORT: `Fiber.yield` is a plain SEND (`GETCONST R2
  # Fiber` + `SEND R2 :yield n=1`), so it would compile as an ordinary call into
  # mrb_fiber_yield from a native compiled frame. mruby's reentrant fiber-resume
  # path (fiber_switch/fiber_resume) breaks with a VM-invisible native frame
  # between the fiber entry and the yield ("resuming dead fiber"; see
  # tools/optcarrot_probe/README.md). A method that calls Fiber.yield directly
  # gets an early `#error` stub. Transitive callers are handled by
  # compute_fiber_unsafe_methods.
  def calls_fiber_yield?(irep)
    irep.instructions.each_with_index do |insn, idx|
      next unless %w[SEND SEND0].include?(insn.op)

      name = insn.args[/:([\w+\-*\/<>=!?\[\]&|^~%@]+)/, 1]
      next unless name == 'yield'

      dest_reg = insn.args[/^R(\d+)/, 1]
      next unless dest_reg
      next unless fiber_const_receiver?(irep, idx, dest_reg)

      return true
    end
    false
  end

  # FIBER_REACHABILITY_UNSAFE_SUPPORT: refusing direct Fiber.yield callers is not
  # enough: any compiled frame between the fiber entry and a yield breaks resume
  # (Optcarrot::PPU#main_loop, which calls the yielding methods, still crashed).
  # This takes the transitive closure from every `Fiber.new { }` block body over
  # self-implicit sends (SSEND/SSEND0/SSENDB) to methods of the SAME owner, and
  # refuses every method reached.
  # Same-owner self-sends only: every real call in a fiber body here has that
  # shape. An explicit-receiver call leaving the class is a known gap (none
  # exists); missing one reproduces the loud FiberError, never a silent wrong
  # answer.
  def compute_fiber_unsafe_methods
    by_owner_name = {} # [owner, name] -> irep label, registered methods only
    irep_owner = {} # irep label -> owner, registered methods AND every block nested inside them
    @registry.each_value do |defs|
      defs.each do |d|
        next unless d.irep

        by_owner_name[[d.owner, d.name]] = d.irep
        irep_owner[d.irep] = d.owner
      end
    end

    # A block shares its method's self/owner, so propagating owners down nested
    # block ireps is exact; a Fiber.new seed several blocks deep resolves
    # correctly.
    propagate = irep_owner.keys.dup
    until propagate.empty?
      label = propagate.shift
      irep = @ireps[label]
      next unless irep

      owner = irep_owner[label]
      (irep.reps || []).each do |child_label|
        next unless child_label
        next if irep_owner.key?(child_label)

        irep_owner[child_label] = owner
        propagate << child_label
      end
    end

    seeds = []
    @ireps.each_value do |irep|
      irep.instructions.each_with_index do |insn, idx|
        next unless insn.op == 'BLOCK'

        paired = irep.instructions[idx + 1]
        next unless paired && paired.op == 'SENDB'
        next unless paired.args[/:([\w+\-*\/<>=!?\[\]&|^~%@]+)/, 1] == 'new'

        dest_reg = paired.args[/^R(\d+)/, 1]
        next unless dest_reg && fiber_const_receiver?(irep, idx, dest_reg)

        block_irep_idx = insn.args[/I\[(\d+)\]/, 1]
        next unless block_irep_idx

        block_label = irep.reps[block_irep_idx.to_i]
        seeds << block_label if block_label
      end
    end

    unsafe = Set.new
    # SEEDS_MULTIPLE_OWNERS_SUPPORT: resolve each seed's owner separately.
    queue = seeds.flat_map do |label|
      seed_irep = @ireps[label]
      next [] unless seed_irep

      owner = irep_owner[label]
      next [] unless owner

      self_call_targets(seed_irep).filter_map { |name| by_owner_name[[owner, name]] }
    end
    until queue.empty?
      label = queue.shift
      next unless unsafe.add?(label)

      irep = @ireps[label]
      next unless irep

      owner = irep_owner[label]
      next unless owner

      self_call_targets(irep).each do |name|
        target = by_owner_name[[owner, name]]
        queue << target if target
      end
    end
    @fiber_unsafe_methods = unsafe
  end

  # Every self-send name reachable from `irep`, including inside nested block
  # ireps (a block body is part of the method that contains it).
  def self_call_targets(irep, seen = Set.new.compare_by_identity)
    return [] unless seen.add?(irep)

    names = []
    irep.instructions.each do |insn|
      next unless %w[SSEND SSEND0 SSENDB].include?(insn.op)

      name = insn.args[/:([\w+\-*\/<>=!?\[\]&|^~%@]+)/, 1]
      names << name if name
    end
    (irep.reps || []).each do |child_label|
      child = child_label && @ireps[child_label]
      names.concat(self_call_targets(child, seen)) if child
    end
    names
  end

  def recognize_block_fallback_regions(irep, available_upvars: [], blk_available: false)
    regions = []
    irep.instructions.each_with_index do |insn, idx|
      next unless insn.op == 'BLOCK'

      paired = irep.instructions[idx + 1]
      next unless paired && %w[SENDB SSENDB].include?(paired.op)

      # EXPLICIT_ARGS_BLOCK_FALLBACK_SUPPORT: any fixed positional count
      # (`ary.inject(0) { }`, `ary.each_slice(2) { }`), but never `n=*` (a splat has
      # no static layout) and never a keyword call (`n=3|nk=1`):
      # mrb_funcall_with_block cannot carry keywords (`ci->nk = 0` in
      # funcall_args_capture).
      n_match = paired.args.match(/n=(\d+)(?:\s|$)/)
      next unless n_match

      n = n_match[1].to_i
      dest, _rest = paired.args.split(/\s+/, 2)
      dest_reg = dest[/^R(\d+)/, 1]
      block_reg = insn.args[/^R(\d+)/, 1]
      # Layout: dest, n positional args, then the block (`BLOCK R4` + `SENDB R2
      # :reduce n=1`), so the block is at dest + n + 1.
      next unless dest_reg && block_reg && block_reg == (dest_reg.to_i + n + 1).to_s

      name = paired.args[/:([\w+\-*\/<>=!?\[\]&|^~%@]+)/, 1]
      next unless name

      # FIBER_NEW_BLOCK_UNSAFE_SUPPORT: never admit `Fiber.new { ... }`.
      next if paired.op == 'SENDB' && name == 'new' && fiber_const_receiver?(irep, idx, dest_reg)

      block_irep_idx = insn.args[/I\[(\d+)\]/, 1]
      next unless block_irep_idx

      block_label = irep.reps[block_irep_idx.to_i]
      block_irep = block_label && @ireps[block_label]
      next unless block_irep && block_fallback_safe?(block_irep)

      upvars = block_upvar_needs(block_irep)
      next if upvars.nil?

      # DEEP_UPVAR_CAPTURE_SUPPORT: a level-0 need is always suppliable (a local of
      # this function, `&r<idx>`). A level-L need (L >= 1) can only be forwarded if
      # this function already holds it, i.e. [L - 1, idx] is in `available_upvars`
      # (empty at method level, so L >= 1 is refused there). block_upvar_needs'
      # propagation should make this hold; it stays a real gate so any uncovered
      # shape keeps `#error` instead of a dangling name.
      next unless upvars.all? { |(l, x)| l.zero? || available_upvars.include?([l - 1, x]) }

      # UPVAR_CAPTURE_SUPPORT: a non-empty capture set requires the call's method to
      # be in BLOCK_FALLBACK_UPVAR_SAFE_METHODS (synchronous, never stores the
      # block); an empty one needs no gate.
      # DEEP_UPVAR_CAPTURE_SUPPORT: a forwarded deeper pointer stays valid because
      # every level in between passed this same gate (a forwarding outer site has a
      # non-empty capture set), so the whole frame chain is live while the inner
      # block runs.
      next if upvars.any? && !BLOCK_FALLBACK_UPVAR_SAFE_METHODS.include?(name)

      # BLOCK_FALLBACK_YIELD_SUPPORT: does this body's `yield` need the enclosing
      # method's block forwarded into the cfunc? Only `[1]` is modelled (every
      # BLKPUSH in the subtree resolves to the frame this call site is in, whose
      # block is a C++ local here). Deeper needs keep `#error` (none exist).
      # `blk_available` is true only from compile_method's top level, for methods
      # whose wrapper extracts a block (the same mandatory_ok condition as
      # needs_blk_param).
      # `needs_blk` never gates admission: an unanswerable BLKPUSH still fails on its
      # own `#error` in emit_proc_fallback_fn.
      # The synchronous allowlist is required here too: the captured block is an
      # mrb_value copy (GC-rooted by the env), but it is an irep-backed RProc whose
      # own env is on the caller's stack, so invoking it after that caller returned
      # would be an escaped block (vm.c raises "unexpected yield" for that).
      blk_needs = block_blk_needs(block_irep)
      needs_blk = blk_available && blk_needs == [1] &&
                  BLOCK_FALLBACK_UPVAR_SAFE_METHODS.include?(name)

      regions << { block_addr: insn.addr, sendb_addr: paired.addr, dest_reg: dest_reg,
                   block_irep: block_irep, name: name, n: n,
                   self_implicit: paired.op == 'SSENDB', upvars: upvars, needs_blk: needs_blk,
                   parent_irep: irep }
    end
    regions
  end

  # BLOCK_FALLBACK_ELEMENT_SUPPORT: pass an exact element class into the cfunc
  # only for a known Array or Hash iterator with a proven yield shape; otherwise
  # dynamic dispatch.
  def block_fallback_element_class(irep, region, owner_name)
    return nil unless irep && !region[:self_implicit]

    shape = case region[:name]
            when 'each' then [:array, 0, 1]
            when 'each_with_index' then [:array, 0, 2]
            when 'each_with_object' then [:array, 1, 2]
            when 'each_value' then [:hash, 0, 1]
            end
    return nil unless shape && region[:n] == shape[1]
    return nil unless mandatory_arity(region[:block_irep]) == shape[2]

    idx = irep.instructions.index { |insn| insn.addr == region[:sendb_addr] }
    return nil unless idx

    insn = irep.instructions[idx]
    return nil unless insn.op == 'SENDB'

    mand = mandatory_arity(irep)
    ivar_classes = @class_layout[owner_name] || {}
    arg_classes = @class_annotations[irep.label]&.args
    recv_class = trace_new_target(irep, idx, region[:dest_reg], ivar_classes, mand, arg_classes,
                                  owner: owner_name, class_layout: @class_layout, registry: @registry,
                                  container_constants: @container_constants,
                                  element_annotations: @element_annotations)
    if shape[0] == :array
      recv_class = proven_array_source(irep, idx, region[:dest_reg]) unless recv_class == 'Array'
      return nil unless recv_class == 'Array'

      proven_element_class(irep, idx, region[:dest_reg], ivar_classes, mand, arg_classes, owner_name)
    else
      return nil unless recv_class == 'Hash'

      proven_hash_element_class(irep, idx, region[:dest_reg], ivar_classes, mand, arg_classes, owner_name)
    end
  end

  # BLOCK_CFUNC_FALLBACK_SUPPORT / LAMBDA_FALLBACK_SUPPORT: the body's standalone
  # `_impl` plus an mrb_func_t entry (`mrb_value(mrb_state*, mrb_value)`, as
  # mrb_proc_new_cfunc_with_env requires) that reads the arguments with
  # mrb_get_args. A cfunc proc, yielded or `.call`ed, gets its arguments on the
  # VM stack like an ordinary call (vm.c exec_irep: `ci->stack[0] = self; return
  # MRB_PROC_CFUNC(p)(mrb, self);`). Shared by both recognizers; it only uses
  # region[:block_irep] and region[:block_addr].
  # SELF_CAPTURE_SUPPORT: the `self` mruby passes is ignored (nil for a cfunc
  # proc, see block_fallback_safe?); the real self is read from env slot 0,
  # filled by emit_rproc_construction.
  # A runtime-def/EXEC body's self is its receiver, not an instance of d.owner
  # (nested blocks inherit that), so self-ivar codegen must not assume d.owner.
  def emit_proc_fallback_fn(region, d, fn_prefix = nil)
    saved_self_class_unknown = @self_class_unknown
    @self_class_unknown = saved_self_class_unknown || runtime_def_fallback_kind?(region[:kind])
    emit_proc_fallback_fn_body(region, d, fn_prefix)
  ensure
    @self_class_unknown = saved_self_class_unknown
  end

  def emit_proc_fallback_fn_body(region, d, fn_prefix)
    block_irep = region[:block_irep]
    mand = mandatory_arity(block_irep)
    arg_names = (1..mand).map { |i| "bc2cpp_barg#{i}" }
    # UPVAR_CAPTURE_SUPPORT: region[:upvars] comes from
    # recognize_block_fallback_regions, or from recognize_lambda_fallback_regions
    # for a frame-confined lambda (lambda_proc_frame_confined?). `|| []` is the
    # plain no-upvars case.
    # DEEP_UPVAR_CAPTURE_SUPPORT: entries are [level, index] (see
    # upvar_var_name); level 0 keeps the old spelling.
    upvar_regs = region[:upvars] || []
    upvar_params = upvar_regs.map { |(l, b)| "mrb_value* #{upvar_var_name(l, b)}" }
    # BLOCK_FALLBACK_YIELD_SUPPORT: only recognize_block_fallback_regions sets
    # needs_blk; a lambda can escape the frame whose block it would capture.
    needs_blk = region[:needs_blk] ? true : false
    blk_param = needs_blk ? ['mrb_value bc2cpp_blk'] : []
    # Function names: block_addr is unique only within one irep, so prefix with
    # cpp_name(d.owner, d.name) (as emit_rescue_try_body does); `region[:kind]` is
    # only for readability.
    # NESTED_BLOCK_FALLBACK_SUPPORT: for a nested region `fn_prefix` is the outer
    # level's unique fn_name, since a nested block_addr lives in the block irep's
    # own address space.
    fn_name = "#{fn_prefix || cpp_name(d.owner, d.name)}_#{region[:kind] || 'block_fallback'}_#{region[:block_addr]}"
    impl_name = "#{fn_name}_impl"

    # NESTED_BLOCK_FALLBACK_SUPPORT: recursively run recognize ->
    # emit_proc_fallback_fn -> emit_block_fallback_glue on regions nested in this
    # body. Runs BEFORE this level sets @block_fallback_upvars/
    # @block_fallback_active: the recursive call sets, uses and clears its own
    # first. `nested_pre` is prepended so nested functions are defined first.
    nested_pre = String.new
    nested_suppressed = []
    nested_glue_at = {}
    # BLOCK_FALLBACK_RESCUE_SUPPORT: claim rescue ranges in `nested_suppressed`
    # before the nested BLOCK_FALLBACK pass, so block calls inside a rescue belong
    # to the rescue's own pass. The extraction itself must wait until the ivars are
    # set (its compile_insn calls need them), while the nested pass must run before;
    # splitting claim from emit satisfies both.
    rescue_regions = top_level_rescue_regions(recognize_rescue_regions(block_irep))
    rescue_regions.each do |rregion|
      nested_suppressed.concat((rregion[:begin_addr]..rregion[:end_addr]).to_a)
      nested_suppressed << rregion[:except_addr]
    end
    # DEEP_UPVAR_CAPTURE_SUPPORT: this body's own captured set, which nested
    # regions may forward.
    recognize_block_fallback_regions(block_irep, available_upvars: upvar_regs).each do |nregion|
      # BLOCK_FALLBACK_RESCUE_SUPPORT: regions inside a rescue range belong to that
      # range's own pass (emit_rescue_try_body); emitting them here too would
      # duplicate them.
      next if nested_suppressed.include?(nregion[:block_addr]) || nested_suppressed.include?(nregion[:sendb_addr])

      fn_result = emit_proc_fallback_fn(nregion, d, fn_name)
      next unless fn_result

      nfn_name, nfn_code = fn_result
      nested_pre << nfn_code
      nested_suppressed << nregion[:block_addr] << nregion[:sendb_addr]
      nested_glue_at[nregion[:block_addr]] = emit_block_fallback_glue(nregion, nfn_name)
    end
    # EXPLICIT_BLOCK_ARG_SUPPORT: `&expr` sites in this body: suppress/glue only,
    # no body to compile.
    recognize_explicit_block_arg_regions(block_irep).each do |nregion|
      next if nested_suppressed.include?(nregion[:sendb_addr])

      nested_suppressed << nregion[:sendb_addr]
      nested_glue_at[nregion[:sendb_addr]] = emit_explicit_block_arg_glue(nregion)
    end

    # RUNTIME_DEF_FALLBACK_SUPPORT: a `def` inside an EXEC-opened class body
    # (`class << Graphics; def update; ...; end; end`) is a TDEF whose I[c] body is
    # compiled by the same recursive emit_proc_fallback_fn (self_source:
    # :receiver, kind tdef_fallback) and installed by emit_tdef_fallback_glue.
    # Only inside exec_fallback: TDEF needs self to be the target class, which
    # OP_EXEC guarantees; inside a block or lambda, check_target_class follows the
    # lexical scope the proc was built in, which compiled code cannot see.
    # Runs before the ivars are set, like the nested pass above.
    if region[:kind] == 'exec_fallback'
      block_irep.instructions.each do |tinsn|
        next unless tinsn.op == 'TDEF'
        next if nested_suppressed.include?(tinsn.addr)

        tregion = tdef_fallback_region(tinsn, block_irep)
        next unless tregion

        tfn_result = emit_proc_fallback_fn(tregion, d, fn_name)
        next unless tfn_result

        tfn_name, tfn_code = tfn_result
        nested_pre << tfn_code
        nested_suppressed << tinsn.addr
        nested_glue_at[tinsn.addr] = emit_tdef_fallback_glue(tregion, tfn_name)
      end
    end

    # ALL_OR_NOTHING_SUPPORT: a body with any `#error` produces no region (as
    # every emitter here). compiles_clean? would reject the enclosing method
    # anyway, but the region would still be miscounted as a BLOCK_FALLBACK win in
    # the coverage diagnostic.
    # UPVAR_CAPTURE_SUPPORT: set for this one body loop only and cleared after, so
    # GETUPVAR/SETUPVAR only see names this function declares.
    @block_fallback_upvars = upvar_regs
    # EXCEPTION_BREAK_SUPPORT: selects BREAK's translation: LAMBDA_FALLBACK keeps a
    # plain return (strict proc), BLOCK_FALLBACK throws.
    # RUNTIME_DEF_FALLBACK_SUPPORT: method and class bodies must not get the
    # throwing BREAK (see RUNTIME_DEF_FALLBACK_KINDS). An explicit membership test
    # on the two kinds that set it (nil and 'block_fallback'), so new kinds are
    # opted out by default; the runtime_def_fallback_kind? assertion states the
    # same fact the other way round.
    raise "unexpected self_source for #{region[:kind]}" if
      runtime_def_fallback_kind?(region[:kind]) && region[:self_source] != :receiver
    @block_fallback_active = [nil, 'block_fallback'].include?(region[:kind])
    # BLOCK_FALLBACK_YIELD_SUPPORT: gates BLKPUSH. Saved and restored, not cleared:
    # compile_method sets @blk_param_name too and this function recurses. Level 1
    # only, matching the admitted `blk_needs == [1]` (`BLKPUSH Rx m1:r:m2:kd (1)`).
    saved_blk_param_name = @blk_param_name
    saved_blk_param_level = @blk_param_level
    @blk_param_name = needs_blk ? 'bc2cpp_blk' : nil
    @blk_param_level = 1
    # BLOCK_FALLBACK_RESCUE_SUPPORT: a `rescue` inside the block body
    # (`cached_bitmap(cache, key) { Bitmap.new(...) rescue StandardError => e;
    # ...; end }`) uses the top-level rescue machinery unchanged. Must run AFTER the
    # ivars are set (emit_rescue_try_body's compile_insn calls need them).
    # `extra_fields`/`extra_field_values` pass the captured upvar pointers into the
    # try body under the same names. arg_names and all-nil native types match the
    # block's `_impl`. `rescue_regions` is the list computed above.
    rescue_regions.each_with_index do |rregion, i|
      try_name = "#{impl_name}_rescue_try#{rescue_regions.size > 1 ? "_#{i}" : ''}"
      # BLOCK_FALLBACK_YIELD_SUPPORT: the forwarded block goes into the try body via
      # `extra_fields` too, as an mrb_value (OP_BLKPUSH only reads it), named
      # `bc2cpp_blk`, which @blk_param_name refers to.
      extra_fields = upvar_regs.map { |(l, b)| { name: upvar_var_name(l, b), c_type: 'mrb_value*' } }
      extra_fields += [{ name: 'bc2cpp_blk', c_type: 'mrb_value' }] if needs_blk
      saved = rescue_entry_saved_fields(block_irep, rregion)
      nested_pre << emit_rescue_try_body(try_name, rregion, block_irep, d, arg_names, Array.new(arg_names.size),
                                          extra_fields: extra_fields + saved, available_upvars: upvar_regs)
      nested_glue_at[rregion[:begin_addr]] =
        emit_rescue_glue(try_name, rregion, arg_names, Array.new(arg_names.size),
                         extra_field_values: extra_fields.map { |f| f[:name] } +
                                             saved.map { |f| f[:name].sub('bc2cpp_saved_', '') })
    end
    body = String.new
    # NESTED_BLOCK_FALLBACK_SUPPORT: the JUMP_TARGET_GLUE_FIX label rule.
    targets = jump_targets(block_irep) - (nested_suppressed - nested_glue_at.keys)
    elem_class = block_fallback_element_class(region[:parent_irep], region, d.owner)
    block_irep.instructions.each_with_index do |insn, idx|
      next if insn.op == 'ENTER'
      next if nested_suppressed.include?(insn.addr) && !nested_glue_at.key?(insn.addr)

      body << "  L#{insn.addr}:;\n" if targets.include?(insn.addr)
      if nested_glue_at.key?(insn.addr)
        body << nested_glue_at[insn.addr]
      else
        with_element_hint(block_irep, insn, idx, '1', elem_class) do
          body << compile_insn(insn, block_irep, d, idx)
        end
      end
    end
    @block_fallback_upvars = nil
    @block_fallback_active = false
    @blk_param_name = saved_blk_param_name
    @blk_param_level = saved_blk_param_level
    return nil if nested_pre.include?('#error') || body.include?('#error')

    out = nested_pre
    # BLOCK_FALLBACK_YIELD_SUPPORT: parameter order self, upvars, blk, then the
    # block's own parameters, matching the env slots. Bodies without it are
    # unchanged.
    out << "static mrb_value #{impl_name}(mrb_state* M, mrb_value self" \
           "#{upvar_params.map { |p| ", #{p}" }.join}#{blk_param.map { |p| ", #{p}" }.join}" \
           "#{arg_names.map { |a| ", mrb_value #{a}" }.join}) {\n"
    (0...block_irep.nregs).each { |i| out << "  mrb_value r#{i}" << (i.zero? ? ' = self;' : ' = mrb_nil_value();') << "\n" }
    arg_names.each_with_index { |a, i| out << "  r#{i + 1} = #{a};\n" }
    out << body
    out << "  return mrb_nil_value(); // unreachable if every path RETURNs\n"
    out << "}\n\n"

    # RUNTIME_DEF_FALLBACK_SUPPORT: method bodies and EXEC-opened class bodies take
    # self from the receiver mruby passes (the opposite of a block body). For an
    # installed method that is the object the call dispatched on. For an EXEC body
    # it is the target class: vm.c OP_EXEC does `struct RClass *c =
    # mrb_class_ptr(recv);` and `cipush(mrb, a, 0, c, p, NULL, 0, 0)`, so regs[0]
    # is recv and target_class is mrb_class_ptr(recv). emit_tdef_fallback_glue
    # relies on this to spell check_target_class(mrb) as mrb_class_ptr(self).
    if region[:self_source] == :receiver
      out << "static mrb_value #{fn_name}(mrb_state* M, mrb_value bc2cpp_recv_self) {\n"
      out << "  mrb_value bc2cpp_captured_self = bc2cpp_recv_self;\n"
    else
      out << "static mrb_value #{fn_name}(mrb_state* M, mrb_value bc2cpp_unused_self) {\n"
      out << "  (void)bc2cpp_unused_self;\n"
      out << "  mrb_value bc2cpp_captured_self = mrb_proc_cfunc_env_get(M, 0);\n"
    end
    # UPVAR_CAPTURE_SUPPORT: env slot 0 is self; upvar i is at slot i + 1, the same
    # order emit_rproc_construction builds (both read upvar_regs).
    upvar_args = upvar_regs.each_with_index.map do |(l, b), i|
      vname = upvar_var_name(l, b)
      out << "  mrb_value* #{vname} = static_cast<mrb_value*>(mrb_cptr(mrb_proc_cfunc_env_get(M, #{i + 1})));\n"
      vname
    end
    # BLOCK_FALLBACK_YIELD_SUPPORT: the forwarded block is the last env slot, read
    # back as a plain mrb_value (a copy, kept GC-reachable by the env).
    if needs_blk
      out << "  mrb_value bc2cpp_blk = mrb_proc_cfunc_env_get(M, #{upvar_regs.size + 1});\n"
    end
    call_args = (['bc2cpp_captured_self'] + upvar_args + (needs_blk ? ['bc2cpp_blk'] : [])).join(', ')
    if mand.zero?
      out << "  return #{impl_name}(M, #{call_args});\n"
    elsif (region[:kind] || 'block_fallback') == 'block_fallback' && mand > 1
      # Blocks are lenient about argument count, and Hash#each passes one [key,
      # value] Array; the interpreter expands it for a multi-parameter block, a
      # cfunc proc does not, so do it here.
      out << "  mrb_value* bc2cpp_argv;\n"
      out << "  mrb_int bc2cpp_argc;\n"
      out << "  mrb_get_args(M, \"*\", &bc2cpp_argv, &bc2cpp_argc);\n"
      arg_names.each { |a| out << "  mrb_value #{a};\n" }
      out << "  if (bc2cpp_argc == 1 && mrb_array_p(bc2cpp_argv[0])) {\n"
      arg_names.each_with_index do |a, i|
        out << "    #{a} = mrb_ary_ref(M, bc2cpp_argv[0], #{i});\n"
      end
      out << "  } else {\n"
      arg_names.each_with_index do |a, i|
        out << "    #{a} = bc2cpp_argc > #{i} ? bc2cpp_argv[#{i}] : mrb_nil_value();\n"
      end
      out << "  }\n"
      out << "  return #{impl_name}(M, #{call_args}, #{arg_names.join(', ')});\n"
    else
      arg_names.each { |a| out << "  mrb_value #{a};\n" }
      fmt = 'o' * mand
      ptrs = arg_names.map { |a| "&#{a}" }.join(', ')
      out << "  mrb_get_args(M, \"#{fmt}\", #{ptrs});\n"
      out << "  return #{impl_name}(M, #{call_args}, #{arg_names.join(', ')});\n"
    end
    out << "}\n\n"
    [fn_name, out]
  end

  # BLOCK_CFUNC_FALLBACK_SUPPORT / LAMBDA_FALLBACK_SUPPORT: build the RProc with
  # mrb_proc_new_cfunc_with_env and an env holding the enclosing method's `self`
  # (captured here, where it is a local; read back with
  # mrb_proc_cfunc_env_get(M, 0)). Returns [rproc_var, code]; the caller
  # dispatches or stores it.
  # INLINE_NESTED_BLOCK_SUPPORT: `inline_offset` (only for regions nested in an
  # inlined loop body) takes addresses of locals instead of forwarding pointer
  # parameters: level 0 is `r<b + inline_offset>`, level 1 the method's `r<b>`
  # (see inline_nested_block_pass). Level >= 2 never gets here. nil keeps the
  # previous output.
  def emit_rproc_construction(addr, fn_name, upvar_regs = [], needs_blk = false, inline_offset: nil)
    var = "bc2cpp_blk_proc_#{addr}"
    out = String.new
    # UPVAR_CAPTURE_SUPPORT: `&r#{b}` is the address of this function's register
    # local, boxed with mrb_cptr_value, in the same order the entry reads them.
    # DEEP_UPVAR_CAPTURE_SUPPORT: a level-L entry (L >= 1) is not a local here;
    # this function holds the pointer as its parameter upvar_var_name(l - 1, b), so
    # forward it as is (`&` would box a pointer-to-pointer).
    # BLOCK_FALLBACK_YIELD_SUPPORT: the enclosing frame's block (`bc2cpp_blk`, from
    # mrb_get_args "&" at method level or forwarded again) is appended by value:
    # nothing writes back through it, and the env keeps it GC-rooted.
    env_entries = ['self'] + upvar_regs.map do |(l, b)|
      if inline_offset
        "mrb_cptr_value(M, &r#{l.zero? ? b + inline_offset : b})"
      elsif l.zero?
        "mrb_cptr_value(M, &r#{b})"
      else
        "mrb_cptr_value(M, #{upvar_var_name(l - 1, b)})"
      end
    end
    env_entries << 'bc2cpp_blk' if needs_blk
    out << "    mrb_value bc2cpp_blk_env_#{addr}[] = { #{env_entries.join(', ')} };\n"
    out << "    struct RProc* #{var} = mrb_proc_new_cfunc_with_env(M, #{fn_name}, #{env_entries.size}, " \
           "bc2cpp_blk_env_#{addr});\n"
    [var, out]
  end

  # BLOCK_CFUNC_FALLBACK_SUPPORT: call-site glue: build the RProc
  # (emit_rproc_construction) and call with mrb_funcall_with_block (dynamic
  # dispatch, never devirtualized). emit_lambda_fallback_glue is the
  # no-dispatch sibling.
  # INLINE_NESTED_BLOCK_SUPPORT: `inline_offset` shifts this region's
  # destination/argument registers into the enclosing function's numbering (the
  # compile_block_body_insn shift) and is passed on for the capture levels.
  # `self` is not shifted: the block shares the method's self. nil keeps the
  # previous output.
  def emit_block_fallback_glue(region, fn_name, inline_offset: nil)
    dest_reg = region[:dest_reg].to_i + (inline_offset || 0)
    recv = region[:self_implicit] ? 'self' : "r#{dest_reg}"
    argv = (1..region[:n]).map { |k| "r#{dest_reg + k}" }
    rproc_var, ctor = emit_rproc_construction(region[:block_addr], fn_name, region[:upvars] || [],
                                              region[:needs_blk] ? true : false, inline_offset: inline_offset)
    out = String.new
    out << "  // BLOCK_FALLBACK :#{region[:name]} -- block body compiled as a standalone cfunc, wrapped as a real RProc " \
           "(self captured at construction time), dynamic dispatch\n"
    out << "  {\n"
    out << ctor
    # EXCEPTION_BREAK_SUPPORT: the dispatch is always wrapped (cheap under
    # zero-cost exceptions, and no need to know whether this body has a BREAK); a
    # body without one never throws.
    out << "    Bc2cppVmMark bc2cpp_brk_mark = bc2cpp_vm_mark(M);\n    try {\n"
    if argv.empty?
      out << "      r#{dest_reg} = mrb_funcall_with_block(M, #{recv}, mrb_intern_cstr(M, \"#{region[:name]}\"), 0, NULL, " \
             "mrb_obj_value(#{rproc_var}));\n"
    else
      out << "      mrb_value bc2cpp_blk_argv_#{region[:block_addr]}[] = { #{argv.join(', ')} };\n"
      out << "      r#{dest_reg} = mrb_funcall_with_block(M, #{recv}, mrb_intern_cstr(M, \"#{region[:name]}\"), " \
             "#{argv.size}, bc2cpp_blk_argv_#{region[:block_addr]}, mrb_obj_value(#{rproc_var}));\n"
    end
    out << "    } catch (bc2cpp_block_break& bc2cpp_brk) {\n"
    out << "      bc2cpp_vm_restore(M, bc2cpp_brk_mark);\n"
    out << "      r#{dest_reg} = bc2cpp_brk.value;\n"
    out << "    }\n"
    out << "  }\n"
    out
  end

  # EXPLICIT_BLOCK_ARG_SUPPORT: `ary.select(&:defending)`, `ary.each(&proc_var)`,
  # `ary.map(&method(:bar))`: no BLOCK instruction, just `expr` evaluated into
  # R(dest+n+1) before the SENDB/SSENDB. No body to compile:
  # mrb_funcall_with_block (vm.c) already runs ensure_block on the value
  # (`if (!mrb_nil_p(blk) && !mrb_proc_p(blk)) blk = mrb_type_convert(mrb, blk,
  # MRB_TT_PROC, MRB_SYM(to_proc));`), and `&nil` passes through. So the register
  # is handed straight to mrb_funcall_with_block, inside the same
  # `catch (bc2cpp_block_break&)` wrapper (the value may be one of our own
  # BLOCK_FALLBACK RProcs, whose break throws that type).
  def recognize_explicit_block_arg_regions(irep)
    regions = []
    irep.instructions.each_with_index do |insn, idx|
      next unless %w[SENDB SSENDB].include?(insn.op)

      prev = idx.positive? ? irep.instructions[idx - 1] : nil
      next if prev && prev.op == 'BLOCK'

      # EXPLICIT_BLOCK_ARG_DYNAMIC_SPLAT_SUPPORT: `n=*` (no `|nk=`) with `&expr`, e.g.
      # `__send__(name, *args, &block)` in RGSS::ErrorReport::Tee#method_missing.
      # The args Array is already built in R(dest+1) (see compile_dynamic_splat_send)
      # and the block is in R(dest+2).
      n_match = insn.args.match(/n=(\d+|\*)(?:\s|$)/)
      next unless n_match

      dest, = insn.args.split(/\s+/, 2)
      dest_reg = dest[/^R(\d+)/, 1]
      next unless dest_reg

      name = insn.args[/:([\w+\-*\/<>=!?\[\]&|^~%@]+)/, 1]
      next unless name

      if n_match[1] == '*'
        regions << { sendb_addr: insn.addr, dest_reg: dest_reg, n: '*',
                     argv_reg: (dest_reg.to_i + 1).to_s,
                     blk_reg: (dest_reg.to_i + 2).to_s, name: name,
                     self_implicit: insn.op == 'SSENDB' }
      else
        n = n_match[1].to_i
        regions << { sendb_addr: insn.addr, dest_reg: dest_reg, n: n,
                     blk_reg: (dest_reg.to_i + n + 1).to_s, name: name,
                     self_implicit: insn.op == 'SSENDB' }
      end
    end
    regions
  end

  def emit_explicit_block_arg_glue(region)
    dest_reg = region[:dest_reg].to_i
    recv = region[:self_implicit] ? 'self' : "r#{dest_reg}"
    out = String.new
    out << "  // EXPLICIT_BLOCK_ARG :#{region[:name]} -- &expr forwarded directly as the block " \
           "(mrb_funcall_with_block's own ensure_block coerces Symbol/Proc/anything with #to_proc), dynamic dispatch\n"
    out << "  {\n  Bc2cppVmMark bc2cpp_brk_mark = bc2cpp_vm_mark(M);\n  try {\n"
    if region[:n] == '*'
      # EXPLICIT_BLOCK_ARG_DYNAMIC_SPLAT_SUPPORT: R(dest+1) is a real Array, so
      # RARRAY_LEN/RARRAY_PTR go straight into mrb_funcall_with_block.
      out << "    r#{dest_reg} = mrb_funcall_with_block(M, #{recv}, mrb_intern_cstr(M, \"#{region[:name]}\"), " \
             "RARRAY_LEN(r#{region[:argv_reg]}), RARRAY_PTR(r#{region[:argv_reg]}), r#{region[:blk_reg]});\n"
    else
      argv = (1..region[:n]).map { |k| "r#{dest_reg + k}" }
      if argv.empty?
        out << "    r#{dest_reg} = mrb_funcall_with_block(M, #{recv}, mrb_intern_cstr(M, \"#{region[:name]}\"), 0, NULL, " \
               "r#{region[:blk_reg]});\n"
      else
        out << "    mrb_value bc2cpp_ebarg_argv_#{region[:sendb_addr]}[] = { #{argv.join(', ')} };\n"
        out << "    r#{dest_reg} = mrb_funcall_with_block(M, #{recv}, mrb_intern_cstr(M, \"#{region[:name]}\"), " \
               "#{argv.size}, bc2cpp_ebarg_argv_#{region[:sendb_addr]}, r#{region[:blk_reg]});\n"
      end
    end
    out << "  } catch (bc2cpp_block_break& bc2cpp_brk) {\n"
    out << "    bc2cpp_vm_restore(M, bc2cpp_brk_mark);\n"
    out << "    r#{dest_reg} = bc2cpp_brk.value;\n"
    out << "  }\n"
    out << "  }\n"
    out
  end

  # RESCUE_BODY_BLOCK_SUPPORT: the shared BLOCK_FALLBACK/EXPLICIT_BLOCK_ARG
  # suppress-and-glue pass, used by compile_method and emit_rescue_try_body.
  # Takes recognized region lists (the caller chooses the scope), mutates the
  # caller's suppressed/glue_at, and returns the nested-function pre-code.
  def emit_block_fallback_glue_pass(block_regions, explicit_arg_regions, d, suppressed, glue_at)
    pre = String.new
    block_regions.each do |region|
      next if suppressed.include?(region[:block_addr]) || suppressed.include?(region[:sendb_addr])

      fn_result = emit_proc_fallback_fn(region, d)
      next unless fn_result

      fn_name, fn_code = fn_result
      pre << fn_code
      suppressed << region[:block_addr] << region[:sendb_addr]
      glue_at[region[:block_addr]] = emit_block_fallback_glue(region, fn_name)
    end
    explicit_arg_regions.each do |region|
      next if suppressed.include?(region[:sendb_addr])

      suppressed << region[:sendb_addr]
      glue_at[region[:sendb_addr]] = emit_explicit_block_arg_glue(region)
    end
    pre
  end
end
