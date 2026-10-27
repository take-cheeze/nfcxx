# frozen_string_literal: true

require 'set'
require_relative 'bytecode_ir'

# CodeGen: SLOT_ASSURED. An embedded mrb_value slot starts as undef (unset), so a compiled read normalises it:
# `mrb_undef_p(f) ? nil : f`. The read can use the field as it is when it provably runs after the slot was
# assigned. docs/bc2cpp-slot-assured.md has the argument; in short:
#
#   - no instance of the struct's family is ever a value before its #initialize returns, so only code running
#     with `self` = the object under construction can see it unassigned. That code (the construction reach) is
#     closed under self-calls, `super`, blocks and the names `send`/`method` dispatch to;
#   - every #initialize an instance can run assigns the ivar on every normal exit;
#   - nothing removes an ivar or makes an instance without #initialize.
#
# A read in an irep outside the construction reach needs no undef test. Reads inside it keep it.
class CodeGen
  # Natives that, called on `self`, neither call another method on it nor hand it out (beyond the names
  # listed, which join the reach). Any other native self-call refuses the family.
  SLOT_ASSURED_NATIVE_SELF_CALLS = {
    'raise' => [], 'block_given?' => [], 'puts' => [], 'print' => [], 'p' => [], 'format' => [], 'sprintf' => [],
    'Integer' => [], 'Float' => [], 'String' => [], 'Array' => [], 'rand' => [], 'lambda' => [], 'proc' => [],
    'loop' => [], 'frozen?' => [], 'is_a?' => [], 'kind_of?' => [], 'instance_of?' => [], 'nil?' => [],
    'class' => [], 'object_id' => [], 'instance_variable_get' => [], 'instance_variable_set' => [],
    'instance_variable_defined?' => [], 'instance_variables' => [], 'respond_to?' => %w[respond_to_missing?],
    # Kernel's format the class and the ivars' values; an ivar never holds self while it is built (LOADSELF).
    'to_s' => [], 'inspect' => %w[to_s],
    # A Method bound to self calls its literal name (slot_reach_symbol_args); its to_s/inspect format the
    # receiver. Method#receiver would hand self out, so the world must never name it.
    'method' => %w[to_s inspect respond_to_missing?],
    # BasicObject's raises NoMethodError, whose message names only the class.
    'method_missing' => [], 'respond_to_missing?' => [],
    'send' => [], '__send__' => [], 'public_send' => []
  }.freeze
  # The self-calls whose first argument names the method they dispatch to.
  SLOT_ASSURED_NAMED_DISPATCH = %w[method send __send__ public_send].freeze
  # Ops that hand `self` out as a value, or define methods while the object is built.
  SLOT_ASSURED_EXPOSING = Set[:LOADSELF, :RETSELF, :EXEC, :SCLASS, :METHOD, :DEF, :SDEF, :TDEF, :ALIAS, :UNDEF,
                              :CLASS, :MODULE, :TCLASS].freeze
  # Ops whose register operands may name R0 without reading `self` as a value.
  SLOT_ASSURED_SELF_OPERAND_OK = (BytecodeIR::Ops::SELF_SEND_FAMILY | %i[GETIV SETIV ENTER SUPER]).freeze
  # Calls that run code no scan sees: `eval`, and the String forms of the *_eval rebinders, which mruby-eval
  # provides. A literal block is the other form.
  SLOT_ASSURED_STRING_EVALS = %w[instance_eval class_eval module_eval].freeze
  SLOT_ASSURED_NORMAL_EXIT = Set[:RETURN, :RETNIL, :RETTRUE, :RETFALSE, :RETSELF].freeze

  # One class family: per class, the #initialize its instances run and their lookup chain (`inits`), and the
  # classes an instance of it can be (`subtrees`); the ireps that may run while an instance is built (`reach`)
  # and the names they self-call (`names`). These are facts about classes, not about the struct, so a fold made
  # after a probe asked leaves them true.
  SlotFacts = Struct.new(:inits, :subtrees, :reach, :names, keyword_init: true)
  # One self-call's targets: Ruby `defs` to walk, `extra` names a native may call back, and whether `defs` is
  # exactly the one definition that runs (`exact`).
  SlotTarget = Struct.new(:defs, :extra, :exact, keyword_init: true)

  # Can the GETIV of @ivar on `self` (an instance of +klass+) in +irep_label+ skip the undef test?
  def slot_read_assured?(klass, ivar, irep_label)
    facts = slot_facts(klass) or return false

    slot_assigned_below?(facts, klass, ivar) && !facts.reach.include?(irep_label)
  end

  # The synthesized reader of @ivar on +owner+: no self-call during construction names it.
  def slot_reader_assured?(owner, ivar)
    facts = slot_facts(owner) or return false

    slot_assigned_below?(facts, owner, ivar) && !facts.names.include?(ivar)
  end

  def slot_assigned_below?(facts, klass, ivar)
    subtree = facts.subtrees[klass] or return false
    return false if @outside_ivar_names.include?(ivar)

    subtree.all? do |k|
      init, chain = facts.inits.fetch(k)
      slot_assigns_on_exit?(init.irep, ivar, chain, [])
    end
  end

  def slot_facts(klass)
    return nil if ENV['BC2CPP_SLOT_ASSURED'] == '0'

    root = embed_storage_owner(klass)
    @slot_facts ||= {}
    return @slot_facts[root] if @slot_facts.key?(root)

    facts = slot_world_refusal || slot_family_facts(root)
    @slot_facts[root] = facts.is_a?(String) ? nil : facts
    slot_report(root, facts)
    @slot_facts[root]
  end

  # BC2CPP_SLOT_ASSURED_REPORT=1 prints one line per family to stderr.
  def slot_report(root, facts)
    return unless ENV['BC2CPP_SLOT_ASSURED_REPORT'] == '1'
    return warn("bc2cpp: slot-assured #{root}: refused: #{facts}") if facts.is_a?(String)

    ivars = (@ivar_layout[root] || {}).keys
    assigned = facts.inits.keys.sort.map do |k|
      "#{k}: #{ivars.select { |ivar| slot_assigned_below?(facts, k, ivar) }.sort.join(' ')}"
    end.join('; ')
    warn "bc2cpp: slot-assured #{root}: assigned #{assigned}; reach #{facts.reach.size} ireps, " \
         "names #{facts.names.to_a.sort.join(' ')}"
  end

  # Why no family can be assured, or nil.
  def slot_world_refusal
    return @slot_world_refusal if defined?(@slot_world_refusal)

    @slot_world_refusal =
      if @closed_world.nil? || @outside_ivar_names.nil? then 'no closed world'
      elsif @closed_world.global_refusal then "global refusal #{@closed_world.global_refusal}"
      elsif !@closed_world.standard_constructor_lookup? then 'new or allocate may be redefined'
      elsif !numeric_allocate_free? || slot_world_names?('allocate') then 'allocate is named'
      elsif (reason = slot_opening_call) then reason
      elsif slot_world_names?('remove_instance_variable') then 'remove_instance_variable is named'
      end
  end

  # Why code the scans do not see could run, or every object be reached (each_object), or nil.
  def slot_opening_call
    return 'each_object is defined and named' if slot_name_definable?('each_object') && slot_world_names?('each_object')
    return nil unless slot_name_definable?('eval')
    return 'eval is defined and named' if slot_world_names?('eval')

    SLOT_ASSURED_STRING_EVALS.each do |name|
      next unless slot_name_definable?(name)
      return "#{name} is named outside" if @closed_world.foreign_ruby_token_files.each_value.any? { |tokens| tokens.include?(name) }

      @ireps.each_value do |irep|
        BytecodeIR.for(irep).each_source do |insn, idx|
          next unless insn.sym.to_s == name
          next if BytecodeIR::Ops::SEND_FAMILY.include?(insn.op) && literal_block_argument?(irep, idx, insn)

          return "#{name} without a literal block in #{irep.label}"
        end
      end
    end
    nil
  end

  # Some definition (or an invisible definer) answers +name+.
  def slot_name_definable?(name)
    !@registry.fetch(name, []).empty? || @closed_world.invisibly_definable?(name)
  end

  # Does any bytecode (as a send, Symbol or String) or foreign Ruby source spell +name+?
  def slot_world_names?(name)
    @slot_world_names ||= {}
    return @slot_world_names[name] if @slot_world_names.key?(name)

    @slot_world_names[name] = @closed_world.foreign_ruby_token_files.each_value.any? { |tokens| tokens.include?(name) } ||
                              @ireps.each_value.any? do |irep|
                                BytecodeIR.for(irep).each_source.any? do |insn, _index|
                                  insn.sym.to_s == name ||
                                    (insn.op == :STRING && irep.pool[insn.pool_index.to_i].to_s == name)
                                end
                              end
  end

  def slot_family_facts(root)
    hierarchy = @closed_world.class_hierarchy(root)
    return 'class hierarchy unknown' unless hierarchy && hierarchy[:wild].empty?

    family = [root] + hierarchy[:descendants].to_a.sort
    return 'a family class is spelled outside' if family.any? { |k| @closed_world.outside_spells_class?(k) }

    reach = Set.new
    names = Set.new
    inits = {}
    family.each do |klass|
      chain = slot_chain(klass)
      return "#{klass}: #{chain}" if chain.is_a?(String)

      init = slot_initialize(klass)
      return "#{klass}: #initialize #{init}" if init.is_a?(String)

      reason = slot_reach(init, chain, reach, names)
      return "#{klass}: #{reason}" if reason

      inits[klass] = [init, chain].freeze
    end
    subtrees = family.to_h { |k| [k, [k] + family.select { |d| slot_ancestor?(k, d) }] }
    SlotFacts.new(inits: inits.freeze, subtrees: subtrees.freeze, reach: reach.freeze, names: names.freeze)
  end

  def slot_ancestor?(klass, descendant)
    seen = Set.new
    current = @superclass_of[descendant]
    while current.is_a?(String) && seen.add?(current)
      return true if current == klass

      current = @superclass_of[current]
    end
    false
  end

  # The #initialize instances of +klass+ run: a MethodDef with a body, or why there is none.
  def slot_initialize(klass)
    seen = Set.new
    while klass.is_a?(String) && seen.add?(klass)
      definition = numeric_init_definition(klass)
      return 'is not a single bytecode definition' if definition == :unknown
      return definition if definition

      klass = @superclass_of[klass]
    end
    'is not defined in Ruby'
  end

  # The method-lookup order of an instance of +klass+, as [owner, sealed] pairs, or why it is unknown. A sealed
  # owner is declared in Ruby and spelled by no outside source, so only the registry's definitions sit on it.
  def slot_chain(klass)
    @slot_chains ||= {}
    @slot_chains.fetch(klass) { @slot_chains[klass] = slot_chain_uncached(klass) }
  end

  def slot_chain_uncached(klass)
    chain = []
    current = klass
    while current.is_a?(String) && chain.none? { |owner, _| owner == current }
      return "#{current} has an unknown mixin" if @unknown_mixins.include?(current)
      return "#{current} has a prepended module" unless Array(@prepended_modules[current]).empty?

      chain << [current, slot_sealed?(current)]
      # The last included module is searched first; a module's own includes follow it.
      modules = Array(@included_modules[current]).reverse
      until modules.empty?
        mod = modules.shift
        next if chain.any? { |owner, _| owner == mod }
        return "#{mod} has an unknown mixin" if @unknown_mixins.include?(mod)
        return "#{mod} has a prepended module" unless Array(@prepended_modules[mod]).empty?

        chain << [mod, slot_sealed?(mod)]
        modules = Array(@included_modules[mod]).reverse + modules
      end
      current = @superclass_of[current]
    end
    return "#{klass}'s superclass chain is unresolved" unless current == :none

    (chain + %w[Object Kernel BasicObject].map { |owner| [owner, false] }).freeze
  end

  def slot_sealed?(owner)
    (@closed_world.class_declared?(owner) || @closed_world.module_declared?(owner)) &&
      !@closed_world.outside_spells_class?(owner)
  end

  # What a self-call of +name+ on an instance with lookup +chain+ reaches (a SlotTarget), or why it may reach
  # code the walk cannot follow. No definition at all raises NoMethodError, whose message names only the class,
  # unless a method_missing answers it.
  def slot_resolve(name, chain)
    return "#{name} has a computed definer" if @closed_world.unknown_def?(name)

    defs = @registry.fetch(name, [])
    native = defs.any? { |d| d.irep.nil? && d.kind != :ivar_accessor } || @closed_world.invisibly_definable?(name)
    chain.each_with_index do |(owner, sealed), i|
      if native && !sealed
        extra = SLOT_ASSURED_NATIVE_SELF_CALLS[name] or return "native self-call #{name}"
        later = chain.drop(i).map(&:first)
        return SlotTarget.new(defs: defs.select { |d| d.irep && later.include?(d.owner) }, extra: extra, exact: false)
      end
      here = defs.select { |d| d.owner == owner && (d.irep || d.kind == :ivar_accessor) }
      next if here.empty?

      ruby = here.select(&:irep)
      return SlotTarget.new(defs: ruby, extra: [], exact: here.one? && ruby.one?)
    end
    SlotTarget.new(defs: [], extra: %w[method_missing inspect to_s], exact: false)
  end

  # Adds the ireps that may run with `self` = an instance under construction, starting at +init+, to +reach+,
  # and the names they self-call to +names+. Resolution depends on +chain+, so each class walks on its own. A
  # callee is walked once per binding of literal arguments (slot_call_binding), which may leave arms dead.
  def slot_reach(init, chain, reach, names)
    visited = Set.new
    targets = {}
    queue = [[init.irep, nil]]
    until queue.empty?
      label, binding = queue.shift
      next unless visited.add?([label, binding])

      reach << label
      irep = @ireps[label] or return "#{label} has no bytecode"
      live = slot_live_indices(irep, binding) or return "#{label}: control flow unresolved"
      BytecodeIR.for(irep).each_source do |insn, idx|
        next unless live.include?(idx)

        reason = slot_reach_insn(insn, idx, irep, chain, targets, names, queue)
        return reason if reason
      end
    end
    nil
  end

  def slot_reach_insn(insn, idx, irep, chain, targets, names, queue)
    op = insn.op
    return "#{op} in #{irep.label}" if SLOT_ASSURED_EXPOSING.include?(op)
    return "#{op} reads self in #{irep.label}" if insn.regs.include?(0) && !SLOT_ASSURED_SELF_OPERAND_OK.include?(op)

    if BytecodeIR::Ops::LITERAL_PROC.include?(op)
      # Proc#binding then Binding#receiver would hand the block's self out.
      return "#{op} in #{irep.label} while binding and receiver are named" if
        slot_world_names?('binding') && slot_world_names?('receiver')

      child = Array(irep.reps)[insn.block_index.to_i] or return "#{op} without a child in #{irep.label}"
      queue << [child, nil]
      return nil
    end
    if op == :SUPER
      owner = numeric_irep_owner[irep.label] or return "super outside a method in #{irep.label}"
      return slot_reach_super(owner, chain, queue)
    end
    return nil unless BytecodeIR::Ops::SELF_SEND_FAMILY.include?(op)

    called = [insn.sym.to_s]
    if SLOT_ASSURED_NAMED_DISPATCH.include?(called.first)
      symbols = slot_reach_symbol_args(irep, idx, insn) or return "#{called.first} with a computed name in #{irep.label}"
      called.concat(symbols)
    end
    first = true
    until called.empty?
      name = called.shift
      names << name
      return 'Method#receiver is named' if name == 'method' && slot_world_names?('receiver')

      target = (targets[name] ||= slot_resolve(name, chain))
      return target if target.is_a?(String)

      binding = first && target.exact ? slot_call_binding(irep, idx, insn, target.defs.first) : nil
      target.defs.each { |d| queue << [d.irep, binding] }
      # Method#super_method reaches the ancestors' definitions too.
      slot_chain_defs(name, chain).each { |d| queue << [d.irep, nil] } if !first && insn.sym.to_s == 'method'
      called.concat(target.extra)
      first = false
    end
    nil
  end

  # `super` reaches the ancestors' definitions of the method's own name. For #initialize, a native one can only be
  # BasicObject's no-op: every other class on the chain is sealed (slot_family_facts refuses an outside-spelled one).
  def slot_reach_super(owner, chain, queue)
    unless owner.name == 'initialize'
      target = slot_resolve(owner.name, chain)
      return target if target.is_a?(String)
    end
    slot_chain_defs(owner.name, chain).each { |d| queue << [d.irep, nil] }
    nil
  end

  def slot_chain_defs(name, chain)
    owners = chain.map(&:first)
    @registry.fetch(name, []).select { |d| d.irep && owners.include?(d.owner) }
  end

  # The literal Symbols a named-dispatch self-call passes as its first argument, or nil.
  def slot_reach_symbol_args(irep, idx, insn)
    return nil unless insn.reg && insn.argc&.positive?

    writers = BytecodeIR.reaching_writer_indices(irep, idx, insn.reg + 1) or return nil
    program = BytecodeIR.for(irep)
    writers.map do |i|
      writer = program.source_at(i)
      return nil unless writer.op == :LOADSYM

      writer.sym.to_s
    end
  end

  # Is @ivar assigned on every normal exit of the method +label+, on an instance with lookup +chain+? A self-call or
  # `super` counts when its exact target assigns it. A raise is not a normal exit, so a handler starts from the
  # state before the instruction that raised.
  def slot_assigns_on_exit?(label, ivar, chain, stack)
    key = [label, ivar, chain]
    @slot_assigns ||= {}
    return @slot_assigns[key] if @slot_assigns.key?(key)
    return false if stack.include?(label)

    @slot_assigns[key] = slot_assigns_on_exit_uncached?(label, ivar, chain, stack + [label])
  end

  def slot_assigns_on_exit_uncached?(label, ivar, chain, stack)
    irep = @ireps[label] or return false
    program = BytecodeIR.for(irep)
    normal = program.instruction_predecessors(include_handlers: false) or return false
    return false unless program.handlers_resolved?
    # A block's `return` leaves this method from inside a call.
    return false if slot_nested_labels(irep).any? { |l| @ireps[l] && BytecodeIR.for(@ireps[l]).op?(:RETURN_BLK) }

    gens = program.instructions.map { |instruction| slot_assigning?(instruction.source, label, ivar, chain, stack) }
    raised_from = Hash.new { |h, k| h[k] = [] }
    program.handler_edges.each { |edge| raised_from[edge.target] << edge.src }
    count = program.instructions.length
    in_state = Array.new(count, true)
    out_state = Array.new(count, true)
    changed = true
    while changed
      changed = false
      program.instructions.each do |instruction|
        i = instruction.index
        incoming = normal[i].map { |p| p == BytecodeIR::ENTRY ? false : out_state[p] }
        incoming.concat(raised_from[i].map { |src| in_state[src] })
        in_i = incoming.empty? || incoming.all?
        out_i = in_i || gens[i]
        next if in_state[i] == in_i && out_state[i] == out_i

        in_state[i] = in_i
        out_state[i] = out_i
        changed = true
      end
    end
    program.instructions.all? do |instruction|
      !SLOT_ASSURED_NORMAL_EXIT.include?(instruction.source.op) || in_state[instruction.index]
    end
  end

  def slot_assigning?(insn, label, ivar, chain, stack)
    return true if insn.op == :SETIV && insn.ivar.to_s == ivar

    if insn.op == :SUPER
      owner = numeric_irep_owner[label]
      target = owner && slot_super_target(label, owner)
      return target ? slot_assigns_on_exit?(target.irep, ivar, chain, stack) : false
    end
    return false unless BytecodeIR::Ops::SELF_SEND_FAMILY.include?(insn.op)

    target = slot_resolve(insn.sym.to_s, chain)
    return false if target.is_a?(String) || !target.exact

    slot_assigns_on_exit?(target.defs.first.irep, ivar, chain, stack)
  end

  # The one definition `super` in the method +owner+ reaches: the nearest superclass's, when no module sits
  # between. Only the method's own body (not a block in it) is resolved.
  def slot_super_target(label, owner)
    return nil unless @owner_of[label] == owner && super_reaches_superclass?(owner)

    defs = @registry.fetch(owner.name, [])
    klass = @superclass_of[owner.owner]
    seen = Set.new
    while klass.is_a?(String) && seen.add?(klass)
      return nil unless slot_sealed?(klass) && Array(@included_modules[klass]).empty?

      own = defs.select { |d| d.owner == klass }
      return own.one? && own.first.irep ? own.first : nil unless own.empty?

      klass = @superclass_of[klass]
    end
    nil
  end

  def slot_nested_labels(irep)
    out = []
    stack = Array(irep.reps).dup
    until stack.empty?
      label = stack.pop
      out << label
      stack.concat(Array(@ireps[label]&.reps))
    end
    out
  end
end
