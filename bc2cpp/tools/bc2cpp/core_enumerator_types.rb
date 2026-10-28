# frozen_string_literal: true

require 'set'
require_relative 'bytecode_ir'
require_relative 'bytecode_ir_ops'
require_relative 'ir_block_operands'
require_relative 'class_world'

# CORE_ENUMERATOR_TYPES: the receiver facts CoreEnumeratorFree needs, a class-set analysis over the engine's own Ruby
# that reads no codegen state (the closed-list proof runs before code generation).
#
# A value is a Set of tags or TOP (any value). A tag is "K" (an instance whose class is exactly K) or "K.singleton"
# (the class object K). The sets only grow. Everything the model does not account for (a core or native method's result,
# an array element, a block parameter, a global, a refused reaching-definitions query) is TOP, and TOP is never
# proven safe. Calls are resolved by NAME, not by receiver: the result of `x.m` is the union over every definition of
# `m` in the world, and TOP when a core or native one exists. That is coarser than a receiver-typed lookup and sound
# without typing the receiver. Arguments flow the same way: parameter i of a method named m is the union over every
# send of `m`. Instance variables are keyed by name alone.
#
# A name whose parameters or result something outside the bytecode touches is TOP: a name a native spells or a looked-up
# Symbol literal names (EXTERNAL_NAMES), an `initialize` (called by `new`: sends of `new` supply its arguments), any
# method with a SUPER in it.
module CoreEnumeratorTypes
  TOP = :top
  EMPTY = Set.new.freeze
  # Sends that run a block with another self, or set an ivar by name: self inside any block is TOP when one is spelled.
  SELF_CHANGING = %w[instance_eval instance_exec class_eval class_exec module_eval module_exec define_method
                     define_singleton_method].to_set.freeze
  LITERAL = { LOADSYM: 'Symbol', SYMBOL: 'Symbol', STRING: 'String', STRCAT: 'String', ARRAY: 'Array', ARRAY2: 'Array',
              ARYCAT: 'Array', ARYPUSH: 'Array', ARYSPLAT: 'Array', HASH: 'Hash', HASHADD: 'Hash', HASHCAT: 'Hash',
              RANGE_INC: 'Range', RANGE_EXC: 'Range', LOADNIL: 'NilClass', LOADTRUE: 'TrueClass',
              LOADFALSE: 'FalseClass', LAMBDA: 'Proc', BLOCK: 'Proc' }.freeze

  def self.union(a, b)
    return TOP if a == TOP || b == TOP

    a.empty? ? b : (b.empty? ? a : a | b)
  end

  # The class graph of the world: engine classes from build_registry's tables, core classes from ClassWorld::NATIVE.
  # +definers+ maps an owner ("Array", "Foo.singleton") to the names defined on it (Ruby and native); +computed+ is
  # the owners with a computed-name registration (any name may be defined there).
  class Hierarchy
    # mruby's exception classes (all C-defined) beside ClassWorld's, enough for a superclass the registry names and for the
    # class of a rescued exception (CoreException stands for any of them: none defines an iterator).
    EXCEPTIONS = %w[ArgumentError RuntimeError TypeError RangeError IndexError KeyError NameError ZeroDivisionError IOError
                    EOFError NotImplementedError LocalJumpError FloatDomainError StopIteration FrozenError ScriptError
                    SystemExit SystemCallError RegexpError SecurityError].freeze
    CORE = ClassWorld::NATIVE.merge(
      EXCEPTIONS.to_h { |n| [n, [[n, 'StandardError', 'Exception', 'Object', 'Kernel', 'BasicObject'], :class]] }
    ).merge(
      'NoMethodError' => [%w[NoMethodError NameError StandardError Exception Object Kernel BasicObject], :class],
      'CoreException' => [%w[CoreException Exception Object Kernel BasicObject], :class]
    ).freeze
    CLASS_CHAIN = %w[Class Module Object Kernel BasicObject].freeze

    def initialize(superclass_of:, included:, prepended:, unknown:, modules:, definers:, computed:, wild: Set.new, native_classes: {})
      @superclass_of = superclass_of
      @included = included
      @prepended = prepended
      @unknown = unknown
      @modules = modules.to_set
      @definers = definers
      @computed = computed
      @wild = wild
      @native_classes = native_classes
      @ancestors = {}
      @classes = (superclass_of.keys + CORE.keys + native_classes.keys).to_set
    end

    attr_reader :definers

    def class?(name)
      @classes.include?(name)
    end

    def known?(name)
      @classes.include?(name) || @modules.include?(name) || CORE.key?(name)
    end

    # Lookup order of the instances of +klass+ ("K") or the class object ("K.singleton"); nil when the graph is unknown.
    def ancestors(tag)
      return @ancestors[tag] if @ancestors.key?(tag)

      @ancestors[tag] = nil # cycle guard
      @ancestors[tag] = tag.end_with?('.singleton') ? singleton_ancestors(tag.delete_suffix('.singleton')) : instance_ancestors(tag)
    end

    # The first owner in lookup order that defines +name+ for +tag+: an owner String, nil (none: NoMethodError), or
    # :unknown (the graph or a registration is not fully known).
    def lookup(tag, name)
      chain = ancestors(tag) or return :unknown
      chain.each do |owner|
        return :unknown if @computed.include?(owner)
        return owner if @definers.fetch(owner, EMPTY).include?(name)
      end
      # A ROM table installed into several classes defines the name on one of them.
      @wild.include?(name) ? :unknown : nil
    end

    # Every tag whose receiver may run a method defined on +owner+: the owner's own class and what inherits it.
    def family(owner, universe)
      singleton = owner.end_with?('.singleton')
      # A module is a receiver only as its class object (`module M; def self.x`).
      universe = universe + @modules.to_a if singleton
      universe.filter_map do |klass|
        tag = singleton ? "#{klass}.singleton" : klass
        tag if ancestors(tag)&.include?(owner)
      end
    end

    def classes
      @classes
    end

    # The modules Object includes (`include RGSS` at the top level): their constants resolve from anywhere.
    def object_mixins
      mixins_of('Object')
    end

    def module?(name)
      @modules.include?(name) && !CORE.key?(name)
    end

    # The class at the top of +klass+'s run of engine-declared superclasses: instances of a class and its engine
    # subclasses share instance variables, and nothing else does.
    def root_class(klass)
      seen = Set.new
      while seen.add?(klass)
        sup = @superclass_of[klass]
        break unless sup.is_a?(String) && @superclass_of.key?(sup) && !CORE.key?(sup)

        klass = sup
      end
      klass
    end

    private

    def mixins_of(klass)
      @included.fetch(klass, []).reverse.flat_map { |m| [m, *mixins_of(m)] }
    end

    def superclass(klass)
      return @native_classes[klass] if @native_classes.key?(klass) && !@superclass_of.key?(klass)

      sup = @superclass_of[klass]
      return 'Object' if sup == :none || sup.nil?

      return sup if known?(sup)

      # A core superclass the registry spelled with the enclosing namespace (`LCF::StandardError`).
      bare = sup.split('::').last
      CORE.key?(bare) ? bare : nil
    end

    def instance_ancestors(klass)
      return nil if @unknown.include?(klass) || !known?(klass)

      pre = @prepended.fetch(klass, []).reverse.flat_map { |m| [m, *mixins_of(m)] }
      return [*pre, klass, *mixins_of(klass)] if @modules.include?(klass) && !CORE.key?(klass)

      own = [*pre, klass, *mixins_of(klass)]
      if CORE.key?(klass)
        return (own + CORE.fetch(klass).first.drop(1) + mixins_of('Object')).uniq
      end

      sup = superclass(klass) or return nil
      parent = ancestors(sup) or return nil
      (own + parent).uniq
    end

    def singleton_ancestors(klass)
      return nil if @unknown.include?(klass) || !known?(klass)

      out = []
      cur = klass
      seen = Set.new
      while cur
        return nil unless seen.add?(cur)

        out << "#{cur}.singleton"
        cur = CORE.key?(cur) ? CORE.fetch(cur).first[1..].find { |a| CORE.fetch(a).last == :class } : superclass(cur)
        break if cur.nil? && !out.empty? && !CORE.key?(out.last.delete_suffix('.singleton')) && !@classes.include?(out.last.delete_suffix('.singleton'))
      end
      out + CLASS_CHAIN + mixins_of('Object')
    end
  end

  # One engine group's class-set analysis. +group+ responds to ireps, registry, body_of (irep label => MethodDef),
  # method_of (irep label => enclosing method body label) and parent. +external+ is the names something outside the
  # bytecode may call (see the header), +ivar_external+ the ivar names a native may set.
  class Typer
    def initialize(group:, hierarchy:, external:, external_owners:, ivar_external:, foreign:)
      @group = group
      @hier = hierarchy
      @external = external
      @external_owners = external_owners
      @ivar_external = ivar_external
      @foreign = foreign
      @vals = {}
      @why = {}
      @reads = Hash.new { |h, k| h[k] = Set.new }
      @deps = Hash.new { |h, k| h[k] = Set.new }
      @queue = []
      @queued = Set.new
      @stable_self = group.sends_named(SELF_CHANGING).empty? && !group.class_building_blocks?
      @defs_by_name = Hash.new { |h, k| h[k] = [] }
      group.registry.each { |name, defs| @defs_by_name[name].concat(defs) }
      @universe = @hier.classes.select { |k| Hierarchy::CORE.fetch(k, [nil, :class]).last == :class }.to_a
    end

    # The class set of the value in +reg+ at the read at +index+ of +irep+, or TOP.
    def at(irep, index, reg)
      key = [:site, irep.label, index, reg]
      solve(key)
    end

    # Why the value at the site is TOP, as a chain of node descriptions (debugging aid for an unproven site).
    def explain(irep, index, reg)
      explain_key(index ? [:site, irep.label, index, reg] : [:self, irep.label])
    end

    def explain_key(key)
      solve(key)
      # Breadth first over the TOP nodes it reads, to the nearest one that was made TOP for a stated reason.
      parent = { key => nil }
      queue = [key]
      until queue.empty?
        node = queue.shift
        if @why[node]
          path = []
          cur = node
          while cur
            path.unshift("#{cur.first(3).inspect[0, 70]}#{cur == node ? " -- #{@why[node]}" : ''}")
            cur = parent[cur]
          end
          return path
        end
        @reads[node].each do |r|
          next unless @vals[r] == TOP && !parent.key?(r)

          parent[r] = node
          queue << r
        end
      end
      [key.first(3).inspect]
    end

    # The class set of self in the method of +irep+ (its enclosing method's owner), or TOP.
    def self_of(irep)
      key = [:self, irep.label]
      solve(key)
    end

    private

    def solve(key)
      val(key, nil)
      until @queue.empty?
        node = @queue.shift
        @queued.delete(node)
        evaluate(node)
      end
      @vals.fetch(key)
    end

    # Read a node's current value; the reader is re-evaluated when it grows.
    def val(key, reader)
      @deps[key] << reader if reader
      @reads[reader] << key if reader
      unless @vals.key?(key)
        @vals[key] = EMPTY
        @queue << key
        @queued << key
      end
      @vals[key]
    end

    def evaluate(key)
      @cur = key
      new = compute(key)
      old = @vals[key]
      new = CoreEnumeratorTypes.union(old, new)
      return if new == old

      @vals[key] = new
      @deps[key].each { |d| @queue << d if @queued.add?(d) }
    end

    def compute(key)
      case key[0]
      when :site then site_value(key)
      when :self then self_value(key)
      when :ivar then ivar_value(key)
      when :arg then arg_value(key)
      when :arg_init then arg_init_value(key)
      when :upvar then upvar_value(key)
      when :ret then ret_value(key)
      when :retdef then retdef_value(key)
      when :const then const_value(key)
      else top('unknown node')
      end
    end

    # TOP, remembering why for the node being computed (explain).
    def top(reason)
      @why[@cur] ||= reason
      TOP
    end

    def irep_of(label)
      @group.ireps.fetch(label)
    end

    # IrBlockOperands.definitions with the state cap raised: the largest methods (a 1000-instruction loader) exceed the default.
    def definitions(irep, index, reg, follow_moves: true)
      return nil unless index.is_a?(Integer) && index.between?(0, BytecodeIR.for(irep).size - 1)

      defs = BytecodeIR.reaching_definitions(irep, index, reg, follow_moves: follow_moves, through_handlers: true, origin_transfers: true,
                                                               shared: true, max_states: MAX_STATES)
      defs && !defs.empty? ? defs : nil
    end

    # GETUPVAR R(a) b c: variable b of the frame c + 1 levels up (c = 0 is the frame that made this block).
    def upvar_read(irep, w, reader)
      index, level = w.upvar_ref
      target = irep.label
      (level + 1).times { target = @group.parent[target] or return top('GETUPVAR above the root') }
      val([:upvar, target, index], reader)
    end

    # A captured variable, flow-insensitively: every write of its register in the frame that owns it, every SETUPVAR of a
    # block below it, its value on entry (a parameter), and nil.
    def upvar_value(key)
      _, label, reg = key
      irep = irep_of(label)
      prog = BytecodeIR.for(irep)
      acc = Set['NilClass']
      prog.each_source do |insn, idx|
        next unless prog.may_write_at?(idx, reg)
        # RESCUE reads its first register and writes only its second (the match result).
        next if insn.op == :RESCUE && insn.regs[1] != reg

        acc = CoreEnumeratorTypes.union(acc, writer_value(irep, idx, insn, reg, key))
      end
      @group.upvar_writers[[label, reg]].each do |e_irep, idx, src|
        acc = CoreEnumeratorTypes.union(acc, val([:site, e_irep.label, idx, src], key))
      end
      CoreEnumeratorTypes.union(acc, entry_value(irep, reg, nil, key))
    end

    def site_value(key)
      _, label, index, reg = key
      irep = irep_of(label)
      defs = definitions(irep, index, reg)
      defs ||= definitions(irep, index, reg, follow_moves: false) if captured_source?(irep, index, reg)
      unless defs
        # A variable some block writes (SETUPVAR) has no reaching-definition answer: its value is any write of it.
        return val([:upvar, label, reg], key) if @group.upvar_writers.key?([label, reg])

        return top('reaching definitions refused')
      end

      defs.inject(EMPTY) do |acc, df|
        v = df.entry? ? entry_value(irep, df.reg, nil, key) : def_value(irep, df, key)
        CoreEnumeratorTypes.union(acc, v)
      end
    end

    # Is the register at +index+ a copy (MOVE) of a variable some block writes? Following the copy is what the answer refuses.
    def captured_source?(irep, index, reg)
      first = definitions(irep, index, reg, follow_moves: false) or return false
      first.any? { |df| !df.entry? && BytecodeIR.for(irep).source_at(df.index).op == :MOVE }
    end

    # The slot of ENTER's layout a register names: the vm.c OP_ENTER rule enter_slot (bytecode_ir_dataflow.rb) states.
    def entry_value(irep, reg, enter, reader)
      method_def = @group.body_of[irep.label]
      return top("a block parameter (no yield flow is modelled)") unless method_def

      return val([:self, irep.label], reader) if reg.to_i.zero?

      enter ||= irep.enter
      fields = enter && enter.enter_fields
      return top('ENTER shape') unless fields && fields.size == 8

      req, opt, rest, post, key, kdict = fields.first(6).map(&:to_i)
      n = reg.to_i
      kd = key.positive? || kdict.positive? ? 1 : 0
      len = req + opt + rest + post
      if n <= req + opt
        return val([:arg_init, method_def.owner, n - 1], reader) if method_def.name == 'initialize'

        return val([:arg, method_def.name, n - 1], reader)
      end
      return Set['Array'] if rest.positive? && n == req + opt + 1
      return Set['Hash'] if kd == 1 && n == len + 1
      return Set['Proc', 'NilClass'] if n == len + kd + 1
      return top('a post parameter') if n <= len

      n < irep.nlocals.to_i ? Set['NilClass'] : top('a temporary at entry')
    end

    def def_value(irep, df, reader)
      writer = BytecodeIR.for(irep).source_at(df.index)
      return top('no writer') unless writer

      writer_value(irep, df.index, writer, df.reg, reader)
    end

    def writer_value(irep, index, w, reg, reader)
      op = w.op
      return Set['Integer'] if BytecodeIR::Ops::LOADI_OPS.include?(op)
      return Set[LITERAL.fetch(op)] if LITERAL.key?(op)

      case op
      when :LOADL then loadl(irep, w)
      when :ADD, :SUB, :MUL, :DIV, :ADDI, :SUBI then arithmetic(irep, index, w, reader, NUMERIC)
      when :EQ, :LT, :LE, :GT, :GE then arithmetic(irep, index, w, reader, BOOLEAN)
      when :EXCEPT then exception_value
      when :LOADSELF then val([:self, irep.label], reader)
      when :MOVE then val([:site, irep.label, index, w.regs[1]], reader)
      when :ENTER then entry_value(irep, reg, w, reader)
      when :GETIV then val([:ivar, w.ivar, ivar_group(irep)], reader)
      when :GETUPVAR then upvar_read(irep, w, reader)
      when :GETCONST, :GETMCNST then const_value_of(irep, index, w, reader)
      when :SEND, :SEND0, :SSEND, :SSEND0 then call_value(irep, index, w, reader)
      else top("writer #{op}#{":#{w.sym}" if w.sym}")
      end
    end

    MAX_STATES = 20_000
    NUMERIC = Set['Integer', 'Float'].freeze
    BOOLEAN = Set['TrueClass', 'FalseClass'].freeze
    # Methods of Integer and Float that answer an Integer or a Float whatever the operand is.
    NUMERIC_METHODS = %w[+ - * / % ** & | ^ << >> -@ +@ ~ abs floor ceil round truncate to_i to_f succ pred divmod fdiv].to_set.freeze
    COMPARISONS = %w[== != < <= > >= <=>].to_set.freeze

    # An arithmetic or comparison opcode: the VM runs the Integer/Float arm for a numeric receiver and sends the operator
    # (a method of any other class) otherwise.
    def arithmetic(irep, index, w, reader, numeric_result)
      recv = val([:site, irep.label, index, w.reg], reader)
      return EMPTY if recv.empty?
      return top("#{w.op} on a receiver that is not a number") if recv == TOP || !recv.subset?(NUMERIC)

      numeric_result
    end

    # The exception a `rescue` caught: an engine exception class, or any core one.
    def exception_value
      tags = @hier.family('Exception', @universe)
      tags.empty? ? Set['CoreException', 'Exception', 'StandardError'] : tags.to_set | Set['CoreException', 'Exception', 'StandardError']
    end

    def loadl(irep, w)
      entry = irep.pool[w.pool_index.to_i]
      return top('LOADL') unless entry.is_a?(Hash)

      case entry[:type]
      when :int32, :int64, :bigint then Set['Integer']
      when :float then Set['Float']
      else top('LOADL')
      end
    end

    # The class object a constant read names (K.singleton), or the type of the value some SETCONST stores. A scoped
    # read (`A::B`) resolves its scope register first.
    def const_value_of(irep, index, w, reader)
      name = w.const_name.to_s
      if w.op == :GETMCNST
        scope = val([:site, irep.label, index, w.paren_reg], reader)
        return EMPTY if scope.empty? # not computed yet: the node runs again when the scope grows
        return val([:const, name], reader) if scope == TOP

        tags = scope.map { |t| t.end_with?('.singleton') && @hier.known?("#{t.delete_suffix('.singleton')}::#{name}") ? "#{t.delete_suffix('.singleton')}::#{name}" : nil }
        return val([:const, name], reader) if tags.any?(&:nil?) || tags.empty? || tags.any? { |c| @group.const_names.include?(name) }

        return Set.new(tags.map { |c| "#{c}.singleton" })
      end
      owner = @group.body_of[@group.method_of[irep.label]]&.owner
      scope = owner.to_s.delete_suffix('.singleton').split('::')
      candidates = scope.length.downto(1).map { |n| "#{scope.first(n).join('::')}::#{name}" } << name
      candidates.concat(@hier.object_mixins.map { |m| "#{m}::#{name}" })
      hit = candidates.find { |c| @hier.known?(c) }
      return val([:const, name], reader) unless hit && !@group.const_names.include?(name)

      Set["#{hit}.singleton"]
    end

    def const_value(key)
      name = key[1]
      stores = @group.const_stores[name]
      return top("constant #{name} has no SETCONST (a core or native constant)") if stores.nil? || stores.empty?

      stores.inject(EMPTY) { |acc, (irep, idx, reg)| CoreEnumeratorTypes.union(acc, val([:site, irep.label, idx, reg], key)) }
    end

    def self_value(key)
      label = key[1]
      up = @group.method_of[label]
      method_def = up && @group.body_of[up]
      return top('self at class body / top level') unless method_def
      return top('self in a block of a program that changes self') if label != up && !@stable_self
      return top('native owner') if method_def.owner == '<native>'

      tags = @hier.family(method_def.owner, @universe)
      tags.empty? ? top('self: no class family') : tags.to_set
    end

    # The instance-variable family of the method that holds +irep+: '*' when the owner is a module, Object or unknown (the
    # variable may belong to any class), else the root of its engine superclasses ("S:" for a class object's own).
    def ivar_group(irep)
      up = @group.method_of[irep.label]
      d = up && @group.body_of[up]
      d ? owner_group(d.owner) : '*'
    end

    def owner_group(owner)
      return '*' if owner.nil? || owner == '<native>'

      base = owner.delete_suffix('.singleton')
      return '*' if @hier.module?(base) || %w[Object Kernel BasicObject Comparable].include?(base) || !@hier.class?(base)

      root = @hier.root_class(base)
      owner.end_with?('.singleton') ? "S:#{root}" : root
    end

    def same_group?(a, b)
      a == '*' || b == '*' || a == b
    end

    # ivar "name" (no @) of a family: every store in the program to that family (or to '*'), the accessor writers of it, and
    # nil (read before any store).
    def ivar_value(key)
      _, name, group = key
      return top("a native may set @#{name}") if @ivar_external.include?(name)

      acc = Set['NilClass']
      (@group.ivar_stores[name] || []).each do |irep, idx, reg|
        next unless same_group?(group, ivar_group(irep))

        acc = CoreEnumeratorTypes.union(acc, val([:site, irep.label, idx, reg], key))
      end
      if @defs_by_name["#{name}="].any? { |d| d.kind == :ivar_accessor && same_group?(group, owner_group(d.owner)) }
        acc = CoreEnumeratorTypes.union(acc, val([:arg, "#{name}=", 0], key))
      end
      acc
    end

    # Argument i of every send named +name+ (`new` supplies `initialize`'s). A site that passes keywords hands a Hash to
    # a method without keyword parameters.
    def arg_value(key)
      _, name, i = key
      return top("#{name} is called from outside the bytecode (native/Symbol)") if @external.include?(name)

      senders = @group.sends_by_name[name] + @group.super_sites[name]
      senders.inject(EMPTY) do |acc, (irep, idx, insn)|
        next top("a splat call of #{name}") if insn.positional_splat? || insn.keyword_splat?
        # A call whose argument count no definition of the name takes raises before any body runs.
        next acc unless @defs_by_name[name].any? { |d| takes?(d, insn) }

        slots = insn.positional_slots
        next CoreEnumeratorTypes.union(acc, insn.keyword_arguments? && i == slots ? Set['Hash'] : EMPTY) if i >= slots

        CoreEnumeratorTypes.union(acc, val([:site, irep.label, idx, insn.reg + 1 + i], key))
      end
    end

    # Parameter i of the `initialize` an owner defines: the arguments of every `new` that can build one of its instances
    # (the receiver is unknown, or a class whose `initialize` lookup ends at this owner) and of the `super` calls below it.
    def arg_init_value(key)
      _, owner, i = key
      return top('a native may build one (its class name is spelled in native text)') if @external_owners.include?(owner.delete_suffix('.singleton'))

      acc = EMPTY
      inits = @defs_by_name['initialize'].select { |d| d.owner == owner }
      @group.sends_by_name['new'].each do |irep, idx, insn|
        if insn.positional_splat? || insn.keyword_splat?
          next unless builds_owner?(irep, idx, insn, owner, key)

          return top('a splat call of new that may build it')
        end
        next unless inits.any? { |d| takes?(d, insn) } && builds_owner?(irep, idx, insn, owner, key)

        slots = insn.positional_slots
        if i >= slots
          acc = CoreEnumeratorTypes.union(acc, Set['Hash']) if insn.keyword_arguments? && i == slots
          next
        end
        acc = CoreEnumeratorTypes.union(acc, val([:site, irep.label, idx, insn.reg + 1 + i], key))
      end
      # super: from an `initialize` whose class has this owner above it.
      @group.super_sites['initialize'].each do |irep, idx, insn|
        up = @group.method_of[irep.label]
        d = up && @group.body_of[up]
        next unless d && super_reaches?(d.owner, owner)
        return top('a splat super in initialize') if insn.positional_splat? || insn.keyword_splat?
        next unless inits.any? { |m| takes?(m, insn) }

        slots = insn.positional_slots
        next if i >= slots

        acc = CoreEnumeratorTypes.union(acc, val([:site, irep.label, idx, insn.reg + 1 + i], key))
      end
      acc
    end

    # Can the definition +d+ be entered by the call +insn+ (its ENTER takes that many positional arguments; a keyword hash
    # may count as one more)? A definition without a body (an attr accessor) takes what its kind does.
    def takes?(d, insn)
      return true unless d.irep

      enter = irep_of(d.irep).enter
      fields = enter && enter.enter_fields
      k = insn.positional_slots
      return k.zero? || (insn.keyword_arguments? && k == 0) if fields.nil?
      return true unless fields.size == 8

      req, opt, rest, post = fields.first(4).map(&:to_i)
      fits = ->(n) { n >= req + post && (rest.positive? || n <= req + opt + post) }
      fits.call(k) || (insn.keyword_arguments? && fits.call(k + 1))
    end

    # Does `new` at the site possibly end in the `initialize` of +owner+?
    def builds_owner?(irep, idx, insn, owner, reader)
      recv = if BytecodeIR::Ops::SELF_SEND_FAMILY.include?(insn.op) then val([:self, irep.label], reader)
             else val([:site, irep.label, idx, insn.reg], reader)
             end
      return true if recv == TOP

      recv.any? do |tag|
        next true unless tag.end_with?('.singleton')

        @hier.lookup(tag.delete_suffix('.singleton'), 'initialize') == owner
      end
    end

    # Does a `super` in a method of +from+ reach +to+ (the first definer of the name above it, or any above for an unknown graph)?
    def super_reaches?(from, to)
      return true if from == to

      chain = @hier.ancestors(from.delete_suffix('.singleton'))
      return true unless chain

      above = chain.drop(chain.index(from) ? chain.index(from) + 1 : 0)
      above.include?(to)
    end

    # The result of a send, by name.
    def call_value(irep, index, w, reader)
      name = w.sym.to_s
      if name == 'new' && %i[SSEND SSEND0].include?(w.op)
        recv = val([:self, irep.label], reader)
        return new_value(recv, name, reader) unless recv == TOP
      end
      if %i[SEND SEND0].include?(w.op) && (name == 'new' || NUMERIC_METHODS.include?(name) || COMPARISONS.include?(name))
        recv = val([:site, irep.label, index, w.reg], reader)
        return new_value(recv, name, reader) if name == 'new' && recv != TOP
        if recv != TOP && !recv.empty? && recv.subset?(NUMERIC)
          return NUMERIC if NUMERIC_METHODS.include?(name)
          return BOOLEAN if COMPARISONS.include?(name) && name != '<=>'
        end
      end
      val([:ret, name], reader)
    end

    def new_value(recv, name, reader)
      out = EMPTY
      recv.each do |tag|
        return val([:ret, name], reader) unless tag.end_with?('.singleton')

        klass = tag.delete_suffix('.singleton')
        owner = @hier.lookup(tag, 'new')
        return top('new on an unknown class graph') if owner == :unknown
        return val([:ret, name], reader) unless owner == 'Class' || owner.nil?

        out |= Set[klass]
      end
      out
    end

    def ret_value(key)
      name = key[1]
      defs = @defs_by_name[name]
      return top("no engine definition of #{name}") if defs.empty?
      return top("#{name} is also defined by core Ruby or a native") if @foreign.include?(name)
      return top("#{name} has a native definition") if defs.any? { |d| d.owner == '<native>' || (d.irep.nil? && d.kind != :ivar_accessor) }

      defs.inject(EMPTY) do |acc, d|
        v = if d.kind == :ivar_accessor && d.irep.nil?
              name.end_with?('=') ? top('a setter result') : val([:ivar, name, owner_group(d.owner)], key)
            else
              val([:retdef, d.irep], key)
            end
        CoreEnumeratorTypes.union(acc, v)
      end
    end

    # The union of what the method's returns carry; a `return` in a block counts.
    def retdef_value(key)
      label = key[1]
      acc = EMPTY
      @group.each_irep_of_method(label) do |irep|
        prog = BytecodeIR.for(irep)
        prog.each_source do |insn, idx|
          v = case insn.op
              when :RETURN then irep.label == label ? val([:site, irep.label, idx, insn.reg], key) : nil
              when :RETURN_BLK then val([:site, irep.label, idx, insn.reg], key)
              when :RETSELF then val([:self, label], key)
              when :RETNIL then Set['NilClass']
              when :RETTRUE then Set['TrueClass']
              when :RETFALSE then Set['FalseClass']
              end
          acc = CoreEnumeratorTypes.union(acc, v) if v
        end
      end
      acc
    end
  end
end
