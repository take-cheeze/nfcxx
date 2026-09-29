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
    new_proof_idx = idx || trace_idx
    new_proof_reg = unshift_proof_reg(trace_receiver_reg || d, trace_reg_offset)
    drawing_proof_idx = idx || trace_idx
    drawing_proof_reg = unshift_proof_reg(trace_receiver_reg || d, trace_reg_offset)
    drawing_enter = irep&.instructions&.find { |insn| insn.op == 'ENTER' }
    drawing_mand = drawing_enter ? drawing_enter.args.split(':').first.to_i : 0
    drawing_arg_classes = owner_def && @class_annotations[irep&.label]&.args
    drawing_ivar_classes = owner_def && @class_layout[owner_def.owner]

    # EXCEPTION_MESSAGE_DIRECT: the rescue recognizer plus the receiver-fact
    # MOVE-chain proof establishes that `recv` is the caught Exception object.
    # Match error.c's exc_to_s exactly, including nil/non-string messages and
    # the lazy String class assignment; the registry gate excludes Ruby overrides.
    if name == 'message' && n.zero? && !self_implicit && irep && idx &&
       rescued_exception_message_safe? && rescued_exception_receiver?(irep, idx, d)
      return "  // EXCEPTION_MESSAGE_DIRECT: recognized rescued Exception; mirrors error.c exc_to_s.\n" \
             "  {\n" \
             "    mrb_value bc2cpp_exc_message = mrb_exc_ptr(#{recv})->mesg ? " \
             "mrb_obj_value(mrb_exc_ptr(#{recv})->mesg) : mrb_nil_value();\n" \
             "    if (!mrb_string_p(bc2cpp_exc_message)) {\n" \
             "      r#{d} = mrb_str_new_cstr(M, mrb_obj_classname(M, #{recv}));\n" \
             "    } else {\n" \
             "      struct RObject* bc2cpp_exc_message_obj = mrb_obj_ptr(bc2cpp_exc_message);\n" \
             "      if (!bc2cpp_exc_message_obj->c) bc2cpp_exc_message_obj->c = M->string_class;\n" \
             "      r#{d} = bc2cpp_exc_message;\n" \
             "    }\n" \
             "  }\n"
    end

    # IO_PUTS_MODEL: mruby-io's public helper checks the actual resolved method
    # against its registered C body, then calls the same implementation with
    # explicit argv. Any override, prepend, or non-IO receiver keeps Ruby dispatch.
    if name == 'puts' && !self_implicit && n <= 14
      direct_argv = argv.empty? ? 'NULL' : "bc2cpp_puts_argv_#{d}"
      args_decl = argv.empty? ? '' : "    mrb_value bc2cpp_puts_argv_#{d}[#{n}] = { #{argv.join(', ')} };\n"
      return "  // IO_PUTS_MODEL: calls core IO#puts with explicit arguments after exact runtime target check.\n" \
             "#ifdef HAVE_MRUBY_IO_GEM\n" \
             "  {\n" \
             "#{args_decl}" \
             "    mrb_value bc2cpp_puts_result_#{d};\n" \
             "    if (mrb_io_puts_direct(M, #{recv}, #{n}, #{direct_argv}, " \
             "&bc2cpp_puts_result_#{d})) {\n" \
             "      r#{d} = bc2cpp_puts_result_#{d};\n" \
             "    } else {\n" \
             "      #{dynamic_dispatch_line(d, recv, name, argv)}" \
             "    }\n" \
             "  }\n" \
             "#else\n" \
             "  #{dynamic_dispatch_line(d, recv, name, argv)}" \
             "#endif\n"
    end

    implicit_new_target = name == 'new' && self_implicit ? implicit_singleton_self_class(owner_def) : nil
    new_target = if implicit_new_target
                   implicit_new_target
                 elsif name == 'new' && !self_implicit && irep && new_proof_idx
                   trace_new_target(irep, new_proof_idx, new_proof_reg, nil, 0, nil, resolving_new: true,
                                   owner: owner_def&.owner,
                                   class_layout: @class_layout, registry: @registry,
                                   container_constants: @container_constants,
                                   element_annotations: @element_annotations,
                                   known_owners: @known_owners,
                                   capture_hints: @block_hash_capture_hints,
                                   method_return_class: ->(method_name) { class_return_for_dispatch(method_name) })
                 end

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

    # FLOAT_DIV_RECEIVER: an exact Float tag selects Float#/'s native body.
    # Keep dispatch for other receiver classes and Complex arguments.
    if name == '/' && n == 1 && builtin_class_send_safe?(name, %w[Float])
      arg = argv.first
      fallback = dynamic_dispatch_line(d, recv, name, argv)
      return "  // FLOAT_DIV_RECEIVER :/ -> Float#/, guarded by exact Float type\n" \
             "  #ifdef MRB_USE_COMPLEX\n" \
             "  if (mrb_type(#{recv}) == MRB_TT_FLOAT && mrb_type(#{arg}) != MRB_TT_COMPLEX) {\n" \
             "  #else\n" \
             "  if (mrb_type(#{recv}) == MRB_TT_FLOAT) {\n" \
             "  #endif\n" \
             "    r#{d} = mrb_float_value(M, mrb_div_float(mrb_float(#{recv}), mrb_as_float(M, #{arg})));\n" \
             "  } else {\n" \
             "    #{fallback.chomp}\n" \
             "  }\n"
    end

    # Devirtualize `:new` when either bytecode traces its class constant or the
    # enclosing singleton method proves that implicit self is the class object.
    if name == 'new' && irep && new_target
      known = new_target
      native_name = known && UniqueClassNames.table&.key(known)
      native_name = nil unless native_name && UniqueClassNames.resolve(native_name, owner_def&.owner) == known
      native = known && (NATIVE_CONSTRUCT_TARGETS[known] ||
                         (native_name && NATIVE_CONSTRUCT_TARGETS[native_name]) ||
                         NATIVE_CONSTRUCT_TARGETS.values.find { |row| row[:class_owner] == known })
      native_owner = native && (native[:class_owner] || known)
      native_constructor_safe = native && @closed_world&.standard_constructor_lookup? &&
                                exact_constructor_chain?(native_owner)
      # Exact arity only (an Array lists several accepted counts); other counts fall
      # through to dynamic dispatch.
      if native_constructor_safe &&
         (native[:arity] == n || (native[:arity].is_a?(Array) && native[:arity].include?(n)))
        @native_construct_used << known
        if native[:arg_type] == :table_dimensions
          dims = argv.each_with_index.map { |arg, i| "bc2cpp_table_dim_#{d}_#{i}" }
          declarations = argv.zip(dims).map { |arg, local| "mrb_int #{local} = mrb_as_int(M, #{arg});" }
          padded_dims = dims + Array.new(3 - dims.size, '1')
          call = "r#{d} = #{native[:fn]}(M, #{native[:class_fn]}(), #{n}, #{padded_dims.join(', ')});"
          class_guard = "mrb_class_p(#{recv}) && mrb_class_ptr(#{recv}) == #{native[:class_fn]}()"
          fallback = dynamic_dispatch_line(d, recv, name, argv).chomp
          return <<~CPP
              // RGSS Table.new -- integer conversion and allocation match Table#initialize
              if (#{class_guard}) {
                {
                  #{declarations.join("\n  ")}
                  #{call}
                }
              } else {
                #{fallback}
              }
          CPP
        end
        # `fn` takes native mrb_int/mrb_float, so arguments are unboxed here with the
        # same mrb_as_int/mrb_as_float the function used internally (same TypeError).
        # `:object` (Sprite) passes through; a 0-argument Sprite.new passes an explicit
        # mrb_nil_value(), since the C++ signature always has the full parameter list
        # (include/rgss_construct.hxx) and "|o" leaves vp nil.
        # `type_guard` (Bitmap): check every argument's Integer tag and fall back to
        # mrb_funcall if any fails (a String first argument is the file-load form);
        # read with mrb_integer after the check.
        stable_constructor = stable_standard_constructor_class?(native_owner)
        class_value = stable_constructor ? "#{native[:class_fn]}()" : "mrb_class_ptr(#{recv})"
        class_guard = stable_constructor ? nil : "mrb_class_ptr(#{recv}) == #{native[:class_fn]}()"
        if native[:type_guard] == :int
          arg_checks = argv.map { |a| "mrb_integer_p(#{a})" }.join(' && ')
          unboxed_argv = argv.map { |a| "mrb_integer(#{a})" }
          guard = [class_guard, arg_checks].compact.join(' && ')
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
          guard = class_guard
          note_extra = ''
        end
        # The note's "unboxes each argument" only applies to :int/:float.
        unbox_phrase = case native[:arg_type]
                       when :int then 'unboxes each argument register with the same mrb_as_int that function used to call internally'
                       when :float then 'unboxes each argument register with the same mrb_as_float that function used to call internally'
                       else 'passes each argument register straight through as mrb_value'
                       end
        note = ["  // MONO :new -> #{known}, direct native construct (mruby-rgss/src/lib.cxx's own ",
                "#{native[:fn]}) -- skips Class#new's own allocate+initialize dispatch chain entirely.\n",
                (stable_constructor ?
                  "  // CLOSED_WORLD_STABLE_CLASS: the class constant and constructor lookup cannot be " \
                  "reassigned or intercepted, so its identity guard is omitted.\n" :
                  "  // Runtime-guarded: a reassigned class constant falls back to ordinary mrb_funcall.\n"),
                "  //#{note_extra} #{native[:fn]}'s own parameters are native mrb_int/",
                "mrb_float, not mrb_value (except :object, passed straight through), so this call site #{unbox_phrase}, ",
                "and passes #{class_value} as the exact native class pointer.\n"].join
        call = "r#{d} = #{native[:fn]}(M, #{class_value}, #{unboxed_argv.join(', ')});\n"
        return "#{note}  #{call}" unless guard

        return "#{note}" \
               "  if (#{guard}) {\n" \
               "    #{call}" \
               "  } else {\n" \
               "    #{dynamic_dispatch_line(d, recv, name, argv)}" \
               "  }\n"
      end
    end

    # DIRECT_CONSTRUCT_TARGETS plus locally emitted compiled classes: the
    # compiled-initializer counterpart of the block above. The allowlist keeps
    # its stable gem-init accessor; other classes use the owner-class cache.
    if name == 'new' && irep && new_target
      known = new_target
      listed_target = known && DIRECT_CONSTRUCT_TARGETS.include?(known)
      generic_target = known && !listed_target && @closed_world&.stable_class_constant?(known) &&
                       stable_standard_constructor_class?(known)
      if known && (listed_target || generic_target)
        init_defs = @registry['initialize'].select { |md| md.owner == known }
        init_def = init_defs.one? ? init_defs.first : nil
        # DIRECT_CONSTRUCT_TARGETS' soundness bar, checked live against this run's
        # registry and ONLY_OWNERS.
        # 1/2: no custom `def self.new`/`def self.allocate` on this class ("X.singleton"
        # owner, see build_registry).
        no_custom_new = @closed_world&.standard_constructor_lookup? && exact_constructor_chain?(known) &&
                        @registry['new'].none? { |md| md.owner == "#{known}.singleton" }
        no_custom_allocate = @registry['allocate'].none? { |md| md.owner == "#{known}.singleton" }
        # 3: #initialize is a compiling leaf whose arity range covers this call.
        #
        # POSITIONAL_OPTIONAL_CONSTRUCT (this arm): the count used to have to
        # equal `mandatory_arity`, so an #initialize with `= default` arguments
        # could never fire -- and the comment above used to say so as a property of
        # the class ("they could never fire"). It CAN: the compiled `_impl` already
        # takes `mand + opt` positional registers plus a trailing `bc2cpp_given_opt`,
        # and its own OP_ENTER jump table substitutes the default when a position
        # was not supplied. So the call site supplies the real arguments, pads the
        # rest with placeholders the default code overwrites, and passes
        # `n - mand` as `bc2cpp_given_opt` -- exactly the shape
        # compile_keyword_direct_construct already emits for the keyword case
        # (KEYWORD_CONSTRUCT_OPTIONAL_POSITIONAL_SUPPORT).
        #
        # The defaults stay where they are: inside `_impl`, which is mruby's own
        # compiled body, so a `= 0` or `= nil` default is mruby's own value and
        # not a value bc2cpp re-derived. Nothing is invented at the call site.
        # `optional_arg_table` must resolve, which is what proves the jump targets
        # the jump table is about to take exist.
        init_irep = init_def&.irep ? @ireps.fetch(init_def.irep) : nil
        t_mand = init_irep ? mandatory_arity(init_irep) : nil
        t_opt = init_irep ? optional_arity(init_irep) : nil
        arity_ok = init_irep && n.between?(t_mand, t_mand + t_opt) && compiles_clean?(init_def.irep)
        arity_ok &&= !t_opt.positive? || optional_arg_table(init_irep)[1]
        # KEYWORD_INITIALIZE_STAYS_KEYWORDED: this arm emits a POSITIONAL call --
        # real arguments, optional padding, then bc2cpp_given_opt. An #initialize
        # that also declares KEYWORDS has its _impl widened to take them as
        # trailing (value, given) pairs (see compile_keyword_direct_construct's
        # own note), so a positional call here would be a compile error for a
        # too-few-argument call, and, where the arity happened to line up, would
        # silently drop the keyword values. Those classes belong to
        # compile_keyword_direct_construct, which matches keywords BY NAME and
        # pads positionals itself. Relaxing the arity test must not widen the
        # positional arm past the classes it can express.
        arity_ok &&= !mandatory_optional_and_keyword_arity?(init_irep) if arity_ok
        # NATIVE_ARG_TYPES_STAY_BOXED: an #initialize in NATIVE_ARG_TARGETS with
        # an ArgTypes annotation has its `_impl` narrowed to mrb_int/mrb_float
        # parameters (compile_method's signature, via native_arg_types), and the
        # UNBOXING lives in the entry wrapper's `mrb_get_args("i")`, not in the
        # `_impl`. A direct call bypasses that wrapper, so passing the mrb_value
        # register straight through is a type error:
        #
        #   RPG2k__Scene__Map__LRUBitmapCache_initialize_impl(M, r2, r3);
        #                                                    ^ cannot convert
        #                                                      mrb_value to mrb_int
        #
        # Unboxing here is possible (mrb_integer with the same nil-raise the
        # wrapper would do) but is a second, separate proof, and the wrapper's
        # nil-guard is what the annotation's own comment relies on. Refusing is
        # the sound and small answer: such a class keeps its dynamic dispatch
        # until a path that unboxes properly exists.
        arity_ok &&= native_arg_types(init_def, t_mand).all? { |ty| ty.nil? } if arity_ok
        if no_custom_new && no_custom_allocate && arity_ok
          # 4: the ONLY_OWNERS/OTHER_OWNERS emission guard.
          owner_emitted = if listed_target
                            !@only_owners || @only_owners.include?(known) || @other_owners&.include?(known)
                          else
                            !@only_owners || @only_owners.include?(known)
                          end
          if owner_emitted
            if listed_target
              @direct_construct_used << known
              accessor = "#{direct_construct_class_fn(known)}()"
            else
              accessor = owner_class_ptr_expr(known)
            end
            @direct_alloc_used = true
            stable_constructor = stable_standard_constructor_class?(known)
            init_impl = cpp_name(known, 'initialize') + '_impl'
            # POSITIONAL_OPTIONAL_CONSTRUCT: pad the omitted optionals, then pass
            # how many were really given, so `_impl`'s jump table substitutes the
            # defaults for exactly the omitted positions. Omitted optionals never
            # reach the entry wrapper, so the value passed here is a placeholder
            # the default branch overwrites.
            call_args = argv.dup
            if t_opt.positive?
              call_args += Array.new(t_mand + t_opt - argv.size, 'mrb_nil_value()')
              call_args << (argv.size - t_mand).to_s
            end
            opt_phrase = if t_opt.positive?
                           " #{t_opt} optional parameter(s) omitted at this site are filled by " \
                           "#{init_impl}'s own OP_ENTER default jump table, which is mruby's own code, " \
                           "given bc2cpp_given_opt = #{argv.size - t_mand} (positional-only, so no " \
                           "KEYWORD_CALLSITE_ARITY_FIX adjustment applies).\n"
                         else
                           ''
                         end
            note = ["  // MONO :new -> #{known}, direct compiled construct (bc2cpp_direct_alloc + ",
                    "#{init_impl}) -- skips Class#new's own allocate+initialize dispatch chain entirely; ",
                    "#{known}#initialize's own return value is discarded (real Ruby .new always returns ",
                    "the new object, never whatever #initialize itself returns).\n",
                    "  // #{known}#initialize declares arity [#{t_mand}, #{t_mand + t_opt}] and this call ",
                    "passes #{n}.#{opt_phrase}",
                    (stable_constructor ?
                      "  // CLOSED_WORLD_STABLE_CLASS: the class constant and constructor lookup cannot be " \
                      "reassigned or intercepted, so the class identity guard is omitted.\n" :
                      "  // The class identity guard preserves ordinary dispatch if the constant was rebound.\n")].join
            if stable_constructor
              return "#{note}" \
                     "  r#{d} = bc2cpp_direct_alloc(M, #{accessor});\n" \
                     "  #{init_impl}(M, #{(['r' + d] + call_args).join(', ')});\n"
            end

            return "#{note}" \
                   "  if (mrb_class_ptr(#{recv}) == #{accessor}) {\n" \
                   "    r#{d} = bc2cpp_direct_alloc(M, mrb_class_ptr(#{recv}));\n" \
                   "    #{init_impl}(M, #{(['r' + d] + call_args).join(', ')});\n" \
                   "  } else {\n" \
                   "    #{dynamic_dispatch_line(d, recv, name, argv)}" \
                   "  }\n"
          end
        end
      end
    end

    # GENERIC_OBJECT_CONSTRUCTION: for any stable class constant with the
    # standard Class#new/allocate lookup chain, mruby's public mrb_obj_new is
    # the exact allocate + initialize operation. Unlike the compiled/native
    # specializations above, it keeps #initialize dynamically dispatched, so
    # native initializers and arbitrary initialize bodies retain their behavior.
    # The class-identity guard also rejects a receiver whose register came from
    # another control-flow arm; the trace only proposes `known`.
    # SENDB / keyword sends do not enter this positional compile_send path.
    if name == 'new' && irep && new_target
      known = new_target
      builtin_class_expr = { 'Array' => 'M->array_class',
                             'Hash' => 'M->hash_class',
                             'Range' => 'M->range_class',
                             'String' => 'M->string_class',
                             'NameError' => 'mrb_exc_get_id(M, MRB_SYM(NameError))' }[known]
      generic_constructor_safe = stable_standard_constructor_class?(known) ||
                                 (builtin_class_expr && @closed_world&.standard_constructor_lookup? &&
                                  exact_constructor_chain?(known))
      if known && generic_constructor_safe
        construction = if argv.empty?
                       "    r#{d} = mrb_obj_new(M, mrb_class_ptr(#{recv}), 0, NULL);\n"
                       else
                         "    mrb_value bc2cpp_new_args[] = { #{argv.join(', ')} };\n" +
                           "    r#{d} = mrb_obj_new(M, mrb_class_ptr(#{recv}), #{n}, bc2cpp_new_args);\n"
                       end
        note = "  // MONO :new -> #{known}, generic direct object construction via mrb_obj_new; " +
               "standard Class#new/allocate lookup is proven and #initialize remains ordinary runtime dispatch.\n"
        class_expr = builtin_class_expr || owner_class_ptr_expr(known)
        guard = "mrb_class_p(#{recv}) && mrb_class_ptr(#{recv}) == #{class_expr}"
        return [note, "  if (#{guard}) {\n", construction,
                "  } else {\n", "    #{dynamic_dispatch_line(d, recv, name, argv)}", "  }\n"].join
      end
    end

    # Frame-independent RGSS entry points need only a native class identity
    # guard. Static tracing may narrow the common cases, but is not required for
    # these wrappers because every other receiver retains ordinary dispatch.
    if n.zero? && (helpers = NATIVE_WRAPPER_ZERO_ARG_DIRECT[name])
      owners = helpers.keys.select do |owner|
        native_wrapper_owner_safe?(name, owner)
      end
      unless owners.empty?
        @native_construct_used.merge(owners)
        branches = owners.map do |owner|
          class_accessor = NATIVE_WRAPPER_CLASS_ACCESSORS.fetch(owner)
          helper = helpers.fetch(owner)
          "if (mrb_obj_class(M, #{recv}) == rgss::#{class_accessor}()) {\n" \
            "  r#{d} = rgss::#{helper}(M, #{recv});\n} else "
        end.join
        fallback = compile_poly_small_n(name, d, recv, argv, n,
                                        closed_world_site: closed_world_site(recv, irep, idx || trace_idx, owner_def)) ||
                   dynamic_dispatch_line(d, recv, name, argv)
        return "  // RGSS ##{name} -- exact native class identities select frame independent wrappers\n" \
               "  #{branches}{\n" \
               "#{fallback.lines.map { |line| "  #{line}" }.join}" \
               "  }\n"
      end
    elsif name == 'dispose' && n.zero?
      owners = NATIVE_WRAPPER_DIRECT_OWNERS.fetch(name).select do |owner|
        native_wrapper_owner_safe?(name, owner)
      end
      unless owners.empty?
        class_accessors = {
          'RGSS::Bitmap' => 'native_bitmap_class',
          'RGSS::Sprite' => 'native_sprite_class',
          'RGSS::Viewport' => 'native_viewport_class',
          'RGSS::Plane' => 'native_plane_class',
          'RGSS::Tilemap' => 'native_tilemap_class',
          'RGSS::Window' => 'native_window_class'
        }
        branches = owners.map do |owner|
          function = owner == 'RGSS::Tilemap' ? 'tilemap_dispose_direct' : 'dispose_direct'
          "if (mrb_obj_class(M, #{recv}) == rgss::#{class_accessors.fetch(owner)}()) {\n" \
            "  r#{d} = rgss::#{function}(M, #{recv});\n} else "
        end.join
        fallback = compile_poly_small_n(name, d, recv, argv, n,
                                        closed_world_site: closed_world_site(recv, irep, idx || trace_idx, owner_def)) ||
                   dynamic_dispatch_line(d, recv, name, argv)
        return "  // RGSS #dispose -- captured exact-class registrations select frame-independent native bodies\n" \
               "  #{branches}{\n" \
               "#{fallback.lines.map { |line| "  #{line}" }.join}" \
               "  }\n"
      end
    end

    if name == 'bitmap=' && n == 1 && native_wrapper_owner_safe?(name, 'RGSS::Sprite')
      @native_construct_used << 'RGSS::Sprite'
      return <<~CPP
          // RGSS Sprite#bitmap= -- exact runtime class proves the native wrapper target
          if (mrb_obj_class(M, #{recv}) == rgss::native_sprite_class()) {
            r#{d} = rgss::sprite_bitmap_set_direct(M, #{recv}, #{argv.first});
          } else {
            #{dynamic_dispatch_line(d, recv, name, argv).chomp}
          }
      CPP
    elsif name == 'fill_rect' && n == 5 && native_wrapper_owner_safe?(name, 'RGSS::Bitmap')
      @native_construct_used << 'RGSS::Bitmap'
      return <<~CPP
          // RGSS Bitmap#fill_rect -- exact runtime class proves the native wrapper target
          if (mrb_obj_class(M, #{recv}) == rgss::native_bitmap_class()) {
            r#{d} = rgss::bitmap_fill_rect_direct(M, #{recv},
                #{argv[0]}, #{argv[1]}, #{argv[2]}, #{argv[3]}, #{argv[4]});
          } else {
            #{dynamic_dispatch_line(d, recv, name, argv).chomp}
          }
      CPP
    elsif name == 'blt' && [4, 5].include?(n) && native_wrapper_owner_safe?(name, 'RGSS::Bitmap')
      @native_construct_used << 'RGSS::Bitmap'
      opacity = n == 4 ? 'mrb_fixnum_value(255)' : argv[4]
      opacity_given = n == 5 ? 'TRUE' : 'FALSE'
      return <<~CPP
          // RGSS Bitmap#blt -- exact runtime class proves the native wrapper target
          if (mrb_obj_class(M, #{recv}) == rgss::native_bitmap_class()) {
            r#{d} = rgss::bitmap_blt_direct(M, #{recv},
                #{argv[0]}, #{argv[1]}, #{argv[2]}, #{argv[3]}, #{opacity}, #{opacity_given});
          } else {
            #{dynamic_dispatch_line(d, recv, name, argv).chomp}
          }
      CPP
    elsif name == 'stretch_blt' && [3, 4].include?(n) && native_wrapper_owner_safe?(name, 'RGSS::Bitmap')
      @native_construct_used << 'RGSS::Bitmap'
      opacity = n == 3 ? 'mrb_fixnum_value(255)' : argv[3]
      opacity_given = n == 4 ? 'TRUE' : 'FALSE'
      return <<~CPP
          // RGSS Bitmap#stretch_blt -- exact runtime class proves the native wrapper target
          if (mrb_obj_class(M, #{recv}) == rgss::native_bitmap_class()) {
            r#{d} = rgss::bitmap_stretch_blt_direct(M, #{recv},
                #{argv[0]}, #{argv[1]}, #{argv[2]}, #{opacity}, #{opacity_given});
          } else {
            #{dynamic_dispatch_line(d, recv, name, argv).chomp}
          }
      CPP
    elsif name == 'draw_text' && [2, 3, 5, 6].include?(n) && native_wrapper_owner_safe?(name, 'RGSS::Bitmap')
      @native_construct_used << 'RGSS::Bitmap'
      return <<~CPP
          // RGSS Bitmap#draw_text -- exact runtime class proves the native wrapper target
          if (mrb_obj_class(M, #{recv}) == rgss::native_bitmap_class()) {
            mrb_value bc2cpp_draw_text_args[] = { #{argv.join(', ')} };
            r#{d} = rgss::bitmap_draw_text_direct(M, #{recv}, #{n}, bc2cpp_draw_text_args);
          } else {
            #{dynamic_dispatch_line(d, recv, name, argv).chomp}
          }
      CPP
    elsif name == 'copy_blt' && n == 4 && native_wrapper_owner_safe?(name, 'RGSS::Bitmap')
      @native_construct_used << 'RGSS::Bitmap'
      return <<~CPP
          // RGSS Bitmap#copy_blt -- exact runtime class proves the native wrapper target
          if (mrb_obj_class(M, #{recv}) == rgss::native_bitmap_class()) {
            r#{d} = rgss::bitmap_copy_blt_direct(M, #{recv},
                #{argv[0]}, #{argv[1]}, #{argv[2]}, #{argv[3]});
          } else {
            #{dynamic_dispatch_line(d, recv, name, argv).chomp}
          }
      CPP
    elsif name == 'text_size' && n == 1 && native_wrapper_owner_safe?(name, 'RGSS::Bitmap')
      @native_construct_used << 'RGSS::Bitmap'
      return <<~CPP
          // RGSS Bitmap#text_size -- exact runtime class proves the native wrapper target
          if (mrb_obj_class(M, #{recv}) == rgss::native_bitmap_class()) {
            r#{d} = rgss::bitmap_text_size_direct(M, #{recv}, #{argv.first});
          } else {
            #{dynamic_dispatch_line(d, recv, name, argv).chomp}
          }
      CPP
    end

    # RGSS_NATIVE_BITMAP_SET: spr_set_bmp reads its argument from the active
    # mruby C frame, so direct callers use the frame-independent body and keep
    # the original C wrapper for all ordinary dispatch. The class guard makes
    # a stale or merged receiver trace fall back through normal Ruby lookup.
    if name == 'bitmap=' && n == 1 && !self_implicit && irep && drawing_proof_idx &&
       native_wrapper_owner_safe?(name, 'RGSS::Sprite')
      traced_class = trace_new_target(
        irep, drawing_proof_idx, drawing_proof_reg, drawing_ivar_classes, drawing_mand,
        drawing_arg_classes, owner: owner_def&.owner,
        class_layout: @class_layout, registry: @registry,
        container_constants: @container_constants,
        element_annotations: @element_annotations,
        known_owners: @known_owners, capture_hints: @block_hash_capture_hints,
        method_return_class: ->(method_name) { class_return_for_dispatch(method_name) }
      )
      if traced_class == 'RGSS::Sprite' ||
         UniqueClassNames.resolve(traced_class, owner_def&.owner) == 'RGSS::Sprite'
        @native_construct_used << 'RGSS::Sprite'
        return <<~CPP
            // RGSS Sprite#bitmap= -- frame-independent native body under exact class identity
            if (mrb_obj_class(M, #{recv}) == rgss::native_sprite_class()) {
              r#{d} = rgss::sprite_bitmap_set_direct(M, #{recv}, #{argv.first});
            } else {
              #{dynamic_dispatch_line(d, recv, name, argv).chomp}
            }
        CPP
      end
    end

    if name == 'fill_rect' && n == 5 && !self_implicit && irep && drawing_proof_idx &&
       native_wrapper_owner_safe?(name, 'RGSS::Bitmap')
      traced_class = trace_new_target(
        irep, drawing_proof_idx, drawing_proof_reg, drawing_ivar_classes, drawing_mand,
        drawing_arg_classes, owner: owner_def&.owner,
        class_layout: @class_layout, registry: @registry,
        container_constants: @container_constants,
        element_annotations: @element_annotations,
        known_owners: @known_owners, capture_hints: @block_hash_capture_hints,
        method_return_class: ->(method_name) { class_return_for_dispatch(method_name) }
      )
      if traced_class == 'RGSS::Bitmap' ||
         UniqueClassNames.resolve(traced_class, owner_def&.owner) == 'RGSS::Bitmap'
        @native_construct_used << 'RGSS::Bitmap'
        return <<~CPP
            // RGSS Bitmap#fill_rect(x, y, w, h, color) -- same C-body under exact class identity
            if (mrb_obj_class(M, #{recv}) == rgss::native_bitmap_class()) {
              r#{d} = rgss::bitmap_fill_rect_direct(M, #{recv},
                  #{argv[0]}, #{argv[1]}, #{argv[2]}, #{argv[3]}, #{argv[4]});
            } else {
              #{dynamic_dispatch_line(d, recv, name, argv).chomp}
            }
        CPP
      end
    end

    if name == 'blt' && [4, 5].include?(n) && !self_implicit && irep && drawing_proof_idx &&
       native_wrapper_owner_safe?(name, 'RGSS::Bitmap')
      traced_class = trace_new_target(
        irep, drawing_proof_idx, drawing_proof_reg, drawing_ivar_classes, drawing_mand,
        drawing_arg_classes, owner: owner_def&.owner,
        class_layout: @class_layout, registry: @registry,
        container_constants: @container_constants,
        element_annotations: @element_annotations,
        known_owners: @known_owners, capture_hints: @block_hash_capture_hints,
        method_return_class: ->(method_name) { class_return_for_dispatch(method_name) }
      )
      if traced_class == 'RGSS::Bitmap' ||
         UniqueClassNames.resolve(traced_class, owner_def&.owner) == 'RGSS::Bitmap'
        @native_construct_used << 'RGSS::Bitmap'
        opacity = n == 4 ? 'mrb_fixnum_value(255)' : argv[4]
        opacity_given = n == 5 ? 'TRUE' : 'FALSE'
        return <<~CPP
            // RGSS Bitmap#blt -- preserves mruby integer conversion and optional opacity default
            if (mrb_obj_class(M, #{recv}) == rgss::native_bitmap_class()) {
              r#{d} = rgss::bitmap_blt_direct(M, #{recv},
                  #{argv[0]}, #{argv[1]}, #{argv[2]}, #{argv[3]}, #{opacity},
                  #{opacity_given});
            } else {
              #{dynamic_dispatch_line(d, recv, name, argv).chomp}
            }
        CPP
      end
    end

    if name == 'stretch_blt' && [3, 4].include?(n) && !self_implicit && irep && drawing_proof_idx &&
       native_wrapper_owner_safe?(name, 'RGSS::Bitmap')
      traced_class = trace_new_target(
        irep, drawing_proof_idx, drawing_proof_reg, drawing_ivar_classes, drawing_mand,
        drawing_arg_classes, owner: owner_def&.owner,
        class_layout: @class_layout, registry: @registry,
        container_constants: @container_constants,
        element_annotations: @element_annotations,
        known_owners: @known_owners, capture_hints: @block_hash_capture_hints,
        method_return_class: ->(method_name) { class_return_for_dispatch(method_name) }
      )
      if traced_class == 'RGSS::Bitmap' ||
         UniqueClassNames.resolve(traced_class, owner_def&.owner) == 'RGSS::Bitmap'
        @native_construct_used << 'RGSS::Bitmap'
        opacity = n == 3 ? 'mrb_fixnum_value(255)' : argv[3]
        opacity_given = n == 4 ? 'TRUE' : 'FALSE'
        return <<~CPP
            // RGSS Bitmap#stretch_blt -- exact receiver identity keeps the native body and conversions
            if (mrb_obj_class(M, #{recv}) == rgss::native_bitmap_class()) {
              r#{d} = rgss::bitmap_stretch_blt_direct(M, #{recv},
                  #{argv[0]}, #{argv[1]}, #{argv[2]}, #{opacity}, #{opacity_given});
            } else {
              #{dynamic_dispatch_line(d, recv, name, argv).chomp}
            }
        CPP
      end
    end

    if name == 'draw_text' && [2, 3, 5, 6].include?(n) && !self_implicit && irep && drawing_proof_idx &&
       native_wrapper_owner_safe?(name, 'RGSS::Bitmap')
      traced_class = trace_new_target(
        irep, drawing_proof_idx, drawing_proof_reg, drawing_ivar_classes, drawing_mand,
        drawing_arg_classes, owner: owner_def&.owner,
        class_layout: @class_layout, registry: @registry,
        container_constants: @container_constants,
        element_annotations: @element_annotations,
        known_owners: @known_owners, capture_hints: @block_hash_capture_hints,
        method_return_class: ->(method_name) { class_return_for_dispatch(method_name) }
      )
      if traced_class == 'RGSS::Bitmap' ||
         UniqueClassNames.resolve(traced_class, owner_def&.owner) == 'RGSS::Bitmap'
        @native_construct_used << 'RGSS::Bitmap'
        return <<~CPP
            // RGSS Bitmap#draw_text -- native argument parsing is independent of the caller frame
            if (mrb_obj_class(M, #{recv}) == rgss::native_bitmap_class()) {
              mrb_value bc2cpp_draw_text_args[] = { #{argv.join(', ')} };
              r#{d} = rgss::bitmap_draw_text_direct(M, #{recv}, #{n}, bc2cpp_draw_text_args);
            } else {
              #{dynamic_dispatch_line(d, recv, name, argv).chomp}
            }
        CPP
      end
    end

    if name == 'copy_blt' && n == 4 && !self_implicit && irep && drawing_proof_idx &&
       native_wrapper_owner_safe?(name, 'RGSS::Bitmap')
      traced_class = trace_new_target(
        irep, drawing_proof_idx, drawing_proof_reg, drawing_ivar_classes, drawing_mand,
        drawing_arg_classes, owner: owner_def&.owner,
        class_layout: @class_layout, registry: @registry,
        container_constants: @container_constants,
        element_annotations: @element_annotations,
        known_owners: @known_owners, capture_hints: @block_hash_capture_hints,
        method_return_class: ->(method_name) { class_return_for_dispatch(method_name) }
      )
      if traced_class == 'RGSS::Bitmap' ||
         UniqueClassNames.resolve(traced_class, owner_def&.owner) == 'RGSS::Bitmap'
        @native_construct_used << 'RGSS::Bitmap'
        return <<~CPP
            // RGSS Bitmap#copy_blt -- shared pixel body with wrapper-equivalent conversions
            if (mrb_obj_class(M, #{recv}) == rgss::native_bitmap_class()) {
              r#{d} = rgss::bitmap_copy_blt_direct(M, #{recv},
                  #{argv[0]}, #{argv[1]}, #{argv[2]}, #{argv[3]});
            } else {
              #{dynamic_dispatch_line(d, recv, name, argv).chomp}
            }
        CPP
      end
    end

    if name == 'text_size' && n == 1 && !self_implicit &&
       native_wrapper_owner_safe?(name, 'RGSS::Bitmap')
      @native_construct_used << 'RGSS::Bitmap'
      return <<~CPP
          // RGSS Bitmap#text_size -- exact native class guard is sufficient without a static receiver fact
          if (mrb_obj_class(M, #{recv}) == rgss::native_bitmap_class()) {
            r#{d} = rgss::bitmap_text_size_direct(M, #{recv}, #{argv.first});
          } else {
            #{dynamic_dispatch_line(d, recv, name, argv).chomp}
          }
      CPP
    end

    if %w[openness= tone= opacity=].include?(name) && n == 1 && !self_implicit && irep && drawing_proof_idx
      traced_class = trace_new_target(
        irep, drawing_proof_idx, drawing_proof_reg, drawing_ivar_classes, drawing_mand,
        drawing_arg_classes, owner: owner_def&.owner,
        class_layout: @class_layout, registry: @registry,
        container_constants: @container_constants,
        element_annotations: @element_annotations,
        known_owners: @known_owners, capture_hints: @block_hash_capture_hints,
        method_return_class: ->(method_name) { class_return_for_dispatch(method_name) }
      )
      if %w[openness= tone=].include?(name) &&
         (traced_class == 'RGSS::Window' ||
          UniqueClassNames.resolve(traced_class, owner_def&.owner) == 'RGSS::Window') &&
         native_wrapper_owner_safe?(name, 'RGSS::Window')
        @native_construct_used << 'RGSS::Window'
        direct = name == 'openness=' ? 'window_openness_set_direct' : 'window_tone_set_direct'
        return <<~CPP
            // RGSS Window##{name} -- frame-independent native body under exact class identity
            if (mrb_obj_class(M, #{recv}) == rgss::native_window_class()) {
              r#{d} = rgss::#{direct}(M, #{recv}, #{argv.first});
            } else {
              #{dynamic_dispatch_line(d, recv, name, argv).chomp}
            }
        CPP
      end
      if %w[opacity= tone=].include?(name) &&
         (traced_class == 'RGSS::Sprite' ||
          UniqueClassNames.resolve(traced_class, owner_def&.owner) == 'RGSS::Sprite') &&
         native_wrapper_owner_safe?(name, 'RGSS::Sprite')
        @native_construct_used << 'RGSS::Sprite'
        direct = name == 'opacity=' ? 'sprite_opacity_set_direct' : 'sprite_tone_set_direct'
        return <<~CPP
            // RGSS Sprite##{name} -- frame-independent native body under exact class identity
            if (mrb_obj_class(M, #{recv}) == rgss::native_sprite_class()) {
              r#{d} = rgss::#{direct}(M, #{recv}, #{argv.first});
            } else {
              #{dynamic_dispatch_line(d, recv, name, argv).chomp}
            }
        CPP
      end
      if name == 'tone=' &&
         (traced_class == 'RGSS::Viewport' ||
          UniqueClassNames.resolve(traced_class, owner_def&.owner) == 'RGSS::Viewport') &&
         native_wrapper_owner_safe?(name, 'RGSS::Viewport')
        @native_construct_used << 'RGSS::Viewport'
        return <<~CPP
            // RGSS Viewport#tone= -- frame-independent native body under exact class identity
            if (mrb_obj_class(M, #{recv}) == rgss::native_viewport_class()) {
              r#{d} = rgss::viewport_tone_set_direct(M, #{recv}, #{argv.first});
            } else {
              #{dynamic_dispatch_line(d, recv, name, argv).chomp}
            }
        CPP
      end
    end

    if name == 'opacity=' && n == 1 && !self_implicit &&
       native_wrapper_owner_safe?(name, 'RGSS::Sprite')
      @native_construct_used << 'RGSS::Sprite'
      return <<~CPP
          // RGSS Sprite#opacity= -- exact runtime class identity proves the native wrapper target
          if (mrb_obj_class(M, #{recv}) == rgss::native_sprite_class()) {
            r#{d} = rgss::sprite_opacity_set_direct(M, #{recv}, #{argv.first});
          } else {
            #{dynamic_dispatch_line(d, recv, name, argv).chomp}
          }
      CPP
    end

    if name == 'tone=' && n == 1 && !self_implicit
      tone_targets = [
        ['RGSS::Sprite', 'native_sprite_class', 'sprite_tone_set_direct'],
        ['RGSS::Window', 'native_window_class', 'window_tone_set_direct'],
        ['RGSS::Viewport', 'native_viewport_class', 'viewport_tone_set_direct']
      ].select { |owner, _class_fn, _direct| native_wrapper_owner_safe?(name, owner) }
      unless tone_targets.empty?
        tone_targets.each { |owner, _class_fn, _direct| @native_construct_used << owner }
        branches = tone_targets.map.with_index do |(_owner, class_fn, direct), i|
          keyword = i.zero? ? 'if' : 'else if'
          <<~CPP.chomp
            #{keyword} (mrb_obj_class(M, #{recv}) == rgss::#{class_fn}()) {
              r#{d} = rgss::#{direct}(M, #{recv}, #{argv.first});
            }
          CPP
        end.join(' ')
        return <<~CPP
            // RGSS tone setters -- exact runtime class identity selects a registered native body
            #{branches} else {
              #{dynamic_dispatch_line(d, recv, name, argv).chomp}
            }
        CPP
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

    if name == 'to_s' && n.zero? && !devirt_blocked_name?(name) &&
       builtin_class_send_safe?(name, %w[Array Hash Integer String]) &&
       builtin_class_send_safe?('inspect', %w[Array Hash])
      return compile_native_primitive_send(name, d, recv, argv)
    end

    # TO_I_BUILTIN_TYPE_TAG_DISPATCH: the native registry has class-specific
    # to_i entries, while compile_native_primitive_send checks each runtime tag
    # and keeps ordinary dispatch for receiver types it does not implement.
    if name == 'to_i' && n.zero? &&
       builtin_class_send_safe?(name, %w[Integer Float String])
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

    if (expected_n = NATIVE_PRIMITIVE_SEND_ARITY[name]) && n == expected_n && ownerless_native_dispatch_safe?(name) &&
       (!@native_registered_expressions.key?(name) || name == 'to_s')
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
    module_function_self = false
    lexical_self_ivar_accessor = nil
    if target.nil? && self_implicit
      module_target = lexical_module_function_self_target(name, owner_def)
      if module_target&.irep && pure_mandatory_or_optional_arity?(@ireps.fetch(module_target.irep)) &&
         compiles_clean?(module_target.irep) &&
         n.between?(mandatory_arity(@ireps.fetch(module_target.irep)),
                    mandatory_arity(@ireps.fetch(module_target.irep)) + optional_arity(@ireps.fetch(module_target.irep))) &&
         native_arg_types(module_target, n).compact.empty?
        target = module_target
        module_function_self = true
      end
      lex_owner = lexical_self_owner(owner_def)
      # SINGLETON_LEXICAL_SELF: only the irep branch below; accessors stay dynamic.
      singleton_candidate = lex_owner.nil? && lexical_self_singleton_def(name, owner_def)
      if target.nil? && (lex_owner || singleton_candidate)
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
    inherited_typed = false
    exact_class_dispatch = false
    typed_guard_class = nil
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
                                      container_constants: @container_constants,
                                      element_annotations: @element_annotations,
                                      known_owners: @known_owners,
                                      capture_hints: @block_hash_capture_hints,
                                      method_return_class: ->(method_name) { class_return_for_dispatch(method_name) })
      exact_class = known_class && exact_new_receiver_class(irep, proof_idx, proof_reg,
                                                            owner: owner_def&.owner,
                                                            expected_class: known_class)
      if exact_class
        exact_target = closed_world_exact_target(name, exact_class)
        if exact_target&.irep && pure_mandatory_or_optional_arity?(@ireps.fetch(exact_target.irep)) &&
           compiles_clean?(exact_target.irep) &&
           n.between?(mandatory_arity(@ireps.fetch(exact_target.irep)),
                      mandatory_arity(@ireps.fetch(exact_target.irep)) + optional_arity(@ireps.fetch(exact_target.irep)))
          target = exact_target
          typed = true
          exact_class_dispatch = true
          typed_guard_class = exact_class
        end
      end
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
        typed_guard_class = known_class
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
      if target.nil? && !ivar_accessor_target
        inherited = closed_world_inherited_target(name, known_class)
        if inherited&.irep && pure_mandatory_or_optional_arity?(@ireps.fetch(inherited.irep)) &&
           compiles_clean?(inherited.irep) &&
           n.between?(mandatory_arity(@ireps.fetch(inherited.irep)),
                      mandatory_arity(@ireps.fetch(inherited.irep)) + optional_arity(@ireps.fetch(inherited.irep)))
          target = inherited
          typed = true
          inherited_typed = true
          typed_guard_class = known_class
        end
      end
    end
    # A target whose owner this run does not emit (ONLY_OWNERS) has no `_impl`
    # here (LCF::File#to_lcf calling LCF.write_ber would fail to link), so use
    # dynamic dispatch, unless another gem emits it (@other_owners; see
    # emit_decls_header).
    if target && @only_owners && !@only_owners.include?(target.owner)
      copied_owner = "#{target.owner}.singleton"
      module_function_emitted = @only_owners.include?(copied_owner) &&
                                (@registry[target.name] || []).any? do |definition|
                                  definition.kind == :module_function && definition.owner == copied_owner &&
                                    definition.copy_owner == target.owner && definition.copy_irep == target.irep
                                end
      target = nil unless @other_owners&.include?(target.owner) || module_function_emitted
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
        if exact_class_dispatch
          note = "  // CLOSED_WORLD_EXACT_CLASS :#{name} -> #{target.owner}##{target.name} " \
                 "(fresh #{typed_guard_class}.new; stable class constant and standard constructor), " \
                 "closed-world lookup, direct C++ call with no guard or mrb_funcall fallback#{native_note}\n"
          return "#{note}  r#{d} = #{impl}(M, #{([recv] + call_argv).join(', ')});\n"
        end

        check_owner = typed_guard_class || target.owner
        check = "#{owner_class_ptr_expr(check_owner)} == mrb_obj_class(M, #{recv})"
        # ELEMENT_CLASS_SUPPORT: the tag records which fact proved the receiver.
        kind = inherited_typed ? 'CLOSED_WORLD_TYPED_INHERITED' : (via_element ? 'ELEMENT' : 'TYPED')
        traced_note = if inherited_typed
                        "receiver traced to #{check_owner}; closed-world lookup proves inherited #{target.owner}##{target.name}"
                      elsif via_element
                        "inlined block element of Array<#{target.owner}>"
                      else
                        "receiver traced to #{target.owner}"
                      end
        note = "  // #{kind} :#{name} -> #{target.owner}##{target.name} (#{traced_note}), " \
               "runtime-class-checked direct C++ call, mrb_funcall fallback#{native_note}\n"
        fallback = typed_fallback ||
                   guarded_fallback_line(d, recv, name, argv, [check_owner],
                                         closed_world_site(recv, irep, idx, owner_def))
        "#{note}  if (#{check}) {\n" \
          "    r#{d} = #{impl}(M, #{([recv] + call_argv).join(', ')});\n" \
          "  } else {\n" \
          "    #{fallback}" \
          "  }\n"
      elsif module_function_self
        note = "  // MODULE_FUNCTION_SELF :#{name} -> #{target.owner}.singleton##{target.name} " \
               "(the compiled source body runs with its module object as self), direct C++ call " \
               "(no mrb_funcall, no runtime check)#{native_note}\n"
        "#{note}  r#{d} = #{impl}(M, #{([recv] + call_argv).join(', ')});\n"
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
      if builtin_native_expression_send
        exact_entry = if exact_class && known_class
                        native_expression_entries.find do |entry|
                          entry[:owner][:class_name] == known_class && entry[:arity] == argv.length
                        end
                      end
        if exact_entry
          expression = exact_entry[:expression].gsub('recv', recv)
          expression = expression.gsub('BC2CPP_ARG0', argv.fetch(0)) if exact_entry[:arity] == 1
          return "  // CLOSED_WORLD_NATIVE_EXACT :#{name} -> #{known_class} native body; " \
                 "fresh exact-class receiver, no dispatch fallback\n" \
                 "  r#{d} = #{expression};\n"
        end

        return compile_native_primitive_send(name, d, recv, argv)
      end

      if !self_implicit && irep && idx && @closed_world &&
         %w[SEND0 SEND SSEND0 SSEND].include?(irep.instructions[idx].op)
        constant_owner = constant_object_owner(irep, idx,
                                               unshift_proof_reg(trace_receiver_reg || d, trace_reg_offset),
                                               owner_def&.owner)
        singleton_owner = "#{constant_owner}.singleton" if constant_owner
        singleton_defs = @registry[name]&.select { |md| md.owner == singleton_owner } if singleton_owner
        candidate = singleton_defs&.one? ? singleton_defs.first : nil
        copied_module_function = candidate&.kind == :module_function
        candidate_label = candidate&.irep || (candidate.copy_irep if copied_module_function)
        candidate_irep = candidate_label && @ireps.fetch(candidate_label)
        target = if copied_module_function
                   @registry[name]&.find do |md|
                     md.owner == candidate.copy_owner && md.irep == candidate.copy_irep
                   end
                 else
                   candidate
                 end
        if candidate && candidate_irep && candidate.visibility == :public && !devirt_blocked_name?(name) &&
           Array(@included_modules[singleton_owner]).empty? && Array(@prepended_modules[singleton_owner]).empty? &&
           !@unknown_mixins.include?(singleton_owner) && pure_mandatory_arity?(candidate_irep) &&
           mandatory_arity(candidate_irep) == n && !hot_only_excluded?(candidate_label) &&
           constant_object_candidate_clean?(candidate_label) &&
           (!copied_module_function || module_function_copy_self_safe?(candidate_irep)) &&
           target &&
           native_arg_types(target, n).compact.empty? &&
           (!@only_owners || @only_owners.include?(singleton_owner) || @other_owners&.include?(singleton_owner))
          impl = cpp_name(target.owner, target.name) + '_impl'
          via = copied_module_function ? "module_function copy of #{target.owner}##{target.name}" : "#{candidate.owner}##{candidate.name}"
          note = "  // CLOSED_WORLD_CONSTANT_OBJECT :#{name} -> #{via} " \
                 "(stable class/module constant, unique public singleton definition), direct C++ call " \
                 "without mrb_funcall.\n"
          return "#{note}  r#{d} = #{impl}(M, #{([recv] + argv).join(', ')});\n"
        end
      end

      cw_site = closed_world_site(recv, irep, idx, owner_def)
      poly = compile_poly_small_n(name, d, recv, argv, n, closed_world_site: cw_site) ||
             compile_poly_table(name, d, recv, argv, n, closed_world_site: cw_site)
      return poly if poly

      candidates = poly_candidates(name, n) || []
      definitions = @registry[name] || []
      lone_accessor = definitions.size == 1 && definitions.first.kind == :ivar_accessor && definitions.first.irep.nil?
      path = if devirt_blocked_name?(name)
               'dynamic_runtime_definition_guard'
             elsif definitions.empty?
               'dynamic_no_registered_definition'
             elsif definitions.size < 2 && !lone_accessor
               'dynamic_single_registered_definition'
             elsif candidates.size > POLY_TABLE_MAX
               'dynamic_candidate_limit'
             elsif candidates.size > POLY_SMALL_N_MAX &&
                   candidates.reject { |candidate| candidate.kind == :ivar_accessor && candidate.irep.nil? }.size <= POLY_SMALL_N_MAX
               'dynamic_table_threshold'
             else
               'dynamic_no_complete_candidate_set'
             end
      receiver_fact = if self_implicit
                        'implicit_self_unresolved'
                      elsif via_element
                        'element_class_hint'
                      elsif known_class
                        'traced_class_no_direct_target'
                      elsif idx || trace_idx
                        'receiver_class_unresolved'
                      else
                        'receiver_class_unavailable'
                      end
      receiver_origin = if receiver_fact == 'receiver_class_unresolved'
                          receiver_trace_origin(irep, idx || trace_idx,
                                               unshift_proof_reg(trace_receiver_reg || d, trace_reg_offset))
                        end
      diag = poly_diagnostic(name, n, path, candidates, receiver: receiver_fact, origin: receiver_origin)
      note = "  // POLY :#{name} -- real dynamic dispatch, receiver's runtime class decides\n"
      "#{diag}#{note}  #{dynamic_dispatch_line(d, recv, name, argv)}"
    end
  end

  # Prove the first implementation in a receiver's inherited lookup chain. An
  # exact runtime class guard handles subclasses; this proof only needs a stable
  # receiver constant and a complete, mixin-free chain up to the defining owner.
  def closed_world_inherited_target(name, receiver_class)
    return nil unless @closed_world&.inherited_lookup_safe?(name, receiver_class)
    return nil if devirt_blocked_name?(name)

    target, known = closed_world_lookup_target(name, receiver_class, Set.new)
    known && target&.owner != receiver_class ? target : nil
  end

  # Follow the proven mruby ancestor order: prepended modules, the owner,
  # included modules (latest include first), then the superclass. An unknown or
  # unstable mixin before the first definition makes the lookup ambiguous.
  def closed_world_lookup_target(name, owner, active)
    return [nil, false] unless active.add?(owner)
    return [nil, false] if @unknown_mixins.include?(owner)

    Array(@prepended_modules[owner]).reverse.each do |mod|
      return [nil, false] unless @closed_world.stable_constant_identity?(mod)

      target, known = closed_world_lookup_target(name, mod, active.dup)
      return [nil, false] unless known
      return [target, true] if target
    end

    definitions = @registry.fetch(name, []).select { |definition| definition.owner == owner }
    unless definitions.empty?
      return [nil, false] unless definitions.one? && definitions.first.irep && definitions.first.visibility == :public

      return [definitions.first, true]
    end

    # Included modules follow the class's own methods, so check them after the
    # owner before advancing to its superclass.
    Array(@included_modules[owner]).reverse.each do |mod|
      return [nil, false] unless @closed_world.stable_constant_identity?(mod)

      target, known = closed_world_lookup_target(name, mod, active.dup)
      return [nil, false] unless known
      return [target, true] if target
    end

    superclass = @superclass_of[owner]
    superclass = 'Object' if superclass == :none && owner != 'Object'
    return [nil, true] if superclass.nil?

    closed_world_lookup_target(name, superclass, active)
  end

  # Exact-instance counterpart to closed_world_inherited_target: the receiver
  # is a proven fresh instance, so its own class method may be selected too.
  def closed_world_exact_target(name, receiver_class)
    return nil unless @closed_world&.inherited_lookup_safe?(name, receiver_class)
    return nil if devirt_blocked_name?(name)

    klass = receiver_class
    seen = Set.new
    loop do
      return nil unless seen.add?(klass)
      return nil if @unknown_mixins.include?(klass) || !Array(@included_modules[klass]).empty? ||
                    !Array(@prepended_modules[klass]).empty?

      here = @registry.fetch(name, []).select { |definition| definition.owner == klass }
      unless here.empty?
        return here.one? && here.first.irep ? here.first : nil
      end

      superclass = @superclass_of[klass]
      return nil if superclass.nil? || superclass == :none

      klass = superclass
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
