# frozen_string_literal: true

require_relative 'computed_send_names'
require_relative 'dynamic_names'

# COMPUTED_SEND_EXPANSION: `send(name, args...)` whose name register provably holds one of a
# finite set of plain Symbols (ComputedSendNames) becomes a chain of direct calls, one per name,
# each compiled as the literal-name send of the same site (so it inherits that name's own
# visibility, arity and dispatch proofs). It is taken only when every arm is a direct call with no
# by-name dispatch left in it; otherwise the site keeps its single computed send.
#
# The default arm is not a fallback: a Symbol outside the proven set is a proof violation
# and the one non-Symbol value a table can yield, nil, raises the TypeError `send`
# raises for it.
#
# COMPUTED_SEND_GUARDED: a computed send on self whose name is not provable instead tries the names self's
# class defines that the program spells as Symbols (DynamicNames) and that accept the call's argument count,
# one direct arm each, and keeps the original send as its default arm for any other value.
module ComputedSend
  # Only `__send__`: `send`/`public_send` come from mruby-metaprog, which a build (or a test harness
  # compiling against more gems than it links) may lack, and a direct arm would then answer where the
  # interpreter raises NoMethodError.
  SEND_NAMES = %w[__send__].freeze
  # `send` too when the closed world shows the build's only definition is Kernel's native one (mruby-metaprog).
  METAPROG_SEND_NAMES = %w[send].freeze
  # =0 keeps an unproven computed send as one by-name call.
  GUARDED_SWITCH = 'BC2CPP_COMPUTED_SEND_GUARDED'
  # COMPUTED_SEND_GUARDED: at most this many arms per site (the code size of the expansion, not its speed: the
  # arm is found through a table, see computed_send_guarded_dispatch).
  GUARDED_MAX_ARMS = 512
  # =0 keeps every computed send as one by-name call (the before side of a measurement).
  KILL_SWITCH = 'BC2CPP_COMPUTED_SEND'
  # =0 keeps ARYCAT's copy of a guarded splat send's list on every call.
  SPLAT_SHARED_SWITCH = 'BC2CPP_SPLAT_SHARED'
  # SPLAT_SHARED: how far back the LOADNIL of the list register is looked for.
  SPLAT_SHARED_WINDOW = 16
  # =0 keeps SPLAT_ROW_MEMO off: every `send(*recv[i])` finds its arm through the length and Symbol tables.
  SPLAT_ROW_MEMO_SWITCH = 'BC2CPP_SPLAT_ROW_MEMO'
  # SPLAT_ROW_MEMO: memo entries per site, indexed by `i`; any other index takes the tables.
  SPLAT_ROW_MEMO_SLOTS = 256
  # Core containers whose [] / freeze the table proof reads through.
  TABLE_READERS = [%w[Array []], %w[Hash []]].freeze
  TABLE_FREEZERS = [%w[Array freeze], %w[Hash freeze], %w[Object freeze], %w[Kernel freeze]].freeze
  DYNAMIC_ARM = /\b(?:bc2cpp_send|bc2cpp_funcall\w*|mrb_funcall\w*|bc2cpp_nomethod\w*|bc2cpp_guard_violation\w*|bc2cpp_hint_violation\w*)\(|#error/

  def compile_send(insn, **kwargs)
    computed_send_expansion(insn, kwargs) { super } || super
  end

  private

  def computed_send_expansion(insn, kwargs, &original)
    plan = computed_send_plan(insn, kwargs)
    return computed_send_guarded(insn, kwargs, &original) unless plan

    names, irep, idx, owner_def = plan.values_at(:names, :irep, :idx, :owner_def)
    d = insn.reg.to_i
    self_implicit = BytecodeIR::Ops::SELF_SEND_FAMILY.include?(insn.op)
    rest = (2..insn.argc.to_i).map { |k| "r#{d + k}" }
    arms = names.names.map do |name|
      code = splat_send_with(name, d, self_implicit, irep, idx, owner_def, rest, nil)
      return nil unless code && computed_send_arm_direct?(code)

      [name, code]
    end
    computed_send_code(insn, names, arms, self_implicit)
  end

  # nil, or the proven name set with the site the arms are compiled for.
  def computed_send_plan(insn, kwargs)
    irep, idx = kwargs.values_at(:irep, :idx)
    return nil unless irep && idx && %i[SEND SSEND].include?(insn.op) &&
                      computed_send_name?(insn.sym, insn.op == :SSEND ? kwargs[:owner_def]&.owner : nil)
    return nil unless kwargs[:call_receiver].nil? && kwargs[:call_arguments].nil? && @call_block_expr.nil?
    return nil unless ENV[KILL_SWITCH] != '0' && NomethodReviewed.guard_violation_enabled? && insn.plain_fixed_argc?

    count = insn.argc.to_i
    return nil unless count.between?(1, CodeGen::FUNCALL_ARGC_MAX)

    original = BytecodeIR.for(irep).source_at(idx)
    return nil unless original && original.addr == insn.addr && original.op == insn.op && original.sym == insn.sym
    return nil unless computed_send_kernel?(insn.sym) && computed_send_world_static?

    names = ComputedSendNames.names_at(irep, idx, insn.reg.to_i + 1, computed_send_tables)
    return nil unless names && names.names.none? { |name| computed_send_name_rebound?(name) }
    return nil if names.source.include?('table') && !computed_send_tables_trusted?

    { names: names, irep: irep, idx: idx, owner_def: kwargs[:owner_def] }
  end

  # `owner`: the class of self at the site, whose own ancestors are the only definers that matter.
  def computed_send_name?(name, owner = nil)
    return true if SEND_NAMES.include?(name)
    return false unless METAPROG_SEND_NAMES.include?(name) && @closed_world

    owners = outside_owner_call_owners(name)
    return false unless owners&.include?('Kernel')
    return owners == ['Kernel'] unless owner

    chain = computed_send_chain(owner)
    chain && (owners - ['Kernel']).none? { |definer| chain.include?(definer) }
  end

  # `owner`, its program superclasses and their modules, and Object's own chain; nil for a module (any class
  # may include it) or a class whose chain reaches a core class other than Object.
  def computed_send_chain(owner)
    return nil unless @superclass_of.key?(owner)

    chain = []
    klass = owner
    while klass.is_a?(String) && @superclass_of.key?(klass) && !chain.include?(klass)
      chain << klass
      chain.concat(Array(@included_modules[klass]), Array(@prepended_modules[klass]))
      klass = @superclass_of[klass]
    end
    return nil unless klass == :none || klass == 'Object'

    chain + %w[Object Kernel BasicObject]
  end

  # COMPUTED_SEND_GUARDED: the expansion of an unproven name on self, or nil.
  def computed_send_guarded(insn, kwargs, &)
    irep, idx, owner_def = kwargs.values_at(:irep, :idx, :owner_def)
    return nil unless ENV[KILL_SWITCH] != '0' && ENV[GUARDED_SWITCH] != '0' && irep && idx && insn.op == :SSEND
    return nil unless owner_def && computed_send_name?(insn.sym, owner_def.owner)
    return nil unless kwargs[:call_receiver].nil? && kwargs[:call_arguments].nil? && @call_block_expr.nil?
    return nil unless computed_send_kernel?(insn.sym) && computed_send_world_static?

    original = BytecodeIR.for(irep).source_at(idx)
    return nil unless original && original.addr == insn.addr && original.op == insn.op && original.sym == insn.sym
    return computed_send_guarded_splat(insn, irep, idx, owner_def, &) if insn.positional_splat? && !insn.keyword_arguments?
    return nil unless insn.plain_fixed_argc?

    count = insn.argc.to_i
    return nil unless count.between?(1, CodeGen::FUNCALL_ARGC_MAX)

    d = insn.reg.to_i
    rest = (2..count).map { |k| "r#{d + k}" }
    arms = computed_send_guarded_names(owner_def.owner, count - 1).filter_map do |name|
      code = splat_send_with(name, d, true, irep, idx, owner_def, rest, nil)
      [name, code] if code && computed_send_arm_direct?(code)
    end
    return nil if arms.empty?

    computed_send_guarded_code(insn, arms, yield)
  end

  # `send(*args)`: the packed Array's first element is the name and its length picks the arity; each arm reads
  # its arguments out of the Array before the call.
  def computed_send_guarded_splat(insn, irep, idx, owner_def)
    d = insn.reg.to_i
    ary = "bc2cpp_gsplat_#{d}"
    shared = @splat_shared if @splat_shared&.[](:irep).equal?(irep) && @splat_shared[:idx] == idx && @splat_shared[:reg] == d + 1
    groups = (0..[CodeGen::FUNCALL_ARGC_MAX - 1, 8].min).filter_map do |argc|
      argv = (1..argc).map { |k| "#{ary}_a#{k}" }
      arms = computed_send_guarded_names(owner_def.owner, argc).filter_map do |name|
        code = splat_send_with(name, d, true, irep, idx, owner_def, argv, nil)
        [name, code] if code && computed_send_arm_direct?(code)
      end
      [argc, arms] unless arms.empty?
    end
    total = groups.sum { |_, arms| arms.size }
    return nil if groups.empty? || total > GUARDED_MAX_ARMS

    fallback = yield
    key = shared && splat_row_memo_key(irep, idx, shared)
    return splat_row_memo_send(insn, ary, shared, key, groups, total, fallback) if key

    list = "r#{d + 1}"
    out = +"  // COMPUTED_SEND_GUARDED :#{insn.sym} n=* over #{total} spelled names of self's class by arity; " \
           "any other value keeps the original send\n  {\n    bool #{ary}_done = false;\n"
    if shared
      list = "#{ary}_list"
      out << splat_shared_prologue(ary, shared, groups.map(&:first).max + 1)
      fallback = "if (#{ary}_shared) r#{shared[:reg]} = mrb_ary_splat(M, r#{shared[:src]});\n#{fallback}"
    end
    out << "    if (mrb_array_p(#{list}) && RARRAY_LEN(#{list}) >= 1 && mrb_symbol_p(RARRAY_PTR(#{list})[0])) {\n"
    out << "      mrb_sym #{ary}_id = mrb_symbol(RARRAY_PTR(#{list})[0]);\n      switch (RARRAY_LEN(#{list}) - 1) {\n"
    groups.each do |argc, arms|
      out << "      case #{argc}: {\n"
      (1..argc).each { |k| out << "        mrb_value #{ary}_a#{k} = RARRAY_PTR(#{list})[#{k}];\n" }
      out << computed_send_guarded_dispatch("#{ary}_id", "#{ary}_done", arms, '        ')
      out << "        break;\n      }\n"
    end
    out << "      default: break;\n      }\n    }\n    if (!#{ary}_done) {\n"
    out << fallback.lines.map { |line| "    #{line}" }.join
    out << "    }\n  }\n"
    shared[:emitted] = out if shared
    out
  end

  # SPLAT_SHARED: an Array of at most +max+ immediates is read in place, so ARYCAT's copy is made only for the fallback
  # send, which may keep it. Immediates need no root once read; any other list is copied first, as before.
  def splat_shared_prologue(ary, shared, max, declare: true)
    src = "r#{shared[:src]}"
    out = +"    // SPLAT_SHARED: the list is read from #{src} in place; ARYCAT's copy is made only when no arm takes it\n"
    out << "    #{'bool ' if declare}#{ary}_shared = mrb_array_p(#{src}) && RARRAY_LEN(#{src}) <= #{max};\n"
    out << "    for (mrb_int k = 0; #{ary}_shared && k < RARRAY_LEN(#{src}); ++k) " \
           "#{ary}_shared = mrb_immediate_p(RARRAY_PTR(#{src})[k]);\n"
    # The list register was nil (LOADNIL), so ARYCAT's effect is the copy alone.
    out << "    if (!#{ary}_shared) r#{shared[:reg]} = mrb_ary_splat(M, #{src});\n"
    out << "    mrb_value #{ary}_list = #{ary}_shared ? #{src} : r#{shared[:reg]};\n"
    out
  end

  # SPLAT_ROW_MEMO: `send(*recv[i])`, a GETIDX straight before the shared pair's ARYCAT, is keyed by the index
  # register, which nothing writes between the two. nil for any other list.
  def splat_row_memo_key(irep, idx, shared)
    return nil if ENV[SPLAT_ROW_MEMO_SWITCH] == '0' || idx < 2

    getidx = BytecodeIR.for(irep).source_at(idx - 2)
    getidx&.op == :GETIDX && getidx.reg.to_i == shared[:src] ? "r#{shared[:src] + 1}" : nil
  end

  # SPLAT_ROW_MEMO: the guarded splat with a per-site memo from the index to the arm. An entry is a copy of a list
  # that was all immediates when its arm was found. A list equal to it bit for bit has the same length and leading
  # Symbol, so it takes the same arm, and its immediates can be read from the copy. Any other list, or an index
  # outside the memo, takes the length and Symbol tables as before and refills the entry. The key only picks the
  # entry, so nothing about the table (frozen, reassigned, rows written) needs proving: a changed row misses.
  def splat_row_memo_send(insn, ary, shared, key, groups, total, fallback)
    src = "r#{shared[:src]}"
    width = groups.map(&:first).max + 1
    memo = "#{ary}_memo_#{(@computed_send_site_seq || 0) + 1}"
    numbered = groups.flat_map { |argc, arms| arms.map { |name, code| [argc, name, code] } }
                     .each_with_index.map { |(argc, name, code), i| [argc, name, code, i + 1] }
    out = +"  // COMPUTED_SEND_GUARDED :#{insn.sym} n=* over #{total} spelled names of self's class by arity; " \
           "any other value keeps the original send\n  {\n    bool #{ary}_done = false;\n"
    out << "    // SPLAT_ROW_MEMO: the arm of #{src} is remembered per index #{key} while the list stays bit-identical\n"
    out << "    static mrb_state* #{memo}_M = nullptr;\n"
    out << "    static struct { mrb_int n; uint16_t arm; mrb_value v[#{width}]; } #{memo}[#{SPLAT_ROW_MEMO_SLOTS}];\n"
    out << "    if (mrb_unlikely(#{memo}_M != M)) { memset(#{memo}, 0, sizeof(#{memo})); #{memo}_M = M; }\n"
    out << "    uint16_t #{ary}_arm = 0;\n    const mrb_value* #{ary}_argv = nullptr;\n    bool #{ary}_shared = false;\n"
    out << "    const bool #{ary}_keyed = mrb_fixnum_p(#{key}) && (mrb_uint)mrb_fixnum(#{key}) < #{SPLAT_ROW_MEMO_SLOTS};\n"
    out << "    if (mrb_likely(#{ary}_keyed && mrb_array_p(#{src}))) {\n"
    out << "      auto& e = #{memo}[mrb_fixnum(#{key})];\n"
    # Bit equality: equal words are one immediate (a word-boxed Float's sign of zero included). The compare is
    # unrolled from the entry's length down, which is at most the width.
    out << "      auto same = [](mrb_value a, mrb_value b) {\n#if defined(MRB_WORD_BOXING)\n        return a.w == b.w;\n" \
           "#else\n        return memcmp(&a, &b, sizeof(mrb_value)) == 0;\n#endif\n      };\n"
    out << "      const mrb_value* p = RARRAY_PTR(#{src});\n      bool hit = false;\n"
    out << "      switch (RARRAY_LEN(#{src}) == e.n ? e.n : 0) {\n"
    width.downto(2) do |k|
      out << "      case #{k}: if (!same(p[#{k - 1}], e.v[#{k - 1}])) break; [[fallthrough]];\n"
    end
    out << "      case 1: hit = same(p[0], e.v[0]); break;\n      default: break;\n      }\n"
    out << "      if (mrb_likely(hit)) { #{ary}_arm = e.arm; #{ary}_argv = e.v + 1; }\n    }\n"
    out << "    if (#{ary}_arm == 0) {\n"
    out << splat_shared_prologue(ary, shared, width, declare: false)
    list = "#{ary}_list"
    out << "    if (mrb_array_p(#{list}) && RARRAY_LEN(#{list}) >= 1 && mrb_symbol_p(RARRAY_PTR(#{list})[0])) {\n"
    out << "      mrb_sym #{ary}_id = mrb_symbol(RARRAY_PTR(#{list})[0]);\n      switch (RARRAY_LEN(#{list}) - 1) {\n"
    groups.each do |argc, _|
      arms = numbered.select { |a, *| a == argc }.map { |_, name, _, number| [name, number] }
      out << "      case #{argc}: {\n"
      out << computed_send_guarded_lookup("#{ary}_id", "#{ary}_arm", arms, '        ')
      out << "        break;\n      }\n"
    end
    out << "      default: break;\n      }\n      #{ary}_argv = RARRAY_PTR(#{list}) + 1;\n"
    # Only an all-immediates list is copied: the copy needs no GC root.
    out << "      if (#{ary}_arm != 0 && #{ary}_shared && #{ary}_keyed) {\n"
    out << "        auto& e = #{memo}[mrb_fixnum(#{key})];\n        e.n = RARRAY_LEN(#{list});\n"
    out << "        for (mrb_int k = 0; k < e.n; ++k) e.v[k] = RARRAY_PTR(#{list})[k];\n        e.arm = #{ary}_arm;\n"
    out << "      }\n    }\n    }\n    switch (#{ary}_arm) {\n"
    numbered.each do |argc, name, code, number|
      out << "    case #{number}: {  // :#{name}/#{argc}\n"
      # Read before the call: a re-entrant call may refill the entry.
      (1..argc).each { |k| out << "      mrb_value #{ary}_a#{k} = #{ary}_argv[#{k - 1}];\n" }
      out << code.lines.map { |line| "      #{line}" }.join
      out << "      #{ary}_done = true;\n      break;\n    }\n"
    end
    out << "    default: break;\n    }\n    if (!#{ary}_done) {\n"
    fallback = "if (#{ary}_shared) r#{shared[:reg]} = mrb_ary_splat(M, #{src});\n#{fallback}"
    out << fallback.lines.map { |line| "    #{line}" }.join
    out << "    }\n  }\n"
    shared[:emitted] = out
    out
  end

  # SPLAT_SHARED: true when the ARYCAT at +idx+ only builds the list of the guarded splat send after it, so the
  # method loop may hand its text to that send (codegen_method.rb). The list register must still hold the nil of a
  # LOADNIL: the instructions after it compute the splat operand above the list register, and no jump, glue or
  # prefix touches them.
  def splat_shared_pair?(irep, idx, blocked)
    return false if @resumable || ENV[KILL_SWITCH] == '0' || ENV[SPLAT_SHARED_SWITCH] == '0'
    return false unless (prog = BytecodeIR.for(irep)) && idx + 1 < prog.size

    arycat = prog.source_at(idx)
    send = prog.source_at(idx + 1)
    return false unless arycat.op == :ARYCAT && send.op == :SSEND && send.positional_splat? && !send.keyword_arguments?

    list = arycat.reg.to_i
    return false unless send.reg.to_i + 1 == list && arycat.paren_reg.to_i > list

    (idx - 1).downto([idx - SPLAT_SHARED_WINDOW, 0].max) do |i|
      insn = prog.source_at(i)
      return false if blocked.call(insn.addr)
      return (i + 1..idx + 1).none? { |j| blocked.call(prog.source_at(j).addr) } if insn.op == :LOADNIL && insn.reg.to_i == list
      return false unless insn.reg && insn.reg.to_i > list
    end
    false
  end

  # The send's text under +pending+; the deferred ARYCAT text goes first unless the guarded splat took it.
  def splat_shared_send(pending)
    saved = @splat_shared
    @splat_shared = pending
    code = yield
    # Only the expansion itself may stand in for the pair: a wrapper around it could read the list register.
    pending[:emitted] == code ? code : pending[:arycat] + code
  ensure
    @splat_shared = saved
  end

  # The arm for Symbol `id` among `arms`: a per-site table from Symbol id to arm number, built on the first call
  # for each mrb_state (Symbols are never collected, so the ids stay valid), then a switch on the number.
  def computed_send_guarded_dispatch(id, done, arms, pad)
    @computed_send_site_seq = (@computed_send_site_seq || 0) + 1
    tab = "bc2cpp_gtab_#{@computed_send_site_seq}"
    syms = arms.map { |name, _| "mrb_intern_lit(M, \"#{name}\")" }
    out = +"#{pad}static mrb_state* #{tab}_M = nullptr;\n#{pad}static uint16_t* #{tab} = nullptr;\n" \
           "#{pad}static mrb_sym #{tab}_max = 0;\n"
    out << "#{pad}if (#{tab}_M != M) {\n#{pad}  const mrb_sym syms[] = { #{syms.join(', ')} };\n"
    out << "#{pad}  mrb_sym max = 0;\n#{pad}  for (mrb_sym s : syms) if (s > max) max = s;\n"
    out << "#{pad}  free(#{tab});\n#{pad}  #{tab} = static_cast<uint16_t*>(calloc(max + 1, sizeof(uint16_t)));\n"
    out << "#{pad}  for (size_t k = 0; k < sizeof(syms) / sizeof(syms[0]); ++k) #{tab}[syms[k]] = (uint16_t)(k + 1);\n"
    out << "#{pad}  #{tab}_max = max;\n#{pad}  #{tab}_M = M;\n#{pad}}\n"
    out << "#{pad}switch (#{id} <= #{tab}_max ? #{tab}[#{id}] : 0) {\n"
    arms.each_with_index do |(name, code), i|
      out << "#{pad}case #{i + 1}: {  // :#{name}\n"
      out << code.lines.map { |line| "#{pad}  #{line}" }.join
      out << "#{pad}  #{done} = true;\n#{pad}  break;\n#{pad}}\n"
    end
    out << "#{pad}default: break;\n#{pad}}\n"
    out
  end

  # SPLAT_ROW_MEMO: computed_send_guarded_dispatch's table alone, storing the arm's number (0: none) into +var+.
  def computed_send_guarded_lookup(id, var, arms, pad)
    @computed_send_site_seq = (@computed_send_site_seq || 0) + 1
    tab = "bc2cpp_gtab_#{@computed_send_site_seq}"
    syms = arms.map { |name, _| "mrb_intern_lit(M, \"#{name}\")" }
    out = +"#{pad}static mrb_state* #{tab}_M = nullptr;\n#{pad}static uint16_t* #{tab} = nullptr;\n" \
           "#{pad}static mrb_sym #{tab}_max = 0;\n"
    out << "#{pad}if (#{tab}_M != M) {\n#{pad}  const mrb_sym syms[] = { #{syms.join(', ')} };\n"
    out << "#{pad}  const uint16_t nums[] = { #{arms.map(&:last).join(', ')} };\n"
    out << "#{pad}  mrb_sym max = 0;\n#{pad}  for (mrb_sym s : syms) if (s > max) max = s;\n"
    out << "#{pad}  free(#{tab});\n#{pad}  #{tab} = static_cast<uint16_t*>(calloc(max + 1, sizeof(uint16_t)));\n"
    out << "#{pad}  for (size_t k = 0; k < sizeof(syms) / sizeof(syms[0]); ++k) #{tab}[syms[k]] = nums[k];\n"
    out << "#{pad}  #{tab}_max = max;\n#{pad}  #{tab}_M = M;\n#{pad}}\n"
    out << "#{pad}#{var} = #{id} <= #{tab}_max ? #{tab}[#{id}] : 0;\n"
    out
  end

  # Spelled names `owner` itself defines in bytecode whose arity accepts `argc` arguments, sorted.
  def computed_send_guarded_names(owner, argc)
    @computed_send_universe ||= DynamicNames.universe(@ireps)
    names = @computed_send_universe.select do |name|
      next false if computed_send_name_rebound?(name) || !name.match?(/\A[a-z_]\w*[?!]?\z/)

      (@registry[name] || []).any? do |definition|
        definition.owner == owner && definition.irep && computed_send_accepts?(@ireps.fetch(definition.irep), argc)
      end
    end
    names.sort.first(GUARDED_MAX_ARMS + 1).then { |list| list.size > GUARDED_MAX_ARMS ? [] : list }
  end

  def computed_send_accepts?(t_irep, argc)
    mand = mandatory_arity(t_irep)
    return argc >= mand if rest_only_callee?(t_irep)

    argc.between?(mand, mand + positional_optional_count(t_irep))
  end

  def computed_send_guarded_code(insn, arms, fallback)
    d = insn.reg.to_i
    var = "bc2cpp_gsend_#{d}"
    out = +"  // COMPUTED_SEND_GUARDED :#{insn.sym} over #{arms.size} spelled names of self's class; " \
           "any other value keeps the original send\n  {\n    mrb_value #{var} = r#{d + 1};\n    bool #{var}_done = false;\n"
    out << "    if (mrb_symbol_p(#{var})) {\n      mrb_sym #{var}_id = mrb_symbol(#{var});\n"
    out << computed_send_guarded_dispatch("#{var}_id", "#{var}_done", arms, '      ')
    out << "    }\n    if (!#{var}_done) {\n"
    out << fallback.lines.map { |line| "    #{line}" }.join
    out << "    }\n  }\n"
    out
  end

  def computed_send_tables
    self.class.computed_send_tables || {}
  end

  # The violation arm and the arms assume nothing answers or replaces a name behind their back: a
  # closed world with no method_missing, no singleton class on an instance and no unresolved installer.
  def computed_send_world_static?
    @closed_world && @closed_world.global_refusal.nil? && @closed_world.method_missing_classes.empty? &&
      @closed_world.exact_instances_singleton_free? && !symbol_installed_names.nil?
  end

  def computed_send_name_rebound?(name)
    devirt_blocked_name?(name) || symbol_installed_names.include?(name)
  end

  # The send being replaced is mruby's own core `__send__`: a Ruby or native definition of it on another
  # class could be the receiver's.
  def computed_send_kernel?(name)
    return false if devirt_blocked_name?(name)

    @registry.fetch(name, []).all? { |definition| definition.owner == '<native>' }
  end

  # The table proof reads the constant through Array#[] / Hash#[] and trusts `freeze`: nothing may
  # replace them.
  def computed_send_tables_trusted?
    (TABLE_READERS + TABLE_FREEZERS).all? do |owner, name|
      defs = @registry.fetch(name, [])
      defs.all? { |definition| definition.owner == '<native>' || !%w[Array Hash Object Kernel BasicObject].include?(definition.owner) } &&
        @closed_world.core_native_arm_safe?(name, owner)
    end
  end

  def computed_send_arm_direct?(code)
    live = code.lines.reject { |line| line.lstrip.start_with?('//') }.join
    live.include?('_impl(M') && !live.match?(DYNAMIC_ARM)
  end

  def computed_send_code(insn, names, arms, self_implicit)
    d = insn.reg.to_i
    recv = self_implicit ? 'self' : "r#{d}"
    all = (1..insn.argc.to_i).map { |k| "r#{d + k}" }
    var = "bc2cpp_csend_#{d}"
    violation = guard_violation_line(d, recv, insn.sym, all, 'COMPUTED_SEND')
    out = +"  // COMPUTED_SEND :#{insn.sym} (#{names.source}) over #{names.names.join('/')}: direct arm per name, " \
           "a Symbol outside the set is a proof violation (ADR 0303)\n  {\n    mrb_value #{var} = #{all.first};\n"
    out << "    if (mrb_symbol_p(#{var})) {\n      mrb_sym #{var}_id = mrb_symbol(#{var});\n"
    arms.each_with_index do |(name, code), i|
      out << "      #{i.zero? ? '' : 'else '}if (#{var}_id == mrb_intern_lit(M, \"#{name}\")) {\n"
      out << code.lines.map { |line| "        #{line}" }.join
      out << "      }\n"
    end
    out << "      else {\n        #{violation.chomp}\n      }\n    } else {\n"
    # TypeError for nil, exactly as Kernel#send raises it; a value the table cannot hold is a violation.
    out << "      (void)mrb_obj_to_sym(M, #{var});\n" if names.nilable
    out << "      #{violation.chomp}\n    }\n  }\n"
    out
  end
end

CodeGen.prepend(ComputedSend)
CodeGen.singleton_class.attr_accessor :computed_send_tables
