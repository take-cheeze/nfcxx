# frozen_string_literal: true

require 'set'
require_relative 'bytecode_ir_ops'
require_relative 'core_defs'
require_relative 'define_method_sites'
require_relative 'core_hierarchy_sigs'

# LOOP_INSTALLERS: a class-body loop over a literal container whose body installs
# attr_reader/attr_writer/attr_accessor names (`NAMES.each { |n| attr_accessor n }`, optcarrot's
# `OPTIONS.each_value { |o| o.each { |id, opt| next if opt[:shortcut]; attr_reader id } }`) is, to
# the registry, the same fact as the literal `attr_reader :a, :b` it unrolls to.
#
# The names are not guessed from the container: the loop body is executed here, on the literal
# value, by an interpreter that knows only a few pure operations (a hint that is not
# proved is not used). Anything it does not model refuses the loop, which then stays the dynamic
# installer it was.
#
# Soundness conditions, each enforced where named:
# - a container no call could have reached: every call poisons its operands and the constants
#   (Walker#generic_call), and a poisoned container is never iterated (Walker#loop_site).
# - the loop runs once per execution of the body (Walker#straight_line_limit).
# - the iterators, lookups and installers are mruby's own (#core_methods_untouched?).
# - the interpreter refuses every opcode, receiver and branch it does not model (Interp).
#
# DEFINE_METHOD_LOOPS: `define_method(n) { ... }` in such a loop is an installer the
# interpreter models too. Each name it installs becomes a MethodDef(installer: :define_method) whose body is
# a copy of the block (DefineMethodSites.expand) in which the loop variables the block reads are the Symbols
# that iteration bound. Conditions on top of the ones above:
# - the loop runs in a class or module body of the engine's own Ruby (not a singleton class, a Struct
#   block or mruby's core Ruby), where Module#define_method installs a public method on that class;
# - the name is a Symbol the walk built, and the body is method-shaped (DefineMethodSites.loop_body_captures);
# - every loop-block register the body reads holds a Symbol when the iteration's frame ends, which is the
#   value the block's env keeps from then on (the frame cannot run the body earlier: the interpreter models no
#   call that could).
# DefineMethodSites.settle then keeps all of a send's expansions or none.
module LoopInstallers
  # Not read from core_block_iterators: that table declares no Hash#each/each_pair/each_value/each_key.
  ITERATORS = %w[each each_pair each_value each_key].freeze
  ATTR_SENDS = %w[attr_reader attr_writer attr_accessor].freeze
  # Methods the interpreter models on a container, and the classes whose reopening would change them.
  MODELED_METHODS = (ITERATORS + %w[[] []= key? has_key? freeze]).freeze
  # From core_hierarchy: the ancestry of the container and installer classes, plus every core mixin.
  CORE_OWNERS = (%w[Hash Array Module Class].flat_map { |name| CoreHierarchySigs.ancestors(name) } +
                 CoreHierarchySigs.hierarchy[1].values.flatten).uniq.freeze
  CALLS = BytecodeIR::Ops::SEND_FAMILY
  # SEND and SEND0 alone: an explicit receiver and no block (SSEND forms take self, SENDB/SSENDB pass a block).
  PLAIN_SEND = (BytecodeIR::Ops::SEND - BytecodeIR::Ops::BLOCK_SEND - BytecodeIR::Ops::SELF_SEND).freeze
  # Control flow that ends or splits the straight-line walk.
  FLOW_OPS = BytecodeIR::Ops::FLOW_PREFIX_OPS
  ARITH_OPS = %w[ADD SUB MUL DIV EQ LT LE GT GE ADDI SUBI].freeze
  LOAD_TRUTHY = BytecodeIR::Ops::LOAD_TRUTHY_OPS
  ATTR_NAME = /\A[A-Za-z_][A-Za-z0-9_]*\z/
  # A name define_method installs, or a Symbol an expansion loads: an identifier, optionally ending in ?, ! or =.
  METHOD_NAME = /\A[A-Za-z_][A-Za-z0-9_]*[?!=]?\z/
  STEP_LIMIT = 200_000

  Sym = Struct.new(:name)
  # kind :hash (items: name => value, Symbol keys only) or :array.
  Cont = Struct.new(:kind, :items, :poisoned)
  BlockVal = Struct.new(:label)
  OPAQUE = Object.new.freeze
  TRUTHY = Object.new.freeze
  SELF = Object.new.freeze

  # An interpreter refusal; Walker#loop_site turns it into the reason the loop stays dynamic.
  class Refused < StandardError; end

  Result = Struct.new(:installs, :sites, :namespace, keyword_init: true)

  module_function

  # True when the SENDB at insns[idx] is a loop whose block tree sends an attr_* installer or define_method.
  def candidate?(irep, idx, ireps)
    insn = irep.instructions[idx]
    return false unless insn.op == 'SENDB' && ITERATORS.include?(insn.sym)

    return false if idx.zero?

    block = irep.instructions[idx - 1]
    return false unless block.op == 'BLOCK' && block.block_index

    label = irep.reps[block.block_index]
    label ? !(attr_sends(label, ireps).empty? && define_method_sends(label, ireps).empty?) : false
  end

  # Every `define_method` SSENDB of the block tree rooted at +label+, as [irep label, index].
  def define_method_sends(label, ireps, found = [])
    irep = ireps[label] or return found
    irep.each_with_op('SSENDB') do |insn, i|
      found << [label, i] if insn.sym == 'define_method'
    end
    irep.reps.compact.each { |child| define_method_sends(child, ireps, found) }
    found
  end

  # Every attr_* send of the block tree rooted at +label+, as [irep label, index].
  def attr_sends(label, ireps, found = [])
    irep = ireps[label] or return found
    irep.each_with_op('SSEND', 'SSEND0') do |insn, i|
      found << [label, i] if ATTR_SENDS.include?(insn.sym)
    end
    irep.reps.compact.each { |child| attr_sends(child, ireps, found) }
    found
  end

  # Registers the accessors of every recognized loop. +sites+: [[irep label, SENDB index, namespace,
  # visibility], ...] the registry walk collected. Returns [recognized, refused reasons].
  def install(registry, ireps, sites)
    refused = Hash.new(0)
    recognized = 0
    sites.group_by(&:first).each_value do |group|
      irep = ireps.fetch(group.first.first)
      Walker.new(irep, ireps, registry, group.to_h { |_, idx, ns, vis| [idx, [ns, vis]] }).run.each do |site|
        if site.is_a?(String)
          refused[site] += 1
        else
          recognized += 1
          register(registry, site, ireps)
        end
      end
    end
    [recognized, refused]
  end

  def register(registry, result, ireps)
    owner = result.namespace || 'Object'
    seen = Set.new
    expansions = Hash.new(0)
    result.installs.each do |kind, name, body, captures, send_site|
      if kind == :define_method
        label = DefineMethodSites.expand(ireps, body, captures, expansions[body])
        expansions[body] += 1
        registry[name] << MethodDef.new(name: name, owner: owner, irep: label, visibility: :public,
                                        installer: :define_method, site: [send_site])
        next
      end

      names = []
      names << name if %i[reader accessor].include?(kind)
      names << "#{name}=" if %i[writer accessor].include?(kind)
      names.each do |n|
        next unless seen.add?(n)

        registry[n] << MethodDef.new(name: n, owner: owner, irep: nil, visibility: :public, kind: :ivar_accessor,
                                      core: false, site: result.sites)
      end
    end
  end

  # [irep label, index] of every attr_* send a registered loop accounts for.
  def sites(registry)
    registry.each_value.with_object(Set.new) do |defs, set|
      defs.each { |d| d.site&.each { |s| set << s } }
    end
  end

  # No user-written definition changes what the interpreter models: the container methods on core
  # owners, and the installers anywhere.
  def core_methods_untouched?(registry, ireps)
    (MODELED_METHODS + ATTR_SENDS).all? do |name|
      registry.fetch(name, []).all? do |d|
        next true if d.core || (d.irep && ireps[d.irep] && CoreDefs.core_source?(ireps[d.irep].file))

        ATTR_SENDS.include?(name) ? false : !CORE_OWNERS.include?(d.owner.to_s.delete_suffix('.singleton'))
      end
    end
  end

  def poison(value, seen = {}.compare_by_identity)
    return unless value.is_a?(Cont) && !seen.key?(value)

    seen[value] = true
    value.poisoned = true
    (value.kind == :hash ? value.items.values : value.items).each { |v| poison(v, seen) }
  end

  def reachable(value, seen = {}.compare_by_identity)
    return seen unless value.is_a?(Cont) && !seen.key?(value)

    seen[value] = true
    (value.kind == :hash ? value.items.values : value.items).each { |v| reachable(v, seen) }
    seen
  end

  # One class or module body, walked forward with the registers and constants it holds.
  class Walker
    def initialize(irep, ireps, registry, sites)
      @irep = irep
      @ireps = ireps
      @registry = registry
      @sites = sites
      @regs = {}
      @consts = {}
    end

    # One Result per recognized loop, one reason String per refused one.
    def run
      out = []
      limit = straight_line_limit
      @irep.instructions.each_with_index do |insn, idx|
        break if idx >= limit

        out << loop_site(insn, idx) if @sites.key?(idx)
        step(insn) unless @sites.key?(idx)
      end
      out
    end

    private

    def get(reg)
      @regs.fetch(reg.to_i, OPAQUE)
    end

    # First index the walk cannot treat as straight-line: a branch, a return, a handler, or any
    # instruction a branch lands on (a loop back edge makes the site run more than once).
    def straight_line_limit
      insns = @irep.instructions
      limit = insns.size
      insns.each_with_index do |insn, i|
        limit = i if FLOW_OPS.include?(insn.op) && i < limit
        target = insn.branch_target
        next unless target

        landing = @irep.index_of_addr(target)
        limit = [limit, landing].min if landing
      end
      (@irep.catch_handlers || []).each do |h|
        [h.begin_addr, h.target].each do |addr|
          at = @irep.index_of_addr(addr)
          limit = [limit, at].min if at
        end
      end
      limit
    end

    # A Result for a recognized loop, else the reason String.
    def loop_site(insn, idx)
      namespace, visibility = @sites.fetch(idx)
      return generic_refusal(insn, 'a private or protected default visibility') unless visibility == :public
      return generic_refusal(insn, 'a user definition of an iterator or installer') unless
        LoopInstallers.core_methods_untouched?(@registry, @ireps)

      recv = get(insn.reg)
      block = get(insn.reg.to_i + 1)
      return generic_refusal(insn, 'a receiver that is not a built literal container') unless recv.is_a?(Cont)

      reached = LoopInstallers.reachable(recv)
      return generic_refusal(insn, 'a container that code may have reached') if reached.each_key.any?(&:poisoned)
      return generic_refusal(insn, 'a block that is not a literal block') unless block.is_a?(BlockVal)

      interp = Interp.new(@ireps, @consts, reached, definer: definer?(namespace))
      interp.iterate(insn.sym, recv, block)
      @regs[insn.reg.to_i] = recv
      @regs.delete(insn.reg.to_i + 1)
      Result.new(installs: interp.installs, sites: LoopInstallers.attr_sends(block.label, @ireps),
                 namespace: namespace)
    rescue Refused => e
      generic_refusal(insn, e.message)
    end

    # DEFINE_METHOD_LOOPS: `define_method` in this body installs a public method on +namespace+, a class or
    # module the registry names (a singleton class body is "X.singleton", a Struct block "<struct:...>").
    def definer?(namespace)
      !namespace.nil? && !namespace.include?('.singleton') && !namespace.start_with?('<') &&
        !CoreDefs.core_source?(@irep.file)
    end

    # A loop the interpreter cannot follow is an ordinary call: its block may run anything.
    def generic_refusal(insn, why)
      generic_call(insn)
      "#{why} (#{@irep.label}:#{insn.addr})"
    end

    def step(insn)
      op = insn.op
      case op
      when 'MOVE' then @regs[insn.regs[0].to_i] = get(insn.regs[1])
      when 'LOADSYM' then @regs[insn.reg.to_i] = Sym.new(insn.sym_token)
      when 'SYMBOL' then @regs[insn.reg.to_i] = pool_symbol(insn)
      when 'LOADNIL' then @regs[insn.reg.to_i] = nil
      when 'LOADTRUE' then @regs[insn.reg.to_i] = true
      when 'LOADFALSE' then @regs[insn.reg.to_i] = false
      when 'LOADSELF' then @regs[insn.reg.to_i] = SELF
      when LOAD_TRUTHY then @regs[insn.reg.to_i] = TRUTHY
      when 'ARRAY', 'ARRAY2' then @regs[insn.reg.to_i] = build_array(insn)
      when 'HASH' then @regs[insn.reg.to_i] = build_hash(insn)
      when 'BLOCK' then @regs[insn.reg.to_i] = BlockVal.new(@irep.reps[insn.block_index])
      when 'LAMBDA', 'METHOD', 'TDEF', 'SDEF', 'TCLASS', 'SCLASS', 'GETIV', 'GETUPVAR', 'GETGV', 'GETCV', 'GETSV'
        @regs[insn.reg.to_i] = OPAQUE
      when 'SETCONST' then @consts[insn.const_name] = get(insn.reg_operand)
      when 'GETCONST' then get_const(insn)
      when 'NOP' then nil
      when 'GETMCNST', 'GETIDX', 'SETIDX', *ARITH_OPS then operand_call(insn)
      else
        CALLS.include?(op) ? call(insn) : havoc
      end
    end

    # `X = [...].freeze` leaves the value as it was; any other call may do anything to its operands.
    def call(insn)
      return generic_call(insn) unless PLAIN_SEND.include?(insn.op) && insn.sym == 'freeze' && insn.argc.to_i.zero? &&
                                       get(insn.reg).is_a?(Cont)

      nil
    end

    # An opcode that is a call on registers a, a+1, a+2 (a GETMCNST reads its scope from a).
    def operand_call(insn)
      base = insn.reg.to_i
      (base..(base + 2)).each { |r| LoopInstallers.poison(get(r)) }
      poison_consts
      return if insn.op == 'SETIDX'

      consume(base, 3)
      @regs[base] = OPAQUE
    end

    def pool_symbol(insn)
      entry = @irep.pool[insn.pool_index.to_i]
      entry.is_a?(String) ? Sym.new(entry) : OPAQUE
    end

    # The operands of a constructor or call are consumed: a stale copy in a dead register must not be
    # mistaken for a live reference (poisoning it would poison the object it was built into).
    def consume(from, count)
      count.times { |i| @regs.delete(from + i) }
    end

    # `ARRAY Ra n` takes Ra..Ra+n-1; the disassembly also calls `ARRAY2 Ra Rb c` (Rb..Rb+c-1) ARRAY.
    def build_array(insn)
      kinds = insn.operand_kinds
      from, count = case kinds
                    when %i[reg int] then [insn.reg.to_i, insn.typed[1].value]
                    when %i[reg reg int] then [insn.regs[1].to_i, insn.typed[2].value]
                    else return OPAQUE
                    end
      items = Array.new(count) { |i| get(from + i) }
      consume(from + (kinds.size == 2 ? 1 : 0), kinds.size == 2 ? count - 1 : count)
      Cont.new(:array, items, false)
    end

    def build_hash(insn)
      return OPAQUE unless insn.operand_kinds == %i[reg int]

      base = insn.reg.to_i
      pairs = insn.typed[1].value
      keys = Array.new(pairs) { |i| get(base + 2 * i) }
      values = Array.new(pairs) { |i| get(base + 2 * i + 1) }
      consume(base + 1, 2 * pairs - 1)
      return OPAQUE unless keys.all?(Sym)

      Cont.new(:hash, keys.map(&:name).zip(values).to_h, false)
    end

    # A constant read can reach const_missing, so only a constant this walk set is
    # known; reading any other may run code.
    def get_const(insn)
      name = insn.const_name
      if @consts.key?(name)
        @regs[insn.reg.to_i] = @consts[name]
      else
        poison_consts
        @regs[insn.reg.to_i] = OPAQUE
      end
    end

    # A call may mutate whatever it was handed and, by name, any constant.
    def generic_call(insn)
      base = insn.reg.to_i
      span = insn.argc.to_i + 2 * insn.nk_spec.to_i + 2
      (base..(base + span)).each { |r| LoopInstallers.poison(get(r)) }
      poison_consts
      consume(base, span + 1)
      @regs[base] = OPAQUE
    end

    def poison_consts
      @consts.each_value { |v| LoopInstallers.poison(v) }
    end

    # An op this walk does not model: anything it held may have been reached or replaced.
    def havoc
      @regs.each_value { |v| LoopInstallers.poison(v) }
      poison_consts
      @regs.clear
    end
  end

  # Runs a loop body on concrete values. Models only the operations the loop shapes use; any other
  # opcode, receiver or branch on an unknown value raises Refused.
  class Interp
    attr_reader :installs

    def initialize(ireps, consts, protected_conts, definer: false)
      @ireps = ireps
      @consts = consts
      @protected = protected_conts
      @definer = definer
      @installs = []
      @steps = 0
    end

    def iterate(name, recv, block)
      case [recv.kind, name.to_sym]
      when %i[hash each], %i[hash each_pair]
        recv.items.to_a.each { |k, v| call_block(block, [Sym.new(k), v]) }
      when %i[hash each_value] then recv.items.values.each { |v| call_block(block, [v]) }
      when %i[hash each_key] then recv.items.keys.each { |k| call_block(block, [Sym.new(k)]) }
      when %i[array each] then recv.items.dup.each { |v| call_block(block, [v]) }
      else raise Refused, "#{name} on a #{recv.kind}"
      end
    end

    private

    def refuse(why)
      raise Refused, why
    end

    def call_block(block, args)
      irep = @ireps[block.label] or refuse('a missing block body')
      insns = irep.instructions
      first = insns.first
      refuse('a block without plain parameters') unless first&.op == 'ENTER' && first.enter_fields[0] == args.size &&
                                                        first.enter_fields[1..].all?(&:zero?)
      regs = {}
      args.each_with_index { |v, i| regs[i + 1] = v }
      defines = []
      pc = 1
      while pc < insns.size
        refuse('too many steps') if (@steps += 1) > STEP_LIMIT
        insn = insns[pc]
        pc = exec(irep, insn, pc, regs, defines)
        return close_frame(regs, defines) if pc.nil?
      end
      refuse('a block that falls off its end')
    end

    # DEFINE_METHOD_LOOPS: the frame ends, so each register a define_method body of this frame reads keeps
    # the value it has now for good.
    def close_frame(regs, defines)
      defines.each do |name, body, registers, send_site|
        captures = registers.to_h do |r|
          value = regs.fetch(r, OPAQUE)
          refuse('a define_method body reading a loop variable that is not a Symbol') unless value.is_a?(Sym)
          refuse("the captured Symbol #{value.name.inspect}") unless value.name.match?(METHOD_NAME)

          [r, value.name]
        end
        @installs << [:define_method, name, body, captures, send_site]
      end
      nil
    end

    # Index of the next instruction, nil to leave the block.
    def exec(irep, insn, pc, regs, defines)
      get = ->(r) { regs.fetch(r.to_i, OPAQUE) }
      case insn.op
      when 'MOVE' then regs[insn.regs[0].to_i] = get.call(insn.regs[1])
      when 'LOADSYM' then regs[insn.reg.to_i] = Sym.new(insn.sym_token)
      when 'SYMBOL'
        entry = irep.pool[insn.pool_index.to_i]
        regs[insn.reg.to_i] = entry.is_a?(String) ? Sym.new(entry) : OPAQUE
      when 'LOADNIL' then regs[insn.reg.to_i] = nil
      when 'LOADTRUE' then regs[insn.reg.to_i] = true
      when 'LOADFALSE' then regs[insn.reg.to_i] = false
      when 'LOADSELF' then regs[insn.reg.to_i] = SELF
      when LOAD_TRUTHY then regs[insn.reg.to_i] = TRUTHY
      when 'NOP' then nil
      when 'RETURN', 'RETNIL', 'RETSELF', 'RETTRUE', 'RETFALSE' then return nil
      when 'JMP' then return jump(irep, insn)
      when 'JMPNOT' then return truthy(get.call(insn.reg)) ? pc + 1 : jump(irep, insn)
      when 'JMPIF' then return truthy(get.call(insn.reg)) ? jump(irep, insn) : pc + 1
      when 'JMPNIL' then return opaque_check(get.call(insn.reg)).nil? ? jump(irep, insn) : pc + 1
      when 'GETIDX' then regs[insn.regs[0].to_i] = fetch(get.call(insn.regs[0]), get.call(insn.regs[1]))
      when 'SETIDX' then store(get.call(insn.regs[0]), get.call(insn.regs[1]), get.call(insn.regs[2]))
      when 'GETCONST' then regs[insn.reg.to_i] = scratch_const(insn.const_name)
      when 'BLOCK' then regs[insn.reg.to_i] = BlockVal.new(irep.reps[insn.block_index])
      when 'SEND' then regs[insn.reg.to_i] = send_op(insn, get)
      when 'SSEND', 'SSEND0' then install(insn, get)
      when 'SSENDB' then regs[insn.reg.to_i] = define_site(irep, insn, pc, get, defines)
      when 'SENDB' then nested(insn, get, regs)
      else refuse("the unmodeled opcode #{insn.op}")
      end
      pc + 1
    end

    def jump(irep, insn)
      irep.index_of_addr(insn.branch_target) || refuse('a jump to nowhere')
    end

    def opaque_check(value)
      refuse('a branch on a value the interpreter does not know') if value.equal?(OPAQUE)
      value
    end

    def truthy(value)
      !opaque_check(value).nil? && value != false
    end

    def hash_cont(value)
      refuse('a read of something that is not a literal Hash') unless value.is_a?(Cont) && value.kind == :hash
      value
    end

    def fetch(recv, key)
      refuse('a key that is not a Symbol literal') unless key.is_a?(Sym)
      hash_cont(recv).items[key.name]
    end

    # DEFAULT_OPTIONS[id] = v: the one write a loop may do, into a Hash the iteration cannot reach.
    def store(recv, key, value)
      hash = hash_cont(recv)
      refuse('a key that is not a Symbol literal') unless key.is_a?(Sym)
      refuse('a write into the container being iterated') if @protected.key?(hash)
      hash.items[key.name] = value
      LoopInstallers.poison(value)
    end

    def scratch_const(name)
      value = @consts[name]
      refuse("the constant #{name}, which the walk did not build") unless value.is_a?(Cont) && value.kind == :hash &&
                                                                         !value.poisoned
      value
    end

    def send_op(insn, get)
      refuse("the call #{insn.sym}") unless insn.plain_fixed_argc? && insn.argc == 1
      recv = hash_cont(get.call(insn.reg))
      key = get.call(insn.reg.to_i + 1)
      refuse('a key that is not a Symbol literal') unless key.is_a?(Sym)
      case insn.sym
      when 'key?', 'has_key?' then recv.items.key?(key.name)
      when '[]' then recv.items[key.name]
      else refuse("the call #{insn.sym}")
      end
    end

    def install(insn, get)
      kind = { 'attr_reader' => :reader, 'attr_writer' => :writer, 'attr_accessor' => :accessor }[insn.sym]
      refuse("the call #{insn.sym}") unless kind && insn.plain_fixed_argc?
      insn.argc.to_i.times do |i|
        arg = get.call(insn.reg.to_i + 1 + i)
        refuse('an attribute name that is not a Symbol literal') unless arg.is_a?(Sym)
        refuse("the attribute name #{arg.name.inspect}") unless arg.name.match?(ATTR_NAME)

        @installs << [kind, arg.name]
      end
    end

    # DEFINE_METHOD_LOOPS: `define_method(name) { ... }`, recorded for the frame's end (close_frame). It
    # answers the name, as Module#define_method does.
    def define_site(irep, insn, pc, get, defines)
      refuse("the call #{insn.sym}") unless insn.sym == 'define_method' && insn.plain_fixed_argc? && insn.argc == 1
      refuse('define_method outside a class or module body of the engine') unless @definer
      name = get.call(insn.reg.to_i + 1)
      block = get.call(insn.reg.to_i + 2)
      refuse('a method name that is not a Symbol literal') unless name.is_a?(Sym)
      refuse("the method name #{name.name.inspect}") unless name.name.match?(METHOD_NAME)
      refuse('a define_method body that is not a literal block') unless block.is_a?(BlockVal)
      body = @ireps[block.label] or refuse('a missing define_method body')
      registers = DefineMethodSites.loop_body_captures(body, @ireps)
      refuse('a define_method body a method cannot spell') unless registers

      defines << [name.name, block.label, registers.to_a.sort, [irep.label, pc]]
      name
    end

    def nested(insn, get, regs)
      refuse('an iterator call with arguments') unless insn.plain_fixed_argc? && insn.argc.zero?
      recv = get.call(insn.reg)
      block = get.call(insn.reg.to_i + 1)
      refuse('an iteration over something that is not a literal container') unless recv.is_a?(Cont)
      refuse('a block that is not a literal block') unless block.is_a?(BlockVal)
      refuse("the iterator #{insn.sym}") unless ITERATORS.include?(insn.sym)
      iterate(insn.sym, recv, block)
      regs[insn.reg.to_i] = recv
    end
  end
end
