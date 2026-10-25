# frozen_string_literal: true

require 'set'
require_relative 'bytecode_ir_containers'
require_relative 'irep_arity'

# CLASS_OBJECT_ARGS: a `klass.new` whose receiver is a parameter of a method (or a captured one) names the
# class constants its callers pass, so a generic `klass.new` helper no longer withdraws every initialize that takes
# its argument count (constructor_new_site). Each condition is a negative in
# scripts/bc2cpp/class_object_args_check.rb. BC2CPP_CLASS_OBJECT_ARGS=0 turns it off.
class CodeGen
  CLASS_OBJECT_ARGS_DEPTH = 3
  # Ops that name a method without making a plain positional call; a call index entry of one of them poisons the name.
  CLASS_OBJECT_DEFINING_OPS = Set[:DEF, :SDEF, :TDEF].freeze
  CLASS_OBJECT_CALL_OPS = Set[:SEND, :SENDB, :SSEND, :SSENDB, :SEND0, :SSEND0].freeze

  def class_object_args_enabled?
    ENV.fetch('BC2CPP_CLASS_OBJECT_ARGS', '1') != '0'
  end

  # The classes (full paths) the receiver register +reg+ of the `new` at +idx+ can hold, or nil when any definition
  # reaching it is not provably a class constant or a stable parameter that only class constants reach.
  def class_object_receiver_classes(irep, idx, insn)
    return nil unless class_object_args_enabled? && @foreign_method_names && @closed_world

    classes = class_object_values(irep, idx, insn.reg, 0, Set.new)
    classes && classes.to_a.sort
  end

  private

  # Set of class paths register +reg+ holds at +idx+ in +irep+, or nil.
  def class_object_values(irep, idx, reg, depth, active)
    return nil if depth > CLASS_OBJECT_ARGS_DEPTH

    defs = BytecodeIR.reaching_definitions(irep, idx, reg, through_handlers: true, shared: true)
    return nil if defs.nil? || defs.empty?

    values = Set.new
    defs.each do |definition|
      found = if definition.entry?
                class_object_param_values(irep, definition.reg, depth, active)
              else
                class_object_writer_values(irep, BytecodeIR.for(irep).source_at(definition.index), depth, active)
              end
      return nil unless found

      values.merge(found)
    end
    values
  end

  def class_object_writer_values(irep, writer, depth, active)
    case writer.op
    when :GETCONST, :GETMCNST
      name = writer.const_name
      return nil unless name && @closed_world.class_valued_constant?(name)

      @closed_world.classes_named(name)
    when :GETUPVAR
      index, level = writer.upvar_ref
      return nil unless index

      # No send of the build can write a local by name.
      return nil unless captured_local_class_enabled?

      ancestor, = captured_local_frame(irep, level)
      return nil unless ancestor && class_object_param_stable?(ancestor, index)

      class_object_param_values(ancestor, index.to_s, depth, active)
    end
  end

  # The classes passed at parameter +reg+ of +irep+ (a method body) by every call that can enter it.
  def class_object_param_values(irep, reg, depth, active)
    d = @owner_of[irep.label]
    return nil unless d && d.irep == irep.label && irep.equal?(@ireps[d.irep])

    k = reg.to_i
    return nil unless k.positive? && pure_mandatory_arity?(irep) && k <= mandatory_arity(irep)

    key = [d.irep, k]
    @class_object_param_cache ||= {}
    return @class_object_param_cache[key] if @class_object_param_cache.key?(key)
    return nil if active.include?(key)

    active.add(key)
    result = compute_class_object_param_values(d, irep, k, depth, active)
    active.delete(key)
    # Only an answer is kept: a refusal may come from a bound (the depth, a cycle) and says nothing about the parameter.
    @class_object_param_cache[key] = result if result
    result
  end

  def compute_class_object_param_values(d, irep, k, depth, active)
    return nil unless class_object_name_admitted?(d)

    sites = class_object_call_sites(d.name)
    return nil unless sites

    mand = mandatory_arity(irep)
    values = Set.new
    sites.each do |(site_irep, site_idx, recv, argc)|
      next unless argc == mand

      found = class_object_values(site_irep, site_idx, (recv + k).to_s, depth + 1, active)
      return nil unless found

      values.merge(found)
    end
    values.empty? ? nil : values
  end

  # The by-name enumeration of ENTRY_ARG_CALLSITE_PROOF (rules 2-5 and 7) without its single-definition rule, which
  # the arity filter and the `super` check replace.
  def class_object_name_admitted?(d)
    name = d.name
    return false if name == 'initialize' || name !~ /\A[A-Za-z_]/
    return false if @foreign_method_names.include?(name) || @closed_world.unknown_def?(name)
    return false if class_object_called_outside?(name) || numeric_dynamically_named?(name)

    defs = @registry[name] || []
    return false unless defs.include?(d) && d.irep && !d.core

    # Another definition of the name that calls `super` can reach this body with arguments no call site shows.
    defs.none? { |other| !other.equal?(d) && class_object_super_in?(other) }
  end

  # Can code outside the analysed bytecode call +name+: a native funcall or a foreign Ruby identifier names it, or an
  # outside native source spells it as anything but a registration's name. The call-name test of SETTER_POOLS; a name that is only a C identifier is not one (ENTRY_ARG_CALLSITE_PROOF's blunter token rule refuses it).
  def class_object_called_outside?(name)
    @class_object_outside_names ||= @closed_world.outside_call_names(@ireps.values.to_set(&:file))
    @class_object_outside_names.include?(name) || @closed_world.outside_native_literal?(name)
  end

  # Does the body of +definition+ (nested blocks included) contain a SUPER? A native or accessor definition has no body.
  def class_object_super_in?(definition)
    return false unless definition.irep

    stack = [definition.irep]
    seen = Set.new
    until stack.empty?
      label = stack.pop
      next unless seen.add?(label)

      irep = @ireps[label] or return true
      return true if BytecodeIR.for(irep).op?(:SUPER)

      stack.concat(Array(irep.reps))
    end
    false
  end

  # [irep, index, receiver register, argc] of every plain positional call of +name+, or nil when the name is poisoned: a
  # mention that is not such a call (a Symbol, an alias, a splat or keyword call) can reach a body with arguments nobody
  # sees. Calls with SEND0/SSEND0 are zero-argument sites; none of them can enter a body that takes an argument.
  def class_object_call_sites(name)
    @class_object_call_index ||= build_class_object_call_index
    @class_object_call_index[:sites][name] unless @class_object_call_index[:poisoned].include?(name)
  end

  def build_class_object_call_index
    sites = Hash.new { |h, k| h[k] = [] }
    poisoned = Set.new
    @ireps.each_value do |irep|
      BytecodeIR.for(irep).each_source do |insn, i|
        name = insn.sym
        next unless name
        next if CLASS_OBJECT_DEFINING_OPS.include?(insn.op)

        # `alias new old` reaches old's body through `new`; both names are poisoned.
        if insn.op == :ALIAS
          old = insn.first_of(:name)&.value
          poisoned << old if old
          poisoned << name
          next
        end
        unless CLASS_OBJECT_CALL_OPS.include?(insn.op)
          poisoned << name
          next
        end

        zero = insn.op.to_s.end_with?('0')
        if insn.reg.nil? || !(zero || insn.plain_fixed_argc?)
          poisoned << name
          next
        end

        sites[name] << [irep, i, insn.reg.to_i, zero ? 0 : insn.argc]
      end
    end
    { sites: sites, poisoned: poisoned }
  end

  # Parameter +index+ of +ancestor+ (a method body) is never rewritten, so a block that reads it later sees its entry
  # value: the register has the entry definition alone at every instruction, and no nested block writes it.
  def class_object_param_stable?(ancestor, index)
    d = @owner_of[ancestor.label]
    return false unless d && d.irep == ancestor.label && index.positive? && index <= mandatory_arity(ancestor)
    return false unless pure_mandatory_arity?(ancestor)

    # The write test of rbs_param_check.rb's upvar_why, without a reaching-definitions walk per instruction. A RETURN
    # of the register writes nothing a later instruction reads, so the NO_WRITE_OPS are not writes here.
    reg = index.to_s
    return false if BytecodeIR.own_upvar_written_regs(ancestor).include?(reg)

    program = BytecodeIR.for(ancestor)
    program.each_source.none? do |insn, i|
      op = insn.op
      op != :ENTER && !NumericFlow::NO_WRITE_OPS.include?(op) && program.may_write_at?(i, reg)
    end
  end
end
