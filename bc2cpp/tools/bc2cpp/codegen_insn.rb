# frozen_string_literal: true

# CodeGen: compile_insn and comparisons.

class CodeGen
  # `idx` is the instruction's position in irep.instructions (for the backward
  # proofs). `reg_offset` is non-zero only for compile_block_body_insn's shifted
  # registers and is undone with unshift_proof_reg wherever a register reaches a
  # proof rather than the output.
  def compile_insn(insn, irep, owner_def, idx = nil, reg_offset = 0)
    a = insn.args
    case insn.op
    when 'ENTER'
      "  // #{insn.raw.strip} (args already bound above)\n"
    when 'GETUPVAR', 'SETUPVAR'
      # UPVAR_CAPTURE_SUPPORT: only reached inside a BLOCK_FALLBACK body
      # (@block_fallback_upvars set for that loop); method ireps have no
      # GETUPVAR/SETUPVAR, and inlined block bodies use compile_block_body_insn.
      # `GETUPVAR R3 4 0`: `upvar_idx` is the defining frame's register (vm.c
      # `e->stack[b]`).
      # DEEP_UPVAR_CAPTURE_SUPPORT: matched on the [level, index] pair against the
      # captured set this function declares parameters for; anything else keeps
      # `#error`. The access is the same at every level: an mrb_value* to the
      # defining frame's register.
      reg, upvar_idx, level = a.split(/\s+/)
      key = [level.to_i, upvar_idx.to_i]
      if level =~ /\A\d+\z/ && @block_fallback_upvars&.include?(key)
        vname = upvar_var_name(*key)
        if insn.op == 'GETUPVAR'
          "  r#{reg[/\d+/]} = *#{vname};\n"
        else
          "  *#{vname} = r#{reg[/\d+/]};\n"
        end
      else
        "  #error unhandled opcode #{insn.op} -- not in this prototype's supported subset\n"
      end
    when 'KEY_P'
      # KEYWORD_ARG_SUPPORT: presence of an optional keyword: a bool parameter the
      # entry wrapper computed, named from `:sym` (kwarg_param_name).
      d = a[/^R(\d+)/, 1]
      sym = a[/:(\S+)/, 1]
      "  r#{d} = mrb_bool_value(#{kw_given_param_name(sym)});\n"
    when 'KARG'
      # KEYWORD_ARG_SUPPORT: the keyword's value, already an unpacked parameter. An
      # omitted optional one's default code overwrites the register after KEY_P's
      # JMPIF.
      d = a[/^R(\d+)/, 1]
      sym = a[/:(\S+)/, 1]
      "  r#{d} = #{kwarg_param_name(sym)};\n"
    when 'KEYEND'
      # KEYWORD_ARG_SUPPORT: unknown keywords already raised ArgumentError in the
      # entry wrapper's mrb_kwargs (`rest: NULL`).
      "  // KEYEND: already enforced by the entry wrapper's own mrb_kwargs (rest: NULL)\n"
    when 'MOVE'
      d, s = regs(a, 2)
      "  r#{d} = r#{s};\n"
    when 'LOADNIL'
      d, = regs(a, 1)
      "  r#{d} = mrb_nil_value();\n"
    when 'LOADFALSE'
      d, = regs(a, 1)
      "  r#{d} = mrb_false_value();\n"
    when 'LOADTRUE'
      d, = regs(a, 1)
      "  r#{d} = mrb_true_value();\n"
    when 'LOADSELF'
      # "LOADSELF R2 (R0)": R[a] = self (vm.c). Emitted for `self.foo = ...`; r0 is
      # already `self`.
      d, = regs(a, 1)
      "  r#{d} = self;\n"
    when 'LOADSYM'
      d = a[/^R(\d+)/, 1]
      name = a[/:(\S+)/, 1]
      "  r#{d} = mrb_symbol_value(mrb_intern_cstr(M, \"#{name}\"));\n"
    when /^LOADI/
      d = a[/^R(\d+)/, 1]
      # Small immediates print parenthesized ("R6\t(3)"); LOADI8/16/32 print bare
      # ("R1\t128").
      lit = a[/\(([^)]+)\)/, 1] || a[/^R\d+\s+(-?\d+)/, 1]
      "  r#{d} = mrb_fixnum_value(#{lit});\n"
    when 'LOADL'
      # "LOADL R5 L[0]": a pool literal (vm.c OP_LOADL). Only FLOAT is modelled:
      # mrbc's C dump prints it as a valid C double literal (".f=0.33000000000000002").
      # INT32/INT64/BIGINT are not decoded and keep `#error`.
      d = a[/^R(\d+)/, 1]
      pidx = a[/L\[(\d+)\]/, 1].to_i
      entry = irep.pool.fetch(pidx)
      if entry.is_a?(Hash) && entry[:type] == :float
        lit = entry[:raw][/\.f\s*=\s*(.+)/, 1]
        "  r#{d} = mrb_float_value(M, #{lit});\n"
      else
        kind = entry.is_a?(Hash) ? entry[:type] : :string
        "  #error LOADL references a non-float pool entry (#{kind}) -- not in this prototype's supported subset\n"
      end
    when 'STRING'
      d = a[/^R(\d+)/, 1]
      idx = a[/L\[(\d+)\]/, 1].to_i
      entry = irep.pool.fetch(idx)
      if entry.is_a?(String)
        "  r#{d} = mrb_str_new_cstr(M, #{c_string_literal(entry)});\n"
      else
        "  #error STRING references a non-string pool entry (#{entry[:type]}) -- not in this prototype's supported subset\n"
      end
    when 'SYMBOL'
      # "SYMBOL R2 L[0] ; atk_mod": ops.h `R[a] = intern(Pool[b])`, unlike LOADSYM,
      # which carries an interned symbol. Same `L[idx]` pool read as STRING
      # (codedump.c), interned with mrb_intern_cstr. mrbc emits it for `%i[...]`
      # literals (gen_literal_array: each word is an OP_STRING that gen_intern's
      # peephole turns into SYMBOL, followed by ARRAY(N)); `:foo` / `:"foo"` are
      # interned at parse time into LOADSYM.
      d = a[/^R(\d+)/, 1]
      sidx = a[/L\[(\d+)\]/, 1].to_i
      sentry = irep.pool.fetch(sidx)
      if sentry.is_a?(String)
        "  r#{d} = mrb_symbol_value(mrb_intern_cstr(M, #{c_string_literal(sentry)}));\n"
      else
        "  #error SYMBOL references a non-string pool entry (#{sentry[:type]}) -- not in this prototype's supported subset\n"
      end
    when 'INTERN'
      # "INTERN R<a>": vm.c `mrb_ensure_string_type(mrb, regs[a]); mrb_sym sym =
      # mrb_intern_str(mrb, regs[a]); regs[a] = mrb_symbol_value(sym);`, an in-place
      # String -> Symbol conversion (`:"#{expr}"`). Unconditional, like STRCAT.
      d = a[/^R(\d+)/, 1]
      "  r#{d} = mrb_ensure_string_type(M, r#{d});\n  r#{d} = mrb_symbol_value(mrb_intern_str(M, r#{d}));\n"
    when 'STRCAT'
      # Matches OP_STRCAT's own real semantics exactly (src/vm.c):
      # mrb_ensure_string_type then mrb_str_concat (mutates r<d> in place).
      d = a[/^R(\d+)/, 1]
      s = a[/\(R(\d+)\)/, 1]
      "  r#{d} = mrb_ensure_string_type(M, r#{d});\n  mrb_str_concat(M, r#{d}, r#{s});\n"
    when 'GETIV'
      d = a[/^R(\d+)/, 1]
      ivar = a[/@(\w+)/, 1]
      klass = self_class(owner_def)
      code = ivar_get_code(klass, 'self', ivar, "r#{d}", self_of_klass: true)
      type = embed_type(klass, ivar) if klass
      if code.nil?
        "  #error GETIV @#{ivar}: self's class is unknown here and some class embeds @#{ivar}\n"
      elsif type
        "  // @#{ivar} embedded (#{type}) -- direct struct field read, no mrb_iv_get\n  #{code}\n"
      else
        "  #{code}\n"
      end
    when 'SETIV'
      ivar = a[/@(\w+)/, 1]
      # Not `$`-anchored: a trailing "; R1:name" comment (see IvarLayout.analyze).
      s = a[/R(\d+)/, 1]
      klass = self_class(owner_def)
      code = ivar_set_code(klass, 'self', ivar, "r#{s}", self_of_klass: true)
      type = embed_type(klass, ivar) if klass
      if code.nil?
        "  #error SETIV @#{ivar}: self's class is unknown here and some class embeds @#{ivar}\n"
      elsif type
        "  // @#{ivar} embedded (#{type}) -- direct struct field write, no mrb_iv_set\n  #{code}\n"
      else
        "  #{code}\n"
      end
    when 'ADDI'
      d = a[/^R(\d+)/, 1]
      lit = a.split(/\s+/).last
      # FIXNUM_OPERAND_PROOF: the immediate is a Fixnum, so only the destination
      # needs proving.
      if proven_fixnum_operand?(irep, idx, unshift_proof_reg(d, reg_offset), owner_def)
        "#{FIXNUM_PROOF_NOTE}  r#{d} = mrb_fixnum_value(mrb_fixnum(r#{d}) + #{lit});\n"
      else
        <<~CPP
          if (mrb_integer_p(r#{d})) {
            r#{d} = mrb_fixnum_value(mrb_fixnum(r#{d}) + #{lit});
          } else {
            #{compile_operator_fallback('+', d, nil, "mrb_fixnum_value(#{lit})", irep, idx, owner_def, reg_offset)}
          }
        CPP
      end
    when 'ADD'
      d = a[/^R(\d+)/, 1]
      s = a[/\(R(\d+)\)/, 1]
      if proven_fixnum_pair?(irep, idx, unshift_proof_reg(d, reg_offset), unshift_proof_reg(s, reg_offset), owner_def)
        "#{FIXNUM_PROOF_NOTE}  r#{d} = mrb_fixnum_value(mrb_fixnum(r#{d}) + mrb_fixnum(r#{s}));\n"
      else
        <<~CPP
          if (mrb_fixnum_p(r#{d}) && mrb_fixnum_p(r#{s})) {
            r#{d} = mrb_fixnum_value(mrb_fixnum(r#{d}) + mrb_fixnum(r#{s}));
          #ifndef MRB_NO_FLOAT
          } else if (mrb_float_p(r#{d}) && mrb_integer_p(r#{s})) {
            r#{d} = mrb_float_value(M, mrb_float(r#{d}) + mrb_integer(r#{s}));
          } else if (mrb_integer_p(r#{d}) && mrb_float_p(r#{s})) {
            r#{d} = mrb_float_value(M, mrb_integer(r#{d}) + mrb_float(r#{s}));
          } else if (mrb_float_p(r#{d}) && mrb_float_p(r#{s})) {
            r#{d} = mrb_float_value(M, mrb_float(r#{d}) + mrb_float(r#{s}));
          #endif
          } else {
            #{compile_operator_fallback('+', d, s, nil, irep, idx, owner_def, reg_offset)}
          }
        CPP
      end
    when 'SUBI'
      d = a[/^R(\d+)/, 1]
      lit = a.split(/\s+/).last
      if proven_fixnum_operand?(irep, idx, unshift_proof_reg(d, reg_offset), owner_def)
        "#{FIXNUM_PROOF_NOTE}  r#{d} = mrb_fixnum_value(mrb_fixnum(r#{d}) - #{lit});\n"
      else
        <<~CPP
          if (mrb_integer_p(r#{d})) {
            r#{d} = mrb_fixnum_value(mrb_fixnum(r#{d}) - #{lit});
          } else {
            #{compile_operator_fallback('-', d, nil, "mrb_fixnum_value(#{lit})", irep, idx, owner_def, reg_offset)}
          }
        CPP
      end
    when 'SUB'
      d = a[/^R(\d+)/, 1]
      s = a[/\(R(\d+)\)/, 1]
      if proven_fixnum_pair?(irep, idx, unshift_proof_reg(d, reg_offset), unshift_proof_reg(s, reg_offset), owner_def)
        "#{FIXNUM_PROOF_NOTE}  r#{d} = mrb_fixnum_value(mrb_fixnum(r#{d}) - mrb_fixnum(r#{s}));\n"
      else
        <<~CPP
          if (mrb_fixnum_p(r#{d}) && mrb_fixnum_p(r#{s})) {
            r#{d} = mrb_fixnum_value(mrb_fixnum(r#{d}) - mrb_fixnum(r#{s}));
          #ifndef MRB_NO_FLOAT
          } else if (mrb_float_p(r#{d}) && mrb_integer_p(r#{s})) {
            r#{d} = mrb_float_value(M, mrb_float(r#{d}) - mrb_integer(r#{s}));
          } else if (mrb_integer_p(r#{d}) && mrb_float_p(r#{s})) {
            r#{d} = mrb_float_value(M, mrb_integer(r#{d}) - mrb_float(r#{s}));
          } else if (mrb_float_p(r#{d}) && mrb_float_p(r#{s})) {
            r#{d} = mrb_float_value(M, mrb_float(r#{d}) - mrb_float(r#{s}));
          #endif
          } else {
            #{compile_operator_fallback('-', d, s, nil, irep, idx, owner_def, reg_offset)}
          }
        CPP
      end
    when 'MUL'
      # Same shape as ADD/SUB: vm.c OP_ADD/OP_SUB/OP_MUL all expand OP_MATH, so MUL
      # differs only in operator and fallback name.
      d = a[/^R(\d+)/, 1]
      s = a[/\(R(\d+)\)/, 1]
      if proven_fixnum_pair?(irep, idx, unshift_proof_reg(d, reg_offset), unshift_proof_reg(s, reg_offset), owner_def)
        "#{FIXNUM_PROOF_NOTE}  r#{d} = mrb_fixnum_value(mrb_fixnum(r#{d}) * mrb_fixnum(r#{s}));\n"
      else
        <<~CPP
          if (mrb_fixnum_p(r#{d}) && mrb_fixnum_p(r#{s})) {
            r#{d} = mrb_fixnum_value(mrb_fixnum(r#{d}) * mrb_fixnum(r#{s}));
          #ifndef MRB_NO_FLOAT
          } else if (mrb_float_p(r#{d}) && mrb_integer_p(r#{s})) {
            r#{d} = mrb_float_value(M, mrb_float(r#{d}) * mrb_integer(r#{s}));
          } else if (mrb_integer_p(r#{d}) && mrb_float_p(r#{s})) {
            r#{d} = mrb_float_value(M, mrb_integer(r#{d}) * mrb_float(r#{s}));
          } else if (mrb_float_p(r#{d}) && mrb_float_p(r#{s})) {
            r#{d} = mrb_float_value(M, mrb_float(r#{d}) * mrb_float(r#{s}));
          #endif
          } else {
            #{compile_operator_fallback('*', d, s, nil, irep, idx, owner_def, reg_offset)}
          }
        CPP
      end
    when 'DIV'
      # DIV_FASTPATH_SUPPORT: Integer#/ floors (not C's truncation). int_div
      # (src/numeric.c) calls mrb_div_int_value(mrb, mrb_integer(x), mrb_integer(y))
      # for Integer/Integer, so calling it here reproduces the rounding and the
      # ZeroDivisionError/overflow raises exactly. Declared `extern "C"` like
      # mrb_str_aref (mruby/internal.h has no C-linkage guard). Same fixnum/fixnum
      # guard as ADD/SUB/MUL, mrb_funcall otherwise.
      d = a[/^R(\d+)/, 1]
      s = a[/\(R(\d+)\)/, 1]
      if proven_fixnum_pair?(irep, idx, unshift_proof_reg(d, reg_offset), unshift_proof_reg(s, reg_offset), owner_def)
        "#{FIXNUM_PROOF_NOTE}  r#{d} = mrb_div_int_value(M, mrb_fixnum(r#{d}), mrb_fixnum(r#{s}));\n"
      else
        <<~CPP
          if (mrb_fixnum_p(r#{d}) && mrb_fixnum_p(r#{s})) {
            r#{d} = mrb_div_int_value(M, mrb_fixnum(r#{d}), mrb_fixnum(r#{s}));
          } else {
            #{compile_operator_fallback('/', d, s, nil, irep, idx, owner_def, reg_offset)}
          }
        CPP
      end
    when 'EQ', 'LT', 'LE', 'GT', 'GE'
      compile_cmp(insn.op, a, irep, idx, owner_def, reg_offset)
    # BLOCK_BODY_INDEX_SUPPORT: compile_send keeps `idx` nil inside shifted block
    # bodies: its other scans derive r<d>..r<d+n> windows from `args`, and two of
    # them (compile_keyword_send, compile_splat_send) print register lists back
    # into the output, which would need re-shifting. trace_new_target needs only
    # the receiver register and index, both safely unshiftable, so it alone gets
    # the separate `trace_idx`/offset context.
    when 'SEND0', 'SEND'
      compile_send(a, self_implicit: false, irep: irep, idx: reg_offset.zero? ? idx : nil, owner_def: owner_def,
                   trace_idx: idx, trace_reg_offset: reg_offset)
    when 'SSEND0', 'SSEND'
      compile_send(a, self_implicit: true, irep: irep, idx: reg_offset.zero? ? idx : nil, owner_def: owner_def,
                   trace_idx: idx, trace_reg_offset: reg_offset)
    when 'BLKPUSH'
      # BLKPUSH_YIELD_SUPPORT: `BLKPUSH R4 2:0:0:0 (0)`: vm.c OP_BLKPUSH with lv == 0
      # reads regs[1 + offset], this frame's block (lv > 0 walks uvenv). Compiled
      # only with @blk_param_name set, i.e. when compile_method's prescan arranged
      # for the wrapper to extract the block. vm.c raises LocalJumpError
      # ("unexpected yield") for a nil slot, reproduced here (mrb_get_args "&"
      # returns nil instead of raising).
      # BLOCK_FALLBACK_YIELD_SUPPORT: inside a BLOCK_FALLBACK body whose enclosing
      # method's block was captured, @blk_param_level answers exactly that lv
      # (uvenv(mrb, lv-1) is a different frame for each lv).
      d = a[/^R(\d+)/, 1]
      lv = a[/\((\d+)\)/, 1]
      if lv == @blk_param_level.to_s && @blk_param_name
        <<~CPP
          if (mrb_nil_p(#{@blk_param_name})) {
            mrb_raise(M, mrb_exc_get_id(M, mrb_intern_lit(M, "LocalJumpError")), "bc2cpp: unexpected yield");
          }
          r#{d} = #{@blk_param_name};
        CPP
      else
        "#error unhandled opcode BLKPUSH #{a}\n"
      end
    when 'BLKCALL'
      # "BLKCALL R4 2": ops.h `R[a] = R[a].call(R[a+1],...,R[a+b])`. codegen_yield's
      # fast path for a plain `yield` (no keywords, < 15 args, no splat; otherwise
      # SEND :call), always right after a BLKPUSH into the same register. So this is
      # `yield`, not a general "call a Proc in a register".
      # vm.c OP_BLKCALL does no method dispatch: it raises TypeError unless R[a] is
      # a Proc (`mrb_raisef(mrb, E_TYPE_ERROR, "wrong type %T (expected Proc)",
      # recv)`) and runs the proc body, ignoring any #call method. mrb_funcall(...,
      # "call") would be wrong (an object with its own #call would be invoked), so
      # the type check is reproduced (fixed message, as elsewhere here) and the call
      # goes through mrb_yield_argv (public). For an irep-backed Proc (every real
      # site passes a literal block) both take self from the proc's env
      # (mrb_proc_get_self, src/proc.c), and `break` unwinds normally past this
      # frame's POD locals.
      # Not modelled: a cfunc-backed Proc here (`&:sym`, `&method(...)`), where vm.c
      # passes the proc as self but mrb_yield_argv passes nil. Calling the cfunc
      # pointer directly would skip the ci frame mrb_get_args reads, which is worse.
      # No site passes one, and no core cfunc proc depends on its self.
      d = a[/^R(\d+)/, 1].to_i
      blkn = a[/^R\d+\s+(\d+)/, 1].to_i
      out = String.new
      out << "  if (!mrb_proc_p(r#{d})) {\n"
      out << "    mrb_raise(M, mrb_exc_get_id(M, mrb_intern_lit(M, \"TypeError\")), \"bc2cpp: BLKCALL (yield) expected a Proc\");\n"
      out << "  }\n"
      if blkn.zero?
        out << "  r#{d} = mrb_yield_argv(M, r#{d}, 0, NULL);\n"
      else
        out << "  {\n"
        out << "    mrb_value blkcall_args[] = { #{(1..blkn).map { |i| "r#{d + i}" }.join(', ')} };\n"
        out << "    r#{d} = mrb_yield_argv(M, r#{d}, #{blkn}, blkcall_args);\n"
        out << "  }\n"
      end
      out
    when 'RETURN'
      r = a.empty? ? '0' : a[/^R(\d+)/, 1]
      "  return r#{r};\n"
    when 'RETNIL'
      "  return mrb_nil_value();\n"
    when 'RETFALSE'
      "  return mrb_false_value();\n"
    when 'RETTRUE'
      "  return mrb_true_value();\n"
    when 'RETSELF'
      # "RETSELF": vm.c `a = 0; goto NORMAL_RETURN;`. mrbc's gen_return only emits
      # it as a LOADSELF+RETURN peephole, and every leaf irep compiled here is a def
      # body, so it is `return self`.
      "  return self;\n"
    when 'JMP'
      # `.to_i`: the disassembly zero-pads ("018") while labels use the integer
      # ("L18:").
      target = ensure_remapped_jump_target(irep, a.strip[/\d+/].to_i)
      "  goto L#{target};\n"
    when 'JMPUW'
      # JMPUW_SUPPORT: break/next/redo/retry; a plain JMP when this irep has no
      # catch handlers (see jmpuw_is_plain_jump?). `.to_i` as for JMP.
      if jmpuw_is_plain_jump?(irep)
        "  goto L#{a.strip[/\d+/].to_i};\n"
      else
        "  #error unhandled opcode JMPUW -- not in this prototype's supported subset\n"
      end
    when 'JMPNOT'
      reg = a[/^R(\d+)/, 1]
      target = ensure_remapped_jump_target(irep, jmp_target_after_reg(a))
      "  if (!mrb_test(r#{reg})) goto L#{target};\n"
    when 'JMPIF'
      reg = a[/^R(\d+)/, 1]
      target = ensure_remapped_jump_target(irep, jmp_target_after_reg(a))
      "  if (mrb_test(r#{reg})) goto L#{target};\n"
    when 'JMPNIL'
      # "JMPNIL R3 024": jump if exactly nil (vm.c), for nil-specific tests like
      # `x.nil? ? a : b`.
      reg = a[/^R(\d+)/, 1]
      target = ensure_remapped_jump_target(irep, jmp_target_after_reg(a))
      "  if (mrb_nil_p(r#{reg})) goto L#{target};\n"
    when 'GETCONST'
      # "GETCONST R4 Integer": the VM resolves against the lexical scope chain
      # (mrb_vm_const_get), which compiled code does not have. A single lookup from
      # Object misses class-body and enclosing-module constants (`KIND_SKILL` in
      # Game::EnemyAction, `Tone` in RGSS::Sprite): const_get_nohook (src/variable.c)
      # stops before Object's table unless the search starts at Object. So try each
      # scope of the owner's nesting innermost first ("RGSS::Sprite" ->
      # [RGSS::Sprite, RGSS]), then Object (Module.nesting for defs nested where the
      # owner name says).
      # A failing mrb_const_get raises by longjmp, so it cannot be tried and then
      # polled; bc2cpp_const_try (emit_const_lookup_helper) wraps each attempt in
      # mrb_protect_error. The final lookup, from Object, is unprotected: a constant
      # still not found is a real error.
      # A top-level def (owner "Object") needs just the one lookup.
      # Name: `\S+`, so a trailing "; R3:name" comment ("GETCONST R3 MAX_DIGITS\t;
      # R3:d") is not interned into the name.
      d = a[/^R(\d+)/, 1]
      name = a[/^R\d+\s+(\S+)/, 1]
      # INTEGER_CONSTANT_VALUE_PROOF: a name analyze_values proved always binds this
      # number needs no lookup. Checked first; it can never also be a
      # StableClassConstants name (one poisons on CLASS/MODULE, the other requires
      # it).
      if (value = self.class.integer_constant_values&.[](name))
        return "  r#{d} = mrb_fixnum_value(#{value});\n"
      end

      owner_path = lexical_scope_path(owner_def.owner)
      if self.class.stable_class_constants&.include?(name)
        # CONST_SITE_CACHE: see tools/bc2cpp/const_site_cache.rb. One helper per
        # (lexical scope, name); it runs the ordinary lookup until it finds a
        # class/module, then returns the stored value.
        @const_site_cache ||= {}
        key = [owner_path, name]
        unless @const_site_cache.key?(key)
          @const_site_cache[key] = { index: @const_site_cache.size, body: const_lookup_block('0', name, owner_path) }
        end
        return "  r#{d} = bc2cpp_cconst_#{@const_site_cache[key][:index]}(M);\n"
      end

      const_lookup_block(d, name, owner_path)
    when 'OCLASS'
      # OCLASS_SUPPORT: "OCLASS R3" for `::Foo` (followed by GETMCNST); vm.c
      # `regs[a] = mrb_obj_value(mrb->object_class)`.
      d = a[/^R(\d+)/, 1]
      "  r#{d} = mrb_obj_value(M->object_class);\n"
    when 'GETMCNST'
      # "GETMCNST R6 (R6)::Sections": r<d> holds the owning module (from the chain,
      # e.g. GETCONST R2 LCF; GETMCNST R2 (R2)::Schema; GETMCNST R2 (R2)::DATABASE);
      # read the constant from it into the same register.
      d = a[/^R(\d+)/, 1]
      name = a[/::(\w+)\s*$/, 1]
      # INTEGER_CONSTANT_VALUE_PROOF, as in GETCONST. The preceding scope lookups
      # still run (and raise if missing); only this value lookup is skipped. This is
      # the hot `case cmd.code when Cmd::X` shape.
      if (value = self.class.integer_constant_values&.[](name))
        return "  r#{d} = mrb_fixnum_value(#{value});\n"
      end

      "  r#{d} = mrb_const_get(M, r#{d}, mrb_intern_cstr(M, \"#{name}\"));\n"
    when 'HASH'
      # "HASH R2 22": N key/value pairs from Rd, result into Rd (vm.c OP_HASH). All
      # pair registers are read before Rd is written.
      d = a[/^R(\d+)/, 1].to_i
      n = a[/^R\d+\s+(\d+)/, 1].to_i
      out = String.new
      out << "  {\n"
      out << "    mrb_value h = mrb_hash_new_capa(M, #{n});\n"
      n.times { |i| out << "    mrb_hash_set(M, h, r#{d + 2 * i}, r#{d + 2 * i + 1});\n" }
      out << "    r#{d} = h;\n"
      out << "  }\n"
      out
    when 'ARRAY'
      # "ARRAY R3 2": N registers from Rd into a new Array in Rd (vm.c
      # `mrb_ary_new_from_values(mrb, b, &regs[a])`). The registers are separate C++
      # locals, not contiguous, so they are copied into a C array first; all are
      # read before Rd is written. This is codegen_array's no-splat path; splats
      # use ARYCAT/ARYPUSH/ARYSPLAT.
      # ARRAY2_OPERAND_FORM: OP_ARRAY2 disassembles under the same mnemonic with a
      # source register, `ARRAY Rd Rs N` ("ARRAY\tR%d\tR%d\t%d", codedump.c): Rd =
      # [Rs .. Rs+N-1], emitted for `local = [literal]`. The 2-operand regex does
      # not match it, and treating N as 0 compiled it to an empty Array; it is
      # handled explicitly.
      d = a[/^R(\d+)/, 1].to_i
      three = a.match(/^R\d+\s+R(\d+)\s+(\d+)/)
      src = three ? three[1].to_i : d
      n = three ? three[2].to_i : a[/^R\d+\s+(\d+)/, 1].to_i
      if n.zero?
        "  r#{d} = mrb_ary_new(M);\n"
      else
        out = String.new
        out << "  {\n"
        out << "    mrb_value elems[] = { #{(0...n).map { |i| "r#{src + i}" }.join(', ')} };\n"
        out << "    r#{d} = mrb_ary_new_from_values(M, #{n}, elems);\n"
        out << "  }\n"
        out
      end
    when 'ARYPUSH'
      # "ARYPUSH R3 2": push Ra+1..Ra+N onto the Array in Ra (vm.c
      # `mrb_ensure_array_type(mrb, regs[a]); for (...) mrb_ary_push(...)`). Ra is
      # always an Array here: codegen.c emits OP_ARYPUSH only in gen_values and
      # codegen_array, each after an OP_ARRAY wrote that register, so the ensure is
      # a no-op and plain mrb_ary_push calls suffice.
      d = a[/^R(\d+)/, 1].to_i
      n = a[/^R\d+\s+(\d+)/, 1].to_i
      out = String.new
      n.times { |i| out << "  mrb_ary_push(M, r#{d}, r#{d + i + 1});\n" }
      out
    when 'ARYCAT'
      # "ARYCAT R3 (R4)" (codedump.c `"ARYCAT\tR%d\t(R%d)"`). vm.c OP_ARYCAT:
      #   mrb_value splat = mrb_ary_splat(mrb, regs[a+1]);
      #   if (mrb_nil_p(regs[a])) regs[a] = splat;
      #   else { mrb_ensure_array_type(mrb, regs[a]); mrb_ary_concat(mrb, regs[a], splat); }
      # ARYCAT_NIL_START_SUPPORT: R[a] can be nil: `bar(*list, *list2)` compiles to
      # `LOADNIL R5` then `ARYCAT R5 (R6)`, so the nil branch is reproduced. A
      # non-nil R[a] always came from ARRAY or ARYCAT, so ensure_array_type is a
      # no-op. R[a+1] can be anything, so mrb_ary_splat is really called.
      d = a[/^R(\d+)/, 1]
      s = a[/\(R(\d+)\)/, 1]
      <<~CPP
        {
          mrb_value bc2cpp_arycat_splat = mrb_ary_splat(M, r#{s});
          if (mrb_nil_p(r#{d})) {
            r#{d} = bc2cpp_arycat_splat;
          } else {
            mrb_ary_concat(M, r#{d}, bc2cpp_arycat_splat);
          }
        }
      CPP
    when 'AREF'
      # "AREF R2 R6 0 ; R2:x": R[a] = R[b][c] with an immediate c (vm.c): for a
      # non-Array, index 0 yields R[b] itself and others nil; for an Array,
      # mrb_ary_ref. This is `x, y, w, h = some_call(...)` destructuring.
      d, s = regs(a, 2)
      c = a[/^R\d+\s+R\d+\s+(\d+)/, 1]
      "  r#{d} = mrb_array_p(r#{s}) ? bc2cpp_ary_entry(M, r#{s}, #{c}) : (#{c} == 0 ? r#{s} : mrb_nil_value());\n"
    when 'GETIDX'
      # "GETIDX R2 (R3)": R[a] = R[a][R[a+1]] with a register index (vm.c).
      # Mirrors vm.c's fast paths: Array with an Integer index (mrb_ary_ref), Hash
      # (mrb_hash_get), String with an Integer/String/Range index; anything else
      # calls the real `[]`. The fast paths require the exact base class, as vm.c
      # does, so subclass/singleton `[]` overrides keep Ruby dispatch. r<d> is read
      # by every branch before any write.
      # GETIDX_STRING_AREF: the String arm calls `mrb_str_aref(mrb, str, idx,
      # mrb_undef_value())` (no length; codegen.c only emits GETIDX for one-argument
      # `[]`), with vm.c's index-type gate (INTEGER/STRING/RANGE). mrb_str_aref is
      # declared `extern "C"` in the prologue.
      # GETIDX_STATIC_RECEIVER_SUPPORT: when static_indexable_class proves Array or
      # Hash, emit one guarded fast path instead of the four-way gate; a wrong hint
      # still falls back to `[]`, and subclasses use Ruby dispatch. A Hash needs no
      # index-type check; an Array still needs mrb_integer_p (bc2cpp_ary_entry only
      # takes a fixnum).
      d, s = regs(a, 2)
      index_class = static_indexable_class(irep, idx, unshift_proof_reg(d, reg_offset), owner_def)
      case index_class
      when 'Array'
        <<~CPP
          if (mrb_array_p(r#{d}) && mrb_obj_ptr(r#{d})->c == M->array_class && mrb_integer_p(r#{s})) {
            r#{d} = bc2cpp_ary_entry(M, r#{d}, mrb_integer(r#{s}));
          } else {
            r#{d} = mrb_funcall(M, r#{d}, "[]", 1, r#{s});
          }
        CPP
      when 'Hash'
        <<~CPP
          if (mrb_hash_p(r#{d}) && mrb_obj_ptr(r#{d})->c == M->hash_class) {
            r#{d} = mrb_hash_get(M, r#{d}, r#{s});
          } else {
            r#{d} = mrb_funcall(M, r#{d}, "[]", 1, r#{s});
          }
        CPP
      else
        # STRUCT_INDEX_CACHE (see compile_struct_literal_index_read); a miss is "".
        struct_read = compile_struct_literal_index_read(irep, idx, s, d)
        fallback = outlined_getidx_code(d, s, struct_read)
        unless fallback
          # INDEX_CHAIN: send the untyped `x[i]` fallback through the exact-class chain
          # (compile_poly_small_n), so program-defined `#[]` (Game::Variables,
          # LCF::Array1D, ...) is called directly; nil keeps the funcall.
          tail = compile_poly_small_n('[]', d.to_i, "r#{d}", ["r#{s}"], 1)
          tail = tail ? tail.gsub(/^/, '  ').lstrip : "r#{d} = mrb_funcall(M, r#{d}, \"[]\", 1, r#{s});"
          fallback = <<~CPP
            if (mrb_array_p(r#{d}) && mrb_obj_ptr(r#{d})->c == M->array_class && mrb_integer_p(r#{s})) {
              r#{d} = bc2cpp_ary_entry(M, r#{d}, mrb_integer(r#{s}));
            } else if (mrb_hash_p(r#{d}) && mrb_obj_ptr(r#{d})->c == M->hash_class) {
              r#{d} = mrb_hash_get(M, r#{d}, r#{s});
            } else if (mrb_string_p(r#{d}) && mrb_obj_ptr(r#{d})->c == M->string_class &&
                       (mrb_integer_p(r#{s}) || mrb_string_p(r#{s}) || mrb_range_p(r#{s}))) {
              r#{d} = mrb_str_aref(M, r#{d}, r#{s}, mrb_undef_value());
            } #{struct_read}else {
              #{tail}
            }
          CPP
        end
        typed = compile_typed_index_send(irep, idx, owner_def, d, d, "r#{s}", reg_offset, index_class, fallback)
        typed || fallback
      end
    when 'GETIDX0'
      # "GETIDX0 R7 R4[0]": R[a] = R[b][0] (vm.c), separate dest/source registers
      # and no index register. Same exact-class Array/Hash fast paths as GETIDX,
      # else a real `[]` send with 0, as vm.c's getidx0_fallback.
      # GETIDX_STATIC_RECEIVER_SUPPORT applies to `s`, the receiver here.
      d, s = regs(a, 2)
      index_class = static_indexable_class(irep, idx, unshift_proof_reg(s, reg_offset), owner_def)
      case index_class
      when 'Array'
        <<~CPP
          if (mrb_array_p(r#{s}) && mrb_obj_ptr(r#{s})->c == M->array_class) {
            r#{d} = bc2cpp_ary_entry(M, r#{s}, 0);
          } else {
            r#{d} = mrb_funcall(M, r#{s}, "[]", 1, mrb_fixnum_value(0));
          }
        CPP
      when 'Hash'
        <<~CPP
          if (mrb_hash_p(r#{s}) && mrb_obj_ptr(r#{s})->c == M->hash_class) {
            r#{d} = mrb_hash_get(M, r#{s}, mrb_fixnum_value(0));
          } else {
            r#{d} = mrb_funcall(M, r#{s}, "[]", 1, mrb_fixnum_value(0));
          }
        CPP
      else
        # OUTLINED_INDEX_OPS: the Array/Hash/funcall chain is bc2cpp_getidx0.
        fallback = outlined_index_call('getidx0', "r#{d}", "r#{s}")
        typed = compile_typed_index_send(irep, idx, owner_def, d, s, 'mrb_fixnum_value(0)', reg_offset,
                                         index_class, fallback)
        typed || fallback
      end
    when 'SETIDX'
      # "SETIDX R4 (R5) (R6)": R[a][R[a+1]] = R[a+2], then R[a] = R[a+2] on the fast
      # Array/Hash paths (vm.c; `arr[i] = v` evaluates to v). Otherwise (including
      # container subclasses) a real `[]=` send, whose return value is kept, as in
      # vm.c's setidx_fallback.
      # GETIDX_STATIC_RECEIVER_SUPPORT as for GETIDX. The index register is named
      # `idx_reg`: `idx` would shadow compile_insn's instruction position, which
      # static_indexable_class needs.
      d, idx_reg, val = regs(a, 3)
      index_class = static_indexable_class(irep, idx, unshift_proof_reg(d, reg_offset), owner_def)
      case index_class
      when 'Array'
        <<~CPP
          if (mrb_array_p(r#{d}) && mrb_obj_ptr(r#{d})->c == M->array_class && mrb_integer_p(r#{idx_reg})) {
            mrb_ary_set(M, r#{d}, mrb_integer(r#{idx_reg}), r#{val});
            r#{d} = r#{val};
          } else {
            r#{d} = mrb_funcall(M, r#{d}, "[]=", 2, r#{idx_reg}, r#{val});
          }
        CPP
      when 'Hash'
        <<~CPP
          if (mrb_hash_p(r#{d}) && mrb_obj_ptr(r#{d})->c == M->hash_class) {
            mrb_hash_set(M, r#{d}, r#{idx_reg}, r#{val});
            r#{d} = r#{val};
          } else {
            r#{d} = mrb_funcall(M, r#{d}, "[]=", 2, r#{idx_reg}, r#{val});
          }
        CPP
      else
        # OUTLINED_INDEX_OPS: the Array/Hash/funcall chain is bc2cpp_setidx.
        fallback = outlined_index_call('setidx', "r#{d}", "r#{d}", "r#{idx_reg}", "r#{val}")
        typed = compile_typed_index_write(irep, idx, owner_def, d, idx_reg, val, reg_offset, index_class, fallback)
        typed || fallback
      end
    when 'GETGV'
      # "GETGV R4 $stderr": R[a] = mrb_gv_get (vm.c); the symbol already includes the
      # `$`.
      d = a[/^R(\d+)/, 1]
      name = a[/(\$\S+)/, 1]
      "  r#{d} = mrb_gv_get(M, mrb_intern_cstr(M, \"#{name}\"));\n"
    when 'SETGV'
      # "SETGV $stderr R4": operands are reversed relative to GETGV (codedump.c
      # `"SETGV\t\t%s\tR%d"`), so both are matched unanchored (one `$` token, one
      # register). vm.c: `mrb_gv_set(mrb, irep->syms[b], regs[a])`.
      s = a[/R(\d+)/, 1]
      name = a[/(\$\S+)/, 1]
      "  mrb_gv_set(M, mrb_intern_cstr(M, \"#{name}\"), r#{s});\n"
    when 'STOP'
      ''
    when 'NOP'
      # "NOP": vm.c does nothing. mrbc places it after a while loop's entry JMPNOT.
      ''
    when 'ADDILV'
      # "ADDILV Rd Rb N ; Rd:name": vm.c OP_MATHILV(add) updates regs[a] in place
      # (`b` is never touched), falling back to `+` for non-Integers, like ADDI.
      # Overflow wraps instead of promoting to Bignum, the same simplification ADDI
      # accepts. The immediate is the third operand (`^R\d+\s+R\d+\s+(-?\d+)`): `a`
      # is a named local, so a trailing "; Rd:name" comment is normal and
      # `.split.last` would pick it up.
      d = a[/^R(\d+)/, 1]
      lit = a[/^R\d+\s+R\d+\s+(-?\d+)/, 1]
      # FIXNUM_OPERAND_PROOF: as ADDI; rarely provable (a loop back-edge sits
      # between the write and this use).
      if proven_fixnum_operand?(irep, idx, unshift_proof_reg(d, reg_offset), owner_def)
        "#{FIXNUM_PROOF_NOTE}  r#{d} = mrb_fixnum_value(mrb_fixnum(r#{d}) + #{lit});\n"
      else
        <<~CPP
          if (mrb_integer_p(r#{d})) {
            r#{d} = mrb_fixnum_value(mrb_fixnum(r#{d}) + #{lit});
          } else {
            #{compile_operator_fallback('+', d, nil, "mrb_fixnum_value(#{lit})", irep, idx, owner_def, reg_offset)}
          }
        CPP
      end
    when 'SUBILV'
      # OP_SUBILV: ADDILV's sibling (same shape, same extraction), e.g. `new_level -=
      # 1 while ...`.
      d = a[/^R(\d+)/, 1]
      lit = a[/^R\d+\s+R\d+\s+(-?\d+)/, 1]
      if proven_fixnum_operand?(irep, idx, unshift_proof_reg(d, reg_offset), owner_def)
        "#{FIXNUM_PROOF_NOTE}  r#{d} = mrb_fixnum_value(mrb_fixnum(r#{d}) - #{lit});\n"
      else
        <<~CPP
          if (mrb_integer_p(r#{d})) {
            r#{d} = mrb_fixnum_value(mrb_fixnum(r#{d}) - #{lit});
          } else {
            #{compile_operator_fallback('-', d, nil, "mrb_fixnum_value(#{lit})", irep, idx, owner_def, reg_offset)}
          }
        CPP
      end
    when 'RANGE_INC'
      # "RANGE_INC Ra": R[a] = mrb_range_new(mrb, regs[a], regs[a+1], FALSE) (vm.c);
      # both operands are read before r<a> is written.
      d = a[/^R(\d+)/, 1].to_i
      "  r#{d} = mrb_range_new(M, r#{d}, r#{d + 1}, FALSE);\n"
    when 'RANGE_EXC'
      # OP_RANGE_EXC: RANGE_INC with exclude_end TRUE (`a...b`).
      d = a[/^R(\d+)/, 1].to_i
      "  r#{d} = mrb_range_new(M, r#{d}, r#{d + 1}, TRUE);\n"
    when 'RETURN_BLK'
      # "RETURN_BLK Ra": vm.c starts with `if (!MRB_PROC_ENV_P(ci->proc) ||
      # MRB_PROC_STRICT_P(ci->proc)) goto NORMAL_RETURN;`. Reached from:
      # (1) a def body (always strict, @block_fallback_active false): e.g. an early
      #     `return` inside a `while` loop; a plain `return`.
      # (2) a LAMBDA_FALLBACK body (a lambda proc is strict): a plain `return`.
      # (3) EXCEPTION_RETURN_SUPPORT: a BLOCK_FALLBACK body (@block_fallback_active
      #     true), where `return` exits the whole enclosing method:
      #     `throw bc2cpp_method_return{...}`, caught by compile_method's top-level
      #     try/catch (needs_return_catch). The per-call-site
      #     `catch (bc2cpp_block_break&)` cannot match it (exact C++ catch types).
      r = a.strip.empty? ? '0' : a[/^R(\d+)/, 1]
      if @block_fallback_active
        "  throw bc2cpp_method_return{r#{r}};\n"
      else
        "  return r#{r};\n"
      end
    when 'BREAK'
      # "BREAK Ra": vm.c starts with `if (MRB_PROC_STRICT_P(ci->proc)) goto
      # NORMAL_RETURN;`. Reached from:
      # (1) a LAMBDA_FALLBACK body (strict): a plain `return`.
      # (2) EXCEPTION_BREAK_SUPPORT: a BLOCK_FALLBACK body, where a non-strict break
      #     unwinds to the SENDB call site, past mrb_funcall_with_block: `throw`,
      #     caught by emit_block_fallback_glue's `catch (bc2cpp_block_break&)`.
      r = a.strip.empty? ? '0' : a[/^R(\d+)/, 1]
      if @block_fallback_active
        "  throw bc2cpp_block_break{r#{r}};\n"
      else
        "  return r#{r};\n"
      end
    when 'RESCUE'
      # "RESCUE Ra Rb": vm.c `R[b] = R[a].isa?(R[b])`. Ra holds the exception (only
      # RESCUE_SUPPORT's glue produces one) and Rb the class from the preceding
      # GETCONST/GETMCNST chain, so this is correct wherever it appears; not gated on
      # the recognizer (unlike EXCEPT).
      ra, rb = a.split(/\s+/)
      d = ra[/^R(\d+)/, 1]
      s = rb[/^R(\d+)/, 1]
      "  r#{s} = mrb_bool_value(mrb_obj_is_kind_of(M, r#{d}, mrb_class_ptr(r#{s})));\n"
    when 'RAISEIF'
      # "RAISEIF Ra": re-raise Ra unless nil. In a recognized rescue it is reached
      # only on the non-matching path with the exception in Ra. vm.c's mrb_break_p
      # branch (a break unwinding through a block) does not apply: the leaf ireps
      # compiled here are def bodies, so Ra is nil or an exception.
      ra = a[/^R(\d+)/, 1]
      "  if (!mrb_nil_p(r#{ra})) { mrb_exc_raise(M, r#{ra}); }\n"
    when 'SUPER'
      # "SUPER Ra n=N": vm.c looks up ci->mid one level above the current class, with
      # self as receiver and N args in R(a+1)..R(a+N), plus one register forwarding
      # the current block. That block is never read: a compiled `_impl` has none
      # (see SUPER_TARGETS). super_target applies the allowlist.
       target_def = super_target(owner_def)
       dest, nstr = a.split(/\s+/, 2)
       d_reg = dest[/^R(\d+)/, 1]
       n = nstr && nstr[/^n=(\d+)$/, 1]
       zsuper_kind = reg_offset.zero? ? zsuper_native_kind(owner_def, irep, idx) : nil
       zsuper_plan = reg_offset.zero? && zsuper_kind.nil? ? zsuper_forward_plan(owner_def, irep, idx) : nil
       if target_def && d_reg && n
         args = (1..n.to_i).map { |i| "r#{d_reg.to_i + i}" }
         "  r#{d_reg} = #{cpp_name(target_def.owner, target_def.name)}_impl(M, self#{args.map { |x| ", #{x}" }.join});\n"
       elsif zsuper_kind && d_reg
         compile_zsuper_native(zsuper_kind, d_reg)
       elsif zsuper_plan && d_reg
         compile_zsuper_forward(zsuper_plan[:target_def], d_reg, zsuper_plan[:m])
       else
         "  #error unhandled opcode SUPER -- not in this prototype's supported subset\n"
       end
     when 'ARGARY'
      # ZSUPER_NATIVE_SUPPORT: the array this ARGARY builds is only read by the next
      # `SUPER ... n=*` (zsuper_native_kind checks the adjacency and registers), and
      # both translations use the original registers instead, so it is not built.
      # OP_ARGARY has no other observable effect (see ZSUPER_NATIVE_TARGETS). Any
      # other ARGARY keeps `#error`.
      if reg_offset.zero? && zsuper_native_kind(owner_def, irep, idx)
        "  // #{insn.raw.strip} (zsuper argument array not built -- consumed by the SUPER below)\n"
      elsif reg_offset.zero? && zsuper_forward_plan(owner_def, irep, idx)
        # ZSUPER_GENERAL_SUPPORT: same dead-array suppression for the general zsuper
        # pair, whose SUPER arm calls the superclass `_impl` with the original
        # registers.
        "  // #{insn.raw.strip} (zsuper argument array not built -- forwarded to the superclass _impl below)\n"
      else
        "  #error unhandled opcode ARGARY -- not in this prototype's supported subset\n"
      end
    else
      "  #error unhandled opcode #{insn.op} -- not in this prototype's supported subset\n"
    end
  end

  # ZSUPER_NATIVE_SUPPORT: replacement body for a recognized ARGARY + `SUPER
  # n=*` pair (`d_reg` is SUPER's destination). See ZSUPER_NATIVE_TARGETS and
  # zsuper_native_kind.
  def compile_zsuper_native(kind, d_reg)
    case kind
    when :kernel_respond_to_missing
      # Kernel#respond_to_missing? is src/kernel.c's mrb_false:
      # `return mrb_false_value();`.
      "  // super -> Kernel#respond_to_missing? (3rd/mruby/src/kernel.c's own `mrb_false`: " \
        "unconditionally false, reads neither self nor arguments)\n" \
        "  r#{d_reg} = mrb_false_value();\n"
    when :basic_object_method_missing
      # BasicObject#method_missing is mrb_obj_missing (src/class.c), which reads its
      # arguments via mrb_get_args off mrb->c->ci and cannot be called directly;
      # its values are computed here and passed to mrb_method_missing.
      # The ARGARY spec is `1:1:0:0` with lv=0: vm.c builds `[r1, *r2]`, so "n*!"
      # gives name = r1 and args = r2, read from the live registers (a reassignment
      # before `super` is forwarded as the interpreter would).
      # The mrb_array_p guard is vm.c's OP_ARGARY `r != 0` branch (`if
      # (mrb_array_p(stack[m1])) { ... }`, else len 0: an empty forwarded list), and
      # keeps RARRAY_LEN/PTR off a non-Array.
      # `self` = r0 (OP_SUPER reads regs[0]).
      # mrb_method_missing is mrb_noreturn, so nothing follows and d_reg is left
      # unassigned; the next RETURN is unreachable (as after RAISEIF's raise).
      "  // super -> BasicObject#method_missing (3rd/mruby/src/class.c's own `mrb_obj_missing`, " \
        "reproduced via the `mrb_method_missing` it tail-calls -- always raises NoMethodError)\n" \
        "  mrb_method_missing(M, mrb_obj_to_sym(M, r1), self,\n" \
        "                     mrb_array_p(r2)\n" \
        "                       ? mrb_ary_new_from_values(M, RARRAY_LEN(r2), RARRAY_PTR(r2))\n" \
        "                       : mrb_ary_new(M));\n"
    end
  end

  # EQ/LT/LE/GT/GE share vm.c OP_CMP: Integer/Integer (and, with floats,
  # Integer/Float, Float/Integer, Float/Float) compare natively. For EQ's other
  # shapes the fallback keeps mrb_equal's mrb_obj_eq identity shortcut before
  # dispatching `==`, so `x == x` stays true even with an overridden `==`.
  # FIXNUM_OPERAND_PROOF: when both operands prove, only the native comparison
  # is emitted (the same value the fast path computes).
  def compile_cmp(op, args, irep = nil, idx = nil, owner_def = nil, reg_offset = 0)
    sym = { 'EQ' => '==', 'LT' => '<', 'LE' => '<=', 'GT' => '>', 'GE' => '>=' }.fetch(op)
    d = args[/^R(\d+)/, 1]
    s = args[/\(R(\d+)\)/, 1]
    if proven_fixnum_pair?(irep, idx, unshift_proof_reg(d, reg_offset), unshift_proof_reg(s, reg_offset), owner_def)
      return "#{FIXNUM_PROOF_NOTE}  r#{d} = mrb_bool_value(mrb_fixnum(r#{d}) #{sym} mrb_fixnum(r#{s}));\n"
    end

    # OP_CMP's MRB_TT_INTEGER is the full Integer tag, and with floats all three
    # Integer/Float pairs compare natively; the tag checks come before
    # mrb_integer/mrb_float, which are only valid for matching tags.
    # EQ: OP_EQ's identity shortcut runs before OP_CMP; keep that order (NaN,
    # symbols), with numeric comparison only after identity fails. MRB_NO_FLOAT
    # builds compile out the float arms.
    # Non-numeric operands use a real send; route it through compile_send's
    # MONO/TYPED resolver so compiled operator methods are called directly. For
    # EQ the generated chain below already handles String/Symbol, so its fallback
    # must not repeat the registered-expression switch.
    @suppress_native_expression_send = sym if op == 'EQ'
    begin
      fallback = compile_operator_fallback(sym, d, s, nil, irep, idx, owner_def, reg_offset)
    ensure
      @suppress_native_expression_send = nil
    end
    # String/Symbol `==` come from their C wrappers; the resolver fallback stays
    # the `else`.
    fallback = generated_eq_dispatch(d, s, fallback) || fallback if op == 'EQ'

    integer_accessor = "mrb_integer(r#{d}) #{sym} mrb_integer(r#{s})"
    no_float_accessor = "mrb_fixnum(r#{d}) #{sym} mrb_fixnum(r#{s})"
    numeric_dispatch = <<~CPP
      if (mrb_type(r#{d}) == MRB_TT_INTEGER && mrb_type(r#{s}) == MRB_TT_INTEGER) {
      #ifdef MRB_NO_FLOAT
        r#{d} = mrb_bool_value(#{no_float_accessor});
      #else
        r#{d} = mrb_bool_value(#{integer_accessor});
      #endif
      }
      #ifndef MRB_NO_FLOAT
      else if (mrb_type(r#{d}) == MRB_TT_INTEGER && mrb_type(r#{s}) == MRB_TT_FLOAT) {
        r#{d} = mrb_bool_value(mrb_integer(r#{d}) #{sym} mrb_float(r#{s}));
      } else if (mrb_type(r#{d}) == MRB_TT_FLOAT && mrb_type(r#{s}) == MRB_TT_INTEGER) {
        r#{d} = mrb_bool_value(mrb_float(r#{d}) #{sym} mrb_integer(r#{s}));
      } else if (mrb_type(r#{d}) == MRB_TT_FLOAT && mrb_type(r#{s}) == MRB_TT_FLOAT) {
        r#{d} = mrb_bool_value(mrb_float(r#{d}) #{sym} mrb_float(r#{s}));
      }
      #endif
      else {
        #{fallback}
      }
    CPP

    if op == 'EQ'
      <<~CPP
        if (mrb_obj_eq(M, r#{d}, r#{s})) {
          r#{d} = mrb_true_value();
        } else if (mrb_symbol_p(r#{d})) {
          // OP_EQ: a symbol receiver that is not identical is unequal, no send.
          r#{d} = mrb_false_value();
        } else {
          // Numeric tag pair handling mirrors the pinned mruby OP_CMP.
          #{numeric_dispatch}
        }
      CPP
    else
      "  // Numeric tag pair handling mirrors the pinned mruby OP_CMP.\n#{numeric_dispatch}"
    end
  end

  # EQ on non-numeric operands used to mrb_funcall whenever identity missed
  # (every false String/Symbol compare). String#== (mrb_str_equal) and Symbol#==
  # (mrb_obj_equal) are single public-API expressions, emitted behind the usual
  # per-class guards; everything else keeps the identity/dispatch fallback. nil
  # when nothing was generated or a Ruby definition/prepend could shadow the
  # built-in (builtin_class_send_safe?).
  def generated_eq_dispatch(d, s, identity_dispatch)
    entries = @native_registered_expressions['==']
    return unless entries && !entries.empty? && entries.all? { |entry| entry[:arity] == 1 }
    return unless builtin_class_send_safe?('==', entries.map { |entry| entry[:owner][:class_name] }.uniq)

    # An if/else-if chain rather than compile_native_registered_expression's
    # switch, which would repeat the fallback (an mrb_funcall site) per class.
    recv = "r#{d}"
    chain = entries.map do |entry|
      owner = entry[:owner]
      guard = "mrb_type(#{recv}) == #{owner[:tag]}"
      guard += " && mrb_obj_ptr(#{recv})->c == M->#{owner[:field]}" unless %w[Float Symbol].include?(owner[:class_name])
      expression = entry[:expression].gsub('recv', recv).gsub('BC2CPP_ARG0', "r#{s}")
      "  if (#{guard}) {\n    r#{d} = #{expression};\n  } else "
    end.join
    "  // == -- generated from native registrations and C method bodies\n#{chain}{\n#{identity_dispatch}  }\n"
  end

  # Operator opcodes fall back to a one-argument send; reuse compile_send's
  # MONO/TYPED resolution. ADDI/SUBI pass the immediate as an expression rather
  # than borrowing a possibly live register.
  def compile_operator_fallback(name, dest_reg, arg_reg, arg_expr, irep, idx, owner_def, reg_offset)
    argument = arg_reg ? "r#{arg_reg}" : arg_expr
    send_args = "R#{dest_reg} :#{name} n=1"
    send = compile_send(send_args, self_implicit: false, irep: irep,
                        idx: reg_offset.zero? ? idx : nil, owner_def: owner_def,
                        call_receiver: "r#{dest_reg}", call_arguments: [argument])
    send.lines.map { |line| "  #{line}" }.join
  end
end
