# frozen_string_literal: true

require 'set'
require_relative 'irep'
require_relative 'bytecode_ir'
require_relative 'core_defs'

# ESCAPE_ANALYSIS (ADR 0316): one value-flow module for "does the value this instruction creates leave
# the frame that made it?". Every claim is sound by construction. The default answer is "escapes", and a
# value is non-escaping only when every instruction that can see it is on the audited lists below: a
# register copy, a branch test, a call whose every possible callee provably keeps neither that argument
# nor its receiver, a closure that itself does not escape. An op, a callee, a CFG or a state the model
# does not name is an escape.
#
# A tracked value is a SET of registers that may hold it (a forward may-alias flow over the irep's CFG,
# catch-handler edges included). Per creation site it answers:
#   1. only registers of the creating frame        -> no reasons; `uses` lists the calls made on it
#   2. passed as receiver / argument / block       -> every definition the name can reach must have a
#      summary saying that position is not kept (bytecode: this analysis run on the callee; native: the
#      audited tables below)
#   3. returned, stored (ivar, global, constant, upvar, array, hash, range), raised, read by a closure
#      that escapes, handed to an unknown or by-name send -> escapes
#
# Callee positions: [:self], [:arg, k], [:block]. A summary says whether the callee "captures" (keeps,
# returns or loses track of) that position. Callees are found by NAME over every definition in the
# world, so the answer holds for any receiver class. Mutual recursion is assumed non-capturing only
# while it is being decided (co-inductive); a non-capturing result that rests on such an assumption is
# not memoised unless the assumed frame itself finishes non-capturing.
module EscapeAnalysis
  # BC2CPP_ESCAPE_ANALYSIS=0 returns every consumer to the earlier output.
  def self.enabled?
    ENV['BC2CPP_ESCAPE_ANALYSIS'] != '0'
  end

  class << self
    # The World of the program being compiled (set by the driver once the registry and the native names
    # exist); nil when the analysis is off. Each CodeGen builds its own Analyzer over it so that memoised
    # answers never outlive the class facts they used.
    attr_reader :world

    def install(world)
      @world = world
    end
  end

  # kind :call = a Proc invocation with the value as receiver; :pass_arg / :pass_block = handed to `name`.
  Use = Struct.new(:index, :kind, :name, :reg, keyword_init: true)
  # reasons: [[symbol, instruction address]]; empty = the value does not escape. tracked: every register
  # of the analysed frame that may hold it.
  Verdict = Struct.new(:reasons, :uses, :tracked, keyword_init: true) do
    def escapes?
      !reasons.empty?
    end

    def reason
      reasons.first&.first
    end
  end

  # -- audited facts about native (C) methods, by name ------------------------------------------------
  # A name here is a claim about EVERY native definition of that name in the world;
  # scripts/bc2cpp_escape_analysis_check.rb compares each name's registrations with NATIVE_MANIFEST so a
  # new definition forces a new audit. mruby's iterators (each, map, times, inject, ...) are Ruby in
  # mrblib: they need no entry, their summaries are computed from bytecode.

  # Natives that take a block and either call it synchronously or never read it; none keeps it.
  NATIVE_BLOCK_NO_CAPTURE = Set['section', 'select', 'count', 'index'].freeze
  NATIVE_MANIFEST = {
    'section' => %w[mruby-rgss/src/profiler.cxx],
    'select' => %w[3rd/mruby/mrbgems/mruby-io/src/io.c],
    'count' => %w[3rd/mruby/mrbgems/mruby-string-ext/src/string.c],
    'index' => %w[3rd/mruby/src/array.c 3rd/mruby/src/string.c]
  }.freeze

  # Natives that do not keep their RECEIVER. :fresh = the result is a new value or an element, never the
  # receiver; :self = the result may be the receiver itself (so it joins the tracked set).
  NATIVE_RECEIVER_OK = {
    'call' => :fresh, '[]' => :fresh, '===' => :fresh, 'arity' => :fresh, 'lambda?' => :fresh,
    'nil?' => :fresh, '!' => :fresh, '==' => :fresh, 'equal?' => :fresh, 'size' => :fresh,
    'length' => :fresh, 'empty?' => :fresh, 'first' => :fresh, 'last' => :fresh, 'include?' => :fresh,
    'key?' => :fresh, 'has_key?' => :fresh, 'pop' => :fresh, 'shift' => :fresh, '[]=' => :fresh,
    '<<' => :self, 'push' => :self, 'unshift' => :self
  }.freeze
  # Receiver names that invoke a Proc (a `uses` entry the consumers turn into a direct call).
  PROC_CALLS = Set['call', '[]', '==='].freeze

  # -- the op model ---------------------------------------------------------------------------------
  # Write only their leading register and read no register that can hold a tracked value.
  KILLS_LEAD = Set[
    'LOADL', 'LOADI8', 'LOADINEG', 'LOADI__1', 'LOADI_0', 'LOADI_1', 'LOADI_2', 'LOADI_3', 'LOADI_4',
    'LOADI_5', 'LOADI_6', 'LOADI_7', 'LOADI16', 'LOADI32', 'LOADSYM', 'LOADNIL', 'LOADTRUE', 'LOADFALSE',
    'GETGV', 'GETSV', 'GETIV', 'GETCV', 'GETCONST', 'GETUPVAR', 'GETMCNST', 'OCLASS', 'TCLASS', 'EXCEPT',
    'KARG', 'KEY_P', 'STRING', 'SYMBOL', 'INTERN', 'METHOD', 'AREF'
  ].freeze
  PASSES = Set[
    'NOP', 'EXT1', 'EXT2', 'EXT3', 'DEBUG', 'JMP', 'JMPUW', 'KEYEND', 'ALIAS', 'UNDEF', 'ENTER', 'JMPIF',
    'JMPNOT', 'JMPNIL', 'MATCHERR', 'RETNIL', 'RETTRUE', 'RETFALSE', 'STOP', 'ERR'
  ].freeze
  # Read their leading register and keep it somewhere that outlives the instruction.
  STORES_LEAD = {
    'SETGV' => :stored_global, 'SETSV' => :stored_global, 'SETIV' => :stored_ivar, 'SETCV' => :stored_classvar,
    'SETCONST' => :stored_constant, 'SETMCNST' => :stored_constant, 'SETUPVAR' => :stored_upvar,
    'RAISEIF' => :raised, 'RETURN' => :returned, 'RETURN_BLK' => :returned, 'BREAK' => :returned,
    'ASET' => :stored_container
  }.freeze
  # Write the leading register from a window of registers starting there; a tracked value in the window
  # would be kept by the result (array, hash, range) or by the class machinery.
  WINDOW_OPS = %w[RANGE_INC RANGE_EXC CLASS MODULE SCLASS EXEC DEF TDEF SDEF].freeze
  BINARY_NAMES = {
    'ADD' => '+', 'SUB' => '-', 'MUL' => '*', 'DIV' => '/', 'EQ' => '==', 'LT' => '<', 'LE' => '<=',
    'GT' => '>', 'GE' => '>='
  }.freeze
  SEND_OPS = Set['SEND', 'SEND0', 'SENDB', 'SSEND', 'SSEND0', 'SSENDB'].freeze
  CLOSURE_OPS = Set['BLOCK', 'LAMBDA'].freeze

  # The callee side: ireps, every definition of a name and the native method names. +defs+ is
  # name => [MethodDef] as build_registry leaves it BEFORE core filtering (a core method the build keeps
  # interpreted is still a callee). +native_names+ nil means the native sources were not scanned, so every
  # name may have a native definition. +aliases+: new name => [old names] from the ALIAS op. +invisible+
  # says whether some definer outside the ireps (an outside Ruby source, a computed installer) can make
  # that name; such a name has no enumerable definitions.
  class World
    DEF_OPS = Set['TDEF', 'SDEF', 'DEF'].freeze
    SENDS = Set['SEND', 'SEND0', 'SENDB', 'SSEND', 'SSEND0', 'SSENDB'].freeze
    # Sends that make a method from a name computed at run time. A literal name is modelled below; any
    # other makes every callee set unknowable (`dynamic`).
    NAMING_SENDS = %w[define_method define_singleton_method alias_method].freeze
    # `obj.send(:define_method, :x) { }` names the installer in its first argument. A first argument that is
    # not a literal is the closed world's own residual (ClosedWorld reads direct installer sends only).
    FORWARDING_SENDS = %w[send __send__ public_send].freeze

    # mruby's own class tree for the classes the registry never declares (the natives and mrblib reopen
    # them without a superclass), and the modules their C code includes. Checked against a real mruby by
    # scripts/bc2cpp_escape_analysis_check.rb.
    BUILTIN_SUPERCLASS = {
      'Integer' => 'Numeric', 'Float' => 'Numeric', 'Numeric' => 'Object', 'Array' => 'Object', 'Hash' => 'Object',
      'String' => 'Object', 'Symbol' => 'Object', 'Range' => 'Object', 'Proc' => 'Object', 'NilClass' => 'Object',
      'TrueClass' => 'Object', 'FalseClass' => 'Object', 'Struct' => 'Object', 'Object' => 'BasicObject',
      'Exception' => 'Object', 'StandardError' => 'Exception', 'RuntimeError' => 'StandardError',
      'ArgumentError' => 'StandardError', 'TypeError' => 'StandardError', 'IndexError' => 'StandardError',
      'RangeError' => 'StandardError', 'NameError' => 'StandardError', 'NoMethodError' => 'NameError',
      'KeyError' => 'IndexError', 'IOError' => 'StandardError', 'EOFError' => 'IOError', 'ScriptError' => 'Exception',
      'NotImplementedError' => 'ScriptError', 'FiberError' => 'StandardError', 'StopIteration' => 'IndexError',
      'ZeroDivisionError' => 'StandardError', 'LocalJumpError' => 'StandardError',
      'FloatDomainError' => 'RangeError'
    }.freeze
    BUILTIN_INCLUDES = {
      'Object' => %w[Kernel], 'Numeric' => %w[Comparable], 'String' => %w[Comparable],
      'Symbol' => %w[Comparable], 'Array' => %w[Enumerable], 'Hash' => %w[Enumerable],
      'Range' => %w[Enumerable], 'Struct' => %w[Enumerable]
    }.freeze

    # Sends and constants that read a frame's locals or the whole heap by name, so no value is confined.
    REFLECTIVE_SENDS = %w[binding eval local_variable_get local_variable_set local_variables
                          local_variable_defined?].freeze
    REFLECTIVE_CONSTS = %w[ObjectSpace].freeze

    attr_reader :ireps, :aliases, :dynamic_sites, :reflective_sites

    def initialize(ireps:, defs:, native_names: nil, aliases: {}, superclass_of: {}, included: {}, prepended: {},
                   unknown_mixins: Set.new, modules: Set.new, struct_classes: Set.new, invisible: nil)
      @ireps = ireps
      @invisible = invisible
      @native_names = native_names
      @superclass_of = superclass_of
      @included = included
      @prepended = prepended
      @unknown_mixins = unknown_mixins
      @modules = modules
      @struct_classes = struct_classes.to_set
      @mro = {}
      @aliases = Hash.new { |h, k| h[k] = [] }
      aliases.each { |new_name, olds| @aliases[new_name].concat(olds) }
      @dynamic_sites = []
      @reflective_sites = []
      @defs = Hash.new { |h, k| h[k] = [] }
      defs.each { |name, list| @defs[name].concat(list) }
      # A class mruby's own Ruby opens (IO, File, Enumerator ...) may include modules from C, which the
      # registry never sees: only the builtin tables place such a class.
      @core_classes = @defs.values.flatten.select(&:core).to_set(&:owner)
      scan_definitions
    end

    # Definitions a call of +name+ can reach, or nil when the world cannot enumerate them.
    def defs_named(name, seen = Set.new)
      return nil unless @dynamic_sites.empty?
      return nil if @invisible&.call(name)
      return [] unless seen.add?(name)

      list = @defs.fetch(name, []).dup
      Array(@aliases.fetch(name, [])).each do |old|
        more = defs_named(old, seen) or return nil

        list.concat(more)
      end
      list
    end

    def native_name?(name)
      @native_names.nil? || @native_names.include?(name)
    end

    # Can the hierarchy tables place the class +name+?
    def class_known?(name)
      !mro(name).nil?
    end

    # Definitions a call of +name+ can reach on a receiver of class +klass+ (exactly that class when
    # +exact+, else it or any subclass; a module name means any includer). Every class or module the
    # hierarchy tables cannot place leaves the answer at all definitions of the name.
    def defs_for(name, klasses, exact)
      list = defs_named(name)
      return list if list.nil? || klasses.nil? || klasses.empty?

      # A class whose ancestry the tables cannot place may sit under any class, so no override is excluded.
      return list if !exact && known_classes.any? { |c| mro(c).nil? }

      chains = []
      klasses.each do |klass|
        if exact
          chains << (mro(klass) or return list)
        else
          ([klass] + descendants(klass)).each do |c|
            next if c == klass && module_name?(klass)

            chains << (mro(c) or return list)
          end
        end
      end
      return list if chains.empty?

      chains.flat_map { |chain| first_owner_defs(list, chain) }.uniq | list.select { |d| d.owner.start_with?('<') }
    end

    private

    def module_name?(name)
      @modules.include?(name) || BUILTIN_INCLUDES.values.flatten.include?(name)
    end

    # Method resolution order of +klass+ (own prepended modules, the class, its included modules, then
    # the superclass chain), or nil when a link is unknown.
    def mro(klass)
      return @mro[klass] if @mro.key?(klass)

      @mro[klass] = begin
        chain = []
        k = klass
        until k.nil?
          return @mro[klass] = nil if chain.include?(k) || @unknown_mixins.include?(k)
          return @mro[klass] = nil if @core_classes.include?(k) && !BUILTIN_SUPERCLASS.key?(k) && !module_name?(k)

          Array(@prepended[k]).reverse_each { |m| add_module(chain, m) }
          chain << k
          (Array(@included[k]) + Array(BUILTIN_INCLUDES[k])).reverse_each { |m| add_module(chain, m) }
          k = superclass(k)
          return @mro[klass] = nil if k == :unknown
        end
        chain
      end
    end

    def add_module(chain, mod)
      return if chain.include?(mod)

      chain << mod
      Array(@included[mod]).reverse_each { |m| add_module(chain, m) }
    end

    # Superclass name, nil at the root, :unknown for a class neither declared nor builtin.
    def superclass(klass)
      return nil if klass == 'BasicObject'
      return 'BasicObject' if klass == 'Object'

      # A reopened builtin keeps its real superclass (`class Integer` without one is not Object's child),
      # and a class made by `Name = Struct.new` stays a Struct when reopened.
      return BUILTIN_SUPERCLASS[klass] if BUILTIN_SUPERCLASS.key?(klass)
      return 'Struct' if @struct_classes.include?(klass)

      declared = @superclass_of[klass]
      return 'Object' if declared == :none

      declared.is_a?(String) ? resolve_superclass(declared) : :unknown
    end

    # The registry spells a superclass relative to the class body (`class Timeout < StandardError` inside
    # RGSS is "RGSS::StandardError"). A name no declared class owns is the builtin of that simple name.
    def resolve_superclass(name)
      return name if @superclass_of.key?(name) || @modules.include?(name) || BUILTIN_SUPERCLASS.key?(name)

      simple = name.split('::').last
      BUILTIN_SUPERCLASS.key?(simple) ? simple : :unknown
    end

    def known_classes
      @known_classes ||= (@superclass_of.keys + BUILTIN_SUPERCLASS.keys + ['BasicObject']).uniq
    end

    # Classes that inherit from, or (for a module) include, +klass+.
    def descendants(klass)
      known_classes.select { |c| c != klass && (chain = mro(c)) && chain.include?(klass) }
    end

    # For each chain, the definitions of the first owner that defines the name.
    def first_owner_defs(list, chain)
      chain.each do |owner|
        found = list.select { |d| d.owner == owner }
        return found unless found.empty?
      end
      []
    end

    # A `def` the registry walk did not see still dispatches (every TDEF/SDEF names a callee); a literal
    # define_method/alias_method/attr_* is a definition, a computed one makes the world dynamic.
    def scan_definitions
      known = Hash.new { |h, k| h[k] = Set.new }
      @defs.each { |name, list| list.each { |d| known[name] << d.irep if d.irep } }
      closure_bodies = Set.new
      @ireps.each_value do |irep|
        irep.instructions.each do |insn|
          closure_bodies << irep.reps[insn.block_index.to_i] if CLOSURE_OPS.include?(insn.op)
        end
      end
      @ireps.each_value do |irep|
        irep.instructions.each_with_index do |insn, idx|
          if (SENDS.include?(insn.op) && REFLECTIVE_SENDS.include?(insn.sym)) ||
             (%w[GETCONST GETMCNST].include?(insn.op) && REFLECTIVE_CONSTS.include?(insn.const_name))
            @reflective_sites << [irep.label, idx]
          end
          if DEF_OPS.include?(insn.op) && insn.sym
            scan_definition_op(irep, idx, insn, known, closure_bodies.include?(irep.label))
          elsif SENDS.include?(insn.op) && NAMING_SENDS.include?(insn.sym)
            scan_naming_send(irep, idx, insn, insn.sym, 1)
          elsif SENDS.include?(insn.op) && FORWARDING_SENDS.include?(insn.sym)
            named = insn.plain_fixed_argc? && insn.argc.to_i.positive? && literal_symbol(irep, idx, (insn.reg.to_i + 1).to_s)
            scan_naming_send(irep, idx, insn, named, 2) if named && NAMING_SENDS.include?(named)
          end
        end
      end
    end

    # The registry owns a def by its lexical class; one inside a block (Class.new { def ... }) lands on
    # a class chosen at run time, so it also counts under an owner that every class can reach.
    def scan_definition_op(irep, idx, insn, known, in_closure)
      label = CoreDefs.def_body_label(irep, insn)
      return @dynamic_sites << [irep.label, idx, insn.op] if label.nil?
      return unless in_closure || !known[insn.sym].include?(label)

      owner = in_closure ? '<scoped>' : '<def-op>'
      @defs[insn.sym] << MethodDef.new(name: insn.sym, owner: owner, irep: label, visibility: :public)
    end

    # +first+: argument slot of the first name (1, or 2 behind the method name of a forwarding send).
    def scan_naming_send(irep, idx, insn, sym, first)
      count = insn.plain_fixed_argc? ? insn.argc.to_i : -1
      last = count - first + 1
      names = last.positive? ? (first..count).map { |k| literal_symbol(irep, idx, (insn.reg.to_i + k).to_s) } : []
      literal = !names.empty? && names.none?(&:nil?)
      case sym
      when 'alias_method'
        return @dynamic_sites << [irep.label, idx, sym] unless literal && names.size == 2

        @aliases[names[0]] << names[1]
      when 'define_method', 'define_singleton_method'
        return @dynamic_sites << [irep.label, idx, sym] unless literal

        @defs[names[0]] << MethodDef.new(name: names[0], owner: '<define_method>', irep: nil, visibility: :public,
                                         installer: :define_method)
      end
    end

    # The Symbol every definition reaching +reg+ loads, or nil.
    def literal_symbol(irep, idx, reg)
      defs = BytecodeIR.reaching_definitions(irep, idx, reg)
      return nil if defs.nil? || defs.empty? || defs.any?(&:entry?)

      loads = defs.map { |d| irep.instructions[d.index] }
      loads.first.sym if loads.all? { |l| l.op == 'LOADSYM' } && loads.map(&:sym).uniq.size == 1
    end
  end

  class Analyzer
    MAX_DEPTH = 24
    STEP_CAP = 20_000
    NONE = Float::INFINITY

    # Callbacks that sharpen callee sets from the compiler's class flow (nil = by name only):
    #   receiver_classes.call(irep, index, reg) -> every class that register may hold at that instruction
    #   self_class.call(irep) -> the class or module whose method the irep belongs to
    attr_reader :world
    attr_accessor :receiver_classes, :self_class

    def initialize(world)
      @world = world
      @memo = {}
      @stack = []
      @floor = NONE
      @refs = {}
    end

    CREATED_CLASS = { 'LAMBDA' => 'Proc', 'BLOCK' => 'Proc', 'ARRAY' => 'Array', 'HASH' => 'Hash',
                      'STRING' => 'String', 'RANGE_INC' => 'Range', 'RANGE_EXC' => 'Range' }.freeze

    # The value written to the leading register of irep.instructions[index]: a LAMBDA, BLOCK, ARRAY, HASH,
    # STRING or the result of a `new` send (then +value_class+ is the constructed class when known).
    def creation(irep, index, value_class: nil)
      insn = irep.instructions[index]
      return failed(:no_destination) unless insn.reg
      return failed(:reflection) unless @world.reflective_sites.empty?

      flow(irep, { index => { insn.reg => true } }, created_at: index, value_class: CREATED_CLASS[insn.op] || value_class)
    end

    # true when +mdef+ may keep its +position+ ([:self], [:arg, k] or [:block]) or it cannot be shown.
    def captures?(mdef, position)
      return true unless @world.reflective_sites.empty?

      cyclic([:summary, mdef.object_id, position]) { compute_summary(mdef, position) }
    end

    # Does the closure BLOCK/LAMBDA at irep[index] leave its frame?
    def closure_escapes?(irep, index)
      cyclic([:closure, irep.label, index]) { creation(irep, index).escapes? }
    end

    private

    # Memoised boolean "bad" (captures / escapes). A key found on the stack is assumed good (false); a
    # result computed under such an assumption is kept only if it is bad (monotone: the assumption can
    # only remove reasons) or the assumed frame is this one.
    def cyclic(key)
      return @memo[key] if @memo.key?(key)

      if (at = @stack.index(key))
        @floor = [@floor, at].min
        return false
      end
      return true if @stack.size >= MAX_DEPTH

      saved = @floor
      @floor = NONE
      @stack.push(key)
      result = yield
      @stack.pop
      assumed = @floor
      @memo[key] = result if result || assumed >= @stack.size
      @floor = [saved, assumed < @stack.size ? assumed : NONE].min
      result
    end

    # -- summaries --------------------------------------------------------------------------------
    def compute_summary(mdef, position)
      return position[0] == :arg && mdef.name.end_with?('=') if mdef.irep.nil? && mdef.kind == :ivar_accessor

      irep = body_irep(mdef) or return true
      case position[0]
      when :self then flow(irep, { 0 => { '0' => true } }, self_tracked: true).escapes?
      when :arg then arg_captured?(irep, position[1])
      when :block then block_captured?(irep)
      else true
      end
    end

    def body_irep(mdef)
      return nil if mdef.installer

      label = mdef.irep || (mdef.kind == :module_function ? mdef.copy_irep : nil)
      label && @world.ireps[label]
    end

    # Leading mandatory arguments sit in R1.. on entry; other layouts are not modelled.
    def arg_captured?(irep, k)
      enter = irep.enter
      return true unless enter && k < enter.enter_fields[0].to_i

      flow(irep, { 0 => { (1 + k).to_s => true } }).escapes?
    end

    # The block of a method is born at BLKPUSH (level 0) and, with a block parameter, in its local.
    def block_captured?(irep)
      fields = irep.enter ? irep.enter.enter_fields : []
      sources = []
      irep.instructions.each_with_index { |insn, j| sources << j if insn.op == 'BLKPUSH' && insn.paren_value.to_i.zero? }
      starts = {}
      local = nil
      if fields[6].to_i.positive?
        return true if fields[4].to_i.positive? || fields[5].to_i.positive?

        local = (1 + fields[0].to_i + fields[1].to_i + fields[2].to_i + fields[3].to_i).to_s
        starts[0] = { local => true }
      end
      return false if starts.empty? && sources.empty? && !nested_block_reads?(irep)

      flow(irep, starts, block_sources: sources, block_tracked: true, value_class: 'Proc').escapes?
    end

    def nested_block_reads?(irep)
      closure_children(irep).any? { |_, child| subtree_refs(child, 0, []).any? { |ref| ref[:kind] == :blk } }
    end

    # -- the frame flow ------------------------------------------------------------------------------
    # Per-run state shared by the transfer functions.
    Run = Struct.new(:irep, :reasons, :uses, :self_tracked, :params, :block_slot, :value_class, keyword_init: true)

    # +starts+: { instruction index => { register => true } }. With +created_at+ the start index is the
    # creating instruction and the value enters its SUCCESSORS (and again whenever it runs); otherwise the
    # state holds on entry to that index. +block_sources+: BLKPUSH indices that introduce the value;
    # +block_tracked+: the value is a method's block, so closures that BLKPUSH it from a nested level see it.
    def flow(irep, starts, created_at: nil, self_tracked: false, block_sources: [], block_tracked: false,
             value_class: nil)
      prog = BytecodeIR.for(irep)
      return failed(:cfg_unresolved) unless prog.resolved?
      return failed(:handlers_unresolved) unless prog.handlers_resolved?

      insns = prog.instructions
      params = parameter_count(irep)
      run = Run.new(irep: irep, reasons: [], uses: [], self_tracked: self_tracked, params: params,
                    block_slot: (params + 1).to_s, value_class: value_class)
      state = Array.new(insns.size)
      work = []
      seed = lambda do |index, regs|
        next if regs.empty? || index >= insns.size

        cur = state[index]
        merged = cur ? cur | regs : regs.to_set
        next if cur && merged.size == cur.size

        state[index] = merged
        work << index
      end
      starts.each do |index, regs|
        if created_at
          insns[index].successors.each { |succ| seed.call(succ, regs.keys) }
        else
          seed.call(index, regs.keys)
        end
      end
      block_sources.each do |j|
        insns[j].successors.each { |succ| seed.call(succ, [insns[j].source.reg]) }
      end

      ever = Set.new
      steps = 0
      until work.empty?
        i = work.pop
        return failed(:state_cap) if (steps += 1) > STEP_CAP

        s = state[i]
        ever.merge(s)
        out = step(run, i, insns[i].source, s)
        return Verdict.new(reasons: run.reasons, uses: run.uses.uniq, tracked: ever) unless run.reasons.empty?

        out = out | [insns[i].source.reg] if i == created_at
        insns[i].successors.each { |succ| seed.call(succ, out.to_a) }
        prog.successors_of(i, include_handlers: true).each do |succ|
          seed.call(succ, (s | out).to_a) unless insns[i].successors.include?(succ)
        end
      end

      ever.merge(Array(starts.values.flat_map(&:keys)))
      read_by_closures(run, ever, block_tracked: block_tracked)
      Verdict.new(reasons: run.reasons, uses: run.uses.uniq, tracked: ever)
    end

    def failed(reason)
      Verdict.new(reasons: [[reason, 0]], uses: [], tracked: Set.new)
    end

    # Registers R1..R<n> are the parameters; the block slot follows. ARGARY (zsuper) and BLKPUSH read them
    # without printing them.
    def parameter_count(irep)
      fields = irep.enter ? irep.enter.enter_fields : []
      fields.first(6).sum(&:to_i)
    end

    # -- one instruction -----------------------------------------------------------------------------
    # The registers holding the value after +insn+; appends to run.reasons when it escapes.
    def step(run, i, insn, s)
      op = insn.op
      lead = insn.reg
      escape = ->(why) { run.reasons << [why, insn.addr] }
      held = ->(r) { s.include?(r.to_s) }
      window = ->(from, count) { (0...count).any? { |k| held.call(from.to_i + k) } }

      return s if PASSES.include?(op)
      return s - [lead] if KILLS_LEAD.include?(op)

      if STORES_LEAD.key?(op)
        escape.call(STORES_LEAD[op]) if held.call(insn.reg_operand)
        return s
      end

      case op
      when 'MOVE' then s - [lead] | (held.call(insn.regs[1]) ? [lead] : [])
      when 'LOADSELF' then s - [lead] | (s.include?('0') ? [lead] : [])
      when 'RETSELF'
        escape.call(:returned) if s.include?('0')
        s
      when 'RESCUE'
        escape.call(:rescue_operand) if held.call(insn.regs[0]) || held.call(insn.regs[1])
        s - [insn.regs[1]]
      when 'ARGARY'
        escape.call(:stored_array) if s.any? { |r| r.to_i.between?(1, run.params) }
        s - [lead]
      when 'BLKPUSH'
        s - [lead] | (insn.paren_value.to_i.zero? && held.call(run.block_slot) ? [lead] : [])
      when *BINARY_NAMES.keys
        send_site(run, i, insn, s, BINARY_NAMES[op], recv: lead, args: [lead.to_i + 1], dest: lead)
      when 'ADDI', 'SUBI'
        send_site(run, i, insn, s, op == 'ADDI' ? '+' : '-', recv: lead, args: [], dest: lead)
      when 'ADDILV', 'SUBILV'
        # R[b], R[b+1] are the scratch window of the method-call fallback: written, never read.
        scratch = [insn.regs[1], (insn.regs[1].to_i + 1).to_s]
        send_site(run, i, insn, s, op == 'ADDILV' ? '+' : '-', recv: lead, args: [], dest: lead) - scratch
      when 'GETIDX' then send_site(run, i, insn, s, '[]', recv: lead, args: [lead.to_i + 1], dest: lead)
      when 'GETIDX0' then send_site(run, i, insn, s, '[]', recv: insn.regs[1], args: [], dest: lead)
      when 'SETIDX'
        send_site(run, i, insn, s, '[]=', recv: lead, args: [lead.to_i + 1, lead.to_i + 2], dest: lead)
      when *SEND_OPS then send_op(run, i, insn, s)
      when 'BLKCALL'
        escape.call(:block_call_argument) if window.call(lead.to_i + 1, insn.uint_operand.to_i)
        run.uses << Use.new(index: i, kind: :call, name: 'call', reg: lead) if held.call(lead)
        s - [lead]
      when 'SUPER'
        positional, kw = argument_slots(insn)
        escape.call(:super_window) if window.call(lead, positional + kw + 2) || s.include?('0')
        s - [lead]
      when 'ARRAY'
        three = insn.src_and_literal
        escape.call(:stored_array) if window.call(three ? three[0] : lead, three ? three[1].to_i : insn.uint_operand.to_i)
        s - [lead]
      when 'ARYCAT', 'HASHCAT', 'ARYSPLAT'
        escape.call(:spread_operand) if window.call(lead, 2)
        s - [lead]
      when 'ARYPUSH'
        escape.call(:stored_array) if window.call(lead.to_i + 1, insn.uint_operand.to_i)
        s
      when 'HASH'
        escape.call(:stored_hash) if window.call(lead, 2 * insn.uint_operand.to_i)
        s - [lead]
      when 'HASHADD'
        escape.call(:stored_hash) if window.call(lead.to_i + 1, 2 * insn.uint_operand.to_i)
        s
      when 'APOST'
        s - (0..insn.typed[2].value).map { |k| (lead.to_i + k).to_s }
      when 'STRCAT'
        # A String operand is copied; anything else is converted by its own to_s.
        escape.call(:string_operand) if held.call(lead.to_i + 1) && run.value_class != 'String'
        s
      when *CLOSURE_OPS then s - [lead]
      when *WINDOW_OPS
        escape.call(:class_machinery) if window.call(lead, 2) || s.include?('0')
        s - [lead]
      else
        escape.call(:unmodelled_op)
        s
      end
    end

    # -- sends ---------------------------------------------------------------------------------------
    # [positional slots, keyword slots] after the receiver; `n=*` packs the arguments in one slot.
    def argument_slots(insn)
      n = insn.n_spec
      nk = insn.nk_spec
      [n.nil? ? 0 : (n == '*' ? 1 : n.to_i), nk.nil? ? 0 : (nk == '*' ? 1 : 2 * nk.to_i)]
    end

    def send_op(run, i, insn, s)
      a = insn.reg.to_i
      positional, kw = argument_slots(insn)
      spread = insn.n_spec == '*'
      unpacked = spread ? [a + 1] : []
      unpacked += ((a + positional + 1)..(a + positional + kw)).to_a
      return reject(run, insn, :spread_or_keyword_argument, s) if unpacked.any? { |r| s.include?(r.to_s) }

      send_site(run, i, insn, s, insn.sym, recv: insn.op.start_with?('SS') ? nil : a,
                args: spread ? [] : (1..positional).map { |k| a + k }, dest: a,
                block: insn.op.end_with?('B') ? a + positional + kw + 1 : nil)
    end

    # The shared send rule; returns the registers holding the value after the call.
    def send_site(run, i, insn, s, name, recv:, args:, dest:, block: nil)
      out = s - [dest.to_s]
      reg_held = ->(r) { r && s.include?(r.to_s) }
      list = callees(run, i, name, recv, receiver_held: recv.nil? ? s.include?('0') : reg_held.call(recv))
      if recv.nil? ? s.include?('0') : reg_held.call(recv)
        result = receiver_result(name, list)
        return reject(run, insn, :send_receiver, s) unless result

        run.uses << Use.new(index: i, kind: :call, name: name, reg: recv.to_s) if recv && PROC_CALLS.include?(name)
        out |= [dest.to_s] if result == :self
      end
      args.each_with_index do |r, k|
        next unless reg_held.call(r)
        return reject(run, insn, :send_argument, s) if arg_captured_by_name?(name, k, list)

        run.uses << Use.new(index: i, kind: :pass_arg, name: name, reg: r.to_s)
      end
      if reg_held.call(block)
        return reject(run, insn, :send_block, s) if block_captured_by_name?(name, list)

        run.uses << Use.new(index: i, kind: :pass_block, name: name, reg: block.to_s)
      end
      out
    end

    # Definitions the call can reach: by the receiver's class when something proves it (the tracked
    # value's own class, the compiler's class flow, the class whose method this is for an implicit
    # self), else every definition of the name. nil when the world cannot enumerate them.
    def callees(run, index, name, recv, receiver_held:)
      if recv.nil?
        owner = run.self_tracked ? nil : @self_class&.call(run.irep)
        return @world.defs_for(name, owner && [owner], false)
      end
      return @world.defs_for(name, [run.value_class], true) if receiver_held && run.value_class

      @world.defs_for(name, @receiver_classes&.call(run.irep, index, recv), true)
    end

    def reject(run, insn, why, s)
      run.reasons << [why, insn.addr]
      s
    end

    # Definitions in +list+ with no analysable body that are not a plain accessor: natives the registry
    # lists, Struct members, module_function copies without a body.
    def opaque_defs(list)
      list.select { |d| body_irep(d).nil? && !(d.irep.nil? && d.kind == :ivar_accessor) }
    end

    # A definition installed by define_method has a block body whose parameters are not modelled.
    def installer?(list)
      list.any?(&:installer)
    end

    # :fresh / :self when no definition in +list+ keeps the receiver, else nil. A native counts only
    # through NATIVE_RECEIVER_OK; the rest is each bytecode definition's [:self] summary.
    def receiver_result(name, list)
      return nil if list.nil? || installer?(list)

      table = NATIVE_RECEIVER_OK[name]
      opaque = opaque_defs(list)
      return nil if table.nil? && (list.empty? || @world.native_name?(name) || !opaque.empty?)
      return nil if list.any? { |d| !opaque.include?(d) && captures?(d, [:self]) }

      table || :fresh
    end

    # No native has an audited argument fact: a name with a native definition keeps every argument.
    def arg_captured_by_name?(name, k, list)
      return true if list.nil? || list.empty? || installer?(list) || @world.native_name?(name)
      return true unless opaque_defs(list).empty?

      list.any? { |d| captures?(d, [:arg, k]) }
    end

    def block_captured_by_name?(name, list)
      return true if list.nil? || installer?(list)

      opaque = opaque_defs(list)
      natives = @world.native_name?(name) || !opaque.empty?
      return true if (natives || list.empty?) && !NATIVE_BLOCK_NO_CAPTURE.include?(name)

      list.any? { |d| !opaque.include?(d) && captures?(d, [:block]) }
    end

    # -- closures that can see the value ---------------------------------------------------------------
    # A closure made in this frame reads the frame's variables when it runs: a captured local (GETUPVAR),
    # the method block (BLKPUSH from a nested level) or, for self, implicitly. It sees the value safely
    # only if neither it nor any closure between it and the reading frame escapes, and the value does not
    # escape in the reading frame.
    def read_by_closures(run, ever, block_tracked:)
      irep = run.irep
      closure_children(irep).each do |ci, child|
        refs = closure_refs(irep, ci, child).select do |ref|
          !ref[:write] && (ref[:kind] == :blk ? block_tracked : ever.include?(ref[:idx].to_s))
        end
        next if refs.empty? && !run.self_tracked

        reason = closure_reason(irep, ci, child, refs, run)
        next unless reason

        run.reasons << [reason, irep.instructions[ci].addr]
        return
      end
    end

    def closure_refs(irep, ci, child)
      @refs[[irep.label, ci]] ||= subtree_refs(child, 0, [[irep, ci]])
    end

    def closure_reason(irep, ci, child, refs, run)
      return :captured_by_escaping_closure if closure_escapes?(irep, ci)

      refs.each do |ref|
        return :captured_by_escaping_closure if ref[:chain].any? { |(owner, index)| closure_escapes?(owner, index) }

        verdict = flow(ref[:irep], { ref[:index] => { ref[:dest] => true } }, created_at: ref[:index],
                       value_class: run.value_class)
        return verdict.reason if verdict.escapes?
      end
      return nil unless run.self_tracked

      verdict = flow(child, { 0 => { '0' => true } }, self_tracked: true)
      verdict.escapes? ? verdict.reason : nil
    end

    # [[closure instruction index, child irep]] of +irep+.
    def closure_children(irep)
      irep.instructions.each_with_index.filter_map do |insn, j|
        next unless CLOSURE_OPS.include?(insn.op)

        child = @world.ireps[irep.reps[insn.block_index.to_i]]
        [j, child] if child
      end
    end

    # Reads (GETUPVAR/SETUPVAR/BLKPUSH) inside +irep+'s closure subtree that resolve to the frame +irep+
    # is a closure of (+depth+ 0 = a read in +irep+ itself). +chain+: the [irep, closure index] pairs that
    # carry the read out of that frame.
    def subtree_refs(irep, depth, chain)
      refs = []
      irep.instructions.each_with_index do |insn, j|
        case insn.op
        when 'GETUPVAR', 'SETUPVAR'
          idx, level = insn.upvar_ref
          refs << { kind: :up, idx: idx, irep: irep, index: j, dest: insn.reg, write: insn.op == 'SETUPVAR',
                    chain: chain } if level == depth
        when 'BLKPUSH'
          refs << { kind: :blk, irep: irep, index: j, dest: insn.reg, write: false, chain: chain } if insn.paren_value.to_i == depth + 1
        end
      end
      closure_children(irep).each do |ci, child|
        refs.concat(subtree_refs(child, depth + 1, chain + [[irep, ci]]))
      end
      refs
    end
  end
end
