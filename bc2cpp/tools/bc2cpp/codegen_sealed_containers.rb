# frozen_string_literal: true

require 'set'
require_relative 'bytecode_ir'
require_relative 'bytecode_ir_containers'
require_relative 'dynamic_names'

# SEALED_HASH_IVAR: `@h[k]` is exactly C or nil when the Hash in `@h` never leaves the
# ivar and every Hash ever stored there was a literal whose values are all exactly C.
#
# ElementLayout's element facts are guarded hints (a mutation through an alias it cannot attribute is a named
# residual). This rule is a proof, for the narrow shape where no alias exists:
#
#   * stores: every SETIV that can write `@h` of the reader's class (ivar_store_sites_of: NUMERIC_IVAR_PROOF's group,
#     which fails on an attr_writer, a Symbol or String naming the ivar, an outside source spelling it, a
#     self-rebinding block, a wild family) stores either nil or the result of a `HASH` instruction directly before
#     it (nothing else saw the new Hash), whose register no later instruction reads before overwriting it, and whose
#     every value register is exactly C at the HASH (the caller's class trace);
#   * reads: every GETIV of the name anywhere in the program feeds only a GETIDX on its own register, in straight-line
#     code, through loads that do not read it. OP_GETIDX on an exact Hash is mrb_hash_get (vm.c), which runs no
#     method of the Hash and returns a stored value or, for a missing key and no default, nil. A literal Hash has no
#     default and nothing can give it one without a reference;
#   * no other way to the Hash: no attr_reader / attr_accessor of the name, no instance_variable_get the closed
#     world cannot see (a computed send of it, an outside Ruby source spelling it, a native other than its
#     registration in mruby-metaprog; a literal `instance_variable_get(:@h)` already fails the group), and no
#     ObjectSpace.each_object at all (it hands out every live object);
#   * nil cannot answer `[]` (an unassigned or nil `@h` then raises instead of returning).
#
# The answer is "C or nil" (a missing key), so only a nilable consumer (`-> C?`) may take it.
class CodeGen
  # Loads that write only their leading register and read no register but MOVE's source.
  SEALED_HASH_LOAD_OPS = %w[NOP MOVE LOADL LOADSYM LOADNIL LOADSELF LOADTRUE LOADFALSE GETIV GETCONST GETUPVAR
                            STRING].freeze
  SEALED_HASH_WINDOW = 16
  # Frame exits that read no register: the stored Hash's register dies there unread.
  SEALED_HASH_EXITS = %w[RETNIL RETTRUE RETFALSE RETSELF].freeze
  # Ruby methods that reach an object without a reference, and the one native source allowed to spell each (its
  # registration).
  SEALED_HASH_REFLECTION = { 'instance_variable_get' => 'mruby-metaprog/src/metaprog.c',
                             'each_object' => 'mruby-objectspace/src/mruby_objectspace.c' }.freeze
  # SEALED_HASH_STORES: native Hash methods a read may call, as [name, argc]. Each answers a new object or a scalar,
  # never the Hash itself, and none stores into it, so no second reference to the Hash comes out of them.
  SEALED_HASH_READ_SENDS = [['keys', 0], ['values', 0], ['size', 0], ['length', 0], ['empty?', 0], ['key?', 1],
                            ['has_key?', 1], ['include?', 1], ['member?', 1]].freeze
  # The classes whose Ruby definitions could answer those names on a Hash.
  SEALED_HASH_ANCESTORS = %w[Hash Enumerable Object Kernel BasicObject].freeze

  # nil when the GETIDX at +w+ of +irep+ reads a sealed Hash ivar whose values are exactly +cls+, else why not.
  # +prove+ is called as (irep, index, register) for each stored value and answers nil or why it is not +cls+.
  def sealed_hash_read_failure(irep, w, cls, prove)
    insn = BytecodeIR.for(irep).source_at(w)
    return 'not a GETIDX' unless insn&.op == :GETIDX && insn.reg

    sources = BytecodeIR.producers(irep, w, insn.reg, through_handlers: true)
    return 'its receiver is not one ivar read' unless sources&.size == 1 && sources.first.op == :GETIV

    name = sources.first.insn.ivar
    owner = ivar_reader_owner(irep.label)
    return 'its receiver is not an ivar of a known class' unless name && owner

    why = sealed_hash_ivar_failure(owner, name)
    return "@#{name} is not a sealed Hash (#{why})" if why

    sites, why = ivar_store_sites_of(owner, name)
    return "@#{name}: #{why}" if why

    sites.each do |site_irep, idx, reg|
      why = sealed_hash_store_failure(site_irep, idx, reg, cls, prove)
      return "@#{name} = (#{why}) at #{site_irep.file}:#{BytecodeIR.for(site_irep).source_at(idx).lineno}" if why
    end
    # SEALED_HASH_STORES: `@h[k] = v` stores v into the one Hash the slot holds.
    sealed_hash_index_stores(name).each do |site_irep, idx, value|
      why = prove.call(site_irep, idx, value)
      return "@#{name}[k] = (#{why}) at #{site_irep.file}:#{BytecodeIR.for(site_irep).source_at(idx).lineno}" if why
    end
    nil
  end

  # The name-level conditions (reads, reflection, accessors, nil), cached per name.
  def sealed_hash_ivar_failure(owner, name)
    @sealed_hash_ivar_failures ||= {}
    key = [owner, name]
    return @sealed_hash_ivar_failures[key] if @sealed_hash_ivar_failures.key?(key)

    @sealed_hash_ivar_failures[key] = compute_sealed_hash_ivar_failure(name)
  end

  def compute_sealed_hash_ivar_failure(name)
    return "nil may answer `[]`, so an unassigned @#{name} would not raise" unless nil_unanswerable?('[]')
    return 'instance_variable_get or ObjectSpace.each_object may reach it' unless sealed_hash_reflection_free?

    accessor = (@registry[name] || []).find { |d| d.kind == :ivar_accessor }
    return "#{accessor.owner} has an attr reader `#{name}`" if accessor

    stores = []
    @ireps.each_value do |ir|
      BytecodeIR.for(ir).each_with_op('GETIV') do |insn, g|
        next unless insn.ivar == name
        next if sealed_hash_getiv_consumed?(ir, g)
        next if sealed_hash_stores? && sealed_hash_getiv_stores(ir, g, stores)

        return "the read at #{ir.file}:#{insn.lineno} is used other than as `@#{name}[k]`"
      end
    end
    (@sealed_hash_index_stores ||= {})[name] = stores
    nil
  end

  # SEALED_HASH_STORES: the `@name[k] = v` sites, as [irep, index, value register]; filled by the name check.
  def sealed_hash_index_stores(name)
    @sealed_hash_index_stores ||= {}
    @sealed_hash_index_stores.fetch(name, [])
  end

  # BC2CPP_SEALED_HASH_STORES=0 keeps the literal-only rule.
  def sealed_hash_stores?
    return @sealed_hash_stores if defined?(@sealed_hash_stores)

    @sealed_hash_stores = ENV['BC2CPP_SEALED_HASH_STORES'] != '0' && nil_unanswerable?('[]=') &&
                          SEALED_HASH_READ_SENDS.all? { |name, _| sealed_hash_read_send_native?(name) }
  end

  # Only a native answers +name+ on a Hash: no Ruby definition on its ancestors, nothing prepended or mixed into
  # Hash, and nil cannot answer it (an unassigned slot raises).
  def sealed_hash_read_send_native?(name)
    (@registry[name] || []).none? { |d| SEALED_HASH_ANCESTORS.include?(d.owner) } &&
      Array(@prepended_modules['Hash']).empty? && !@unknown_mixins.include?('Hash') && nil_unanswerable?(name)
  end

  # SEALED_HASH_STORES: the GETIV at +g+ is only read as the receiver of `[]`, `[]=` (its stores are appended to
  # +stores+) or a SEALED_HASH_READ_SENDS send, through its copies in this frame and never by a block.
  def sealed_hash_getiv_stores(irep, g, stores)
    reg = BytecodeIR.for(irep).source_at(g).reg
    return false unless reg && !fixnum_proof_ctx(irep)[:upvars].include?(reg.to_s)

    uses = FactoryFlow.uses(irep, g, reg) or return false
    program = BytecodeIR.for(irep)
    found = []
    ok = uses.all? do |use, r|
      insn = program.source_at(use)
      next false if fixnum_proof_ctx(irep)[:upvars].include?(r.to_s)

      case insn.op
      when :GETIDX then insn.reg == r.to_s
      when :SETIDX
        recv, key, value = insn.regs
        next false unless recv == r.to_s && value && ![key, value].include?(r.to_s)

        found << [irep, use, value]
      when :SEND, :SEND0
        argc = insn.op == :SEND0 ? 0 : (insn.plain_fixed_argc? ? insn.argc : nil)
        insn.reg == r.to_s && SEALED_HASH_READ_SENDS.include?([insn.sym, argc])
      else false
      end
    end
    stores.concat(found) if ok
    ok
  end

  # No instance_variable_get the closed world cannot see, and no each_object.
  def sealed_hash_reflection_free?
    return @sealed_hash_reflection_free if defined?(@sealed_hash_reflection_free)

    world = @closed_world
    dynamic = DynamicNames.universe(@ireps)
    @sealed_hash_reflection_free = world.global_refusal.nil? &&
                                   SEALED_HASH_REFLECTION.all? do |name, registration|
                                     !world.outside_ruby_token?(name) && !dynamic.include?(name) &&
                                       world.native_paths_spelling(name).all? { |path| path.end_with?(registration) } &&
                                       sealed_hash_sends_visible?(name)
                                   end
  end

  # Every send of +name+ is an instance_variable_get of a literal ivar Symbol (which fails that ivar's group).
  def sealed_hash_sends_visible?(name)
    @ireps.each_value.none? do |ir|
      BytecodeIR.for(ir).each_source.any? do |insn, idx|
        insn.sym == name && insn.op.include?('SEND') &&
          !(name == 'instance_variable_get' && literal_ivar_argument?(ir, idx, insn))
      end
    end
  end

  # The GETIV at +g+ feeds only `GETIDX` on its own register, in straight-line code.
  def sealed_hash_getiv_consumed?(irep, g)
    x = BytecodeIR.for(irep).source_at(g).reg
    return false unless x

    sealed_hash_straight_line(irep, g + 1) do |insn|
      next :done if insn.op == :GETIDX && insn.reg == x
      next :fail if insn.op == :MOVE && insn.regs[1] == x
      next :done if insn.reg == x # overwritten unread

      :next
    end
  end

  # One store: nil, or a HASH literal directly before the SETIV whose register dies unread and whose values are
  # exactly +cls+.
  def sealed_hash_store_failure(irep, idx, reg, cls, prove)
    sources = BytecodeIR.producers(irep, idx, reg, through_handlers: true, follow_moves: false)
    return 'a value the checker cannot follow' unless sources

    program = BytecodeIR.for(irep)
    preds = program.instruction_predecessors(include_handlers: true)
    sources.each do |producer|
      return 'an argument' if producer.entry?
      next if producer.op == :LOADNIL

      literal = program.container_literal(producer.index)
      return "#{producer.op}, not a Hash literal" unless literal&.kind == :hash
      unless producer.index == idx - 1 && preds && preds[idx] == Set[idx - 1]
        return 'a Hash literal another instruction can see before it is stored'
      end
      return 'a Hash literal whose register is read after the store' unless sealed_hash_dead_after?(irep, idx, reg.to_s)

      literal.value_regs.each_with_index do |value, k|
        why = prove.call(irep, producer.index, value)
        return "value #{k + 1}: #{why}" if why
      end
    end
    nil
  end

  # After the SETIV at +s+, +reg+ is overwritten before anything reads it.
  def sealed_hash_dead_after?(irep, s, reg)
    sealed_hash_straight_line(irep, s + 1) do |insn|
      next :done if SEALED_HASH_EXITS.include?(insn.op) || (sealed_hash_empty_literal?(insn) && insn.reg == reg)
      next :fail unless sealed_hash_load_op?(insn.op)
      next :fail if insn.op == :MOVE && insn.regs[1] == reg
      next :done if insn.reg == reg

      :next
    end
  end

  # Walks Program#straight_line from +start+ while each instruction is a SEALED_HASH_LOAD_OPS / LOADI* load; the
  # block answers :done, :fail or :next for each. true on :done, false on :fail, on any other instruction or past
  # the window.
  def sealed_hash_straight_line(irep, start)
    BytecodeIR.for(irep).straight_line(start, SEALED_HASH_WINDOW) do |insn, _k|
      verdict = yield insn
      return true if verdict == :done && (insn.op == :GETIDX || sealed_hash_load_op?(insn.op) ||
                                          SEALED_HASH_EXITS.include?(insn.op) || sealed_hash_empty_literal?(insn))
      return false if verdict == :fail || !sealed_hash_load_op?(insn.op)
    end
    false
  end

  # `HASH Ra 0` / `ARRAY Ra 0`: writes R[a], reads no register.
  def sealed_hash_empty_literal?(insn)
    %w[HASH ARRAY].include?(insn.op) && insn.typed.size == 2 && insn.typed[1].value.to_i.zero?
  end

  def sealed_hash_load_op?(op)
    SEALED_HASH_LOAD_OPS.include?(op) || op.start_with?('LOADI')
  end
end
