# frozen_string_literal: true

require 'set'
require_relative 'bytecode_ir'
require_relative 'bytecode_ir_containers'
require_relative 'ir_symbol_flow'
require_relative 'irep_arity'

# FRAGMENT_USES (closed only): which string-pool literals can become a piece of a name built at run time.
#
# The plain fragment rule (static_dispatch_registrations.rb, rule 4) counts every pool literal of two or more
# identifier characters, so one `"state"` anywhere keeps every `state*` / `*state` method registered. A literal can
# only end up inside another string if its value reaches something that builds or keeps strings: a concatenation,
# a store, a return, a block capture, an argument the trace cannot follow. A literal whose every load is only
# compared (`==`, `when`, `start_with?`), used as a key into a native lookup (`h["state"]`, `key?`), tested for
# truth or printed cannot. Each STRING / FSTRING / SYMBOL load is followed forward (IrSymbolFlow.value_reads, MOVE
# copies included); an argument of a closed-world method is followed into that method's parameter. Anything else,
# or a use the flow query refuses, keeps the literal a fragment.
module StaticDispatchFragmentUses
  LOAD_OPS = Set[:STRING, :FSTRING, :SYMBOL].freeze
  # Ops that read the value without passing it on: a comparison, a branch on its truth.
  PURE_OPS = Set[:EQ, :JMPIF, :JMPNOT, :JMPNIL].freeze
  # Sends that only compare or measure their receiver.
  PURE_RECEIVER_SENDS = Set['==', '!=', '===', 'eql?', 'equal?', '=~', 'match?', 'start_with?', 'end_with?',
                            'include?', 'empty?', 'size', 'length', 'hash', 'nil?', 'is_a?', 'kind_of?',
                            'instance_of?', '!'].freeze
  # Sends that only compare, look up or print an argument (the core / native methods; a closed-world definition of
  # the name is followed into instead).
  PURE_ARGUMENT_SENDS = (PURE_RECEIVER_SENDS | Set['key?', 'has_key?', 'member?', 'fetch', 'dig', '[]', 'delete',
                                                    'puts', 'print', 'p', 'warn']).freeze
  # Of those, the ones whose result can be the argument itself (`str["x"]`, `h.fetch(k, "x")`, `p "x"`): their result
  # is followed too.
  RESULT_CARRYING_SENDS = Set['fetch', 'dig', '[]', 'delete', 'p'].freeze
  # Sends that only query a collection holding the value (and the ones whose result is that collection again).
  PURE_CONTAINER_SENDS = Set['include?', 'member?', 'key?', 'has_key?', 'value?', '==', '!=', 'eql?', 'empty?',
                             'size', 'length', 'count', 'index', 'find_index', 'hash'].freeze
  SAME_CONTAINER_SENDS = Set['freeze', 'dup', 'clone'].freeze
  # Sends whose result is one element of the collection: the element is followed like the value itself.
  ELEMENT_SENDS = Set['[]', 'at', 'fetch', 'first', 'last', 'dig'].freeze
  # The owners a method of an Array / Hash literal (or of self in one of their methods) can resolve to.
  CONTAINER_OWNERS = Set['Array', 'Hash', 'Enumerable', 'Object', 'Kernel', 'BasicObject', 'Comparable'].freeze
  # A character no method name has: a string built with one in it is never a name.
  NON_NAME_CHAR = /[^\w?!=]/
  MAX_DEPTH = 6
  MAX_PASSES = 20

  module_function

  # Positional argument count of a send, 0 for the SEND0-style forms; nil for a splat.
  def send_argc(insn)
    BytecodeIR::Ops::ZERO_SUFFIX_OPS.include?(insn.op) ? 0 : insn.argc
  end

  # The pool literals matching `fragment_re` that some load may pass into a built string (all of them when a
  # literal is never seen loaded).
  # `outside`: names something outside the closed bytecode may call, whose results go where the trace cannot see.
  def escaping(ireps, body_of, method_of, outside, fragment_re)
    bodies = Hash.new { |h, k| h[k] = [] }
    body_of.each { |label, (_owner, name)| bodies[name] << label }
    ctx = { ireps: ireps, bodies: bodies, body_of: body_of, method_of: method_of, outside: outside,
            callers: callers_by_name(ireps), constants: constant_reads(ireps), super_names: super_names(ireps, method_of, body_of) }
    loads = Hash.new { |h, k| h[k] = [] }
    ireps.each_value do |irep|
      BytecodeIR.for(irep).each_source do |insn, index|
        next unless LOAD_OPS.include?(insn.op)

        literal = irep.pool[insn.pool_index]
        loads[literal] << [irep, index, insn.reg] if literal.is_a?(String)
      end
    end
    # A use on a cycle (a recursive call, a loop through a constant) is read before it is finished; each pass reads
    # the previous pass's answer there and a true answer stays true, so the passes only grow until one changes nothing.
    ctx[:previous] = {}
    MAX_PASSES.times do
      ctx[:memo] = {}
      out = escaping_pass(ireps, loads, fragment_re, ctx)
      escaped = ctx[:memo].select { |_, v| v }.keys
      return out if escaped.all? { |key| ctx[:previous][key] }

      ctx[:previous] = ctx[:previous].merge(escaped.to_h { |key| [key, true] })
    end
    every_literal(ireps, fragment_re) # no fixpoint: the plain rule
  end

  def every_literal(ireps, fragment_re)
    ireps.each_value.with_object(Set.new) do |irep, out|
      irep.pool.each { |literal| out << literal if literal.is_a?(String) && literal.match?(fragment_re) }
    end
  end

  def escaping_pass(ireps, loads, fragment_re, ctx)
    out = Set.new
    ireps.each_value do |irep|
      irep.pool.each do |literal|
        next unless literal.is_a?(String) && literal.match?(fragment_re) && !out.include?(literal)

        sites = loads[literal]
        out << literal if sites.empty? || sites.any? { |site_irep, index, reg| escapes?(site_irep, index, reg, ctx, 0) }
      end
    end
    out
  end

  def memoized(ctx, key)
    return ctx[:memo][key] if ctx[:memo].key?(key)
    return ctx[:memo][key] = true if ctx[:previous][key]

    ctx[:memo][key] = false
    ctx[:memo][key] = yield
  end

  # Whether the value written to `reg` at `index` may reach anything other than a pure use.
  def escapes?(irep, index, reg, ctx, depth)
    memoized(ctx, [irep.label, index, reg]) { depth > MAX_DEPTH || uses_escape?(irep, index, reg, ctx, depth) }
  end

  def uses_escape?(irep, index, reg, ctx, depth)
    walked = IrSymbolFlow.follow_forward_uses(irep, index, reg) do |use, insn, register|
      if PURE_OPS.include?(insn.op)
        nil
      elsif BytecodeIR::Ops::SEND.include?(insn.op)
        send_escapes?(irep, use, insn, register.to_i, ctx, depth)
      elsif insn.op == :GETIDX
        # `x[value]`: the `[]` send GETIDX stands for, with the value as its argument (or receiver).
        call_escapes?(irep, use, '[]', insn.reg.to_i, 1, register.to_i, false, ctx, depth)
      elsif %i[ARRAY HASH ARYPUSH HASHADD].include?(insn.op)
        container_escapes?(irep, use, insn.reg, ctx, depth + 1)
      elsif insn.op == :STRCAT
        !concat_poisoned?(irep, use, insn.reg)
      elsif insn.op == :RETURN
        result_escapes?(irep, ctx, depth + 1)
      else
        true
      end
    end
    walked.nil? || walked
  end

  def callers_by_name(ireps)
    callers = Hash.new { |h, k| h[k] = [] }
    ireps.each_value do |irep|
      BytecodeIR.for(irep).each_source do |insn, index|
        callers[insn.sym.to_s] << [irep, index, insn] if BytecodeIR::Ops::SEND.include?(insn.op) && insn.sym
      end
    end
    callers
  end

  # Names of methods whose body calls `super`: a SUPER is a call site no send of the name shows.
  def super_names(ireps, method_of, body_of)
    ireps.each_value.with_object(Set.new) do |irep, names|
      next if BytecodeIR.for(irep).instructions_with_op(:SUPER).empty?

      m = method_of[irep.label]
      names << body_of[m][1] if m
    end
  end

  # constant name => [[irep, index of the GETCONST / GETMCNST, register]].
  def constant_reads(ireps)
    reads = Hash.new { |h, k| h[k] = [] }
    ireps.each_value do |irep|
      BytecodeIR.for(irep).each_source do |insn, index|
        reads[insn.const_name.to_s] << [irep, index, insn.reg] if %i[GETCONST GETMCNST].include?(insn.op)
      end
    end
    reads
  end

  # A collection holding the value: only queried (`LIST.include?(x)`), or stored in a constant that only is.
  def container_escapes?(irep, index, reg, ctx, depth)
    memoized(ctx, [:container, irep.label, index, reg]) do
      depth > MAX_DEPTH || container_uses_escape?(irep, index, reg, ctx, depth)
    end
  end

  def container_uses_escape?(irep, index, reg, ctx, depth)
    walked = IrSymbolFlow.follow_forward_uses(irep, index, reg) do |use, insn, register|
      if PURE_OPS.include?(insn.op)
        nil
      elsif insn.op == :SETCONST
        if ctx[:outside].include?(insn.const_name.to_s) # native code may read it
          true
        else
          ctx[:constants][insn.const_name.to_s].any? do |reader, at, value_reg|
            container_escapes?(reader, at, value_reg, ctx, depth + 1)
          end
        end
      elsif %i[ARRAY HASH ARYPUSH HASHADD].include?(insn.op)
        container_escapes?(irep, use, insn.reg, ctx, depth + 1)
      elsif BytecodeIR::Ops::SELF_SEND.include?(insn.op) && insn.reg.to_i == register.to_i
        nil # only the result slot
      elsif BytecodeIR::Ops::SEND.include?(insn.op) && insn.reg.to_i == register.to_i && send_argc(insn)
        name = insn.sym.to_s
        # A closed-world definition of the name (mruby-rgss's Array#include?) gets the collection as self.
        container_bodies = ctx[:bodies][name].select { |body| CONTAINER_OWNERS.include?(ctx[:body_of][body][0]) }
        if container_bodies.any? { |body| self_escapes?(body, ctx, depth + 1) }
          true
        elsif SAME_CONTAINER_SENDS.include?(name)
          IrSymbolFlow::Follow.new(insn.reg)
        elsif ELEMENT_SENDS.include?(name)
          escapes?(irep, use, insn.reg, ctx, depth + 1)
        else
          !PURE_CONTAINER_SENDS.include?(name)
        end
      else
        true
      end
    end
    walked.nil? || walked
  end

  # A closed-world method whose self is the collection: it only queries self (or the elements it takes out).
  def self_escapes?(body, ctx, depth)
    callee = ctx[:ireps][body]
    return true unless callee

    container_escapes?(callee, 0, '0', ctx, depth)
  end

  # STRCAT R(a) R(a+1) building a string that also gets a NON_NAME_CHAR literal (before or right after): never a name.
  def concat_poisoned?(irep, index, reg)
    backward_poison?(irep, index, reg, 0) || forward_poison?(irep, index, reg, 0)
  end

  def non_name_literal?(irep, index, reg)
    (BytecodeIR.reaching_definitions(irep, index, reg) || []).any? do |d|
      next false if d.entry?

      insn = BytecodeIR.for(irep).source_at(d.index)
      literal = %i[STRING FSTRING].include?(insn.op) && irep.pool[insn.pool_index]
      literal.is_a?(String) && literal.match?(NON_NAME_CHAR)
    end
  end

  def backward_poison?(irep, index, reg, depth)
    return false if depth > 32
    return true if non_name_literal?(irep, index, reg) || non_name_literal?(irep, index, reg + 1)

    defs = BytecodeIR.reaching_definitions(irep, index, reg) || []
    !defs.empty? && defs.all? do |d|
      !d.entry? && BytecodeIR.for(irep).source_at(d.index).op == :STRCAT && backward_poison?(irep, d.index, reg, depth + 1)
    end
  end

  # The result's only use is the next STRCAT appending to it.
  def forward_poison?(irep, index, reg, depth)
    return false if depth > 32

    reads = IrSymbolFlow.value_reads(irep, index, reg)
    return false unless reads&.size == 1

    insn = BytecodeIR.for(irep).source_at(reads.first)
    return false unless insn.op == :STRCAT && insn.reg == reg

    non_name_literal?(irep, reads.first, reg + 1) || forward_poison?(irep, reads.first, reg, depth + 1)
  end

  # A method body returning the value: followed into the result of every bytecode send of its name.
  def result_escapes?(irep, ctx, depth)
    m = ctx[:method_of][irep.label]
    return true unless m == irep.label && depth <= MAX_DEPTH

    name = ctx[:body_of][m]&.at(1)
    return true if name.nil? || ctx[:outside].include?(name) || ctx[:super_names].include?(name)
    return true if ctx[:callers][name].empty?

    ctx[:callers][name].any? { |caller, index, insn| escapes?(caller, index, insn.reg, ctx, depth) }
  end

  # A send reading the value as its receiver or one of its arguments.
  def send_escapes?(irep, use, insn, reg, ctx, depth)
    argc = send_argc(insn) or return true

    call_escapes?(irep, use, insn.sym.to_s, insn.reg.to_i, argc, reg, BytecodeIR::Ops::SELF_SEND.include?(insn.op), ctx,
                  depth)
  end

  # A call of `name` with receiver R(base) (or self) and `argc` arguments R(base+1)..., reading the value in R(reg);
  # its result goes to R(base).
  def call_escapes?(irep, use, name, base, argc, reg, self_send, ctx, depth)
    position = reg - base # 0: receiver, k: argument k
    # A self send's R(a) is only its result slot: the value there is overwritten, not read.
    return false if position.zero? && self_send
    return true if position > argc # the block slot
    return true unless (position.zero? ? PURE_RECEIVER_SENDS : PURE_ARGUMENT_SENDS).include?(name)
    return true if RESULT_CARRYING_SENDS.include?(name) && escapes?(irep, use, base, ctx, depth + 1)

    # A closed-world definition of the name gets the value as self or as parameter `position`.
    ctx[:bodies][name].any? do |body|
      next true if position.zero? # a closed method on a String receiver: not followed

      callee = ctx[:ireps][body]
      enter = callee&.enter
      next true unless callee && enter && optional_positionals_only?(callee)
      next false if position > enter.enter_fields[0] + enter.enter_fields[1]

      escapes?(callee, 0, position, ctx, depth + 1)
    end
  end
end
