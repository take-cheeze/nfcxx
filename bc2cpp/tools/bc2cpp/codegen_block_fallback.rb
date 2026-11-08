# frozen_string_literal: true

require_relative 'ir_rbs_block_types'
require_relative 'core_block_param_sigs'
require_relative 'core_fact_sigs'
require_relative 'block_capture_index'
require_relative 'block_yielders'

# CodeGen: blocks that stay procs, and fiber safety.

class CodeGen
  # SYNC_BY_DEFINITION: a name admitted to a captured-block fallback because every definition the closed world can
  # dispatch to calls its block without keeping it. Keyed by name; each entry lists the core Ruby owners whose
  # body was read (they call `block` only), and the native owners whose C body takes no block.
  #   to_h: mruby-array-ext and mruby-enum-ext call `blk.call` inside their own `each`; mruby-hash-ext takes no block.
  #   native Struct#to_h, nil.to_h (NilClass) and Data#to_h take no block (checked per function body below).
  SYNC_BY_DEFINITION = {
    'to_h' => { ruby_owners: %w[Array Enumerable Hash], native_owners: %w[Struct NilClass Data] }
  }.freeze

  # A block-taking send of +name+ whose block captures locals runs synchronously in every definition the closed world
  # can dispatch to. Refused when the closed world is not whole (a global refusal, a computed or outside definer, a
  # method_missing that is user code), when a native definer has no owner or a body that cannot be read, when a
  # user definition has a block parameter (it could keep the block) or calls super (super forwards the frame's block).
  def sync_by_definition?(name)
    rule = SYNC_BY_DEFINITION[name]
    return false unless rule
    return false unless @closed_world && @closed_world.global_refusal.nil?
    return false if @closed_world.unknown_def?(name) || @closed_world.unknown_definer?(name) ||
                    @closed_world.invisibly_definable?(name)
    # A user method_missing (a Ruby definition) could receive any name; BasicObject's native one only raises.
    return false if (@registry['method_missing'] || []).any? { |d| d.irep && !d.core }
    return false unless native_definers_sync?(name, rule[:native_owners])

    # Core Ruby definitions of the name are checked by owner; a world with none of them has no body to read.
    (@registry[name] || []).reject { |d| d.owner == '<native>' }.all? do |d|
      next false unless d.kind.nil? && d.irep

      if d.core
        rule[:ruby_owners].include?(d.owner)
      else
        definition = @ireps.fetch(d.irep)
        !BlockYielders.block_param?(definition) && !BytecodeIR.for(definition).op?(:SUPER)
      end
    end
  end

  # The scanner spells mrb->nil_class as `Nil` (capitalizing the field name); the class is NilClass.
  def native_owner_name(owner)
    owner == 'Nil' ? 'NilClass' : owner
  end

  # Every native definer of +name+ is attributed to one of +owners+, and each one's C function is read and takes no
  # block. Attribution comes from NativeExpressionDevirt.class_registrations; an opaque entry with no owner, a missing
  # body or an unattributed definition makes the answer no.
  def native_definers_sync?(name, owners)
    registrations, opaque = block_core_registrations
    regs = registrations.fetch(name, [])
    opaque_owners = opaque.fetch(name, []).map { |owner| native_owner_name(owner) }
    return false if regs.empty? && opaque_owners.empty?
    return false if opaque_owners.any? { |owner| owner.nil? || !owners.include?(owner) }
    return false unless regs.all? { |entry| entry[:owner] && owners.include?(native_owner_name(entry[:owner][:class_name])) }

    functions = regs.map { |entry| [entry[:path], entry[:function]] }
    functions += native_define_functions(name)
    return false if functions.empty?

    functions.all? do |path, function|
      body = path && function && NativeExpressionDevirt.native_function_body(path, function)
      body && !body.match?(/mrb_yield|mrb_block|mrb_proc|mrb_block_given/)
    end
  end

  # The C functions registered for +name+ through mrb_define_method_id in its native sources, as [path, function].
  # Opaque registrations (Data#to_h) are found only this way, so the scan has to name every one of them.
  def native_define_functions(name)
    (@native_name_sources[name] || []).flat_map do |path|
      source = File.file?(path) ? File.read(path) : ''
      source.scan(/mrb_define_method_id\s*\(\s*\w+\s*,\s*\w+\s*,\s*MRB_SYM\(#{Regexp.escape(name)}\)\s*,\s*(\w+)/).map do |(function)|
        [path, function]
      end
    end
  end

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
      # RECEIVER_ROOTS: a call on another receiver (`arr.each_index { ... }`) names a method whose owner the fiber body
      # does not prove, so every definition of that name is a candidate root. Compiling a root that is not reached is
      # harmless: its entry runs the same body, and only a suspension through it needs the resumable form.
      # Guarded core methods are not registry definitions (bc2cpp.rb moves them to core_hidden_defs), so both are searched.
      hidden = self.class.core_hidden_defs || []
      fiber_receiver_call_names(seed_irep).each do |name|
        candidates = (@registry[name] || []) + hidden.select { |d| d.name == name }
        candidates.each { |d| @fiber_roots << d.irep if d.irep }
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
    # CALL_STEP: a method a root calls on self that can itself suspend is a root too. BLOCKS_IN_STEPS: so is one a root calls
    # with a literal block that reaches Fiber.yield; its name then counts as a yielding name.
    # DYN_CALL: a method a fiber reaches that sends by name can reach the program's other yielding methods.
    @fiber_roots.merge(dynamic_send_targets) if reachable.any? { |l| (i = @ireps[l]) && deep_send_names(i).intersect?(DYN_SEND_NAMES) }
    queue = @fiber_roots.to_a + seeds
    until queue.empty?
      label = queue.shift
      irep = @ireps[label]
      owner = irep_owner[label]
      next unless irep && owner

      enroll = lambda do |sym, yielding|
        target = by_owner_name[[owner, sym]]
        next unless target

        @fiber_yield_names << sym if yielding
        queue << target if @fiber_roots.add?(target)
      end
      # A call in a block nested in the root counts too: the block is a step of the root's own.
      irep_tree(irep).flat_map { |part| BytecodeIR.for(part).instructions_with_op(:SSEND, :SSEND0).to_a }.each do |insn|
        enroll.call(insn.sym, false) if insn.sym && @fiber_yield_names.include?(insn.sym)
      end
      # DYN_CALL: a root that sends by name may reach any method its symbol literals name.
      if deep_send_names(irep).intersect?(DYN_SEND_NAMES)
        deep_symbol_literals(irep).each do |sym|
          target = by_owner_name[[owner, sym]]
          enroll.call(sym, true) if target && !@fiber_roots.include?(target)
        end
      end
      # A call on self that forwards the root's own block (`other(&block)`) reaches the yield through it.
      BytecodeIR.for(irep).each_with_op(:SSENDB) do |insn, idx|
        prev = BytecodeIR.for(irep).previous(idx)
        enroll.call(insn.sym, true) unless (prev && prev.op == :BLOCK) || !insn.sym
      end
      BytecodeIR.for(irep).adjacent_pairs(:BLOCK, %i[SSENDB]) do |block_insn, paired, _|
        block_label = block_insn.block_index && irep.reps[block_insn.block_index.to_i]
        block_irep = block_label && @ireps[block_label]
        enroll.call(paired.sym, true) if paired.sym && block_irep && deep_fiber_yield?(block_irep, seeds.to_set)
      end
    end
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
    @yield_reach.fiber_unsafe(fiber_defs.keys)
  end

  # DYN_CALL: a send can reach any program method that yields to its block and that some symbol literal names; those become
  # roots, so the dispatcher registry has their step. Core methods keep their own bodies (RESUMABLE_DUAL gives a variant).
  def dynamic_send_targets
    named = Set.new
    @ireps.each_value { |i| BytecodeIR.for(i).instructions_with_op(:LOADSYM).each { |insn| named << insn.sym if insn.sym } }
    named.flat_map { |sym| @registry[sym] || [] }.filter_map do |dd|
      next unless dd.irep && !dd.core && dd.kind.nil? && (i = @ireps[dd.irep]) && BytecodeIR.for(i).op?(:BLKCALL)

      @fiber_yield_names << dd.name
      dd.irep
    end
  end

  # +irep+ and every irep nested in it (block bodies are part of the method that contains them).
  def irep_tree(irep)
    tree = [irep]
    pending = [irep]
    until pending.empty?
      (pending.pop.reps || []).each do |child|
        nested = child && @ireps[child]
        next unless nested

        tree << nested
        pending << nested
      end
    end
    tree
  end

  def tree_syms(irep, *ops)
    irep_tree(irep).flat_map { |part| BytecodeIR.for(part).instructions_with_op(*ops).filter_map(&:sym) }
  end

  def deep_send_names(irep)
    tree_syms(irep, :SEND, :SEND0, :SENDB, :SSEND, :SSEND0, :SSENDB).to_set
  end

  def deep_symbol_literals(irep)
    tree_syms(irep, :LOADSYM)
  end

  # Every self-send name reachable from `irep`, including inside nested block ireps.
  def self_call_targets(irep)
    tree_syms(irep, :SSEND, :SSEND0, :SSENDB)
  end

  def recognize_block_fallback_regions(irep, available_upvars: [], blk_available: false, cell_levels: [])
    regions = []
    BytecodeIR.for(irep).adjacent_pairs(:BLOCK, %i[SENDB SSENDB]) do |insn, paired, sendb_idx|
      idx = sendb_idx - 1
      # EXPLICIT_ARGS_BLOCK_FALLBACK_SUPPORT: any fixed positional count
      # (`ary.inject(0) { }`, `ary.each_slice(2) { }`), but never `n=*` (a splat has
      # no static layout).
      # BLOCK_KEYWORD_CALL: keywords sit between the positionals and the block (a Hash register or key/value pairs).
      next if paired.positional_splat?
      next unless paired.argc_operand

      n = paired.argc.to_i
      dest_reg = paired.reg
      block_reg = insn.reg
      kw = dyn_call_shape(paired)[:kw]
      next unless dest_reg && block_reg && block_reg == dest_reg + n + paired.keyword_slots + 1

      name = paired.sym
      next unless name
      next if kw && name == 'public_send'

      # FIBER_NEW_BLOCK_UNSAFE_SUPPORT: removed; a Fiber.new block is admitted like any other literal block.

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
      synchronous = BLOCK_FALLBACK_UPVAR_SAFE_METHODS.include?(name) || block_proven_to_stay?(irep, idx) ||
                    sync_by_definition?(name)
      # FIBER_BODY_CAPTURE: a Fiber body outlives the frame, so it never takes the frame's addresses (the gates
      # below); where fiber_body_by_value? holds, its locals are copied into a heap Array at the site instead.
      by_value = upvars.any? && fiber_body_by_value?(irep, idx, paired, block_irep, upvars)
      # STEP_CLOSURES: a block that may outlive the call (the callee is not proven to leave it) captures this function's registers
      # through heap cells (an Array the block's env keeps), so no pointer outlives its frame.
      # `new` keeps its block (Hash.new's default proc, Proc.new, Fiber.new's body) unless the receiver is Array.
      keeps_block = name == 'new' && !array_const_receiver?(irep, idx, dest_reg)
      # A block that is only called during the call still needs cells when a block it builds may be kept and reads
      # the frames above it (its pointers must lead into cells too).
      boxed = upvars.any? && !by_value && cells_capture?(upvars, cell_levels) &&
              (!synchronous || keeps_block || nested_keeps_upper_cells?(block_irep, upvars))
      next if upvars.any? && !synchronous && !by_value && !boxed

      # BLOCK_SEMANTICS: `new` is on the allowlist for Array.new only. Hash.new
      # keeps its block as the default proc and Proc.new returns it, either of
      # which outlives this frame and would hold pointers into it.
      next if upvars.any? && keeps_block && !by_value && !boxed

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
                 block_irep: block_irep, name: name, n: n, kw: kw,
                 self_implicit: paired.op == :SSENDB, upvars: upvars, needs_blk: needs_blk,
                 parent_irep: irep, boxed: boxed, by_value: by_value }
      # BLOCK_SEMANTICS: the tokens this block's env must carry. A return token is
      # forwarded by every enclosing block, so it is needed for a `return` at any depth.
      region[:needs_brk] = BytecodeIR.for(block_irep).op?(:BREAK)
      region[:cell_levels] = upvars.map(&:first).uniq.sort if boxed
      region[:needs_ret] = BytecodeIR.for(block_irep).op?(:RETURN_BLK) ||
                           recognize_block_fallback_regions(block_irep, available_upvars: upvars, cell_levels: region_cell_levels(region))
                           .any? { |nested| nested[:needs_ret] }
      regions << region
    end
    regions
  end

  # STEP_CLOSURES: only the registers of the function that makes the block can be boxed. A level >= 1 pointer is the enclosing
  # function's, so +cell_levels+ lists the upvar levels this function holds cells for.
  def cells_capture?(upvars, cell_levels = [])
    ENV['BC2CPP_STEP_CLOSURES'] != '0' && upvars.all? { |(level, _)| level.zero? || cell_levels.include?(level - 1) }
  end

  # Does a block nested in +block_irep+ (whose own upvars are +upvars+) keep and read a frame above it? Then +block_irep+'s
  # region holds those frames' cells for it.
  def nested_keeps_upper_cells?(block_irep, upvars)
    levels = upvars.map(&:first).uniq
    recognize_block_fallback_regions(block_irep, available_upvars: upvars, cell_levels: levels)
      .any? { |nested| nested[:boxed] && nested[:upvars].any? { |(level, _)| level >= 1 } }
  end

  # The C++ values a boxed region's env carries as cells, one per level of its upvars (in the function that builds it:
  # level 0 is its own cells Array, level L the cells it holds for its upvar level L - 1).
  def region_cells_exprs(region)
    return nil unless region[:boxed]

    region_cell_levels(region).map { |level| level.zero? ? 'bc2cpp_cells_ary' : "bc2cpp_up_cells_#{level - 1}" }
  end

  def region_cell_levels(region)
    region[:boxed] ? (region[:cell_levels] || [0]) : []
  end

  # The registers of a function that its recognized +regions+ capture through cells, sorted.
  def boxed_registers(regions)
    regions.select { |region| region[:boxed] }.flat_map { |region| region[:upvars].select { |(level, _)| level.zero? }.map(&:last) }.uniq.sort
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
    return {} unless irep && !region[:self_implicit] && !region[:kw]

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
      return shape.elements.to_h { |pos| [pos + 1, strict ? element : SoftElementHint.new(element)] }
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
               elsif (const_name = IrBlockOperands.constant_name(irep, idx, region[:dest_reg]))
                 # CONSTANT_BLOCK_HINT: a class-object receiver (`File.open { }`) is a singleton call, defined by what
                 # constant_object_core_def proves for the constant's singleton chain.
                 target = constant_object_core_def(name, const_name)
                 target&.irep ? [target.owner] : nil
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
    return nil unless classes

    names = classes.map(&:to_s).sort
    return names.first if names.size == 1

    # UNION_ELEMENT_HINT: a union of one class and its subclasses (`IO | File`, File < IO) is typed by their common
    # ancestor, with each member guarded exactly. Any other union stays untyped.
    ancestor = names.find { |a| names.all? { |c| c == a || ancestor_class?(a, c) } }
    return nil unless ancestor && names.size <= 4

    AncestorElementHint.new(ancestor, names)
  end

  # True when +ancestor+ is a proper superclass of +klass+, through the closed world's hierarchy or the core's.
  def ancestor_class?(ancestor, klass)
    current = klass
    seen = Set.new
    while current.is_a?(String) && seen.add?(current)
      current = @closed_world.class_parent(current) || core_superclass(current)
      return true if current == ancestor
    end
    false
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
    return false unless @closed_world.class_declared?(klass)
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
    # FIBER_BODY: the nested regions are emitted inside this body, so the marker must be set before them.
    saved_fiber_prologue = @fiber_prologue
    @fiber_prologue = d && fiber_body_target_id(region, d) ? region[:block_irep] : nil
    saved_self_class_unknown = @self_class_unknown
    @self_class_unknown = saved_self_class_unknown || runtime_def_fallback_kind?(region[:kind])
    result = emit_proc_fallback_fn_body(region, d, fn_prefix)
    result && [result[0], result[1] + proc_spec_registration(region, result[0])]
  ensure
    @self_class_unknown = saved_self_class_unknown
    @fiber_prologue = saved_fiber_prologue
  end

  # PROC_SPEC: a compiled block is a C function proc with no ENTER word or parameter names, so bc2cpp_proc_spec_stand_in is
  # registered under its C function and direct entry for Proc#arity and Proc#parameters.
  def proc_spec_registration(region, fn_name)
    return '' unless (region[:kind] || 'block_fallback') == 'block_fallback'

    block = region[:block_irep]
    fields = (block.enter ? block.enter.enter_fields.map(&:to_i) : []) + [0] * 7
    m1, opt, rest, m2, key, kdict, blk = fields
    aspec = (m1 << 18) | (opt << 13) | (rest << 12) | (m2 << 7) | (key << 2) | (kdict << 1) | blk
    names = (block.lv || []).first([block.nlocals.to_i - 1, 0].max)
    @proc_spec_seq = @proc_spec_seq.to_i + 1
    id = "bc2cpp_proc_spec_#{@proc_spec_seq}"
    out = String.new
    out << "static const mrb_code #{id}_iseq[] = { OP_ENTER, #{(aspec >> 16) & 0xff}, #{(aspec >> 8) & 0xff}, #{aspec & 0xff}, OP_RETURN, 0 };\n"
    out << "static const char* const #{id}_names[] = { #{(names.map { |n| c_string_literal(n.to_s) } + ['nullptr']).join(', ')} };\n"
    # A direct-entry block has no C function of its own (its proc runs the shared thunk, and the entry names the block).
    keys = [region[:direct_entry] ? "(const void*)&#{fn_name}_direct" : "(const void*)&#{fn_name}"]
    out << "static const int #{id} = #{keys.map { |k| "bc2cpp_proc_spec_register(#{k}, #{id}_iseq, 6, #{block.nlocals.to_i}, #{id}_names)" }.join(' + ')};\n\n"
    out
  end

  def emit_proc_fallback_fn_body(region, d, fn_prefix)
    block_irep = region[:block_irep]
    # BLOCK_SELF_WORLD: every block or lambda body compiled here reads its creator's self; a rebound one
    # never runs under it. The recognizers already skip these; this keeps any other caller from compiling one.
    return nil if !runtime_def_fallback_kind?(region[:kind]) && block_self_rebound?(block_irep.label)
    mand = mandatory_arity(block_irep)
    rest_block = (region[:kind] || 'block_fallback') == 'block_fallback' && rest_only_block?(block_irep)
    # MIXED_REST_BLOCK: m values, then the rest Array as the last parameter (mixed_rest_unpack fills them).
    mixed_rest = (region[:kind] || 'block_fallback') == 'block_fallback' && !rest_block && mixed_rest_block?(block_irep)
    arg_count = rest_block ? 1 : (mixed_rest ? mand + 1 : mand)
    arg_names = (1..arg_count).map { |i| "bc2cpp_barg#{i}" }
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
    # STEP_CLOSURES: a boxed region's env ends with the cells Arrays of its upvar levels; the body takes them as parameters.
    cell_levels = region_cell_levels(region)
    cells_slot = next_slot + (ret_slot ? 1 : 0) + (brk_slot ? 1 : 0)
    cell_params = cell_levels.map { |l| "mrb_value bc2cpp_up_cells_#{l}" }
    cell_args = cell_levels.map { |l| "bc2cpp_up_cells_#{l}" }
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
    # RANGE_MAP_INLINE: a counted `(a..b).map` in this body runs as a loop here, not as one nested cfunc call per
    # element (fallback_range_map_inlines); claimed before the nested pass so it does not take the block.
    fallback_range_map_inlines(block_irep, upvar_regs, d).each do |rregion, code|
      next if nested_suppressed.include?(rregion[:block_addr]) || nested_suppressed.include?(rregion[:sendb_addr])

      nested_suppressed << rregion[:block_addr] << rregion[:sendb_addr]
      nested_glue_at[rregion[:block_addr]] = code
    end
    nested_regions = recognize_block_fallback_regions(block_irep, available_upvars: upvar_regs, blk_available: needs_blk,
                                                      cell_levels: cell_levels)
    nested_regions.each do |nregion|
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
    saved_cell_levels = @block_cell_levels
    @block_cell_levels = cell_levels
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
      extra_fields += cell_args.map { |name| { name: name, c_type: 'mrb_value' } }
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
      elem_hints = { 1 => rbs_class } if rbs_class
    end
    body << "  // RBS_BLOCK_PARAM_HINT :#{region[:name]} parameter 1 -> #{rbs_class}\n" if rbs_class
    arm_prune_block_analysis(block_irep, d, 0)
    # TAIL_YIELD_BLOCK: see tail_yield_block?; the direct entry scopes the one call the adapter armed.
    saved_tail_yield_block = @tail_yield_block
    @tail_yield_block = tail_yield_block?(block_irep) ? block_irep : nil
    region[:tail_yield] = !@tail_yield_block.nil?
    @fiber_body_used = true if region[:tail_yield]
    # BLOCK_ENSURE: a `begin ... ensure` in the body is the guard scope compile_method opens (ENSURE_RAII_SUPPORT), so a
    # `break` or `return` thrown out of it runs the ensure body on the way.
    prefix_at = block_ensure_prefixes(block_irep, d, targets, nested_suppressed)
    BytecodeIR.for(block_irep).each_source do |insn, idx|
      next if insn.op == :ENTER

      body << prefix_at[insn.addr] if prefix_at.key?(insn.addr)
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
    @tail_yield_block = saved_tail_yield_block
    @ensure_except_remaps = nil
    @block_fallback_upvars = nil
    @block_cell_levels = saved_cell_levels
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
           "#{upvar_params.map { |p| ", #{p}" }.join}#{blk_param.map { |p| ", #{p}" }.join}#{cell_params.map { |p| ", #{p}" }.join}" \
           "#{arg_names.map { |a| ", mrb_value #{a}" }.join}) {\n"
    out << errinfo_scope_line(block_irep)
    out << emit_register_initializers(block_irep.nregs, arg_names, boxed: boxed_registers(nested_regions))
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
      out << emit_block_direct_entry(fn_name, impl_name, region, upvar_regs, needs_blk, mand, arg_names, rest_block,
                                     mixed_rest: mixed_rest, cells: [cell_args, cells_slot])
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
    elsif region[:free]
      # FREE_LAMBDA (codegen_class_body.rb): the proc has no env, so nothing is read from it; the body reads no self.
      out << "static mrb_value #{fn_name}(mrb_state* M, mrb_value bc2cpp_passed_self) {\n"
      out << "  mrb_value bc2cpp_captured_self = bc2cpp_passed_self;\n"
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
      out << "  mrb_value* #{vname} = reinterpret_cast<mrb_value*>(static_cast<uintptr_t>(mrb_integer(mrb_proc_cfunc_env_get(M, #{i + 1}))));\n"
      vname
    end
    # BLOCK_FALLBACK_YIELD_SUPPORT: the forwarded block is the last env slot, read
    # back as a plain mrb_value (a copy, kept GC-reachable by the env).
    if needs_blk
      out << "  mrb_value bc2cpp_blk = mrb_proc_cfunc_env_get(M, #{upvar_regs.size + 1});\n"
    end
    cell_args.each_with_index { |name, i| out << "  mrb_value #{name} = mrb_proc_cfunc_env_get(M, #{cells_slot + i});\n" }
    call_args = (['bc2cpp_captured_self'] + upvar_args + (needs_blk ? ['bc2cpp_blk'] : []) + cell_args).join(', ')
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
      elsif mixed_rest
        out << "  mrb_value* bc2cpp_argv;\n"
        out << "  mrb_int bc2cpp_argc;\n"
        out << "  mrb_get_args(M, \"*\", &bc2cpp_argv, &bc2cpp_argc);\n"
        out << mixed_rest_unpack(arg_names, mand, 'bc2cpp_argc', 'bc2cpp_argv', strict: 'bc2cpp_proc_strict_p(M)')
        out << call_impl.call("M, #{call_args}, #{arg_names.join(', ')}")
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
  # MIXED_REST_BLOCK: binds `arg_names` for `{ |x, *r| }` from the yielded values (argc, argv), as vm.c does for a
  # non-lambda block: one Array argument is spread over the parameters (only when the block takes more than one).
  # A strict (lambda) block also rejects too few arguments; an extra one goes to the rest Array.
  def mixed_rest_unpack(arg_names, mand, argc, argv, strict:)
    values = arg_names[0...mand]
    rest = arg_names[mand]
    out = String.new
    out << "  if (#{strict} && #{argc} < #{mand}) mrb_argnum_error(M, #{argc}, #{mand}, -1);\n"
    out << "  mrb_value bc2cpp_mixed_vals = (#{argc} == 1 && mrb_array_p(#{argv}[0])) ? #{argv}[0] : " \
           "mrb_ary_new_from_values(M, #{argc}, #{argv});\n"
    out << "  mrb_int bc2cpp_mixed_len = RARRAY_LEN(bc2cpp_mixed_vals);\n"
    values.each_with_index do |a, i|
      out << "  mrb_value #{a} = bc2cpp_mixed_len > #{i} ? mrb_ary_ref(M, bc2cpp_mixed_vals, #{i}) : mrb_nil_value();\n"
    end
    out << "  mrb_value #{rest} = mrb_ary_new(M);\n"
    out << "  for (mrb_int bc2cpp_k = #{mand}; bc2cpp_k < bc2cpp_mixed_len; bc2cpp_k++) " \
           "mrb_ary_push(M, #{rest}, mrb_ary_ref(M, bc2cpp_mixed_vals, bc2cpp_k));\n"
    out
  end

  def emit_block_direct_entry(fn_name, impl_name, region, upvar_regs, needs_blk, mand, arg_names, rest_block,
                              mixed_rest: false, cells: [[], 0])
    out = String.new
    out << "static mrb_value #{fn_name}_direct(mrb_state* M, struct REnv* bc2cpp_env, bool bc2cpp_strict, " \
           "mrb_int bc2cpp_argc, const mrb_value* bc2cpp_argv) {\n"
    out << "  (void)bc2cpp_strict; (void)bc2cpp_argc; (void)bc2cpp_argv;\n"
    out << "  mrb_value bc2cpp_captured_self = bc2cpp_env->stack[0];\n"
    out << "  Bc2cppTailYieldScope bc2cpp_tail_scope(bc2cpp_env);\n" if region[:tail_yield]
    upvar_args = upvar_regs.each_with_index.map do |(l, b), i|
      vname = upvar_var_name(l, b)
      out << "  mrb_value* #{vname} = reinterpret_cast<mrb_value*>(static_cast<uintptr_t>(mrb_integer(bc2cpp_env->stack[#{i + 1}])));\n"
      vname
    end
    out << "  mrb_value bc2cpp_blk = bc2cpp_env->stack[#{upvar_regs.size + 1}];\n" if needs_blk
    cell_names, cells_slot = cells
    cell_names.each_with_index { |name, i| out << "  mrb_value #{name} = bc2cpp_env->stack[#{cells_slot + i}];\n" }
    call_args = (['bc2cpp_captured_self'] + upvar_args + (needs_blk ? ['bc2cpp_blk'] : []) + cell_names).join(', ')
    if rest_block
      out << "  return #{impl_name}(M, #{call_args}, mrb_ary_new_from_values(M, bc2cpp_argc, bc2cpp_argv));\n"
    elsif mixed_rest
      out << mixed_rest_unpack(arg_names, mand, 'bc2cpp_argc', 'bc2cpp_argv', strict: 'bc2cpp_strict')
      out << "  return #{impl_name}(M, #{call_args}, #{arg_names.join(', ')});\n"
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
                              ret_token: nil, brk_token: nil, direct_entry: nil, yield_free: false, upvar_cells: nil,
                              step_maker: nil, unwind_targets: nil, cells: nil)
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
    ptr = ->(expr) { "mrb_int_value(M, static_cast<mrb_int>(reinterpret_cast<uintptr_t>(#{expr})))" }
    env_entries = ['self'] + upvar_regs.each_with_index.map do |(l, b), i|
      if upvar_cells
        # FIBER_BODY_CAPTURE: the pointers lead into a heap Array holding a snapshot of the locals, not into this frame.
        ptr.call("&#{upvar_cells}[#{i}]")
      elsif inline_offset
        ptr.call("&r#{l.zero? ? b + inline_offset : b}")
      elsif l.zero?
        ptr.call("&r#{b}")
      else
        ptr.call(upvar_var_name(l - 1, b))
      end
    end
    # FIBER_BODY_CAPTURE: the snapshot Array rides in the env, right after the upvar pointers, so the GC keeps it.
    env_entries << "#{upvar_cells}_ary" if upvar_cells
    # The block is copied to a heap RProc when it is frame-local (bc2cpp_env_block): this env is heap, and outlives the frame.
    env_entries << 'bc2cpp_env_block(M, bc2cpp_blk)' if needs_blk
    env_entries << ret_token if ret_token
    env_entries << brk_token if brk_token
    # STEP_CLOSURES: the cells Array the captured registers live in goes after the tokens (readers index from the end); the
    # env keeps it so the pointers outlive the frame.
    env_entries.concat(cells) if cells
    if direct_entry
      # BLOCK_STEP_UNWIND: the frames a `return` / `break` of the block's step ends (it must name them to the fiber), just
      # before the maker: return target, then break target.
      env_entries.concat(unwind_targets) if step_maker && unwind_targets
      # BLOCK_STEP: the maker of the block's step frame sits just before the entry (the readers index from the end).
      env_entries << ptr.call("&#{step_maker}") if step_maker
      env_entries << ptr.call("&#{direct_entry}")
      # The flag slot: YIELD_FREE (bit 0), the BLOCK_SELF_WORLD check (bit 1) and BLOCK_STEP (bit 2: the maker slot is
      # present), read by bc2cpp_block_thunk and the C++ Fiber's adapter.
      env_entries << "mrb_int_value(M, #{(yield_free ? 1 : 0) | (block_self_check? ? 2 : 0) | (step_maker ? 4 : 0) | (step_maker && unwind_targets ? 8 : 0)})"
    end
    # BLOCK_STEP_UNWIND: a block that returns or breaks has no direct entry (its plain body reads its tokens from a cfunc frame),
    # so it stays an ordinary cfunc proc; the trailer marks it for the fiber's adapter with a magic flag word.
    if !direct_entry && step_maker && unwind_targets
      env_entries.concat(unwind_targets)
      env_entries << ptr.call("&#{step_maker}")
      env_entries << 'mrb_int_value(M, 0)'
      env_entries << "mrb_int_value(M, #{BLOCK_STEP_MAGIC | 4 | 8})"
    end
    out << "    mrb_value bc2cpp_blk_env_#{addr}[] = { #{env_entries.join(', ')} };\n"
    out << "    struct RProc* #{var} = bc2cpp_heap_proc(M, #{direct_entry ? 'bc2cpp_block_thunk' : fn_name}, " \
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
  # The flag word of a step trailer on a block that is not a thunk (direct-entry) proc.
  BLOCK_STEP_MAGIC = 0x5b2c0000

  def emit_block_fallback_glue(region, fn_name, inline_offset: nil, owner_def: nil)
    dest_reg = region[:dest_reg].to_i + (inline_offset || 0)
    recv = region[:self_implicit] ? 'self' : "r#{dest_reg}"
    argv = (1..region[:n]).map { |k| "r#{dest_reg + k}" }
    kw = shifted_keywords(region[:kw], inline_offset)
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
    # FIBER_BODY: `Fiber.new { prologue; m(args) }` is a C++ Fiber whose root frame runs the block and then the
    # suspendable method `m` (tools/bc2cpp/runtime/bc2cpp_fiber.hxx), not an mruby Fiber over a cfunc proc.
    if !kw && (fiber_id = fiber_body_target_id(region, owner_def))
      @fiber_body_used = true
      return emit_fiber_body_site(region, fn_name, fiber_id, dest_reg)
    end
    if inline_offset.nil? && (call = resumable_block_call_glue(region, fn_name, dest_reg, owner_def))
      return call
    end
    if !kw && owner_def && region[:direct_entry] && fiber_new_site?(region) && block_step_maker_for(region)
      return emit_fiber_body_step_site(region, fn_name, dest_reg)
    end
    rproc_var, ctor = emit_rproc_construction(region[:block_addr], fn_name, region[:upvars] || [],
                                              region[:needs_blk] ? true : false, inline_offset: inline_offset,
                                              cells: region_cells_exprs(region),
                                              ret_token: ret_token, brk_token: brk_token,
                                              direct_entry: region[:direct_entry] ? "#{fn_name}_direct" : nil,
                                              yield_free: region[:yield_free],
                                              step_maker: region[:direct_entry] ? block_step_maker_for(region) : nil)
    # ARG_SHAPES_BLOCK: a top-level site whose call resolves to compiled code.
    # BLOCK_ARM_REACH: a block nested in an inlined loop body takes the same arms, shifted.
    stack_expr = stack_block_expr(region)
    # FIBER_BODY: the tail call of a Fiber body prologue goes through the method's entry (no inlined arm), after storing
    # its receiver for the handoff check (bc2cpp_prologue_armed).
    prologue_tail = !kw && fiber_prologue_tail_region?(region)
    # BLOCK_KEYWORD_CALL: no direct arm models keywords.
    direct = if prologue_tail || kw
               nil
             elsif inline_offset.nil?
               compile_direct_block_send(region, "mrb_obj_value(#{rproc_var})", owner_def, stack_expr: stack_expr)
             elsif owner_def && block_arm_reach?
               compile_direct_block_send(region, "mrb_obj_value(#{rproc_var})", owner_def, inline_offset: inline_offset,
                                                                                         stack_expr: stack_expr)
             end
    ctor, direct = stack_block_glue(region, rproc_var, ctor, direct) if direct && stack_expr && direct.include?(stack_expr)
    owner_call = nil
    unless direct || kw
      owner_call = block_owner_call_line("r#{dest_reg}", recv, region[:name], argv, "mrb_obj_value(#{rproc_var})")
      # STATIC_OWNER_ARMS may put compiled arms in front of this owner call; built over the frame, they take the
      # stack block the way a direct call does, and the heap RProc is made only when the owner call runs.
      if owner_call && stack_expr && !static_owner_arm_targets(region[:name], argv.size, true).empty?
        ctor, owner_call = stack_block_glue(region, rproc_var, ctor, owner_call)
      end
    end
    out = String.new
    out << "  bc2cpp_prologue_set_recv(#{recv});\n" if prologue_tail && !region[:self_implicit]
    out << "  // BLOCK_FALLBACK :#{region[:name]} -- block body compiled as a standalone cfunc, wrapped as a real RProc " \
           "(self captured at construction time), #{direct ? 'direct call with the block' : 'dynamic dispatch'}\n"
    out << "  {\n"
    out << "    Bc2cppFrameGuard #{site}(&bc2cpp_break_frames);\n" if region[:needs_brk]
    out << ctor
    # EXCEPTION_BREAK_SUPPORT: only a body with a BREAK can throw to this site.
    indent = region[:needs_brk] ? '      ' : '    '
    out << "    Bc2cppVmMark bc2cpp_brk_mark = bc2cpp_vm_mark(M);\n    try {\n" if region[:needs_brk]
    if direct
      out << indent_lines(direct, indent)
    else
      # BLOCK_SEMANTICS: `pr.call(x) { ... }` on a cfunc Proc cannot use Proc#call
      # (see bc2cpp_cfunc_proc_call_p); the block is dropped, as a cfunc proc
      # takes none.
      args = argv.empty? ? 'NULL' : "bc2cpp_blk_argv_#{region[:block_addr]}"
      out << "#{indent}mrb_value bc2cpp_blk_argv_#{region[:block_addr]}[] = { #{argv.join(', ')} };\n" unless argv.empty?
      name = "mrb_intern_cstr(M, \"#{region[:name]}\")"
      if PROC_CALL_NAMES.include?(region[:name]) && !kw
        out << "#{indent}if (mrb_type(#{recv}) == MRB_TT_PROC && bc2cpp_cfunc_proc_call_p(M, #{recv}, #{name})) {\n"
        out << "#{indent}  r#{dest_reg} = bc2cpp_yield_argv(M, #{recv}, #{argv.size}, #{args});\n"
        out << "#{indent}} else\n"
      end
      out << if kw
               keyword_call_lines(kw, indent, "bc2cpp_kd_#{region[:block_addr]}") +
                 "#{indent}r#{dest_reg} = bc2cpp_funcall_kw(M, #{recv}, #{keyword_call_target(region[:name], name, argv, args)}, " \
                 "bc2cpp_kd_#{region[:block_addr]}, mrb_obj_value(#{rproc_var}));\n"
             elsif owner_call
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
      out << "      if (M->exc) mrb_exc_raise(M, mrb_obj_value(M->exc));  // an ensure body raised: it replaces the break\n"
      out << "      r#{dest_reg} = bc2cpp_brk.value;\n"
      out << "    }\n"
    end
    out << "  }\n"
    out
  end

  # The text to emit ahead of an address of a block body whose ensure region is a guard scope; +targets+ and +suppressed+
  # (arrays) are updated as compile_method does. Empty when the body has none, or its ensure body does not compile.
  def block_ensure_prefixes(block_irep, d, targets, suppressed)
    region = recognize_ensure_region(block_irep)
    return {} unless region

    open_glue, ok = emit_ensure_guard(region, block_irep, d)
    return {} unless ok

    prefix_at = { region[:begin_addr] => (region[:entry_label] ? "  L#{region[:begin_addr]}:;\n" : '') + open_glue,
                  region[:except_addr] => "  } // ensure guard leaves scope: runs the ensure body\n" }
    targets.delete(region[:begin_addr]) if region[:entry_label]
    unless region[:except_jump_srcs].empty?
      prefix_at[region[:raiseif_addr]] = "  L#{region[:raiseif_addr]}:;\n"
      @ensure_except_remaps = { block_irep => { region[:except_addr] => region[:raiseif_addr] } }
    end
    folded = (region[:except_addr]..region[:raiseif_addr]).to_a
    suppressed.concat(folded)
    targets.replace(targets - folded)
    prefix_at
  end

  def shifted_keywords(kw, inline_offset)
    return kw if kw.nil? || inline_offset.nil?

    kw.merge(reg: kw[:reg] + inline_offset)
  end

  # "mid, argc, argv" of a keyword call; `send(:m, ...)` calls :m with the rest (Kernel#send would drop the keywords).
  def keyword_call_target(name, name_expr, argv, args)
    return "#{name_expr}, #{argv.size}, #{args}" unless %w[send __send__].include?(name) && !argv.empty?

    "mrb_obj_to_sym(M, #{argv.first}), #{argv.size - 1}, #{argv.size > 1 ? "#{args} + 1" : 'NULL'}"
  end

  # C++ lines leaving the call's keyword Hash in +var+.
  def keyword_call_lines(kw, indent, var)
    if kw[:kind] == :hash
      return "#{indent}mrb_value #{var} = r#{kw[:reg]};\n"
    end

    out = String.new("#{indent}mrb_value #{var} = mrb_hash_new(M);\n")
    kw[:n].times do |i|
      out << "#{indent}mrb_hash_set(M, #{var}, r#{kw[:reg] + 2 * i}, r#{kw[:reg] + 2 * i + 1});\n"
    end
    out
  end

  # STACK_BLOCK (docs/bc2cpp-stack-blocks.md): a direct-entry block may be built in the frame instead of on the
  # heap. A block that yields to the frame's own block (`needs_blk`) holds that block as it is; Bc2cppBlock::proc copies a
  # frame-local one when the block is wrapped, so a heap env never holds it.
  def stack_block_expr(region)
    return nil unless stack_blocks? && (region[:direct_entry] || stack_cfunc_block?(region))

    "bc2cpp_blk_stack_#{region[:block_addr]}.value()"
  end

  # A block that breaks or returns has no direct entry: a yield runs its cfunc wrapper, which reads the tokens and
  # everything else from the proc's env, so the proc may sit in the frame like a thunk block's.
  def stack_cfunc_block?(region)
    region[:direct_entry] == false && (region[:kind] || 'block_fallback') == 'block_fallback' &&
      region[:self_source] != :receiver && !region[:free]
  end

  # The arms took the frame-local block: build it over the env array, and build the heap RProc only where the
  # remaining code still dispatches (the by-name else), when it runs.
  def stack_block_glue(region, rproc_var, ctor, direct)
    addr = region[:block_addr]
    heap_line = ctor[/^ *struct RProc\* #{rproc_var} = bc2cpp_heap_proc\(M, ([\w$]+), (\d+), bc2cpp_blk_env_#{addr}\);\n/]
    return [ctor, direct] unless heap_line

    fn = Regexp.last_match(1)
    len = Regexp.last_match(2)
    heap_ref = "mrb_obj_value(#{rproc_var})"
    entry = fn == 'bc2cpp_block_thunk' ? '' : "#{fn}, "
    lines = "    Bc2cppBlock bc2cpp_blk_stack_#{addr}(M, #{entry}#{len}, bc2cpp_blk_env_#{addr});\n"
    direct = direct.gsub(heap_ref, "bc2cpp_blk_stack_#{addr}.proc()") if direct.include?(heap_ref)
    [ctor.sub(heap_line, lines).sub("bc2cpp_env_block(M, bc2cpp_blk)", "bc2cpp_blk"), direct]
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

      # EXPLICIT_BLOCK_ARG_DYNAMIC_SPLAT_SUPPORT: `n=*` with `&expr`. The args Array is already built in R(dest+1) (see
      # compile_dynamic_splat_send); the keywords and the block follow it.
      next unless insn.argc_operand

      dest_reg = insn.reg
      next unless dest_reg

      name = insn.sym
      next unless name

      shape = dyn_call_shape(insn)
      # Outside a step, `public_send` and a splatted `send` with keywords have no by-name translation.
      next if shape[:kw] && !@resumable && (name == 'public_send' || (DYN_SEND_NAMES.include?(name) && insn.positional_splat?))

      if insn.positional_splat?
        regions << { sendb_addr: insn.addr, dest_reg: dest_reg, n: '*',
                     argv_reg: dest_reg + 1,
                     blk_reg: shape[:blk_reg], name: name, kw: shape[:kw],
                     self_implicit: insn.op == :SSENDB }
      else
        n = insn.argc.to_i
        regions << { sendb_addr: insn.addr, dest_reg: dest_reg, n: n,
                     blk_reg: shape[:blk_reg], name: name, kw: shape[:kw],
                     self_implicit: insn.op == :SSENDB, parent_irep: irep }
      end
    end
    regions
  end

  def emit_explicit_block_arg_glue(region, owner_def: nil)
    dyn = owner_def && resumable_explicit_block_dyn(region)
    return dyn if dyn
    return emit_explicit_block_arg_keyword_call(region) if region[:kw]

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

  # BLOCK_KEYWORD_CALL: `recv.m(args, k: v, &expr)` outside a step.
  def emit_explicit_block_arg_keyword_call(region)
    dest_reg = region[:dest_reg].to_i
    recv = region[:self_implicit] ? 'self' : "r#{dest_reg}"
    var = "bc2cpp_ebkw_#{region[:sendb_addr]}"
    out = String.new
    out << "  // EXPLICIT_BLOCK_ARG :#{region[:name]} -- keywords and a forwarded &expr block in one by-name call\n  {\n"
    out << keyword_call_lines(region[:kw], '    ', "#{var}_kd")
    if region[:n] == '*'
      ary = "r#{region[:argv_reg]}"
      count = "ary_size(#{ary})"
      items = "ary_items(#{ary})"
    else
      argv = (1..region[:n]).map { |k| "r#{dest_reg + k}" }
      out << "    mrb_value #{var}_argv[] = { #{(argv + ['mrb_nil_value()']).join(', ')} };\n"
      count = argv.size
      items = "#{var}_argv"
    end
    target = region[:n] == '*' ? "mrb_intern_cstr(M, \"#{region[:name]}\"), #{count}, #{items}" :
             keyword_call_target(region[:name], "mrb_intern_cstr(M, \"#{region[:name]}\")", argv, "#{var}_argv")
    out << "    r#{dest_reg} = bc2cpp_funcall_kw(M, #{recv}, #{target}, #{var}_kd, r#{region[:blk_reg]});\n  }\n"
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
    out << indent_lines(direct, '  ')
    out << "  }\n"
    out
  end

  # BC2CPP_EXPLICIT_BLOCK_ARG_DIRECT=0 keeps every `&expr` site on mrb_funcall_with_block.
  def explicit_block_arg_direct?
    ENV['BC2CPP_EXPLICIT_BLOCK_ARG_DIRECT'] != '0'
  end

  # INSTANCE_EVAL_IVAR: `obj.instance_eval { @x }` and `{ @x = v }` read and write an instance variable of +obj+ without a
  # block (mruby-enumerator's Enumerator#each is written that way).
  def recognize_instance_eval_ivar_regions(irep)
    return [] if (@registry['instance_eval'] || []).any? { |dd| dd.irep && !dd.core }

    regions = []
    BytecodeIR.for(irep).adjacent_pairs(:BLOCK, %i[SENDB]) do |insn, paired, _|
      next unless paired.sym == 'instance_eval' && paired.plain_fixed_argc? && paired.argc.to_i.zero?
      next unless insn.reg == paired.reg.to_i + 1

      label = insn.block_index && irep.reps[insn.block_index.to_i]
      block = label && @ireps[label]
      next unless block && (block.reps || []).empty?

      ops = BytecodeIR.for(block).instructions.map(&:source).reject { |s| s.op == :ENTER }
      region = { block_addr: insn.addr, sendb_addr: paired.addr, dest_reg: paired.reg.to_i }
      if ops.map(&:op) == %i[GETIV RETURN] && ops[0].reg == ops[1].reg && ops[0].ivar
        regions << region.merge(kind: :get, ivar: ops[0].ivar)
      elsif ops.map(&:op) == %i[GETUPVAR SETIV RETURN] && ops[0].reg == ops[1].regs.first && ops[1].regs.first == ops[2].reg &&
            ops[1].ivar && ops[0].upvar_ref&.last&.zero?
        regions << region.merge(kind: :set, ivar: ops[1].ivar, value_reg: ops[0].upvar_ref.first)
      end
    end
    regions
  end

  def instance_eval_ivar_glue(region)
    dest = region[:dest_reg]
    name = c_string_literal("@#{region[:ivar]}")
    if region[:kind] == :get
      "  // INSTANCE_EVAL_IVAR :get\n  r#{dest} = mrb_iv_get(M, r#{dest}, mrb_intern_cstr(M, #{name}));\n"
    else
      "  // INSTANCE_EVAL_IVAR :set\n  mrb_iv_set(M, r#{dest}, mrb_intern_cstr(M, #{name}), r#{region[:value_reg]});\n" \
        "  r#{dest} = r#{region[:value_reg]};\n"
    end
  end

  # RESCUE_BODY_BLOCK_SUPPORT: the shared BLOCK_FALLBACK/EXPLICIT_BLOCK_ARG
  # suppress-and-glue pass, used by compile_method and emit_rescue_try_body.
  # Takes recognized region lists (the caller chooses the scope), mutates the
  # caller's suppressed/glue_at, and returns the nested-function pre-code.
  def emit_block_fallback_glue_pass(block_regions, explicit_arg_regions, d, suppressed, glue_at, irep: nil)
    pre = String.new
    block_regions.each do |region|
      next if suppressed.include?(region[:block_addr]) || suppressed.include?(region[:sendb_addr])

      fn_result = emit_proc_fallback_fn(region, d) || step_only_block_fn(region, d)
      next unless fn_result

      fn_name, fn_code = fn_result
      pre << fn_code
      suppressed << region[:block_addr] << region[:sendb_addr]
      glue_at[region[:block_addr]] = emit_block_fallback_glue(region, fn_name, owner_def: d)
    end
    (irep ? recognize_instance_eval_ivar_regions(irep) : []).each do |region|
      next if suppressed.include?(region[:block_addr]) || suppressed.include?(region[:sendb_addr])

      suppressed << region[:block_addr] << region[:sendb_addr]
      glue_at[region[:block_addr]] = instance_eval_ivar_glue(region)
    end
    explicit_arg_regions.each do |region|
      next if suppressed.include?(region[:sendb_addr])

      suppressed << region[:sendb_addr]
      glue_at[region[:sendb_addr]] = emit_explicit_block_arg_glue(region, owner_def: d)
    end
    pre
  end
end
