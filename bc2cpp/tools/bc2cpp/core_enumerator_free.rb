# frozen_string_literal: true

require 'set'
require_relative 'bytecode_ir'
require_relative 'bytecode_ir_ops'
require_relative 'ir_block_operands'
require_relative 'core_enumerator_types'
require_relative 'native_owner_map'

# CORE_ENUMERATOR_FREE (closed only): a proof that no Enumerator is ever created in the closed build, so the methods
# of mruby-enumerator's Fiber machinery (Enumerator#each, #with_index, #initialize, Generator, Yielder, Kernel#to_enum,
# Enumerable#zip and #chunk, ...) can never run and the build may remove them like any other unreachable core method.
# The name scan (CoreNativeCandidates) cannot prove it: `each`, `zip` and `initialize` are spelled all over.
#
# An Enumerator is made by `Enumerator.new` and by `to_enum`/`enum_for`, which every core iterator calls when it is
# given no block (`return to_enum(:each) unless block_given?`), and by two natives (Array#index and #rindex, with
# neither argument nor block). So the proof is about the call sites of those iterators:
#
#   creators   the methods that can make one: a Ruby body that names to_enum/enum_for or an Enumerator constant, or a native
#              that calls to_enum (read from the C text). `:blockless` ones make it only when called without a block
#              (the creating instruction lies where no block is given: the false arm of `block_given?`, or of a test of the
#              block parameter); `:always` ones whatever the caller passes (Enumerable#chunk builds an Enumerator for its
#              block, #zip one per argument). A method that forwards its own block to a creator name outside the arm
#              where a block is given is a `:blockless` creator itself, to a fixpoint.
#   sites      every send of a creator name in the Ruby the binary loads. It needs no proof when it passes a block (a
#              literal, a Symbol or the caller's own block where one is given) to a `:blockless` creator, or an argument to a
#              native that only makes one without arguments. Any other site needs its receiver proven not to reach a
#              creator: the lookup of the name on every class the receiver may have (core_enumerator_types.rb) finds
#              another definition first, or finds none.
#   others     a Symbol literal that names a creator and reaches a lookup (`map(&:index)`, `send(:select)`); a native that
#              spells a creator name; an Enumerator constant outside a creator; a `method_missing`.
#
# The proof holds only when every one is accounted for; the unproven ones are returned with file and line so the result
# says what an engine rewrite would have to change. Nothing here is a heuristic: a value the model cannot type is TOP, and a
# site with a TOP receiver is unproven.
#
# Premises, the ones the closed-list proof makes anyway (docs/bc2cpp-unregistered-methods.md): the Ruby the binary runs is the
# world's own (the sealed host refuses --script), natives look a method up only by a name they spell, and every lookup by
# Symbol takes a literal (StaticDispatchSymbolUses). So a parameter that no send, `new`, `super`, native, Symbol or VM call
# supplies receives nothing, and a receiver read from it is the empty set, which passes: that code does not run.
module CoreEnumeratorFree
  ENUM_CONSTANTS = %w[Enumerator Generator Yielder Lazy Chain Producer].to_set.freeze
  CREATE_SENDS = %w[to_enum enum_for].to_set.freeze
  # The file whose methods the proof releases.
  GROUP_FILE = %r{/mruby-enumerator/mrblib/enumerator\.rb\z}
  # The classes whose instances only an Enumerator machinery makes: their methods run on an existing instance, so they
  # are no way to get the first one (Enumerator.produce, a singleton, is).
  INSTANCE_OWNERS = %w[Enumerator Enumerator::Generator Enumerator::Yielder Enumerator::Lazy Enumerator::Chain].to_set.freeze
  TOP = CoreEnumeratorTypes::TOP
  # +site+ is [file, line] of the instruction that made it a creator.
  Creator = Struct.new(:owner, :name, :mode, :noarg, :why, :explained, :group, :site, keyword_init: true)
  Unproven = Struct.new(:file, :line, :where, :name, :why, keyword_init: true)
  Result = Struct.new(:holds, :creators, :unproven, :proven, :sites, keyword_init: true)
  # One checked site: name, file, line, where, verdict (:block: settled by a block or an argument, :receiver, or :unproven).
  # +classes+ is the receiver's class set for a :receiver verdict (empty when no value ever reaches the receiver).
  SiteLog = Struct.new(:name, :file, :line, :where, :verdict, :engine, :classes, keyword_init: true)

  # One Ruby world (the engine, or one core file): the tables the proof reads, built once.
  class Group
    attr_reader :ireps, :registry, :engine, :file, :alias_sites

    # +alias_sites+ are build_registry's ALIAS records ({owner:, new:, old:}).
    def initialize(ireps:, registry:, engine:, file: nil, alias_sites: [])
      @ireps = ireps
      @registry = registry
      @engine = engine
      @file = file
      @alias_sites = alias_sites
    end

    # irep label => MethodDef of each method body.
    def body_of
      @body_of ||= registry.each_value.with_object({}) { |defs, h| defs.each { |d| h[d.irep] = d if d.irep } }
    end

    def parent
      @parent ||= ireps.each_value.with_object({}) { |irep, h| irep.reps.each { |c| h[c] = irep.label } }
    end

    # irep label => label of the method body it belongs to (itself, or the nearest one around a block); nil for the
    # root, class bodies and the blocks made directly in them.
    def method_of
      @method_of ||= ireps.each_key.with_object({}) do |label, h|
        up = label
        up = parent[up] until up.nil? || body_of.key?(up)
        h[label] = up
      end
    end

    def each_irep_of_method(label, &block)
      irep = ireps.fetch(label)
      yield irep
      irep.reps.each { |c| each_irep_of_method(c, &block) if ireps.key?(c) }
    end

    # name => [[irep, index, insn]] of every send in the group.
    def sends_by_name
      @sends_by_name ||= begin
        out = Hash.new { |h, k| h[k] = [] }
        ireps.each_value do |irep|
          BytecodeIR.for(irep).each_source do |insn, idx|
            out[insn.sym.to_s] << [irep, idx, insn] if BytecodeIR::Ops::SEND_FAMILY.include?(insn.op)
          end
        end
        out
      end
    end

    # Does a block go to `Class.new`, `Module.new`, `Struct.new` or `Data.define` (the block runs with the new class as self)?
    def class_building_blocks?
      return @class_building if defined?(@class_building)

      @class_building = ireps.each_value.any? do |irep|
        BytecodeIR.for(irep).each_source.any? do |insn, idx|
          next false unless BytecodeIR::Ops::BLOCK_SEND_FAMILY.include?(insn.op) && %w[new define].include?(insn.sym.to_s)

          defs = IrBlockOperands.definitions(irep, idx, insn.reg)
          defs.nil? || defs.any? do |df|
            next true if df.entry?

            w = BytecodeIR.for(irep).source_at(df.index)
            !%i[GETCONST GETMCNST].include?(w.op) || %w[Class Module Struct Data].include?(w.const_name.to_s)
          end
        end
      end
    end

    def sends_named(names)
      names.flat_map { |n| sends_by_name.fetch(n, []) }
    end

    # ivar name (no @) => [[irep, index, source register]] of each SETIV.
    def ivar_stores
      @ivar_stores ||= scan_stores(%i[SETIV]) { |insn| insn.ivar }
    end

    # bare constant name => [[irep, index, source register]] of each SETCONST / SETMCNST.
    def const_stores
      @const_stores ||= scan_stores(%i[SETCONST SETMCNST]) { |insn| insn.const_name.to_s }
    end

    def const_names
      @const_names ||= const_stores.keys.to_set
    end

    # [label of the frame that owns the variable, register] => [[irep, index, source register]] of the SETUPVARs that write it.
    def upvar_writers
      @upvar_writers ||= begin
        out = Hash.new { |h, k| h[k] = [] }
        ireps.each_value do |irep|
          BytecodeIR.for(irep).each_source do |insn, idx|
            next unless insn.op == :SETUPVAR

            index, level = insn.upvar_ref
            target = irep.label
            (level + 1).times { target &&= parent[target] }
            out[[target, index]] << [irep, idx, insn.reg] if target
          end
        end
        out
      end
    end

    # name => [[irep, index, insn]] of the SUPER instructions in methods of that name: the arguments they pass reach the
    # same-named methods above, like a send's.
    def super_sites
      @super_sites ||= begin
        out = Hash.new { |h, k| h[k] = [] }
        ireps.each do |label, irep|
          up = method_of[label]
          d = up && body_of[up] or next
          BytecodeIR.for(irep).each_source { |insn, idx| out[d.name] << [irep, idx, insn] if insn.op == :SUPER }
        end
        out
      end
    end

    def engine_owners
      @engine_owners ||= registry.values.flatten.to_set(&:owner)
    end

    private

    def scan_stores(ops)
      out = Hash.new { |h, k| h[k] = [] }
      ireps.each_value do |irep|
        BytecodeIR.for(irep).each_source do |insn, idx|
          next unless ops.include?(insn.op)

          key = yield(insn)
          out[key] << [irep, idx, insn.reg_operand] if key
        end
      end
      out
    end
  end

  # Where a method's block is given: the instruction indices a run reaches when the method is called with a block, and
  # when it is not. The walk is path-sensitive over the block state and a few register facts, because the tests that
  # decide it are rarely a bare `block_given?`: `return to_enum(:gsub) if args.length == 1 && !block` tests a `!` of the
  # block parameter behind a short circuit, which a flow-insensitive reading cannot split.
  #   - a register written by `block_given?`, copied from the block parameter or negated by `!` is a block test: its value
  #     follows the state;
  #   - a conditional jump on any other register learns that register's truth on each edge, until it is written, so the
  #     second jump of `a && b` on the same register has one feasible edge on the path that already jumped on it.
  # An edge a run cannot take is left out of that run's region; handler edges are in both, with the facts dropped. Past
  # CAP states the walk gives up and both regions are everything (no site is then called guarded).
  class BlockRegions
    CONDITIONAL = %i[JMPIF JMPNOT JMPNIL].freeze
    CAP = 20_000

    def self.of(irep)
      prog = BytecodeIR.for(irep)
      return nil unless prog.resolved? && prog.handlers_resolved?

      new(irep, prog)
    end

    def initialize(irep, prog)
      @irep = irep
      @prog = prog
      @given = explore(:given)
      @absent = explore(:absent)
    end

    # Reached with a block and not without one.
    def given_only?(index)
      !@given.nil? && !@absent.nil? && @given.include?(index) && !@absent.include?(index)
    end

    def absent_only?(index)
      !@given.nil? && !@absent.nil? && @absent.include?(index) && !@given.include?(index)
    end

    private

    # State: [index, {reg => polarity}, {reg => truth}] with polarity :given (true exactly when a block is given) or :absent.
    def explore(block)
      handlers = @prog.raise_targets
      seen = Set.new
      visited = Set.new
      stack = [[0, {}, {}]]
      until stack.empty?
        i, tests, truth = stack.pop
        next unless seen.add?([i, tests.to_a, truth.to_a])
        return nil if seen.size > CAP

        visited << i
        insn = @prog.source_at(i)
        tests, truth = effect(i, insn, tests, truth)
        Array(handlers[i]).each { |t| stack << [t, {}, {}] }
        if CONDITIONAL.include?(insn.op)
          conditional_edges(i, insn, block, tests, truth).each { |e| stack << e }
        else
          Array(@prog.successor_lists[i]).each { |t| stack << [t, tests, truth] }
        end
      end
      visited
    end

    # The facts after +insn+: written registers forget theirs; the block tests are born here.
    def effect(i, insn, tests, truth)
      before = tests
      tests = tests.reject { |r, _| @prog.may_write_at?(i, r) }
      truth = truth.reject { |r, _| @prog.may_write_at?(i, r) }
      case insn.op
      when :SSEND0
        tests = tests.merge(insn.reg => :given) if insn.sym == 'block_given?'
      when :MOVE
        pol = before[insn.regs[1]]
        tests = tests.merge(insn.reg => pol) if pol
      when :SEND0
        pol = before[insn.reg]
        tests = tests.merge(insn.reg => pol == :given ? :absent : :given) if insn.sym == '!' && pol
      when :ENTER
        fields = insn.enter_fields
        if fields.size == 8
          req, opt, rest, post, key, kdict = fields.first(6).map(&:to_i)
          kd = key.positive? || kdict.positive? ? 1 : 0
          tests = tests.merge(req + opt + rest + post + kd + 1 => :given)
        end
      end
      [tests, truth]
    end

    # Which edges of the jump at +i+ a run in +block+ state can take, with the facts each carries.
    def conditional_edges(i, insn, block, tests, truth)
      reg = insn.reg
      target = @prog.address_to_index[insn.branch_target]
      known = if tests[reg] then (block == :given) == (tests[reg] == :given)
              elsif truth.key?(reg) then truth[reg]
              end
      jump_on = insn.op == :JMPIF # truthy value jumps; JMPNOT jumps on a false one
      edges = []
      if insn.op == :JMPNIL
        # nil: a block parameter holding no block; a value known true cannot be nil.
        nil_known = tests[reg] ? block == :absent : (truth[reg] ? false : nil)
        edges << [target, tests, truth] unless nil_known == false
        edges << [i + 1, tests, truth] unless nil_known == true
        return edges
      end
      edges << [target, tests, truth.merge(reg => jump_on)] if known.nil? || known == jump_on
      edges << [i + 1, tests, truth.merge(reg => !jump_on)] if known.nil? || known == !jump_on
      edges
    end
  end

  # A set that holds every name: the parameters of core Ruby are called by natives the model does not read.
  ALL = Class.new { def include?(_name) = true }.new.freeze

  module_function

  # The creation a send or constant read stands for, or nil.
  def creation(insn)
    if BytecodeIR::Ops::SEND_FAMILY.include?(insn.op) && CREATE_SENDS.include?(insn.sym.to_s)
      "calls #{insn.sym}"
    elsif %i[GETCONST GETMCNST].include?(insn.op) && ENUM_CONSTANTS.include?(insn.const_name.to_s)
      "names #{insn.const_name}"
    end
  end

  # How the send at +idx+ gets its block: :none (a plain send, or a nil block), :literal (a block or lambda),
  # :symbol (`&:name`) or :forwarded (a Proc the model cannot tell is non-nil).
  def block_kind(irep, idx, insn)
    return :none unless BytecodeIR::Ops::BLOCK_SEND_FAMILY.include?(insn.op)
    return :literal if IrBlockOperands.literal_block_labels(irep, idx)

    reg = IrBlockOperands.block_register(insn)
    return :forwarded unless reg
    return :symbol if IrBlockOperands.all_writers?(irep, idx, reg) { |w| w.op == :LOADSYM }
    return :none if IrBlockOperands.all_writers?(irep, idx, reg) { |w| w.op == :LOADNIL }

    :forwarded
  end

  # Is the send at +idx+ of +irep+ reachable only where its method's own block is given?
  def given_only?(group, irep, idx)
    label = group.method_of[irep.label]
    return false unless label == irep.label

    regions = (@regions ||= {}.compare_by_identity)[group.ireps.fetch(label)] ||= BlockRegions.of(irep) || :none
    regions != :none && regions.given_only?(idx)
  end

  def absent_only?(group, irep, idx)
    regions = (@regions ||= {}.compare_by_identity)[irep] ||= BlockRegions.of(irep) || :none
    regions != :none && regions.absent_only?(idx)
  end

  def reset_caches
    @regions = nil
  end

  # Creators made by Ruby bodies (and the forwarders of a creator name), by name: key [owner, name].
  def ruby_creators(groups)
    creators = {}
    groups.each do |g|
      g.registry.each_value do |defs|
        defs.each do |d|
          next unless d.irep && g.ireps.key?(d.irep)
          next if INSTANCE_OWNERS.include?(d.owner) && g.ireps.fetch(d.irep).file.to_s.match?(GROUP_FILE)

          g.each_irep_of_method(d.irep) do |sub|
            BytecodeIR.for(sub).each_source do |insn, idx|
              why = creation(insn) or next
              mode = sub.label == d.irep && absent_only?(g, sub, idx) ? :blockless : :always
              add_creator(creators, g, d, mode, why, sub, idx, insn)
            end
          end
        end
      end
    end
    forwarders(groups, creators)
    creators
  end

  def add_creator(creators, group, d, mode, why, irep, idx, insn)
    c = (creators[[d.owner, d.name]] ||= Creator.new(owner: d.owner, name: d.name, mode: mode, noarg: false, why: why,
                                                    explained: Set.new, group: group, site: [irep.file.to_s, insn.lineno]))
    c.mode = :always if mode == :always
    c.explained << [group.object_id, irep.label, idx]
    c
  end

  # A method that gives a creator name a block that may be nil is a creator of its own name, to a fixpoint.
  def forwarders(groups, creators)
    loop do
      grew = alias_creators(groups, creators)
      names = creators.each_value.to_set(&:name) | CREATE_SENDS
      groups.each do |g|
        names.each do |n|
          g.sends_by_name.fetch(n, []).each do |irep, idx, insn|
            next unless block_kind(irep, idx, insn) == :forwarded
            next if given_only?(g, irep, idx)

            up = g.method_of[irep.label]
            d = up && g.body_of[up] or next
            grew = true unless creators.key?([d.owner, d.name])
            add_creator(creators, g, d, :blockless, "forwards its block to #{n}", irep, idx, insn)
          end
        end
      end
      return unless grew
    end
  end

  # `alias new old` copies the body, so the new name makes an Enumerator exactly when the old one does.
  def alias_creators(groups, creators)
    grew = false
    groups.each do |g|
      g.alias_sites.each do |site|
        c = creators[[site[:owner], site[:old]]] or next
        next if creators.key?([site[:owner], site[:new]])

        creators[[site[:owner], site[:new]]] = Creator.new(owner: site[:owner], name: site[:new], mode: c.mode, noarg: c.noarg,
                                                           why: "alias of #{site[:old]}", explained: Set.new, group: g, site: c.site)
        grew = true
      end
    end
    grew
  end

  TO_ENUM_C = /MRB_SYM\(\s*(?:to_enum|enum_for)\s*\)|"(?:to_enum|enum_for)"/
  FUNCTION_C = /^(?:static\s+)?(?:MRB_API\s+)?mrb_value\s+(\w+)\s*\(/
  # `if (mrb_get_args(mrb, "|o&", &obj, &blk) == 0 && mrb_nil_p(blk))`: no argument and no block.
  NOARG_BLOCKLESS_C = /mrb_get_args\(\s*mrb\s*,\s*"\|o&"\s*,\s*&\w+\s*,\s*&\w+\s*\)\s*==\s*0\s*&&\s*mrb_nil_p\(\s*\w+\s*\)\s*\)/

  # A native send of +name+ that always passes a block the native builds itself: `mrb_funcall_with_block(mrb, self,
  # MRB_SYM(each), 0, NULL, mrb_obj_value(blk))` where `blk` is assigned exactly once in the same function, from
  # mrb_proc_new_cfunc_with_env (a fresh cfunc proc, never nil), in the block the send is in, before it, and no goto or
  # switch in that function could jump over the assignment. Such a send is the same as a Ruby send with a literal block:
  # a :blockless creator does not make an Enumerator when a block is given, and an :always one is refused by the caller.
  # Every spelling of +name+ in +text+ (comments and registrations already blanked) must be such a send, or nil is
  # returned and the spelling stays a spelling. Returns [[line, function]] of the sends.
  NATIVE_FUNCTION_START = /^(?:static\s+)?(?:MRB_API\s+)?mrb_value\s+(\w+)\s*\(/

  def native_own_block_sends(text, name)
    total = text.scan(/\b#{Regexp.escape(name)}\b/).size
    return nil if total.zero?

    starts = []
    text.scan(NATIVE_FUNCTION_START) { starts << Regexp.last_match.begin(0) }
    sends = []
    text.scan(/mrb_funcall_with_block\(\s*mrb\s*,\s*\w+\s*,\s*MRB_SYM\(\s*#{Regexp.escape(name)}\s*\)\s*,\s*\w+\s*,\s*\w+\s*,\s*mrb_obj_value\(\s*(\w+)\s*\)\s*\)/) do |(var)|
      at = Regexp.last_match.begin(0)
      fn_start = starts.select { |s| s <= at }.last or return nil
      fn_end = starts.find { |s| s > at } || text.size
      body = text[fn_start...fn_end].gsub(/"(?:\\.|[^"\\\n])*"|'(?:\\.|[^'\\\n])*'/) { |m| m.gsub(/[^\n]/, ' ') }
      rel = at - fn_start
      assigns = []
      body.scan(/(?<![\w.>&])#{Regexp.escape(var)}\s*=(?!=)/) { assigns << Regexp.last_match }
      return nil unless assigns.size == 1 && !body.match?(/&\s*#{Regexp.escape(var)}\b/)

      assign = assigns.first
      return nil unless body[assign.end(0)..].match?(/\A\s*mrb_proc_new_cfunc_with_env\s*\(/)
      return nil if body.match?(/\b(?:goto|switch|case)\b/)

      a = assign.begin(0)
      depth = 0
      min = Float::INFINITY
      depth_at_assign = nil
      body.each_char.with_index do |c, i|
        depth_at_assign = depth if i == a
        break if i == rel

        depth += 1 if c == '{'
        depth -= 1 if c == '}'
        min = depth if i > a && depth < min
      end
      return nil unless depth_at_assign && a < rel && depth == depth_at_assign && min >= depth_at_assign

      line = text[0...at].count("\n") + 1
      fn = text[fn_start..].match(NATIVE_FUNCTION_START)[1]
      sends << [line, fn]
    end
    return nil unless sends.size == total

    sends
  end

  # The natives that call to_enum: [Creator list, problems]. +entries+ are CoreNativeCandidates.entries, +registrations+
  # NativeOwnerMap's [owner, name, function] triples, +strip+ blanks the C comments. A function that is registered
  # nowhere (its name cannot be told) or an Enumerator named in native text is a problem: the proof does not hold.
  def native_creators(paths, entries, registrations, strip:)
    creators = []
    problems = []
    paths.each do |path|
      text = strip.call(File.binread(path).force_encoding(Encoding::UTF_8).scrub)
      problems << "#{path} names Enumerator" if text.match?(/\bEnumerator\b/)
      text.scan(TO_ENUM_C) do
        at = Regexp.last_match.begin(0)
        fn = text[0...at].scan(FUNCTION_C).last&.first
        owners = []
        entries.each { |e| owners << [e[:mt_class], e[:name]] if e[:fn] == fn && e[:name] } if fn
        registrations.each { |owner, name, f| owners << [owner, name] if f == fn && owner.is_a?(String) && name } if fn
        if owners.empty?
          problems << "#{path}: a native calls to_enum from #{fn || 'no function'}, which no table or registration names"
          next
        end
        noarg = text[[at - 200, 0].max...at].match?(NOARG_BLOCKLESS_C)
        owners.uniq.each do |owner, name|
          creators << Creator.new(owner: owner, name: name, mode: :blockless, noarg: noarg, why: "native #{fn} calls to_enum",
                                  explained: Set.new, group: nil)
        end
      end
    end
    [creators, problems]
  end

  # Everything the proof needs from the build, gathered by the caller (StaticDispatchRegistrations).
  #   engine, core    Groups
  #   hierarchy       CoreEnumeratorTypes::Hierarchy
  #   foreign         names some core Ruby or native definition has (a call by that name has an unmodelled result)
  #   external        names something outside the engine's bytecode calls: natives and looked-up Symbol literals
  #   external_owners the engine classes whose name a native spells (it may build one, with arguments the model cannot see)
  #   ivar_external   ivar names (no @) a native may set
  #   symbol_lookups  StaticDispatchSymbolUses.lookups of the engine, or nil
  #   native_creators / native_problems   native_creators's result
  #   native_aliases  [[owner, new, old]] native aliases
  #   native_spelled  name => the native files that spell it, outside table entries and registrations
  #   native_block_sends  name => [[file, [[line, function]]]] of the native sends of it that always pass a block the native
  #                   builds (native_own_block_sends); a spelling in such a file is no spelling of its own
  #   block_returns   method name => [BlockReturns::Entry] of the checked `{ ... } -> T` declarations (sig/bc2cpp)
  Inputs = Struct.new(:engine, :core, :hierarchy, :foreign, :external, :external_owners, :ivar_external, :symbol_lookups,
                      :native_creators, :native_problems, :native_aliases, :native_spelled, :block_returns, :native_block_sends,
                      keyword_init: true)

  # The proof. Returns a Result; +unproven+ names every site and condition it could not account for.
  def prove(inputs)
    reset_caches
    groups = [inputs.engine, *inputs.core]
    creators = ruby_creators_with_natives(groups, inputs)
    unproven = []
    inputs.native_problems.each { |m| unproven << Unproven.new(file: nil, line: nil, where: nil, name: nil, why: m) }
    names = creators.each_value.to_set(&:name) | CREATE_SENDS
    always = creators.each_value.select { |c| c.mode == :always }.to_set(&:name) | CREATE_SENDS
    noarg_only = names.select { |n| (cs = creators.values.select { |c| c.name == n }).any? && cs.all?(&:noarg) }.to_set
    explained = creators.each_value.flat_map { |c| c.explained.to_a }.to_set

    engine_conditions(inputs, creators, unproven)
    symbol_conditions(inputs, names, unproven)
    inputs.native_spelled.each do |name, files|
      next unless names.include?(name)

      unproven << Unproven.new(file: files.first, line: nil, where: nil, name: name,
                               why: "native text spells the creator name #{name} (#{files.size} file#{'s' if files.size > 1})")
    end

    proven = Hash.new(0)
    log = []
    inputs.native_block_sends.each do |name, files|
      next unless names.include?(name) && !inputs.native_spelled.key?(name)

      files.each do |path, sends|
        sends.each do |line, fn|
          if always.include?(name)
            unproven << Unproven.new(file: path, line: line, where: fn, name: name, why: 'a creator that builds one for any call')
          else
            proven[:given] += 1
            log << SiteLog.new(name: name, file: path, line: line, where: fn, verdict: :block, engine: false, classes: nil)
          end
        end
      end
    end
    groups.each do |g|
      typer = nil # built when the first site of the group needs a receiver
      names.each do |n|
        g.sends_by_name.fetch(n, []).each do |irep, idx, insn|
          next if explained.include?([g.object_id, irep.label, idx])
          next if released?(g, irep)

          kind = block_kind(irep, idx, insn)
          reason = site_reason(g, irep, idx, insn, n, kind, always, noarg_only)
          if reason == :safe
            proven[:given] += 1
            log << site_log(g, irep, insn, n, :block)
            next
          end
          typer ||= typer_for(g, inputs)
          verdict = receiver_verdict(typer, inputs.hierarchy, creators, g, irep, idx, insn, n)
          if verdict.is_a?(Set)
            proven[:receiver] += 1
            log << site_log(g, irep, insn, n, :receiver, verdict)
          else
            unproven << site_unproven(g, irep, idx, insn, n, "#{reason}: #{verdict}")
            log << site_log(g, irep, insn, n, :unproven)
          end
        end
      end
    end
    Result.new(holds: unproven.empty?, creators: creators.values, unproven: unproven, proven: proven, sites: log)
  end

  def ruby_creators_with_natives(groups, inputs)
    creators = ruby_creators(groups)
    inputs.native_creators.each { |c| creators[[c.owner, c.name]] = c }
    # A native alias copies the function: the new name makes an Enumerator exactly when the old one does.
    inputs.native_aliases.each do |owner, new_name, old_name|
      c = creators[[owner, old_name]] or next
      creators[[owner, new_name]] ||= Creator.new(owner: owner, name: new_name, mode: c.mode, noarg: c.noarg, why: "alias of #{old_name}",
                                                    explained: Set.new, group: nil)
    end
    creators
  end

  # A method of the group being released is reached only through the paths proven here (an Enumerator, a creator name's
  # callers), so the sites inside it are no new way in.
  def released?(group, irep)
    up = group.method_of[irep.label] or return false
    d = group.body_of[up]
    d && group.ireps.fetch(up).file.to_s.match?(GROUP_FILE)
  end

  # :safe when the site cannot create an Enumerator whatever its receiver is; otherwise the label of what it needs proven.
  def site_reason(group, irep, idx, insn, name, kind, always, noarg_only)
    return 'a creator that builds one for any call' if always.include?(name)

    case kind
    when :literal, :symbol then :safe
    when :forwarded
      given_only?(group, irep, idx) ? :safe : 'a block that may be nil'
    else
      return :safe if noarg_only.include?(name) && !insn.positional_splat? && (insn.positional_slots.positive? || insn.keyword_arguments?)

      'no block'
    end
  end

  # The receiver's class set when none of its classes finds a creator for +name+; else a text saying why not.
  def receiver_verdict(typer, hier, creators, group, irep, idx, insn, name)
    tags = if BytecodeIR::Ops::SELF_SEND_FAMILY.include?(insn.op) then typer.self_of(irep)
           else typer.at(irep, idx, insn.reg)
           end
    if tags == TOP
      why = BytecodeIR::Ops::SELF_SEND_FAMILY.include?(insn.op) ? typer.explain(irep, nil, nil) : typer.explain(irep, idx, insn.reg)
      return "receiver not typed (#{describe_receiver(irep, idx, insn)}: #{why.join(' <- ')})"
    end

    bad = tags.select do |tag|
      owner = hier.lookup(tag, name)
      owner == :unknown || creators.key?([owner, name])
    end
    bad.empty? ? tags : "receiver may be #{bad.sort.first(4).join(', ')}#{' ...' if bad.size > 4}, which finds a creator of #{name}"
  end

  def describe_receiver(irep, idx, insn)
    return 'implicit self' if BytecodeIR::Ops::SELF_SEND_FAMILY.include?(insn.op)

    defs = IrBlockOperands.definitions(irep, idx, insn.reg)
    return 'untraceable' unless defs

    prog = BytecodeIR.for(irep)
    defs.map { |df| df.entry? ? 'entry' : "#{prog.source_at(df.index).op}#{":#{prog.source_at(df.index).sym}" if prog.source_at(df.index).sym}" }.uniq.join('|')
  end

  def site_log(group, irep, insn, name, verdict, classes = nil)
    up = group.method_of[irep.label]
    d = up && group.body_of[up]
    SiteLog.new(name: name, file: irep.file.to_s, line: insn.lineno, where: d ? "#{d.owner}##{d.name}" : 'class body', verdict: verdict,
                engine: group.engine, classes: classes)
  end

  def site_unproven(group, irep, idx, insn, name, why)
    up = group.method_of[irep.label]
    d = up && group.body_of[up]
    Unproven.new(file: irep.file.to_s, line: insn.lineno, where: d ? "#{d.owner}##{d.name}" : 'class body', name: name, why: why)
  end

  def typer_for(group, inputs)
    if group.engine
      CoreEnumeratorTypes::Typer.new(group: group, hierarchy: inputs.hierarchy, external: inputs.external,
                                     external_owners: inputs.external_owners, ivar_external: inputs.ivar_external,
                                     foreign: inputs.foreign, block_returns: inputs.block_returns)
    else
      CoreEnumeratorTypes::Typer.new(group: group, hierarchy: inputs.hierarchy, external: ALL, external_owners: ALL,
                                     ivar_external: ALL, foreign: ALL)
    end
  end

  # Conditions on the engine's own Ruby: it makes no Enumerator itself, defines no method_missing, subclasses no Enumerator.
  def engine_conditions(inputs, creators, unproven)
    engine = inputs.engine
    creators.each_value do |c|
      # An engine method that only passes its block on makes an Enumerator when called without one: it is a creator (its
      # own call sites are checked), not a way in by itself.
      next unless c.group&.engine && !c.why.start_with?('forwards', 'alias')

      unproven << Unproven.new(file: c.site&.first, line: c.site&.last, where: "#{c.owner}##{c.name}", name: c.name,
                               why: "an engine method #{c.why}")
    end
    (inputs.core + [engine]).each do |g|
      g.registry.fetch('method_missing', []).each do |d|
        unproven << Unproven.new(file: nil, line: nil, where: d.owner, name: 'method_missing', why: 'a method_missing can route any call')
      end
      g.ireps.each_value do |irep|
        next if g.method_of[irep.label]
        # The released file's own class bodies define its methods and constants (`def Enumerator.produce` names the class).
        next if irep.file.to_s.match?(GROUP_FILE)

        BytecodeIR.for(irep).each_source do |insn, _|
          why = creation(insn) or next
          unproven << Unproven.new(file: irep.file.to_s, line: insn.lineno, where: 'load time', name: insn.sym.to_s, why: "a class body or the top level #{why}")
        end
      end
    end
    inputs.hierarchy.classes.each do |k|
      next unless inputs.engine.engine_owners.include?(k)

      chain = inputs.hierarchy.ancestors(k)
      unproven << Unproven.new(file: nil, line: nil, where: k, name: nil, why: "#{k} has no known ancestors") if chain.nil?
      unproven << Unproven.new(file: nil, line: nil, where: k, name: nil, why: "#{k} inherits Enumerator") if chain&.include?('Enumerator')
    end
  end

  # A Symbol literal that reaches a lookup (`map(&:index)`, `send(:select)`) calls its name on a receiver nothing here types.
  def symbol_conditions(inputs, names, unproven)
    lookups = inputs.symbol_lookups
    if lookups.nil?
      unproven << Unproven.new(file: nil, line: nil, where: nil, name: nil, why: 'some lookup takes a name that is no Symbol literal')
      return
    end
    inputs.engine.ireps.each_value do |irep|
      BytecodeIR.for(irep).each_source do |insn, _|
        next unless insn.op == :LOADSYM && lookups.include?(insn.sym.to_s) && names.include?(insn.sym.to_s)

        unproven << Unproven.new(file: irep.file.to_s, line: insn.lineno, where: nil, name: insn.sym.to_s,
                                 why: "Symbol :#{insn.sym} names a creator and reaches a lookup")
      end
    end
  end

  # Native text that spells a creator name without calling it: the compiler's `for` loop emits a send of `each` with a
  # block (codegen.c gen_for), into a program compiled at run time that the sealed closed host never loads.
  NOT_CALLS = [
    /sym_idx\(\s*s\s*,\s*MRB_SYM\(each\)\s*\)/,
    # The creating natives' own call (native_creators reads them): Array#index and #rindex answer `to_enum(:index)`.
    /mrb_funcall_id\(\s*mrb\s*,\s*self\s*,\s*MRB_SYM\(to_enum\)\s*,\s*1\s*,\s*mrb_symbol_value\(\s*MRB_SYM\(\w+\)\s*\)\s*\)/
  ].freeze

  # The natives' include/prepend calls: [[class, module]] and the ones whose target the owner map could not name. The three
  # unnamed ones of class.c are Module#include, #prepend and #extend themselves (they act on the receiver).
  GENERIC_MIXIN_FILE = %r{/3rd/mruby/src/class\.c\z}

  def native_mixins(paths)
    mixins = []
    problems = []
    paths.each do |path|
      text = File.binread(path)
      next unless text.include?('include_module') || text.include?('prepend_module')

      NativeOwnerMap.build([path]).mixins.each do |target, mod, _core|
        if target.is_a?(String) && mod.is_a?(String) then mixins << [target, mod]
        elsif !path.match?(GENERIC_MIXIN_FILE)
          problems << "#{path}: a native include/prepend whose class or module is not a name the owner map resolves"
        end
      end
    end
    [mixins.uniq, problems]
  end

  NATIVE_SUPERS = { /\A(?:\w+->)?object_class\z/ => 'Object', /\AE_STANDARD_ERROR\z|\A(?:\w+->)?eStandardError_class\z/ => 'StandardError' }.freeze

  # Classes the natives create: leaf name => superclass name (nil when the superclass expression is none of NATIVE_SUPERS),
  # from the `mrb_define_class*` calls in the C text. The leaf is a string literal or MRB_SYM(Name), the superclass the last
  # argument.
  def native_class_supers(paths, strip:)
    out = {}
    paths.each do |path|
      text = strip.call(File.binread(path).force_encoding(Encoding::UTF_8).scrub)
      text.scan(/\bmrb_define_class\w*\s*\(/) do
        start = Regexp.last_match.end(0)
        depth = 1
        i = start
        while i < text.size && depth.positive?
          depth += 1 if text[i] == '('
          depth -= 1 if text[i] == ')'
          i += 1
        end
        args = text[start...(i - 1)].split(',').map(&:strip)
        leaf = args.filter_map { |a| a[/\A"(\w+)"\z/, 1] || a[/\AMRB_SYM\((\w+)\)\z/, 1] }.first or next
        sup = NATIVE_SUPERS.find { |re, _| args.last.match?(re) }&.last
        out[leaf] = sup if sup || !out.key?(leaf)
      end
    end
    out
  end

  # The Inputs of the build. +engine+ and each of +core+ are { ireps:, tuple: } with +tuple+ build_registry's result (core
  # also :path); +entries+ and +map+ are CoreNativeCandidates.entries and NativeOwnerMap of the native sources. The three
  # lambdas are StaticDispatchRegistrations' own: +strip+ blanks C comments, +tokens+ is native_name_tokens, +entry_name+
  # the regexp that blanks a table entry's defining name. +implicit_names+ are the methods the VM calls itself (to_s, ==, each
  # of a `for`, an operator opcode's name), whose parameters no send in the bytecode accounts for. +block_returns+ is Inputs'.
  def inputs(engine:, core:, native:, entries:, map:, symbol_lookups:, strip:, tokens:, entry_name:, implicit_names:, block_returns: {})
    tuples = [engine.fetch(:tuple)] + core.map { |c| c.fetch(:tuple) }
    engine_group = Group.new(ireps: engine.fetch(:ireps), registry: engine.fetch(:tuple)[0], engine: true,
                             alias_sites: engine.fetch(:tuple)[12])
    core_groups = core.map do |c|
      Group.new(ireps: c.fetch(:ireps), registry: c.fetch(:tuple)[0], engine: false, file: c[:path], alias_sites: c.fetch(:tuple)[12])
    end
    definers = Hash.new { |h, k| h[k] = Set.new }
    foreign = Set.new
    ([engine_group] + core_groups).each do |g|
      g.registry.each do |name, defs|
        defs.each do |d|
          definers[d.owner] << name unless d.owner == '<native>'
          foreign << name if !g.engine || d.owner == '<native>'
        end
      end
    end
    entries.each do |e|
      next unless e[:name]

      # A table installed into more than one class is no single class's: the name may be on any.
      e[:installed] ? definers[e[:installed]] << e[:name] : foreign << e[:name]
      foreign << e[:name]
    end
    map.registrations.each { |owner, name, _fn| (definers[owner] << name) if owner.is_a?(String) && name; foreign << name if name }
    map.aliases.each { |owner, new_name, _old| definers[owner] << new_name; foreign << new_name }
    wild = entries.reject { |e| e[:installed] }.filter_map { |e| e[:name] }
    wild.each { |name| definers['*wild*'] << name }

    superclass = {}
    included = {}
    prepended = {}
    unknown = Set.new
    modules = Set.new
    tuples.each do |t|
      superclass.merge!(t[1])
      t[3].each { |k, v| (included[k] ||= []).concat(v) }
      t[4].each { |k, v| (prepended[k] ||= []).concat(v) }
      unknown.merge(t[5])
      modules.merge(t[11])
    end
    mixins, mixin_problems = native_mixins(native)
    mixins.each { |target, mod| (included[target] ||= []) << mod unless included[target]&.include?(mod) }
    supers = native_class_supers(native, strip: strip)
    native_classes = {}
    map.registrations.each do |owner, _name, _fn|
      next unless owner.is_a?(String)

      key = owner.delete_suffix('.singleton')
      leaf = key.split('::').last
      next unless supers.key?(leaf) && !CoreEnumeratorTypes::Hierarchy::CORE.key?(key) && !superclass.key?(key) && !modules.include?(key)

      native_classes[key] = supers[leaf]
    end
    hierarchy = CoreEnumeratorTypes::Hierarchy.new(superclass_of: superclass, included: included, prepended: prepended,
                                                   unknown: unknown, modules: modules, definers: definers,
                                                   computed: map.computed.to_set, wild: wild.to_set, native_classes: native_classes)

    spelled_in = Hash.new { |h, k| h[k] = [] }
    block_sent = Hash.new { |h, k| h[k] = [] }
    native.each do |path|
      text = File.read(path, encoding: 'BINARY').gsub(entry_name) { "#{Regexp.last_match(1)}#{' ' * Regexp.last_match(2).size}" }
      text = NOT_CALLS.inject(text) { |t, re| t.gsub(re) { |m| ' ' * m.size } }
      found = Set.new
      tokens.call(text, found)
      found.each do |name|
        sends = native_own_block_sends(strip.call(text), name)
        if sends then block_sent[name] << [path, sends] else spelled_in[name] << path end
      end
    end
    spelled = spelled_in.keys.to_set
    ivar_strings = Set.new
    spelled.each { |t| ivar_strings << t.delete_prefix('@') if t.match?(/\A@\w+\z/) }
    engine_names = engine_group.registry.keys.to_set
    external = (spelled & engine_names) | (symbol_lookups || Set.new)
    external |= implicit_names
    # `initialize` and `new` are tracked per class (arg_init_value).
    external -= %w[initialize new]
    owners = engine_group.engine_owners.map { |o| o.delete_suffix('.singleton') }.uniq
    external_owners = owners.select { |o| spelled.include?(o) || spelled.include?(o.split('::').last) }.to_set
    creators, problems = native_creators(native, entries, map.registrations, strip: strip)
    problems += mixin_problems
    Inputs.new(engine: engine_group, core: core_groups, hierarchy: hierarchy, foreign: foreign, external: external,
               external_owners: external_owners, ivar_external: ivar_strings, symbol_lookups: symbol_lookups,
               native_creators: creators, native_problems: problems, native_aliases: map.aliases.map { |o, n, old| [o, n, old] },
               native_spelled: spelled_in, block_returns: block_returns, native_block_sends: block_sent)
  end
end
