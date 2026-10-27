# frozen_string_literal: true

require 'set'
require_relative 'bytecode_ir'
require_relative 'core_defs'

# CodeGen: SLOT_ASSURED's construction arguments. A self-call made while an instance is built often passes literals
# that switch work off (`reset(mapping: false)`, `setup(false)`), and the arm they switch off is what hands `self`
# out. The construction reach walks such a callee with those literals bound and skips the arms they decide:
#
#   - a parameter bound to a literal decides a JMPIF/JMPNOT/JMPNIL that tests it (or a MOVE of it);
#   - a parameter bound to the keyword Hash of the call decides a test of `param.fetch(:key, literal)` or
#     `param[:key]`, when every use of the parameter is such a read (nothing else sees or changes the Hash) and
#     Hash#fetch / Hash#[] are the native ones;
#   - the optional-argument table of ENTER takes only the entry the call's argument count selects.
#
# A binding is { given: optionals supplied, params: { register => [:lit, truth] | [:hash, { key => truth }] } },
# where a truth is true, false or :nil.
class CodeGen
  SLOT_LITERAL_TRUTH = { LOADTRUE: true, LOADFALSE: false, LOADNIL: :nil, LOADSYM: true, LOADI: true, LOADINEG: true,
                         LOADI8: true, LOADI16: true, LOADI32: true, LOADI__1: true, LOADI_0: true, LOADI_1: true,
                         LOADI_2: true, LOADI_3: true, LOADI_4: true, LOADI_5: true, LOADI_6: true, LOADI_7: true,
                         STRING: true }.freeze
  SLOT_HASH_READS = %w[fetch []].freeze

  # The binding a self-call at +idx+ gives +callee+ (a MethodDef), or nil when no argument is a literal.
  def slot_call_binding(irep, idx, insn, callee)
    body = @ireps[callee.irep] or return nil
    enter = BytecodeIR.for(body).instructions.first&.source
    return nil unless enter&.op == :ENTER && insn.reg && insn.argc && !insn.keyword_splat?

    m1, o, r, m2, k, kd = enter.enter_fields.map(&:to_i)
    return nil unless r.zero? && m2.zero? && k.zero? && kd.zero?

    n = insn.argc
    params = {}
    n.times do |i|
      truth = slot_literal_truth(irep, idx, insn.reg + 1 + i)
      params[i + 1] = [:lit, truth] unless truth.nil?
    end
    # Without keyword parameters the keywords arrive as one more positional Hash.
    nk = insn.keyword_argc.to_i
    if insn.keyword_arguments? && nk.positive?
      pairs = nk.times.map do |j|
        key = slot_literal_symbol(irep, idx, insn.reg + 1 + n + 2 * j)
        truth = slot_literal_truth(irep, idx, insn.reg + 2 + n + 2 * j)
        key && !truth.nil? ? [key, truth] : nil
      end
      params[n + 1] = [:hash, pairs.to_h.freeze] if pairs.all?
      n += 1
    end
    given = n - m1
    return nil if params.empty? || given.negative? || given > o

    { given: given, params: params.freeze }.freeze
  end

  def slot_literal_truth(irep, idx, reg)
    writers = BytecodeIR.reaching_writer_indices(irep, idx, reg) or return nil
    truths = writers.map { |i| SLOT_LITERAL_TRUTH[BytecodeIR.for(irep).source_at(i).op] }
    truths.uniq.size == 1 ? truths.first : nil
  end

  def slot_literal_symbol(irep, idx, reg)
    writers = BytecodeIR.reaching_writer_indices(irep, idx, reg) or return nil
    syms = writers.map { |i| (w = BytecodeIR.for(irep).source_at(i)).op == :LOADSYM ? w.sym.to_s : nil }
    syms.uniq.size == 1 ? syms.first : nil
  end

  # The instruction indexes of +irep+ that can run under +binding+ (every reachable one without it), or nil when
  # the control flow is not resolved. Pruning only removes writers, so decisions are retried until nothing changes.
  def slot_live_indices(irep, binding)
    program = BytecodeIR.for(irep)
    return nil unless program.instruction_predecessors(include_handlers: true)

    live = slot_reachable(program, binding, {})
    return live unless binding

    loop do
      pruned = slot_reachable(program, binding, slot_decisions(irep, program, binding, live))
      return pruned if pruned == live

      live = pruned
    end
  end

  def slot_reachable(program, binding, decided)
    raises = program.handler_edges.group_by(&:src)
    live = Set.new
    stack = [0]
    until stack.empty?
      i = stack.pop
      next if i.nil? || i >= program.instructions.length || !live.add?(i)

      instruction = program.instructions[i]
      stack.concat(if decided.key?(i) then [decided[i]]
                   elsif binding && instruction.source.op == :ENTER then [i + 1 + binding[:given]]
                   else instruction.successors
                   end)
      stack.concat(Array(raises[i]).map(&:target))
    end
    live
  end

  # { branch index => the one successor its bound condition takes }.
  def slot_decisions(irep, program, binding, live)
    upvar_written = BytecodeIR.own_upvar_written_regs(irep)
    unwritten = binding[:params].keys.reject do |reg|
      # ENTER's own write is the binding.
      upvar_written.include?(reg) || live.any? { |i| program.instructions[i].source.op != :ENTER && program.may_write_at?(i, reg) }
    end.to_set
    decided = {}
    live.each do |i|
      insn = program.instructions[i].source
      next unless %i[JMPIF JMPNOT JMPNIL].include?(insn.op)

      truth = slot_bound_truth(program, binding, unwritten, live, i, insn.reg)
      next if truth.nil?

      target = program.address_to_index[insn.branch_target] or next
      jumps = case insn.op
              when :JMPIF then truth == true
              when :JMPNOT then truth != true
              else truth == :nil
              end
      decided[i] = jumps ? target : i + 1
    end
    decided
  end

  # The truth of the value +reg+ holds right before +i+, or nil when unknown. A parameter no live instruction
  # writes holds its bound literal everywhere; any other register follows its writer on the same straight line.
  def slot_bound_truth(program, binding, unwritten, live, i, reg)
    truth = slot_param_truth(binding, unwritten, reg)
    return truth unless truth.nil?

    j = slot_line_writer(program, i, reg)
    return nil unless j.is_a?(Integer)

    insn = program.instructions[j].source
    case insn.op
    when :MOVE then slot_bound_truth(program, binding, unwritten, live, j, insn.regs[1])
    when :SEND, :GETIDX then slot_hash_read_truth(program, binding, unwritten, live, j, insn)
    else SLOT_LITERAL_TRUTH[insn.op]
    end
  end

  def slot_param_truth(binding, unwritten, reg)
    value = binding[:params][reg]
    value&.first == :lit && unwritten.include?(reg) ? value.last : nil
  end

  # `recv.fetch(:key, literal)` / `recv[:key]` where recv is a MOVE of a bound keyword Hash.
  def slot_hash_read_truth(program, binding, unwritten, live, j, insn)
    name = insn.op == :GETIDX ? '[]' : insn.sym.to_s
    argc = insn.op == :GETIDX ? 1 : insn.argc
    return nil unless (name == 'fetch' && argc == 2) || (name == '[]' && argc == 1)
    return nil unless slot_standard_hash_reads?

    recv = insn.reg
    move = slot_line_writer(program, j, recv)
    return nil unless move.is_a?(Integer) && program.instructions[move].source.op == :MOVE

    param = program.instructions[move].source.regs[1]
    hash = binding[:params][param]
    return nil unless hash&.first == :hash && unwritten.include?(param) && slot_hash_only_read?(program, live, param)

    key_at = slot_line_writer(program, j, recv + 1)
    return nil unless key_at.is_a?(Integer) && (key = program.instructions[key_at].source).op == :LOADSYM

    entries = hash.last
    return entries[key.sym.to_s] if entries.key?(key.sym.to_s)
    return :nil if name == '[]'

    default_at = slot_line_writer(program, j, recv + 2)
    default_at.is_a?(Integer) ? SLOT_LITERAL_TRUTH[program.instructions[default_at].source.op] : nil
  end

  # Hash#fetch, #[] and #key? are mruby's own (native, or the core gems' Ruby), so a read of a literal key in a
  # keyword Hash nothing else touches answers what the call passed.
  def slot_standard_hash_reads?
    return @slot_standard_hash_reads unless @slot_standard_hash_reads.nil?

    @slot_standard_hash_reads = %w[fetch [] key?].all? do |name|
      @registry.fetch(name, []).none? { |d| d.irep && d.owner == 'Hash' && !CoreDefs.core_source?(@ireps[d.irep]&.file) }
    end
  end

  # Every live use of +param+ is a MOVE feeding a fetch/[] in the same line (the Hash is never passed on or changed).
  def slot_hash_only_read?(program, live, param)
    live.all? do |i|
      insn = program.instructions[i].source
      next true unless insn.regs.include?(param)
      next false unless insn.op == :MOVE && insn.regs[1] == param

      slot_moved_into_hash_read?(program, i, insn.reg)
    end
  end

  # MOVE Rt Rp; LOADSYM Rt+1; [literal Rt+2;] SEND Rt :fetch | GETIDX Rt
  def slot_moved_into_hash_read?(program, i, reg)
    (i + 1..[i + 3, program.instructions.length - 1].min).each do |k|
      return false unless slot_straight?(program, k)

      insn = program.instructions[k].source
      if %i[SEND GETIDX].include?(insn.op) && insn.reg == reg
        return insn.op == :GETIDX || insn.sym.to_s == 'fetch'
      end
      return false if program.may_write_at?(k, reg)
    end
    false
  end

  # The index of the last writer of +reg+ before +i+ on the straight line of code that ends at +i+, :entry when
  # that line starts the method with no writer, or nil when another path joins it first.
  def slot_line_writer(program, i, reg)
    k = i
    while k.positive?
      return nil unless slot_straight?(program, k)
      return :entry if program.instructions[k - 1].source.op == :ENTER
      return k - 1 if program.may_write_at?(k - 1, reg)

      k -= 1
    end
    :entry
  end

  # Only the previous instruction leads to +k+ (no branch or handler lands on it).
  def slot_straight?(program, k)
    program.instruction_predecessors(include_handlers: true)[k].to_a == [k - 1]
  end
end
