# frozen_string_literal: true

# CodeGen: construction, embedding and the monomorphic-target queries.

# ---------------------------------------------------------------------------
# Step 7: codegen -- one C++ function pair per leaf method-body irep.
#
# Each compiled method gets two C++ functions:
#   - `<Owner>_<name>_impl(mrb_state*, mrb_value self[, mrb_value arg1, ...])`
#     the real translated body, taking every argument as a plain typed C++
#     parameter -- no marshalling. This is what a monomorphic call site
#     compiles to a direct call to.
#   - `<Owner>_<name>(mrb_state*, mrb_value self)` the normal mrb_func_t
#     shape, which fetches its args the ordinary way (mrb_get_args) and
#     forwards to _impl. This is what gets registered with
#     mrb_define_method, so the method is still reachable the normal way --
#     from interpreted code, via #send, or from a call site this analysis
#     could not prove monomorphic.
# ---------------------------------------------------------------------------
class CodeGen
  # EMBED_WIRED (compiled_gems.rb BC2CPP_WIRED_EMBEDDINGS): nil leaves embedding
  # unrestricted (unit checks); the driver sets it for a real gem build.
  # struct_members: STRUCT_MEMBERS_ANALYSIS result (Struct owner -> members in
  # storage order); nil proves nothing.
  # embed_ivar_limits: owner -> the only ivars it may embed
  # (BC2CPP_EMBED_IVAR_LIMITS); nil or an absent owner means no cap.
  # hot_only_excluded: irep labels BC2CPP_HOT_METHODS leaves out (ADR 0214); nil
  # or empty excludes nothing. Class-level so every probing CodeGen sees it.
  class << self
    attr_accessor :wired_embeddings, :embed_ivar_limits, :stable_class_constants, :struct_members,
                  :integer_constant_values, :hot_only_excluded
  end

  C_TYPE = { fixnum: 'mrb_int', symbol: 'mrb_sym', bool: 'mrb_bool',
             fixnum_nil: 'Bc2cppFixnumOrNil' }.freeze

  # box/check/unbox/err per embeddable type for GETIV/SETIV codegen. An mrb_sym
  # field needs no GC keep-alive (see IvarLayout.trace_type's LOADSYM arm).
  # `:bool` has no single check macro (MRB_TT_TRUE/MRB_TT_FALSE are separate
  # tags), so bc2cpp_bool_p (emit_bool_check_helper) ORs mrb_true_p/mrb_false_p;
  # emitted only when an embedded :bool needs it.
  #
  # NILABLE_EMBED_SUPPORT: a tagged pair still fills `box`/`check`/`err` -- the
  # three every consumer uses -- but has no `unbox`: storing one is
  # `bc2cpp_fixnum_or_nil_set`, not an assignment, so the two write sites check
  # `unbox` and route to the setter instead (ivar_set_code,
  # emit_ivar_accessor_pair). `check` uses mrb_fixnum_p, so a heap Bignum can
  # never be truncated into the field's mrb_int.
  TYPE_OPS = {
    fixnum: { box: 'mrb_fixnum_value', check: 'mrb_integer_p', unbox: 'mrb_integer', err: 'Integer' },
    symbol: { box: 'mrb_symbol_value', check: 'mrb_symbol_p', unbox: 'mrb_symbol', err: 'Symbol' },
    bool: { box: 'mrb_bool_value', check: 'bc2cpp_bool_p', unbox: 'mrb_true_p', err: 'boolean' },
    fixnum_nil: { box: 'bc2cpp_fixnum_or_nil_box', check: 'bc2cpp_fixnum_or_nil_p',
                  err: 'Integer or nil' }
  }.freeze

  # The types whose storage is a generated struct rather than a scalar, so
  # `emit_structs` must emit that struct first and `emit_nullable_helpers` its
  # box/check/unbox. Kept beside TYPE_OPS so the two cannot drift.
  NULLABLE_TYPES = %i[fixnum_nil].freeze

  def initialize(ireps, registry, ivar_layout, class_layout = {}, class_annotations = {}, annotations = {},
                 superclass_of = {}, element_layout = {}, element_annotations = {}, container_constants = {},
                 hash_element_layout = {}, integer_constants = Set.new,
                 foreign_method_names = nil, outside_tokens = nil,
                  native_name_sources = nil, included_modules = {}, prepended_modules = {},
                  unknown_mixins = Set.new, analysis_only: false, native_expression_devirt: {},
                  native_registered_expressions: {}, closed_world: nil)
    @ireps = ireps
    # CLOSED_WORLD: a ClosedWorld (closed_world.rb) when BC2CPP_CLOSED_WORLD=1.
    @closed_world = closed_world
    # ENTRY_ARG_CALLSITE_PROOF: identifier tokens from NATIVE_SRCS and
    # FOREIGN_RUBY_SRCS (outside_world_tokens). nil means the scan did not run;
    # compute_entry_arg_fixnum then proves nothing.
    @outside_tokens = outside_tokens
    # FIXNUM_RETURN_PROOF: method names defined in foreign Ruby sources
    # (foreign_method_names). nil: compute_fixnum_return_names proves nothing
    # rather than use an incomplete poison set.
    @foreign_method_names = foreign_method_names
    # ZSUPER_NATIVE_SUPPORT: name -> NATIVE_SRCS files registering it
    # (extract_native_method_sources). nil: zsuper_native_kind declines every
    # site.
    @native_name_sources = native_name_sources
    # NATIVE_EXPRESSION_DEVIRT: single-expression implementations of zero-argument
    # C methods; only the allowlisted subset in native_expression_devirt.rb.
    @native_expression_devirt = native_expression_devirt
    # NATIVE_CONTAINER_DEVIRT: class-specific expressions from mruby's ROM
    # registration owner, instance tag and C body, including direct calls to
    # public C methods whose source reads no VM frame.
    @native_registered_expressions = native_registered_expressions
    # INTEGER_CONSTANT_PROOF: IntegerConstants.analyze's admitted names; read by
    # fixnum_proof_source?'s GETCONST/GETMCNST arms. Empty proves nothing.
    @integer_constants = integer_constants
    # CONST_CONTAINER_SUPPORT: qualified constant -> 'Array'/'Hash'/'Range'
    # (build_registry). Read by the block recognizers' receiver-class gate.
    @container_constants = container_constants
    # ELEMENT_CLASS_SUPPORT: ArrayElementLayout's filtered table and
    # ElementAnnotations. Read only by the block emitters, which guard every use
    # with mrb_obj_class.
    @element_layout = element_layout
    @element_annotations = element_annotations
    # HASH_ELEMENT_SUPPORT: HashElementLayout's filtered table; read only by
    # recognize_hash_each_regions/emit_hash_each_inline, guarded the same way.
    @hash_element_layout = hash_element_layout
    # Element class in scope, set by block emitters around one inlined body; nil
    # elsewhere.
    @elem_class_hint = nil
    # INLINE_BLOCK_CAPTURE_HINTS: captured Hash<Klass> arguments proven at the
    # enclosing block call site, keyed by block irep and GETUPVAR destination.
    # Scoped by emit_each_inline; nil elsewhere.
    @block_hash_capture_hints = nil
    # UPVAR_CAPTURE_SUPPORT: registers capturable by pointer, set by
    # emit_proc_fallback_fn around one BLOCK_FALLBACK body; read by compile_insn's
    # GETUPVAR/SETUPVAR. nil elsewhere.
    @block_fallback_upvars = nil
    # EXCEPTION_BREAK_SUPPORT: true only while compiling a BLOCK_FALLBACK body;
    # BREAK then throws bc2cpp_block_break instead of returning.
    @block_fallback_active = false
    # BLKPUSH_YIELD_SUPPORT: the method's block parameter name ('bc2cpp_blk'), set
    # by compile_method around its body; read by BLKPUSH. nil elsewhere.
    # BLOCK_FALLBACK_YIELD_SUPPORT: also set by emit_proc_fallback_fn for a body
    # that forwards the method's block (`region[:needs_blk]`). Saved and restored
    # (not cleared) because that function recurses and compile_method sets it too.
    @blk_param_name = nil
    # BLOCK_FALLBACK_YIELD_SUPPORT: the BLKPUSH `lv` that `@blk_param_name`
    # answers: 0 in a method body (vm.c `if (lv == 0) stack = regs + 1`), else the
    # body's nesting depth below its method (codegen.c counts scopes up to the
    # method scope, so a direct child block has lv == 1). Other lv keep `#error`.
    @blk_param_level = 0
    @registry = registry
    @known_owners = Set.new(registry.values.flatten.map(&:owner))
    # FIBER_REACHABILITY_UNSAFE_SUPPORT: must exist before drop_unsafe_embeddings,
    # which reaches compile_method through compiles_clean?. See
    # compute_fiber_unsafe_methods.
    compute_fiber_unsafe_methods
    # SUPER_SUPPORT: resolve_superclass_ref's table (name, :none, or absent); read
    # by compile_insn's SUPER case.
    @superclass_of = superclass_of
    # ANCESTOR_MIXINS_SUPPORT: build_registry's include/prepend tables. Prepended
    # modules are never consulted by `super`'s intervening-module check (they sit
    # above the class).
    @included_modules = included_modules
    @prepended_modules = prepended_modules
    @unknown_mixins = unknown_mixins
    # irep label -> Annotations::Annotation. Also the only trigger for
    # NATIVE_ARG_TARGETS' native calling convention (never ArgTypes); read by
    # native_arg_types for compile_method and compile_send.
    @annotations = annotations
    # irep label -> {owner:, name:} for every leaf body. Native MethodDefs have no
    # body.
    @owner_of = {}
    registry.each_value do |defs|
      defs.each { |d| @owner_of[d.irep] = d if d.irep }
    end
    @class_layout = class_layout # class_name -> {ivar_name => class_name} -- see ClassLayout's own comment.
    @class_annotations = class_annotations # irep label -> ClassAnnotations::Annotation
    @only_owners = nil # set by compile_all -- see its own comment.
    # Set when a compiled method needs bc2cpp_const_get_or_object;
    # emit_const_lookup_helper emits it (and mruby/error.h) only then.
    @const_lookup_helper_used = false
    # NATIVE_CONSTRUCT_TARGETS keys actually used; read by
    # emit_native_construct_decls.
    @native_construct_used = Set.new
    # DIRECT_CONSTRUCT_TARGETS actually used; read by
    # emit_direct_construct_decls.
    @direct_construct_used = Set.new
    @clean_cache = {} # irep label -> does compile_method(label) end up #error-free? (memoized -- see compiles_clean?'s own comment)
    @probing = Set.new # recursion guard for compiles_clean? (mutually-MONO-recursive methods)
    # ATTR_STRUCT_DEVIRT: [owner, ivar] pairs embedded only because a synthesized
    # struct-aware accessor (emit_ivar_accessor_pair) replaces the native attr_*
    # one. Filled by drop_unsafe_embeddings, read by emit_synthesized_accessors.
    @synthesize_accessor_for = Set.new
    # Temporarily the RAW layout: drop_unsafe_embeddings calls compiles_clean? ->
    # compile_method, which reads @ivar_layout[d.owner] (nil would raise).
    # Replaced by the filtered result right after.
    @ivar_layout = ivar_layout
    # FIXNUM_RETURN_PROOF: must exist (empty) before drop_unsafe_embeddings
    # (compiles_clean? -> compile_method -> proven_fixnum_operand?). Probing with
    # the empty set is exact: this proof chooses between two `#error`-free arms,
    # so the memoized compiles_clean? answers are the same. The real fixpoint runs
    # once @ivar_layout is final (proof source 3 reads it).
    @fixnum_return_names = Set.new
    # ENTRY_ARG_CALLSITE_PROOF: nil (not empty) until its fixpoint runs;
    # fixnum_proof_entry_arg? refuses on nil, so the first
    # compute_fixnum_return_names pass has no circular seeding.
    @entry_arg_fixnum = nil
    # ARRAY_RETURN_PROOF: must exist (empty) before drop_unsafe_embeddings, for the
    # same reason as @fixnum_return_names: a recognizer's region is all-or-nothing
    # and otherwise falls back to the `#error`-free BLOCK_FALLBACK, so
    # compiles_clean? answers are unchanged.
    @array_return_names = Set.new
    # ARRAY_RETURN_IVAR_HINT: `analysis_only` builds just enough to answer
    # array_return_names so the driver can feed it into a second ClassLayout pass
    # (see the driver's stratification comment). Exact, not approximate:
    # compute_array_return_names reads only ivars already final here, and not
    # @ivar_layout or @fixnum_return_names (its predicate is trace_new_target, a
    # top-level function, plus proven_array_source).
    # FIXNUM_RETURN_IVAR_HINT (`analysis_only == :fixnum_return`): stop after
    # FIXNUM_RETURN_PROOF instead. Its proof source 3 reads @ivar_layout, so
    # drop_unsafe_embeddings runs first, or an ivar it would reject could leak a
    # false proof. The ENTRY_ARG alternation is skipped; the final CodeGen runs it.
    if analysis_only == :fixnum_return
      @ivar_layout = drop_unsafe_embeddings(ivar_layout)
      compute_fixnum_return_names
      return
    end
    if analysis_only
      compute_array_return_names
      # RETCLASS_SELF_CALL_SUPPORT: computed in the same probing pass as
      # compute_array_return_names, for the same reason.
      compute_class_return_names
      return
    end
    @ivar_layout = drop_unsafe_embeddings(ivar_layout) # class_name -> {ivar_name => :fixnum}
    compute_fixnum_return_names
    # ARRAY_RETURN_PROOF: once, after @class_layout and @ivar_layout are final. It
    # neither reads nor feeds the Fixnum sets, so it is outside the alternation.
    compute_array_return_names
    # RETCLASS_SELF_CALL_SUPPORT: recomputed against the final @class_layout.
    compute_class_return_names
    # ENTRY_ARG_CALLSITE_PROOF <-> FIXNUM_RETURN_PROOF alternation. Each is a
    # greatest fixpoint that is sound given the other's current set (joint
    # induction: see compute_entry_arg_fixnum), and each re-seeds from all
    # candidates, so both sets only grow and the loop converges. The limit keeps
    # it linear if a future proof source converges slowly.
    ENTRY_ARG_ALTERNATION_LIMIT.times do
      before_args = @entry_arg_fixnum
      before_rets = @fixnum_return_names
      compute_entry_arg_fixnum
      compute_fixnum_return_names
      break if @entry_arg_fixnum == before_args && @fixnum_return_names == before_rets
    end
  end

  def const_lookup_helper_used?
    @const_lookup_helper_used
  end

  # FIXNUM_RETURN_PROOF result, for the diagnostic.
  def fixnum_return_names
    @fixnum_return_names
  end

  # Embedded ivars live in a struct allocated by the compiled #initialize's
  # mrb_data_init. If #initialize does not compile (or is inherited), other
  # compiled methods would use DATA_PTR(self) on a plain MRB_TT_OBJECT: memory
  # corruption, not a missed optimization.
  # An arity check is not enough (Game::Actor#initialize has pure mandatory
  # arity but its body has a block); compiles_clean? is the exact test, and is
  # also sufficient: the mrb_data_init emission is unconditional for a compiled
  # #initialize with an embedded layout and comes before any control flow,
  # including emit_optional_dispatch. (SUPER and other pure_mandatory_arity?
  # callers still need pure arity because they call `_impl` directly, bypassing
  # the entry wrapper.)
  def drop_unsafe_embeddings(ivar_layout)
    embedding_owners = ivar_layout.keys.to_set
    subclass_of = lambda do |klass, ancestor|
      seen = Set.new
      superclass = @superclass_of[klass]
      while superclass.is_a?(String) && !seen.include?(superclass)
        return true if superclass == ancestor

        seen << superclass
        superclass = @superclass_of[superclass]
      end
      false
    end

    ivar_layout.each_with_object({}) do |(owner, ivars), out|
      # One object has one DATA_PTR: a base class and a subclass that both embed
      # would overwrite it with different layouts. Keep both in iv_tbl unless one
      # shared struct covers the whole chain.
      inherited_layout = embedding_owners.any? do |other|
        other != owner && (subclass_of.call(owner, other) || subclass_of.call(other, owner))
      end
      next if inherited_layout

      next if self.class.wired_embeddings && !self.class.wired_embeddings.include?(owner)

      limit = self.class.embed_ivar_limits&.[](owner)
      ivars = ivars.select { |name, _| limit.include?(name) } if limit
      init = @registry['initialize']&.find { |d| d.owner == owner }
      next unless init && compiles_clean?(init.irep)

      # Every read/write of an embedded ivar must go through this compiler's
      # GETIV/SETIV or a replacement it controls. A native attr_reader/attr_writer
      # (src/class.c, plain mrb_iv_get/mrb_iv_set on iv_tbl) would read nil or write
      # into iv_tbl (LCF::EventCommand's `attr_reader :code`). build_registry
      # registers such accessors as synthetic irep-nil MethodDefs, checked here.
      # ATTR_STRUCT_DEVIRT: a `kind: :ivar_accessor` exposure (and only that; a
      # Struct member accessor is different storage) can be replaced by
      # emit_ivar_accessor_pair, registered via register.cxx. mrb_define_method
      # replaces the class's method-table entry, so dynamic calls (send, unproven
      # receivers) reach the struct-aware accessor too; IVAR_ACCESSOR_DEVIRT is only
      # a call-site shortcut on top. Only ivars whose native reader and writer are
      # all :ivar_accessor qualify.
      safe = ivars.reject do |name, _|
        reader_native = natively_exposed?(owner, name)
        writer_native = natively_exposed?(owner, "#{name}=")
        reader_blocked = reader_native && !synthesizable_accessor_only?(owner, name)
        writer_blocked = writer_native && !synthesizable_accessor_only?(owner, "#{name}=")
        next true if reader_blocked || writer_blocked || !every_accessor_compiles?(owner, name)

        # Synthesize only the accessor that exists natively: adding an `x=` to a class
        # with only `attr_reader :x` would change behavior.
        @synthesize_accessor_for << [owner, name, :reader] if reader_native
        @synthesize_accessor_for << [owner, name, :writer] if writer_native
        false
      end
      out[owner] = safe unless safe.empty?
    end
  end

  # Is `name` on `owner` exposed by a native (irep-nil) accessor that uses
  # iv_tbl and would bypass the embedded struct?
  def natively_exposed?(owner, name)
    (@registry[name] || []).any? { |d| d.owner == owner && d.irep.nil? }
  end

  # ATTR_STRUCT_DEVIRT: are all native definitions of `name` on `owner` plain
  # attr_* accessors (:ivar_accessor)? Vacuously true when there are none. False
  # when another native definition shares the name, e.g. a Struct member
  # accessor (positional storage, nothing to synthesize).
  def synthesizable_accessor_only?(owner, name)
    (@registry[name] || []).select { |d| d.owner == owner }.all? { |d| d.kind == :ivar_accessor }
  end

  # Every method touching an embedded ivar must compile, not just #initialize.
  # struct RData (mruby/data.h) has its own `iv` table separate from `data`
  # (DATA_PTR), so an interpreted method would read/write iv_tbl while compiled
  # siblings use the struct: two diverging copies of the same ivar (e.g.
  # Game::Interpreter#update, left interpreted, read nil @frame_steps).
  def every_accessor_compiles?(owner, ivar_name)
    # `@registry` auto-vivifies on `[]`, and compiles_clean? below can reach such a
    # read (natively_exposed?), which would add keys while this loop iterates.
    # `.values` snapshots the arrays first.
    @registry.values.each do |defs|
      defs.each do |d|
        next unless d.irep

        # A subclass's own GETIV/SETIV addresses its own (struct-less) layout,
        # so it would reach iv_tbl even when compiled: never embed then.
        return false if d.owner != owner && strict_subclass?(d.owner, owner) && irep_subtree_touches_ivar?(d.irep, ivar_name)
        next unless d.owner == owner

        touches = irep_subtree_touches_ivar?(d.irep, ivar_name)
        return false if touches && !compiles_clean?(d.irep)
      end
    end
    true
  end

  def strict_subclass?(klass, ancestor)
    seen = Set.new
    superclass = @superclass_of[klass]
    while superclass.is_a?(String) && seen.add?(superclass)
      return true if superclass == ancestor

      superclass = @superclass_of[superclass]
    end
    false
  end

  # Does this method's irep, or any irep nested in it (block bodies are separate
  # child ireps), touch this ivar? An interpreted method runs its blocks too, so
  # Game::Transition#clip's `rects.each { ... @width ... }` counts even though
  # its top-level irep never mentions @width. `seen` skips ireps shared by
  # several call sites.
  def irep_subtree_touches_ivar?(label, ivar_name, seen = Set.new)
    return false if seen.include?(label)

    seen << label
    irep = @ireps.fetch(label)
    return true if irep.instructions.any? do |insn|
      (insn.op == 'SETIV' || insn.op == 'GETIV') && insn.args[/@(\w+)/, 1] == ivar_name
    end

    irep.reps.any? { |child| irep_subtree_touches_ivar?(child, ivar_name, seen) }
  end

  def cpp_name(owner, name)
    sanitize("#{owner}_#{name}")
  end

  # NATIVE_ARG_TARGETS' per-position types, shared by compile_method (signature)
  # and compile_send (call-site unboxing) so they cannot disagree. Returns `mand`
  # slots of :fixnum/:symbol or nil (plain mrb_value). Requires a real irep AND
  # NATIVE_ARG_TARGETS membership; an annotation alone is not enough (see that
  # constant).
  def native_arg_types(d, mand)
    return Array.new(mand) unless d.irep && NATIVE_ARG_TARGETS.include?("#{d.owner}##{d.name}")

    ann = @annotations[d.irep]
    return Array.new(mand) unless ann

    Array.new(mand) { |i| ann.args[i] }
  end

  # C++ type for a native_arg_types slot: C_TYPE.fetch(t) or mrb_value. No
  # `:array` arm on purpose: an Array token in argument position raises KeyError
  # (fail loud). Return-type gates read `.ret` directly.
  # NILABLE_EMBED_SUPPORT: `:fixnum_nil` has a C_TYPE entry (emit_structs needs
  # it) but must never reach here: an argument is boxed into an mrb_value
  # register by TYPE_OPS[:box], which is a value-producing call, not a
  # by-reference field. Refused loudly rather than silently mistyped.
  def native_c_type(t)
    raise "NILABLE_EMBED_SUPPORT: #{t} cannot be a native argument type" if CodeGen::NULLABLE_TYPES.include?(t)

    t ? C_TYPE.fetch(t) : 'mrb_value'
  end

  # Owner names are constant paths ("Game::Actor"); `::` is not valid in a C++
  # identifier, so every generated name goes through this.
  def sanitize(s)
    s.gsub(/[^a-zA-Z0-9_]/, '_')
  end

  # Lexical scope segments (innermost last) for a bare constant in a def body,
  # used by GETCONST codegen and const_chain_value_expr. A trailing ".singleton"
  # is stripped: `def self.x` inside `class Bitmap` has Module.nesting
  # [RGSS::Bitmap, RGSS]. Splitting "RGSS::Bitmap.singleton" as-is looked up a
  # constant named "Bitmap.singleton" in the unguarded scope-chain part of
  # GETCONST, a NameError at runtime. No effect on real constant paths.
  def lexical_scope_path(owner)
    owner.sub(/\.singleton\z/, '').split('::')
  end

  # Names with exactly one definition in the whole program: static method
  # resolution. A name whose only definition is native (irep nil) is not a
  # target: there is no `_impl`, and calling the C function directly would
  # leave mrb_get_args reading a stale mrb->c->ci frame (see vm.c
  # mrb_funcall_with_block).
  def monomorphic_target(name)
    # RUNTIME_DEF_DEVIRT_GUARD: a name the current method may install on a
    # singleton class at runtime cannot be bound statically (see
    # devirt_blocked_name?/class_body_installed_names).
    return nil if devirt_blocked_name?(name)

    defs = @registry[name]
    return nil unless defs && defs.size == 1
    return nil unless defs.first.irep
    return nil unless compiles_clean?(defs.first.irep)

    defs.first
  end
end
