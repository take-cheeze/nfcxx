# frozen_string_literal: true

# CodeGen: recognizers of inlinable block-loop regions.

class CodeGen
  # BLOCK_SUPPORT (ADR 0147): inline `receiver.times { |i| BODY }` as a native
  # `for` loop instead of building a Proc. mrb_proc_new would build a Proc with
  # no captured environment, while blocks close over outer locals; inlined, the
  # block body shares the method's `r0..rN`, so level-0 GETUPVAR/SETUPVAR are the
  # same variables and RETURN_BLK is a plain C++ return.
  # `#times` has no bytecode definition anywhere in the registry, so a
  # non-Integer receiver already raises NoMethodError when interpreted; the
  # emitted mrb_integer_p guard (raising on mismatch) is equivalent to real
  # dispatch for every receiver.
  # Shape: `SENDB Ra :times n=0` right after `BLOCK R(a+1) I[k]` (the block
  # argument goes in the register after the destination for n=0), with I[k]
  # taking exactly one mandatory argument.
  def recognize_times_regions(irep)
    regions = []
    irep.instructions.each_with_index do |insn, idx|
      next unless insn.op == 'SENDB' && idx.positive?

      dest, name, nstr = insn.args.split(/\s+/, 3)
      next unless name == ':times' && nstr == 'n=0'

      block_insn = irep.instructions[idx - 1]
      next unless block_insn && block_insn.op == 'BLOCK'

      dest_reg = dest[/^R(\d+)/, 1]
      block_reg = block_insn.args[/^R(\d+)/, 1]
      next unless dest_reg && block_reg && block_reg == (dest_reg.to_i + 1).to_s

      block_irep_idx = block_insn.args[/I\[(\d+)\]/, 1]
      next unless block_irep_idx

      block_label = irep.reps[block_irep_idx.to_i]
      block_irep = block_label && @ireps[block_label]
      next unless block_irep && mandatory_arity(block_irep) == 1 && pure_mandatory_arity?(block_irep)

      needs_blk = block_blk_needs(block_irep)
      if needs_blk.nil? || (!needs_blk.empty? &&
         (needs_blk != [1] || !pure_mandatory_arity?(irep) || !(block_irep.reps || []).empty? ||
          !BLOCK_FALLBACK_UPVAR_SAFE_METHODS.include?('times')))
        next
      end

      regions << { block_addr: block_insn.addr, sendb_addr: insn.addr, dest_reg: dest_reg,
                   block_irep: block_irep, needs_blk: needs_blk == [1] }
    end
    regions
  end

  # EACH_BLOCK_SUPPORT (ADR 0152): inline `ary.each { |x| ... }`. Same BLOCK +
  # `SENDB`/`SSENDB Ra :each n=0` adjacency as times. `#each` has bytecode
  # definitions (Game::Actors, Game::Party, LCF::Array2D), so the receiver must
  # trace (trace_new_target) to exactly "Array". An SSENDB (self receiver) is
  # admitted only when the owner is Array itself. Anything unproven gives no
  # region.
  def recognize_each_regions(irep, owner_name, mand, ivar_classes, arg_classes)
    regions = []
    irep.instructions.each_with_index do |insn, idx|
      next unless %w[SENDB SSENDB].include?(insn.op) && idx.positive?

      dest, name, nstr = insn.args.split(/\s+/, 3)
      next unless name == ':each' && nstr == 'n=0'

      block_insn = irep.instructions[idx - 1]
      next unless block_insn && block_insn.op == 'BLOCK'

      dest_reg = dest[/^R(\d+)/, 1]
      block_reg = block_insn.args[/^R(\d+)/, 1]
      next unless dest_reg && block_reg && block_reg == (dest_reg.to_i + 1).to_s

      block_irep_idx = block_insn.args[/I\[(\d+)\]/, 1]
      next unless block_irep_idx

      block_label = irep.reps[block_irep_idx.to_i]
      block_irep = block_label && @ireps[block_label]
      next unless block_irep && mandatory_arity(block_irep) == 1 && pure_mandatory_arity?(block_irep)

      if insn.op == 'SSENDB'
        next unless owner_name == 'Array'
      else
        # CHAINED_ACCESSOR_SUPPORT: passing @class_layout/@registry can only turn nil
        # into 'Array'.
        traced = trace_new_target(irep, idx, dest_reg, ivar_classes, mand, arg_classes, owner: owner_name,
                                   class_layout: @class_layout, registry: @registry,
                                   container_constants: @container_constants)
        traced = proven_array_source(irep, idx, dest_reg) if traced != 'Array'
        next unless traced == 'Array'
      end

      regions << { block_addr: block_insn.addr, sendb_addr: insn.addr, dest_reg: dest_reg, block_irep: block_irep,
                   ssendb: insn.op == 'SSENDB',
                   elem_class: region_element_class(insn, irep, idx, dest_reg, ivar_classes, mand, arg_classes,
                                                   owner_name) }
    end
    regions
  end

  # HASH_EACH_SUPPORT: inline `hash.each { |k, v| ... }`. Same adjacency and
  # `:each` name as recognize_each_regions; the receiver gates ('Array' vs
  # 'Hash') make them exclusive. Hash#each (mrblib/hash.rb) always yields key
  # and value; the emitter assigns them directly to the block's R1/R2 (as the
  # reduce/inject and each_with_index emitters do). No bytecode Hash#each
  # override or Hash subclass exists here; the SSENDB/owner-is-Hash rule is
  # kept for symmetry.
  def recognize_hash_each_regions(irep, owner_name, mand, ivar_classes, arg_classes)
    regions = []
    irep.instructions.each_with_index do |insn, idx|
      next unless %w[SENDB SSENDB].include?(insn.op) && idx.positive?

      dest, name, nstr = insn.args.split(/\s+/, 3)
      next unless name == ':each' && nstr == 'n=0'

      block_insn = irep.instructions[idx - 1]
      next unless block_insn && block_insn.op == 'BLOCK'

      dest_reg = dest[/^R(\d+)/, 1]
      block_reg = block_insn.args[/^R(\d+)/, 1]
      next unless dest_reg && block_reg && block_reg == (dest_reg.to_i + 1).to_s

      block_irep_idx = block_insn.args[/I\[(\d+)\]/, 1]
      next unless block_irep_idx

      block_label = irep.reps[block_irep_idx.to_i]
      block_irep = block_label && @ireps[block_label]
      next unless block_irep && mandatory_arity(block_irep) == 2 && pure_mandatory_arity?(block_irep)

      if insn.op == 'SSENDB'
        next unless owner_name == 'Hash'
      else
        traced = trace_new_target(irep, idx, dest_reg, ivar_classes, mand, arg_classes, owner: owner_name,
                                   class_layout: @class_layout, registry: @registry,
                                   container_constants: @container_constants)
        next unless traced == 'Hash'
      end

      regions << { block_addr: block_insn.addr, sendb_addr: insn.addr, dest_reg: dest_reg, block_irep: block_irep,
                   ssendb: insn.op == 'SSENDB',
                   elem_class: region_hash_element_class(insn, irep, idx, dest_reg, ivar_classes, mand, arg_classes,
                                                        owner_name) }
    end
    regions
  end

  def recognize_hash_each_value_regions(irep, owner_name, mand, ivar_classes, arg_classes)
    regions = []
    irep.instructions.each_with_index do |insn, idx|
      next unless %w[SENDB SSENDB].include?(insn.op) && idx.positive?

      dest, name, nstr = insn.args.split(/\s+/, 3)
      next unless name == ':each_value' && nstr == 'n=0'

      block_insn = irep.instructions[idx - 1]
      next unless block_insn && block_insn.op == 'BLOCK'

      dest_reg = dest[/^R(\d+)/, 1]
      block_reg = block_insn.args[/^R(\d+)/, 1]
      next unless dest_reg && block_reg && block_reg == (dest_reg.to_i + 1).to_s

      block_irep_idx = block_insn.args[/I\[(\d+)\]/, 1]
      next unless block_irep_idx

      block_label = irep.reps[block_irep_idx.to_i]
      block_irep = block_label && @ireps[block_label]
      next unless block_irep && mandatory_arity(block_irep) == 1 && pure_mandatory_arity?(block_irep)

      if insn.op == 'SSENDB'
        next unless owner_name == 'Hash'
      else
        traced = trace_new_target(irep, idx, dest_reg, ivar_classes, mand, arg_classes, owner: owner_name,
                                   class_layout: @class_layout, registry: @registry,
                                   container_constants: @container_constants)
        next unless traced == 'Hash'
      end

      regions << { block_addr: block_insn.addr, sendb_addr: insn.addr, dest_reg: dest_reg, block_irep: block_irep,
                   ssendb: insn.op == 'SSENDB',
                   elem_class: region_hash_element_class(insn, irep, idx, dest_reg, ivar_classes, mand, arg_classes,
                                                        owner_name) }
    end
    regions
  end

  # EACH_INDEX_SUPPORT: inline `ary.each_index { |i| ... }`. Array#each_index
  # (mrblib/array.rb):
  #
  #   def each_index(&block)
  #     return to_enum(:each_index) unless block
  #     idx = 0
  #     while idx < length
  #       yield idx
  #       idx += 1
  #     end
  #     self
  #   end
  #
  # `length` is re-read every pass, the block gets the index, and the result is
  # the receiver. Same adjacency and Array receiver gate as each. No bytecode
  # override exists (the only Array reopens are array_include.rb and
  # array_sort.rb, and LCF::Array1D/Array2D are not Array subclasses).
  def recognize_each_index_regions(irep, owner_name, mand, ivar_classes, arg_classes)
    regions = []
    irep.instructions.each_with_index do |insn, idx|
      next unless %w[SENDB SSENDB].include?(insn.op) && idx.positive?

      dest, name, nstr = insn.args.split(/\s+/, 3)
      next unless name == ':each_index' && nstr == 'n=0'

      block_insn = irep.instructions[idx - 1]
      next unless block_insn && block_insn.op == 'BLOCK'

      dest_reg = dest[/^R(\d+)/, 1]
      block_reg = block_insn.args[/^R(\d+)/, 1]
      next unless dest_reg && block_reg && block_reg == (dest_reg.to_i + 1).to_s

      block_irep_idx = block_insn.args[/I\[(\d+)\]/, 1]
      next unless block_irep_idx

      block_label = irep.reps[block_irep_idx.to_i]
      block_irep = block_label && @ireps[block_label]
      next unless block_irep && mandatory_arity(block_irep) == 1 && pure_mandatory_arity?(block_irep)

      if insn.op == 'SSENDB'
        next unless owner_name == 'Array'
      else
        traced = trace_new_target(irep, idx, dest_reg, ivar_classes, mand, arg_classes, owner: owner_name,
                                   class_layout: @class_layout, registry: @registry,
                                   container_constants: @container_constants)
        traced = proven_array_source(irep, idx, dest_reg) if traced != 'Array'
        next unless traced == 'Array'
      end

      regions << { block_addr: block_insn.addr, sendb_addr: insn.addr, dest_reg: dest_reg, block_irep: block_irep,
                   ssendb: insn.op == 'SSENDB' }
    end
    regions
  end

  # EACH_KEY_SUPPORT: inline `hash.each_key { |k| ... }`. Hash#each_key
  # (mrblib/hash.rb):
  #
  #   def each_key(&block)
  #     return to_enum(:each_key) unless block
  #     self.keys.each {|k| block.call(k)}
  #     self
  #   end
  #
  # It iterates a snapshot (`keys` is a fresh Array, mrb_hash_keys), yields the
  # key, returns the receiver. Same adjacency and Hash receiver gate as
  # recognize_hash_each_regions; no bytecode override exists.
  def recognize_each_key_regions(irep, owner_name, mand, ivar_classes, arg_classes)
    regions = []
    irep.instructions.each_with_index do |insn, idx|
      next unless %w[SENDB SSENDB].include?(insn.op) && idx.positive?

      dest, name, nstr = insn.args.split(/\s+/, 3)
      next unless name == ':each_key' && nstr == 'n=0'

      block_insn = irep.instructions[idx - 1]
      next unless block_insn && block_insn.op == 'BLOCK'

      dest_reg = dest[/^R(\d+)/, 1]
      block_reg = block_insn.args[/^R(\d+)/, 1]
      next unless dest_reg && block_reg && block_reg == (dest_reg.to_i + 1).to_s

      block_irep_idx = block_insn.args[/I\[(\d+)\]/, 1]
      next unless block_irep_idx

      block_label = irep.reps[block_irep_idx.to_i]
      block_irep = block_label && @ireps[block_label]
      next unless block_irep && mandatory_arity(block_irep) == 1 && pure_mandatory_arity?(block_irep)

      if insn.op == 'SSENDB'
        next unless owner_name == 'Hash'
      else
        traced = trace_new_target(irep, idx, dest_reg, ivar_classes, mand, arg_classes, owner: owner_name,
                                   class_layout: @class_layout, registry: @registry,
                                   container_constants: @container_constants)
        next unless traced == 'Hash'
      end

      regions << { block_addr: block_insn.addr, sendb_addr: insn.addr, dest_reg: dest_reg, block_irep: block_irep,
                   ssendb: insn.op == 'SSENDB' }
    end
    regions
  end

  # ELEMENT_CLASS_SUPPORT: element class of a region's receiver, or nil. SSENDB
  # answers nil: its receiver is self (only admitted when the owner is Array),
  # with no register to scan.
  def region_element_class(insn, irep, idx, dest_reg, ivar_classes, mand, arg_classes, owner_name)
    return nil if insn.op == 'SSENDB'

    proven_element_class(irep, idx, dest_reg, ivar_classes, mand, arg_classes, owner_name)
  end

  # HASH_ELEMENT_SUPPORT: region_element_class for Hash values.
  def region_hash_element_class(insn, irep, idx, dest_reg, ivar_classes, mand, arg_classes, owner_name)
    return nil if insn.op == 'SSENDB'

    proven_hash_element_class(irep, idx, dest_reg, ivar_classes, mand, arg_classes, owner_name)
  end

  # INTERP_UNLOCK / CORE_ARRAY_CHAIN: the chained-receiver rule lives at top
  # level in proven_array_source_scan (ClassLayout.analyze needs it too; one copy
  # of a soundness-critical rule). This wrapper adds the registry and the
  # `-> Array` annotations.
  # ARRAY_RETURN_PROOF: the return fixpoint is passed as the second oracle here
  # but not from ClassLayout.analyze's call (it needs @class_layout, which
  # ClassLayout is still building), so ClassLayout's facts are unaffected.
  def proven_array_source(irep, idx, dest_reg)
    proven_array_source_scan(irep, idx, dest_reg, @registry, ->(n) { annotated_array_return(n) },
                             ->(n) { @array_return_names.include?(n) })
  end

  # GETIDX_STATIC_RECEIVER_SUPPORT: is this GETIDX/GETIDX0/SETIDX receiver
  # provably Array or Hash, using the facts recognize_each_regions trusts
  # (trace_new_target, plus proven_array_source for Arrays; there is no Hash
  # literal scan yet, which only costs proofs)? Also returns an exact custom
  # class with a compiled `[]`/`[]=` so compile_send's guarded TYPED lowering
  # can be reused. Other callers match only Array/Hash.
  # `idx.nil?` bails: the backward scan needs a position.
  # BLOCK_BODY_INDEX_SUPPORT: inlined block bodies pass the real index in
  # block_irep.instructions plus the register shift, and compile_insn maps `reg`
  # back with unshift_proof_reg, so `irep`, `idx` and `reg` share one numbering.
  def static_indexable_class(irep, idx, reg, owner_def)
    return nil unless owner_def && idx

    enter = irep.instructions.find { |i| i.op == 'ENTER' }
    mand = enter ? enter.args.split(':').first.to_i : 0
    arg_classes = @class_annotations[irep.label]&.args
    ivar_classes = @class_layout[owner_def.owner]
    traced = trace_new_target(irep, idx, reg, ivar_classes, mand, arg_classes, owner: owner_def.owner,
                               class_layout: @class_layout, registry: @registry,
                               container_constants: @container_constants,
                               element_annotations: @element_annotations,
                               known_owners: @known_owners, capture_hints: @block_hash_capture_hints)
    traced = resolve_owner_name(traced, { owner: owner_def.owner, known_owners: @known_owners }) if traced
    return traced if %w[Array Hash].include?(traced)
    return traced if traced && %w[[] []=].any? do |name|
      @registry[name]&.any? { |md| md.owner == traced && md.irep }
    end

    proven_array_source(irep, idx, reg) == 'Array' ? 'Array' : nil
  end

  # INDEX_SEND_DEVIRT: when GETIDX's dynamic `[]` fallback receiver has an exact
  # compiled user class, reuse compile_send's guarded TYPED call. Only a TYPED
  # result is accepted: MONO would drop GETIDX's container semantics for
  # unproven receivers.
  def compile_typed_index_send(irep, idx, owner_def, dest_reg, receiver_reg, index_expr, reg_offset, receiver_class,
                               fallback_code)
    return nil unless owner_def && idx && receiver_class
    return nil unless @registry['[]']&.any? { |md| md.owner == receiver_class && md.irep }

    saved_hint = @elem_class_hint
    code = compile_send("R#{dest_reg} :[] n=1", self_implicit: false, irep: irep,
                        idx: reg_offset.zero? ? idx : nil, owner_def: owner_def,
                        call_receiver: "r#{receiver_reg}", call_arguments: [index_expr],
                        trace_idx: idx, trace_reg_offset: reg_offset,
                        trace_receiver_reg: receiver_reg, typed_fallback: fallback_code)
    return code if code.include?('TYPED :[] ->')

    @elem_class_hint = saved_hint
    nil
  end

  def compile_typed_index_write(irep, idx, owner_def, receiver_reg, index_reg, value_reg, reg_offset, receiver_class,
                                fallback_code)
    return nil unless owner_def && idx && receiver_class
    return nil unless @registry['[]=']&.any? { |md| md.owner == receiver_class && md.irep }

    saved_hint = @elem_class_hint
    code = compile_send("R#{receiver_reg} :[]= n=2", self_implicit: false, irep: irep,
                        idx: reg_offset.zero? ? idx : nil, owner_def: owner_def,
                        call_receiver: "r#{receiver_reg}", call_arguments: ["r#{index_reg}", "r#{value_reg}"],
                        trace_idx: idx, trace_reg_offset: reg_offset,
                        trace_receiver_reg: receiver_reg, typed_fallback: fallback_code)
    return code if code.include?('TYPED :[]= ->')

    @elem_class_hint = saved_hint
    nil
  end

  # MAP_BLOCK_SUPPORT: inline map/select/reject/find/filter_map (1-arg blocks),
  # each_with_index (2-arg) and flat_map. Same BLOCK + `SENDB/SSENDB Ra :name
  # n=0` adjacency and Array gate as recognize_each_regions. Only block arities
  # matching the method are admitted (a mismatch would raise when interpreted),
  # so the rest keep `#error`. Per-method semantics are in emit_collect_inline.
  # filter_map is Enumerable#filter_map (mruby-enum-ext/mrblib/enum.rb, a
  # dependency of the build):
  #
  #   def filter_map(&blk)
  #     return to_enum(:filter_map) unless blk
  #     ary = []
  #     self.each do |*x|
  #       x = blk.call(*x)
  #       ary.push x if x
  #     end
  #     ary
  #   end
  #
  # For an Array receiver the block gets one element; the block's RESULT is
  # pushed when truthy. Not redefined anywhere here.
  COLLECT_BLOCK_METHODS = %w[map select reject find each_with_index flat_map filter_map].freeze

  # ACCUM_BLOCK_SUPPORT: inline any?/all?/none?/count (1-arg blocks) and
  # reduce/inject(init) (2-arg blocks, n=1). Semantics (emit_accum_inline):
  #   - any?: false default, first truthy result exits with true;
  #   - all?: true default, first falsy result exits with false;
  #   - none?: true default, first truthy result exits with false;
  #   - count: tally of truthy results;
  #   - reduce/inject(init): init is in R(dest+1) (checked by register), the
  #     accumulator goes through the block's two params.
  # No-init `reduce` (n=0) stays out (empty-array/seeding semantics). Arity
  # mismatches keep `#error`.
  ACCUM_BLOCK_METHODS = %w[any? all? none? count].freeze
  ACCUM_FOLD_METHODS = %w[reduce inject].freeze

  def recognize_accum_regions(irep, owner_name, mand, ivar_classes, arg_classes)
    regions = []
    irep.instructions.each_with_index do |insn, idx|
      next unless %w[SENDB SSENDB].include?(insn.op) && idx.positive?

      dest, name, nstr = insn.args.split(/\s+/, 3)
      meth = name&.sub(/\A:/, '')
      n = nstr.to_s[/n=(\d+)/, 1]&.to_i
      is_pred = n == 0 && ACCUM_BLOCK_METHODS.include?(meth)
      is_fold = n == 1 && ACCUM_FOLD_METHODS.include?(meth)
      next unless is_pred || is_fold

      block_insn = irep.instructions[idx - 1]
      next unless block_insn && block_insn.op == 'BLOCK'

      dest_reg = dest[/^R(\d+)/, 1]
      block_reg = block_insn.args[/^R(\d+)/, 1]
      if is_fold
        # `reduce(init)`: dest, init, block, so BLOCK is at dest+2 (`BLOCK R4` +
        # `SENDB R2 :reduce n=1`).
        next unless dest_reg && block_reg && block_reg == (dest_reg.to_i + 2).to_s
      else
        next unless dest_reg && block_reg && block_reg == (dest_reg.to_i + 1).to_s
      end

      block_irep_idx = block_insn.args[/I\[(\d+)\]/, 1]
      next unless block_irep_idx

      block_label = irep.reps[block_irep_idx.to_i]
      block_irep = block_label && @ireps[block_label]
      want_arity = is_fold ? 2 : 1
      next unless block_irep && mandatory_arity(block_irep) == want_arity && pure_mandatory_arity?(block_irep)

      if insn.op == 'SSENDB'
        next unless owner_name == 'Array'
      else
        # CHAINED_ACCESSOR_SUPPORT: passing @class_layout/@registry can only turn nil
        # into 'Array'.
        traced = trace_new_target(irep, idx, dest_reg, ivar_classes, mand, arg_classes, owner: owner_name,
                                   class_layout: @class_layout, registry: @registry,
                                   container_constants: @container_constants)
        traced = proven_array_source(irep, idx, dest_reg) if traced != 'Array'
        next unless traced == 'Array'
      end

      regions << { block_addr: block_insn.addr, sendb_addr: insn.addr, dest_reg: dest_reg, block_irep: block_irep,
                   method_name: meth, init_reg: is_fold ? (dest_reg.to_i + 1).to_s : nil,
                   ssendb: insn.op == 'SSENDB',
                   elem_class: region_element_class(insn, irep, idx, dest_reg, ivar_classes, mand, arg_classes,
                                                   owner_name) }
    end
    regions
  end

  def recognize_collect_regions(irep, owner_name, mand, ivar_classes, arg_classes)
    regions = []
    irep.instructions.each_with_index do |insn, idx|
      next unless %w[SENDB SSENDB].include?(insn.op) && idx.positive?

      dest, name, nstr = insn.args.split(/\s+/, 3)
      meth = name&.sub(/\A:/, '')
      next unless nstr == 'n=0' && COLLECT_BLOCK_METHODS.include?(meth)

      block_insn = irep.instructions[idx - 1]
      next unless block_insn && block_insn.op == 'BLOCK'

      dest_reg = dest[/^R(\d+)/, 1]
      block_reg = block_insn.args[/^R(\d+)/, 1]
      next unless dest_reg && block_reg && block_reg == (dest_reg.to_i + 1).to_s

      block_irep_idx = block_insn.args[/I\[(\d+)\]/, 1]
      next unless block_irep_idx

      block_label = irep.reps[block_irep_idx.to_i]
      block_irep = block_label && @ireps[block_label]
      want_arity = meth == 'each_with_index' ? 2 : 1
      next unless block_irep && mandatory_arity(block_irep) == want_arity && pure_mandatory_arity?(block_irep)

      if insn.op == 'SSENDB'
        next unless owner_name == 'Array'
      else
        # CHAINED_ACCESSOR_SUPPORT: passing @class_layout/@registry can only turn nil
        # into 'Array'.
        traced = trace_new_target(irep, idx, dest_reg, ivar_classes, mand, arg_classes, owner: owner_name,
                                   class_layout: @class_layout, registry: @registry,
                                   container_constants: @container_constants)
        traced = proven_array_source(irep, idx, dest_reg) if traced != 'Array'
        next unless traced == 'Array'
      end

      regions << { block_addr: block_insn.addr, sendb_addr: insn.addr, dest_reg: dest_reg, block_irep: block_irep,
                   method_name: meth, ssendb: insn.op == 'SSENDB',
                   elem_class: region_element_class(insn, irep, idx, dest_reg, ivar_classes, mand, arg_classes,
                                                   owner_name) }
    end
    regions
  end

  # EACH_BLOCK_SUPPORT: `ary.reject(&:dead?)` and friends: `LOADSYM R(a+1) :sym`
  # then `SENDB`/`SSENDB Ra :name n=0`, no BLOCK. OP_SENDB turns regs[bidx] into
  # a symbol proc (ensure_block), so there is nothing to inline or capture; each
  # element gets one call (emit_sym_inline). Same Array gate as
  # recognize_each_regions.
  SYM_BLOCK_METHODS = %w[each map select reject find any? all? none? count].freeze

  def recognize_sym_regions(irep, owner_name, mand, ivar_classes, arg_classes)
    regions = []
    irep.instructions.each_with_index do |insn, idx|
      next unless %w[SENDB SSENDB].include?(insn.op) && idx.positive?

      dest, name, nstr = insn.args.split(/\s+/, 3)
      next unless nstr == 'n=0' && SYM_BLOCK_METHODS.include?(name&.sub(/\A:/, ''))

      loadsym_insn = irep.instructions[idx - 1]
      next unless loadsym_insn && loadsym_insn.op == 'LOADSYM'
      # No BLOCK check needed: OP_SENDB takes its block from regs[bidx] (dest+1 for
      # n=0), which the LOADSYM just wrote (register match below).
      # A keyword call also LOADSYMs its key symbols into later registers, but it is
      # always SEND/SSEND, never SENDB/SSENDB, so it cannot form a region here.

      dest_reg = dest[/^R(\d+)/, 1]
      sym_reg = loadsym_insn.args[/^R(\d+)/, 1]
      next unless dest_reg && sym_reg && sym_reg == (dest_reg.to_i + 1).to_s

      sym_name = loadsym_insn.args[/:(\S+)/, 1]&.sub(/\A:/, '')
      next unless sym_name && !sym_name.empty?

      if insn.op == 'SSENDB'
        next unless owner_name == 'Array'
      else
        # CHAINED_ACCESSOR_SUPPORT: passing @class_layout/@registry can only turn nil
        # into 'Array'.
        traced = trace_new_target(irep, idx, dest_reg, ivar_classes, mand, arg_classes, owner: owner_name,
                                   class_layout: @class_layout, registry: @registry,
                                   container_constants: @container_constants)
        traced = proven_array_source(irep, idx, dest_reg) if traced != 'Array'
        next unless traced == 'Array'
      end

      regions << { sym_addr: loadsym_insn.addr, sendb_addr: insn.addr, dest_reg: dest_reg,
                   method_name: name.sub(/\A:/, ''), sym_name: sym_name, ssendb: insn.op == 'SSENDB' }
    end
    regions
  end

  # INTERP_UNLOCK: inline `r.each { |id| ... }` for a receiver tracing to Range
  # (a RANGE_INC/RANGE_EXC literal or `range(cmd)` below). Same adjacency and
  # 1-arg gate as recognize_each_regions; zero-arg blocks are also admitted
  # because Range#each yields the same counter to either form. No SSENDB: no
  # game class is a Range.
  def recognize_range_each_regions(irep, owner_name, mand, ivar_classes, arg_classes)
    regions = []
    irep.instructions.each_with_index do |insn, idx|
      next unless insn.op == 'SENDB' && idx.positive?

      dest, name, nstr = insn.args.split(/\s+/, 3)
      next unless name == ':each' && nstr == 'n=0'

      block_insn = irep.instructions[idx - 1]
      next unless block_insn && block_insn.op == 'BLOCK'

      dest_reg = dest[/^R(\d+)/, 1]
      block_reg = block_insn.args[/^R(\d+)/, 1]
      next unless dest_reg && block_reg && block_reg == (dest_reg.to_i + 1).to_s

      block_irep_idx = block_insn.args[/I\[(\d+)\]/, 1]
      next unless block_irep_idx

      block_label = irep.reps[block_irep_idx.to_i]
      block_irep = block_label && @ireps[block_label]
      next unless block_irep && [0, 1].include?(mandatory_arity(block_irep)) && pure_mandatory_arity?(block_irep)

      traced = trace_new_target(irep, idx, dest_reg, ivar_classes, mand, arg_classes, owner: owner_name,
                                 container_constants: @container_constants)
      traced = range_return_call(irep, idx, dest_reg) if traced != 'Range'
      next unless traced == 'Range'

      regions << { block_addr: block_insn.addr, sendb_addr: insn.addr, dest_reg: dest_reg, block_irep: block_irep }
    end
    regions
  end

  # INTERP_UNLOCK: Game::Interpreter#range returns a Range on every path (`a..b`
  # or `1..0`). A single exact Owner#name allowlist (SUPER_TARGETS style), so a
  # `range` method elsewhere never matches and a non-Range change to #range
  # must update this.
  RANGE_RETURN_METHODS = Set['Game::Interpreter#range'].freeze

  def range_return_call(irep, idx, dest_reg)
    (idx - 1).downto(0) do |i|
      pin = irep.instructions[i]
      next unless pin
      next unless pin.args[/^R(\d+)/, 1] == dest_reg
      # Only a `range` call made FROM a Game::Interpreter method counts (checked via
      # the irep's MethodDef owner), not just the name.
      next unless %w[SEND SSEND SEND0 SSEND0].include?(pin.op)

      called = pin.args[/:([\w+\-*\/<>=!?\[\]&|^~%@]+)/, 1]
      return nil unless called == 'range'

      return 'Range' if RANGE_RETURN_METHODS.include?("#{@owner_of.fetch(irep.label).owner}#range")

      return nil
    end
    nil
  end

  # PROFILER_SECTION_SUPPORT: inline `RGSS::Profiler.section("name") { ... }`
  # and `RGSS::Profiler.frame { ... }` as the same shape every other inline pass
  # uses -- one BLOCK instruction immediately before a block-carrying send --
  # but with NO receiver gate. Both names are the native profiling primitives in
  # mruby-rgss/src/profiler.cxx (prof_section/prof_frame): they take a block,
  # time it, and return the block's value, with an explicit `!g_enabled` fast
  # path that is a bare yield.
  #
  # What the emitter actually does with them is NOT "time the body by hand":
  # profiler_section_begin/profiler_section_end/profiler_frame_begin/
  # profiler_frame_end (include/profiler.hxx) are public primitives that already
  # encapsulate the enabled test, the clock read, the aggregation and the
  # Chrome-trace write, and are documented no-ops when profiling is disabled
  # (section_end returns immediately on a zero start stamp). So the emitted code
  # calls the two primitives around the inlined body and the native
  # `if (!g_enabled) return mrb_yield_argv(...)` branch collapses into them --
  # which is the same trade the shipping code already makes in
  # mruby-rgss/src/lib.cxx, where ProfilerScope times gfx.zorder/gfx.lvgl/
  # gfx.invalidate in the same per-frame hot path.
  #
  # The receiver is matched structurally instead of through trace_new_target: a
  # GETCONST/GETMCNST pair naming RGSS::Profiler, which is exactly what the real
  # call sites compile to (`GETCONST R2 RGSS` + `GETMCNST R2 (R2)::Profiler`).
  # A receiver that reaches these names by any other route -- a constant
  # rebound to something else, a local alias, a subclass -- is simply not
  # matched and keeps today's BLOCK_FALLBACK.
  #
  # The section NAME must be a String pool literal, because the C primitive
  # takes `const char*` and only promises to copy it during the call
  # (profiler_section_end stores it into a std::string map key immediately).
  # Every real call site passes a literal ("map.render", "scene.update", ...),
  # so a computed name is declined rather than approximated: materializing an
  # arbitrary mrb_value name per call would add an allocation per frame for no
  # benefit. `frame` takes no name, so it is admitted unconditionally.
  #
  # No BREAK: `break` out of an inlined region has no meaning here (the native
  # path mrb_yield_argv's the block, so a `break` in it is already a LOCAL jump
  # mruby's VM resolves against the sending frame's tag -- an enclosing loop of
  # the Ruby method, not the section), and refusing it is what the other
  # inlined-loop passes do too. `next` (a block return) and a method `return`
  # (RETURN_BLK, already a plain C++ return in every inline body) are fine.
  PROFILER_SECTION_NAMES = { 'section' => 1, 'frame' => 0 }.freeze

  def recognize_profiler_section_regions(irep)
    regions = []
    irep.instructions.each_with_index do |insn, idx|
      next unless insn.op == 'SENDB' && idx.positive?

      dest, name, nstr = insn.args.split(/\s+/, 3)
      meth = name&.sub(/\A:/, '')
      want_argc = PROFILER_SECTION_NAMES[meth]
      next unless want_argc && nstr == "n=#{want_argc}"

      dest_reg = dest[/^R(\d+)/, 1]
      next unless dest_reg

      block_insn = irep.instructions[idx - 1]
      next unless block_insn && block_insn.op == 'BLOCK'

      # The block proc register is the one AFTER the arguments (vm.c OP_SENDB):
      # dest+1 for :frame (no arguments at all), dest+2 for :section, whose name
      # is argument 0 and is written into dest+1 first. Getting this wrong is
      # what a plain "dest+1" check from the collection passes assumes.
      block_reg = block_insn.args[/^R(\d+)/, 1]
      next unless block_reg == (dest_reg.to_i + 1 + want_argc).to_s

      block_irep_idx = block_insn.args[/I\[(\d+)\]/, 1]
      next unless block_irep_idx

      block_label = irep.reps[block_irep_idx.to_i]
      block_irep = block_label && @ireps[block_label]
      next unless block_irep && mandatory_arity(block_irep).zero? && pure_mandatory_arity?(block_irep)

      # The receiver must be the literal constant path RGSS::Profiler (see
      # profiler_section_receiver?), and a :section's name must be a String pool
      # literal (see profiler_section_literal?). Everything else keeps today's
      # BLOCK_FALLBACK.
      next unless profiler_section_receiver?(irep, idx, dest_reg, meth)

      section_name = meth == 'section' ? profiler_section_literal(irep, idx, (dest_reg.to_i + 1).to_s) : nil
      next if meth == 'section' && section_name.nil?

      upvars = block_upvar_needs(block_irep)
      # A block whose captures cannot be modelled, or which breaks out, stays on
      # the fallback: `break` here has no inlined target, and the nested break
      # scan needs the same available_upvars the emitter would supply.
      next if upvars.nil?
      nbrk = inline_nested_region_has_break?({ block_irep: block_irep, upvars: upvars }, upvars)
      next if nbrk

      regions << { block_addr: block_insn.addr, sendb_addr: insn.addr, dest_reg: dest_reg,
                   block_irep: block_irep, method_name: meth, section_name: section_name }
    end
    regions
  end

  # Is `reg` the literal constant path RGSS::Profiler at this call? `idx` is the
  # SENDB's index, so the BLOCK is at idx-1. The pair
  # `GETCONST R<r> RGSS` + `GETMCNST R<r> (R<r>)::Profiler` ends immediately
  # before the BLOCK for :frame, and one STRING earlier for :section (whose
  # name argument is written in between), so both positions are tried.
  # Anything else -- a local alias, a rebased constant, a different receiver
  # answering `section` -- is not matched and keeps today's BLOCK_FALLBACK.
  def profiler_section_receiver?(irep, idx, reg, meth)
    receiver_pair_before?(irep, idx - 1, reg) || (meth == 'section' && receiver_pair_before?(irep, idx - 2, reg))
  end

  # The two-instruction `GETCONST R<r> RGSS` / `GETMCNST R<r> (R<r>)::Profiler`
  # occupying the two slots immediately before index `block_idx` (the BLOCK).
  def receiver_pair_before?(irep, block_idx, reg)
    mcnst = irep.instructions[block_idx - 1]
    return false unless mcnst && mcnst.op == 'GETMCNST'
    return false unless mcnst.args =~ /\AR#{reg}\s+\(R#{reg}\)::Profiler\z/

    const = irep.instructions[block_idx - 2]
    const && const.op == 'GETCONST' && const.args == "R#{reg}\tRGSS"
  end

  # The String pool literal for :section's name argument, or nil. The VM wrote
  # that argument (register dest+1) with a `STRING R<n> L[k]` pool load placed
  # between the receiver pair and the BLOCK. The search is bounded to exactly
  # those two instructions, so a STRING left over from an earlier statement in
  # the method can never be mistaken for this call's name.
  def profiler_section_literal(irep, idx, reg)
    insn = irep.instructions[idx - 2]
    return nil unless insn && insn.op == 'STRING' && insn.args[/^R(\d+)/, 1] == reg

    pool_idx = insn.args[/L\[(\d+)\]/, 1]
    return nil unless pool_idx

    entry = irep.pool.fetch(pool_idx.to_i)
    entry if entry.is_a?(String)
  end

  # SORT_BLOCK_SUPPORT: inline sort_by (1-arg key), sort (2-arg comparator) and
  # uniq (1-arg key), with the proven_array_source gate. Semantics in
  # emit_sort_inline.
  # Not supported, with no block-form call sites in the closed world:
  #   - sort_by!/uniq!: could replace the receiver via mrb_ary_replace after the
  #     existing passes (as mruby's own sort_by!/uniq! do);
  #   - max/min (2-arg comparator: a single fold, block not called for the first
  #     element) and max_by/min_by (1-arg key, called for every element); ties
  #     keep the first element, empty is nil.
  # Arity mismatches keep `#error`.
  SORT_BLOCK_METHODS = %w[sort sort_by uniq].freeze

  def recognize_sort_regions(irep, owner_name, mand, ivar_classes, arg_classes)
    regions = []
    irep.instructions.each_with_index do |insn, idx|
      next unless %w[SENDB SSENDB].include?(insn.op) && idx.positive?

      dest, name, nstr = insn.args.split(/\s+/, 3)
      meth = name&.sub(/\A:/, '')
      next unless nstr == 'n=0' && SORT_BLOCK_METHODS.include?(meth)

      block_insn = irep.instructions[idx - 1]
      next unless block_insn && block_insn.op == 'BLOCK'

      dest_reg = dest[/^R(\d+)/, 1]
      block_reg = block_insn.args[/^R(\d+)/, 1]
      next unless dest_reg && block_reg && block_reg == (dest_reg.to_i + 1).to_s

      block_irep_idx = block_insn.args[/I\[(\d+)\]/, 1]
      next unless block_irep_idx

      block_label = irep.reps[block_irep_idx.to_i]
      block_irep = block_label && @ireps[block_label]
      want_arity = meth == 'sort' ? 2 : 1
      next unless block_irep && mandatory_arity(block_irep) == want_arity && pure_mandatory_arity?(block_irep)

      if insn.op == 'SSENDB'
        next unless owner_name == 'Array'
      else
        # CHAINED_ACCESSOR_SUPPORT: passing @class_layout/@registry can only turn nil
        # into 'Array'.
        traced = trace_new_target(irep, idx, dest_reg, ivar_classes, mand, arg_classes, owner: owner_name,
                                   class_layout: @class_layout, registry: @registry,
                                   container_constants: @container_constants)
        traced = proven_array_source(irep, idx, dest_reg) if traced != 'Array'
        next unless traced == 'Array'
      end

      regions << { block_addr: block_insn.addr, sendb_addr: insn.addr, dest_reg: dest_reg, block_irep: block_irep,
                   method_name: meth, ssendb: insn.op == 'SSENDB',
                   elem_class: region_element_class(insn, irep, idx, dest_reg, ivar_classes, mand, arg_classes,
                                                   owner_name) }
    end
    regions
  end
  # compile_block_body_insn (below): translate one instruction of an INLINED
  # block body. `offset` is added to every `R<N>` before delegating to
  # compile_insn, keeping the block's registers apart from the method's.
  # BLOCK_BODY_INDEX_SUPPORT: the delegation passes the instruction's real index
  # in block_irep and the shift; unshift_proof_reg undoes the shift wherever a
  # register reaches a proof. Addresses are unchanged. `owner_def` stays the
  # enclosing method's (the block shares its self), and
  # fixnum_proof_entry_arg?'s `owner_def.irep == irep.label` guard keeps the
  # method's NATIVE_ARG_TARGETS types off the block's parameters.
  # Block-specific opcodes:
  #   - RETURN/RETNIL/RETFALSE/RETTRUE: the block's yielded value (`next` is
  #     RETNIL); for #times, a goto to this iteration's end label.
  #   - RETURN_BLK: a real `return`; the block's frame is inlined into the
  #     method's function, so it is a plain C++ return.
  #   - GETUPVAR/SETUPVAR at level 0: the outer scope is this same function, so
  #     `b` names `r<b>` directly, without the offset.
  # INLINE_BLOCK_CAPTURE_HINTS: a block GETUPVAR keeps a Hash<Klass> hint only
  # when the exact SENDB site captures an untouched mandatory Hash<Klass>
  # argument; the generated index and typed call keep their runtime guards and
  # fallbacks.
  def inline_hash_capture_hints(host_irep, region)
    block_irep = region[:block_irep]
    return {} if block_irep.instructions.any? { |insn| %w[SETUPVAR BLOCK SENDB SSENDB].include?(insn.op) }

    call_idx = host_irep.instructions.index { |insn| insn.addr == region[:sendb_addr] }
    return {} unless call_idx

    enter = host_irep.instructions.find { |insn| insn.op == 'ENTER' }
    mandatory = enter ? enter.args.split(':').first.to_i : 0
    elements = @element_annotations[host_irep.label]
    return {} unless elements

    captures = {}
    block_irep.instructions.each do |insn|
      next unless insn.op == 'GETUPVAR'

      dst, upvar, level = insn.args.split(/\s+/)
      next unless level == '0'

      reg = upvar
      (call_idx - 1).downto(0) do |i|
        prior = host_irep.instructions[i]
        next unless prior.args[/^R(\d+)/, 1] == reg

        if prior.op == 'MOVE'
          reg = prior.args.scan(/R(\d+)/).flatten[1]
          break unless reg
        else
          reg = nil
          break
        end
      end
      arg_pos = reg&.to_i
      next unless arg_pos && arg_pos.between?(1, mandatory)
      next unless elements.arg_containers&.[](arg_pos - 1) == 'Hash'

      element_class = elements.arg_elements&.[](arg_pos - 1)
      next unless element_class

      captures[dst[/\d+/].to_i] = { container_class: 'Hash', element_class: element_class }
    end
    captures.empty? ? {} : { block_irep.label => captures }
  end

  def with_block_hash_capture_hints(hints)
    previous = @block_hash_capture_hints
    @block_hash_capture_hints = hints
    yield
  ensure
    @block_hash_capture_hints = previous
  end

  # ELEMENT_CLASS_SUPPORT: publish "this instruction's receiver is the loop
  # element, of class `elem_class`" for exactly one instruction. compile_send
  # consumes the hint on read, so a nested compile (compiles_clean? on another
  # body) never sees it, and the `ensure` clears it regardless. Only
  # explicit-receiver sends qualify (SSEND receivers are self).
  def with_element_hint(block_irep, insn, i, elem_reg, elem_class)
    hint = nil
    if elem_class && elem_reg && %w[SEND SEND0].include?(insn.op) &&
       element_receiver?(block_irep, i, insn.args[/^R(\d+)/, 1], elem_reg)
      hint = elem_class
    end
    prev = @elem_class_hint
    @elem_class_hint = hint
    yield
  ensure
    @elem_class_hint = prev
  end

  # ELEMENT_CLASS_SUPPORT: does `reg` still hold the loop element at `idx`? mrbc
  # MOVEs a parameter into a scratch register before sending (`MOVE R10 R8`,
  # `SEND R10 :dead?`), so follow MOVEs back to the element register with no
  # other write in between; reassigning the parameter stops the scan.
  # Straight-line and control-flow-insensitive, which is only a precision
  # limit: the emitted code checks mrb_obj_class before the direct call.
  def element_receiver?(block_irep, idx, reg, elem_reg)
    return false unless reg

    (idx - 1).downto(0) do |i|
      insn = block_irep.instructions[i]
      next unless insn
      next unless insn.args[/^R(\d+)/, 1] == reg
      return false unless insn.op == 'MOVE'

      src = insn.args.scan(/R(\d+)/).flatten[1]
      return false unless src

      reg = src
    end
    reg == elem_reg
  end

  # INLINE_NESTED_BLOCK_SUPPORT: the shift-then-compile_insn step of
  # compile_block_body_insn's `else` arm, named so the BLOCK/SENDB/SSENDB case
  # can reuse it for an unclaimed nested region (one copy, no drift).
  def compile_shifted_body_insn(insn, block_irep, owner_def, offset, idx)
    shifted_args = insn.args.gsub(/R(\d+)/) { "R#{Regexp.last_match(1).to_i + offset}" }
    shifted = Insn.new(lineno: insn.lineno, addr: insn.addr, op: insn.op, args: shifted_args, raw: insn.raw)
    compile_insn(shifted, block_irep, owner_def, idx, offset)
  end

  def compile_block_body_insn(insn, block_irep, owner_def, offset, iter_end_label, label_prefix,
                                break_dest: nil, break_label: nil, idx: nil)
    case insn.op
    # INLINE_NESTED_BLOCK_SUPPORT: a nested block-carrying call in this inlined
    # body. `@inline_nested` holds the regions inline_nested_block_pass claimed
    # for the body loop running now. A claimed region's BLOCK address carries the
    # whole replacement (RProc construction and dispatch) and its SENDB address
    # nothing, as in compile_method's and emit_proc_fallback_fn's passes.
    # An unclaimed one falls through to compile_insn, which emits `#error`, so the
    # driving emitter gives up and the loop falls back to BLOCK_FALLBACK as
    # before.
    when 'BLOCK', 'SENDB', 'SSENDB'
      glue = @inline_nested&.glue&.[](insn.addr)
      if glue
        glue
      elsif @inline_nested&.skip?(insn.addr)
        # A claimed region's SENDB/SSENDB: already emitted at its BLOCK address.
        ''
      else
        # Unclaimed: the plain shift-then-compile_insn, i.e. `#error`, which makes
        # the driving emitter abandon the region.
        compile_shifted_body_insn(insn, block_irep, owner_def, offset, idx)
      end
    when 'RETURN', 'RETNIL', 'RETFALSE', 'RETTRUE'
      "  goto #{iter_end_label};\n"
    when 'RETURN_BLK'
      r = insn.args.strip.empty? ? '0' : insn.args[/^R(\d+)/, 1]
      "  return r#{r.to_i + offset};\n"
    when 'BREAK'
      # EACH_BLOCK_SUPPORT: `break` (bare breaks carry a LOADNIL'd register) makes
      # the value the whole SEND's result (vm.c OP_BREAK L_UNWINDING). Inlined:
      # assign the SENDB destination and jump past the loop. Only the each/sym
      # emitters pass break_dest/break_label; in #times a break keeps its `#error`.
      if break_dest && break_label
        r = insn.args.strip.empty? ? '0' : insn.args[/^R(\d+)/, 1]
        "  r#{break_dest} = r#{r.to_i + offset};\n  goto #{break_label};\n"
      else
        "  #error unhandled opcode BREAK -- not in this prototype's supported subset\n"
      end
    when 'GETUPVAR'
      dst, upvar_idx, level = insn.args.split(/\s+/)
      if level == '0'
        "  r#{dst[/\d+/].to_i + offset} = r#{upvar_idx};\n"
      else
        "  #error unhandled opcode GETUPVAR -- not in this prototype's supported subset\n"
      end
    when 'SETUPVAR'
      src, upvar_idx, level = insn.args.split(/\s+/)
      if level == '0'
        "  r#{upvar_idx} = r#{src[/\d+/].to_i + offset};\n"
      else
        "  #error unhandled opcode SETUPVAR -- not in this prototype's supported subset\n"
      end
    # JMP/JMPNOT/JMPIF/JMPNIL are handled here, not by compile_insn, whose bare
    # `goto L<target>;` would miss this body's `label_prefix`-qualified labels or
    # collide with a same-numbered label of the enclosing method (goto labels have
    # function scope). `.to_i`: disassembly zero-pads addresses ("016") but labels
    # use the integer value.
    when 'JMP'
      "  goto #{label_prefix}#{insn.args.strip[/\d+/].to_i};\n"
    when 'JMPUW'
      # JMPUW_SUPPORT: as compile_insn's JMPUW case, but against `block_irep`'s own
      # catch handlers and jump targets, and with prefixed labels (see JMP above).
      if jmpuw_is_plain_jump?(block_irep)
        "  goto #{label_prefix}#{insn.args.strip[/\d+/].to_i};\n"
      else
        "  #error unhandled opcode JMPUW -- not in this prototype's supported subset\n"
      end
    when 'JMPNOT'
      reg = insn.args[/^R(\d+)/, 1]
      "  if (!mrb_test(r#{reg.to_i + offset})) goto #{label_prefix}#{jmp_target_after_reg(insn.args)};\n"
    when 'JMPIF'
      reg = insn.args[/^R(\d+)/, 1]
      "  if (mrb_test(r#{reg.to_i + offset})) goto #{label_prefix}#{jmp_target_after_reg(insn.args)};\n"
    when 'JMPNIL'
      reg = insn.args[/^R(\d+)/, 1]
      "  if (mrb_nil_p(r#{reg.to_i + offset})) goto #{label_prefix}#{jmp_target_after_reg(insn.args)};\n"
    else
      # BLOCK_BODY_INDEX_SUPPORT: `idx` is the instruction's real position in
      # block_irep.instructions (the emitters walk it in order, skipping only
      # ENTER), and `offset` the register shift; with both, FIXNUM_OPERAND_PROOF and
      # GETIDX_STATIC_RECEIVER_SUPPORT run against block_irep's own facts, via
      # unshift_proof_reg.
      compile_shifted_body_insn(insn, block_irep, owner_def, offset, idx)
    end
  end
end
