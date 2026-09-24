# frozen_string_literal: true

# CodeGen: compile_send and const/owner caches.

class CodeGen
  def compile_send(args, self_implicit:, irep: nil, idx: nil, owner_def: nil,
                   call_receiver: nil, call_arguments: nil, trace_idx: nil, trace_receiver_reg: nil,
                   trace_reg_offset: 0, typed_fallback: nil)
    # ELEMENT_CLASS_SUPPORT: consume the element hint before anything else
    # (including compiles_clean? probes that re-enter compile_method), so no other
    # call site can read it.
    elem_class_hint = @elem_class_hint
    @elem_class_hint = nil
    d = args[/^R(\d+)/, 1]
    # The method-name charset must include `?`, `!` and every operator character
    # (`&`, `|`, `^`, `~`, `%`, `@` for `-@`/`+@`). A missing character truncates
    # the name (`key?` -> "key") or yields "" (`flags & x` -> `mrb_funcall(M, r6,
    # "", ...)`): the C++ compiles and links, then raises NoMethodError at runtime,
    # which no `#error` check catches. Keep every copy of this charset in sync.
    name = args[/:([\w+\-*\/<>=!?\[\]&|^~%@]+)/, 1]
    # Parse `n=` including the other print_args shapes (src/codedump.c):
    #   - "n=3|nk=1": keyword pairs, which OP_SEND packs into a Hash at runtime;
    #   - "n=*": a splat (CALL_MAXARGS) with no fixed register list.
    # A bare `/n=(\d+)/` misparsed both (nil.to_i == 0), silently dropping splatted
    # arguments or keyword hashes (e.g. `charged:`, `keep:`, `preserve_mod: false`)
    # while compiling cleanly. Such sites now go to the keyword/splat paths or get
    # `#error` (SKIP_UNSUPPORTED keeps them interpreted). SEND0/SSEND0 print no
    # `n=` (vm.c OP_SEND0 has c=0), so nil still means n=0.
    n_match = args.match(/n=(\d+|\*)(?:\|nk=(\d+|\*))?/)
    if n_match && (n_match[1] == '*' || n_match[2])
      # Keyword call site (nk > 0, no splat): try compile_keyword_send before
      # `#error`.
      if n_match[1] != '*' && n_match[2] != '*' && irep && !idx.nil?
        kw_result = compile_keyword_send(args, self_implicit: self_implicit, irep: irep, idx: idx,
                                         owner_def: owner_def, name: name, d: d,
                                         n: n_match[1].to_i, nk: n_match[2].to_i)
        return kw_result if kw_result
      end
      # SPLAT_UNROLL_SUPPORT: try compile_splat_send (literal Array/Hash) before
      # `#error`; a splatted variable or expression still errors.
      if irep && !idx.nil?
        splat_result = compile_splat_send(args, self_implicit: self_implicit, irep: irep, idx: idx,
                                          name: name, d: d, owner_def: owner_def)
        return splat_result if splat_result
      end
      return "  #error SEND/SSEND :#{name} has a splat and/or keyword argument list (#{n_match[0]}) -- not in this prototype's supported subset\n"
    end

    n = n_match ? n_match[1].to_i : 0
    recv = call_receiver || (self_implicit ? 'self' : "r#{d}")
    argv = call_arguments || (1..n).map { |k| "r#{d.to_i + k}" }

    # LITERAL_EQQ_SUPPORT: `LITERAL === x` from `case x; when LITERAL` (receiver a
    # literal Fixnum or Symbol, see trace_eqq_literal_receiver) is compiled to
    # mruby's native semantics (mrb_eqq_m -> mrb_equal) directly. Soundness:
    # eqq_literal_devirt_safe? (both `:==` and `:===` MONO native, re-checked every
    # run). Runs before monomorphic_target, which refuses native-only names anyway,
    # so only `:===` sites that would otherwise mrb_funcall change. `n == 1`:
    # both natives are MRB_ARGS_REQ(1).
    if name == '===' && n == 1 && irep && idx && eqq_literal_devirt_safe?
      literal = trace_eqq_literal_receiver(irep, idx, d)
      if literal
        arg = argv.first
        case literal[:type]
        when :symbol
          # No fallback needed: Symbol#== is still mrb_obj_equal_m (the same `:==` check),
          # so mrb_equal's mrb_func_basic_p guard holds and it never dispatches; the
          # answer is `mrb_symbol(v1) == mrb_symbol(v2)` with an exact type match, and
          # Symbols have no cross-type equality.
          note = "  // LITERAL === :symbol -- `:#{literal[:name]} === arg` (case/when literal), " \
                 "Object#===/Symbol#== both confirmed native/unoverridden anywhere in this program's " \
                 "own whole-program registry -- sound unconditionally, no mrb_funcall fallback ever " \
                 "needed (see eqq_literal_devirt_safe?'s own comment).\n"
          return "#{note}  r#{d} = mrb_bool_value(mrb_symbol_p(#{arg}) && " \
                 "mrb_symbol(#{arg}) == mrb_intern_cstr(M, \"#{literal[:name]}\"));\n"
        when :fixnum
          # Only an exactly-Integer `arg`: mrb_equal (object.c) does Integer<->Float
          # comparison, and with mruby-bigint (always in build_config.rb's
          # rpg_maker_gems) Integer<->Bigint too (also in int_equal, src/numeric.c), so
          # `5 === 5.0` is true. Only MRB_TT_INTEGER vs MRB_TT_INTEGER is compared
          # directly (exact, given `:==` is MONO native); every other type uses
          # mrb_funcall, like compile_cmp's EQ.
          note = "  // LITERAL === :fixnum -- `#{literal[:value]} === arg` (case/when literal), " \
                 "Object#===/Integer#== both confirmed native/unoverridden anywhere in this program's " \
                 "own whole-program registry -- only the exact-Integer-type shape is handled directly; " \
                 "a Float/Bigint/other-typed arg falls back to real mrb_funcall (mrb_equal's own " \
                 "Integer<->Float/Bigint cross-type comparison, see this block's own top comment).\n"
          return "#{note}  if (mrb_fixnum_p(#{arg})) {\n" \
                 "    r#{d} = mrb_bool_value(mrb_fixnum(#{arg}) == #{literal[:value]});\n" \
                 "  } else {\n" \
                 "    #{dynamic_dispatch_line(d, recv, name, argv)}" \
                 "  }\n"
        end
      end
    end

    # Devirtualize `SEND :new` whose receiver traces (GETCONST, at this call site)
    # to a NATIVE_CONSTRUCT_TARGETS class. Never for self_implicit sends; irep/idx
    # are nil exactly then, but are checked because trace_new_target needs them.
    if name == 'new' && !self_implicit && irep && idx
      known = trace_new_target(irep, idx, d, nil, 0, nil, resolving_new: true, owner: owner_def&.owner,
                               canonical: false)
      native = known && NATIVE_CONSTRUCT_TARGETS[known]
      # Exact arity only (an Array lists several accepted counts); other counts fall
      # through to dynamic dispatch.
      if native && (native[:arity] == n || (native[:arity].is_a?(Array) && native[:arity].include?(n)))
        @native_construct_used << known
        # `fn` takes native mrb_int/mrb_float, so arguments are unboxed here with the
        # same mrb_as_int/mrb_as_float the function used internally (same TypeError).
        # `:object` (Sprite) passes through; a 0-argument Sprite.new passes an explicit
        # mrb_nil_value(), since the C++ signature always has the full parameter list
        # (include/rgss_construct.hxx) and "|o" leaves vp nil.
        # `type_guard` (Bitmap): check every argument's Integer tag and fall back to
        # mrb_funcall if any fails (a String first argument is the file-load form);
        # read with mrb_integer after the check.
        if native[:type_guard] == :int
          arg_checks = argv.map { |a| "mrb_integer_p(#{a})" }.join(' && ')
          unboxed_argv = argv.map { |a| "mrb_integer(#{a})" }
          guard = "mrb_class_ptr(#{recv}) == #{native[:class_fn]}() && #{arg_checks}"
          note_extra = " Argument tags checked first (#{arg_checks}), " \
                       "falling back to ordinary dispatch for any other shape -- " \
                       "see that entry's own `type_guard` comment."
        else
          unboxed_argv = case native[:arg_type]
                         when :int then argv.map { |a| "mrb_as_int(M, #{a})" }
                         when :float then argv.map { |a| "mrb_as_float(M, #{a})" }
                         else argv
                         end
          unboxed_argv = ['mrb_nil_value()'] if unboxed_argv.empty?
          guard = "mrb_class_ptr(#{recv}) == #{native[:class_fn]}()"
          note_extra = ''
        end
        # The note's "unboxes each argument" only applies to :int/:float.
        unbox_phrase = case native[:arg_type]
                       when :int then 'unboxes each argument register with the same mrb_as_int that function used to call internally'
                       when :float then 'unboxes each argument register with the same mrb_as_float that function used to call internally'
                       else 'passes each argument register straight through as mrb_value'
                       end
        note = "  // MONO :new -> #{known}, direct native construct (mruby-rgss/src/lib.cxx's own " \
               "#{native[:fn]}) -- skips Class#new's own allocate+initialize dispatch chain entirely.\n" \
               "  // Runtime-guarded: #{known} could have been reassigned at the constant level (e.g. " \
               "`RGSS::#{known} = SomeOtherClass`) since #{native[:class_fn]}'s own class was registered " \
               "-- #{recv} is whatever this method's own existing GETCONST resolution chain above just " \
               "produced, so a reassignment there is already reflected in it; falls back to ordinary " \
               "mrb_funcall (whatever #{recv} now actually is) rather than misconstruct if it doesn't " \
               "match the real native class.#{note_extra} #{native[:fn]}'s own parameters are native mrb_int/" \
               "mrb_float, not mrb_value (except :object, passed straight through), so this call site #{unbox_phrase}, " \
               "and passes mrb_class_ptr(#{recv}) " \
               "straight through (already computed for the guard just above -- no second, redundant " \
               "mrb_class_ptr call needed).\n"
        return "#{note}" \
               "  if (#{guard}) {\n" \
               "    r#{d} = #{native[:fn]}(M, mrb_class_ptr(#{recv}), #{unboxed_argv.join(', ')});\n" \
               "  } else {\n" \
               "    #{dynamic_dispatch_line(d, recv, name, argv)}" \
               "  }\n"
      end
    end

    # DIRECT_CONSTRUCT_TARGETS (see its comment): the compiled-class counterpart of
    # the block above. A separate `if`, so neither can shadow the other (the two
    # owner sets never overlap); re-running trace_new_target is cheap.
    if name == 'new' && !self_implicit && irep && idx
      known = trace_new_target(irep, idx, d, nil, 0, nil, resolving_new: true, owner: owner_def&.owner,
                               canonical: false)
      if known && DIRECT_CONSTRUCT_TARGETS.include?(known)
        init_def = @registry['initialize'].find { |md| md.owner == known }
        # DIRECT_CONSTRUCT_TARGETS' soundness bar, checked live against this run's
        # registry and ONLY_OWNERS.
        # 1/2: no custom `def self.new`/`def self.allocate` on this class ("X.singleton"
        # owner, see build_registry).
        no_custom_new = @registry['new'].none? { |md| md.owner == "#{known}.singleton" }
        no_custom_allocate = @registry['allocate'].none? { |md| md.owner == "#{known}.singleton" }
        # 3: #initialize is a compiling, pure-mandatory leaf whose arity matches this
        # call (the TYPED path's checks); an optional-argument #initialize must never
        # be skipped past this way.
        init_ok = init_def&.irep && pure_mandatory_arity?(@ireps.fetch(init_def.irep)) &&
                  compiles_clean?(init_def.irep) && n == mandatory_arity(@ireps.fetch(init_def.irep))
        if no_custom_new && no_custom_allocate && init_ok
          # 4: the ONLY_OWNERS/OTHER_OWNERS emission guard.
          owner_emitted = !@only_owners || @only_owners.include?(known) || @other_owners&.include?(known)
          if owner_emitted
            @direct_construct_used << known
            accessor = direct_construct_class_fn(known)
            init_impl = cpp_name(known, 'initialize') + '_impl'
            note = "  // MONO :new -> #{known}, direct compiled construct (bc2cpp_direct_alloc + " \
                   "#{init_impl}) -- skips Class#new's own allocate+initialize dispatch chain entirely; " \
                   "#{known}#initialize's own return value is discarded (real Ruby .new always returns " \
                   "the new object, never whatever #initialize itself returns).\n" \
                   "  // Runtime-guarded the same way NATIVE_CONSTRUCT_TARGETS' own native-construct path " \
                   "is (see that block's own comment): #{known} could have been reassigned at the constant " \
                   "level since #{accessor}'s own class was captured at gem-init, so #{recv} (this call " \
                   "site's own already-resolved GETCONST/GETMCNST receiver) is compared against it rather " \
                   "than trusted outright, falling back to ordinary mrb_funcall if they differ.\n"
            return "#{note}" \
                   "  if (mrb_class_ptr(#{recv}) == #{accessor}()) {\n" \
                   "    r#{d} = bc2cpp_direct_alloc(M, mrb_class_ptr(#{recv}));\n" \
                   "    #{init_impl}(M, #{([recv] + argv).join(', ')});\n" \
                   "  } else {\n" \
                   "    #{dynamic_dispatch_line(d, recv, name, argv)}" \
                   "  }\n"
          end
        end
      end
    end

    # NATIVE_PRIMITIVE_SENDS: inline native primitives at any call site, without
    # receiver-class knowledge. monomorphic_target refuses native-only names
    # (calling an arbitrary C method directly would leave mrb_get_args reading a
    # stale frame), but for these each native body is an expression that is safe
    # outside a dispatched frame, so native_only_mono? (no bytecode override
    # anywhere) is the whole soundness argument:
    #   - `!`: mrb_bob_not is `mrb_bool_value(!mrb_test(cv))` (class.c).
    #   - `nil?`: Object's is mrb_false, NilClass's mrb_true; together exactly
    #     mrb_nil_p(recv) for every receiver.
    #   - `is_a?`/`kind_of?`: mrb_obj_is_kind_of_m does `mrb_get_args(mrb, "c",
    #     &c)` (TypeError unless Class/Module) then mrb_obj_is_kind_of. Reproduced
    #     behind an `mrb_class_p(arg) || mrb_module_p(arg)` guard; otherwise
    #     mrb_funcall raises the real TypeError.
    #   - `equal?`: mrb_obj_equal_m is mrb_obj_equal(self, arg) (public).
    #   - `class`: mrb_obj_value(mrb_obj_class(mrb, self)).
    #   - `object_id`: mrb_fixnum_value(mrb_obj_id(self)) (boxing-generic).
    #   - `keys`: mrb_hash_keys casts unchecked, so it needs an mrb_hash_p guard
    #     (KEYS_TYPE_TAG_GUARD).
    #   - `to_s`, `length`, `first`: several native bodies behind one registry
    #     entry; per-type handling in *_TYPE_TAG_DISPATCH (Array/Hash to_s mutate
    #     ci->mid and are excluded; String length depends on MRB_UTF8_STRING;
    #     Array#first reads mrb_get_argc, so it is reproduced).
    #   - `dup`: exactly two native bodies, no fallback needed
    #     (DUP_TYPE_TAG_DISPATCH).
    # `respond_to?` has a positive-only fast path (a miss keeps dispatch so
    # respond_to_missing? runs; the two-argument form stays dynamic).
    if name == '[]' && n == 2 && builtin_class_send_safe?(name, %w[Array])
      start, length = argv
      fallback = dynamic_dispatch_line(d, recv, name, argv)
      return <<~CPP
          // ARRAY_SLICE_READ :[] -- exact Array and Fixnum slice only; preserve coercion and overrides
          if (mrb_array_p(#{recv}) && mrb_obj_ptr(#{recv})->c == M->array_class &&
              mrb_fixnum_p(#{start}) && mrb_fixnum_p(#{length}) &&
              !ARY_SHARED_P(mrb_ary_ptr(#{recv})) && mrb_fixnum(#{length}) >= 0 &&
              mrb_fixnum(#{length}) <= 10) {
            mrb_int bc2cpp_slice_start = mrb_fixnum(#{start});
            mrb_int bc2cpp_slice_length = mrb_fixnum(#{length});
            mrb_int bc2cpp_slice_array_length = RARRAY_LEN(#{recv});
            if (bc2cpp_slice_start < 0 && bc2cpp_slice_start >= -bc2cpp_slice_array_length) {
              bc2cpp_slice_start += bc2cpp_slice_array_length;
            }
            if (bc2cpp_slice_start < 0 || bc2cpp_slice_array_length < bc2cpp_slice_start ||
                bc2cpp_slice_length < 0) {
              r#{d} = mrb_nil_value();
            } else {
              if (bc2cpp_slice_length > bc2cpp_slice_array_length - bc2cpp_slice_start) {
                bc2cpp_slice_length = bc2cpp_slice_array_length - bc2cpp_slice_start;
              }
              if (bc2cpp_slice_length == 0) {
                r#{d} = mrb_ary_new(M);
              } else {
                r#{d} = mrb_ary_new_from_values(M, bc2cpp_slice_length,
                    RARRAY_PTR(#{recv}) + bc2cpp_slice_start);
              }
            }
          } else {
            #{fallback.chomp}
          }
      CPP
    end

    if name == '[]=' && n == 3 && builtin_class_send_safe?(name, %w[Array])
      # Array slice writes (optcarrot's mapper bank switches): mrb_ary_splice is the
      # public native body of this three-argument form. Only exact Arrays with
      # fixnum start/length; coercion, subclasses and non-Arrays keep dispatch.
      # Array#[]= returns the replacement, mrb_ary_splice the receiver.
      start, length, replacement = argv
      fallback = dynamic_dispatch_line(d, recv, name, argv)
      return <<~CPP
          // ARRAY_SLICE_WRITE :[]= -- exact Array and fixnum indices only; preserve coercion and overrides
          if (mrb_array_p(#{recv}) && mrb_obj_ptr(#{recv})->c == M->array_class &&
              mrb_fixnum_p(#{start}) && mrb_fixnum_p(#{length})) {
            mrb_ary_splice(M, #{recv}, mrb_fixnum(#{start}), mrb_fixnum(#{length}), #{replacement});
            r#{d} = #{replacement};
          } else {
            #{fallback.chomp}
          }
      CPP
    end

    if name == 'push' && n == 1 && builtin_class_send_safe?(name, %w[Array])
      value = argv.first
      fallback = dynamic_dispatch_line(d, recv, name, argv)
      return <<~CPP
          // ARRAY_PUSH :push -- exact base Array and one value; preserve overrides and other arities
          if (mrb_array_p(#{recv}) && mrb_obj_ptr(#{recv})->c == M->array_class) {
            mrb_ary_push(M, #{recv}, #{value});
            r#{d} = #{recv};
          } else {
            #{fallback.chomp}
          }
      CPP
    end

    if ['+', '-', '*'].include?(name) && n == 1 && builtin_class_send_safe?(name, %w[Integer Numeric])
      left, right = recv, argv.first
      fallback = dynamic_dispatch_line(d, recv, name, argv)
      helper = { '+' => 'mrb_num_add', '-' => 'mrb_num_sub', '*' => 'mrb_num_mul' }.fetch(name)
      return <<~CPP
          // FIXNUM_ARITHMETIC :#{name} -- exact Fixnums use mruby's overflow-aware numeric helper
          if (mrb_fixnum_p(#{left}) && mrb_fixnum_p(#{right})) {
            r#{d} = #{helper}(M, #{left}, #{right});
          } else {
            #{fallback.chomp}
          }
      CPP
    end

    # INTEGER_LSHIFT: `bits << n` on two Integers uses mrb_num_shift, the kernel
    # Integer#<< calls (src/numeric.c int_lshift), so zero shifts, negative counts
    # and the width limit match. MRB_INT_MIN counts and overflow (bigint or
    # RangeError) take ordinary dispatch, which also keeps bigints out of C on
    # 32-bit mrb_int builds. Placed next to the exact-Array push arm, so a site
    # that was ARRAY_PUSH-only stays so when Integer#<< is overridden in Ruby.
    if name == '<<' && n == 1 && builtin_class_send_safe?(name, %w[Integer])
      value = argv.first
      fallback = dynamic_dispatch_line(d, recv, name, argv).chomp
      array_arm = ''
      if builtin_class_send_safe?(name, %w[Array])
        array_arm = <<~CPP
            // ARRAY_PUSH :<< -- exact Array only; preserve subclass and override dispatch
            if (mrb_array_p(#{recv}) && mrb_obj_ptr(#{recv})->c == M->array_class) {
              mrb_ary_push(M, #{recv}, #{value});
              r#{d} = #{recv};
            } else\x20
        CPP
      end
      return <<~CPP
          #{array_arm.chomp}// INTEGER_LSHIFT :<< -- two immediate Integers; overflow keeps ordinary dispatch
          if (mrb_integer_p(#{recv}) && mrb_integer_p(#{value}) && mrb_integer(#{value}) != MRB_INT_MIN) {
            mrb_int bc2cpp_shl_v = mrb_integer(#{recv}), bc2cpp_shl_w = mrb_integer(#{value}), bc2cpp_shl_out;
            if (bc2cpp_shl_w == 0 || bc2cpp_shl_v == 0) {
              r#{d} = #{recv};
            } else if (mrb_num_shift(M, bc2cpp_shl_v, bc2cpp_shl_w, &bc2cpp_shl_out)) {
              r#{d} = mrb_int_value(M, bc2cpp_shl_out);
            } else {
              #{fallback}
            }
          } else {
            #{fallback}
          }
      CPP
    end

    integer_unary = compile_integer_unary(name, n, d, recv, argv)
    return integer_unary if integer_unary

    if name == '<<' && n == 1 && builtin_class_send_safe?(name, %w[Array])
      value = argv.first
      fallback = dynamic_dispatch_line(d, recv, name, argv)
      return <<~CPP
          // ARRAY_PUSH :<< -- exact Array only; preserve subclass and override dispatch
          if (mrb_array_p(#{recv}) && mrb_obj_ptr(#{recv})->c == M->array_class) {
            mrb_ary_push(M, #{recv}, #{value});
            r#{d} = #{recv};
          } else {
            #{fallback.chomp}
          }
      CPP
    end

    if name == 'concat' && n == 1 && owner_def&.owner == 'Optcarrot::APU' && owner_def.name == 'flush_sound' &&
       builtin_class_send_safe?(name, %w[Array])
      source = argv.first
      fallback = dynamic_dispatch_line(d, recv, name, argv)
      return <<~CPP
          // ARRAY_CONCAT_COPY :concat -- APU output buffer; preserve exact-Array capacity without sharing
          if (mrb_array_p(#{recv}) && mrb_obj_ptr(#{recv})->c == M->array_class &&
              mrb_array_p(#{source}) && mrb_obj_ptr(#{source})->c == M->array_class &&
              mrb_obj_ptr(#{recv}) != mrb_obj_ptr(#{source}) && ARY_LEN(mrb_ary_ptr(#{recv})) == 0) {
            r#{d} = mrb_ary_splice(M, #{recv}, 0, 0, #{source});
          } else {
            #{fallback.chomp}
          }
      CPP
    end

    if name == 'clear' && n.zero? && builtin_class_send_safe?(name, %w[Array])
      fallback = dynamic_dispatch_line(d, recv, name, argv)
      retain_frame_capacity = (owner_def&.owner == 'Optcarrot::PPU' && owner_def.name == 'setup_frame') ||
                              (owner_def&.owner == 'Optcarrot::APU' && owner_def.name == 'flush_sound')
      if retain_frame_capacity
        return <<~CPP
            // ARRAY_CLEAR_RETAIN :clear -- frame/audio buffer; clear length but reuse backing storage
            if (mrb_array_p(#{recv}) && mrb_obj_ptr(#{recv})->c == M->array_class) {
              struct RArray *bc2cpp_frame_pixels = mrb_ary_ptr(#{recv});
              mrb_ary_modify(M, bc2cpp_frame_pixels);
              ARY_SET_LEN(bc2cpp_frame_pixels, 0);
              r#{d} = #{recv};
            } else {
              #{fallback.chomp}
            }
        CPP
      end
    end

    if ['%', '&', '|', '^'].include?(name) && n == 1 && native_only_mono?(name)
      left, right = recv, argv.first
      fallback = dynamic_dispatch_line(d, recv, name, argv)
      operation = if name == '%'
                    <<~CPP.chomp
                      mrb_int bc2cpp_mod_left = mrb_fixnum(#{left});
                      mrb_int bc2cpp_mod_right = mrb_fixnum(#{right});
                      if (bc2cpp_mod_left == MRB_INT_MIN && bc2cpp_mod_right == -1) {
                        r#{d} = mrb_fixnum_value(0);
                      } else {
                        mrb_int bc2cpp_mod_value = bc2cpp_mod_left % bc2cpp_mod_right;
                        if ((bc2cpp_mod_left < 0) != (bc2cpp_mod_right < 0) && bc2cpp_mod_value != 0) {
                          bc2cpp_mod_value += bc2cpp_mod_right;
                        }
                        r#{d} = mrb_fixnum_value(bc2cpp_mod_value);
                      }
                    CPP
                  else
                    operator = { '&' => '&', '|' => '|', '^' => '^' }.fetch(name)
                    "r#{d} = mrb_fixnum_value(mrb_fixnum(#{left}) #{operator} mrb_fixnum(#{right}));"
                  end
      return <<~CPP
          // FIXNUM_BINARY :#{name} -- fixnum-only native semantics with Ruby fallback
          if (mrb_fixnum_p(#{left}) && mrb_fixnum_p(#{right})#{' && mrb_fixnum(' + right + ') != 0' if name == '%'}) {
            #{operation}
          } else {
            #{fallback.chomp}
          }
      CPP
    end

    if name == '>>' && n == 1 && builtin_class_send_safe?(name, %w[Integer Numeric])
      value, width = recv, argv.first
      fallback = dynamic_dispatch_line(d, recv, name, argv)
      return <<~CPP
          // FIXNUM_SHIFT :>> -- guarded shifts; overflow and non-Fixnum cases retain Ruby dispatch
          {
          mrb_bool bc2cpp_shift_fast = FALSE;
          mrb_int bc2cpp_shift_result = 0;
          if (mrb_fixnum_p(#{value}) && mrb_fixnum_p(#{width})) {
            mrb_int bc2cpp_shift_value = mrb_fixnum(#{value});
            mrb_int bc2cpp_shift_width = mrb_fixnum(#{width});
            if (bc2cpp_shift_width == 0) {
              bc2cpp_shift_result = bc2cpp_shift_value;
              bc2cpp_shift_fast = TRUE;
            } else if (bc2cpp_shift_width > 0) {
              if (bc2cpp_shift_width >= MRB_INT_BIT - 1) {
                bc2cpp_shift_result = bc2cpp_shift_value < 0 ? -1 : 0;
              } else {
                bc2cpp_shift_result = bc2cpp_shift_value >> bc2cpp_shift_width;
              }
              bc2cpp_shift_fast = TRUE;
            } else if (bc2cpp_shift_width != MRB_INT_MIN) {
              if (bc2cpp_shift_value == 0) {
                bc2cpp_shift_fast = TRUE;
              } else {
                mrb_int bc2cpp_left_width = -bc2cpp_shift_width;
                if (bc2cpp_left_width <= MRB_INT_BIT - 1 &&
                    !(bc2cpp_shift_value > 0 && bc2cpp_shift_value > (MRB_INT_MAX >> bc2cpp_left_width)) &&
                    !(bc2cpp_shift_value < 0 && bc2cpp_shift_value < (MRB_INT_MIN >> bc2cpp_left_width))) {
                  if (bc2cpp_left_width == MRB_INT_BIT - 1) {
                    bc2cpp_shift_result = MRB_INT_MIN;
                  } else if (bc2cpp_shift_value > 0) {
                    bc2cpp_shift_result = bc2cpp_shift_value << bc2cpp_left_width;
                  } else {
                    bc2cpp_shift_result = bc2cpp_shift_value * ((mrb_int)1 << bc2cpp_left_width);
                  }
                  bc2cpp_shift_fast = TRUE;
                }
              }
            }
          }
          if (bc2cpp_shift_fast) {
            r#{d} = mrb_fixnum_value(bc2cpp_shift_result);
          } else {
            #{fallback.chomp}
          }
          }
      CPP
    end

    if ['<', '<=', '>', '>='].include?(name) && n == 1 && native_only_mono?(name)
      left, right = recv, argv.first
      fallback = dynamic_dispatch_line(d, recv, name, argv)
      operator = { '<' => '<', '<=' => '<=', '>' => '>', '>=' => '>=' }.fetch(name)
      return <<~CPP
          // FIXNUM_COMPARE :#{name} -- fixnum-only native comparison with Ruby fallback
          if (mrb_fixnum_p(#{left}) && mrb_fixnum_p(#{right})) {
            r#{d} = mrb_bool_value(mrb_fixnum(#{left}) #{operator} mrb_fixnum(#{right}));
          } else {
            #{fallback.chomp}
          }
      CPP
    end

    if name == 'slice!' && n == 2 && builtin_class_send_safe?(name, %w[Array])
      start, length = argv
      fallback = dynamic_dispatch_line(d, recv, name, argv)
      return <<~CPP
          // ARRAY_PREFIX_SLICE_WRITE :slice! -- exact Array, zero start, nonnegative fixnum length
          if (mrb_array_p(#{recv}) && mrb_obj_ptr(#{recv})->c == M->array_class &&
              !mrb_frozen_p(mrb_obj_ptr(#{recv})) && mrb_fixnum_p(#{start}) &&
              mrb_fixnum(#{start}) == 0 && mrb_fixnum_p(#{length}) && mrb_fixnum(#{length}) >= 0) {
            mrb_value bc2cpp_slice_receiver = #{recv};
            mrb_int bc2cpp_slice_len = mrb_fixnum(#{length});
            mrb_int bc2cpp_array_len = RARRAY_LEN(bc2cpp_slice_receiver);
            if (bc2cpp_slice_len > bc2cpp_array_len) bc2cpp_slice_len = bc2cpp_array_len;
            r#{d} = mrb_ary_new_from_values(M, bc2cpp_slice_len, RARRAY_PTR(bc2cpp_slice_receiver));
            mrb_ary_splice(M, bc2cpp_slice_receiver, 0, bc2cpp_slice_len, mrb_undef_value());
          } else {
            #{fallback.chomp}
          }
      CPP
    end

    if name == 'key?' && n == 1 && !@native_registered_expressions.key?(name) &&
       builtin_class_send_safe?(name, %w[Hash])
      return compile_native_primitive_send(name, d, recv, argv)
    end

    # Resolve compiled MONO/TYPED targets first; only the final POLY fallback uses
    # the generated native C expressions.
    native_expression_entries = @native_registered_expressions[name]
    # EQ_CHAIN_FALLBACK: compile_cmp wraps this send in its own String/Symbol chain
    # (generated_eq_dispatch), so the send must not emit that switch a second time.
    native_expression_entries = nil if @suppress_native_expression_send == name
    native_expression_owners = native_expression_entries&.map { |entry| entry[:owner][:class_name] }&.uniq
    builtin_native_expression_send = native_expression_entries && native_expression_entries.all? { |entry| entry[:arity] == n } &&
                                     builtin_class_send_safe?(name, native_expression_owners)

    if (expected_n = NATIVE_PRIMITIVE_SEND_ARITY[name]) && n == expected_n && native_only_mono?(name) &&
       !@native_registered_expressions.key?(name)
      return compile_native_primitive_send(name, d, recv, argv)
    end

    target = monomorphic_target(name)
    # A MONO name is only safe to devirtualize if its definition fits the calling
    # convention (pure_mandatory_or_optional_arity?).
    target = nil if target && !pure_mandatory_or_optional_arity?(@ireps.fetch(target.irep))
    # ...and if this call's argument count fits the target's arity. Without
    # NATIVE_SRCS, `:repeat?` looks MONO (only Game::MoveRoute#repeat?, 0 args, is
    # bytecode) although `Input.repeat?(key)` (native, 1 arg) uses the name, and a
    # direct call would not compile. The argument count needs no NATIVE_SRCS and
    # never matches a genuinely different method's arity.
    # CALLSITE_OPTIONAL_ARG_SUPPORT: any count in [mand, mand + opt]; with no
    # optionals this is the exact match.
    target = nil if target && !n.between?(mandatory_arity(@ireps.fetch(target.irep)),
                                           mandatory_arity(@ireps.fetch(target.irep)) + optional_arity(@ireps.fetch(target.irep)))
    # LEXICAL_SELF_SUPPORT: POLY by name, but for an IMPLICIT-self send `self`'s
    # class is known outright when lexical_self_owner says so (no subclass of the
    # owner exists, and no instance_eval/instance_exec rebinding occurs here; see
    # self_receiver_class). A proven fact, so the direct call needs no runtime
    # guard or fallback, like MONO. Never for an explicit receiver.
    lexical_self = false
    lexical_self_ivar_accessor = nil
    if target.nil? && self_implicit
      lex_owner = lexical_self_owner(owner_def)
      # SINGLETON_LEXICAL_SELF: only the irep branch below; accessors stay dynamic.
      singleton_candidate = lex_owner.nil? && lexical_self_singleton_def(name, owner_def)
      if lex_owner || singleton_candidate
        lex_candidate = singleton_candidate || @registry[name]&.find { |md| md.owner == lex_owner }
        if lex_candidate&.irep && pure_mandatory_or_optional_arity?(@ireps.fetch(lex_candidate.irep)) &&
           compiles_clean?(lex_candidate.irep) &&
           n.between?(mandatory_arity(@ireps.fetch(lex_candidate.irep)),
                      mandatory_arity(@ireps.fetch(lex_candidate.irep)) + optional_arity(@ireps.fetch(lex_candidate.irep)))
          target = lex_candidate
          lexical_self = true
        elsif lex_candidate&.kind == :ivar_accessor && n == (name.end_with?('=') ? 1 : 0)
          # LEXICAL_SELF_IVAR_ACCESSOR: the :ivar_accessor analogue (an attr_* candidate
          # has no irep; see IVAR_ACCESSOR_DEVIRT). Same certainty, no guard; IVAR_ACCESS
          # chooses iv_tbl or the embedded struct.
          lexical_self_ivar_accessor = lex_candidate
        end
      end
    end
    # Still POLY: try the call-site fallback: the receiver traced (trace_new_target)
    # to one exact class. Exact owner match only (no MRO walk), so an inherited
    # method misses and keeps dispatch.
    # The trace sources are a fresh `.new` (a Ruby guarantee), a ClassLayout ivar
    # hint, or a ClassAnnotations argument (whole-program facts, not proofs), so
    # every hit gets a runtime mrb_obj_class check with an mrb_funcall fallback.
    typed = false
    via_element = false
    ivar_accessor_target = nil
    known_class = nil
    if target.nil? && !self_implicit && irep && (idx || trace_idx)
      proof_idx = idx || trace_idx
      proof_reg = unshift_proof_reg(trace_receiver_reg || d, trace_reg_offset)
      cur_enter = irep.instructions.find { |i| i.op == 'ENTER' }
      cur_mand = cur_enter ? cur_enter.args.split(':').first.to_i : 0
      cur_arg_classes = owner_def && @class_annotations[irep.label]&.args
      ivar_classes = owner_def && @class_layout[owner_def.owner]
      # CHAINED_ACCESSOR_SUPPORT: passing @class_layout/@registry lets TYPED resolve
      # multi-level accessor chains (`@state.screen.foo`); see trace_new_target.
      known_class = trace_new_target(irep, proof_idx, proof_reg, ivar_classes, cur_mand, cur_arg_classes, owner: owner_def&.owner,
                                      class_layout: @class_layout, registry: @registry,
                                      element_annotations: @element_annotations,
                                      known_owners: @known_owners,
                                      capture_hints: @block_hash_capture_hints)
    end
    # ELEMENT_CLASS_SUPPORT: the same TYPED/IVAR_ACCESSOR resolution fed by the
    # element hint (with_element_hint) for an inlined-loop parameter, which no
    # instruction writes. After the ordinary trace, so that path keeps priority by
    # construction. Everything downstream is shared with TYPED, including the
    # runtime `mrb_class_ptr(...) == mrb_obj_class(M, recv)` check and
    # mrb_funcall fallback, so a wrong element fact costs one failed compare.
    if target.nil? && !self_implicit && known_class.nil? && elem_class_hint
      known_class = elem_class_hint
      via_element = true
    end
    if target.nil? && !self_implicit && known_class
      candidate = @registry[name]&.find { |md| md.owner == known_class }
      # The same two guards as MONO: the class-exact candidate must compile clean
      # and fit the call's argument count.
      if candidate&.irep && pure_mandatory_or_optional_arity?(@ireps.fetch(candidate.irep)) &&
         compiles_clean?(candidate.irep) &&
         n.between?(mandatory_arity(@ireps.fetch(candidate.irep)),
                    mandatory_arity(@ireps.fetch(candidate.irep)) + optional_arity(@ireps.fetch(candidate.irep)))
        target = candidate
        typed = true
      elsif candidate&.kind == :ivar_accessor &&
            n == (name.end_with?('=') ? 1 : 0) &&
            ivar_accessor_call_code(candidate.owner, recv, name, d, argv)
        # IVAR_ACCESSOR_DEVIRT: an attr_* candidate has no irep, so it can never take
        # the TYPED branch. Its accessor is provably a bare mrb_iv_get/mrb_iv_set
        # (src/class.c; see MethodDef's `kind`), so it is inlined behind the same
        # runtime guard as TYPED. Arity is 0 for a reader and 1 for a writer (`=`
        # suffix), which is the complete check. For an embedded ivar IVAR_ACCESS
        # (ivar_accessor_call_code) picks the storage; nil leaves the call to dispatch.
        ivar_accessor_target = candidate
      end
    end
    # A target whose owner this run does not emit (ONLY_OWNERS) has no `_impl`
    # here (LCF::File#to_lcf calling LCF.write_ber would fail to link), so use
    # dynamic dispatch, unless another gem emits it (@other_owners; see
    # emit_decls_header).
    if target && @only_owners && !@only_owners.include?(target.owner)
      target = nil unless @other_owners&.include?(target.owner)
    end

    if target
      impl = cpp_name(target.owner, target.name) + '_impl'
      # NATIVE_ARG_TARGETS call-site half: the callee's `_impl` takes mrb_int/mrb_sym
      # for retyped positions (C++ has no implicit conversion from mrb_value), so
      # call_argv unboxes them here with mrb_as_int/mrb_obj_to_sym, the coercions
      # mrb_get_args "i"/"n" use in the entry wrapper (same TypeError). It wraps
      # whatever expression argv holds (e.g. `-weapon_sp_cost`).
      # native_arg_types is asked for t_mand positions only; NATIVE_ARG_TARGETS never
      # names optional-arg methods.
      t_irep = @ireps.fetch(target.irep)
      t_mand = mandatory_arity(t_irep)
      t_opt = optional_arity(t_irep)
      call_types = native_arg_types(target, t_mand)
      call_argv = argv.each_with_index.map do |a, i|
        case call_types[i]
        when :fixnum then "mrb_as_int(M, #{a})"
        when :symbol then "mrb_obj_to_sym(M, #{a})"
        else a
        end
      end
      # CALLSITE_OPTIONAL_ARG_SUPPORT: `_impl` always takes all optionals, so omitted
      # trailing ones get mrb_nil_value() placeholders (as the entry wrapper does;
      # never read), plus the `bc2cpp_given_opt` literal `argv.size - t_mand`.
      if t_opt.positive?
        call_argv += Array.new(t_mand + t_opt - argv.size, 'mrb_nil_value()')
        call_argv << (argv.size - t_mand).to_s
      end
      native_positions = call_types.each_index.select { |i| call_types[i] }.map { |i| i + 1 }
      native_note = native_positions.empty? ? '' : " (position#{'s' unless native_positions.one?} " \
                                                    "#{native_positions.join(', ')} unboxed here to match " \
                                                    "#{impl}'s own native argument type)"
      if typed
        check = "#{owner_class_ptr_expr(target.owner)} == mrb_obj_class(M, #{recv})"
        # ELEMENT_CLASS_SUPPORT: the tag records which fact proved the receiver.
        kind = via_element ? 'ELEMENT' : 'TYPED'
        traced_note = via_element ? "inlined block element of Array<#{target.owner}>" : "receiver traced to #{target.owner}"
        note = "  // #{kind} :#{name} -> #{target.owner}##{target.name} (#{traced_note}), " \
               "runtime-class-checked direct C++ call, mrb_funcall fallback#{native_note}\n"
        fallback = typed_fallback ||
                   guarded_fallback_line(d, recv, name, argv, [target.owner],
                                         closed_world_site(recv, irep, idx, owner_def))
        "#{note}  if (#{check}) {\n" \
          "    r#{d} = #{impl}(M, #{([recv] + call_argv).join(', ')});\n" \
          "  } else {\n" \
          "    #{fallback}" \
          "  }\n"
      elsif lexical_self
        note = "  // LEXICAL_SELF :#{name} -> #{target.owner}##{target.name} (self, statically " \
               "#{target.owner} -- no subclass exists program-wide), direct C++ call (no mrb_funcall, " \
               "no runtime check)#{native_note}\n"
        "#{note}  r#{d} = #{impl}(M, #{([recv] + call_argv).join(', ')});\n"
      elsif @ivar_layout.key?(target.owner)
        # MONO_EMBED_GUARD: MONO says nothing about method_missing: a class answering a
        # name via method_missing (LCF::Array1D/Array2D) adds no registry entry, so
        # MONO may call `impl` on a receiver that is not target.owner. Normally that
        # only touches the wrong iv_tbl (memory-safe), but if target.owner embeds any
        # ivar, GETIV/SETIV cast DATA_PTR(self) unconditionally and a plain RObject
        # receiver makes it a type-confused read (`@db_row.faceset_index` on an
        # Array1D crashed in Game::Actor's accessor). So every MONO call into an
        # embedding class gets the class guard, rather than proving per body that no
        # DATA_PTR is reached.
        cw_site = closed_world_site(recv, irep, idx, owner_def)
        # CLOSED_WORLD_SELF: LEXICAL_SELF's reasoning for a MONO target. Self is
        # kind_of the owner and the closed world proves it has no subclass, so
        # the guard can only be true.
        if cw_site && cw_site[:self_owner] == target.owner && @closed_world.exact_class?(target.owner)
          note = "  // CLOSED_WORLD_SELF :#{name} -> #{target.owner}##{target.name} (self, exactly " \
                 "#{target.owner}: no subclass in the closed world), direct C++ call#{native_note}\n"
          return "#{note}  r#{d} = #{impl}(M, #{([recv] + call_argv).join(', ')});\n"
        end

        check = "#{owner_class_ptr_expr(target.owner)} == mrb_obj_class(M, #{recv})"
        note = "  // MONO_EMBED_GUARD :#{name} -> #{target.owner}##{target.name} (embeds ivars; " \
               "method_missing elsewhere could otherwise mistarget this), runtime-class-checked " \
               "direct C++ call, mrb_funcall fallback#{native_note}\n"
        fallback = guarded_fallback_line(d, recv, name, argv, [target.owner], cw_site)
        "#{note}  if (#{check}) {\n" \
          "    r#{d} = #{impl}(M, #{([recv] + call_argv).join(', ')});\n" \
          "  } else {\n" \
          "    #{fallback}" \
          "  }\n"
      else
        # target.owner embeds no ivar, so its GETIV/SETIV never cast DATA_PTR(self); a
        # wrong receiver is only semantically wrong, as unguarded MONO always was. No
        # guard.
        note = "  // MONO :#{name} -> #{target.owner}##{target.name}, direct C++ call (no mrb_funcall)" \
               "#{native_note}\n"
        "#{note}  r#{d} = #{impl}(M, #{([recv] + call_argv).join(', ')});\n"
      end
    elsif lexical_self_ivar_accessor
      # LEXICAL_SELF_IVAR_ACCESSOR codegen: no guard, no fallback; IVAR_ACCESS picks
      # the storage.
      owner = lexical_self_ivar_accessor.owner
      ivar = name.chomp('=')
      storage = embed_type(owner, ivar) ? 'embedded struct field' : 'mrb_iv_get/mrb_iv_set'
      kind = name.end_with?('=') ? 'attr_writer' : 'attr_reader'
      note = "  // LEXICAL_SELF_IVAR_ACCESSOR :#{name} -> #{owner}#@#{ivar} (self, statically #{owner}), " \
             "#{kind} devirtualized to a direct #{storage} access (no _impl, no mrb_funcall, no runtime " \
             "check) -- see MethodDef's own kind: :ivar_accessor comment for the real " \
             "3rd/mruby/src/class.c citation this reproduces exactly.\n"
      "#{note}  #{ivar_accessor_call_code(owner, recv, name, d, argv, self_of_klass: true)}\n"
    elsif ivar_accessor_target
      # IVAR_ACCESSOR_DEVIRT codegen (see the branch above): guarded like TYPED, since
      # the real class may differ from the trace (subclass, reassigned constant), with
      # an mrb_funcall fallback.
      owner = ivar_accessor_target.owner
      check = "#{owner_class_ptr_expr(owner)} == mrb_obj_class(M, #{recv})"
      # ELEMENT_CLASS_SUPPORT: same tag as the TYPED branch.
      traced_note = via_element ? "inlined block element of Array<#{owner}>" : "receiver traced to #{owner}"
      ivar = name.chomp('=')
      # An embedded ivar goes through its synthesized accessor (IVAR_ACCESS).
      storage = if embed_type(owner, ivar) then 'synthesized struct accessor'
                elsif name.end_with?('=') then 'mrb_iv_set'
                else 'mrb_iv_get'
                end
      kind = name.end_with?('=') ? 'attr_writer' : 'attr_reader'
      note = "  // IVAR_ACCESSOR#{via_element ? '/ELEMENT' : ''} :#{name} -> #{owner}#@#{ivar} (#{traced_note}), " \
             "#{kind} devirtualized to a direct #{storage} (no mrb_funcall) -- see " \
             "MethodDef's own kind: :ivar_accessor comment for the real 3rd/mruby/src/class.c " \
             "citation this reproduces exactly (a writer yields the assigned value).\n"
      fallback = guarded_fallback_line(d, recv, name, argv, [owner], closed_world_site(recv, irep, idx, owner_def))
      "#{note}  if (#{check}) {\n" \
        "    #{ivar_accessor_call_code(owner, recv, name, d, argv, indent: '    ')}\n" \
        "  } else {\n" \
        "    #{fallback}" \
        "  }\n"
    else
      return compile_native_primitive_send(name, d, recv, argv) if builtin_native_expression_send

      cw_site = closed_world_site(recv, irep, idx, owner_def)
      poly = compile_poly_small_n(name, d, recv, argv, n, closed_world_site: cw_site) ||
             compile_poly_table(name, d, recv, argv, n, closed_world_site: cw_site)
      return poly if poly

      note = "  // POLY :#{name} -- real dynamic dispatch, receiver's runtime class decides\n"
      "#{note}  #{dynamic_dispatch_line(d, recv, name, argv)}"
    end
  end

  # `Owner::Path` -> a chained mrb_const_get expression for the class object (the
  # per-segment lookup GETCONST/GETMCNST do; mrb_class_get_under does not parse
  # "::"). Used only in guard conditions. Uses lexical_scope_path, stripping a
  # ".singleton" suffix (see there), although TYPED owners are never
  # `.singleton` today.
  def const_chain_value_expr(owner)
    lexical_scope_path(owner).reduce('mrb_obj_value(M->object_class)') do |expr, seg|
      "mrb_const_get(M, #{expr}, mrb_intern_cstr(M, \"#{seg}\"))"
    end
  end

  # OWNER_CLASS_CACHE: the RClass* for `owner` via a per-owner helper
  # (emit_owner_class_cache) instead of repeating mrb_const_get + mrb_intern_cstr
  # in every TYPED/POLY_SMALL_N guard on the hot path.
  def owner_class_ptr_expr(owner)
    "#{owner_class_fn_name(owner)}(M)"
  end

  # The cache getter itself, for a table that stores it (POLY_TABLE).
  def owner_class_fn_name(owner)
    @owner_class_cache ||= {}
    slot = (@owner_class_cache[owner] ||= { index: @owner_class_cache.size })
    "bc2cpp_owner_class_#{slot[:index]}"
  end

  # File-scope cache emitted ahead of the compiled bodies. A static per owner,
  # also keyed on the mrb_state pointer and reset by the gem's gem_final
  # (bc2cpp_reset_owner_classes), so a later VM at a reused address never sees a
  # stale pointer. Every caller is a class-equality guard with a dynamic
  # fallback, so an undefined class yields nullptr (guard false) instead of
  # raising NameError (an RGSS-only run never defines Game). nullptr is not
  # cached, so a later definition is found. A later reassignment of the constant
  # is not noticed (as with g_direct_construct_*).
  def emit_owner_class_cache
    entries = (@owner_class_cache || {}).to_a
    out = +"// OWNER_CLASS_CACHE -- see bc2cpp.rb's own owner_class_ptr_expr comment.\n"
    out << "static mrb_state* bc2cpp_owner_class_state = nullptr;\n"
    out << "static struct RClass* bc2cpp_owner_class_slots[#{[entries.size, 1].max}] = {};\n"
    memo = poly_table_memo_decl
    out << memo
    out << "static void bc2cpp_reset_owner_classes() {\n" \
           "  bc2cpp_owner_class_state = nullptr;\n" \
           "  for (struct RClass*& c : bc2cpp_owner_class_slots) c = nullptr;\n" \
           "#{memo.empty? ? '' : "  for (bc2cpp_poly_memo& m : bc2cpp_poly_memos) m = {};\n"}" \
           "}\n"
    unless entries.empty?
      # CLOSED_WORLD: a guard whose else arm raises must name exactly the class
      # the registry means, never a same-named constant found through ancestry.
      defined = @closed_world ? 'mrb_const_defined_at' : 'mrb_const_defined'
      out << <<~CPP
        static struct RClass* bc2cpp_owner_class_lookup(mrb_state* M, const char* const* path, int n) {
          mrb_value v = mrb_obj_value(M->object_class);
          for (int i = 0; i < n; ++i) {
            mrb_sym s = mrb_intern_cstr(M, path[i]);
            if (!#{defined}(M, v, s)) return nullptr;
            v = mrb_const_get(M, v, s);
          }
          return mrb_class_ptr(v);
        }
      CPP
    end
    entries.each do |owner, slot|
      i = slot[:index]
      path = lexical_scope_path(owner)
      out << <<~CPP
        static inline struct RClass* bc2cpp_owner_class_#{i}(mrb_state* M) {
          if (bc2cpp_owner_class_state != M) {
            bc2cpp_reset_owner_classes();
            bc2cpp_owner_class_state = M;
          }
          struct RClass* c = bc2cpp_owner_class_slots[#{i}];
          if (!c) {
            static const char* const path[] = {#{path.map { |seg| "\"#{seg}\"" }.join(', ')}};
            c = bc2cpp_owner_class_slots[#{i}] = bc2cpp_owner_class_lookup(M, path, #{path.size});
          }
          return c;
        }
      CPP
    end
    out
  end

  # The uncached GETCONST lookup: resolve the owner's lexical scope chain, probe
  # each scope innermost-first, fall back to Object. `d` is the destination
  # register number (a string). Used inline, and as the slow path of a
  # CONST_SITE_CACHE helper (which passes d = "0").
  def const_lookup_block(d, name, owner_path)
    if owner_path == ['Object']
      "  r#{d} = mrb_const_get(M, mrb_obj_value(M->object_class), mrb_intern_cstr(M, \"#{name}\"));\n"
    else
      @const_lookup_helper_used = true
      out = String.new
      out << "  {\n"
      scope_vars = []
      current = 'mrb_obj_value(M->object_class)'
      owner_path.each_with_index do |seg, i|
        out << "    mrb_value scope#{i} = mrb_const_get(M, #{current}, mrb_intern_cstr(M, \"#{seg}\"));\n"
        scope_vars << "scope#{i}"
        current = "scope#{i}"
      end
      out << "    mrb_bool ok = FALSE;\n"
      out << "    mrb_value r#{d}_tmp = mrb_nil_value();\n"
      scope_vars.reverse_each do |sv|
        out << "    if (!ok) r#{d}_tmp = bc2cpp_const_try(M, #{sv}, mrb_intern_cstr(M, \"#{name}\"), &ok);\n"
      end
      out << "    if (!ok) r#{d}_tmp = mrb_const_get(M, mrb_obj_value(M->object_class), mrb_intern_cstr(M, \"#{name}\"));\n"
      out << "    r#{d} = r#{d}_tmp;\n"
      out << "  }\n"
      out
    end
  end

  # File-scope state and helpers for CONST_SITE_CACHE. Each helper returns the
  # constant's class or module, running the full lookup only until that first
  # succeeds (a failed lookup still raises from the same code and stores
  # nothing). Only a class/module value is stored. Keyed on the mrb_state* with
  # its own reset, dropped by each compiled gem's gem_final via
  # bc2cpp_reset_const_site_cache(); always emitted so gem_final can call it.
  def emit_const_site_cache
    entries = (@const_site_cache || {}).values
    count = [entries.size, 1].max
    out = +"// CONST_SITE_CACHE -- see tools/bc2cpp/const_site_cache.rb.\n"
    out << "static mrb_state* bc2cpp_cconst_state = nullptr;\n"
    out << "static mrb_value bc2cpp_cconst_slots[#{count}];\n"
    out << "static bool bc2cpp_cconst_have[#{count}] = {};\n"
    out << "static void bc2cpp_reset_const_site_cache() {\n" \
           "  bc2cpp_cconst_state = nullptr;\n" \
           "  for (bool& h : bc2cpp_cconst_have) h = false;\n" \
           "}\n"
    entries.each do |slot|
      i = slot[:index]
      out << "static mrb_value bc2cpp_cconst_#{i}(mrb_state* M) {\n" \
             "  if (bc2cpp_cconst_state != M) {\n" \
             "    bc2cpp_reset_const_site_cache();\n" \
             "    bc2cpp_cconst_state = M;\n" \
             "  }\n" \
             "  if (bc2cpp_cconst_have[#{i}]) return bc2cpp_cconst_slots[#{i}];\n" \
             "  mrb_value r0 = mrb_nil_value();\n"
      out << slot[:body].lines.map { |l| "  #{l}" }.join
      out << "  if (mrb_type(r0) == MRB_TT_CLASS || mrb_type(r0) == MRB_TT_MODULE) {\n" \
             "    bc2cpp_cconst_slots[#{i}] = r0;\n" \
             "    bc2cpp_cconst_have[#{i}] = true;\n" \
             "  }\n" \
             "  return r0;\n" \
             "}\n"
    end
    out
  end

  # mruby's variadic mrb_funcall/mrb_funcall_id copy into a fixed
  # MRB_FUNCALL_ARGC_MAX array and raise "Too long arguments" past it.
  FUNCALL_ARGC_MAX = 16

  def dynamic_dispatch_line(d, recv, name, argv)
    if argv.empty?
      "r#{d} = mrb_funcall(M, #{recv}, \"#{name}\", 0);\n"
    elsif argv.size > FUNCALL_ARGC_MAX
      # A literal-sized splat unrolls one argument per element
      # (Game::Battle.from_actor's 22-field `Combatant.new(*[...])`).
      # mrb_funcall_argv has no such cap: it packs 15+ into a splat itself.
      "{ mrb_value bc2cpp_argv[] = { #{argv.join(', ')} }; " \
        "r#{d} = mrb_funcall_argv(M, #{recv}, mrb_intern_lit(M, \"#{name}\"), #{argv.size}, bc2cpp_argv); }\n"
    else
      "r#{d} = mrb_funcall(M, #{recv}, \"#{name}\", #{argv.size}, #{argv.join(', ')});\n"
    end
  end

  # CLOSED_WORLD: the else arm of a receiver-class guard chain listing
  # `listed`. `site` is closed_world_site's result, nil for a chain this does
  # not model. A proven fallback raises what dispatch would (bc2cpp_nomethod);
  # a refused one keeps dispatch and names the reason for the summary.
  def guarded_fallback_line(d, recv, name, argv, listed, site)
    dispatch = dynamic_dispatch_line(d, recv, name, argv)
    return dispatch unless @closed_world && site

    reason = argv.size > FUNCALL_ARGC_MAX ? :argc : @closed_world.refusal(name, listed, site[:self_owner],
                                                                          symbol_installed_names)
    return dispatch.sub(/\n\z/, " /* CLOSED_WORLD kept: #{reason} */\n") if reason

    args = argv.empty? ? '' : ", #{argv.size}, #{argv.join(', ')}"
    # The marker outlives SymbolCache's rewrite of the name; bc2cpp.rb reads it
    # to hold every such site to NOMETHOD_REVIEWED (ADR 0226).
    marker = NomethodReviewed.marker(name, self_receiver: !site[:self_owner].nil?)
    "r#{d} = bc2cpp_nomethod_named(M, #{recv}, \"#{name}\"#{args}); #{marker}\n"
  end

  # CLOSED_WORLD: the facts guarded_fallback_line needs about a call site --
  # the enclosing owner when the receiver is provably that method's own self.
  def closed_world_site(recv, irep, idx, owner_def)
    return nil unless @closed_world

    self_owner = owner_def && self_class(owner_def)
    unless recv == 'self'
      reg = recv[/\Ar(\d+)\z/, 1]
      prev = reg && irep && idx&.positive? && irep.instructions[idx - 1]
      self_loaded = prev && prev.op == 'LOADSELF' && prev.args[/\AR(\d+)/, 1] == reg &&
                    fixnum_proof_preds(irep)&.fetch(idx, nil).to_a == [idx - 1]
      self_owner = nil unless self_loaded
    end
    { self_owner: self_owner }
  end

  def regs(args_text, count)
    args_text.scan(/R(\d+)/).flatten.first(count)
  end

  def c_string_literal(s)
    '"' + s.bytes.map { |b| format('\\x%02x', b) }.join + '"'
  end
end
