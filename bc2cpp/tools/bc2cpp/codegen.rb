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
  class << self
    attr_accessor :wired_embeddings, :stable_class_constants, :struct_members,
                  :integer_constant_values, :integer_constant_ranges, :constant_value_classes,
                  :module_names, :core_hidden_defs,
                  :core_guarded, :core_aliases, :core_result_opaque_defs, :core_result_installed_names, :build_gem_names,
                  :enumerator_model, :native_singleton_inputs,
                  :rbs_block_signatures

    # INLINED_UNLISTED_SITE: kill switch BC2CPP_INLINED_UNLISTED=0.
    def inlined_unlisted_site?
      ENV['BC2CPP_INLINED_UNLISTED'] != '0'
    end

    # LOOP_FLOW_POSITION: kill switch BC2CPP_LOOP_FLOW_POSITION=0 (byte-identical to master).
    def loop_flow_position?
      ENV['BC2CPP_LOOP_FLOW_POSITION'] != '0'
    end
  end

  C_TYPE = { fixnum: 'mrb_int', symbol: 'mrb_sym', bool: 'mrb_bool',
             fixnum_nil: 'Bc2cppFixnumOrNil', value: 'mrb_value' }.freeze

  # NATIVE_DATA_OWNERS: classes whose instances keep their native payload in DATA_PTR, set by a
  # DataType<T> allocation in mruby-rgss/src/lib.cxx (alloc_obj asserts DATA_PTR is null first).
  # A compiled #initialize must not embed an ivar struct in those objects: mrb_data_init would
  # already occupy DATA_PTR before the first native load, so that assertion fails. Their ivars
  # stay in iv_tbl, whatever BC2CPP_WIRED_EMBEDDINGS lists.
  NATIVE_DATA_OWNERS = %w[RGSS::Bitmap].freeze

  # box/check/unbox/err per specialized type proof. Ordinary embedded ivars use
  # mrb_value directly so arbitrary Ruby assignments retain their normal behavior.
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
    fixnum: { box: 'mrb_fixnum_value', check: 'mrb_fixnum_p', unbox: 'mrb_fixnum', err: 'Integer' },
    symbol: { box: 'mrb_symbol_value', check: 'mrb_symbol_p', unbox: 'mrb_symbol', err: 'Symbol' },
    bool: { box: 'mrb_bool_value', check: 'bc2cpp_bool_p', unbox: 'mrb_true_p', err: 'boolean' },
    fixnum_nil: { box: 'bc2cpp_fixnum_or_nil_box', check: 'bc2cpp_fixnum_or_nil_p',
                  err: 'Integer or nil' },
    value: { box: '', check: '', unbox: '', err: '' },
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
                  native_registered_expressions: {}, closed_world: nil, outside_ivar_names: nil,
                  nil_operator_names: nil, outside_const_names: nil, native_ivar_scopes: {})
    @report_only_text = ENV['BC2CPP_TYPE_CHECK_ONLY'] == '1' && ENV['BC2CPP_TYPE_CHECK_TEXT_PASSES'] != '0'
    @ireps = ireps
    # NUMERIC_OPERAND_PROOF: ivar names spelled by sources outside the
    # closed world, and operators they define on NilClass. nil means the scan did
    # not run; the proofs that need them then prove nothing.
    @outside_ivar_names = outside_ivar_names
    @native_ivar_scopes = native_ivar_scopes
    @nil_operator_names = nil_operator_names
    @outside_const_names = outside_const_names
    # CLOSED_WORLD: the build's ClosedWorld (closed_world.rb); every bc2cpp run has one. It is nil only
    # while a core body compiles, in the analysis-only probe, and in unit fixtures.
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
    # BLOCK_SEMANTICS: the env slots of the BLOCK_FALLBACK body being
    # compiled that hold the method's return token and the call site's break
    # token (nil: this block has none). Saved and restored like @blk_param_name.
    @block_ret_slot = nil
    @block_brk_slot = nil
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
    # NESTED_BLOCK_FORWARD: the BLOCK_FALLBACK body's nesting depth,
    # which @blk_param_level is derived from (a nested body's `lv == 2` BLKPUSH
    # resolves against its parent region, not the method). Reset per method with
    # the rest of METHOD_COMPILE_STATE.
    @block_fallback_depth = 0
    # True while compiling a method of mruby's own Ruby (see core_targets).
    @compiling_core = false
    @ir_inline_remaining = 512
    @registry = registry
    # Structural bytecode answers survive probe rollback; emitted registrations do not.
    @block_capture_index = BlockCaptureIndex.new(@ireps, MAX_UPVAR_NEST_DEPTH, BLOCK_GIVEN_NAMES) unless ENV['BC2CPP_BLOCK_CAPTURE_INDEX'] == '0'
    @known_owners = Set.new(registry.values.flatten.map(&:owner))
    # FIBER_REACHABILITY_UNSAFE_SUPPORT: must exist before drop_unsafe_embeddings,
    # which reaches compile_method through compiles_clean?. See
    # compute_fiber_unsafe_methods.
    @yield_reach = build_yield_reach
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
    # CORE_VISIBILITY: compiled, but never a dispatch candidate.
    (self.class.core_hidden_defs || []).each { |d| @owner_of[d.irep] = d if d.irep }
    @core_guard_index = {}
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
    # Any direct allocation needs the shared helper; only allowlisted classes
    # need the gem-init class accessor declared by emit_direct_construct_decls.
    @direct_alloc_used = false
    @clean_cache = {} # irep label -> does compile_method(label) end up #error-free? (memoized -- see compiles_clean?'s own comment)
    @probing = Set.new # recursion guard for compiles_clean? (mutually-MONO-recursive methods)
    # ATTR_STRUCT_DEVIRT: [owner, ivar] pairs embedded only because a synthesized
    # struct-aware accessor (emit_ivar_accessor_pair) replaces the native attr_*
    # one. Filled by drop_unsafe_embeddings, read by emit_synthesized_accessors.
    @synthesize_accessor_for = Set.new
    @typed_demotions = {}
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
    # RBS_CHECKED_PARAMS: `analysis_only == :constructor_sites` builds just the tables
    # constructor_pool_candidates reads; none of them is a layout or a proof table.
    return if analysis_only == :constructor_sites

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
      # Without the foreign-method scan this probe cannot prove a return, so embedding checks cannot help.
      return unless @foreign_method_names

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
    # DECLARED_RETURN_CHECK: every seeded declaration against the final sets.
    check_declared_returns
    # NUMERIC_OPERAND_PROOF reads the sets above; drop flows memoized by the
    # compile probes that ran with weaker facts.
    reset_numeric_flow!
    compute_numeric_facts
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
    demote_typed_ivars_foreign_writable(
      demote_typed_ivars_maybe_unassigned(demote_typed_ivars_read_by_interpreter(select_embeddings(ivar_layout)))
    )
  end

  # INIT_ASSIGNED: the slots whose zeroed state reads as a value.
  # fixnum_nil is left out: its zero state is nil.
  ZEROED_READS_AS_VALUE = %i[fixnum symbol bool].freeze

  # A zeroed typed slot reads 0/false where an ivar some path observes before
  # #initialize assigns it reads nil: such an ivar stays a :value slot.
  def demote_typed_ivars_maybe_unassigned(layout)
    layout.to_h do |owner, ivars|
      init = @registry['initialize']&.find { |d| d.owner == owner }
      program = init&.irep && BytecodeIR.for(@ireps.fetch(init.irep))
      [owner, ivars.to_h do |name, type|
        assigned = !ZEROED_READS_AS_VALUE.include?(type) || (program && program.ivar_assigned_before_exposure?(name))
        [name, assigned ? type : :value]
      end]
    end
  end

  # A typed slot only holds its type; the runtime (rdata_ivar_store) and the
  # synthesized attr_writer raise TypeError for anything else, where the interpreter would
  # store the value. So an ivar keeps a typed slot only when every writer is one the compiler
  # sees and has typed: no reflection or foreign source spells it, no computed
  # instance_variable_set can reach it, and an attr_writer for it is only called with
  # values of its type. Needs the closed-world scans; without them (unit fixtures) the layout
  # is the caller's declaration, as before.
  def demote_typed_ivars_foreign_writable(layout)
    return layout if @outside_ivar_names.nil? || @closed_world.nil?

    typed = layout.flat_map { |owner, ivars| ivars.filter_map { |name, type| [owner, name] if type != :value } }
    return layout if typed.empty?

    names, reflective = foreign_written_ivar_facts
    typed.each do |owner, name|
      reason = if reflective then "computed write: #{reflective}"
               elsif names.include?(name) then 'name spelled outside the typed analysis'
               elsif scoped_outside_writer?(owner, name) then 'name written outside the typed analysis on this family'
               else setter_foreign_value_reason(owner, name, layout[owner][name])
               end
      @typed_demotions[[owner, name]] = reason if reason
    end
    return layout if @typed_demotions.empty?

    layout.to_h do |owner, ivars|
      [owner, ivars.to_h { |name, type| [name, @typed_demotions.key?([owner, name]) ? :value : type] }]
    end
  end

  # [owner, ivar] => why its typed slot became a boxed one (demote_typed_ivars_foreign_writable),
  # for the diagnostic.
  def typed_demotions
    @typed_demotions
  end

  # [names, reflective]: ivar names some source outside the typed analysis writes or reads by
  # name (native/foreign source, a '@name' Symbol/String literal, a block run under another
  # self), and the reason when a write by computed name could reach any ivar (nil otherwise).
  # Marshal.load of bytes outside the closed world stays outside the model.
  def foreign_written_ivar_facts
    @foreign_written_ivar_facts ||= begin
      saved = @numeric_ivar_disabled
      @numeric_ivar_disabled = nil
      names = numeric_ivar_poisoned_names
      rebound = numeric_self_rebound_ireps
      reflective = @numeric_ivar_disabled
      @numeric_ivar_disabled = saved
      rebound.each { |label| names.merge(own_ivar_names(label)) }
      [names, reflective]
    end
  end

  IVAR_SETTER_SLOT_TYPES = { fixnum: %i[fixnum], symbol: %i[symbol], bool: %i[bool],
                             fixnum_nil: %i[fixnum fixnum_nil nil_literal] }.freeze

  # Why an attr_writer (or a setter reached by a computed name) may hand @name of +owner+ a value
  # its slot type cannot hold, or nil when every call of `name=` is a visible site whose
  # argument traces to the slot's type.
  def setter_foreign_value_reason(owner, name, type)
    setter = "#{name}="
    writers = @registry.fetch(setter, []).select do |d|
      d.irep.nil? && d.kind == :ivar_accessor && embed_family_owner?(d.owner, owner)
    end
    return nil if writers.empty?
    return 'attr_writer, no outside-source scan' unless @foreign_method_names && @outside_tokens
    return 'attr_writer reachable by a computed name' if numeric_dynamically_named?(setter)
    return 'attr_writer, name spelled by an outside source' if @outside_tokens.include?(name) || @foreign_method_names.include?(setter)

    sites, poisoned = entry_arg_call_index
    return 'attr_writer, symbol literal of the setter' if poisoned.include?(setter)

    here = sites[setter]
    return 'attr_writer without a visible call site' if here.empty? || here.any? { |(_irep, _idx, _recv, argc, _own)| argc != 1 }

    allowed = IVAR_SETTER_SLOT_TYPES.fetch(type)
    untyped = here.any? do |(irep, idx, recv, _argc, _own)|
      !allowed.include?(IvarLayout.trace_type(irep, idx, (recv + 1).to_s, {}, nil, 0, nil, nil, @registry,
                                              @integer_constants, nil))
    end
    'attr_writer called with an untyped value' if untyped
  end

  # A scoped outside name (native_ivar_scopes: audited natives, or foreign Ruby instance methods) is written
  # outside the typed analysis on instances of its scope classes, so their families' slots stay boxed; other
  # classes keep theirs.
  def scoped_outside_writer?(owner, name)
    scopes = @native_ivar_scopes[name]
    scopes && @outside_ivar_names.include?(name) && scopes.any? { |scope| embed_family_owner?(scope, owner) }
  end

  def embed_family_owner?(candidate, owner)
    candidate == owner || Array(@included_modules[owner]).include?(candidate) ||
      Array(@prepended_modules[owner]).include?(candidate) ||
      strict_subclass?(candidate, owner) || strict_subclass?(owner, candidate)
  end

  def select_embeddings(ivar_layout)
    embedding_owners = ivar_layout.keys.to_set
    ivar_layout.each_with_object({}) do |(owner, ivars), out|
      # One object has one DATA_PTR: a base class and a subclass that both embed
      # would overwrite it with different layouts. Keep both in iv_tbl unless one
      # shared struct covers the whole chain.
      inherited_layout = embedding_owners.any? do |other|
        other != owner && (strict_subclass?(owner, other) || strict_subclass?(other, owner))
      end
      next if inherited_layout
      next if NATIVE_DATA_OWNERS.include?(owner)

      next if self.class.wired_embeddings && !self.class.wired_embeddings.include?(owner)

      init = @registry['initialize']&.find { |d| d.owner == owner }
      next unless init && compiles_clean?(init.irep)

      # A native attr_reader/attr_writer can be replaced by a synthesized direct
      # slot accessor. Other native accessors stay eligible only when they are the
      # plain iv_tbl implementation; mrb_iv_get/mrb_iv_set now route those through
      # the RData slot descriptor too. Interpreted Ruby methods use the same API.
      safe = ivars.reject do |name, _|

        reader_native = natively_exposed?(owner, name)
        writer_native = natively_exposed?(owner, "#{name}=")
        reader_blocked = reader_native && !synthesizable_accessor_only?(owner, name)
        writer_blocked = writer_native && !synthesizable_accessor_only?(owner, "#{name}=")
        next true if reader_blocked || writer_blocked

        # Synthesize only the accessor that exists natively: adding an `x=` to a class
        # with only `attr_reader :x` would change behavior.
        @synthesize_accessor_for << [owner, name, :reader] if reader_native
        @synthesize_accessor_for << [owner, name, :writer] if writer_native
        false
      end

      next if safe.empty?

      @superclass_of.each_key do |klass|
        next unless strict_subclass?(klass, owner)

        initializers = (@registry['initialize'] || []).select { |d| d.owner == klass }
        next if initializers.empty?

        has_super = initializers.one? && initializers.first.irep &&
                    @ireps.fetch(initializers.first.irep).instructions.any? { |insn| insn.op == 'SUPER' }
        unless has_super
          raise "bc2cpp storage error: #{klass}#initialize must call super " \
                "to inherit embedded ivars from #{owner}"
        end

        # A later or conditional super is legal Ruby, but cannot prove that
        # inherited storage exists before the initializer's earlier work.
        next if initializer_starts_with_super?(initializers.first)

        safe = {}
        break
      end

      out[owner] = safe unless safe.empty?
    end
  end

  # TYPED_SLOT_INTERPRETED_ACCESS: a method left on the interpreter reaches a
  # typed slot through the RData ivar descriptor, which boxes on every read and
  # type-checks on every write (patches/mruby-rdata-ivar-slots.patch). Such an
  # ivar stays a plain :value slot instead.
  def demote_typed_ivars_read_by_interpreter(layout)
    typed = layout.flat_map { |owner, ivars| ivars.filter_map { |name, type| [owner, name] if type != :value } }
    return layout if typed.empty?

    # A probe compile registers class slots, counters and the like that the
    # final compile must meet in its own order, so keep only the answers.
    demoted = without_probe_side_effects do
      typed.select { |owner, name| interpreted_access?(owner, name) }
    end
    return layout if demoted.empty?

    layout.to_h do |owner, ivars|
      [owner, ivars.to_h { |name, type| [name, demoted.include?([owner, name]) ? :value : type] }]
    end
  end

  def interpreted_access?(owner, name)
    holders = [owner, *Array(@included_modules[owner])]
    # Snapshot: compiles_clean? reads @registry through its default proc,
    # which inserts keys.
    @registry.values.any? do |defs|
      defs.any? do |d|
        d.irep &&
          (holders.include?(d.owner) || strict_subclass?(d.owner, owner)) &&
          irep_subtree_touches_ivar?(d.irep, name) && !compiles_clean?(d.irep)
      end
    end
  end

  # Shallow-copies every container ivar and restores it afterwards, except
  # @clean_cache, whose answers stay valid. An ivar the probe created lazily
  # (`@x ||= {}`) is removed: leaving it would keep the probe's registrations
  # (e.g. a const-site helper) while the flag that emits their support code
  # is rolled back.
  def without_probe_side_effects
    saved = instance_variables.to_h do |ivar|
      value = instance_variable_get(ivar)
      [ivar, value.is_a?(Hash) || value.is_a?(Array) || value.is_a?(Set) ? value.dup : value]
    end
    yield
  ensure
    (instance_variables - saved.keys - [:@clean_cache]).each { |ivar| remove_instance_variable(ivar) }
    saved.each { |ivar, value| instance_variable_set(ivar, value) unless ivar == :@clean_cache }
  end

  def initializer_starts_with_super?(definition)
    return false unless definition.irep

    irep = @ireps[definition.irep]
    return false unless irep

    first = irep.instructions.find { |insn| !%w[ENTER LINE NOP MOVE].include?(insn.op) }
    first&.op == 'SUPER' && super_reaches_superclass?(definition) &&
      Array(@prepended_modules[definition.owner]).empty?
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

  def strict_subclass?(klass, ancestor)
    # @superclass_of never changes after construction, so each class's strict
    # ancestors are walked once.
    @strict_ancestors ||= {}
    ancestors = @strict_ancestors[klass] ||= begin
      seen = Set.new
      superclass = @superclass_of[klass]
      superclass = @superclass_of[superclass] while superclass.is_a?(String) && seen.add?(superclass)
      seen
    end
    ancestors.include?(ancestor)
  end

  # Does this method's irep, or any irep nested in it (block bodies are separate
  # child ireps), touch this ivar? An interpreted method runs its blocks too, so
  # Game::Transition#clip's `rects.each { ... @width ... }` counts even though
  # its top-level irep never mentions @width.
  def irep_subtree_touches_ivar?(label, ivar_name)
    subtree_ivar_names(label).include?(ivar_name)
  end

  # Every ivar name a GETIV/SETIV in the irep or a nested one mentions; ireps
  # are immutable, so each subtree is walked once however many ivars ask.
  def subtree_ivar_names(label)
    @subtree_ivar_names ||= {}
    @subtree_ivar_names[label] ||= begin
      names = own_ivar_names(label).dup
      @ireps.fetch(label).reps.each { |child| names.merge(subtree_ivar_names(child)) }
      names
    end
  end

  # The ivar names the irep's own GETIV/SETIV mention (nested ireps excluded), scanned once per irep.
  def own_ivar_names(label)
    @own_ivar_names ||= {}
    @own_ivar_names[label] ||= begin
      names = Set.new
      @ireps.fetch(label).instructions.each { |i| names << i.ivar if (i.op == 'GETIV' || i.op == 'SETIV') && i.ivar }
      names.freeze
    end
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
  #
  # INJECTIVE_MANGLE: the two structural characters of a name -- the `::` in a
  # constant path and the `.` in a `.singleton` pseudo-owner -- still become a
  # single `_`, exactly as they always have, so every symbol the tree already
  # spells out (`Game__Actor_update`, `Widget_singleton_make`,
  # `bc2cpp_owner_reg_Widget_singleton`) is unchanged. Every OTHER character
  # becomes `$` plus its two-digit lowercase hex code point.
  #
  # The split is what makes this injective while keeping the diff to a minimum.
  # Under run-collapse, `<` `>` `&` `|` `^` `+` `-` `*` `/` `%` `!` `~` all became
  # `_`, `<=` `>=` `==` `!=` `<<` `>>` `[]` `**` `+@` `-@` `=~` `!~` all became
  # `__`, and `===` `<=>` `[]=` all became `___`. A Ruby method name can contain
  # none of `:` or `.`, so nothing else in the program can produce the `$3c` that
  # `<` produces, and no legal name can forge it: `Array__3c` sanitizes to
  # `Array__3c` (its `_`s pass through) while `Array_<` sanitizes to
  # `Array_$3c`.
  #
  # An earlier revision escaped `_` as well, which is injective but pushed every
  # separator from 1 to 3 characters and took the longest symbol in this program
  # to 97 characters, past C++'s 63-significant-character guarantee. Another let
  # `.` through unescaped, which is wrong: `.` is not a legal C++ identifier
  # character, and codegen_emit's owner-local is
  # `bc2cpp_owner_reg_#{sanitize(owner)}`, so `Widget.singleton` produced
  # `bc2cpp_owner_reg_Widget.singleton` and the C++ build failed to parse it.
  #
  # `$` is a legal C++ identifier character, so every result is still a valid
  # identifier, and none of them can collide with a hand-written name in the tree
  # because none of those contain `$`.
  #
  # This was NOT injective at all before: mruby-hash-ext's Hash#< and Hash#>
  # both became `Hash__`, and Hash#==/#<=/#>=/#!= all became `Hash___`, so
  # compile_all -- which emits one `_impl` per registry leaf and derives the
  # symbol from cpp_name(owner, name) -- emitted the same C++ function twice and
  # the translation unit failed ("redefinition of `mrb_value Hash___impl(...)`").
  # It stayed hidden because no emitted owner had two operator-named methods:
  # mruby-hash-ext's Hash comparison methods reached the registry only once core
  # mrblib entered the closed world, and with a per-gem ONLY_OWNERS allowlist
  # they were filtered out anyway.
  STRUCTURAL_NAME_CHARS = ':.'.freeze

  def sanitize(s)
    # Names repeat across thousands of call sites; the result is frozen because
    # it is shared.
    (@sanitized ||= {})[s] ||= s.gsub(/[^a-zA-Z0-9_]/) { |c|
      STRUCTURAL_NAME_CHARS.include?(c) ? '_' : format('$%02x', c.ord)
    }.freeze
  end

  def ivar_field_name(name)
    "ivar_#{sanitize(name)}"
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

    defs = core_targets(@registry[name])
    return nil unless defs && defs.size == 1
    return nil unless defs.first.irep
    return nil unless compiles_clean?(defs.first.irep)

    defs.first
  end

  # Inside a core method only core definitions (and the native placeholders that
  # keep a name POLY) are static call targets; mruby's own code never binds an engine method.
  def core_targets(defs)
    return defs unless @compiling_core && defs

    defs.select { |d| d.core || d.owner == '<native>' }
  end
end
