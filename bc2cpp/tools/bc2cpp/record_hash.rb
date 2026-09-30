# frozen_string_literal: true

require 'set'
require_relative 'bytecode_ir'
require_relative 'ivar_layout'

# RECORD_HASH_PROOF (docs/adr/0285): per-key value classes of a record-like
# Hash held in an instance variable.
#
# A record slot is an ivar NAME (`@ui`), analysed across the whole closed
# world, whose every store is a Hash literal with Symbol-literal keys (or nil)
# and whose every use of the Hash is `h[key]`, `h[:lit] = v` or `h.delete(:lit)`
# (ALIAS_SCAN follows MOVE copies and captured locals, so `f(@ui)` escapes).
# The object behind `@ui[:key]` is then created by one of the literals and
# mutated only by the stores the scan lists, so the class of a read is the join
# of the values stored under that key (plus nil when a literal can omit it or a
# delete can remove it). Nothing is guarded at run time.
#
# Refusals drop the whole slot: an attr_writer or computed installer, a
# reflective ivar access that can name it, an outside source spelling it, a
# store that is not a literal, a non-literal-key write. Hostile Marshal.load
# data is outside the model, as for every ivar fact in bc2cpp.
module RecordHash
  class << self
    # name => { key => {strict: Set, trusted: Set} }, and the attr_reader names
    # whose call yields the ivar; both set by the driver.
    attr_accessor :table, :readers, :pool

    # BC2CPP_RECORD_HASH_TIER=trusted lets writers classified by the Array
    # block-recognizer scan (tripwire-backed, ADR 0198) count too; the default
    # admits only proofs.
    def consumer_tier
      ENV['BC2CPP_RECORD_HASH_TIER'] == 'trusted' ? :trusted : :strict
    end
  end

  Slot = Struct.new(:name, :keys, :literals, :reads, :stores, keyword_init: true)
  Result = Struct.new(:slots, :refused, :global_refusal, :readers, :pool, keyword_init: true) do
    def table
      slots.transform_values(&:keys)
    end
  end

  NIL_CLASS = 'NilClass'
  UNKNOWN_SET = Set[:unknown].freeze
  REFLECTION_SENDS = %w[instance_variable_get instance_variable_set remove_instance_variable
                        instance_variable_defined? each_object].freeze
  CALL_OPS = %w[SEND SENDB SSEND SSENDB SEND0 SSEND0 SUPER].freeze
  # Ops whose leading register is only written (no implicit reads).
  WRITE_LEAD_ONLY = Set[
    'LOADL', 'LOADSYM', 'LOADNIL', 'LOADTRUE', 'LOADFALSE', 'LOADSELF', 'GETGV', 'GETSV', 'GETIV',
    'GETCV', 'GETCONST', 'GETMCNST', 'GETUPVAR', 'STRING', 'SYMBOL', 'LAMBDA', 'BLOCK', 'METHOD',
    'OCLASS', 'TCLASS', 'EXCEPT', 'AREF', 'KEY_P', 'KARG', 'MOVE'
  ].freeze
  # Ops that read their leading register and leave it unchanged.
  READ_LEAD_KEEP = Set['JMPIF', 'JMPNOT', 'JMPNIL', 'RETURN', 'RETURN_BLK', 'BREAK', 'RAISEIF', 'MATCHERR',
                       'SETUPVAR', 'ASET'].freeze
  # Producers of a value that is provably not a Symbol; a key from one of them
  # can never alias a Symbol key.
  NON_SYMBOL_OPS = Set['LOADNIL', 'LOADTRUE', 'LOADFALSE', 'STRING', 'ARRAY', 'HASH', 'LOADL'].freeze
  STATE_LIMIT = 4000
  POOL_DEPTH = 4
  INF = Float::INFINITY

  module_function

  def analyze(ireps, registry, native_paths:, foreign_paths:, closed_world:, trusted: nil, outside_tokens: nil)
    result = Result.new(slots: {}, refused: {}, global_refusal: nil, readers: Set.new)
    unless closed_world && native_paths && foreign_paths && outside_tokens
      result.global_refusal = 'needs a closed world with native and foreign sources'
      return result
    end
    if closed_world.global_refusal
      result.global_refusal = "closed world refusal #{closed_world.global_refusal}"
      return result
    end

    poison = Poison.new(ireps, registry, closed_world, native_paths, foreign_paths)
    if poison.global
      result.global_refusal = poison.global
      return result
    end
    # The pool is process-wide state for the duration of the analysis and the consumer.
    self.pool = result.pool = KeyPool.new(ireps, registry, outside_tokens)

    candidates = Hash.new { |h, k| h[k] = { sets: [], gets: [], calls: [] } }
    calls = {}
    ireps.each_value do |irep|
      irep.each_with_op('SETIV', 'GETIV') do |insn, i|
        name = insn.ivar or next

        (insn.op == 'SETIV' ? candidates[name][:sets] : candidates[name][:gets]) << [irep, i]
      end
      irep.each_with_op(*CALL_OPS) do |insn, i|
        (calls[insn.sym] ||= []) << [irep, i] if poison.readers.include?(insn.sym)
      end
    end
    calls.each { |name, sites| candidates[name][:calls].concat(sites) if candidates.key?(name) }
    # A call of a reader name is a slot read only if every definition of the name is an attr reader.
    poison.readers.each do |name|
      result.readers << name if registry[name].all? { |d| d.kind == :ivar_accessor }
    end
    candidates.each do |name, sites|
      next unless sites[:sets].any? { |irep, i| hash_literal_store?(irep, i) }

      why = poison.reason(name)
      if why
        result.refused[name] = why
        next
      end
      slot = Scanner.new(name, sites, trusted, closed_world, registry).run
      slot.is_a?(Slot) ? result.slots[name] = slot : result.refused[name] = slot
    end
    result
  end

  # True when the SETIV at +idx+ has a HASH literal among its reaching sources
  # (cheap candidate filter; Scanner re-proves everything).
  def hash_literal_store?(irep, idx)
    defs = BytecodeIR.reaching_definitions(irep, idx, irep.instructions[idx].regs.first, through_handlers: true)
    defs&.any? { |d| !d.entry? && irep.instructions[d.index].op == 'HASH' }
  end

  # The Symbol names register +reg+ can hold at +idx+ (strings), or nil when some reaching value is not
  # provably a literal Symbol. +for_write+ lets provably non-Symbol keys through: storing under one never
  # touches a Symbol key.
  def literal_keys(irep, idx, reg, for_write: false, depth: 0)
    defs = BytecodeIR.reaching_definitions(irep, idx, reg.to_s, through_handlers: true)
    return nil if defs.nil? || defs.empty?

    keys = []
    defs.each do |d|
      found =
        if d.entry?
          pool&.positional(irep, d.reg.to_i, depth)
        else
          insn = irep.instructions[d.index]
          if insn.op == 'LOADSYM' then [insn.sym]
          elsif insn.op == 'KARG' then pool&.keyword(irep, insn, depth)
          elsif for_write && (NON_SYMBOL_OPS.include?(insn.op) || insn.op.start_with?('LOADI')) then []
          end
        end
      return nil if found.nil?

      keys.concat(found)
    end
    keys.uniq
  end

  # The [slot name, key] pairs the GETIDX at +index+ reads, when its receiver is provably a record slot
  # (every reaching value is `@slot` or a call of its attr reader) and the key a literal Symbol; else nil.
  def read_slots(irep, index)
    table = self.table or return nil
    insn = irep.instructions[index]
    return nil unless insn&.op == 'GETIDX'

    recv, key = insn.regs
    defs = BytecodeIR.reaching_definitions(irep, index, recv, through_handlers: true)
    return nil if defs.nil? || defs.empty?

    names = defs.map do |d|
      writer = d.entry? ? nil : irep.instructions[d.index]
      if writer&.op == 'GETIV' then writer.ivar
      elsif writer && CALL_OPS.include?(writer.op) && (readers || Set.new).include?(writer.sym) then writer.sym
      end
    end
    return nil if names.any? { |n| n.nil? || !table.key?(n) }

    keys = literal_keys(irep, index, key) or return nil
    names.uniq.product(keys)
  end

  # RECORD_HASH_PROOF read side for the Array block recognizers: is the GETIDX at +index+ a literal-key
  # read of a record key that always holds a non-nil Array?
  def array_read?(irep, index, tier: :strict)
    slots = read_slots(irep, index) or return false
    slots.all? { |name, key| (table[name][key] || {})[tier] == Set['Array'] }
  end

  # Call-site pooling for the Symbol a method parameter can hold: every call
  # site of a single-definition method is enumerated (ENTRY_ARG_CALLSITE_PROOF's
  # admission, ADR 0261 rules 1-8), so `def f(scroll_key: nil)` resolves to the
  # Symbols its callers pass.
  class KeyPool
    ENTER_POSITIONAL_ONLY = ->(fields) { fields[1..].all?(&:zero?) }

    def initialize(ireps, registry, outside_tokens)
      @registry = registry
      @outside_tokens = outside_tokens
      @sites = Hash.new { |h, k| h[k] = [] }
      @poisoned = Set.new
      @body_def = {}
      registry.each_value { |defs| defs.each { |d| @body_def[d.irep] = d if d.irep } }
      ireps.each_value do |irep|
        irep.instructions.each_with_index do |insn, i|
          name = insn.sym or next

          case insn.op
          when 'SEND', 'SENDB', 'SSEND', 'SSENDB', 'SEND0', 'SSEND0' then @sites[name] << [irep, i]
          when 'DEF', 'SDEF', 'TDEF' then nil
          else @poisoned << name
          end
        end
      end
    end

    # Symbols positional parameter +reg+ of the method whose body is +irep+ can hold, or nil.
    def positional(irep, reg, depth)
      return nil if depth >= POOL_DEPTH

      d = admitted(irep) or return nil
      enter = irep.enter or return nil
      fields = enter.enter_fields
      return nil unless ENTER_POSITIONAL_ONLY.call(fields) && reg.between?(1, fields[0])

      sites = @sites[d.name]
      return nil if sites.empty?

      pooled = []
      sites.each do |site_irep, i|
        site = site_irep.instructions[i]
        n, nk = site_counts(site)
        return nil unless n == fields[0] && nk == 0

        keys = RecordHash.literal_keys(site_irep, i, site.reg.to_i + reg, depth: depth + 1) or return nil
        pooled.concat(keys)
      end
      pooled.uniq
    end

    # Symbols keyword +insn+ (a KARG of the method body +irep+) receives across call sites, or nil.
    # A call that omits the keyword takes the default, which the callee's own KEY_P arm defines.
    def keyword(irep, karg, depth)
      return nil if depth >= POOL_DEPTH

      d = admitted(irep) or return nil
      enter = irep.enter or return nil
      mand, opt, rest, post, kw, kdict, block, noblock = enter.enter_fields
      return nil unless kw.positive? && [opt, rest, post, kdict, block, noblock].all?(&:zero?)

      sites = @sites[d.name]
      return nil if sites.empty?

      pooled = []
      sites.each do |site_irep, i|
        site = site_irep.instructions[i]
        n, nk = site_counts(site)
        # Positional count fixed to the mandatory count so no trailing Hash can be read as keywords.
        return nil unless n == mand && nk

        base = site.reg.to_i + n + 1
        nk.times do |j|
          key = RecordHash.literal_keys(site_irep, i, base + 2 * j) or return nil
          return nil unless key.size == 1

          next unless key.first == karg.sym

          value = RecordHash.literal_keys(site_irep, i, base + 2 * j + 1, depth: depth + 1) or return nil
          pooled.concat(value)
        end
      end
      pooled.uniq
    end

    private

    # [positional count, keyword pair count] of a call site; nil where a splat hides them.
    def site_counts(site)
      return [0, 0] if %w[SEND0 SSEND0].include?(site.op)

      site.argc_operand&.first(2) || [nil, nil]
    end

    # The MethodDef whose body is +irep+, when its every call can be enumerated.
    def admitted(irep)
      d = @body_def[irep.label] or return nil
      name = d.name
      return nil unless (@registry[name] || []).size == 1 && d.kind.nil?
      return nil if @poisoned.include?(name) || @outside_tokens.include?(name)
      return nil unless name.match?(/\A[A-Za-z_]/) && name != 'initialize'

      d
    end
  end

  # Whole-world reasons a name cannot be a record slot.
  class Poison
    attr_reader :global, :readers

    def initialize(ireps, registry, closed_world, native_paths, foreign_paths)
      @by_name = {}
      @global = nil
      @closed_world = closed_world
      @native = native_paths.map { |p| File.file?(p) ? File.read(p, mode: 'rb') : '' }
      @foreign = foreign_paths.map { |p| File.file?(p) ? File.read(p) : '' }
      @readers = Set.new
      registry.each_value do |defs|
        defs.each do |d|
          next unless d.kind == :ivar_accessor

          # A reader hands the Hash out, so its call sites become alias sources
          # (Scanner); a writer stores a value no SETIV shows.
          d.name.end_with?('=') ? poison(d.name.chomp('='), 'attr_writer') : @readers << d.name
        end
      end
      scan_reflection(ireps)
      scan_foreign_reflection
    end

    def reason(name)
      return @by_name[name] if @by_name.key?(name)
      return 'accessor installed outside the registry' if [name, "#{name}="].any? { |n| @closed_world.invisibly_definable?(n) }

      pattern = /["']@#{Regexp.escape(name)}["']|MRB_IVSYM\(\s*#{Regexp.escape(name)}\s*\)/
      return 'spelled by a native source' if @native.any? { |t| t.match?(pattern) }
      return 'spelled by a foreign Ruby source' if @foreign.any? { |t| t.match?(/@#{Regexp.escape(name)}\b/) }

      nil
    end

    private

    def poison(name, why)
      @by_name[name] ||= why
    end

    def scan_reflection(ireps)
      ireps.each_value do |irep|
        irep.pool.each do |entry|
          @global ||= "#{entry} named as a string" if entry.is_a?(String) && REFLECTION_SENDS.include?(entry)
        end
        installer_args = installer_symbol_positions(irep)
        irep.instructions.each_with_index do |insn, i|
          if insn.op == 'LOADSYM'
            @global ||= "#{insn.sym} escapes as a Symbol" if REFLECTION_SENDS.include?(insn.sym)
            # `send(:ui)` / `&:ui` / `method(:ui)` would call a reader without a visible call site.
            poison(insn.sym, 'reader named as a Symbol') if @readers.include?(insn.sym) && !installer_args.include?(i)
          elsif CALL_OPS.include?(insn.op) && REFLECTION_SENDS.include?(insn.sym)
            literal = insn.op.end_with?('0') ? nil : literal_ivar_arg(irep, i, insn)
            literal ? poison(literal, "reflection #{insn.sym}") : (@global ||= "computed #{insn.sym}")
          end
        end
      end
    end

    # LOADSYM indices that are the literal Symbol arguments of an attr_* installer.
    def installer_symbol_positions(irep)
      positions = Set.new
      irep.instructions.each_with_index do |insn, i|
        next unless %w[SSEND SSEND0].include?(insn.op) && insn.sym.to_s.start_with?('attr')

        n = insn.argc or next
        run = irep.instructions[(i - n).clamp(0, i)...i]
        run.each_index { |k| positions << (i - n + k) if run[k].op == 'LOADSYM' }
      end
      positions
    end

    # The ivar named by the first argument of a reflective send, when literal.
    def literal_ivar_arg(irep, idx, insn)
      arg = (insn.reg.to_i + 1).to_s
      defs = BytecodeIR.reaching_definitions(irep, idx, arg, through_handlers: true)
      return nil if defs.nil? || defs.empty?

      names = defs.map do |d|
        next nil if d.entry?

        w = irep.instructions[d.index]
        case w.op
        when 'LOADSYM' then w.sym
        when 'STRING'
          entry = irep.pool[w.pool_index]
          entry.is_a?(String) ? entry : nil
        end
      end
      return nil if names.any?(&:nil?) || names.uniq.size != 1

      names.first.delete_prefix('@')
    end

    # Foreign Ruby that reflects on ivars: literal names poison that ivar, anything else is global.
    def scan_foreign_reflection
      names = REFLECTION_SENDS.map { |n| Regexp.escape(n) }.join('|')
      @foreign.each do |text|
        text.scan(/\b(?:#{names})\b(?:\s*\(\s*:?["']?@(\w+))?/) do |(name)|
          name ? poison(name, 'foreign reflection') : (@global ||= 'computed reflection in a foreign Ruby source')
        end
      end
    end
  end

  # One candidate name: prove the store/use discipline and collect key classes.
  class Scanner
    def initialize(name, sites, trusted, closed_world, registry)
      @registry = registry
      @name = name
      @sites = sites
      @trusted = trusted
      @closed_world = closed_world
      @literals = []      # [irep, hash_index]
      @literal_pairs = [] # [irep, hash_index, keys, value_reg]
      @reads = 0
      @stores = []        # [keys, irep, index, reg]
      @deleted = []
      @captured = Set.new
      @failure = nil
    end

    def run
      @sites[:sets].each { |irep, i| return @failure unless store_ok?(irep, i) }
      return "#{@name}: no Hash literal store" if @literals.empty?

      %i[gets calls].each do |kind|
        @sites[kind].each { |irep, i| return @failure unless alias_scan(irep, i, irep.instructions[i].reg.to_i) }
      end
      return @failure unless @literals.all? { |irep, d| literal_scan(irep, d) }

      Slot.new(name: @name, keys: join_keys, literals: @literals.size, reads: @reads, stores: @stores.size)
    end

    private

    def fail!(why)
      @failure ||= "#{@name}: #{why}#{@site}"
      false
    end

    def escape(why)
      @failure ||= "#{@name}: #{why}#{@site}"
      dump_context(why)
      nil
    end

    # BC2CPP_RECORD_HASH_DEBUG=1 prints the instructions around the first escape of each name.
    def dump_context(why)
      return unless ENV['BC2CPP_RECORD_HASH_DEBUG'] == '1' && @where && !@dumped

      @dumped = true
      irep, k = @where
      warn "RECORD_HASH_DEBUG @#{@name} #{why} #{@site}"
      from = [k - 14, 0].max
      irep.instructions[from..(k + 3)].each_with_index { |i, n| warn "    #{from + n}: #{i.op} #{i.args}" }
    end

    def store_ok?(irep, i)
      insn = irep.instructions[i]
      defs = BytecodeIR.reaching_definitions(irep, i, insn.regs.first, through_handlers: true)
      return fail!('store source not provable') if defs.nil? || defs.empty?

      defs.all? do |d|
        next fail!('store from an argument') if d.entry?

        src = irep.instructions[d.index]
        case src.op
        when 'LOADNIL' then true
        when 'HASH'
          @literals << [irep, d.index] unless @literals.any? { |l, x| l.equal?(irep) && x == d.index }
          true
        else fail!("store from #{src.op}")
        end
      end
    end

    # Alias scan from the literal: it may only be stored to this slot (or read/written by key).
    def literal_scan(irep, d)
      insn = irep.instructions[d]
      n = insn.uint_operand or return fail!('HASH without a pair count')
      base = insn.reg.to_i
      n.times do |k|
        keys = RecordHash.literal_keys(irep, d, base + 2 * k) or return fail!('non-literal key in a Hash literal')
        @literal_pairs << [irep, d, keys, base + 2 * k + 1]
      end
      alias_scan(irep, d, base)
    end

    # Forward walk over every path from +start+ where register +reg+ holds the Hash.
    def alias_scan(irep, start, reg)
      prog = BytecodeIR.for(irep)
      @site = " [#{irep.file.to_s.sub(%r{.*/(mruby-)}, '\\1')} irep #{irep.label} insn #{start}]"
      return fail!('unresolved control flow') unless prog.resolved?
      return fail!('unresolved handlers') if prog.handlers? && !prog.handlers_resolved?
      return false unless scan_captures(irep, reg)

      handler_targets = Hash.new { |h, k| h[k] = [] }
      prog.handler_edges.each { |e| handler_targets[e.src] << e.target } if prog.handlers?
      seen = Set.new
      work = prog.instruction_at(start).successors.map { |s| [s, Set[reg]] }
      until work.empty?
        k, state = work.pop
        next unless seen.add?([k, state])
        return fail!('alias scan state limit') if seen.size > STATE_LIMIT

        insn = prog.instruction_at(k).source
        @site = " [#{irep.file.to_s.sub(%r{.*/(mruby-)}, '\\1')} irep #{irep.label} insn #{k}]"
        @where = [irep, k]
        nxt = step(irep, k, insn, state)
        return false if nxt.nil?

        edge_states(prog, k, insn, nxt).each { |s, st| work << [s, st] unless st.empty? }
        # A raise happens before or after this instruction's own write.
        handler_targets[k].each { |s| work << [s, state | nxt] }
      end
      true
    end

    # Successor => alias set. A Hash is truthy, so the edge of a branch that needs the tested register
    # to be nil/false cannot carry that register as an alias.
    def edge_states(prog, k, insn, state)
      succs = prog.instruction_at(k).successors
      return succs.to_h { |s| [s, state] } unless %w[JMPIF JMPNOT JMPNIL].include?(insn.op) && succs.size == 2

      tested = insn.reg.to_i
      target = prog.address_to_index[insn.jump_target]
      falsy_edge = insn.op == 'JMPIF' ? :fall : :jump
      succs.to_h do |s|
        jump = s == target
        falsy = falsy_edge == :jump ? jump : !jump
        [s, falsy ? state - [tested] : state]
      end
    end

    # A register that holds the Hash may be read by a nested block after the frame moved on, so every
    # block read of it is an alias source of its own (once per register, whatever the path).
    def scan_captures(irep, reg)
      return true unless @captured.add?([irep.label, reg])

      site = @site
      ok = captured_reads(irep, reg).all? { |child, i| alias_scan(child, i, child.instructions[i].reg.to_i) }
      @site = site
      ok
    end

    # [child irep, index] of every GETUPVAR in a block nested under +irep+ that reads +reg+ of +irep+.
    def captured_reads(irep, reg)
      found = []
      walk = lambda do |node, depth|
        (node.reps || []).each do |label|
          child = irep.tree[label] or next
          child.instructions.each_with_index do |insn, i|
            next unless insn.op == 'GETUPVAR'

            index, level = insn.upvar_ref
            found << [child, i] if index == reg && level == depth
          end
          walk.call(child, depth + 1)
        end
      end
      walk.call(irep, 0)
      found
    end

    # The alias set after +insn+, or nil after recording a failure (the Hash escapes).
    def step(irep, k, insn, state)
      op = insn.op
      lead = insn.reg&.to_i
      case op
      when 'MOVE'
        dst, src = insn.regs.map(&:to_i)
        return state - [dst] unless state.include?(src)
        return nil unless scan_captures(irep, dst)

        state | [dst]
      when 'GETIDX'
        recv, key = insn.regs.map(&:to_i)
        return escape('used as a key') if state.include?(key)
        return state unless state.include?(recv)
        return escape('unexpected GETIDX operands') unless key == recv + 1

        # A read by any key mutates nothing, so the key need not be literal.
        @reads += 1
        state - [recv]
      when 'SETIDX'
        recv, key, val = insn.regs.map(&:to_i)
        return escape('stored as a value or key') if state.include?(val) || state.include?(key)
        return state unless state.include?(recv)

        keys = RecordHash.literal_keys(irep, k, key, for_write: true)
        return escape('non-literal key write') unless keys && key == recv + 1 && val == recv + 2

        @stores << [keys, irep, k, val]
        # OP_SETIDX overwrites its receiver register with the assigned value.
        state - [recv]
      when 'JMPIF', 'JMPNOT', 'JMPNIL'
        state
      when 'SETIV'
        return state unless state.include?(insn.regs.first.to_i)

        insn.ivar == @name ? state : escape("stored to @#{insn.ivar}")
      when 'SEND'
        return delete_step(irep, k, insn, state, lead) if insn.sym == 'delete' && state.include?(lead)

        generic_step(insn, state, lead)
      else
        generic_step(insn, state, lead)
      end
    end

    # `h.delete(:lit)` on the plain Hash: the key may be absent afterwards; nothing else changes.
    def delete_step(irep, k, insn, state, lead)
      return escape('Hash#delete may be redefined') unless native_hash_delete?
      return escape('delete arity') unless insn.argc == 1 && insn.argc_operand[1].to_i.zero?
      return escape('deleted key is the Hash') if state.include?(lead + 1)

      keys = RecordHash.literal_keys(irep, k, lead + 1, for_write: true)
      return escape('non-literal delete') unless keys

      @deleted.concat(keys)
      state.reject { |x| x >= lead }.to_set
    end

    def native_hash_delete?
      return @native_hash_delete if defined?(@native_hash_delete)

      @native_hash_delete =
        (@registry['delete'] || []).none? { |d| %w[Hash Object Kernel BasicObject Enumerable].include?(d.owner) } &&
        @closed_world.core_ruby_arm_safe?('delete', 'Hash')
    end

    def generic_step(insn, state, lead)
      others = (lead ? insn.regs.drop(1) : insn.regs).map(&:to_i)
      return escape("operand of #{insn.op}") if others.any? { |x| state.include?(x) }
      return state unless lead

      op = insn.op
      if op == 'ARRAY' && insn.regs.size == 2 # ARRAY2: reads Rb..Rb+c-1
        count = insn.typed.last.value
        return escape('array element') if state.any? { |x| x >= others.first && x < others.first + count }
      elsif !WRITE_LEAD_ONLY.include?(op) && !op.start_with?('LOADI')
        hi = read_span(insn, lead)
        return escape("operand of #{op}") if state.any? { |x| x >= lead && x <= hi }
      end
      return state if READ_LEAD_KEEP.include?(op)
      return state.reject { |x| x >= lead }.to_set if CALL_OPS.include?(op)

      state - [lead]
    end

    # Highest register an op reads through its leading operand (INF: unknown op).
    def read_span(insn, lead)
      case insn.op
      when 'SEND0', 'SSEND0' then lead
      when *CALL_OPS
        n = insn.argc
        nk = insn.argc_operand&.at(1)
        n && nk ? lead + n + 2 * nk + 1 : INF
      when 'ARRAY' then lead + (insn.uint_operand || 0) - 1
      when 'HASH' then lead + 2 * (insn.uint_operand || 0) - 1
      when 'HASHADD' then lead + 2 * (insn.uint_operand || 0)
      when 'ARYPUSH' then lead + (insn.uint_operand || 0)
      when 'ADD', 'SUB', 'MUL', 'DIV', 'LT', 'LE', 'GT', 'GE', 'EQ', 'ARYCAT', 'STRCAT', 'HASHCAT',
           'RANGE_INC', 'RANGE_EXC' then lead + 1
      when 'ADDI', 'SUBI', 'RESCUE', 'RETURN', 'RETURN_BLK', 'BREAK', 'RAISEIF', 'MATCHERR', 'SETUPVAR', 'ASET',
           'JMPIF', 'JMPNOT', 'JMPNIL' then lead
      else INF
      end
    end

    # key => {strict:, trusted:, writers:, nilable:}: class sets (:unknown once a writer is unclassified),
    # every [irep, index, register] that stores under the key, and whether a read can see nil.
    def join_keys
      out = Hash.new { |h, k| h[k] = { strict: Set.new, trusted: Set.new, writers: [], nilable: false } }
      # Per literal, including an empty `{}` (it has no pair to group by): the keys it always carries.
      per_literal = @literals.to_h { |irep, d| [[irep.label, d], Set.new] }
      @literal_pairs.each { |irep, d, keys, _| per_literal[[irep.label, d]].merge(keys) }
      present_in_all = per_literal.values.reduce(:&) || Set.new
      add = lambda do |keys, irep, idx, reg|
        strict, trusted = classify(irep, idx, reg)
        keys.each do |key|
          out[key][:strict].merge(strict)
          out[key][:trusted].merge(trusted)
          out[key][:writers] << [irep, idx, reg]
        end
      end
      @literal_pairs.each { |irep, d, keys, vreg| add.call(keys, irep, d, vreg) }
      @stores.each { |keys, irep, i, vreg| add.call(keys, irep, i, vreg) }
      @deleted.each { |key| out[key] }
      out.each do |key, info|
        # A key some literal omits, or a delete can remove, reads as nil until stored.
        info[:nilable] = !present_in_all.include?(key) || @deleted.include?(key)
        [info[:strict], info[:trusted]].each { |set| set << NIL_CLASS if info[:nilable] }
      end
      out.to_h
    end

    def classify(irep, idx, reg)
      defs = BytecodeIR.reaching_definitions(irep, idx, reg.to_s, through_handlers: true)
      return [UNKNOWN_SET, UNKNOWN_SET] if defs.nil? || defs.empty?

      strict = Set.new
      trusted = Set.new
      defs.each do |d|
        cls = d.entry? ? nil : (literal_class(irep, d.index) || strict_new_class(irep, d.index))
        strict << cls
        trusted << (cls || (@trusted&.call(irep, idx, reg) ? 'Array' : nil))
      end
      [strict.include?(nil) ? UNKNOWN_SET : strict, trusted.include?(nil) ? UNKNOWN_SET : trusted]
    end

    def literal_class(irep, d)
      insn = irep.instructions[d]
      case insn.op
      when 'ARRAY' then 'Array'
      when 'HASH' then 'Hash'
      when 'STRING' then 'String'
      when 'LOADSYM' then 'Symbol'
      when 'LOADTRUE' then 'TrueClass'
      when 'LOADFALSE' then 'FalseClass'
      when 'LOADNIL' then NIL_CLASS
      when 'LOADL'
        entry = irep.pool[insn.pool_index]
        entry.is_a?(Hash) ? (entry[:type] == :float ? 'Float' : 'Integer') : nil
      else
        insn.op.start_with?('LOADI') ? 'Integer' : nil
      end
    end

    # `Array.new(...)`/`Hash.new(...)`/`String.new(...)` on the untouched core constant.
    def strict_new_class(irep, d)
      insn = irep.instructions[d]
      return nil unless %w[SEND SENDB].include?(insn.op) && insn.sym == 'new'

      path = irep.constant_path(d - 1, insn.reg, skip_ops: READ_ONLY_OPCODE_SKIP)
      return nil unless path&.root == :const && path.segments.empty? && %w[Array Hash String].include?(path.name)
      return nil unless @closed_world.stable_constant_identity?(path.name) && @closed_world.standard_constructor_lookup?
      return nil unless (@registry['new'] || []).all? { |md| md.owner == '<native>' }

      path.name
    end
  end
end
