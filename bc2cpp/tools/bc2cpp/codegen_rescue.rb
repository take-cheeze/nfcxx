# frozen_string_literal: true

# CodeGen: ensure and rescue regions.

class CodeGen
  # JMPUW_SUPPORT: is every OP_JMPUW in this irep a plain OP_JMP?
  # mrbc emits JMPUW for loop `break`/`next` (LOOP_NORMAL), `redo` and `retry`
  # (codegen.c), with or without an ensure. vm.c's OP_JMPUW:
  #
  #     a = (uint32_t)((ci->pc - irep->iseq) + (int16_t)a);
  #     CHECKPOINT_RESTORE(RBREAK_TAG_JUMP) { ...resume after ensure... }
  #     CHECKPOINT_MAIN(RBREAK_TAG_JUMP) {
  #       if (irep->clen > 0 &&
  #           (ch = catch_handler_find(irep, ci->pc, MRB_CATCH_FILTER_ENSURE))) {
  #         if (a < ...ch->begin || a > ...ch->end) {
  #           THROW_TAGGED_BREAK(mrb, RBREAK_TAG_JUMP, mrb->c->ci, mrb_fixnum_value(a));
  #         }
  #       }
  #     }
  #     CHECKPOINT_END(RBREAK_TAG_JUMP);
  #     mrb->exc = NULL;
  #     ci->pc = irep->iseq + a;
  #     JUMP;
  #
  # With `irep->clen == 0` it can never throw (and CHECKPOINT_RESTORE is only
  # re-entered by its own throw), so it is exactly OP_JMP.
  # The whole-irep clen == 0 test is used rather than the per-pc range check
  # because: it is vm.c's own first condition (no half-open range subtleties);
  # a real unsound case exists (a `break` inside `begin ... ensure` jumping out
  # of the ensure range must run the ensure body, which a bare goto would skip);
  # and it keeps JMPUW away from RESCUE_SUPPORT's extracted regions (a rescue
  # region implies clen > 0).
  def jmpuw_is_plain_jump?(irep)
    irep.catch_handlers.nil? || irep.catch_handlers.empty?
  end

  # ENSURE_RAII_SUPPORT: the branch target of one instruction, or nil. Same arg
  # shapes as const_entry_addrs.
  def ensure_jump_target(insn)
    case insn.op
    when 'JMP', 'JMPUW'
      insn.args.strip[/\d+/].to_i
    when 'JMPIF', 'JMPNOT', 'JMPNIL'
      insn.args.sub(/;.*\z/m, '').strip.split(/\s+/).last&.to_i
    end
  end

  # ENSURE_DISPATCH_MERGE_SUPPORT: compile_method's per-irep remap of jumps onto
  # an ensure handler address. nil outside compile_method (hence `&.`); keyed on
  # the irep object so a nested irep's same numeric address is unaffected.
  # JMPUW never consults it (it only compiles with no catch handlers).
  def ensure_remapped_jump_target(irep, target)
    return target unless target && @ensure_except_remaps

    map = @ensure_except_remaps[irep]
    map ? map.fetch(target, target) : target
  end

  # ENSURE_RAII_SUPPORT: recognize one `begin BODY ensure ENSURE_BODY end` and
  # return {begin_addr:, except_addr:, raiseif_addr:, body_insns:,
  # except_jump_srcs:}, or nil (keeps `#error unhandled opcode EXCEPT`).
  # `except_jump_srcs` are jumps from inside the protected range onto the
  # handler address (ENSURE_DISPATCH_MERGE_SUPPORT below).
  # Shape (checked against mrbc -v):
  #
  #   catch type: ensure   begin: B   end: E   target: E
  #     [B, E)   the protected computation
  #     E        EXCEPT Rx      -- captures whatever is unwinding (a real
  #                               exception OR an MRB_TT_BREAK break
  #                               object) into Rx
  #     (E, R)   the ensure body itself
  #     R        RAISEIF Rx     -- re-raises/resumes unless Rx is nil
  #     R+       the method continues (or RETURNs)
  #
  # Under RAII, EXCEPT and RAISEIF disappear: C++ unwinding carries the
  # in-flight exception, and the guard's destructor runs the ensure body on
  # every exit. A mruby unwind is carried in M->exc (saved and restored by
  # bc2cpp_ensure_guard); this file's own C++ break/return exceptions run the
  # destructor and continue to their catch sites.
  # Everything below rejects unproven shapes.
  def recognize_ensure_region(irep)
    return nil if irep.catch_handlers.nil?
    # Exactly one handler, the ensure; nesting or a rescue in the same irep is not
    # modelled.
    return nil unless irep.catch_handlers.size == 1
    ch = irep.catch_handlers.first
    return nil unless ch.type == :ensure
    # `end == target` is the only shape reasoned about.
    return nil unless ch.end_addr == ch.target

    by_addr = irep.instructions.each_with_object({}) { |insn, h| h[insn.addr] = insn }
    b, t = ch.begin_addr, ch.target
    return nil unless by_addr.key?(b)

    exc = by_addr[t]
    return nil unless exc && exc.op == 'EXCEPT'
    exc_reg = exc.args.strip[/R(\d+)/, 1]
    return nil unless exc_reg

    # Find this handler's own terminating `RAISEIF Rx` (same register).
    after = irep.instructions.select { |i| i.addr > t }
    raiseif = after.find { |i| i.op == 'RAISEIF' && i.args.strip[/R(\d+)/, 1] == exc_reg }
    return nil unless raiseif

    body = after.select { |i| i.addr < raiseif.addr }
    # The ensure body must only fall off its end: a RETURN would have to return
    # from the method, not the destructor's lambda, and BREAK/BLOCK/SENDB/LAMBDA
    # could throw a C++ exception out of a destructor that may already be running
    # during unwinding (std::terminate).
    return nil if body.any? do |i|
      %w[RETURN RETURN_BLK BREAK BLOCK SENDB SSENDB LAMBDA EXCEPT RAISEIF].include?(i.op)
    end
    # Branches inside the ensure body must stay inside it; its RAISEIF address is
    # allowed (mrbc's "skip the rest" target for a conditional ensure body) and
    # becomes a label at the end of the lambda.
    return nil if body.any? do |i|
      jt = ensure_jump_target(i)
      jt && !(jt > t && jt <= raiseif.addr)
    end
    # No branch may cross into or out of the protected range: the guard is a C++
    # scope, and jumping in would skip its initialization (ill-formed), jumping
    # out would run the ensure where the bytecode does not.
    # ENSURE_DISPATCH_MERGE_SUPPORT: except a jump from INSIDE the range to `t`
    # (== ch.end_addr), mrbc's tail-merge of a trailing conditional onto the
    # ensure region, e.g. optcarrot NES#run:
    #
    #   catch type: ensure   begin: 0004 end: 0122 target: 0122
    #     ...
    #     93 117 JMP              122    <- the merged branch exit
    #     93 120 LOADNIL   R3      (nil) <- the branch's other (fall-in) arm
    #     93 122 EXCEPT    R5
    #     96 124 SSEND0    R6      :dispose
    #     96 127 RAISEIF   R5
    #     96 129 RETURN    R3
    #
    # On the VM that runs EXCEPT (nil on the normal path), the ensure body, and
    # continues after RAISEIF; the RAII equivalent is leaving the guard scope and
    # landing just after it, so these jumps are remapped to raiseif_addr by
    # compile_method (which also emits that label). A jump from OUTSIDE onto `t`
    # stays rejected: it would skip the body but run the ensure.
    inside = ->(a) { a >= b && a < ch.end_addr }
    except_jump_srcs = []
    irep.instructions.each do |i|
      jt = ensure_jump_target(i)
      next unless jt
      # The ensure body was already checked above with a stricter rule.
      next if i.addr > t && i.addr < raiseif.addr
      if jt == t
        return nil unless inside.call(i.addr)

        except_jump_srcs << i.addr
        next
      end
      return nil if inside.call(i.addr) != inside.call(jt)
    end
    # An optional-argument jump table is ordinary JMPs in this irep, so the
    # crossing test already covered it.
    { begin_addr: b, except_addr: t, raiseif_addr: raiseif.addr, body_insns: body,
      except_jump_srcs: except_jump_srcs }
  end

  # ENSURE_RAII_SUPPORT: the opening half of an ensure region: `{`, the ensure
  # body compiled into a by-reference lambda, and the guard whose destructor
  # runs it. Returns [text, ok]; ok false (a body instruction failed) makes
  # compile_method emit nothing, keeping `#error`.
  # The lambda captures `[&]`, so it uses the function's own `rN` locals. Those
  # are declared at the top, before the guard, so reverse destruction order
  # keeps them alive when the guard runs.
  def emit_ensure_guard(region, irep, d)
    body = String.new
    ok = true
    # The ensure body's branches target the body or the RAISEIF; both become
    # labels inside the lambda, so compile_insn's gotos need no rewriting.
    body_targets = region[:body_insns].filter_map { |i| ensure_jump_target(i) }.to_set
    region[:body_insns].each do |insn|
      idx = irep.instructions.index(insn)
      body << "    L#{insn.addr}:;\n" if body_targets.include?(insn.addr)
      code = compile_insn(insn, irep, d, idx)
      ok = false if code.include?('#error')
      body << code
    end
    # mrbc's "skip the rest of the ensure body" target (RAISEIF) means "the
    # lambda is done".
    body << "    L#{region[:raiseif_addr]}:;\n" if body_targets.include?(region[:raiseif_addr])
    text = String.new
    text << "  { // ensure region [#{region[:begin_addr]}, #{region[:except_addr]})\n"
    text << "  auto bc2cpp_ensure_fn = [&]() {\n"
    text << body
    text << "  };\n"
    text << "  bc2cpp_ensure_guard<decltype(bc2cpp_ensure_fn)> " \
            "bc2cpp_ensure_g{M, bc2cpp_ensure_fn};\n"
    text << "  (void)bc2cpp_ensure_g;\n"
    [text, ok]
  end

  # RESCUE_SUPPORT: recognize `begin BODY rescue C => e; HANDLER; end` (also a
  # whole-method `rescue` and the `EXPR rescue FALLBACK` modifier: same
  # EXCEPT/RESCUE/RAISEIF shape). Chained single-class clauses and namespaced
  # classes are supported (recognize_rescue_class_handler), and proper nesting
  # (NESTED_RESCUE_SUPPORT). Not supported: `retry`, `ensure`, a multi-class
  # clause `rescue A, B`, partial overlap. Unrecognized shapes keep
  # `#error unhandled opcode EXCEPT`: RESCUE/RAISEIF translate anywhere, but
  # EXCEPT only means something inside this mrb_protect_error wrapping.
  #
  # Shape behind a "catch type: rescue" entry (checked against mrbc -v):
  #
  #   [begin, end)   -- the protected computation itself (BODY above).
  #   end            -- exactly one instruction, `JMP S` -- BODY's own
  #                     normal (non-raising) exit, landing on address S,
  #                     which every rescue-match path also converges on
  #                     (a final RETURN/RETURN_BLK for a whole-method
  #                     rescue, otherwise just the next instruction).
  #   target         -- exactly `EXCEPT Rexc` (captures the raised
  #                     exception -- mrb->exc -- into Rexc, clearing it).
  #   target+1..    -- one or more chained rescue CLAUSE TESTS: a class
  #                     chain (`GETCONST Rcls <Root>`, then zero or more
  #                     `GETMCNST Rcls (Rcls)::<Seg>`), `RESCUE Rexc Rcls`,
  #                     `JMPIF Rcls match`, `JMP next` (the next clause's
  #                     test head, or `raise` for the last clause); see
  #                     recognize_rescue_class_handler.
  #   raise          -- exactly `RAISEIF Rexc` (re-raises unless nil).
  #
  # Rexc is also the register holding the construct's RESULT on every path:
  # codegen_rescue compiles BODY at cursp(), takes `exc = cursp()` for
  # OP_EXCEPT, and compiles each handler at the same cursp(). So the value
  # flowing into S is always r<exc_reg>, whatever instruction S is.
  # emit_rescue_glue's early return for a RETURN/RETURN_BLK S is only a
  # shortcut; the goto-to-S path is correct for both.
  # Every address in the chain is cross-checked.
  #
  # DEFINED_CONST_RESCUE_SUPPORT: a second shape, the compiler-generated
  # `defined?` constant probe (a bare EXCEPT, no RESCUE); see
  # recognize_defined_const_handler.
  #
  # Returns one Hash per non-nested handler:
  # {begin_addr:, end_addr:, except_addr:, exc_reg:, cls_name:, match_addr:,
  #  raise_addr:, shared_target:, connector_reg:, tail_return:, kind:}.
  # `kind` is :rescue_class or :defined_const; the emitters read neither
  # it nor cls_name/match_addr/raise_addr (nil for :defined_const).
  def recognize_rescue_regions(irep)
    return [] if irep.catch_handlers.nil? || irep.catch_handlers.empty?
    return [] unless irep.catch_handlers.all? { |ch| ch.type == :rescue }

    by_addr = irep.instructions.each_with_object({}) { |insn, h| h[insn.addr] = insn }
    by_index = irep.instructions.each_with_index.to_h

    regions = []
    irep.catch_handlers.each do |ch|
      b, e, t = ch.begin_addr, ch.end_addr, ch.target
      # NESTED_RESCUE_SUPPORT: proper nesting (one range inside another, e.g. a
      # `(x rescue nil)` modifier inside a method-level rescue) is allowed. Only a
      # partial overlap, which mrbc never produces, is rejected: it would mean the
      # shape assumptions are wrong. compile_method and emit_rescue_try_body each
      # claim only top-level regions of their scope (top_level_rescue_regions);
      # nested ones become further-nested try-body functions.
      next if irep.catch_handlers.any? do |o|
        next false if o == ch

        overlaps = o.begin_addr <= e && b <= o.end_addr
        nested = (o.begin_addr <= b && e <= o.end_addr) || (b <= o.begin_addr && o.end_addr <= e)
        overlaps && !nested
      end

      except_i = by_addr[t]
      next unless except_i && except_i.op == 'EXCEPT'
      exc_reg = except_i.args[/^R(\d+)/, 1]
      next unless exc_reg

      # Two exclusive handler shapes, each with its own recognizer (nil means "not
      # this shape"): the classic `rescue SomeClass` chain, and the `defined?`
      # constant probe (see recognize_defined_const_handler).
      handler = recognize_rescue_class_handler(irep, by_addr, by_index, except_i, exc_reg) ||
                recognize_defined_const_handler(irep, by_index, except_i, exc_reg, b, e)
      next unless handler

      cls_name = handler[:cls_name]
      match_addr = handler[:match_addr]
      raise_addr = handler[:raise_addr]

      exit_i = by_addr[e]
      next unless exit_i && exit_i.op == 'JMP'
      shared_target = exit_i.args.strip[/\d+/].to_i
      # shared_target can never be this region's except_addr in mrbc output
      # (OP_EXCEPT is emitted before the success JMP is patched); rejected anyway,
      # since that address is suppressed and has no label.
      next if shared_target == t
      shared_i = by_addr[shared_target]
      next unless shared_i
      # DEFINED_CONST_RESCUE_SUPPORT: the success path must land on `STRING
      # R<exc_reg> L[n]` (codegen_defined_const's "constant" push,
      # patches/mruby-defined-keyword.patch), which overwrites r<exc_reg>. That makes
      # the try body's result dead on success; anything else is unverified.
      if handler[:kind] == :defined_const
        next unless shared_i.op == 'STRING' && shared_i.args[/^R(\d+)/, 1] == exc_reg
        next unless handler[:join_addr] > shared_target
      end
      # connector_reg is always exc_reg (see the header). tail_return stays a
      # checked distinction: emit_rescue_glue takes the early return only then, and
      # verifies connector_reg against the RETURN operand.
      tail_return = %w[RETURN RETURN_BLK].include?(shared_i.op)
      connector_reg = exc_reg
      if tail_return
        tail_reg = shared_i.args.strip.empty? ? '0' : shared_i.args[/^R(\d+)/, 1]
        next unless tail_reg == connector_reg
      end

      # Containment, checked by jump SOURCE address:
      #   1. No jump from outside [b, e] may target inside it, except a jump from
      #      strictly before `b` landing exactly on `b` (an `if ...; return; end`
      #      guard or an optional-argument default dispatch entering the region).
      #      A `retry` would jump back from the handler, after `e`, so it is still
      #      rejected.
      #   2. No jump from inside [b, e) may leave it; the only exits are `e`
      #      (checked above) or a raise (mrb_protect_error's job).
      jump_target_of = lambda do |insn|
        case insn.op
        when 'JMP' then insn.args.strip[/\d+/].to_i
        when 'JMPNOT', 'JMPIF', 'JMPNIL' then jmp_target_after_reg(insn.args)
        end
      end
      escapes = irep.instructions.any? do |src|
        tgt = jump_target_of.call(src)
        next false unless tgt
        if src.addr >= b && src.addr < e
          !(tgt >= b && tgt <= e) # (2): an internal source jumping outside the region
        elsif src.addr < b && tgt == b
          false # legitimate explicit-branch entry into the region, see above
        else
          tgt >= b && tgt <= e # (1): an external source jumping into the region
        end
      end
      next if escapes

      regions << { begin_addr: b, end_addr: e, except_addr: t, exc_reg: exc_reg, cls_name: cls_name,
                   match_addr: match_addr, raise_addr: raise_addr, shared_target: shared_target,
                   connector_reg: connector_reg, tail_return: tail_return, kind: handler[:kind] }
    end
    regions
  end

  # RESCUE_SUPPORT: the classic `rescue SomeClass` handler shape. Returns nil
  # unless it matches completely.
  #
  # NAMESPACED_RESCUE_SUPPORT / MULTI_RESCUE_SUPPORT: a clause-chain walk.
  # (a) A namespaced class (`rescue RGSS::Timeout`, RPG2k#start):
  #
  #       catch type: rescue   begin: 0004 end: 0011 target: 0014
  #        004 BLOCK     R3  I[0]
  #        007 SSENDB    R2  :loop  n=0
  #        011 JMP       039           <- e, the non-raising exit
  #        014 EXCEPT    R2            <- t
  #        016 GETCONST  R3  RGSS      <- class chain ROOT
  #        019 GETMCNST  R3  (R3)::Timeout   <- ...and its one segment
  #        022 RESCUE    R2  R3
  #        025 JMPIF     R3  032       <- match
  #        029 JMP       037           <- no match: straight to RAISEIF
  #        032 LOADNIL   R2  (nil)     <- the (empty) handler body
  #        034 JMP       039
  #        037 RAISEIF   R2
  #        039 RETURN    R2            <- shared_target
  #
  # (b) Chained clauses (RGSS::Graphics.singleton#_transition_map):
  #
  #       catch type: rescue   begin: 0004 end: 0038 target: 0041
  #        038 JMP       166           <- e; shared_target 166
  #        041 EXCEPT    R4            <- t
  #        043 GETCONST  R5  Bitmap              -- clause 1 test
  #        046 GETMCNST  R5  (R5)::LoadError
  #        049 RESCUE    R4  R5
  #        052 JMPIF     R5  059       <- match -> body 1
  #        056 JMP       105           <- NO match -> clause 2's GETCONST
  #        059 ... body 1 ...
  #        102 JMP       166           <- body 1 converges on shared_target
  #        105 GETCONST  R5  StandardError      -- clause 2 test
  #        108 RESCUE    R4  R5
  #        111 JMPIF     R5  118       <- match -> body 2
  #        115 JMP       164           <- NO match -> RAISEIF (last clause)
  #        118 ... body 2 ...
  #        161 JMP       166
  #        164 RAISEIF   R4
  #        166 RETURN    R4            <- shared_target
  #
  # Each clause's no-match JMP must land on the next clause's GETCONST or on
  # `RAISEIF Rexc` (first-match-wins). vm.c OP_RESCUE is only `regs[b] =
  # mrb_bool_value(mrb_obj_is_kind_of(mrb, exc, ec))` and OP_RAISEIF re-raises
  # regs[a] unless nil.
  # Soundness of chaining: the no-match path never enters a handler body (bodies
  # clobber r<exc_reg> but are only reached via a matched JMPIF and exit to
  # shared_target), and GETCONST/GETMCNST/RESCUE/JMPIF/JMP never write
  # r<exc_reg> (`cls_reg != exc_reg` is checked), so the exception is intact at
  # every later RESCUE.
  # Nothing downstream changes: cls_name/match_addr/raise_addr are not read by
  # any emitter; compile_method suppresses [begin_addr, end_addr] and
  # except_addr only and compiles everything after through compile_insn, which
  # translates each of these opcodes unconditionally. The protected range and
  # its checks are untouched.
  def recognize_rescue_class_handler(irep, by_addr, by_index, except_i, exc_reg)
    clause_idx = by_index[except_i]
    return nil unless clause_idx

    clause_idx += 1
    cls_names = []
    first_match_addr = nil

    loop do
      # The class name: a GETCONST root then GETMCNST segments, all reading and
      # writing the root's register; anything else is rejected.
      getconst_i = irep.instructions[clause_idx]
      return nil unless getconst_i && getconst_i.op == 'GETCONST'
      cls_reg = getconst_i.args[/^R(\d+)/, 1]
      cls_name = getconst_i.args[/^R\d+\s+(\S+)/, 1]
      return nil unless cls_reg && cls_name
      # The class chain must not target the exception register (RESCUE/RAISEIF
      # still need it); codegen_rescue puts it at cursp() above exc, checked here.
      return nil if cls_reg == exc_reg

      seg_idx = clause_idx + 1
      while (seg_i = irep.instructions[seg_idx]) && seg_i.op == 'GETMCNST'
        seg_m = seg_i.args.strip.match(/^R#{cls_reg}\s+\(R#{cls_reg}\)::(\S+?)\s*(?:;.*)?$/)
        return nil unless seg_m
        cls_name = "#{cls_name}::#{seg_m[1]}"
        seg_idx += 1
      end

      rescue_i, jmpif_i, jmp_i = irep.instructions[seg_idx, 3]
      return nil unless rescue_i && jmpif_i && jmp_i
      return nil unless rescue_i.op == 'RESCUE' && rescue_i.args.strip =~ /^R#{exc_reg}\s+R#{cls_reg}$/
      return nil unless jmpif_i.op == 'JMPIF' && jmpif_i.args[/^R(\d+)/, 1] == cls_reg

      match_addr = jmp_target_after_reg(jmpif_i.args)
      return nil unless match_addr && match_addr > jmpif_i.addr
      return nil unless jmp_i.op == 'JMP'
      next_addr = jmp_i.args.strip[/\d+/].to_i
      # Strictly forward: bounds the walk and excludes a backward `retry`.
      return nil unless next_addr > jmp_i.addr

      cls_names << cls_name
      first_match_addr ||= match_addr

      next_i = by_addr[next_addr]
      return nil unless next_i

      # Last clause: the no-match path re-raises.
      if next_i.op == 'RAISEIF'
        return nil unless next_i.args[/^R(\d+)/, 1] == exc_reg

        return { kind: :rescue_class, cls_name: cls_names.join(', '),
                 match_addr: first_match_addr, raise_addr: next_addr }
      end

      # Otherwise it must be the next clause's class-test head, never a handler
      # body (the soundness property above).
      return nil unless next_i.op == 'GETCONST'

      clause_idx = by_index[next_i]
      return nil unless clause_idx
    end
  end

  # DEFINED_CONST_RESCUE_SUPPORT: the other shape behind a "catch type: rescue"
  # entry: this repo's `defined?(CONST)` / `defined?(A::B)` / `defined?(::B)`
  # (patches/mruby-defined-keyword.patch; upstream codegen_defined returns nil).
  # It has no RESCUE and no RAISEIF, e.g. RPG2k::Scene::Map#try_open_debug_menu:
  #
  #   catch type: rescue   begin: 0051 end: 0057 target: 0060
  #    051 GETCONST  R2  Scene            <- b, the probe itself
  #    054 GETMCNST  R2  (R2)::DebugMenu
  #    057 JMP       067                  <- e, the non-raising exit
  #    060 EXCEPT    R2                   <- t, a BARE EXCEPT
  #    062 LOADNIL   R2  (nil)
  #    064 JMP       070                  <- join, past the STRING
  #    067 STRING    R2  L[0]  ; constant <- shared_target
  #    070 JMPIF     R2  075
  #
  # Sound with the existing mrb_protect_error machinery and no new emitter:
  #  1. emit_rescue_glue's non-tail_return output is exactly right: on success
  #     its assignment is overwritten by the STRING; on failure the exception
  #     lands in r<exc_reg> and falls through to the LOADNIL, as EXCEPT would.
  #  2. The handler is two ordinary instructions (LOADNIL, JMP), compiled
  #     normally.
  #  3. The protected range must have no live-in registers:
  #     emit_rescue_try_body nil-initializes everything but self and mandatory
  #     arguments, which is only valid at a region entered right after ENTER,
  #     and a `defined?` probe can sit anywhere. `defined?(x.bar::Baz)` reads a
  #     live local inside the range, so only these chains are accepted (all on
  #     r<exc_reg>, codegen_defined_const's `r = cursp()`):
  #     GETCONST Rd <Name>                                (`defined?(C)`)
  #     GETCONST Rd <Base>  (GETMCNST Rd (Rd)::<Name>)+   (`defined?(A::B)`)
  #     OCLASS   Rd         (GETMCNST Rd (Rd)::<Name>)+   (`defined?(::B)`)
  #     Each writes r<exc_reg> before reading it and calls no Ruby method, so
  #     the only live-in is `self` (for GETCONST's lexical lookup).
  # codegen_defined_const is the only catch_handler_new the patch adds, so no
  # other compiler-generated rescue region exists.
  # Returns {kind:, cls_name:, match_addr:, raise_addr:, join_addr:}; the three
  # classic fields are nil and unused by the emitters.
  def recognize_defined_const_handler(irep, by_index, except_i, exc_reg, b, e)
    idx = by_index[except_i]
    seq = irep.instructions[idx + 1, 2]
    return nil unless seq && seq.size == 2

    loadnil_i, jmp_i = seq
    return nil unless loadnil_i.op == 'LOADNIL' && loadnil_i.args[/^R(\d+)/, 1] == exc_reg
    return nil unless jmp_i.op == 'JMP'

    join_addr = jmp_i.args.strip[/\d+/].to_i
    # The handler only runs forward into the join.
    return nil unless join_addr > jmp_i.addr

    body = irep.instructions.select { |i| i.addr >= b && i.addr < e }
    head, *rest = body
    return nil unless head
    case head.op
    when 'GETCONST'
      return nil unless head.args[/^R(\d+)/, 1] == exc_reg && head.args[/^R\d+\s+(\S+)/, 1]
    when 'OCLASS'
      # `::Name` always has a GETMCNST after OCLASS; a lone OCLASS cannot raise and
      # is never emitted by codegen_defined_const.
      return nil unless head.args[/^R(\d+)/, 1] == exc_reg && !rest.empty?
    else
      return nil
    end
    rest.each do |i|
      return nil unless i.op == 'GETMCNST'
      return nil unless i.args.strip =~ /^R#{exc_reg}\s+\(R#{exc_reg}\)::\w+\s*(;.*)?$/
    end

    { kind: :defined_const, cls_name: nil, match_addr: nil, raise_addr: nil, join_addr: join_addr }
  end

  # NESTED_RESCUE_SUPPORT: the regions not contained in another region of the
  # same list: what the current scope (compile_method, or emit_rescue_try_body
  # for its own range) claims directly; nested ones are left to the child's
  # recursive extraction.
  def top_level_rescue_regions(regions)
    regions.reject do |r|
      regions.any? { |o| o != r && o[:begin_addr] <= r[:begin_addr] && r[:end_addr] <= o[:end_addr] }
    end
  end

  # RESCUE_SUPPORT: the extracted try body for one region, a top-level static
  # function (mrb_protect_error takes a C function pointer; see
  # emit_const_lookup_helper). It covers [begin_addr, end_addr] including the
  # exit JMP, which becomes a C++ `return` of the value the JMP would pass on
  # (the function's result is mrb_protect_error's result on success). A
  # by-value Ctx carries self and the mandatory arguments; mrb_protect_error's
  # `void*` is its address. Other registers are temporaries, declared and
  # nil-initialized like `_impl`'s preamble; internal jumps use the usual labels.
  # `extra_fields` ([{name:, c_type:}]) adds Ctx members restored into
  # same-named locals: BLOCK_FALLBACK_RESCUE_SUPPORT passes captured upvar
  # pointers (`bc2cpp_upvar_N`), so GETUPVAR/SETUPVAR (keyed by name) work
  # unchanged.
  # DEEP_UPVAR_CAPTURE_SUPPORT: `available_upvars` is the enclosing function's
  # captured-pointer set (empty for a method-level rescue), threaded in by name
  # via `extra_fields`, so nested block calls may forward them further.
  # rescue_entry_saved_fields: self + raw arguments are the whole live-in state
  # only when begin_addr directly follows ENTER. A region entered by a branch
  # (an optional default like `def drive_battle(it = @interpreter)`, or an `if
  # ...; return; end` guard) can have any register set, so the whole register
  # file is captured by value, as for NESTED_RESCUE_SUPPORT.
  def rescue_entry_saved_fields(irep, region)
    return [] if irep.instructions.all? { |insn| insn.addr >= region[:begin_addr] || insn.op == 'ENTER' }

    (1...irep.nregs).map { |i| { name: "bc2cpp_saved_r#{i}", c_type: 'mrb_value' } }
  end

  def emit_rescue_try_body(try_name, region, irep, d, arg_names, arg_native_types, extra_fields: [],
                           available_upvars: [])
    ctx_struct = "#{try_name}_Ctx"
    ctx_fields = ['mrb_value self'] + arg_names.each_with_index.map { |a, i| "#{native_c_type(arg_native_types[i])} #{a}" } +
                 extra_fields.map { |f| "#{f[:c_type]} #{f[:name]}" }
    # RESCUE_BODY_BLOCK_SUPPORT: block-carrying calls inside the protected range
    # (`RGSS::Profiler.section("...") { ... }` in RPG2k#start_new_game) go through
    # emit_block_fallback_glue_pass like compile_method's top-level pass,
    # restricted to [begin_addr, end_addr]. The top-level pass never claims them
    # (this range is already in its `suppressed`). Local suppressed/glue_at: a
    # separate C++ function. Emitted before this function's opening brace, since
    # a cfunc cannot be defined inside another function.
    range = (region[:begin_addr]..region[:end_addr])
    local_suppressed = Set.new
    local_glue_at = {}
    # NESTED_RESCUE_SUPPORT: nested rescue ranges are claimed before the
    # block-fallback pass, as compile_method does, so a block inside a nested
    # region belongs to that region's recursive extraction. Claiming it here too
    # would emit the same block function twice (`redefinition of ...`).
    nested_rescue_regions = top_level_rescue_regions(
      recognize_rescue_regions(irep).select do |r|
        r != region && region[:begin_addr] <= r[:begin_addr] && r[:end_addr] <= region[:end_addr]
      end
    )
    nested_rescue_regions.each do |nregion|
      local_suppressed.merge((nregion[:begin_addr]..nregion[:end_addr]).to_a)
      local_suppressed << nregion[:except_addr]
    end
    nested_block_regions = recognize_block_fallback_regions(irep, available_upvars: available_upvars)
                           .select { |r| range.cover?(r[:block_addr]) }
    nested_arg_regions = recognize_explicit_block_arg_regions(irep).select { |r| range.cover?(r[:sendb_addr]) }
    out = emit_block_fallback_glue_pass(nested_block_regions, nested_arg_regions, d, local_suppressed, local_glue_at)

    # NESTED_RESCUE_SUPPORT: each direct child region gets its own further-nested
    # try body. Its begin_addr is reached after arbitrary code in this body, so
    # its live-in state may be any register: the whole register file r1..nregs-1
    # (all plain mrb_values) is captured by value via extra_fields/
    # extra_field_values, the mechanism upvar pointers already use. This body's
    # own extra_fields are inherited too. arg_names/arg_native_types are empty for
    # the recursive call (no named argument locals exist here). The init loop
    # below uses a `bc2cpp_saved_r<N>` field instead of nil when present.
    saved_regs = (1...irep.nregs).to_a
    nested_saved_fields = saved_regs.map { |i| { name: "bc2cpp_saved_r#{i}", c_type: 'mrb_value' } }
    # This body's own saved-register fields are superseded by the fresh capture.
    inherited_fields = extra_fields.reject { |f| f[:name].start_with?('bc2cpp_saved_r') }
    nested_extra_fields = inherited_fields + nested_saved_fields
    nested_extra_values = inherited_fields.map { |f| f[:name] } + saved_regs.map { |i| "r#{i}" }
    nested_rescue_regions.each_with_index do |nregion, ni|
      # (Already claimed into local_suppressed above.)
      nested_try_name = "#{try_name}_nested#{nested_rescue_regions.size > 1 ? "_#{ni}" : ''}"
      out << emit_rescue_try_body(nested_try_name, nregion, irep, d, [], [], extra_fields: nested_extra_fields,
                                                                            available_upvars: available_upvars)
      local_glue_at[nregion[:begin_addr]] =
        emit_rescue_glue(nested_try_name, nregion, [], [], extra_field_values: nested_extra_values)
    end

    out << "struct #{ctx_struct} { #{ctx_fields.join('; ')}; };\n"
    out << "static mrb_value #{try_name}(mrb_state* M, void* ud) {\n"
    out << "  #{ctx_struct}* ctx = (#{ctx_struct}*)ud;\n"
    extra_fields.each { |f| out << "  #{f[:c_type]} #{f[:name]} = ctx->#{f[:name]};\n" }
    (0...irep.nregs).each do |i|
      if i.zero?
        # GETIV/SETIV codegen uses the bare identifier `self`; this function receives
        # it through ctx, so alias it.
        out << "  mrb_value self = ctx->self;\n"
        out << "  mrb_value r0 = self;\n"
      elsif (saved = extra_fields.find { |f| f[:name] == "bc2cpp_saved_r#{i}" })
        # A saved-register capture is the register's value at begin_addr, so it wins
        # over the raw argument (an optional default may have replaced it).
        out << "  mrb_value r#{i} = #{saved[:name]};\n"
      elsif i <= arg_names.size
        a = arg_names[i - 1]
        t = arg_native_types[i - 1]
        out << if t
                  "  mrb_value r#{i} = #{TYPE_OPS.fetch(t)[:box]}(ctx->#{a});\n"
                else
                  "  mrb_value r#{i} = ctx->#{a};\n"
                end
      else
        out << "  mrb_value r#{i} = mrb_nil_value();\n"
      end
    end
    body_targets = jump_targets(irep).select { |t| t >= region[:begin_addr] && t <= region[:end_addr] } -
                   (local_suppressed.to_a - local_glue_at.keys)
    irep.instructions.each_with_index do |insn, idx|
      next unless insn.addr >= region[:begin_addr] && insn.addr <= region[:end_addr]
      next if local_suppressed.include?(insn.addr) && !local_glue_at.key?(insn.addr)

      out << "  L#{insn.addr}:;\n" if body_targets.include?(insn.addr)
      out << if insn.addr == region[:end_addr]
                "  return r#{region[:connector_reg]};\n"
              else
                local_glue_at[insn.addr] || compile_insn(insn, irep, d, idx)
              end
    end
    out << "  return mrb_nil_value(); // unreachable\n"
    out << "}\n\n"
    out
  end

  # RESCUE_SUPPORT: glue at begin_addr replacing [begin_addr, end_addr]: run the
  # try body under mrb_protect_error (vm.c), which returns the body's result with
  # err == FALSE, or the exception with err == TRUE, exception state cleared and
  # the ci stack unwound to here. On failure assign the exception to r<exc_reg>
  # and fall through into the clause tests (EXCEPT itself is suppressed).
  # On success:
  #   tail_return  -- a whole-method rescue: `return` the result directly.
  #   otherwise    -- assign it to r<connector_reg> (== r<exc_reg>) and goto
  #                   shared_target, which is a real jump target and so has a
  #                   label.
  # `extra_field_values`: C++ expressions for emit_rescue_try_body's
  # `extra_fields`, appended in order to the aggregate `ctx{...}` initializer.
  def emit_rescue_glue(try_name, region, arg_names, arg_native_types, extra_field_values: [])
    ctx_struct = "#{try_name}_Ctx"
    ctx_args = (['self'] + arg_names + extra_field_values).join(', ')
    err_var = "#{try_name}_err"
    result_var = "#{try_name}_result"
    out = String.new
    out << "  {\n"
    out << "    #{ctx_struct} ctx{#{ctx_args}};\n"
    out << "    mrb_bool #{err_var} = FALSE;\n"
    out << "    mrb_value #{result_var} = mrb_protect_error(M, #{try_name}, &ctx, &#{err_var});\n"
    out << if region[:tail_return]
              "    if (!#{err_var}) { return #{result_var}; }\n"
            else
              "    if (!#{err_var}) { r#{region[:connector_reg]} = #{result_var}; goto L#{region[:shared_target]}; }\n"
            end
    out << "    r#{region[:exc_reg]} = #{result_var};\n"
    out << "  }\n"
    out
  end
end
