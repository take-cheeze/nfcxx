#!/usr/bin/env ruby
# frozen_string_literal: true

# Origin walk over ops that write above their leading register (vm.c, pinned mruby 67a569ed):
# the fallback send of GETIDX0, SETIDX and the operator ops (L_SEND_SYM writes nil into R(a+2)),
# BLKCALL (clears every register above its arguments) and ENTER (rest, keyword and block slots, which ENTER
# stores: typed definitions in the origin walk, as are R1, the post arguments and the locals ENTER clears). Each one has
# a positive case (the origin walk refuses where the write is possible, or types the ENTER's own write) and a negative
# case (the answer stays exact where vm.c writes nothing else, or a counted refusal where ENTER says nothing). Codegen's default walk is not changed: it still answers as the audited
# model did, and this check pins that too.
require_relative '../../tools/bc2cpp/irep'
require_relative '../../tools/bc2cpp/bytecode_ir'

def insn(addr, op, args)
  Insn.new(lineno: 1, addr: addr, op: op, args: args, raw: "#{op} #{args}")
end

failures = []
check = ->(label, ok) { failures << label unless ok }
program = ->(list, nlocals: nil) { BytecodeIR::Program.new(Irep.new(label: 't', instructions: list, catch_handlers: [], nlocals: nlocals)) }
cause_of = lambda do |prog, index, reg|
  refusal = {}
  prog.reaching_definitions(index, reg, origin_transfers: true, refusal: refusal)
  refusal[:cause]
end
defs_of = lambda do |prog, index, reg, **opts|
  found = prog.reaching_definitions(index, reg, **opts)
  found && found.map { |d| d.entry? ? :entry : d.index }
end

# GETIDX0 R1 = R0[0]: its fallback also writes R2 (= 0) before the send. The read of R2 has two writers
# on two paths: the LOADI (fast path) and the GETIDX0 (fallback). The origin walk must refuse.
getidx0 = program.call([
  insn(0, 'LOADI_5', 'R2 (5)'), insn(2, 'GETIDX0', "R1\tR0[0]"), insn(4, 'MOVE', "R3\tR2"), insn(6, 'RETURN', 'R3')
])
check.call('GETIDX0 fallback writes R[a+1]: origin walk refuses a read of it', getidx0.reaching_definitions(2, '2', origin_transfers: true).nil?)
check.call('GETIDX0 fallback: the default walk refuses too (codegen, ORIGIN_FRAME_OPS)', defs_of.call(getidx0, 2, '2').nil?)
check.call('GETIDX0: a read of its leading register is defined by it (negative)',
           defs_of.call(getidx0, 2, '1', origin_transfers: true) == [1])

# ADD R0 (R1): the fallback sends with nil in R(a+2), so R2 has the LOADI and the ADD as writers.
add = program.call([insn(0, 'LOADI_5', 'R2 (5)'), insn(2, 'ADD', "R0\t(R1)"), insn(4, 'MOVE', "R3\tR2"), insn(6, 'RETURN', 'R3')])
check.call('ADD fallback writes R[a+2]: origin walk refuses a read of it', add.reaching_definitions(2, '2', origin_transfers: true).nil?)
check.call('ADD fallback: the default walk refuses too (codegen, ORIGIN_FRAME_OPS)', defs_of.call(add, 2, '2').nil?)
check.call('ADD: its leading register is still defined by it (negative)',
           defs_of.call(program.call([insn(0, 'LOADI_5', 'R0 (5)'), insn(2, 'ADD', "R0\t(R1)"), insn(4, 'MOVE', "R3\tR0"), insn(6, 'RETURN', 'R3')]), 2, '0', origin_transfers: true) == [1])

# BLKCALL R1 0: the block frame starts at R1 and clears R2.. above its argument, so a read of R5 may be nil.
blk = program.call([insn(0, 'LOADI_5', 'R5 (5)'), insn(2, 'BLKCALL', "R1\t0"), insn(4, 'MOVE', "R6\tR5"), insn(6, 'RETURN', 'R6')])
check.call('BLKCALL clears registers above its arguments: origin walk refuses a read above it',
           blk.reaching_definitions(2, '5', origin_transfers: true).nil?)
check.call('BLKCALL: the default walk refuses too (codegen, since BLKCALL joined CALLEE_FRAME_OPS)', defs_of.call(blk, 2, '5').nil?)
check.call('BLKCALL: a register below its frame is untouched (negative)',
           defs_of.call(program.call([insn(0, 'LOADI_5', 'R0 (5)'), insn(2, 'BLKCALL', "R1\t0"), insn(4, 'MOVE', "R6\tR0"), insn(6, 'RETURN', 'R6')]), 2, '0', origin_transfers: true) == [0])

# ENTER stores its rest, keyword-hash and block slots (vm.c OP_ENTER, 3rd/mruby/src/vm.c:2710-2741). The origin walk
# answers each of them with the ENTER as the writer, typed by what it stores (Definition#built). Codegen's default walk
# does not change: it still passes ENTER and answers the entry value, and write_dominates? keeps its answers.
built_of = lambda do |prog, index, reg|
  found = prog.reaching_definitions(index, reg, origin_transfers: true)
  found && found.map(&:built)
end

# Rest slot R1 of "0:0:1" (req 0, rest 1): the Array ENTER builds.
rest = program.call([insn(0, 'ENTER', "0:0:1:0:0:0:0:0\t(0x0)"), insn(2, 'MOVE', "R2\tR1"), insn(4, 'RETURN', 'R2')])
check.call('ENTER rest slot: origin walk types it as the ENTER-built Array',
           built_of.call(rest, 1, '1') == [:rest] && defs_of.call(rest, 1, '1', origin_transfers: true) == [0])
check.call('ENTER rest slot: the MOVE chain reaches the same typed definition (origin)', built_of.call(rest, 2, '2') == [:rest])
check.call('ENTER rest slot: codegen default walk still answers the entry value', defs_of.call(rest, 1, '1') == [:entry])
check.call('ENTER rest slot: write_dominates? keeps the codegen answer (entry dominates)',
           rest.write_dominates?(BytecodeIR::ENTRY, 1, '1') && !rest.write_dominates?(0, 1, '1'))

# Keyword hash R2 of "1:0:0:0:1:0:0:0" (req 1, keywords): the Hash ENTER builds (kd, vm.c:2741).
kwhash = program.call([insn(0, 'ENTER', "1:0:0:0:1:0:0:0\t(0x0)"), insn(2, 'MOVE', "R4\tR2"), insn(4, 'RETURN', 'R4')])
check.call('ENTER keyword hash slot: origin walk types it as the ENTER-built Hash', built_of.call(kwhash, 1, '2') == [:hash])
check.call('ENTER keyword hash slot: codegen default walk still answers the entry value', defs_of.call(kwhash, 1, '2') == [:entry])

# Block slot R2 of "1:0:0:0:0:0:1:0" (req 1, block, no keywords): the block ENTER stores (vm.c:2736).
block = program.call([insn(0, 'ENTER', "1:0:0:0:0:0:1:0\t(0x0)"), insn(2, 'MOVE', "R3\tR2"), insn(4, 'RETURN', 'R3')])
check.call('ENTER block slot without keywords: origin walk types it as the block', built_of.call(block, 1, '2') == [:block])
check.call('ENTER block slot: codegen default walk still answers the entry value', defs_of.call(block, 1, '2') == [:entry])

# Block slot R3 after the keyword hash R2 of "1:0:0:0:1:0:1:0" (kd 1: the block is at len+kd+1 = 3).
blockslot = program.call([insn(0, 'ENTER', "1:0:0:0:1:0:1:0\t(0x0)"), insn(2, 'MOVE', "R4\tR3"), insn(4, 'RETURN', 'R4')])
check.call('ENTER block slot after the keyword hash: origin walk types R3 as the block', built_of.call(blockslot, 1, '3') == [:block])
check.call('ENTER keyword hash is R2, not the block: origin walk types R2 as the hash', built_of.call(blockslot, 1, '2') == [:hash])
check.call('ENTER block slot: codegen default walk still answers the entry value', defs_of.call(blockslot, 1, '3') == [:entry])

# Post argument R3 of "1:0:1:1:0:0:0:0" (req 1, rest, post 1): the argument ENTER moves there, or nil when none was passed
# (vm.c:2700-2705, :2728). It is the post parameter's value, typed :post; the rest slot R2 is still typed as the Array.
post = program.call([insn(0, 'ENTER', "1:0:1:1:0:0:0:0\t(0x0)"), insn(2, 'MOVE', "R4\tR3"), insn(4, 'RETURN', 'R4')])
check.call('ENTER post slot: origin walk types it as the post parameter', built_of.call(post, 1, '3') == [:post])
check.call('ENTER post slot: codegen default walk still answers the entry value', defs_of.call(post, 1, '3') == [:entry])
check.call('ENTER post: the rest slot is R2 and stays typed as the Array (origin)', built_of.call(post, 1, '2') == [:rest])
check.call('ENTER post slot: the write is the ENTER (index 0)', defs_of.call(post, 1, '3', origin_transfers: true) == [0])
# Post slots of an optional+post method "1:1:0:2:0:0:0:0" (no rest): R3 and R4 are post, R2 is the optional (entry).
optpost = program.call([insn(0, 'ENTER', "1:1:0:2:0:0:0:0\t(0x0)"), insn(2, 'MOVE', "R6\tR4"), insn(4, 'RETURN', 'R6')])
check.call('ENTER post slots without a rest: R3 and R4 are post', built_of.call(optpost, 1, '3') == [:post] && built_of.call(optpost, 1, '4') == [:post])
check.call('ENTER post slots: the optional argument before them stays its entry value (negative)',
           defs_of.call(optpost, 1, '2', origin_transfers: true) == [:entry])
check.call('ENTER post slots: the register after the last post is the block, not a post (negative)',
           built_of.call(optpost, 1, '5') == [:block])

# Locals: ENTER clears every register from the first local up to nlocals with nil (vm.c:2612, :2750), so a local no
# path wrote is nil. "1:0:0:0:0:0:1:0" has R1 (arg), R2 (block); R3 and R4 are locals when nlocals is 5.
locals = lambda do |nlocals|
  program.call([insn(0, 'ENTER', "1:0:0:0:0:0:1:0\t(0x0)"), insn(2, 'MOVE', "R5\tR3"), insn(4, 'RETURN', 'R5')], nlocals: nlocals)
end
check.call('ENTER local slot (R3 < nlocals 5): origin walk types it as the nil ENTER stores', built_of.call(locals.call(5), 1, '3') == [:local])
check.call('ENTER local slot: the codegen default walk still answers the entry value', defs_of.call(locals.call(5), 1, '3') == [:entry])
check.call('ENTER local slot: a register at nlocals is a temporary ENTER does not clear, a counted refusal (negative)',
           locals.call(3).reaching_definitions(1, '3', origin_transfers: true).nil? && cause_of.call(locals.call(3), 1, '3') == 'unmodelled:ENTER:temp')
check.call('ENTER local slot: an irep without nlocals refuses the same way (negative)',
           cause_of.call(locals.call(nil), 1, '3') == 'unmodelled:ENTER:temp')
check.call('ENTER local slot: the last local (nlocals - 1) is nil, the first temporary is not (boundary)',
           built_of.call(locals.call(4), 1, '3') == [:local] && locals.call(4).reaching_definitions(1, '4', origin_transfers: true).nil?)
# An operand without the eight ASPEC fields is not ENTER's layout: a counted refusal. The operand schema rejects such a
# line at load time, so the instruction is cut down after the program is built.
malformed = program.call([insn(0, 'ENTER', "1:0:0:0:0:0:0:0\t(0x0)"), insn(2, 'MOVE', "R3\tR1"), insn(4, 'RETURN', 'R3')], nlocals: 4)
malformed.instructions[0].source.define_singleton_method(:enter_fields) { [1, 0, 0] }
check.call('ENTER with a malformed operand refuses with its own cause (negative)', cause_of.call(malformed, 1, '1') == 'unmodelled:ENTER:shape')
# A local that is written on one path and not the other joins the ENTER's nil with that write.
partial = program.call([
  insn(0, 'ENTER', "0:0:0:0:0:0:0:0\t(0x0)"), insn(2, 'JMPNOT', "R1\t8"), insn(4, 'LOADI_5', 'R2 (5)'),
  insn(6, 'JMP', '8'), insn(8, 'MOVE', "R3\tR2"), insn(10, 'RETURN', 'R3')
], nlocals: 3)
check.call('a local written on one path only: the join holds the LOADI and the ENTER nil',
           defs_of.call(partial, 4, '2', origin_transfers: true) == [0, 2] && built_of.call(partial, 4, '2') == [:local, nil])

# Negative: required parameters (1 and 2), self and an optional parameter are their entered values; ENTER keeps them exact.
req = program.call([insn(0, 'ENTER', "2:0:0:0:0:0:0:0\t(0x0)"), insn(2, 'MOVE', "R3\tR2"), insn(4, 'RETURN', 'R3')])
check.call('ENTER required parameter stays the entry value (negative)',
           defs_of.call(req, 1, '2', origin_transfers: true) == [:entry] && built_of.call(req, 1, '2') == [nil])
check.call('ENTER keeps self as the entry value (negative)',
           defs_of.call(req, 1, '0', origin_transfers: true) == [:entry])
optional = program.call([insn(0, 'ENTER', "1:1:0:0:0:0:0:0\t(0x0)"), insn(2, 'MOVE', "R3\tR2"), insn(4, 'RETURN', 'R3')])
check.call('ENTER optional parameter stays the entry value (negative)',
           defs_of.call(optional, 1, '2', origin_transfers: true) == [:entry])

# R1 of a method with a positional parameter and no keywords: ENTER can rebind it (a packed splat/keyword argument
# list is unpacked into it, vm.c:2647, :2695, :2720), so it is the parameter's value as ENTER leaves it, typed :arg, not
# the entry value. Required and optional alike; the codegen walk still answers the entry value.
check.call('ENTER without keywords: R1 is the ENTER-stored parameter value', built_of.call(req, 1, '1') == [:arg] &&
           defs_of.call(req, 1, '1', origin_transfers: true) == [0])
check.call('ENTER without keywords: R1 codegen default walk still answers the entry value', defs_of.call(req, 1, '1') == [:entry])
check.call('ENTER optional R1 (opt 1, no required): typed :arg as well',
           built_of.call(program.call([insn(0, 'ENTER', "0:1:0:0:0:0:0:0\t(0x0)"), insn(2, 'MOVE', "R3\tR1"), insn(4, 'RETURN', 'R3')]), 1, '1') == [:arg])
# Negative: with keywords (kw 1) R1 is still a positional parameter, not packed.
kw = program.call([insn(0, 'ENTER', "1:0:0:0:1:0:0:0\t(0x0)"), insn(2, 'MOVE', "R3\tR1"), insn(4, 'RETURN', 'R3')])
check.call('ENTER with keywords keeps R1 as the entry value (negative)',
           defs_of.call(kw, 1, '1', origin_transfers: true) == [:entry])
# Negative: R1 of a rest-only method is the rest Array, not a positional parameter.
check.call('ENTER rest-only: R1 is the rest Array, not :arg (negative)',
           built_of.call(program.call([insn(0, 'ENTER', "0:0:1:0:0:0:0:0\t(0x0)"), insn(2, 'MOVE', "R2\tR1"), insn(4, 'RETURN', 'R2')]), 1, '1') == [:rest])

# APOST and ARGARY write a run (R[a..a+post], R[a..a+1+kd]; BytecodeIR.written_run, vm.c OP_APOST / OP_ARGARY).
# Both walks answer the run exactly: the read of R2 is the write at index 1, which kills LOADI_5 (index 0).
apost = program.call([insn(0, 'LOADI_5', 'R2 (5)'), insn(2, 'APOST', "R1\t0\t1"), insn(4, 'MOVE', "R3\tR2"), insn(6, 'RETURN', 'R3')])
check.call('APOST writes R[a..a+post]: both walks see the APOST as the definition of R2',
           defs_of.call(apost, 2, '2', origin_transfers: true) == [1] && defs_of.call(apost, 2, '2') == [1])
check.call('APOST leaves R[a+post+1] to the entry value (both walks)',
           defs_of.call(apost, 2, '3', origin_transfers: true) == [:entry] && defs_of.call(apost, 2, '3') == [:entry])
argary = program.call([insn(0, 'LOADI_5', 'R2 (5)'), insn(2, 'ARGARY', "R1\t0:0:0:0\t(0x0)"), insn(4, 'MOVE', "R3\tR2"), insn(6, 'RETURN', 'R3')])
check.call('ARGARY writes R[a..a+1+kd]: both walks see the ARGARY as the definition of R2',
           defs_of.call(argary, 2, '2', origin_transfers: true) == [1] && defs_of.call(argary, 2, '2') == [1])
check.call('ARGARY without kd leaves R[a+2] to the entry value (both walks)',
           defs_of.call(argary, 2, '3', origin_transfers: true) == [:entry] && defs_of.call(argary, 2, '3') == [:entry])

abort("bc2cpp_origin_multiwrite_check FAILED: #{failures.join(', ')}") unless failures.empty?
puts 'bc2cpp_origin_multiwrite_check OK'
