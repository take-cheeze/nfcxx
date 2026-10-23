# frozen_string_literal: true

require 'set'
require_relative 'bytecode_ir'

# CodeGen: CALLEE_RETURN_FOLD, behind BC2CPP_RETURN_FOLD=1.
#
# A conditional jump on the result of a call is decided when every definition the call can reach returns a literal
# true, false or nil. The NumericFlow mask cannot say this: TrueClass and FalseClass are OTHER, so `if ok?` with
# `def ok?; true; end` keeps its test. The jump is decided through decided_branch_outcome (codegen_decided_branch.rb), so
# the emitter and the arm pruner agree.
#
# Admission for a name, as for the Fixnum return proof: the name is fully visible to the closed world, not foreign,
# not aliased, not installed by a symbol and not reachable by a computed name, so a call reaches only the registered
# bodies. Every body is bytecode with no catch handler and no non-local exit, and each of its return sources is a
# LOADTRUE, LOADFALSE, LOADNIL or a fall-through of a nil. A call that raises yields no value, so it takes no edge.
# Only SEND/SEND0/SSEND/SSEND0 results are read: a SENDB result is the value of a `break` out of its block.
class CodeGen
  def return_fold_enabled?
    ENV['BC2CPP_RETURN_FOLD'] == '1'
  end

  RETURN_FOLD_CALL_OPS = %w[SEND SEND0 SSEND SSEND0].freeze
  RETURN_FOLD_LITERALS = { 'LOADTRUE' => :true, 'LOADFALSE' => :false, 'LOADNIL' => :nil }.freeze

  # :taken or :not_taken for the jump +insn+ at +idx+ of +irep+ decided by its call result's literal kinds, else nil.
  def callee_return_outcome(insn, irep, idx)
    return nil unless return_fold_enabled? && idx

    kinds = call_result_literal_kinds(irep, idx, insn.reg.to_s)
    return nil unless kinds

    # JMPNIL is taken exactly on nil; a result that is never nil never takes it.
    if insn.op == 'JMPNIL'
      return :taken if kinds == Set[:nil]

      return :not_taken unless kinds.include?(:nil)

      return nil
    end

    truthy = kinds.subset?(Set[:true])
    falsy = kinds.subset?(Set[:false, :nil])
    return nil unless truthy || falsy

    jumps = truthy == (insn.op == 'JMPIF')
    jumps ? :taken : :not_taken
  end

  # The literal kinds every writer of +reg+ at +idx+ can carry, or nil when one is not a proven call result.
  def call_result_literal_kinds(irep, idx, reg)
    writers = BytecodeIR.writers_reaching(irep, idx, reg)
    return nil unless writers && !writers.empty?

    kinds = Set.new
    writers.each do |_writer_index, writer|
      return nil unless RETURN_FOLD_CALL_OPS.include?(writer.op)

      written = callee_literal_kinds(writer.sym)
      return nil unless written

      kinds |= written
    end
    kinds
  end

  # The literal kinds a call to +name+ can return, or nil. Memoized: a name's definitions are fixed once the closed
  # world is built.
  def callee_literal_kinds(name)
    @callee_literal_kinds ||= {}
    return @callee_literal_kinds[name] if @callee_literal_kinds.key?(name)

    @callee_literal_kinds[name] = compute_callee_literal_kinds(name)
  end

  def compute_callee_literal_kinds(name)
    return nil unless name && @foreign_method_names && @closed_world && @closed_world.global_refusal.nil?
    return nil unless @closed_world.name_fully_visible?(name)
    return nil if name == 'initialize' || @foreign_method_names.include?(name) || numeric_aliased_names.include?(name)
    return nil if numeric_dynamically_named?(name)

    installed = symbol_installed_names
    return nil if installed.nil? || installed.include?(name)

    defs = return_table_definitions(name)
    return nil if defs.empty?

    kinds = Set.new
    defs.each do |d|
      return nil if d.owner.start_with?('<') || d.irep.nil? || @ireps[d.irep].nil?

      body = callee_body_literal_kinds(@ireps[d.irep])
      return nil unless body

      kinds |= body
    end
    kinds
  end

  # The literal kinds one body returns, or nil when one of its return paths is not a literal.
  def callee_body_literal_kinds(irep)
    return nil unless (irep.catch_handlers || []).empty?
    return nil if subtree_has_nonlocal_exit?(irep)

    kinds = Set.new
    BytecodeIR.for(irep).exits.each do |exit|
      case exit.kind
      when :true, :false, :nil then kinds << exit.kind
      when :value
        sources = BytecodeIR.return_sources(irep, exit.index, exit.reg&.to_s)
        return nil unless sources && !sources.empty?

        sources.each do |source|
          if source == BytecodeIR::NIL_SOURCE
            kinds << :nil
            next
          end

          literal = RETURN_FOLD_LITERALS[BytecodeIR.for(irep).source_at(source[0]).op]
          return nil unless literal

          kinds << literal
        end
      else
        return nil
      end
    end
    kinds.empty? ? nil : kinds
  end
end
