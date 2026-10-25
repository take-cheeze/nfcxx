# frozen_string_literal: true

require_relative 'ir_rbs_block_types'
require_relative 'core_block_param_sigs'
require_relative 'core_fact_sigs'
require_relative 'block_capture_index'

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
    return region[:needs_ret] unless region[:needs_ret].nil?

    block_irep = region[:block_irep]
    return true if BytecodeIR.for(block_irep).op?(:RETURN_BLK)

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

  def block_upvar_needs(irep)
    return @block_capture_index.upvars(irep) if @block_capture_index

    compute_block_upvar_needs(irep)
  end

  def compute_block_upvar_needs(irep)
    needs = []
    walked = BytecodeIR.each_nested_insn(irep, ->(label) { @ireps[label] }, max_depth: MAX_UPVAR_NEST_DEPTH) do |insn, depth|
      next unless %i[GETUPVAR SETUPVAR].include?(insn.op)

      upvar_idx, level = insn.upvar_ref
      # Relative to +irep+ a reference `depth` blocks down needs the frame `level - depth` up; a negative one is the
      # enclosing frame, which +irep+ does not need.
      needs << [level - depth, upvar_idx] if level >= depth
    end
    walked ? needs.uniq.sort : nil
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
  # BLOCK_SEMANTICS: `given: false` leaves out the `block_given?`
  # reads, which only test the block for nil and so need no synchronous callee.
  def block_blk_needs(irep, depth = 0, given: true)
    if @block_capture_index
      return @block_capture_index.block_levels(irep, depth, given: given && block_given_modelled?)
    end

    return nil if depth > MAX_UPVAR_NEST_DEPTH

    needs = []
    BytecodeIR.for(irep).instructions_with_op(:BLKPUSH).each do |insn|
      lv = insn.paren_value
      return nil unless lv

      needs << lv.to_i
    end
    # `block_given?` reads the method's block like a BLKPUSH from `depth + 1`
    # levels up (the root is one level below its method).
    needs << depth + 1 if given && block_given_modelled? && calls_block_given?(irep)
    (irep.reps || []).each do |child_label|
      child = child_label && @ireps[child_label]
      next unless child

      child_needs = block_blk_needs(child, depth + 1, given: given)
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
    const_receiver?(irep, call_idx, dest_reg, 'Fiber')
  end

  def array_const_receiver?(irep, call_idx, dest_reg)
    const_receiver?(irep, call_idx, dest_reg, 'Array')
  end

  def const_receiver?(irep, call_idx, dest_reg, const_name)
    writer = irep.source_writer(call_idx - 1, dest_reg)
    writer&.op == :GETCONST && writer.const_name == const_name
  end

  # FIBER_YIELD_UNSAFE_SUPPORT: `Fiber.yield` is a plain SEND (`GETCONST R2
  # Fiber` + `SEND R2 :yield n=1`), so it would compile as an ordinary call into
  # mrb_fiber_yield from a native compiled frame. mruby's reentrant fiber-resume
  # path (fiber_switch/fiber_resume) breaks with a VM-invisible native frame
  # between the fiber entry and the yield ("resuming dead fiber"; see
  # tools/optcarrot_probe/README.md). A method that calls Fiber.yield directly
  # gets an early `#error` stub, unless it is a Fiber.new root that compiles as a
  # resumable step function. Transitive callers are handled
  # by compute_fiber_unsafe_methods.
  def calls_fiber_yield?(irep)
    BytecodeIR.for(irep).each_with_op(:SEND, :SEND0) do |insn, idx|
      name = insn.sym
      next unless name == 'yield'

      dest_reg = insn.reg
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
  # refuses the methods reached that can themselves reach Fiber.yield
  # (compute_fiber_yield_names): only those have a yield above their native frame.
  # The others return before any fiber switch and compile like any method.
  # Same-owner self-sends only: every real call in a fiber body here has that
  # shape. An explicit-receiver call leaving the class is a known gap (none
  # exists); missing one reproduces the loud FiberError, never a silent wrong
  # answer.
  def compute_fiber_unsafe_methods
    by_owner_name = {} # [owner, name] -> irep label, registered methods only
    irep_owner = {} # irep label -> owner, registered methods AND every block nested inside them
    fiber_defs = {} # irep label -> MethodDef, registered methods only
    @registry.each_value do |defs|
      defs.each do |d|
        next unless d.irep

        by_owner_name[[d.owner, d.name]] = d.irep
        irep_owner[d.irep] = d.owner
        fiber_defs[d.irep] = d
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
      BytecodeIR.for(irep).adjacent_pairs(:BLOCK, %i[SENDB]) do |insn, paired, sendb_idx|
        idx = sendb_idx - 1
        next unless paired.sym == 'new'

        dest_reg = paired.reg
        next unless dest_reg && fiber_const_receiver?(irep, idx, dest_reg)

        block_irep_idx = insn.block_index
        next unless block_irep_idx

        block_label = irep.reps[block_irep_idx.to_i]
        seeds << block_label if block_label
      end
    end

    # RESUMABLE_ROOTS: the methods a Fiber.new block body calls directly on self.
    # A root that qualifies is compiled as a resumable step function instead of refused.
    @fiber_roots = Set.new
    seeds.each do |label|
      seed_irep = @ireps[label]
      owner = irep_owner[label]
      next unless seed_irep && owner

      fiber_block_root_targets(seed_irep).each do |name|
        root = by_owner_name[[owner, name]]
        @fiber_roots << root if root
      end
    end

    reachable = Set.new
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
      next unless reachable.add?(label)

      irep = @ireps[label]
      next unless irep

      owner = irep_owner[label]
      next unless owner

      self_call_targets(irep).each do |name|
        target = by_owner_name[[owner, name]]
        queue << target if target
      end
    end
    # Only a reachable method that can itself reach Fiber.yield has a yield above its native
    # frame; the others return before any switch and compile like any method. The yield names
    # are by name over every receiver, so an explicit-receiver call cannot hide one
    # (compute_fiber_yield_names).
    @fiber_yield_names = seeds.empty? ? Set.new : compute_fiber_yield_names(seeds.to_set)
    @fiber_unsafe_methods = reachable.select do |label|
      d = fiber_defs[label]
      d.nil? || @fiber_yield_names.include?(d.name)
    end.to_set
    @fiber_unsafe_methods.merge(yield_reach_unsafe_methods(fiber_defs))
  end

  # YIELD_REACH_UNSAFE_SUPPORT: every method a Fiber.new body can reach by any call (explicit
  # receivers, other classes, blocks, dynamic sends resolved by name) whose execution may suspend the
  # Fiber above its frame. A core iterator with a run-time guard decides per call instead.
  def yield_reach_unsafe_methods(fiber_defs)
    guarded = self.class.core_guarded || Set.new
    @yield_reach.fiber_unsafe(fiber_defs.keys.reject { |label| guarded.include?(label) })
  end

  # Every self-send name reachable from `irep`, including inside nested block
  # ireps (a block body is part of the method that contains it).
  def self_call_targets(irep, seen = Set.new.compare_by_identity)
    return [] unless seen.add?(irep)

    names = []
    BytecodeIR.for(irep).instructions_with_op(:SSEND, :SSEND0, :SSENDB).each do |insn|
      name = insn.sym
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
    BytecodeIR.for(irep).adjacent_pairs(:BLOCK, %i[SENDB SSENDB]) do |insn, paired, sendb_idx|
      idx = sendb_idx - 1
      # EXPLICIT_ARGS_BLOCK_FALLBACK_SUPPORT: any fixed positional count
      # (`ary.inject(0) { }`, `ary.each_slice(2) { }`), but never `n=*` (a splat has
      # no static layout) and never a keyword call (`n=3|nk=1`):
      # mrb_funcall_with_block cannot carry keywords (`ci->nk = 0` in
      # funcall_args_capture).
      next unless paired.plain_fixed_argc?

      n = paired.n_spec.to_i
      dest_reg = paired.reg
      block_reg = insn.reg
      # Layout: dest, n positional args, then the block (`BLOCK R4` + `SENDB R2
      # :reduce n=1`), so the block is at dest + n + 1.
      next unless dest_reg && block_reg && block_reg == dest_reg + n + 1

      name = paired.sym
      next unless name

      # FIBER_NEW_BLOCK_UNSAFE_SUPPORT: never admit `Fiber.new { ... }`.
      next if paired.op == :SENDB && name == 'new' && fiber_const_receiver?(irep, idx, dest_reg)

      block_irep_idx = insn.block_index
      next unless block_irep_idx

      block_label = irep.reps[block_irep_idx.to_i]
      block_irep = block_label && @ireps[block_label]
      next unless block_irep && block_fallback_safe?(block_irep)
      # BLOCK_SELF_WORLD: a rebinder runs this block under another self; the compiled body would read
      # its creator's. It stays interpreted (with the method holding it).
      next if block_self_rebound?(block_label)

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
      synchronous = BLOCK_FALLBACK_UPVAR_SAFE_METHODS.include?(name) || block_proven_to_stay?(irep, idx)
      next if upvars.any? && !synchronous

      # BLOCK_SEMANTICS: `new` is on the allowlist for Array.new only. Hash.new
      # keeps its block as the default proc and Proc.new returns it, either of
      # which outlives this frame and would hold pointers into it.
      next if upvars.any? && name == 'new' && !array_const_receiver?(irep, idx, dest_reg)

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
      # BLOCK_FALLBACK_YIELD_SUPPORT: `lv == 1` is this METHOD's block, which
      # the wrapper extracted. `lv == 2` with no `lv == 1` is the enclosing
      # REGION's block: this block is itself nested (NESTED_BLOCK_FORWARD),
      # so uvenv(lv-1) resolves to its parent cfunc, which holds that
      # block in its own `bc2cpp_blk`. `blk_available` is therefore the caller's
      # needs_blk, not the method's -- see the nested recognize call below.
      needs_blk = blk_available && (blk_needs == [1] || blk_needs == [2]) &&
                  (synchronous || block_blk_needs(block_irep, given: false) == [])

      region = { block_addr: insn.addr, block_index: idx, sendb_addr: paired.addr, dest_reg: dest_reg,
                 block_irep: block_irep, name: name, n: n,
                 self_implicit: paired.op == :SSENDB, upvars: upvars, needs_blk: needs_blk,
                 parent_irep: irep }
      # BLOCK_SEMANTICS: the tokens this block's env must carry. A return token is
      # forwarded by every enclosing block, so it is needed for a `return` at any depth.
      region[:needs_brk] = BytecodeIR.for(block_irep).op?(:BREAK)
      region[:needs_ret] = BytecodeIR.for(block_irep).op?(:RETURN_BLK) ||
                           recognize_block_fallback_regions(block_irep, available_upvars: upvars).any? { |nested| nested[:needs_ret] }
      regions << region
    end
    regions
  end

  # BLOCK_FALLBACK_ELEMENT_SUPPORT: pass an exact element class into the cfunc
  # only for a known Array or Hash iterator with a proven yield shape; otherwise
  # dynamic dispatch.
  # CORE_BLOCK_ELEMENT_HINT: the yield shapes are sig/bc2cpp/declarations.rbs#core_block_params
  # (CoreBlockParamSigs). Returns { block parameter register => hint }, where a
  # hint is the class name (a STRICT_HINTS element hint, as before) for the shapes
  # this pass always had, and a SoftElementHint for the rest: those keep their
  # by-name else arm until a verify build reviews them.
  # The element class comes from the same scans as before (proven_element_class /
  # proven_hash_element_class, i.e. ArrayElementLayout's ivar facts, `Array[C]`
  # ivar and return signatures, and locals traced to them), so no new purity
  # assumption is made about any Array.
  STRICT_BLOCK_ELEMENT_SHAPES = [%w[Array each], %w[Array each_with_index], %w[Array each_with_object],
                                 %w[Hash each_value]].freeze
  # The lookup chain of an exact Array / Hash instance up to the modules core iterators live in (declarations.rbs#core_hierarchy).
  BLOCK_ELEMENT_CHAINS = %w[Array Hash].to_h { |klass| [klass, CoreHierarchySigs.ancestors(klass)] }.freeze

  def block_fallback_element_hints(irep, region, owner_name)
    return {} unless irep && !region[:self_implicit]

    block_irep = region[:block_irep]
    fields = block_irep.enter&.enter_fields
    # Pure required positionals only: an optional or rest parameter changes how a
    # yielded Array is spread over the parameters.
    return {} unless fields && fields.drop(1).all?(&:zero?)

    idx = irep.index_of_addr(region[:sendb_addr])
    insn = idx && BytecodeIR.for(irep).source_at(idx)
    return {} unless insn&.op == :SENDB

    shapes = CoreBlockParamSigs.shapes.select do |(klass, name), shape|
      name == region[:name] && shape.argc.cover?(region[:n]) && shape.arity == fields.first && !shape.elements.empty? &&
        block_element_chain_core?(klass, name)
    end
    return {} if shapes.empty?

    recv_class = block_fallback_receiver_class(irep, idx, region[:dest_reg], owner_name)
    mand = mandatory_arity(irep)
    ivar_classes = @class_layout[owner_name] || {}
    arg_classes = @class_annotations[irep.label]&.args
    shapes.each do |(klass, name), shape|
      element = if klass == 'Array'
                  array = recv_class
                  array = proven_array_source(irep, idx, region[:dest_reg], owner: owner_name) unless array == 'Array'
                  array == 'Array' &&
                    proven_element_class(irep, idx, region[:dest_reg], ivar_classes, mand, arg_classes, owner_name)
                elsif recv_class == 'Hash'
                  proven_hash_element_class(irep, idx, region[:dest_reg], ivar_classes, mand, arg_classes, owner_name)
                end
      # Only a class of this program: the scans also return primitive tags and VACUOUS, which
      # PRIMITIVE_ELEMENT_SUPPORT keeps away from the element-hint consumers.
      next unless element.is_a?(String) && known_owner_set.include?(element) &&
                  !PRIMITIVE_ELEMENT_CLASSES.include?(element)

      strict = STRICT_BLOCK_ELEMENT_SHAPES.include?([klass, name]) && shape.elements == [0]
      return shape.elements.to_h { |pos| [(pos + 1).to_s, strict ? element : SoftElementHint.new(element)] }
    end
    {}
  end

  # Does an exact `klass` instance answer `name` with the core method? A program
  # definition on its chain (outside 3rd/mruby) could yield anything.
  def block_element_chain_core?(klass, name)
    chain = BLOCK_ELEMENT_CHAINS.fetch(klass)
    (@registry[name] || []).none? do |definition|
      chain.include?(definition.owner) && !@ireps[definition.irep]&.file.to_s.include?('/3rd/mruby/')
    end
  end

  # RBS_BLOCK_PARAM_HINT: the class of a block's first parameter when the method it is passed to declares
  # that block type (`def each: () { (Game::Actor) -> void } -> void` in a signature file). A plain block
  # whose required positionals match the declaration qualifies when every definition the send can reach is
  # known and declares the same first class (rbs_block_definers); anything else gets nil and stays untyped.
  # The class is returned as an element hint, so the direct call it enables still checks mrb_obj_class at
  # run time.
  def block_fallback_rbs_param_class(irep, region, owner_name)
    signatures = self.class.rbs_block_signatures
    return nil unless signatures && irep

    block_irep = region[:block_irep]
    fields = block_irep.enter&.enter_fields
    return nil unless fields && fields.drop(1).all?(&:zero?) && !rest_only_block?(block_irep)
    return nil unless fields.first.positive?

    idx = irep.index_of_addr(region[:sendb_addr])
    insn = idx && BytecodeIR.for(irep).source_at(idx)
    return nil unless insn&.op == (region[:self_implicit] ? :SSENDB : :SENDB)

    name = insn.sym.to_s
    definers = if region[:self_implicit]
                 rbs_block_self_definers(name, @self_class_unknown ? nil : owner_name)
               else
                 recv_class = block_fallback_receiver_class(irep, idx, region[:dest_reg], owner_name)
                 rbs_block_exact_definers(name, recv_class) if recv_class.is_a?(String)
               end
    return nil if definers.nil? || definers.empty?

    classes = definers.map { |owner| rbs_block_first_param_class(signatures[[owner, name]], fields.first) }
    classes.uniq.size == 1 ? classes.first : nil
  end

  # The one class a declared block's first parameter is, or nil: the declaration must take exactly `arity`
  # required positionals and nothing else, and its first type must resolve to a single class.
  def rbs_block_first_param_class(signature, arity)
    function = signature&.block_type&.type
    return nil unless function && function.optional_positionals.empty? && !function.rest_positionals &&
                      function.trailing_positionals.empty? && function.required_keywords.empty? &&
                      function.optional_keywords.empty? && !function.rest_keywords
    return nil unless function.required_positionals.size == arity

    classes = IrRbsBlockTypes.resolve(function.required_positionals.first.type, {})
    classes&.size == 1 ? classes.first.to_s : nil
  end

  # The owners whose definition of +name+ an exact +recv_class+ receiver reaches: the class's own declaration
  # as before, or, in a closed world, the one definition its lookup finds (an inherited declaration).
  def rbs_block_exact_definers(name, recv_class)
    return [recv_class] if self.class.rbs_block_signatures.key?([recv_class, name])
    return nil unless rbs_block_lookup_safe?(name, recv_class)

    target, = closed_world_lookup_target(name, recv_class, Set.new)
    target&.irep ? [target.owner] : nil
  end

  # RBS_BLOCK_PARAM_HINT for an implicit-self send in +self_owner+'s code: self is an instance of self_owner
  # or of any descendant, so the owners are the definition self_owner's own lookup finds plus every
  # descendant's override (the CHA_SELF enumeration, cha_self_plan). nil when the closed world cannot list
  # them all, so an override with another block contract is either listed (and must declare the same class)
  # or makes the hint impossible.
  def rbs_block_self_definers(name, self_owner)
    return nil unless self_owner && rbs_block_lookup_safe?(name, self_owner)

    hierarchy = @closed_world.class_hierarchy(self_owner)
    return nil unless hierarchy && @closed_world.self_method_missing_free?(self_owner)

    default, = closed_world_lookup_target(name, self_owner, Set.new, self_call: true)
    return nil unless default&.irep

    descendants = hierarchy[:descendants]
    return nil if descendants.any? { |klass| cha_mixin_may_define?(name, klass) }

    overriders = @registry.fetch(name, []).select { |d| descendants.include?(d.owner) }
    return nil unless overriders.empty? || hierarchy[:wild].empty?

    ([default] + overriders).map(&:owner).uniq
  end

  # The closed-world facts both lookups need: a declared class whose method table no runtime installer,
  # native definition or opaque name can change behind the lookup.
  def rbs_block_lookup_safe?(name, klass)
    return false unless @closed_world
    return false if klass.end_with?('.singleton') || !@closed_world.class_declared?(klass)
    return false if devirt_blocked_name?(name) || !@closed_world.inherited_lookup_safe?(name, klass)

    installed = symbol_installed_names
    return false if installed.nil? || installed.include?(name)

    @registry.fetch(name, []).none? { |d| d.owner == '<native>' }
  end

  # The class of the block send's receiver: trace_new_target with this method's ivar and argument facts.
  # SELF_ACCESSOR_RECEIVER: an implicit-self attr_reader call (`allies.each`) answers like the GETIV it reads
  # (self_accessor_class).
  def block_fallback_receiver_class(irep, idx, reg, owner_name)
    trace_new_target(irep, idx, reg, @class_layout[owner_name] || {}, mandatory_arity(irep),
                     @class_annotations[irep.label]&.args, owner: owner_name, class_layout: @class_layout,
                     registry: @registry, container_constants: @container_constants,
                     element_annotations: @element_annotations,
                     ret_class_proof: ->(name, owner) { self_accessor_class(name, owner) })
  end

  # SELF_ACCESSOR_RECEIVER: the class of `name` called on implicit self in a method of `owner` when that call
  # can only reach `owner`'s own attr_reader, so it returns exactly what `@name` holds. The answer is then the
  # ClassLayout fact a GETIV of the ivar in the same method gets (the same `K or nil` whole-program agreement,
  # consumed by the same runtime-checked hints).
  def self_accessor_class(name, owner)
    return nil unless self_accessor_owner?(name, owner)

    hint = @class_layout[owner][name] if @class_layout.key?(owner)
    hint unless hint.nil? || hint == ClassLayout::UNKNOWN
  end

  # Does an implicit-self `name` (no arguments) in a method of `owner` reach `owner`'s own attr_reader? Not in a
  # runtime-def body (self is whatever mruby passes) or a singleton owner; `owner` must register the reader, and
  # either have no subclass at all or pass CHA_SELF's hierarchy analysis with no overriding arm (no descendant or
  # mixin defines the name, no method_missing, no installed or native definition), the rule CLOSED_WORLD_SELF
  # already uses to call the target directly.
  def self_accessor_owner?(name, owner)
    return false if @self_class_unknown
    return false unless owner.is_a?(String) && !owner.end_with?('.singleton') && known_owner_set.include?(owner)

    reader = (@registry[name] || []).find { |md| md.owner == owner && md.kind == :ivar_accessor }
    return false unless reader
    return true if exact_receiver_class?(owner)

    plan, = cha_self_plan(name, 0, owner, explicit: false)
    plan ? plan[:arms].empty? && plan[:default].equal?(reader) : false
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
  # { body `_impl` name => [region, ...] } of every body emitted here (see block_yielders.rb). Read after codegen.
  def proc_fallback_origins
    @proc_fallback_origins || {}
  end

  def emit_proc_fallback_fn(region, d, fn_prefix = nil)
    saved_self_class_unknown = @self_class_unknown
    @self_class_unknown = saved_self_class_unknown || runtime_def_fallback_kind?(region[:kind])
    emit_proc_fallback_fn_body(region, d, fn_prefix)
  ensure
    @self_class_unknown = saved_self_class_unknown
  end

  def emit_proc_fallback_fn_body(region, d, fn_prefix)
    block_irep = region[:block_irep]
    # BLOCK_SELF_WORLD: every block or lambda body compiled here reads its creator's self; a rebound one
    # never runs under it. The recognizers already skip these; this keeps any other caller from compiling one.
    return nil if !runtime_def_fallback_kind?(region[:kind]) && block_self_rebound?(block_irep.label)
    mand = mandatory_arity(block_irep)
    rest_block = (region[:kind] || 'block_fallback') == 'block_fallback' && rest_only_block?(block_irep)
    arg_names = (1..(rest_block ? 1 : mand)).map { |i| "bc2cpp_barg#{i}" }
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
    # BLOCK_SEMANTICS: env layout is self, upvars, blk, return token, break token
    # (emit_rproc_construction builds the same order from the same region flags).
    next_slot = upvar_regs.size + 1 + (needs_blk ? 1 : 0)
    ret_slot = region[:needs_ret] ? next_slot : nil
    brk_slot = region[:needs_brk] ? next_slot + (ret_slot ? 1 : 0) : nil
    saved_ret_slot = @block_ret_slot
    saved_brk_slot = @block_brk_slot
    @block_ret_slot = ret_slot
    @block_brk_slot = brk_slot
    # Function names: block_addr is unique only within one irep, so prefix with
    # cpp_name(d.owner, d.name) (as emit_rescue_try_body does); `region[:kind]` is
    # only for readability.
    # NESTED_BLOCK_FALLBACK_SUPPORT: for a nested region `fn_prefix` is the outer
    # level's unique fn_name, since a nested block_addr lives in the block irep's
    # own address space.
    fn_name = "#{fn_prefix || cpp_name(d.owner, d.name)}_#{region[:kind] || 'block_fallback'}_#{region[:block_addr]}"
    impl_name = "#{fn_name}_impl"
    # BLOCK_YIELDERS: the region each body `_impl` was emitted for, read by the BC2CPP_TRACE_TYPES join (see
    # block_yielders.rb). Recording only: nothing emitted reads it. A name recorded twice is not joined.
    (@proc_fallback_origins ||= Hash.new { |h, k| h[k] = [] })[impl_name] << region

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
    #
    # NESTED_BLOCK_FORWARD: a nested region is entered from inside
    # this body's cfunc, so the block it can forward is the one THIS body holds
    # (an `lv == 2` BLKPUSH resolves to its parent region), not the method's.
    # The DEPTH is fixed here, before the recursion: a child's level is this
    # body's level plus one, so this body's own must already be set.
    saved_nested_depth = @block_fallback_depth
    @block_fallback_depth = fn_prefix ? @block_fallback_depth.to_i + 1 : 1
    # BLOCK_FALLBACK_YIELD_SUPPORT: the level a BLKPUSH in THIS body is matched
    # against is this body's own nesting depth:
    # depth 1 reads the method's block, depth 2 its parent region's, and
    # uvenv(lv-1) is a different frame for each. Set here, before the nested
    # pass, so a child can derive its own level from it.
    @blk_param_level = @block_fallback_depth
    recognize_block_fallback_regions(block_irep, available_upvars: upvar_regs,
                                     blk_available: needs_blk).each do |nregion|
      # BLOCK_FALLBACK_RESCUE_SUPPORT: regions inside a rescue range belong to that
      # range's own pass (emit_rescue_try_body); emitting them here too would
      # duplicate them.
      next if nested_suppressed.include?(nregion[:block_addr]) || nested_suppressed.include?(nregion[:sendb_addr])

      fn_result = emit_proc_fallback_fn(nregion, d, fn_name)
      next unless fn_result

      nfn_name, nfn_code = fn_result
      nested_pre << nfn_code
      nested_suppressed << nregion[:block_addr] << nregion[:sendb_addr]
      nested_glue_at[nregion[:block_addr]] = emit_block_fallback_glue(nregion, nfn_name, owner_def: d)
    end
    # EXPLICIT_BLOCK_ARG_SUPPORT: `&expr` sites in this body: suppress/glue only,
    # no body to compile.
    recognize_explicit_block_arg_regions(block_irep).each do |nregion|
      next if nested_suppressed.include?(nregion[:sendb_addr])

      nested_suppressed << nregion[:sendb_addr]
      nested_glue_at[nregion[:sendb_addr]] = emit_explicit_block_arg_glue(nregion, owner_def: d)
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
      BytecodeIR.for(block_irep).instructions_with_op(:TDEF).each do |tinsn|
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
    # compile_method sets @blk_param_name too and this function recurses. The
    # level is this body's nesting depth, fixed before the nested pass above.
    saved_blk_param_name = @blk_param_name
    saved_blk_param_level = @blk_param_level
    @blk_param_name = needs_blk ? 'bc2cpp_blk' : nil
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
                                             saved.map { |f| rescue_field_value(f) })
    end
    body = String.new
    # NESTED_BLOCK_FALLBACK_SUPPORT: the JUMP_TARGET_GLUE_FIX label rule.
    targets = BytecodeIR.for(block_irep).branch_target_addrs - (nested_suppressed - nested_glue_at.keys)
    elem_hints = block_fallback_element_hints(region[:parent_irep], region, d.owner)
    if elem_hints.empty?
      rbs_class = block_fallback_rbs_param_class(region[:parent_irep], region, d.owner)
      elem_hints = { '1' => rbs_class } if rbs_class
    end
    body << "  // RBS_BLOCK_PARAM_HINT :#{region[:name]} parameter 1 -> #{rbs_class}\n" if rbs_class
    arm_prune_block_analysis(block_irep, d, 0)
    BytecodeIR.for(block_irep).each_source do |insn, idx|
      next if insn.op == :ENTER
      next if nested_suppressed.include?(insn.addr) && !nested_glue_at.key?(insn.addr)

      body << "  L#{insn.addr}:;\n" if targets.include?(insn.addr)
      if nested_glue_at.key?(insn.addr)
        body << nested_glue_at[insn.addr]
      else
        with_element_hints(block_irep, insn, idx, elem_hints) do
          body << compile_insn(insn, block_irep, d, idx)
        end
      end
    end
    @block_fallback_upvars = nil
    @block_fallback_active = false
    @blk_param_name = saved_blk_param_name
    @blk_param_level = saved_blk_param_level
    @block_fallback_depth = saved_nested_depth
    @block_ret_slot = saved_ret_slot
    @block_brk_slot = saved_brk_slot
    return nil if nested_pre.include?('#error') || body.include?('#error')

    out = nested_pre
    # BLOCK_FALLBACK_YIELD_SUPPORT: parameter order self, upvars, blk, then the
    # block's own parameters, matching the env slots. Bodies without it are
    # unchanged.
    out << "static mrb_value #{impl_name}(mrb_state* M, mrb_value self" \
           "#{upvar_params.map { |p| ", #{p}" }.join}#{blk_param.map { |p| ", #{p}" }.join}" \
           "#{arg_names.map { |a| ", mrb_value #{a}" }.join}) {\n"
    out << errinfo_scope_line(block_irep)
    out << emit_register_initializers(block_irep.nregs, arg_names)
    out << body
    out << fell_off_end(impl_name)
    out << "}\n\n"

    out = drop_dead_statements(drop_unused_registers(out))

    kind = region[:kind] || 'block_fallback'
    # BLOCK_SEMANTICS: a break or return of a strict proc (Kernel#lambda over
    # this block) only leaves the proc; compile_insn throws bc2cpp_proc_exit for
    # it, caught here so it never reaches a call site.
    exits = kind == 'block_fallback' &&
            (BytecodeIR.for(block_irep).op?(:BREAK) || BytecodeIR.for(block_irep).op?(:RETURN_BLK))
    # BLOCK_DIRECT_ENTRY: the entry replaces the cfunc wrapper for this block.
    region[:direct_entry] = block_direct_entry?(region, kind, exits)
    region[:yield_free] = region[:direct_entry] && note_block_yield_free(region[:block_irep])
    if region[:direct_entry]
      out << emit_block_direct_entry(fn_name, impl_name, region, upvar_regs, needs_blk, mand, arg_names, rest_block)
      return [fn_name, out]
    end

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
      out << "static mrb_value #{fn_name}(mrb_state* M, mrb_value bc2cpp_passed_self) {\n"
      # BLOCK_SELF_WORLD: the body runs under the captured self; a rebinder passing another one is a
      # closed-world violation (bc2cpp_block_self_check) unless the world proves no rebinder gets this block.
      out << (block_self_check? ? "  bc2cpp_block_self_check(M, bc2cpp_passed_self, \"#{fn_name}\");\n" : "  (void)bc2cpp_passed_self;\n")
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
    call_impl = lambda do |args|
      if exits
        "  Bc2cppVmMark bc2cpp_exit_mark = bc2cpp_vm_mark(M);\n  try {\n    return #{impl_name}(#{args});\n" \
          "  } catch (bc2cpp_proc_exit& bc2cpp_exit) {\n    bc2cpp_vm_restore(M, bc2cpp_exit_mark);\n" \
          "    return bc2cpp_exit.value;\n  }\n"
      else
        "  return #{impl_name}(#{args});\n"
      end
    end
    if rest_block
      # REST_ONLY_BLOCK: the block's single parameter is the whole argument array.
      out << "  mrb_value* bc2cpp_argv;\n"
      out << "  mrb_int bc2cpp_argc;\n"
      out << "  mrb_get_args(M, \"*\", &bc2cpp_argv, &bc2cpp_argc);\n"
      out << call_impl.call("M, #{call_args}, mrb_ary_new_from_values(M, bc2cpp_argc, bc2cpp_argv)")
    elsif kind == 'block_fallback'
      # BLOCK_SEMANTICS: a block is called like OP_ENTER of a non-strict proc:
      # missing arguments are nil, extra ones are dropped, and one Array
      # argument is spread over several parameters (vm.c `len > 1 && argc == 1
      # && mrb_array_p`). Kernel#lambda makes the same RProc strict later, and a
      # strict proc raises on any other count instead.
      if mand.zero?
        out << "  if (bc2cpp_proc_strict_p(M) && mrb_get_argc(M) != 0) mrb_argnum_error(M, mrb_get_argc(M), 0, 0);\n"
        out << call_impl.call("M, #{call_args}")
      else
        out << "  mrb_value* bc2cpp_argv;\n"
        out << "  mrb_int bc2cpp_argc;\n"
        out << "  mrb_get_args(M, \"*\", &bc2cpp_argv, &bc2cpp_argc);\n"
        out << "  if (bc2cpp_proc_strict_p(M) && bc2cpp_argc != #{mand}) mrb_argnum_error(M, bc2cpp_argc, #{mand}, #{mand});\n"
        arg_names.each { |a| out << "  mrb_value #{a};\n" }
        if mand > 1
          out << "  if (bc2cpp_argc == 1 && mrb_array_p(bc2cpp_argv[0])) {\n"
          arg_names.each_with_index do |a, i|
            out << "    #{a} = mrb_ary_ref(M, bc2cpp_argv[0], #{i});\n"
          end
          out << "  } else {\n"
          arg_names.each_with_index do |a, i|
            out << "    #{a} = bc2cpp_argc > #{i} ? bc2cpp_argv[#{i}] : mrb_nil_value();\n"
          end
          out << "  }\n"
        else
          out << "  #{arg_names.first} = bc2cpp_argc > 0 ? bc2cpp_argv[0] : mrb_nil_value();\n"
        end
        out << call_impl.call("M, #{call_args}, #{arg_names.join(', ')}")
      end
    elsif mand.zero?
      # A lambda is strict.
      out << "  if (mrb_get_argc(M) != 0) mrb_argnum_error(M, mrb_get_argc(M), 0, 0);\n" if kind == 'lambda_fallback'
      out << "  return #{impl_name}(M, #{call_args});\n"
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

  # BLOCK_DIRECT_ENTRY: a block whose body neither breaks nor returns reads nothing from
  # the frame it is called in (those tokens are read from the calling cfunc's env), so a yield can
  # call it without pushing one. BC2CPP_BLOCK_DIRECT_ENTRY=0 keeps the cfunc wrapper everywhere.
  def block_direct_entry?(region, kind, exits)
    return false if ENV['BC2CPP_BLOCK_DIRECT_ENTRY'] == '0'

    kind == 'block_fallback' && region[:self_source] != :receiver && !region[:needs_ret] &&
      !region[:needs_brk] && !exits
  end

  # The entry itself: the captured self, upvar pointers and forwarded block come from the env
  # (`bc2cpp_env->stack`, where mrb_proc_cfunc_env_get finds them for a cfunc frame), the
  # arguments are bound as OP_ENTER binds them for a non-strict proc, and a strict copy
  # (Kernel#lambda over the block) raises on any other count.
  def emit_block_direct_entry(fn_name, impl_name, region, upvar_regs, needs_blk, mand, arg_names, rest_block)
    out = String.new
    out << "static mrb_value #{fn_name}_direct(mrb_state* M, struct REnv* bc2cpp_env, bool bc2cpp_strict, " \
           "mrb_int bc2cpp_argc, const mrb_value* bc2cpp_argv) {\n"
    out << "  (void)bc2cpp_strict; (void)bc2cpp_argc; (void)bc2cpp_argv;\n"
    out << "  mrb_value bc2cpp_captured_self = bc2cpp_env->stack[0];\n"
    upvar_args = upvar_regs.each_with_index.map do |(l, b), i|
      vname = upvar_var_name(l, b)
      out << "  mrb_value* #{vname} = static_cast<mrb_value*>(mrb_cptr(bc2cpp_env->stack[#{i + 1}]));\n"
      vname
    end
    out << "  mrb_value bc2cpp_blk = bc2cpp_env->stack[#{upvar_regs.size + 1}];\n" if needs_blk
    call_args = (['bc2cpp_captured_self'] + upvar_args + (needs_blk ? ['bc2cpp_blk'] : [])).join(', ')
    if rest_block
      out << "  return #{impl_name}(M, #{call_args}, mrb_ary_new_from_values(M, bc2cpp_argc, bc2cpp_argv));\n"
    elsif mand.zero?
      out << "  if (bc2cpp_strict && bc2cpp_argc != 0) mrb_argnum_error(M, bc2cpp_argc, 0, 0);\n"
      out << "  return #{impl_name}(M, #{call_args});\n"
    else
      out << "  if (bc2cpp_strict && bc2cpp_argc != #{mand}) mrb_argnum_error(M, bc2cpp_argc, #{mand}, #{mand});\n"
      arg_names.each { |a| out << "  mrb_value #{a};\n" }
      if mand > 1
        out << "  if (bc2cpp_argc == 1 && mrb_array_p(bc2cpp_argv[0])) {\n"
        arg_names.each_with_index { |a, i| out << "    #{a} = mrb_ary_ref(M, bc2cpp_argv[0], #{i});\n" }
        out << "  } else {\n"
        arg_names.each_with_index { |a, i| out << "    #{a} = bc2cpp_argc > #{i} ? bc2cpp_argv[#{i}] : mrb_nil_value();\n" }
        out << "  }\n"
      else
        out << "  #{arg_names.first} = bc2cpp_argc > 0 ? bc2cpp_argv[0] : mrb_nil_value();\n"
      end
      out << "  return #{impl_name}(M, #{call_args}, #{arg_names.join(', ')});\n"
    end
    out << "}\n\n"
    out
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
  # BLOCK_SEMANTICS: `ret_token` / `brk_token` are the C++ expressions for the
  # method's return token and this site's break token (nil: the body has none).
  # BLOCK_DIRECT_ENTRY: `direct_entry` names the block's entry function; the proc is
  # then built over bc2cpp_block_thunk with the entry and the YIELD_FREE flag as the two
  # last env slots.
  def emit_rproc_construction(addr, fn_name, upvar_regs = [], needs_blk = false, inline_offset: nil,
                              ret_token: nil, brk_token: nil, direct_entry: nil, yield_free: false)
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
    env_entries << ret_token if ret_token
    env_entries << brk_token if brk_token
    if direct_entry
      env_entries << "mrb_int_value(M, static_cast<mrb_int>(reinterpret_cast<uintptr_t>(&#{direct_entry})))"
      # The flag slot: YIELD_FREE (bit 0) and the BLOCK_SELF_WORLD check (bit 1), read by bc2cpp_block_thunk.
      env_entries << "mrb_int_value(M, #{(yield_free ? 1 : 0) | (block_self_check? ? 2 : 0)})"
    end
    out << "    mrb_value bc2cpp_blk_env_#{addr}[] = { #{env_entries.join(', ')} };\n"
    out << "    struct RProc* #{var} = mrb_proc_new_cfunc_with_env(M, #{direct_entry ? 'bc2cpp_block_thunk' : fn_name}, " \
           "#{env_entries.size}, bc2cpp_blk_env_#{addr});\n"
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
  # The Proc methods that run the proc (sig/bc2cpp/declarations.rbs#core_proc_calls; bc2cpp_cfunc_proc_call_p spells the same set,
  # which scripts/bc2cpp/core_facts_rbs_check.rb compares).
  PROC_CALL_NAMES = CoreFactSigs.proc_call_names

  def emit_block_fallback_glue(region, fn_name, inline_offset: nil, owner_def: nil)
    dest_reg = region[:dest_reg].to_i + (inline_offset || 0)
    recv = region[:self_implicit] ? 'self' : "r#{dest_reg}"
    argv = (1..region[:n]).map { |k| "r#{dest_reg + k}" }
    # BLOCK_SEMANTICS: a `break` in the body unwinds to this site while the site
    # is on the stack, so the site owns a frame (and its token) only then. The
    # method's return token is the innermost method frame at method level, or
    # the enclosing block's own copy of it.
    site = "bc2cpp_site_#{region[:block_addr]}"
    brk_token = region[:needs_brk] ? "mrb_int_value(M, #{site}.frame.token)" : nil
    ret_token = if !region[:needs_ret]
                  nil
                elsif @block_ret_slot
                  "mrb_proc_cfunc_env_get(M, #{@block_ret_slot})"
                else
                  'bc2cpp_return_token(M)'
                end
    rproc_var, ctor = emit_rproc_construction(region[:block_addr], fn_name, region[:upvars] || [],
                                              region[:needs_blk] ? true : false, inline_offset: inline_offset,
                                              ret_token: ret_token, brk_token: brk_token,
                                              direct_entry: region[:direct_entry] ? "#{fn_name}_direct" : nil,
                                              yield_free: region[:yield_free])
    # ARG_SHAPES_BLOCK: a top-level site whose call resolves to compiled code.
    # BLOCK_ARM_REACH: a block nested in an inlined loop body takes the same arms, shifted.
    stack_expr = stack_block_expr(region)
    direct = if inline_offset.nil?
               compile_direct_block_send(region, "mrb_obj_value(#{rproc_var})", owner_def, stack_expr: stack_expr)
             elsif owner_def && block_arm_reach?
               compile_direct_block_send(region, "mrb_obj_value(#{rproc_var})", owner_def, inline_offset: inline_offset,
                                                                                         stack_expr: stack_expr)
             end
    ctor, direct = stack_block_glue(region, rproc_var, ctor, direct) if direct && stack_expr && direct.include?(stack_expr)
    out = String.new
    out << "  // BLOCK_FALLBACK :#{region[:name]} -- block body compiled as a standalone cfunc, wrapped as a real RProc " \
           "(self captured at construction time), #{direct ? 'direct call with the block' : 'dynamic dispatch'}\n"
    out << "  {\n"
    out << "    Bc2cppFrameGuard #{site}(&bc2cpp_break_frames);\n" if region[:needs_brk]
    out << ctor
    # EXCEPTION_BREAK_SUPPORT: only a body with a BREAK can throw to this site.
    indent = region[:needs_brk] ? '      ' : '    '
    out << "    Bc2cppVmMark bc2cpp_brk_mark = bc2cpp_vm_mark(M);\n    try {\n" if region[:needs_brk]
    if direct
      out << direct.lines.map { |line| "#{indent}#{line}" }.join
    else
      # BLOCK_SEMANTICS: `pr.call(x) { ... }` on a cfunc Proc cannot use Proc#call
      # (see bc2cpp_cfunc_proc_call_p); the block is dropped, as a cfunc proc
      # takes none.
      args = argv.empty? ? 'NULL' : "bc2cpp_blk_argv_#{region[:block_addr]}"
      out << "#{indent}mrb_value bc2cpp_blk_argv_#{region[:block_addr]}[] = { #{argv.join(', ')} };\n" unless argv.empty?
      name = "mrb_intern_cstr(M, \"#{region[:name]}\")"
      if PROC_CALL_NAMES.include?(region[:name])
        out << "#{indent}if (mrb_type(#{recv}) == MRB_TT_PROC && bc2cpp_cfunc_proc_call_p(M, #{recv}, #{name})) {\n"
        out << "#{indent}  r#{dest_reg} = bc2cpp_yield_argv(M, #{recv}, #{argv.size}, #{args});\n"
        out << "#{indent}} else\n"
      end
      owner_call = block_owner_call_line("r#{dest_reg}", recv, region[:name], argv, "mrb_obj_value(#{rproc_var})")
      out << if owner_call
               "#{indent}#{owner_call}\n"
             else
               "#{indent}r#{dest_reg} = mrb_funcall_with_block(M, #{recv}, #{name}, #{argv.size}, #{args}, " \
                 "mrb_obj_value(#{rproc_var}));\n"
             end
    end
    if region[:needs_brk]
      out << "    } catch (bc2cpp_block_break& bc2cpp_brk) {\n"
      out << "      if (bc2cpp_brk.token != #{site}.frame.token) throw;\n"
      out << "      bc2cpp_vm_restore(M, bc2cpp_brk_mark);\n"
      out << "      r#{dest_reg} = bc2cpp_brk.value;\n"
      out << "    }\n"
    end
    out << "  }\n"
    out
  end

  # STACK_BLOCK (docs/bc2cpp-stack-blocks.md): a direct-entry block may be built in the frame instead of on the
  # heap. The forwarded frame block (`needs_blk`) is left out: the heap env is what keeps that value rooted.
  def stack_block_expr(region)
    return nil unless stack_blocks? && region[:direct_entry] && !region[:needs_blk]

    "bc2cpp_blk_stack_#{region[:block_addr]}.value()"
  end

  # The arms took the frame-local block: build it over the env array, and build the heap RProc only where the
  # remaining code still dispatches (the by-name else), when it runs.
  def stack_block_glue(region, rproc_var, ctor, direct)
    addr = region[:block_addr]
    heap_line = ctor[/^ *struct RProc\* #{rproc_var} = (mrb_proc_new_cfunc_with_env\(M, \w+, (\d+), bc2cpp_blk_env_#{addr}\));\n/]
    return [ctor, direct] unless heap_line

    alloc = Regexp.last_match(1)
    len = Regexp.last_match(2)
    heap_ref = "mrb_obj_value(#{rproc_var})"
    lines = "    Bc2cppStackBlock bc2cpp_blk_stack_#{addr}(M, #{len}, bc2cpp_blk_env_#{addr});\n"
    if direct.include?(heap_ref)
      lines << "    auto bc2cpp_blk_heap_#{addr} = [&]() { return mrb_obj_value(#{alloc}); };\n"
      direct = direct.gsub(heap_ref, "bc2cpp_blk_heap_#{addr}()")
    end
    [ctor.sub(heap_line, lines), direct]
  end

  # BC2CPP_STACK_BLOCKS=0 builds every block on the heap again.
  def stack_blocks?
    ENV['BC2CPP_STACK_BLOCKS'] != '0'
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
    irep.each_with_op(:SENDB, :SSENDB) do |insn, idx|
      prev = BytecodeIR.for(irep).previous(idx)
      next if prev && prev.op == :BLOCK

      # EXPLICIT_BLOCK_ARG_DYNAMIC_SPLAT_SUPPORT: `n=*` (no `|nk=`) with `&expr`.
      # The args Array is already built in R(dest+1) (see compile_dynamic_splat_send)
      # and the block is in R(dest+2).
      next unless insn.n_spec && insn.nk_spec.nil?

      dest_reg = insn.reg
      next unless dest_reg

      name = insn.sym
      next unless name

      if insn.n_spec == '*'
        regions << { sendb_addr: insn.addr, dest_reg: dest_reg, n: '*',
                     argv_reg: dest_reg + 1,
                     blk_reg: dest_reg + 2, name: name,
                     self_implicit: insn.op == :SSENDB }
      else
        n = insn.n_spec.to_i
        regions << { sendb_addr: insn.addr, dest_reg: dest_reg, n: n,
                     blk_reg: dest_reg + n + 1, name: name,
                     self_implicit: insn.op == :SSENDB, parent_irep: irep }
      end
    end
    regions
  end

  def emit_explicit_block_arg_glue(region, owner_def: nil)
    direct = emit_explicit_block_arg_direct(region, owner_def)
    return direct if direct

    dest_reg = region[:dest_reg].to_i
    recv = region[:self_implicit] ? 'self' : "r#{dest_reg}"
    out = String.new
    # BLOCK_SEMANTICS: no catch here. The value may be one of our own
    # BLOCK_FALLBACK procs, but a `break` in it unwinds to the site that built
    # it (its token), which is further out on the stack.
    out << "  // EXPLICIT_BLOCK_ARG :#{region[:name]} -- &expr forwarded directly as the block " \
           "(mrb_funcall_with_block's own ensure_block coerces Symbol/Proc/anything with #to_proc), dynamic dispatch\n"
    if region[:n] == '*'
      # EXPLICIT_BLOCK_ARG_DYNAMIC_SPLAT_SUPPORT: R(dest+1) is a real Array, so
      # RARRAY_LEN/RARRAY_PTR go straight into mrb_funcall_with_block.
      ary = "r#{region[:argv_reg]}"
      owner_call = block_owner_call_argv_line("r#{dest_reg}", recv, region[:name], "ary_size(#{ary})", "ary_items(#{ary})",
                                              "r#{region[:blk_reg]}")
      out << if owner_call
               "  #{owner_call}\n"
             else
               "  r#{dest_reg} = mrb_funcall_with_block(M, #{recv}, mrb_intern_cstr(M, \"#{region[:name]}\"), " \
                 "ary_size(#{ary}), ary_items(#{ary}), r#{region[:blk_reg]});\n"
             end
    else
      argv = (1..region[:n]).map { |k| "r#{dest_reg + k}" }
      owner_call = block_owner_call_line("r#{dest_reg}", recv, region[:name], argv, "r#{region[:blk_reg]}")
      if owner_call
        out << "  #{owner_call}\n"
      elsif argv.empty?
        out << "  r#{dest_reg} = mrb_funcall_with_block(M, #{recv}, mrb_intern_cstr(M, \"#{region[:name]}\"), 0, NULL, " \
               "r#{region[:blk_reg]});\n"
      else
        out << "  {\n"
        out << "    mrb_value bc2cpp_ebarg_argv_#{region[:sendb_addr]}[] = { #{argv.join(', ')} };\n"
        out << "    r#{dest_reg} = mrb_funcall_with_block(M, #{recv}, mrb_intern_cstr(M, \"#{region[:name]}\"), " \
               "#{argv.size}, bc2cpp_ebarg_argv_#{region[:sendb_addr]}, r#{region[:blk_reg]});\n"
        out << "  }\n"
      end
    end
    out
  end

  # EXPLICIT_BLOCK_ARG_DIRECT: a fixed-arity `&expr` site whose call resolves to compiled code
  # (ARG_SHAPES_BLOCK). The `_impl` gets the block as the VM's OP_SENDB would hand it on:
  # ensure_block's to_proc conversion runs first, once, before any arm or by-name else.
  # See docs/bc2cpp-explicit-block-args.md.
  def emit_explicit_block_arg_direct(region, owner_def)
    return nil unless explicit_block_arg_direct? && owner_def && region[:n].is_a?(Integer)

    blk = "bc2cpp_ebarg_blk_#{region[:sendb_addr]}"
    direct = compile_direct_block_send(region, blk, owner_def)
    return nil unless direct

    out = String.new
    out << "  // EXPLICIT_BLOCK_ARG :#{region[:name]} -- &expr converted as OP_SENDB does (ensure_block), " \
           "direct call with the block\n"
    out << "  {\n"
    out << "    mrb_value #{blk} = r#{region[:blk_reg]};\n"
    out << "    if (!mrb_nil_p(#{blk}) && !mrb_proc_p(#{blk})) " \
           "#{blk} = mrb_type_convert(M, #{blk}, MRB_TT_PROC, mrb_intern_lit(M, \"to_proc\"));\n"
    out << direct.lines.map { |line| "  #{line}" }.join
    out << "  }\n"
    out
  end

  # BC2CPP_EXPLICIT_BLOCK_ARG_DIRECT=0 keeps every `&expr` site on mrb_funcall_with_block.
  def explicit_block_arg_direct?
    ENV['BC2CPP_EXPLICIT_BLOCK_ARG_DIRECT'] != '0'
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
      glue_at[region[:block_addr]] = emit_block_fallback_glue(region, fn_name, owner_def: d)
    end
    explicit_arg_regions.each do |region|
      next if suppressed.include?(region[:sendb_addr])

      suppressed << region[:sendb_addr]
      glue_at[region[:sendb_addr]] = emit_explicit_block_arg_glue(region, owner_def: d)
    end
    pre
  end
end
