#!/usr/bin/env ruby
# frozen_string_literal: true

# Dispatch-target traces answer from the bytecode IR. Host only: every
# irep is hand-built from instruction strings, so no mrbc is needed.
#
# 1. literal_container_class (SETCONST, CONST_CONTAINER_SUPPORT): a constant
#    assigned on two paths gets the class every reaching definition agrees on,
#    or nil. The textually last literal is not the value.
# 2. trace_eqq_literal_receiver (LITERAL_EQQ): a `when` literal is only a
#    literal when every reaching definition of the receiver is that literal.
# 3. trace_new_target_reaching and the GETIDX alias walk: a hop past a join is
#    not taken for an unguarded trace, so `(c ? A : B).new` has no class.
# 4. Join mode is per trace: an unguarded trace nested in a guarded one still
#    refuses a join.
# 5. StaticDispatchRegistrations.receiver_kinds: a register a nested block
#    writes (SETUPVAR) is opaque, so a send on it is :unknown.
#
# Usage: ruby scripts/bc2cpp/dispatch_ir_trace_check.rb

require 'set'

require_relative '../../tools/bc2cpp/irep'
require_relative '../../tools/bc2cpp/bytecode_ir'
require_relative '../../tools/bc2cpp/ivar_layout'
require_relative '../../tools/bc2cpp/irep_scans'
require_relative '../../tools/bc2cpp/unique_class_names'
require_relative '../../tools/bc2cpp/construct_class_names'
require_relative '../../tools/bc2cpp/dispatch_targets'
require_relative '../../tools/bc2cpp/static_dispatch_registrations'

failures = []
check = lambda do |what, condition|
  puts "  #{condition ? 'ok  ' : 'FAIL'} #{what}"
  failures << what unless condition
end

# Instructions are numbered by their address, so a branch operand is an index.
def program(*specs)
  list = specs.each_with_index.map do |(op, args), index|
    Insn.new(lineno: index + 1, addr: index, op: op, args: args, raw: "#{op} #{args}")
  end
  Irep.new(label: "t#{list.hash}", nlocals: 6, instructions: list, catch_handlers: [])
end

puts '-- literal_container_class (host, item 1)'
# X = c ? [] : {}  -- the value is an Array on one path and a Hash on the other.
array_or_hash = program(
  [:JMPNOT, "R1\t3"], [:ARRAY, "R2\t0"], [:JMP, '4'], [:HASH, "R2\t0"], [:SETCONST, "X\tR2"]
)
check.call('X = c ? [] : {} has no single container class (the last literal is not the value)',
           literal_container_class(array_or_hash, 4, 2).nil?)

# X = c ? {} : []
hash_or_array = program(
  [:JMPNOT, "R1\t3"], [:HASH, "R2\t0"], [:JMP, '4'], [:ARRAY, "R2\t0"], [:SETCONST, "X\tR2"]
)
check.call('X = c ? {} : [] has no single container class', literal_container_class(hash_or_array, 4, 2).nil?)

# X = c ? [] : []  -- every path agrees.
array_both = program(
  [:JMPNOT, "R1\t3"], [:ARRAY, "R2\t0"], [:JMP, '4'], [:ARRAY, "R2\t1"], [:SETCONST, "X\tR2"]
)
check.call('X = c ? [] : [] is an Array on every path', literal_container_class(array_both, 4, 2) == 'Array')

straight = program([:ARRAY, "R2\t2"], [:SETCONST, "X\tR2"])
check.call('X = [1, 2] is an Array', literal_container_class(straight, 1, 2) == 'Array')

frozen = program([:ARRAY, "R2\t2"], [:SEND0, "R2\t:freeze"], [:SETCONST, "X\tR2"])
check.call('X = [1, 2].freeze is an Array', literal_container_class(frozen, 2, 2) == 'Array')

nil_path = program([:JMPNOT, "R1\t3"], [:ARRAY, "R2\t0"], [:JMP, '4'], [:LOADNIL, "R2\t(0)"], [:SETCONST, "X\tR2"])
check.call('X = c ? [] : nil is not a container', literal_container_class(nil_path, 4, 2).nil?)

puts '-- trace_eqq_literal_receiver (host, item 2)'
# case x; when (c ? foo : 5) -- the receiver of === is the call's result on one path.
eqq_mixed = program(
  [:JMPNOT, "R1\t3"], [:SEND0, "R4\t:foo"], [:JMP, '4'], [:LOADI_5, "R4\t(5)"], [:MOVE, "R5\tR3"],
  [:SEND, "R4\t:===\tn=1"]
)
check.call('a receiver that is 5 on one path and a call on the other is not a literal',
           trace_eqq_literal_receiver(eqq_mixed, 5, 4).nil?)

eqq_plain = program([:LOADI_5, "R4\t(5)"], [:MOVE, "R5\tR3"], [:SEND, "R4\t:===\tn=1"])
check.call('a `when 5` receiver is the literal 5',
           trace_eqq_literal_receiver(eqq_plain, 2, 4) == { type: :fixnum, value: '5' })

eqq_agree = program(
  [:JMPNOT, "R1\t3"], [:LOADI_5, "R4\t(5)"], [:JMP, '4'], [:LOADI_5, "R4\t(5)"], [:MOVE, "R5\tR3"],
  [:SEND, "R4\t:===\tn=1"]
)
check.call('both paths load the same literal 5: still the literal',
           trace_eqq_literal_receiver(eqq_agree, 5, 4) == { type: :fixnum, value: '5' })

eqq_two = program(
  [:JMPNOT, "R1\t3"], [:LOADI_5, "R4\t(5)"], [:JMP, '4'], [:LOADI_6, "R4\t(6)"], [:MOVE, "R5\tR3"],
  [:SEND, "R4\t:===\tn=1"]
)
check.call('5 on one path and 6 on the other is no literal', trace_eqq_literal_receiver(eqq_two, 5, 4).nil?)

eqq_sym = program(
  [:JMPNOT, "R1\t3"], [:LOADSYM, "R4\t:a"], [:JMP, '4'], [:LOADSYM, "R4\t:b"], [:MOVE, "R5\tR3"],
  [:SEND, "R4\t:===\tn=1"]
)
check.call(':a on one path and :b on the other is no literal', trace_eqq_literal_receiver(eqq_sym, 5, 4).nil?)

puts '-- join mode is per trace (host, item 4)'
# x = c ? [] : {}; y = x  -- an unguarded trace of y must refuse the join, however the trace was reached.
join_value = program(
  [:JMPNOT, "R1\t3"], [:ARRAY, "R2\t0"], [:JMP, '4'], [:HASH, "R2\t0"], [:MOVE, "R3\tR2"], [:RETURN, 'R3']
)
check.call('an unguarded trace of a joined value refuses (the reference answer)',
           trace_new_target(join_value, 5, 3).nil?)

# A guarded consumer's method_return_class callback runs an unguarded trace of its own. That trace must not inherit
# the guarded mode of the trace it was reached from.
outer = program([:SEND0, "R2\t:foo"], [:RETURN, 'R2'])
nested = []
trace_new_target(outer, 1, 2, guarded: true, method_return_class: lambda { |_name|
  nested << trace_new_target(join_value, 5, 3)
  nil
})
check.call('an unguarded trace nested in a guarded one still refuses the join',
           !nested.empty? && nested.all?(&:nil?))

puts '-- reaching definitions walk their hops with dominance (host, item 3)'
# x = (c ? A : B).new -- the reaching definition is the `.new` send, and the walk behind it continues past the send
# into the join. Only one arm is visible to a linear hop, so the class is B on one path and A on the other.
new_on_join = program(
  [:JMPNOT, "R1\t3"], [:GETCONST, "R2\tA"], [:JMP, '4'], [:GETCONST, "R2\tB"], [:SEND0, "R2\t:new"], [:RETURN, 'R2']
)
check.call('(c ? A : B).new has no single class (the join is not skipped)',
           trace_new_target(new_on_join, 5, 2).nil?)

straight_new = program([:GETCONST, "R2\tA"], [:SEND0, "R2\t:new"], [:RETURN, 'R2'])
check.call('A.new is an A (straight-line control)', trace_new_target(straight_new, 2, 2) == 'A')

# The GETIDX arm reads the argument an alias of the receiver came from (the annotated element class of the argument
# applies only when the receiver IS that argument). The alias walk must dominate the GETIDX too.
element_join = Irep.new(label: 'L', nlocals: 6, catch_handlers: [], instructions: [
  Insn.new(lineno: 1, addr: 0, op: :HASH, args: "R2\t0", raw: 'HASH R2 0'),
  Insn.new(lineno: 2, addr: 1, op: :JMPNOT, args: "R9\t3", raw: 'JMPNOT R9 3'),
  Insn.new(lineno: 3, addr: 2, op: :MOVE, args: "R2\tR1", raw: 'MOVE R2 R1'),
  Insn.new(lineno: 4, addr: 3, op: :GETIDX, args: "R2\t(R3)", raw: 'GETIDX R2 (R3)'),
  Insn.new(lineno: 5, addr: 4, op: :RETURN, args: 'R2', raw: 'RETURN R2')
])
element_annotations = { 'L' => Struct.new(:arg_containers, :arg_elements, :ret_class).new(['Hash'], ['Integer'], nil) }
check.call('an element of a receiver that is a literal Hash on one path and the annotated argument on the other',
           trace_new_target(element_join, 4, 2, nil, 1, ['Hash'], class_layout: {}, registry: {},
                            element_annotations: element_annotations).nil?)

# CONTAINER_PHI_MERGE assumes the join at `at + 2` is reached only by the two arms. A third predecessor (here 1 -> 5,
# which keeps a Hash in R2) makes the merge answer 'Array' for a value that can be a Hash.
phi_extra_pred = program(
  [:HASH, "R2\t0"], [:JMPNOT, "R5\t5"], [:LOADNIL, "R2\t(0)"], [:JMPNOT, "R1\t5"], [:ARRAY, "R2\t0"], [:RETURN, 'R2']
)
check.call('a join with a third predecessor that keeps a Hash is no container merge',
           container_phi_merge(phi_extra_pred, 3, 2).nil?)
# `x = c && []` over an earlier nil: both arms are nil or an Array at the join.
phi_nil_arm = program([:LOADNIL, "R2\t(0)"], [:JMPNOT, "R1\t3"], [:ARRAY, "R2\t0"], [:RETURN, 'R2'])
check.call('a nil-or-Array join is an Array (the merge keeps its positive case)',
           container_phi_merge(phi_nil_arm, 1, 2) == 'Array')

puts '-- static dispatch receiver kinds (host, item 5)'
# A nested block writes R2 with SETUPVAR, so the local LOADNIL is not the value the send sees.
upvar_child = Irep.new(label: 'c1', nlocals: 3, catch_handlers: [], instructions: [
  Insn.new(lineno: 1, addr: 0, op: :SETUPVAR, args: "R2\t2\t0", raw: 'SETUPVAR R2 2 0'),
  Insn.new(lineno: 2, addr: 1, op: :RETNIL, args: '', raw: 'RETNIL')
])
upvar_parent = Irep.new(label: 'p1', nlocals: 3, reps: ['c1'], catch_handlers: [], instructions: [
  Insn.new(lineno: 1, addr: 0, op: :LOADNIL, args: "R2\t(0)", raw: 'LOADNIL R2 (0)'),
  Insn.new(lineno: 2, addr: 1, op: :SEND0, args: "R2\t:foo", raw: 'SEND0 R2 :foo'),
  Insn.new(lineno: 3, addr: 2, op: :RETURN, args: 'R2', raw: 'RETURN R2')
])
upvar_parent.tree = { 'c1' => upvar_child }
check.call('a register a nested block writes is no literal receiver for the send',
           StaticDispatchRegistrations.receiver_kinds(upvar_parent)[1] == :unknown)

const_send = program([:GETCONST, "R2\tFoo"], [:SEND0, "R2\t:new"], [:RETURN, 'R2'])
check.call('a constant receiver names its class', StaticDispatchRegistrations.receiver_kinds(const_send)[1] == [:const, 'Foo'])

self_send = program([:MOVE, "R2\tR0"], [:SEND0, "R2\t:bar"], [:RETURN, 'R2'])
check.call('a copy of self is self', StaticDispatchRegistrations.receiver_kinds(self_send)[1] == :self)

mixed_send = program(
  [:JMPNOT, "R1\t3"], [:GETCONST, "R2\tA"], [:JMP, '4'], [:LOADNIL, "R2\t(0)"], [:SEND0, "R2\t:foo"]
)
check.call('a constant on one path and nil on the other has no kind',
           StaticDispatchRegistrations.receiver_kinds(mixed_send)[4] == :unknown)

puts
if failures.empty?
  puts 'bc2cpp dispatch IR trace check: PASS'
else
  puts "bc2cpp dispatch IR trace check: FAIL (#{failures.size})"
  exit 1
end
