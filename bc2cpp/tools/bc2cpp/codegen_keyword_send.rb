# frozen_string_literal: true

# CodeGen: keyword and splat sends.

class CodeGen
  # compile_keyword_send (below), KEYWORD_CALLSITE_SUPPORT: compile a SEND/SSEND
  # with keyword arguments (`n=2|nk=1`) into a direct `_impl` call, or return nil
  # (the caller keeps `#error`). Direct call only: mrb_funcall* can never carry
  # keywords (`ci->nk = 0` in funcall_args_capture, vm.c); only OP_SEND packs
  # them, and the callee's `_impl` takes each keyword as parameters.
  # Layout (`SSEND R9 :deal_attack n=3|nk=1`): n positionals after the
  # destination, then nk (sym, value) pairs. Only literal keys (a LOADSYM,
  # verified by backward scan) are supported. The callee must be MONO, compile
  # clean, have a keyword_arg_table covering the keys, and match the positional
  # arity. A missing optional keyword passes mrb_nil_value() + given=0 (what
  # the entry wrapper does); a missing required one is refused (the interpreter
  # would raise ArgumentError).
  #
  # literal_symbol_write: was `reg`'s most recent write (scanning back from
  # `before_idx`, inclusive) a `LOADSYM :name`? Shared by compile_keyword_send
  # and splat_hash_literal_pairs.
  def literal_symbol_write(irep, before_idx, reg)
    before_idx.downto(0) do |i|
      insn = irep.instructions[i]
      next unless insn
      # A write to this register ends the scan -- it must be LOADSYM.
      next unless insn.args =~ /^R#{reg}\b/

      return nil unless insn.op == 'LOADSYM'

      return insn.args[/:(\S+)/, 1]&.sub(/\A:/, '')
    end
    nil
  end

  # KEYWORD_CALLSITE_SUPPORT: the shared tail of compile_keyword_send (MONO
  # resolution, keyword/arity checks, `_impl` call), reused by compile_splat_send
  # for unrolled splat register lists. argv/kw_val_exprs are C++ expressions.
  def compile_keyword_call(name:, d:, recv:, n:, argv:, kw_names:, kw_val_exprs:,
                           self_implicit: false, owner_def: nil)
    # MONO only, no TYPED: the guard's else branch would need a dynamic keyword
    # dispatch, which mrb_funcall cannot express. MONO needs no guard.
    target = monomorphic_target(name)
    # LEXICAL_SELF_KEYWORD_SUPPORT: a POLY name can still have one reachable
    # definition for an implicit-self send in a class with no subclasses (see
    # lexical_self_keyword_target). A certain, not traced, fact, so no guard or
    # fallback; the checks below apply unchanged. Only consulted after
    # monomorphic_target declined.
    lexical_self = false
    if target.nil?
      target = lexical_self_keyword_target(name, self_implicit: self_implicit, owner_def: owner_def)
      lexical_self = !target.nil?
    end
    return nil unless target&.irep

    # monomorphic_target already checked compiles_clean?; fetch the irep for the
    # checks below.
    callee_irep = @ireps.fetch(target.irep)
    kw_table = keyword_arg_table(callee_irep)
    return nil unless kw_table
    # KEYWORD_CALLSITE_OPTIONAL_POSITIONAL_SUPPORT: the callee's positional arity
    # is [mand, mand + opt]; with opt 0 this is the old exact match.
    # Sound per vm.c OP_ENTER with kd set: OP_SEND packs the nk pairs into one Hash
    # at regs[mrb_ci_kidx(ci)] and sets `ci->nk = CALL_MAXARGS`, so argc counts
    # positionals only (the `!kd` fold-back arm is unreachable since
    # keyword_arg_table requires kw > 0). Optional-slot resolution is then a
    # function of argc alone: the check admits m1 <= argc <= len (len = m1 + o
    # here) and the initializer skip picks jump-table entry argc - m1, which is
    # `bc2cpp_given_opt`; the call site's static `n - t_mand` reproduces it.
    # optional_arg_table's jump targets must have resolved (not just opt > 0),
    # since bc2cpp_given_opt only means this when the callee's dispatch switch was
    # emitted.
    t_mand = mandatory_arity(callee_irep)
    t_opt = optional_arity(callee_irep)
    return nil unless n.between?(t_mand, t_mand + t_opt)
    return nil if t_opt.positive? && !optional_arg_table(callee_irep)[1]
    return nil unless (kw_names - kw_table.map { |k| k[:name] }).empty?

    # Every required keyword must be present, or the interpreter raises
    # ArgumentError.
    required = kw_table.select { |k| k[:required] }.map { |k| k[:name] }
    return nil unless (required - kw_names).empty?

    # Same emission-eligibility guard as compile_send: no `_impl` for owners this
    # run does not emit.
    if @only_owners && !@only_owners.include?(target.owner)
      return nil unless @other_owners&.include?(target.owner)
    end
    impl = cpp_name(target.owner, target.name) + '_impl'
    # KEYWORD_CALLSITE_ARITY_FIX: the argument list must match the callee's
    # `_impl` exactly: compile_method adds `mrb_int bc2cpp_kw_given_<name>` only
    # for OPTIONAL keywords (`kw[:required] ? [value] : [value, given]`), since
    # mrb_get_args already guarantees required ones. Emitting a flag for every
    # keyword shifted later arguments (g++: "could not convert '1'" / "too many
    # arguments").
    # A required keyword is never absent here (refused above), so the
    # "not passed" arm applies only to optional keywords.
    kw_args = kw_table.flat_map do |kw|
      ci = kw_names.index(kw[:name])
      val = ci ? kw_val_exprs[ci] : 'mrb_nil_value()'
      kw[:required] ? [val] : [val, ci ? '1' : '0']
    end
    # KEYWORD_CALLSITE_OPTIONAL_POSITIONAL_SUPPORT: `_impl`'s parameters are all
    # `mand + opt` positionals, then `mrb_int bc2cpp_given_opt` when opt > 0, then
    # the keywords, e.g.
    #
    #   mrb_value Game__Battle_deal_attack_impl(mrb_state* M, mrb_value self,
    #       mrb_value b, mrb_value target, mrb_value swing_index,
    #       mrb_int bc2cpp_given_opt,
    #       mrb_value bc2cpp_kwarg_charged, mrb_int bc2cpp_kw_given_charged)
    #
    # so the padding goes BEFORE kw_args (appending would shift every keyword, the
    # KEYWORD_CALLSITE_ARITY_FIX error class). Omitted optionals get
    # mrb_nil_value(), never read because the callee's switch jumps to the default
    # code, which overwrites the register.
    opt_args = []
    if t_opt.positive?
      opt_args = Array.new(t_mand + t_opt - argv.size, 'mrb_nil_value()')
      opt_args << (argv.size - t_mand).to_s
    end
    call = "r#{d} = #{impl}(M, #{([recv] + argv + opt_args + kw_args).join(', ')});"
    # LEXICAL_SELF_KEYWORD_SUPPORT: a marker distinct from MONO (one definition
    # program-wide vs. a provably exact self class), spelled like compile_send's
    # LEXICAL_SELF, and absent from RUNTIME_DEF_DYNAMIC_MARKERS so
    # runtime_def_devirt_audit checks it.
    note =
      if lexical_self
        "  // LEXICAL_SELF :#{name} -> #{target.owner}##{target.name} (keyword call; self, statically " \
          "known -- #{target.owner} has no subclasses anywhere in this closed world, so this " \
          "implicit-self send can reach no other definition of this POLY name), direct C++ call " \
          "(no mrb_funcall)\n"
      else
        "  // MONO :#{name} -> #{target.owner}##{target.name} (keyword call), direct C++ call (no mrb_funcall)\n"
      end
    "#{note}  #{call}\n"
  end

  def compile_keyword_send(args, self_implicit:, irep:, idx:, owner_def:, name:, d:, n:, nk:)
    dest_reg = d.to_i
    # Keyword (sym, value) pairs sit right after the n positionals.
    kw_sym_regs = (0...nk).map { |k| dest_reg + 1 + n + k * 2 }
    kw_val_regs = (0...nk).map { |k| dest_reg + 2 + n + k * 2 }
    # Every key register must be written by a literal LOADSYM (backward scan in
    # this irep).
    kw_names = kw_sym_regs.map { |reg| literal_symbol_write(irep, idx, reg) }
    return nil if kw_names.any?(&:nil?)

    recv = self_implicit ? 'self' : "r#{d}"
    argv = (1..n).map { |k| "r#{dest_reg + k}" }
    direct = compile_keyword_call(name: name, d: d, recv: recv, n: n, argv: argv,
                                  kw_names: kw_names, kw_val_exprs: kw_val_regs.map { |r| "r#{r}" },
                                  self_implicit: self_implicit, owner_def: owner_def)
    return direct if direct

    # KEYWORD_DIRECT_CONSTRUCT_SUPPORT: for `:new`, compile_keyword_call always
    # declines (Class#new has no `_impl`); the keywords belong to the target
    # class's #initialize. Tried before the Hash-as-positional fallback, which
    # correctly refuses real keyword callees.
    construct = compile_keyword_direct_construct(
      irep: irep, idx: idx, owner_def: owner_def, self_implicit: self_implicit,
      name: name, d: d, n: n, recv: recv, argv: argv, kw_names: kw_names,
      kw_val_exprs: kw_val_regs.map { |r| "r#{r}" }
    )
    return construct if construct

    # KEYWORD_HASH_POSITIONAL_SUPPORT: many sites compile_keyword_call declines are
    # not real keyword calls (the callee declares no keywords). `self_implicit`/
    # `owner_def` let that path use the lexical-self narrowing
    # (KEYWORD_HASH_LEXICAL_SELF_SUPPORT) when the every-def gate declines.
    hashpos = compile_keyword_hash_positional_send(name: name, d: d, recv: recv, n: n, nk: nk,
                                                   argv: argv, kw_sym_regs: kw_sym_regs,
                                                   kw_val_regs: kw_val_regs, kw_names: kw_names,
                                                   self_implicit: self_implicit, owner_def: owner_def)
    return hashpos if hashpos

    # KEYWORD_NEVER_DEFINED_CONST_RECEIVER_SUPPORT: tried last: every other proof
    # declined, but the receiver provably never exists at runtime (see
    # compile_keyword_never_defined_const_send).
    compile_keyword_never_defined_const_send(name: name, d: d, n: n, nk: nk, irep: irep, idx: idx,
                                             argv: argv, kw_sym_regs: kw_sym_regs,
                                             kw_val_regs: kw_val_regs, kw_names: kw_names,
                                             self_implicit: self_implicit)
  end

  # KEYWORD_DIRECT_CONSTRUCT_SUPPORT: `Foo.new(a, b, k1: v1, k2: v2)` where Foo
  # is in DIRECT_CONSTRUCT_TARGETS and its #initialize declares these keywords,
  # matched by name.
  #   * compile_keyword_call cannot fire: it resolves `:new` (Class#new, no
  #     `_impl`, no keywords); the keywords belong to Foo#initialize, found via
  #     trace_new_target.
  #   * compile_keyword_hash_positional_send must not fire: it relies on the
  #     callee declaring NO keywords (OP_ENTER's kd == 0 turns the Hash into a
  #     trailing positional). Here kd == 1, so that would drop the keywords.
  # Emits the guarded bc2cpp_direct_alloc + `_impl` construct of compile_send's
  # DIRECT_CONSTRUCT_TARGETS branch, with compile_keyword_call's (value, given)
  # keyword arguments.
  # Gate: compile_send's DIRECT_CONSTRUCT_TARGETS gate with
  # mandatory_optional_and_keyword_arity? in place of pure_mandatory_arity?,
  # plus:
  #   a. keywords matched by exact name, and every required keyword present;
  #   b. no `self.new`/`self.allocate` defined ANYWHERE in the closed world
  #      (some entries are subclasses, and an inherited custom `self.new` would
  #      defeat the construct; @superclass_of may lack computed superclasses, so
  #      the whole-program question is the sound one). Adding one shuts this
  #      path off;
  #   c. #initialize's return value is discarded (`.new` returns the object).
  # nil (a safe miss) otherwise.
  def compile_keyword_direct_construct(irep:, idx:, owner_def:, self_implicit:,
                                       name:, d:, n:, recv:, argv:, kw_names:, kw_val_exprs:)
    return nil unless name == 'new' && !self_implicit && irep && idx

    known = trace_new_target(irep, idx, d, nil, 0, nil, resolving_new: true, owner: owner_def&.owner,
                             canonical: false)
    return nil unless known && DIRECT_CONSTRUCT_TARGETS.include?(known)

    # 1/2: no custom `self.new`/`self.allocate` on this class ("X.singleton"), and
    # by (b) above none anywhere, which covers inherited ones.
    no_custom_new = @registry['new'].none? { |md| md.owner == "#{known}.singleton" }
    no_custom_allocate = @registry['allocate'].none? { |md| md.owner == "#{known}.singleton" }
    return nil unless no_custom_new && no_custom_allocate

    none_anywhere = (@registry['new'] + @registry['allocate'])
                    .none? { |md| md.owner.to_s.end_with?('.singleton') }
    return nil unless none_anywhere

    # 3: #initialize is a compiling positionals-plus-keywords leaf whose
    # positional arity range covers this call's count.
    init_def = @registry['initialize'].find { |md| md.owner == known }
    return nil unless init_def&.irep

    init_irep = @ireps.fetch(init_def.irep)
    return nil unless mandatory_optional_and_keyword_arity?(init_irep)
    return nil unless compiles_clean?(init_def.irep)

    # KEYWORD_CONSTRUCT_OPTIONAL_POSITIONAL_SUPPORT: #initialize's positional
    # arity is [mand, mand + opt] (0 optional for older entries: an exact match).
    # Class#new forwards all arguments to #initialize, so the OP_ENTER argument of
    # KEYWORD_CALLSITE_OPTIONAL_POSITIONAL_SUPPORT (compile_keyword_call) applies:
    # with kd set, argc counts positionals only and the jump-table entry is
    # argc - m1 = `bc2cpp_given_opt`. The optional table's jump targets must have
    # resolved.
    t_mand = mandatory_arity(init_irep)
    t_opt = optional_arity(init_irep)
    return nil unless n.between?(t_mand, t_mand + t_opt)
    return nil if t_opt.positive? && !optional_arg_table(init_irep)[1]

    # (a): exact keyword-name match, and every required keyword supplied.
    kw_table = keyword_arg_table(init_irep)
    return nil unless kw_table
    return nil unless (kw_names - kw_table.map { |k| k[:name] }).empty?

    required = kw_table.select { |k| k[:required] }.map { |k| k[:name] }
    return nil unless (required - kw_names).empty?

    # 4: the ONLY_OWNERS/OTHER_OWNERS emission guard.
    owner_emitted = !@only_owners || @only_owners.include?(known) || @other_owners&.include?(known)
    return nil unless owner_emitted

    @direct_construct_used << known
    accessor = direct_construct_class_fn(known)
    init_impl = cpp_name(known, 'initialize') + '_impl'
    # (value, given) arguments as in compile_keyword_call (see
    # KEYWORD_CALLSITE_ARITY_FIX).
    kw_args = kw_table.flat_map do |kw|
      ci = kw_names.index(kw[:name])
      val = ci ? kw_val_exprs[ci] : 'mrb_nil_value()'
      kw[:required] ? [val] : [val, ci ? '1' : '0']
    end
    # KEYWORD_CONSTRUCT_OPTIONAL_POSITIONAL_SUPPORT: `_impl` takes `mand + opt`
    # positionals, then `bc2cpp_given_opt`, then the keywords:
    #
    #   mrb_value Game__Battle_initialize_impl(mrb_state* M, mrb_value self,
    #       mrb_value allies, mrb_value enemies, mrb_value rng,
    #       mrb_value states, mrb_value variance, mrb_value criticals,
    #       mrb_value accuracy, mrb_value first_strike, mrb_value attributes,
    #       mrb_value ai, mrb_int bc2cpp_given_opt,
    #       mrb_value bc2cpp_kwarg_rpg2003, mrb_int bc2cpp_kw_given_rpg2003,
    #       mrb_value bc2cpp_kwarg_party,   mrb_int bc2cpp_kw_given_party,
    #       mrb_value bc2cpp_kwarg_battle_type,
    #       mrb_int bc2cpp_kw_given_battle_type);
    #
    # so padding is spliced before kw_args (as in compile_keyword_call).
    # Placeholders are never read (the default code overwrites them). A short
    # argument list would be a g++ error, so omitted optionals are padded.
    opt_args = []
    if t_opt.positive?
      opt_args = Array.new(t_mand + t_opt - argv.size, 'mrb_nil_value()')
      opt_args << (argv.size - t_mand).to_s
    end
    note = "  // MONO :new -> #{known}, direct compiled construct with real KEYWORD arguments " \
           "(bc2cpp_direct_alloc + #{init_impl}) -- skips Class#new's own allocate+initialize " \
           "dispatch chain entirely; #{known}#initialize's own return value is discarded (real " \
           "Ruby .new always returns the new object, never whatever #initialize itself returns).\n" \
           "  // The keywords here are REAL keyword parameters of #{known}#initialize (matched by " \
           "NAME against its own KEY_P/KARG table, not by count), passed as the same explicit " \
           "(value, given) pairs its compiled _impl signature already declares -- NOT packed into " \
           "a trailing positional Hash, which is only correct for a callee declaring no keywords " \
           "at all (vm.c OP_ENTER's own kd == 0 arm; see compile_keyword_hash_positional_send).\n" \
           "  // Runtime-guarded exactly the way the non-keyword direct-construct path is: " \
           "#{known} could have been reassigned at the constant level since #{accessor}'s own " \
           "class was captured at gem-init, so #{recv} (this call site's own already-resolved " \
           "receiver) is compared against it rather than trusted outright, falling back to " \
           "ordinary mrb_funcall if they differ.\n"
    # The guard-miss arm: mrb_funcall cannot carry keywords (`ci->nk = 0`), and
    # OP_ENTER has no trailing-Hash-to-keywords conversion for kd == 1, so a plain
    # funcall would silently drop them (and, the keywords being optional, not
    # raise). Instead the pairs are packed into one Hash passed as a trailing
    # positional, exactly what OP_SEND does before OP_ENTER (hash_new_from_regs;
    # see compile_keyword_hash_positional_send). The arm is only reachable if the
    # constant was reassigned after gem init; the keys come from the literal
    # symbols literal_symbol_write proved.
    kw_hash = String.new
    kw_hash << "    mrb_value bc2cpp_kwh = mrb_hash_new_capa(M, #{kw_names.size});\n"
    kw_names.each_with_index do |kn, k|
      kw_hash << "    mrb_hash_set(M, bc2cpp_kwh, " \
                 "mrb_symbol_value(mrb_intern_cstr(M, \"#{kn}\")), #{kw_val_exprs[k]});\n"
    end
    "#{note}" \
      "  if (mrb_class_ptr(#{recv}) == #{accessor}()) {\n" \
      "    r#{d} = bc2cpp_direct_alloc(M, mrb_class_ptr(#{recv}));\n" \
      "    #{init_impl}(M, #{(["r#{d}"] + argv + opt_args + kw_args).join(', ')});\n" \
      "  } else {\n" \
      "#{kw_hash}" \
      "    #{dynamic_dispatch_line(d, recv, name, argv + ['bc2cpp_kwh'])}" \
      "  }\n"
  end

  # KEYWORD_HASH_POSITIONAL_SUPPORT: a SEND/SSEND with `n=N|nk=K` whose callee
  # declares NO keyword parameters: the VM hands it one ordinary trailing
  # positional Hash (`def foo(opts)`). Only the call site needs work.
  # Callee entry shapes:
  #     def bar(h)      ->  ENTER 1:0:0:0:0:0:0:0   (kw=0, kwrest=0)
  #     def baz(a, h)   ->  ENTER 2:0:0:0:0:0:0:0
  #     def kw(a, name: nil, x: 0)
  #                     ->  ENTER 1:0:0:0:2:0:0:0   (kw=2), then KEY_P ... KEYEND
  # and the call-site layout is compile_keyword_send's (n positionals, then K
  # (sym, value) pairs):
  #   f.bar(name: 1, x: 2)     ->  19 022 LOADSYM  R3  :name
  #                                19 025 LOADI_1  R4  (1)
  #                                19 027 LOADSYM  R5  :x
  #                                19 030 LOADI_2  R6  (2)
  #                                19 032 SEND     R2  :bar   n=0|nk=2
  #
  # vm.c semantics:
  #   1. OP_SEND packs unconditionally, knowing nothing about the callee:
  #        else if (nk > 0) {  /* pack keyword arguments */
  #          mrb_int kidx = a+(n==CALL_MAXARGS?1:n)+1;
  #          mrb_value kdict = hash_new_from_regs(mrb, nk, kidx);
  #          regs[kidx] = kdict;
  #          nk = CALL_MAXARGS;
  #   2. OP_ENTER decides what the Hash means:
  #        mrb_int kd = (MRB_ASPEC_KEY(a) > 0 || MRB_ASPEC_KDICT(a))? 1 : 0;
  #        ...
  #        if (!kd) {
  #          if (!mrb_nil_p(kdict) && mrb_hash_p(kdict) && mrb_hash_size(mrb, kdict) > 0) {
  #            if (argc < 14) {
  #              ci->n++;
  #              argc++;    /* include kdict in normal arguments */
  #            }
  #            ...
  #          }
  #          kdict = mrb_nil_value();
  #          ci->nk = 0;
  #      i.e. with kd == 0 the Hash is appended to the positionals and nk is 0.
  # So the translation is: build the Hash from the K pairs, then an ordinary
  # positional call with N+1 arguments. mrb_funcall's `ci->nk = 0` is exactly the
  # state OP_ENTER would produce anyway.
  #
  # Soundness gate: keyword_hash_positional_callee?(irep, n + 1) on EVERY
  # registry def of the name:
  #   - key/kdict zero (kd == 0) and rest/post/block/noblock zero; optional
  #     positionals are fine (the Hash lands in the next free slot)
  #     (KEYWORD_HASH_POSITIONAL_OPTIONAL_ARG_SUPPORT);
  #   - `total.between?(mand, mand + opt)`: only argc ranges OP_ENTER accepts;
  #   - every def, because mrb_funcall resolves at runtime, so all possible
  #     targets must agree (`:load_h`, five `(h)` defs, compiles;
  #     `:close_message`, whose defs disagree, does not);
  #   - a `<native>` def fails (its argument spec is invisible), which keeps
  #     `:new` sites out;
  #   - `n < 14`, vm.c's `if (argc < 14)` arm.
  # KEYWORD_HASH_LEXICAL_SELF_SUPPORT: when the every-def gate fails, an
  # implicit-self send in a class with no subclasses can only reach that class's
  # def (lexical_self_keyword_target), so the gate runs against that def alone.
  # The marker stays KEYWORD_HASH_POSITIONAL (a dynamic bind).
  # KEYWORD_HASH_DEVIRT_SUPPORT: once packed it is an ordinary positional send of
  # `total = n + 1` arguments, so MONO (monomorphic_target plus arity in [mand,
  # mand + opt], ONLY_OWNERS, no NATIVE_ARG_TARGETS positions; optional padding
  # as in compile_keyword_call) and then POLY_SMALL_N (compile_poly_small_n with
  # the Hash appended) apply. TYPED is not attempted (no trace context here).
  # Marked KEYWORD_HASH_DEVIRT.
  # Returns the C++ or nil.
  def compile_keyword_hash_positional_send(name:, d:, recv:, n:, nk:, argv:, kw_sym_regs:,
                                           kw_val_regs:, kw_names:, self_implicit:, owner_def:)
    # vm.c's `if (argc < 14)` arm.
    return nil unless nk.positive? && n < 14

    defs = @registry[name]
    return nil if defs.nil? || defs.empty?

    total = n + 1
    all_keyword_free = defs.all? do |t|
      # A native def's argument spec is invisible, so it cannot be proven
      # keyword-free.
      next false unless t.irep

      callee_irep = @ireps[t.irep]
      next false unless callee_irep

      keyword_hash_positional_callee?(callee_irep, total)
    end

    # KEYWORD_HASH_LEXICAL_SELF_SUPPORT: retry against the one def this
    # implicit-self site can reach; anything else is a safe miss.
    lexical_self = nil
    unless all_keyword_free
      lexical_self = lexical_self_keyword_target(name, self_implicit: self_implicit, owner_def: owner_def)
      return nil unless lexical_self

      callee_irep = @ireps[lexical_self.irep]
      return nil unless callee_irep && keyword_hash_positional_callee?(callee_irep, total)
    end

    out = String.new
    if lexical_self
      out << "  // KEYWORD_HASH_POSITIONAL :#{name} (n=#{n}|nk=#{nk}) -- POLY name program-wide, but this " \
             "is an implicit-self call inside a #{lexical_self.owner} method and #{lexical_self.owner} has " \
             "NO SUBCLASS anywhere in this closed world, so the only def this send can reach is " \
             "#{lexical_self.owner}##{name}, which declares NO keyword parameters and accepts #{total} " \
             "positional arguments; real src/vm.c OP_ENTER (`if (!kd) { ... ci->n++; argc++; }`) delivers " \
             "the #{nk} keyword pair(s) to exactly it as ONE ordinary trailing positional Hash, as built " \
             "here by OP_SEND's own hash_new_from_regs. Not a keyword call at runtime at all.\n"
    else
      owners = defs.map(&:owner).join(', ')
      out << "  // KEYWORD_HASH_POSITIONAL :#{name} (n=#{n}|nk=#{nk}) -- every real def of this name " \
             "(#{owners}) declares NO keyword parameters and accepts #{total} positional arguments, " \
             "so real src/vm.c OP_ENTER (`if (!kd) { ... ci->n++; argc++; }`) delivers the " \
             "#{nk} keyword pair(s) as ONE ordinary trailing positional Hash, exactly as built here by " \
             "OP_SEND's own hash_new_from_regs. Not a keyword call at runtime at all.\n"
    end
    out << "  {\n"
    out << "    mrb_value bc2cpp_kwh = mrb_hash_new_capa(M, #{nk});\n"
    nk.times do |k|
      out << "    mrb_hash_set(M, bc2cpp_kwh, r#{kw_sym_regs[k]}, r#{kw_val_regs[k]});" \
             "  // :#{kw_names[k]}\n"
    end
    out << "    #{keyword_hash_devirt_line(name: name, d: d, recv: recv, argv: argv, total: total)}"
    out << "  }\n"
    out
  end

  # KEYWORD_HASH_DEVIRT_SUPPORT dispatch tail for the packed-Hash call: MONO, then
  # POLY_SMALL_N, else dynamic dispatch.
  def keyword_hash_devirt_line(name:, d:, recv:, argv:, total:)
    ext_argv = argv + ['bc2cpp_kwh']
    target = monomorphic_target(name)
    if target
      t_irep = @ireps.fetch(target.irep)
      t_mand = mandatory_arity(t_irep)
      t_opt = optional_arity(t_irep)
      if pure_mandatory_or_optional_arity?(t_irep) &&
         total.between?(t_mand, t_mand + t_opt) &&
         native_arg_types(target, t_mand).compact.empty? &&
         (!@only_owners || @only_owners.include?(target.owner) || @other_owners&.include?(target.owner))
        impl = cpp_name(target.owner, target.name) + '_impl'
        call_argv = ext_argv.dup
        if t_opt.positive?
          call_argv += Array.new(t_mand + t_opt - ext_argv.size, 'mrb_nil_value()')
          call_argv << (ext_argv.size - t_mand).to_s
        end
        return "  // KEYWORD_HASH_DEVIRT :#{name} -> #{target.owner}##{target.name} (MONO, trailing-Hash " \
               "positional, direct C++ call, no mrb_funcall)\n" \
               "    r#{d} = #{impl}(M, #{([recv] + call_argv).join(', ')});\n"
      end
    end
    chained = compile_poly_small_n(name, d, recv, ext_argv, total)
    return chained.sub('POLY_SMALL_N', 'KEYWORD_HASH_DEVIRT/POLY_SMALL_N') if chained

    dynamic_dispatch_line(d, recv, name, ext_argv)
  end

  # KEYWORD_NEVER_DEFINED_CONST_RECEIVER_SUPPORT: memoized
  # IntegerConstants.defined_name_universe; without NATIVE_SRCS/FOREIGN_RUBY_SRCS
  # the picture is incomplete and no proof runs.
  def keyword_never_defined_universe
    return @keyword_never_defined_universe if defined?(@keyword_never_defined_universe)

    @keyword_never_defined_universe =
      if ENV['NATIVE_SRCS'] && ENV['FOREIGN_RUBY_SRCS']
        IntegerConstants.defined_name_universe(@ireps, Shellwords.split(ENV['NATIVE_SRCS']),
                                               Shellwords.split(ENV['FOREIGN_RUBY_SRCS']))
      end
  end

  # KEYWORD_NEVER_DEFINED_CONST_RECEIVER_SUPPORT: a keyword SEND whose receiver
  # is a bare constant defined NOWHERE in the closed world is unreachable:
  #   1. the name is absent from defined_name_universe (SETCONST/SETMCNST/
  #      CLASS/MODULE opcodes, native const/class/module definitions, foreign
  #      `NAME =`/class/module);
  #   2. such a GETCONST compiles to the bc2cpp_const_try chain ending in
  #      mrb_const_get from Object, which raises NameError (src/variable.c);
  #   3. the receiver register's first write before the call is that GETCONST,
  #      and no jump or catch target lands strictly between it and the send.
  # So the send never executes. It is still emitted in the faithful OP_SEND form
  # (pairs packed into one trailing Hash, dynamic dispatch) so a broken proof
  # yields a well-formed send.
  # Holes (as for every whole-program gate): runtime const_set, unscanned gems,
  # eval. None define constants here (optcarrot's evals are on the `--opt`
  # path). The shape: optcarrot NES#run's guarded `StackProf.start(...)`.
  def compile_keyword_never_defined_const_send(name:, d:, n:, nk:, irep:, idx:, argv:,
                                               kw_sym_regs:, kw_val_regs:, kw_names:,
                                               self_implicit:)
    return nil if self_implicit
    return nil unless nk.positive?

    universe = keyword_never_defined_universe
    return nil if universe.nil?

    send_insn = irep.instructions[idx]
    return nil unless send_insn && send_insn.op == 'SEND'

    recv_reg = d.to_i
    write = nil
    (idx - 1).downto(0) do |i|
      insn = irep.instructions[i]
      next unless insn
      # The first write to the receiver register must be the constant read itself.
      next unless insn.args =~ /^R#{recv_reg}\b/

      write = insn
      break
    end
    return nil unless write && write.op == 'GETCONST'

    const_name = write.args[/^R\d+\s+(\S+)/, 1]
    return nil unless const_name&.match?(/\A[A-Z][A-Za-z_0-9]*\z/)
    return nil if universe.include?(const_name)

    # No jump target or handler entry may land in (write, send]: that edge would
    # reach the send without the raising GETCONST.
    blocked = jump_targets(irep)
    irep.catch_handlers&.each { |ch| blocked << ch.target }
    return nil if blocked.any? { |t| t > write.addr && t <= send_insn.addr }

    out = String.new
    out << "  // KEYWORD_NEVER_DEFINED_CONST :#{name} (n=#{n}|nk=#{nk}) -- receiver is the value of " \
           "GETCONST `#{const_name}` (addr #{write.addr}), a constant with NO definition anywhere in this " \
           "closed world (no SETCONST/SETMCNST, no CLASS/MODULE, no native mrb_define_const/const_set/" \
           "define_class/define_module, no foreign-source assignment), so that GETCONST's own scope-chain " \
           "raises NameError and this send is dynamically unreachable -- no jump or handler entry lands " \
           "between the two. The keyword packing and real dynamic dispatch emitted below are the " \
           "faithful OP_SEND shape for a call that cannot execute.\n"
    out << "  {\n"
    out << "    mrb_value bc2cpp_kwh = mrb_hash_new_capa(M, #{nk});\n"
    nk.times do |k|
      out << "    mrb_hash_set(M, bc2cpp_kwh, r#{kw_sym_regs[k]}, r#{kw_val_regs[k]});" \
             "  // :#{kw_names[k]}\n"
    end
    out << "    #{dynamic_dispatch_line(d, "r#{d}", name, argv + ['bc2cpp_kwh'])}"
    out << "  }\n"
    out
  end

  # SPLAT_UNROLL_SUPPORT: the argument expressions of the literal Array built at
  # `reg` (traced back, MOVEs followed). vm.c OP_SEND with n == CALL_MAXARGS
  # spreads whatever Array is in R(d+1) at runtime, so a fixed list exists only
  # if that register was built by a literal `ARRAY Rd N`.
  # Elements are read with `mrb_ary_ref(M, r<base>, k)`, not the source
  # registers: OP_ARRAY overwrites r<base> (element 0's register) with the Array,
  # so a bare r<base> would pass the Array as the first argument.
  # Returns C++ expressions or nil.
  def splat_array_literal_regs(irep, idx, reg)
    hops = 0
    (idx - 1).downto(0) do |i|
      insn = irep.instructions[i]
      next unless insn
      # Skip the block proc register (see array_element_source_scan).
      next if insn.op == 'BLOCK'
      next unless insn.args[/^R(\d+)/, 1] == reg

      case insn.op
      when 'MOVE'
        hops += 1
        return nil if hops > 8

        src = insn.args.scan(/R(\d+)/).flatten[1]
        return nil unless src

        reg = src
        next
      when 'ARRAY', 'ARRAY2'
        n = insn.args[/^R\d+\s+(\d+)/, 1]&.to_i
        return nil if n.nil?

        base = reg.to_i
        return (0...n).map { |k| "mrb_ary_ref(M, r#{base}, #{k})" }
      else
        return nil
      end
    end
    nil
  end

  # SPLAT_UNROLL_SUPPORT: the double-splat analogue: a literal `HASH Rd N` (pairs
  # at Rd..Rd+2N-1, see hash_element_source_scan) whose keys are all literal
  # LOADSYMs (needed to match the callee's keyword table). Returns [{name:,
  # val_reg:}] in order, or nil.
  def splat_hash_literal_pairs(irep, idx, reg)
    hops = 0
    (idx - 1).downto(0) do |i|
      insn = irep.instructions[i]
      next unless insn
      next if insn.op == 'BLOCK'
      next unless insn.args[/^R(\d+)/, 1] == reg

      case insn.op
      when 'MOVE'
        hops += 1
        return nil if hops > 8

        src = insn.args.scan(/R(\d+)/).flatten[1]
        return nil unless src

        reg = src
        next
      when 'HASH'
        n = insn.args[/^R\d+\s+(\d+)/, 1]&.to_i
        return nil if n.nil?

        base = reg.to_i
        return (0...n).map do |k|
          key_reg = base + (2 * k)
          val_reg = base + (2 * k) + 1
          kname = literal_symbol_write(irep, i - 1, key_reg.to_s)
          return nil unless kname

          { name: kname, val_reg: "r#{val_reg}" }
        end
      else
        return nil
      end
    end
    nil
  end

  # SPLAT_UNROLL_SUPPORT: a `n=*` and/or `nk=*` call site compiles as an ordinary
  # call when the splatted Array/Hash traces to a fixed-size literal; otherwise
  # `#error`. Plain positional unrolls use dynamic dispatch; keyword-carrying
  # ones use compile_keyword_call's MONO `_impl` call (mrb_funcall cannot carry
  # keywords).
  # DYNAMIC_SPLAT_SUPPORT: a plain `n=*` (no `|nk=`) with a non-literal source
  # (`foo(*list)`): mrbc always builds the complete argument Array in R(dest+1)
  # before the SEND (ARRAY-then-ARYCAT, or LOADNIL-then-ARYCAT when the first
  # argument is a splat), so mrb_funcall_argv with its RARRAY_LEN/RARRAY_PTR is
  # exact. Keyword variants have no such translation and keep `#error`.
  def compile_dynamic_splat_send(name, recv, d, argv_reg)
    <<~CPP
      // SPLAT n=* :#{name} runtime-sized (not a literal), dynamic dispatch via mrb_funcall_argv
      r#{d} = mrb_funcall_argv(M, #{recv}, mrb_intern_cstr(M, "#{name}"), RARRAY_LEN(r#{argv_reg}), RARRAY_PTR(r#{argv_reg}));
    CPP
  end

  def compile_splat_send(args, self_implicit:, irep:, idx:, name:, d:, owner_def: nil)
    return nil unless irep && idx

    n_match = args.match(/n=(\d+|\*)(?:\|nk=(\d+|\*))?/)
    return nil unless n_match

    n_spec, nk_spec = n_match[1], n_match[2]
    return nil unless n_spec == '*' || nk_spec == '*'

    dest_reg = d.to_i
    recv = self_implicit ? 'self' : "r#{d}"

    next_reg = dest_reg + 1
    if n_spec == '*'
      positional = splat_array_literal_regs(irep, idx, next_reg.to_s)
      if positional.nil?
        return nil if nk_spec

        return compile_dynamic_splat_send(name, recv, d, next_reg)
      end

      next_reg += 1 # the single register the splatted array itself occupied.
    else
      n = n_spec.to_i
      positional = (1..n).map { |k| "r#{dest_reg + k}" }
      next_reg += n
    end

    kw_pairs =
      if nk_spec == '*'
        pairs = splat_hash_literal_pairs(irep, idx, next_reg.to_s)
        return nil unless pairs

        pairs
      elsif nk_spec
        nk = nk_spec.to_i
        (0...nk).map do |k|
          key_reg = next_reg + (k * 2)
          val_reg = next_reg + (k * 2) + 1
          kname = literal_symbol_write(irep, idx, key_reg.to_s)
          return nil unless kname

          { name: kname, val_reg: "r#{val_reg}" }
        end
      else
        []
      end

    if kw_pairs.empty?
      note = "  // SPLAT #{n_match[0]} :#{name} unrolled from a literal-sized splat, dynamic dispatch\n"
      "#{note}  #{dynamic_dispatch_line(d, recv, name, positional)}"
    else
      result = compile_keyword_call(name: name, d: d, recv: recv, n: positional.size, argv: positional,
                                     kw_names: kw_pairs.map { |p| p[:name] },
                                     kw_val_exprs: kw_pairs.map { |p| p[:val_reg] },
                                     self_implicit: self_implicit, owner_def: owner_def)
      return nil unless result

      note = "  // SPLAT #{n_match[0]} :#{name} unrolled from a literal-sized splat/double-splat\n"
      "#{note}#{result}"
    end
  end
end
