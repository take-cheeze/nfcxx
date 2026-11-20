# frozen_string_literal: true

require 'set'
require_relative 'bytecode_ir_ops'
require_relative 'bytecode_ir'
require_relative 'bytecode_ir_tree'
require_relative 'core_hierarchy_sigs'

# RECORD_FIELD_TRACE: the classes a value stored into a declared record field can have, for RbsRecordTypes'
# conformance check. Beyond RbsRecordTypes.value_class_at (literals, `Klass.new`, the ClassLayout Array rule) a value
# is traced through
#   joins and moves     every reaching definition, each traced;
#   `@ivar` reads       every SETIV of the name anywhere in the program, plus nil (an unset ivar), when no reflection,
#                       attr_writer or outside source can write it (RecordHash::Poison, outside_ivar_names);
#   program calls       the union of the returns of EVERY definition of the name, so the receiver need not be known:
#                       refused when a definition is native, core, outside the program, installed by a computed name,
#                       or reachable through method_missing (closed world);
#   calls on a traced receiver the definitions its exact classes reach (EscapeAnalysis::World#defs_for) when no
#                       native one sits on their lookup chains; a core block iterator (`recv.map { }`) by
#                       block_result_array?. A nil receiver is dropped when nothing nil answers through defines the
#                       name (the call raises instead).
# A literal block of the send must not `break` (OP_BREAK makes the send evaluate to its operand), and a body whose
# blocks `return` (RETURN_BLK) is refused. Anything else is nil (cannot be traced), which keeps the TC1009 error.
module RbsRecordTypes
  class ValueTrace
    MAX_DEPTH = 24
    MAX_ROUNDS = 8
    CLOSURE_OPS = %i[BLOCK LAMBDA].freeze
    EMPTY = Set.new.freeze
    UNKNOWN = :unknown

    # +exact+: no class hint enters (trace_new_target, the block arm of the ClassLayout Array rule), so the result is a
    # proof, not a guarded hint.
    def initialize(ctx, exact: false)
      @ctx = ctx
      @exact = exact
      @ireps = ctx[:ireps] || {}
      @assume = {}
      @setiv = nil
    end

    # Set of class names the instruction at +index+ leaves in +reg+, or nil. Recursion (a method whose result flows
    # back into a call of itself, an ivar stored from its own read, a loop) is solved by iteration from the empty set:
    # every round assumes the previous round's results for the values still being computed, and the answer is kept
    # only once a round reproduces every assumption it read. Each step is sound whenever its assumptions cover the
    # values of runs up to some depth, so by induction on that depth a fixpoint covers every run.
    def classes_at(irep, index, reg)
      MAX_ROUNDS.times do
        @memo = {}
        @active = Set.new
        @read = Set.new
        @changed = false
        result = def_classes(irep, index, reg, 0)
        return result unless @changed
      end
      nil
    end

    # Set of class names +reg+ can hold when read at +use+, or nil.
    def reg_classes(irep, use, reg, depth)
      defs = BytecodeIR.reaching_definitions(irep, use, reg, through_handlers: true, shared: true)
      return nil if defs.nil? || defs.empty?

      out = Set.new
      defs.each do |d|
        return nil if d.entry?

        classes = def_classes(irep, d.index, d.reg, depth)
        return nil unless classes

        out.merge(classes)
      end
      out
    end

    def def_classes(irep, index, reg, depth)
      fix([irep.label, index, reg], depth) { compute(irep, index, reg, depth) }
    end

    # The value of +key+ in this round: memoized, the previous round's (or the empty set) while it is being
    # computed, nil past the depth bound.
    def fix(key, depth)
      return @memo[key] if @memo.key?(key)
      if @active.include?(key)
        @read << key
        prior = @assume.fetch(key, EMPTY)
        return prior == UNKNOWN ? nil : prior
      end
      return nil if depth > MAX_DEPTH

      @active << key
      begin
        result = yield
      ensure
        @active.delete(key)
      end
      stored = result.nil? ? UNKNOWN : result
      @changed = true if @read.include?(key) && @assume.fetch(key, EMPTY) != stored
      @assume[key] = stored
      @memo[key] = result
    end

    private

    def compute(irep, index, reg, depth)
      insn = BytecodeIR.for(irep).source_at(index)
      base = @exact ? exact_base(irep, index, reg, insn) : RbsRecordTypes.value_class_at(irep, index, reg, @ctx)
      return Set[base] if base

      case insn.op
      when :MOVE then reg_classes(irep, index, insn.regs[1], depth + 1)
      when :GETIV then insn.ivar && ivar_classes(insn.ivar, self_owner(irep), depth + 1)
      else
        send_classes(irep, index, insn, depth + 1) if BytecodeIR::Ops::SEND.include?(insn.op) && insn.sym
      end
    end

    # A literal, or a non-block send the ClassLayout Array rule proves without a hint (a core fresh-Array result).
    def exact_base(irep, index, reg, insn)
      literal = RbsRecordTypes::LITERAL_CLASS.call(irep, index)
      return literal if literal
      return nil unless BytecodeIR::Ops::SEND.include?(insn.op) && !BytecodeIR::Ops::BLOCK_SEND_FAMILY.include?(insn.op)

      @ctx[:value_class]&.call(irep, index + 1, reg)
    end

    def send_classes(irep, index, insn, depth)
      name = insn.sym
      block = BytecodeIR::Ops::BLOCK_SEND_FAMILY.include?(insn.op)
      return nil if block && !break_free_block?(irep, index, insn)

      unless BytecodeIR::Ops::SELF_SEND_FAMILY.include?(insn.op)
        recv = reg_classes(irep, index, insn.reg.to_i, depth)
        recv -= ['NilClass'] if recv && nil_raises?(name)
        if recv && !recv.empty?
          if block && defined?(BLOCK_RESULT_NAMES) && BLOCK_RESULT_NAMES.include?(name) && recv.size == 1 &&
             block_result_array?(name, recv.first, @ctx[:registry])
            return Set['Array']
          end
          scoped = receiver_returns(name, recv, depth)
          return scoped if scoped
        end
      end
      program_returns(name, depth)
    end

    # The union of what the definitions a call of +name+ reaches on receivers of exactly +classes+ return
    # (EscapeAnalysis::World#defs_for), when no native definition sits on any of their lookup chains.
    def receiver_returns(name, classes, depth)
      cw = @ctx[:closed_world]
      world = @ctx[:escape_world]
      return nil unless cw && world && !cw.global_refusal && cw.method_missing_classes.empty?
      return nil if cw.unknown_def?(name) || cw.outside_ruby_name?(name)

      classes.each do |klass|
        chain = world.ancestry(klass)
        return nil unless chain && world.native_free_on?(name, chain)
      end
      defs = world.defs_for(name, classes.to_a, true)
      return nil if defs.nil? || defs.empty?

      out = Set.new
      defs.each do |d|
        found = definition_returns(d, depth)
        return nil unless found

        out.merge(found)
      end
      out
    end

    # The block operand is not a literal block of this frame, or that block has no BREAK of its own (a `break` in a
    # nested block ends the nested call; one in a forwarded block unwinds past this send).
    def break_free_block?(irep, index, insn)
      return false unless insn.plain_fixed_argc?

      block_reg = insn.reg.to_i + insn.argc.to_i + 1
      defs = BytecodeIR.reaching_definitions(irep, index, block_reg, through_handlers: true, shared: true)
      return false if defs.nil? || defs.empty?

      defs.all? do |d|
        next true if d.entry?

        src = BytecodeIR.for(irep).source_at(d.index)
        next true unless CLOSURE_OPS.include?(src.op)

        child = @ireps[irep.reps[src.block_index.to_i]]
        child && !BytecodeIR.for(child).op?(:BREAK)
      end
    end

    # A nil receiver raises NoMethodError: nothing nil answers through defines +name+, natively or in Ruby.
    def nil_raises?(name)
      cw = @ctx[:closed_world]
      world = @ctx[:escape_world]
      owners = CoreHierarchySigs.ancestors('NilClass')
      return false unless cw && world && cw.method_missing_classes.empty? && cw.nil_foreign_definition_free?(name, owners)

      chain = world.ancestry('NilClass')
      chain && world.native_free_on?(name, chain) &&
        (@ctx[:registry][name] || []).none? { |d| owners.include?(d.owner) || d.owner.start_with?('<') && d.owner != '<native>' }
    end

    # The union of what every definition of +name+ in the closed world returns, or nil.
    def program_returns(name, depth)
      fix([:returns, name], depth) { compute_program_returns(name, depth) }
    end

    def compute_program_returns(name, depth)
      cw = @ctx[:closed_world]
      world = @ctx[:escape_world]
      return nil unless cw && world && !cw.global_refusal
      return nil if cw.unknown_def?(name) || cw.outside_ruby_name?(name) || world.native_name?(name)
      return nil unless cw.method_missing_classes.empty?

      defs = world.defs_named(name)
      return nil if defs.nil? || defs.empty?

      out = Set.new
      defs.each do |d|
        classes = definition_returns(d, depth)
        return nil unless classes

        out.merge(classes)
      end
      out
    end

    def definition_returns(defn, depth)
      return nil if defn.installer || defn.core || defn.owner.to_s.start_with?('<')

      if defn.kind == :ivar_accessor
        return nil if defn.name.end_with?('=')

        return ivar_classes(defn.name, defn.owner, depth)
      end
      label = defn.irep || (defn.kind == :module_function ? defn.copy_irep : nil)
      body = label && @ireps[label]
      return nil unless body && (defn.kind.nil? || defn.kind == :module_function)

      body_returns(body, depth)
    end

    def body_returns(body, depth)
      nested_return = false
      BytecodeIR::Tree.each_subtree(body, @ireps, CLOSURE_OPS) do |child, level|
        nested_return ||= level.positive? && BytecodeIR.for(child).op?(:RETURN_BLK)
      end
      return nil if nested_return

      out = Set.new
      prog = BytecodeIR.for(body)
      prog.each_with_op(*BytecodeIR::Ops::FRAME_EXIT) do |insn, i|
        classes = case insn.op
                  when :RETURN then reg_classes(body, i, insn.reg.to_i, depth + 1)
                  when :RETNIL then Set['NilClass']
                  when :RETTRUE then Set['TrueClass']
                  when :RETFALSE then Set['FalseClass']
                  end
        return nil unless classes

        out.merge(classes)
      end
      out
    end

    # Every SETIV of +name+ that can run on an instance of +owner+ (or of a subclass), plus nil (an unset ivar), when
    # nothing else can write the ivar. Without a placeable owner every SETIV of the name counts.
    def ivar_classes(name, owner, depth)
      related = related_owners(owner)
      fix([:ivar, name, related], depth) { compute_ivar_classes(name, related, depth) }
    end

    def compute_ivar_classes(name, related, depth)
      poison = @ctx[:poison]
      return nil if poison.nil? || poison.global || poison.write_reason(name) || @ctx[:outside_ivars]&.include?(name)

      out = Set['NilClass']
      setiv_sites[name].each do |irep, i|
        next if related && unrelated_self?(irep, related)

        classes = reg_classes(irep, i, BytecodeIR.for(irep).source_at(i).regs.first, depth + 1)
        return nil unless classes

        out.merge(classes)
      end
      out
    end

    # The class whose instance is self in +irep+ (a method body or a block that keeps its creator's self), or nil.
    def self_owner(irep)
      owner = @ctx[:owner_of]&.[](irep.label)
      cw = @ctx[:closed_world]
      return nil unless owner && cw
      return nil if irep.label != owner_body_label(irep) && cw.lexical_self_rebound?(irep.label)

      owner
    end

    def owner_body_label(irep)
      @method_labels ||= @ctx[:registry].values.flatten.filter_map(&:irep).to_set
      @method_labels.include?(irep.label) ? irep.label : nil
    end

    # Owners whose method bodies can run with self an instance of +owner+ or of a subclass: the lookup chains of those
    # classes. nil (every SETIV counts) when +owner+ is not a placeable program class.
    def related_owners(owner)
      world = @ctx[:escape_world]
      cw = @ctx[:closed_world]
      return nil unless owner && world && cw && world.plain_class?(owner) && cw.class_declared?(owner)

      @related ||= {}
      return @related[owner] if @related.key?(owner)

      chains = ([owner] + subclasses_of(owner)).map { |klass| world.ancestry(klass) }
      @related[owner] = chains.all? ? chains.flatten.to_set.freeze : nil
    end

    def subclasses_of(owner)
      @children ||= (@ctx[:superclass_of] || {}).each_with_object(Hash.new { |h, k| h[k] = [] }) do |(k, sup), h|
        h[sup] << k if sup.is_a?(String)
      end
      out = []
      stack = [owner]
      until stack.empty?
        @children[stack.pop].each do |c|
          next if out.include?(c)

          out << c
          stack << c
        end
      end
      out
    end

    # A SETIV whose self cannot be an instance of the related classes: a method body (or a block keeping its
    # creator's self) of an unrelated plain owner. Unplaced bodies, scoped definitions and rebound blocks count.
    def unrelated_self?(irep, related)
      owner = self_owner(irep)
      return false unless owner && !owner.start_with?('<')

      !related.include?(owner) && !owner.end_with?('.singleton')
    end

    def setiv_sites
      @setiv ||= begin
        sites = Hash.new { |h, k| h[k] = [] }
        @ireps.each_value do |irep|
          irep.each_with_op(:SETIV) { |insn, i| sites[insn.ivar] << [irep, i] if insn.ivar }
        end
        sites
      end
    end
  end
end
