# frozen_string_literal: true

# CodeGen: per-method compile state and file-level emission.

class CodeGen
  # Does compile_method(label) come out without `#error`? A MONO target with the
  # right arity can still have an unsupported opcode in its body; SKIP_UNSUPPORTED
  # then drops its `_impl` and a direct call to it fails to link. Compiling for
  # real (memoized) is the only way to answer without duplicating compile_insn's
  # opcode list. A label already being probed reports "not known clean" (safe
  # direction), so mutually recursive MONO methods just keep mrb_funcall.
  # HOT_ONLY: an excluded method answers false before compiling, so every direct
  # call and embedding gated here treats it as an unsupported body (ADR 0214).
  def compiles_clean?(label)
    return false if hot_only_excluded?(label)
    # CORE_BLOCK_GUARD: only the registered entry carries the guard, so no direct `_impl`
    # call may reach a guarded body.
    return false if self.class.core_guarded&.include?(label)
    # RESUMABLE_ENTRY: `_impl` is the entry that hands over to the driver, not the body.
    return false if resumable_method?(label)
    return @clean_cache[label] if @clean_cache.key?(label)
    return false if @probing.include?(label)

    @probing << label
    begin
      result = with_fresh_method_state { compile_method(label) }
      @clean_cache[label] = !result[:code].include?('#error')
    ensure
      @probing.delete(label)
    end
  end

  # Every ivar one compile_method call sets and clears for itself, with its
  # top-level value. A probe runs mid-way through another method's compile.
  METHOD_COMPILE_STATE = {
    :@elem_class_hint => nil, :@block_hash_capture_hints => nil, :@block_fallback_upvars => nil,
    :@block_fallback_active => false, :@blk_param_name => nil, :@blk_param_level => 0,
    :@block_ret_slot => nil, :@block_brk_slot => nil,
    :@inline_nested => nil, :@inline_nested_pre => nil, :@suppress_native_expression_send => nil,
    :@runtime_installed_names => nil, :@ensure_except_remaps => nil, :@self_class_unknown => nil,
    :@compiling_core => false, :@resumable => nil
  }.freeze

  # Runs a nested compile against top-level state, then restores the caller's
  # state, so neither compile sees or clobbers the other's (ADR 0202).
  def with_fresh_method_state
    saved = METHOD_COMPILE_STATE.keys.map { |ivar| instance_variable_get(ivar) }
    METHOD_COMPILE_STATE.each { |ivar, initial| instance_variable_set(ivar, initial) }
    yield
  ensure
    METHOD_COMPILE_STATE.keys.zip(saved).each { |ivar, value| instance_variable_set(ivar, value) } if saved
  end

  def embed_type(owner, ivar)
    (@ivar_layout[owner] || {})[ivar]
  end

  def embedding_classes
    owners = @ivar_layout.keys.to_set
    @superclass_of.each do |klass, superclass|
      next unless superclass.is_a?(String) && !klass.end_with?('.singleton')

      seen = Set.new
      while superclass.is_a?(String) && !seen.include?(superclass)
        break if @ivar_layout.key?(superclass) && owners.add?(klass)

        seen << superclass
        superclass = @superclass_of[superclass]
      end
    end
    owners.to_a.sort
  end

  # INSTANCE_TT_SETUP: every class in embedding_classes stores ivars in an RData
  # payload, so its instances must be MRB_TT_DATA (GETIV/SETIV and mrb_data_init
  # assume it). This generates the MRB_SET_INSTANCE_TT setup for exactly those
  # classes instead of hand-kept register.cxx calls that drifted. A class whose
  # constant is not defined yet is skipped: each compiled gem calls this at its
  # gem_init, and a later gem's call picks it up. Idempotent.
  # OWNER_METHOD_REGISTRATION: generates the method registration for every
  # compiled entry of `owners` from the same :aspec data the entry wrapper's
  # mrb_get_args uses, so the two cannot drift (hand registration missed many
  # entries, leaving interpreted fallbacks reading nil from embedded ivars).
  # Idempotent with an identical hand registration: mrb_define_method overwrites.
  # :protected is skipped (mruby has no mrb_define_protected_method, and
  # mrb_define_method would make it public). A `.singleton` owner registers via
  # mrb_define_class_method; a private one via
  # bc2cpp_define_private_class_method (below).
  # STATIC_DISPATCH_UNREGISTRATION (docs/adr/0203): entries in `unregistered` are
  # skipped: static_dispatch_registrations.rb proved no runtime lookup reaches
  # them, so the wrapper is dead, and with no dynamic lookup there is no
  # interpreted fallback to read iv_tbl.
  # HOT_ONLY: with any exclusion, `unregistered` entries are registered again --
  # the 0203 proof assumes every caller is compiled, and an excluded caller
  # looks the name up dynamically (ADR 0214).
  def emit_owner_registrations(compiled, owners, unregistered: STATIC_DISPATCH_UNREGISTERED)
    by_owner = compiled.group_by { |m| m[:owner] }
    targets = owners.select { |o| by_owner.key?(o) }
    if hot_only_active?
      restored = compiled.select { |m| !owners.include?(m[:owner]) && unregistered.include?("#{m[:owner]}##{m[:name]}") }
      by_owner = by_owner.merge(restored.group_by { |m| m[:owner] }) { |_, _, mine| mine }
      targets += restored.map { |m| m[:owner] }.uniq
      unregistered = Set.new
    end

    # PRIVATE_CLASS_METHOD_SUPPORT: mruby has no mrb_define_private_class_method.
    # mrb_define_method_raw (src/class.c) only forces a singleton-class method
    # public while its visibility is still the MT_VDEFAULT sentinel, so setting
    # MRB_METHOD_PRIVATE_FL first keeps it private -- public MRB_API only, no
    # submodule patch.
    needs_private_class_method = targets.any? do |o|
      o.end_with?('.singleton') && by_owner[o].any? { |m| m[:visibility] == :private }
    end

    # Always emitted, even empty, so every gem_init can call it unconditionally.
    out = +"// OWNER_METHOD_REGISTRATION -- see bc2cpp.rb's own emit_owner_registrations comment.\n"
    if needs_private_class_method
      out << <<~CPP
        static void bc2cpp_define_private_class_method(mrb_state* M, struct RClass* c, const char* name, mrb_func_t func, mrb_aspec aspec) {
          int ai = mrb_gc_arena_save(M);
          struct RClass* sc = mrb_singleton_class_ptr(M, mrb_obj_value(c));
          mrb_method_t m;
          MRB_METHOD_FROM_FUNC(m, func);
          m.flags |= aspec;
          MRB_METHOD_SET_VISIBILITY(m, MRB_METHOD_PRIVATE_FL);
          mrb_define_method_raw(M, sc, mrb_intern_cstr(M, name), m);
          mrb_gc_arena_restore(M, ai);
        }
      CPP
    end
    out << "static void bc2cpp_register_owner_methods(mrb_state* M) {\n"
    targets.each do |owner|
      singleton = owner.end_with?('.singleton')
      var = "bc2cpp_owner_reg_#{sanitize(owner)}"
      out << "  struct RClass* #{var} = mrb_class_ptr(#{const_chain_value_expr(owner)});\n"
      by_owner[owner].each do |m|
        fn = if singleton
               m[:visibility] == :private ? 'bc2cpp_define_private_class_method' : 'mrb_define_class_method'
             elsif m[:visibility] == :private
               'mrb_define_private_method'
             elsif m[:visibility] == :public
               'mrb_define_method'
             end
        unless fn
          out << "  // #{owner}##{m[:name]} left unregistered (:#{m[:visibility]} has no safe registration call).\n"
          next
        end
        if unregistered.include?("#{owner}##{m[:name]}")
          out << "  // #{owner}##{m[:name]} left unregistered: statically dispatched only (docs/adr/0203).\n"
          next
        end
        names = [m[:name]]
        # CORE_ALIASES: the same entry under the names the bytecode aliased it to.
        names += self.class.core_aliases&.dig([owner, m[:name]]) || [] if @owner_of[m[:label]]&.core
        defines = names.map { |name| "#{fn}(M, #{var}, #{c_string_literal(name)}, #{m[:entry]}, #{m[:aspec]});" }
        # CORE_BLOCK_GUARD: the bytecode must be saved before it is replaced.
        if m[:guard]
          save = "bc2cpp_core_save_interpreted(M, #{var}, #{singleton}, #{c_string_literal(m[:name])}, #{m[:guard]})"
          out << "  if (#{save}) { #{defines.join(' ')} }\n"
        else
          defines.each { |define| out << "  #{define}\n" }
        end
      end
    end
    out << "}\n\n"
    out
  end

  # CORE_BLOCK_GUARD (ADR 0269): the run-time half of core_block_guard. The bytecode of
  # every guarded method is kept in a hidden ivar of Object (no `@`, so no reflection
  # lists it), one slot per method index, and rooted by it for the state's lifetime.
  # mrb_exec_irep, called by the entry while the VM is still in the cfunc's own
  # frame, swaps that frame for the bytecode, as instance_exec does: no C frame is
  # left between the caller and the method.
  def emit_core_guard_helpers(compiled)
    return '' unless compiled.any? { |m| m[:guard] }

    <<~CPP
      // CORE_BLOCK_GUARD -- see core_block_guard in codegen_method.rb.
      #include <stdio.h>
      extern "C" mrb_value mrb_exec_irep(mrb_state*, mrb_value, const struct RProc*);
      static mrb_value bc2cpp_core_interpreted(mrb_state* M, mrb_value self, mrb_int index) {
        mrb_value table = mrb_iv_get(M, mrb_obj_value(M->object_class), mrb_intern_lit(M, "__bc2cpp_core_interpreted__"));
        return mrb_exec_irep(M, self, mrb_proc_ptr(mrb_ary_ref(M, table, index)));
      }
      static bool bc2cpp_core_each_is_builtin(mrb_state* M, mrb_value self) {
        struct RClass* found = mrb_class(M, self);
        mrb_method_search_vm(M, &found, mrb_intern_lit(M, "each"));
        return found == M->array_class || found == M->hash_class || found == M->range_class;
      }
      static bool bc2cpp_core_save_interpreted(mrb_state* M, struct RClass* c, bool singleton, const char* name, mrb_int index) {
        struct RClass* target = singleton ? mrb_singleton_class_ptr(M, mrb_obj_value(c)) : c;
        struct RClass* found = target;
        mrb_method_t m = mrb_method_search_vm(M, &found, mrb_intern_cstr(M, name));
        mrb_value object = mrb_obj_value(M->object_class);
        mrb_sym key = mrb_intern_lit(M, "__bc2cpp_core_interpreted__");
        mrb_value table = mrb_iv_get(M, object, key);
        if (found == target && !MRB_METHOD_UNDEF_P(m) && MRB_METHOD_PROC_P(m) && !MRB_PROC_CFUNC_P(MRB_METHOD_PROC(m))) {
          if (mrb_nil_p(table)) {
            table = mrb_ary_new(M);
            mrb_iv_set(M, object, key, table);
          }
          mrb_ary_set(M, table, index, mrb_obj_value((struct RProc*)MRB_METHOD_PROC(m)));
          return true;
        }
        // A second registration finds its own entry, which has its bytecode saved already.
        if (found == target && !mrb_nil_p(table) && !mrb_nil_p(mrb_ary_ref(M, table, index))) return true;
        fprintf(stderr, "[RPG2k] bc2cpp core: %s has no bytecode definition to fall back to; left as it is\\n", name);
        return false;
      }

    CPP
  end

  def emit_instance_tt_setup(compiled = [])
    out = +"// INSTANCE_TT_SETUP -- see bc2cpp.rb's own emit_instance_tt_setup comment.\n"
    out << "static void bc2cpp_set_instance_tts(mrb_state* M) {\n"
    out << "  static const char* const paths[][6] = {\n"
    embedding_classes.each do |klass|
      next if klass.end_with?('.singleton')

      segments = klass.split('::')
      raise "INSTANCE_TT_SETUP: #{klass} nests deeper than 5 levels" if segments.size > 5

      out << "    { #{(segments.map { |seg| "\"#{seg}\"" } + ['nullptr']).join(', ')} },\n"
    end
    out << "    { nullptr },\n  };\n"
    out << <<~CPP
      for (const auto& path : paths) {
        if (!path[0]) break;
        mrb_value scope = mrb_obj_value(M->object_class);
        bool found = true;
        for (int i = 0; path[i]; ++i) {
          mrb_sym name = mrb_intern_cstr(M, path[i]);
          if (!mrb_const_defined_at(M, scope, name)) { found = false; break; }
          scope = mrb_const_get(M, scope, name);
        }
        if (found && mrb_type(scope) == MRB_TT_CLASS) MRB_SET_INSTANCE_TT(mrb_class_ptr(scope), MRB_TT_DATA);
      }
    CPP
    # RESUMABLE_ENTRY: define the frame class and the driver where no fiber is running.
    out << "  bc2cpp_resumable_init(M);\n" if compiled.any? { |m| m[:resumable] }
    out << "}\n"
    out
  end

  def struct_name(owner)
    sanitize("#{owner}_ivars")
  end

  def type_var(owner)
    sanitize("#{owner}_ivars_type")
  end

  # ATTR_STRUCT_DEVIRT: the compiled getter/setter for one [owner, ivar,
  # :reader | :writer] from @synthesize_accessor_for (see
  # drop_unsafe_embeddings: once registered, every access path is
  # struct-aware). Built with the same box/check/unbox code as GETIV/SETIV.
  # Returns a `compiled`-shaped Hash so it needs no special-casing downstream.
  def emit_ivar_accessor_pair(owner, ivar, which)
    type = embed_type(owner, ivar)
    return nil unless type

    sname = struct_name(owner)
    ops = TYPE_OPS.fetch(type)
    base = "#{sanitize(owner)}_#{sanitize(ivar)}"

    case which
    when :reader
      impl = "#{base}_impl"
      entry = base
      field = "((#{sname}*)DATA_PTR(self))->#{ivar_field_name(ivar)}"
      value = type == :value ? "(mrb_undef_p(#{field}) ? mrb_nil_value() : #{field})" : "#{ops[:box]}(#{field})"
      code = <<~CPP
        // #{owner}##{ivar} -- synthesized attr_reader override (@#{ivar} is
        // embedded; this replaces the plain native accessor -- see
        // drop_unsafe_embeddings' own ATTR_STRUCT_DEVIRT comment).
        mrb_value #{impl}(mrb_state* M, mrb_value self) {
          return #{value};
        }

        static mrb_value #{entry}(mrb_state* M, mrb_value self) {
          return #{impl}(M, self);
        }

      CPP
      { label: "synth:#{owner}##{ivar}", owner: owner, name: ivar, entry: entry, impl: impl,
        arity: 0, arg_c_types: [], aspec: 'MRB_ARGS_NONE()', code: code, visibility: :public }
    when :writer
      impl = "#{base}_eq_impl"
      # The reader's entry wrapper is already `#{base}`, so a writer that
      # reused it emitted the SAME function twice -- a hard C++ redefinition
      # for every embedded ivar with both attr_reader and attr_writer. The
      # `_eq` suffix is the convention emit_hot_only_registration_stubs and
      # bc2cpp_hot_profile.rb already compute for a writer (base_eq/base_eq_impl).
      entry = "#{base}_eq"
      # NILABLE_EMBED_SUPPORT: a tagged field stores through its setter helper;
      # the check below still runs first, so a refused value leaves the field
      # unchanged and the assigned value (not the field) is returned.
      store =
        if NULLABLE_TYPES.include?(type)
          "  bc2cpp_fixnum_or_nil_set(&((#{sname}*)DATA_PTR(self))->#{ivar_field_name(ivar)}, arg);\n"
        elsif type == :value
          "  ((#{sname}*)DATA_PTR(self))->#{ivar_field_name(ivar)} = arg;\n" \
            "  mrb_field_write_barrier_value(M, (struct RBasic*)mrb_obj_ptr(self), arg);\n"
        else
          "  ((#{sname}*)DATA_PTR(self))->#{ivar_field_name(ivar)} = #{ops[:unbox]}(arg);\n"
        end
      guard = if type == :value
                ''
              else
                "if (!#{ops[:check]}(arg)) mrb_raise(M, mrb_exc_get_id(M, mrb_intern_lit(M, \"TypeError\")), " \
                  "\"@#{ivar}: expected #{ops[:err]}\");"
              end
      code = <<~CPP
        // #{owner}##{ivar}= -- synthesized attr_writer override (@#{ivar} is
        // embedded; this replaces the plain native accessor -- see
        // drop_unsafe_embeddings' own ATTR_STRUCT_DEVIRT comment). Same
        // guarded check-then-store as SETIV's own embedded-ivar codegen
        // (compile_insn's own SETIV case) -- the whole-program analysis
        // proved every *compiled* write site is this type, but an
        // external caller (this accessor's own whole reason to exist) is
        // exactly the case that analysis can't see, so this checks rather
        // than blindly trusting it. Returns the assigned value, never the
        // struct field read back -- real attr_writer's own behavior
        // (3rd/mruby/src/class.c: `mrb_iv_set(...); return val;`, see
        // MethodDef's own kind: :ivar_accessor comment for the citation).
        mrb_value #{impl}(mrb_state* M, mrb_value self, mrb_value arg) {
          #{guard}
        #{store.chomp}
          #{guard}
          return arg;
        }

        static mrb_value #{entry}(mrb_state* M, mrb_value self) {
          mrb_value arg;
          mrb_get_args(M, "o", &arg);
          return #{impl}(M, self, arg);
        }

      CPP

      { label: "synth:#{owner}##{ivar}=", owner: owner, name: "#{ivar}=", entry: entry, impl: impl,
        arity: 1, arg_c_types: ['mrb_value'], aspec: 'MRB_ARGS_REQ(1)', code: code, visibility: :public }
    end
  end

  # Every synthesized accessor, built after compile_all. A nil from
  # emit_ivar_accessor_pair should be impossible (the same pass fills both
  # tables) but is checked. `only_owners` mirrors compile_all's filter: no
  # accessor for a class this run does not emit.
  def emit_synthesized_accessors(only_owners: nil)
    pairs = @synthesize_accessor_for.to_a
    pairs = pairs.select { |owner, _, _| only_owners.include?(owner) } if only_owners
    pairs.sort.filter_map { |owner, ivar, which| emit_ivar_accessor_pair(owner, ivar, which) }
  end

  RDATA_IVAR_HASH_EMPTY = 0xFFFF

  # enum mrb_data_ivar_kind (patches/mruby-rdata-ivar-slots.patch) per TYPE_OPS key.
  RDATA_IVAR_KIND = {
    value: 'MRB_DATA_IVAR_VALUE', fixnum: 'MRB_DATA_IVAR_INT', symbol: 'MRB_DATA_IVAR_SYMBOL',
    bool: 'MRB_DATA_IVAR_BOOL', fixnum_nil: 'MRB_DATA_IVAR_INT_OR_NIL'
  }.freeze

  # RDATA_IVAR_HASH: open-addressing index (FNV-1a 32 of the "@name", linear
  # probing, half full) over a descriptor, so rdata_ivar_find in
  # patches/mruby-rdata-ivar-slots.patch stops scanning every slot per access.
  def rdata_ivar_hash(names)
    raise "too many RData ivar slots (#{names.size})" if names.size >= RDATA_IVAR_HASH_EMPTY

    size = 2
    size <<= 1 while size < names.size * 2
    table = Array.new(size, RDATA_IVAR_HASH_EMPTY)
    names.each_with_index do |name, index|
      hash = 2_166_136_261
      name.each_byte { |byte| hash = ((hash ^ byte) * 16_777_619) & 0xffff_ffff }
      pos = hash & (size - 1)
      pos = (pos + 1) & (size - 1) until table[pos] == RDATA_IVAR_HASH_EMPTY
      table[pos] = index
    end
    table
  end

  # One slot + mrb_data_type marker per statically named ivar. The marker lets
  # mruby's normal ivar APIs and GC find slots; dynamic names remain in RData's
  # ordinary iv_tbl.
  def emit_structs
    out = String.new
    out << emit_nullable_structs
    @ivar_layout.each do |owner, ivars|
      # As compile_all's only_owners filter: no struct for a class this run does not
      # emit (it would be dead code and an unused-static warning).
      next if @only_owners && !@only_owners.include?(owner)

      out << "struct #{struct_name(owner)} {\n"
      ivars.each { |name, type| out << "  #{C_TYPE.fetch(type)} #{ivar_field_name(name)};\n" }
      out << "};\n"
      # NON_POD_MEMBER_SUPPORT: placement-destroy before mrb_free. The struct is
      # allocated with mrb_calloc and released by mrb_free, which is a bare
      # `mrb_basic_alloc_func(p, 0)` -- a plain free() that runs NO member
      # destructor. Every C_TYPE entry today is POD (mrb_int / mrb_sym / mrb_bool
      # and the tagged Bc2cppFixnumOrNil), so nothing leaks and the explicit
      # destructor call below compiles to the same code; it is emitted anyway so
      # that adding a non-POD field type later cannot leak silently. `delete p`
      # would be wrong: the memory comes from mruby's arena/page allocator, not
      # operator new.
      #
      # NON_POD_MEMBER_SUPPORT (the null guard): mruby tests `d->type &&
      # d->type->dfree` but never `d->data` (3rd/mruby/src/gc.c), so this runs
      # with p == NULL for any object whose #initialize raised before its
      # mrb_data_init -- a bare mrb_free(NULL) was harmless, but
      # `static_cast<T*>(nullptr)->~T()` is UB as soon as the destructor is
      # non-trivial, which is the whole point of calling it here. Verified
      # against real libmruby_core.a: 1000 bare MRB_TT_DATA shells produced
      # 1000 dfree calls with p == NULL, every one of them at mrb_close (gc_sweep
      # skips them because the sweep's liveness test never sees them; free_heap
      # frees every non-MRB_TT_FREE slot unconditionally). Same `if (!p) return;`
      # the hand-written DataType<T>::free_obj already uses (mruby-rgss/src/lib.cxx).
      out << "static void #{sanitize(owner)}_ivars_free(mrb_state* mrb, void* p) {\n"
      out << "  if (!p) return;\n"
      out << "  static_cast<#{struct_name(owner)}*>(p)->~#{struct_name(owner)}();\n"
      out << "  mrb_free(mrb, p);\n"
      out << "}\n"
      out << "static const mrb_data_ivar #{sanitize(owner)}_ivar_slots[] = {\n"
      # Typed fields are listed with their kind: the runtime boxes a raw C value on
      # read and type-checks a store, so instance_variable_get/set,
      # instance_variables, inspect, Marshal and dup see them (ADR 0261). The GC
      # marks VALUE slots only.
      slots = ivars.keys
      slots.each do |name|
        out << "  { \"@#{name}\", offsetof(#{struct_name(owner)}, #{ivar_field_name(name)}), " \
               "#{RDATA_IVAR_KIND.fetch(ivars.fetch(name))} },\n"
      end
      out << "  { \"\", 0 }, // placeholder: a zero-length array is not standard C++\n" if slots.empty?
      out << "};\n"
      hash_fields = 'nullptr, 0'
      unless slots.empty?
        table = rdata_ivar_hash(slots.map { |name| "@#{name}" })
        out << "static const uint16_t #{sanitize(owner)}_ivar_hash[] = { #{table.join(', ')} };\n"
        hash_fields = "#{sanitize(owner)}_ivar_hash, #{table.size - 1}"
      end
      out << "static const mrb_data_type #{type_var(owner)} = " \
             "{ \"#{struct_name(owner)}\", #{sanitize(owner)}_ivars_free, " \
             "#{sanitize(owner)}_ivar_slots, #{slots.size}, sizeof(#{struct_name(owner)}), " \
             "#{hash_fields} };\n\n"
    end
    out
  end

  # NILABLE_EMBED_SUPPORT: the tagged Integer-or-nil payload and its three
  # helpers, emitted ahead of every owner struct and only when a field uses
  # them. `present` is first and mrb_calloc zeroes the whole struct, so a fresh
  # instance reads nil before its first SETIV -- the same observable state as
  # an absent ivar. Both arms are immediates, so nothing here is a GC root and
  # no mrb_gc_mark/write barrier is involved.
  #
  # `mrb_fixnum_p`, not `mrb_integer_p`: a heap-backed Bignum is an MRB_TT_INTEGER
  # on a non-word-boxed target, and storing one in an mrb_int would truncate it
  # silently. The check refuses it and the caller's TypeError does the rest.
  def emit_nullable_structs
    return '' unless @ivar_layout.any? { |_, ivars| ivars.any? { |_, t| NULLABLE_TYPES.include?(t) } }

    <<~CPP
      // NILABLE_EMBED_SUPPORT: a tagged Integer-or-nil ivar field. Immediate-only
      // by construction, so it needs no GC rooting; see IvarLayout::FIXNUM_NIL.
      struct Bc2cppFixnumOrNil { mrb_bool present; mrb_int value; };
      // The runtime reads this slot as struct mrb_data_int_or_nil.
      static_assert(sizeof(Bc2cppFixnumOrNil) == sizeof(mrb_data_int_or_nil) &&
                    offsetof(Bc2cppFixnumOrNil, present) == offsetof(mrb_data_int_or_nil, present) &&
                    offsetof(Bc2cppFixnumOrNil, value) == offsetof(mrb_data_int_or_nil, value),
                    "Bc2cppFixnumOrNil must match struct mrb_data_int_or_nil");
      static inline mrb_bool bc2cpp_fixnum_or_nil_p(mrb_value v) {
        return mrb_nil_p(v) || mrb_fixnum_p(v);
      }
      static inline mrb_value bc2cpp_fixnum_or_nil_box(const Bc2cppFixnumOrNil& f) {
        return f.present ? mrb_fixnum_value(f.value) : mrb_nil_value();
      }
      // Store only after bc2cpp_fixnum_or_nil_p, so a rejected value leaves the
      // field exactly as it was (the caller's check raises before this runs).
      static inline void bc2cpp_fixnum_or_nil_set(Bc2cppFixnumOrNil* f, mrb_value v) {
        if (mrb_nil_p(v)) { f->present = FALSE; f->value = 0; }
        else { f->present = TRUE; f->value = mrb_fixnum(v); }
      }

    CPP
  end

  # ARY_ENTRY_INLINE: a same-TU copy of mrb_ary_entry (src/array.c):
  #
  #   struct RArray *a = mrb_ary_ptr(ary);
  #   mrb_int len = ARY_LEN(a);
  #   if (n < 0) n += len;
  #   if (n < 0 || len <= n) return mrb_nil_value();
  #   return ARY_PTR(a)[n];
  #
  # Every emitted "mrb_ary_ref(M, ...)" becomes "bc2cpp_ary_entry(M, ...)"; the
  # real macro is `#define mrb_ary_ref(mrb, ary, n) mrb_ary_entry(ary, n)`
  # (mruby/array.h), so behavior is identical. It exists because mrb_ary_entry
  # lives in libmruby.a and the build has no LTO (docs/adr/0133, 0135), so the
  # call could never be inlined. An unboxed element representation is not an
  # option: the GC marks elements through a real RArray (src/gc.c).
  # Emitted only when some compiled code calls it (checked on the output).
  def emit_ary_entry_helper(compiled)
    # OUTLINED_INDEX_OPS' GETIDX/GETIDX0 helpers call it too.
    return '' unless compiled.any? { |m| m[:code].include?('bc2cpp_ary_entry(') } ||
                     emit_index_helpers(compiled).include?('bc2cpp_ary_entry(')

    <<~CPP
      static inline mrb_value bc2cpp_ary_entry(mrb_state*, mrb_value ary, mrb_int n) {
        struct RArray* a = mrb_ary_ptr(ary);
        mrb_int len = ARY_LEN(a);
        if (n < 0) n += len;
        if (n < 0 || len <= n) return mrb_nil_value();
        return ARY_PTR(a)[n];
      }

    CPP
  end

  # bc2cpp_integer_recv_p / bc2cpp_integer_operand_p (FIXNUM_ARITHMETIC), emitted
  # only when the output uses them. A receiver is an Integer when it is a Fixnum
  # or, where mruby is built with bigints, a heap bigint; the operand may also be
  # a Float. Those are exactly the operand types Integer#+/-/* (src/numeric.c
  # int_add/int_sub/int_mul, mrb_num_add/sub/mul) handle without coercion, so the
  # direct helper call can neither raise a TypeError nor differ from the send.
  def emit_integer_operand_helpers(compiled)
    return '' unless compiled.any? { |m| m[:code].include?('bc2cpp_integer_recv_p(') }

    # mrb_bigint_p / mrb_float_p are FALSE when mruby is built without them.
    <<~CPP
      static inline mrb_bool bc2cpp_integer_recv_p(mrb_value v) { return mrb_integer_p(v) || mrb_bigint_p(v); }
      static inline mrb_bool bc2cpp_integer_operand_p(mrb_value v) { return bc2cpp_integer_recv_p(v) || mrb_float_p(v); }

    CPP
  end

  # NATIVE_CORE_DIRECT (ADR 0257) mirrors of core natives whose bodies are
  # static, emitted only for the ones the output calls. NativeCoreDirect::ENTRIES
  # pins each to the audited core body.
  def emit_native_core_helpers(compiled)
    NativeCoreDirect::HELPERS.filter_map do |name, text|
      "#{text}\n" if compiled.any? { |m| m[:code].include?("#{name}(") }
    end.join
  end

  # bc2cpp_bool_p (TYPE_OPS :bool check), emitted only when the output uses it.
  # There is no single macro for both boolean tags, so it ORs
  # mrb_true_p/mrb_false_p (mruby/value.h).
  def emit_bool_check_helper(compiled)
    return '' unless compiled.any? { |m| m[:code].include?('bc2cpp_bool_p(') }

    <<~CPP
      static inline mrb_bool bc2cpp_bool_p(mrb_value v) { return mrb_true_p(v) || mrb_false_p(v); }

    CPP
  end

  # GETCONST's owner-scope-first helper (see compile_insn). mrb_const_get raises
  # via longjmp, so it cannot be tried then polled; mrb_protect_error
  # (mruby/error.h) takes a C function pointer and a void* payload, hence
  # LookupCtx/lookup_body as a static function. Emitted once, only when used.
  def emit_const_lookup_helper
    return '' unless const_lookup_helper_used?

    <<~CPP
      // Shared by every GETCONST site whose owner isn't Object -- tries one
      // scope in the owner's own real lexical nesting chain and reports
      // success via *ok rather than choosing a fallback itself, so the call
      // site (compile_insn's own GETCONST case) can walk the whole chain,
      // innermost scope first, the way real Ruby constant lookup does. See
      // that comment for why this has to be mrb_protect_error-based rather
      // than a simpler try/poll (a raw mrb_const_get failure longjmps
      // straight past any code that would poll mrb->exc afterward).
      struct Bc2cppConstLookupCtx { mrb_value scope; mrb_sym name; };
      static mrb_value bc2cpp_const_lookup_body(mrb_state* M, void* ud) {
        Bc2cppConstLookupCtx* ctx = (Bc2cppConstLookupCtx*)ud;
        return mrb_const_get(M, ctx->scope, ctx->name);
      }
      static mrb_value bc2cpp_const_try(mrb_state* M, mrb_value scope, mrb_sym name, mrb_bool* ok) {
        // A miss is the common case (most scopes in the chain do not define the
        // name), and mrb_const_get reports one by raising NameError, which
        // allocates an exception, its message and a backtrace before
        // mrb_protect_error swallows it -- measured at ~70k allocations/s in the
        // RPG2k map scene. Answer the miss without raising: walk the same
        // ancestor chain const_get_nohook does (3rd/mruby/src/variable.c: the
        // scope and its superclasses/included modules, skipping a prepended
        // origin, stopping before Object) using the public defined_at test, and
        // only call mrb_const_get once the name is known to be there. It also
        // stops running a user const_missing on an intermediate scope, which
        // Ruby's lexical lookup never does.
        if (mrb_type(scope) == MRB_TT_CLASS || mrb_type(scope) == MRB_TT_MODULE || mrb_type(scope) == MRB_TT_SCLASS) {
          for (struct RClass* c = mrb_class_ptr(scope); c;) {
            if (!MRB_FLAG_TEST(c, MRB_FL_CLASS_IS_PREPENDED) && mrb_const_defined_at(M, mrb_obj_value(c), name)) {
              *ok = TRUE;
              return mrb_const_get(M, scope, name);
            }
            c = c->super;
            if (c == M->object_class) break;
          }
          *ok = FALSE;
          return mrb_nil_value();
        }
        Bc2cppConstLookupCtx ctx{scope, name};
        mrb_bool err = FALSE;
        mrb_value result = mrb_protect_error(M, bc2cpp_const_lookup_body, &ctx, &err);
        *ok = !err;
        return result;
      }

    CPP
  end

  # Declarations for the NATIVE_CONSTRUCT_TARGETS entry points actually used,
  # via include/rgss_construct.hxx (namespace `rgss`). Do not re-spell the
  # signatures here: the header is the single source of truth, and parameter
  # types must match exactly (`RClass*` klass, native arg_type parameters). The
  # three *-compiled mrbgem.rake files add repo include/ to cxx.include_paths.
  def emit_native_construct_decls
    return '' unless @native_construct_used.any?

    out = String.new
    out << "// mruby-rgss/src/lib.cxx's own devirtualized-construction entry\n"
    out << "// points (see that file's own DataType<T> comment) -- called\n"
    out << "// directly in place of Class#new's own allocate+initialize\n"
    out << "// dispatch when a `.new` call site's receiver is provably one of\n"
    out << "// these native DataType<T>-backed classes (compile_send's own\n"
    out << "// \"MONO :new -> direct native construct\" path). Declared in\n"
    out << "// include/rgss_construct.hxx, defined in namespace `rgss` at\n"
    out << "// file scope in lib.cxx -- plain C++ linkage both sides, no\n"
    out << "// `extern \"C\"` anywhere.\n"
    out << "#include \"rgss_construct.hxx\"\n"
    out << "\n"
    out
  end

  # Class-identity accessor name for a DIRECT_CONSTRUCT_TARGETS owner
  # ("Game::Transition" -> "Game__Transition_compiled_class"), derived with
  # `sanitize`; the owning gem's register.cxx defines it with this spelling.
  def direct_construct_class_fn(owner)
    "#{sanitize(owner)}_compiled_class"
  end

  # Declarations for direct compiled construction actually used:
  # 1. bc2cpp_direct_alloc: mirrors mrb_instance_alloc's checks and allocation.
  # 2. Accessors only for listed targets, defined in the same gem's register.cxx.
  #    Other local classes use the owner-class cache instead.
  def emit_direct_construct_decls
    return '' unless @direct_alloc_used || @direct_construct_used.any?

    out = String.new
    out << "// A generic replacement for Class#new's own `self.allocate` step,\n"
    out << "// correct for ANY class C regardless of its own MRB_INSTANCE_TT --\n"
    out << "// including one with an embedded MRB_TT_DATA ivar struct, since\n"
    out << "// MRB_INSTANCE_TT(c) reads the class's OWN stored instance type\n"
    out << "// (set once, at gem-init time, by MRB_SET_INSTANCE_TT), never\n"
    out << "// guesses it from the class's shape. This is exactly what\n"
    out << "// mrb_instance_alloc (3rd/mruby/src/class.c, Class#allocate's own\n"
    out << "// real implementation) does internally -- confirmed by reading that\n"
    out << "// function directly -- just reimplemented here since it is `static`\n"
    out << "// (no external linkage, so this generated file -- a different\n"
    out << "// translation unit -- cannot call it directly) using only the two\n"
    out << "// PUBLIC mruby APIs for allocating with MRB_INSTANCE_TT(c) and\n"
    out << "// mrb_obj_alloc (mruby.h), preserving mrb_instance_alloc's tag and\n"
    out << "// allocator checks. Called directly in\n"
    out << "// place of Class#new's own real allocate+initialize dispatch chain\n"
    out << "// when a `.new` call site's receiver is a compiled class with a\n"
    out << "// proven standard constructor chain (compile_send's direct\n"
    out << "// compiled-construction path).\n"
    out << "// -- #initialize's own already-compiled _impl function is called\n"
    out << "// right after, for its side effects only (its own return value is\n"
    out << "// discarded, never assigned to the result register: real Ruby\n"
    out << "// Class#new always returns the newly allocated object, never\n"
    out << "// whatever #initialize itself returns).\n"
    out << "static inline mrb_value bc2cpp_direct_alloc(mrb_state* M, RClass* c) {\n"
    out << "  enum mrb_vtype ttype = MRB_INSTANCE_TT(c);\n"
    out << "  if (c->tt == MRB_TT_SCLASS) mrb_raise(M, mrb_exc_get_id(M, mrb_intern_lit(M, \"TypeError\")), " \
           "\"can't create instance of singleton class\");\n"
    out << "  if (c == M->nil_class || c == M->false_class) {\n"
    out << "    mrb_assert(ttype == 0);\n"
    out << "  } else if (ttype == 0) {\n"
    out << "    ttype = MRB_TT_OBJECT;\n"
    out << "  }\n"
    type_error = 'mrb_exc_get_id(M, mrb_intern_lit(M, "TypeError"))'
    out << "  if (MRB_UNDEF_ALLOCATOR_P(c)) mrb_raisef(M, #{type_error}, \"allocator undefined for %v\", mrb_obj_value(c));\n"
    out << "  if (ttype <= MRB_TT_CPTR) mrb_raisef(M, #{type_error}, \"can't create instance of %v\", mrb_obj_value(c));\n"
    out << "  return mrb_obj_value(mrb_obj_alloc(M, ttype, c));\n"
    out << "}\n\n"
    out << "// Class-identity accessors for explicitly listed target classes\n"
    out << "// owners define in their compiled gem's own register.cxx (mirroring\n"
    out << "// NATIVE_CONSTRUCT_TARGETS' own class_fn precedent) -- a real,\n"
    out << "// durable RClass* captured once at that gem's own gem-init time, NOT\n"
    out << "// a second mrb_const_get/mrb_class_get_under lookup (see\n"
    out << "// compile_send's own comment on why: that would just observe\n"
    out << "// whatever the constant currently names, exactly what a\n"
    out << "// reassignment would already have changed, so it could never\n"
    out << "// actually detect one happened).\n"
    @direct_construct_used.sort.each do |owner|
      out << "RClass* #{direct_construct_class_fn(owner)}(void);\n"
    end
    out << "\n"
    out
  end

  # `only_owners` limits which classes are emitted, but the registry and
  # ivar_layout must come from the WHOLE closed world: analyzed alone,
  # mruby-lcf has one :rpg2003? definition, while the game has four.
  # `other_owners`: classes compiled in another TU of the same link; their
  # `_impl`s are declared via emit_decls_header and resolved at link time.
  # A ".singleton" pseudo-owner needs no special handling here: it is selected
  # exactly when an `owners:` list names it, and SDEF defs now carry an irep so
  # they are in @owner_of (see build_registry). compile_send's
  # `@only_owners.include?` guard works the same way.
  def compile_all(only_owners: nil, other_owners: nil)
    @only_owners = only_owners
    @other_owners = other_owners
    # SYM_DEVIRT: sym_call_target probes callees with compiles_clean?, whose
    # compile_method reads @only_owners/@other_owners, so both are set before any
    # compile_method runs. compile_method never assigns them.
    leaves = @owner_of.keys
    if only_owners
      leaves.select! { |l| only_owners.include?(@owner_of.fetch(l).owner) && emit_unit_allows?(l) }
      # A module_function copy has its own singleton lookup entry but shares its
      # source body's irep. Emit that body from the module's gem when the copy's
      # singleton owner is selected; the source module method itself stays bytecode.
      copied = @registry.values.flatten.filter_map do |d|
        d.copy_irep if d.kind == :module_function && d.copy_irep && only_owners.include?(d.owner)
      end
      leaves |= copied
    end
    # HOT_ONLY: excluded methods get no `_impl`, entry or declaration (ADR 0214).
    leaves = leaves.reject { |l| hot_only_excluded?(l) }
    leaves.map { |label| compile_method(label) }
  end

  # EMIT_UNIT (ADR 0264): Array and StringIO have definitions in both mruby's own
  # Ruby and an engine gem (mruby-rgss's Array#include?, mruby-lcf's
  # StringIO#ungetbyte), and each compiled gem is one translation unit that must
  # emit a symbol exactly once. The unit is read from the source file and the
  # owner list: the core gem is the run whose owners are all core owners
  # (BC2CPP_CORE_OWNERS) and emits the core-source definitions; a run with any
  # other owner is an engine gem (or the aggregate of all gems) and emits the
  # rest. A run whose owners cover the core set and more emits both, which is
  # what a single-process analysis of every gem wants. Every run agrees on
  # which bodies compile (same registry), only on which TU emits them.
  def emit_unit_allows?(label)
    return true unless @only_owners

    covers_core = BC2CPP_CORE_OWNERS.all? { |owner| @only_owners.include?(owner) }
    core_only = @only_owners.all? { |owner| BC2CPP_CORE_OWNERS.include?(owner) }
    if CoreDefs.core_source?(@ireps.fetch(label).file)
      covers_core
    else
      !core_only
    end
  end

  # HOT_ONLY (ADR 0214): did BC2CPP_HOT_METHODS leave irep `label` out?
  def hot_only_excluded?(label)
    excluded = self.class.hot_only_excluded
    excluded ? excluded.include?(label) : false
  end

  def hot_only_active?
    excluded = self.class.hot_only_excluded
    excluded ? !excluded.empty? : false
  end

  # HOT_ONLY: register.cxx still names uncompiled entries. Each becomes a constant
  # of an empty type whose registration overloads are no-ops, so the bytecode
  # `def` stays the method; exact-type overloading keeps real entries unaffected
  # (ADR 0214). Empty when nothing is excluded.
  def emit_hot_only_registration_stubs(compiled, only_owners: nil)
    return '' unless hot_only_active?

    real = compiled.to_set { |m| m[:entry] }
    # Every uncompiled method, not only excluded ones: a listed method whose
    # keyword/`super` target is excluded comes out `#error` too.
    entries = @owner_of.each_with_object(Set.new) do |(_label, d), out|
      next if only_owners && !only_owners.include?(d.owner)

      entry = cpp_name(d.owner, d.name)
      out << entry unless real.include?(entry)
    end
    # Synthesized accessors exist only while their ivar embeds; when an exclusion
    # drops the embedding, the native attr_* (reading iv_tbl) must stay.
    @registry.each_value do |defs|
      defs.each do |d|
        next unless d.kind == :ivar_accessor && d.irep.nil? && !d.owner.end_with?('.singleton')
        next if only_owners && !only_owners.include?(d.owner)

        base = "#{sanitize(d.owner)}_#{sanitize(d.name.chomp('='))}"
        entry = d.name.end_with?('=') ? "#{base}_eq" : base
        entries << entry unless real.include?(entry)
      end
    end
    out = +"// HOT_ONLY (docs/adr/0214): #{entries.size} entry points of this gem are not compiled and stay bytecode.\n"
    # BC2CPP_HOT_ONLY_STUBS: the self-describing mode signal. A hand-written
    # register.cxx #includes this generated file, so it can test this macro to
    # tell the two builds apart without a second build flag -- the two cannot
    # drift, because this is emitted only on the hot-only path, and the no-op
    # mrb_define_* overloads immediately below exist only here.
    out << "#define BC2CPP_HOT_ONLY_STUBS 1\n"
    out << "struct bc2cpp_hot_only_excluded {};\n"
    %w[mrb_define_method mrb_define_private_method mrb_define_class_method].each do |fn|
      out << "static inline void #{fn}(mrb_state*, struct RClass*, const char*, bc2cpp_hot_only_excluded, " \
             "mrb_aspec) {}\n"
    end
    entries.sort.each { |e| out << "[[maybe_unused]] static constexpr bc2cpp_hot_only_excluded #{e}{};\n" }
    out << "\n"
    out
  end

  # Forward declarations first: a direct call can target a method defined later
  # in the file.
  def emit_forward_decls(compiled)
    out = String.new
    compiled.each do |m|
      out << "#{decl_line(m)};\n"
      # The entry wrapper stays static: only this gem's registration calls it.
      out << "static mrb_value #{m[:entry]}(mrb_state*, mrb_value);\n"
    end
    out << "\n"
    out
  end

  # The same declarations as a `#pragma once` header, for other gems' generated
  # code (OTHER_DECLS_HEADER in mrbgem.rake) so the linker resolves cross-gem
  # direct calls. `_impl`/entry are not `static` for this reason.
  def emit_decls_header(compiled)
    out = String.new
    out << "#pragma once\n"
    out << "#include <mruby.h>\n\n"
    compiled.each { |m| out << "#{decl_line(m)};\n" }
    out << "\n"
    out
  end

  # `m[:arg_c_types]`: each mandatory position's C++ type (mrb_value, or
  # mrb_int/mrb_sym for NATIVE_ARG_TARGETS). `self` is never retyped. Absent (an
  # `#error` stub) means all mrb_value.
  def decl_line(m)
    arg_c_types = m[:arg_c_types] || Array.new(m[:arity], 'mrb_value')
    impl_params = (['mrb_state*', 'mrb_value'] + arg_c_types).join(', ')
    "mrb_value #{m[:impl]}(#{impl_params})"
  end
end
