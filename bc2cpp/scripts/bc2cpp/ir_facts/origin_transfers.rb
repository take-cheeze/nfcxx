#!/usr/bin/env ruby
# frozen_string_literal: true

# Origin-only transfers (BytecodeIR::Program#origin_effect, used by the
# SiteOriginTable walk with origin_transfers: true; see
# docs/bc2cpp-dynamic-site-census.md). Each transfer has a positive case
# (the walk answers through the op) and a negative case (the answer stays a
# refusal). Codegen never passes origin_transfers:, so the default walk must
# still refuse at these ops, except a plain JMPUW and a dead predecessor.
require_relative '../../../tools/bc2cpp/irep'
require_relative '../../../tools/bc2cpp/bytecode_ir'

def insn(addr, op, args)
  Insn.new(lineno: 1, addr: addr, op: op, args: args, raw: "#{op} #{args}")
end

failures = []
check = ->(label, ok) { failures << label unless ok }
program = lambda do |list, handlers = [], nlocals: nil|
  BytecodeIR::Program.new(Irep.new(label: 't', instructions: list, catch_handlers: handlers, nlocals: nlocals))
end
defs_of = lambda do |prog, index, reg, **opts|
  found = prog.reaching_definitions(index, reg, **opts)
  found && found.map { |d| d.entry? ? :entry : d.index }
end

# JMPUW: a write before an unconditional unwinding jump still reaches the join.
#   0: LOADI_1 R1   1: JMPNOT R9 -> 8   2: JMPUW -> 10   3: LOADI_2 R2 (@8)   4: RETURN R1 (@10)
jmpuw = program.call([
  insn(0, 'LOADI_1', 'R1 (1)'), insn(2, 'JMPNOT', "R9\t8"), insn(4, 'JMPUW', '10'),
  insn(8, 'LOADI_2', 'R2 (2)'), insn(10, 'RETURN', 'R1')
])
check.call('JMPUW: the write before it reaches the join (origin walk)',
           defs_of.call(jmpuw, 4, '1', origin_transfers: true) == [0])
check.call('JMPUW outside every protected range is a plain jump: the default walk answers too (ADR 0476)',
           defs_of.call(jmpuw, 4, '1') == [0])

# JMPUW inside a protected range: its ensure unwinding is not modelled, so the origin walk still refuses.
jmpuw_guarded = program.call([
  insn(0, 'LOADI_1', 'R1 (1)'), insn(2, 'JMPNOT', "R9\t8"), insn(4, 'JMPUW', '10'),
  insn(8, 'LOADI_2', 'R2 (2)'), insn(10, 'RETURN', 'R1'), insn(12, 'RETURN', 'R2')
], [CatchHandler.new(type: :ensure, begin_addr: 4, end_addr: 6, target: 12)])
check.call('JMPUW inside a protected range refuses under the origin walk',
           jmpuw_guarded.reaching_definitions(4, '1', origin_transfers: true).nil?)
check.call('JMPUW inside a protected range refuses under the default walk',
           jmpuw_guarded.reaching_definitions(4, '1').nil?)
check.call('JMPUW inside a protected range refuses under through_handlers',
           jmpuw_guarded.reaching_definitions(4, '1', through_handlers: true).nil?)

# RESCUE a b: writes only R[b] (the match result). A query on R[b] is answered by the RESCUE.
#   0: LOADNIL R2   1: LOADNIL R3   2: RESCUE R2 R3   3: JMPNOT R3 -> 10   4: RETURN R1 (@8)   5: RETURN R3 (@10)
rescue_ = program.call([
  insn(0, 'LOADNIL', 'R2 (nil)'), insn(2, 'LOADNIL', 'R3 (nil)'), insn(4, 'RESCUE', "R2\tR3"),
  insn(6, 'JMPNOT', "R3\t10"), insn(8, 'RETURN', 'R1'), insn(10, 'RETURN', 'R3')
])
check.call('RESCUE: the query on its written register is defined by the RESCUE (origin walk)',
           defs_of.call(rescue_, 5, '3', origin_transfers: true) == [2])
check.call('RESCUE: a query on its read-only register passes through to the earlier write',
           defs_of.call(rescue_, 5, '2', origin_transfers: true) == [0])
check.call('RESCUE: the default walk still refuses at it', rescue_.reaching_definitions(5, '3').nil?)

# RESCUE inside a protected range: the walk still refuses at the protected predecessor.
rescue_guarded = program.call([
  insn(0, 'LOADNIL', 'R2 (nil)'), insn(2, 'LOADNIL', 'R3 (nil)'), insn(4, 'RESCUE', "R2\tR3"),
  insn(6, 'JMPNOT', "R3\t10"), insn(8, 'RETURN', 'R1'), insn(10, 'RETURN', 'R3')
], [CatchHandler.new(type: :rescue, begin_addr: 4, end_addr: 6, target: 8)])
check.call('RESCUE inside a protected range refuses under the origin walk',
           rescue_guarded.reaching_definitions(5, '3', origin_transfers: true).nil?)

# EXCEPT a: a handler target (guarded) that stores the exception or nil into R[a] on every entry. The walk
# reaches it only from the query, so a use of R[a] right after it is defined by the EXCEPT.
#   0: LOADNIL R1   1: SEND0 R2 (@2, protected [2,3))   2: EXCEPT R3 (@8, handler target)   3: RETURN R3 (@10)
except = program.call([
  insn(0, 'LOADNIL', 'R1 (nil)'), insn(2, 'SEND0', "R2\t:f"), insn(8, 'EXCEPT', 'R3'), insn(10, 'RETURN', 'R3')
], [CatchHandler.new(type: :rescue, begin_addr: 2, end_addr: 3, target: 8)])
check.call('EXCEPT: a use of its own register is defined by the EXCEPT (origin walk)',
           defs_of.call(except, 3, '3', origin_transfers: true) == [2])
check.call('EXCEPT: the default walk still refuses at the handler target', except.reaching_definitions(3, '3').nil?)
check.call('EXCEPT: a register it does not write is refused by the normal origin walk (the handler target is guarded)',
           except.reaching_definitions(3, '1', origin_transfers: true).nil?)

# EXCEPT writes only R[a] (vm.c OP_EXCEPT): under through_handlers another register passes through it to the
# handler edges, so a use after the handler's EXCEPT sees the value the protected send was entered with.
#   0: LOADNIL R1   1: SEND0 R2 (@2, protected [2,4))   2: JMP -> 12   3: EXCEPT R3 (@8, handler)   4: NOP (@10)   5: RETURN R1
except_pass = program.call([
  insn(0, 'LOADNIL', 'R1 (nil)'), insn(2, 'SEND0', "R2\t:f"), insn(4, 'JMP', '12'), insn(8, 'EXCEPT', 'R3'),
  insn(10, 'NOP', ''), insn(12, 'RETURN', 'R1')
], [CatchHandler.new(type: :rescue, begin_addr: 2, end_addr: 4, target: 8)])
check.call('EXCEPT: another register passes through it under through_handlers',
           defs_of.call(except_pass, 4, '1', origin_transfers: true, through_handlers: true) == [0])
check.call('EXCEPT: its own register is still the EXCEPT\'s write under through_handlers (negative)',
           defs_of.call(except_pass, 4, '3', origin_transfers: true, through_handlers: true) == [3])
# A raising send whose callee frame can reach the register still refuses: the handler path sees the clobber.
except_clobber = program.call([
  insn(0, 'LOADNIL', 'R4 (nil)'), insn(2, 'SEND0', "R2\t:f"), insn(4, 'JMP', '12'), insn(8, 'EXCEPT', 'R3'),
  insn(10, 'NOP', ''), insn(12, 'RETURN', 'R1')
], [CatchHandler.new(type: :rescue, begin_addr: 2, end_addr: 4, target: 8)])
check.call('EXCEPT: a register above the raising send\'s frame still refuses (negative)',
           except_clobber.reaching_definitions(4, '4', origin_transfers: true, through_handlers: true).nil?)
check.call('EXCEPT: the default walk still refuses at the handler target (negative)', except_pass.reaching_definitions(4, '1').nil?)

# A break out of begin/ensure: the JMPUW on the normal edge unwinds through the ensure body (vm.c OP_JMPUW, then
# RAISEIF jumps to the target), so the target reads the ensure body's write. The ensure's own fall-through does not
# reach the target. through_handlers must refuse at the normal JMPUW edge, not answer the write before it.
#   0: LOADI_5 R2   2: JMPUW -> 8 (ensure range [2,4), handler 4)   4: LOADI_1 R2 (ensure body)
#   6: RETURN R3 (the ensure's fall-through)   8: RETURN R2 (the break target)
unwind = program.call([
  insn(0, 'LOADI_5', 'R2 (5)'), insn(2, 'JMPUW', '8'), insn(4, 'LOADI_1', 'R2 (1)'),
  insn(6, 'RETURN', 'R3'), insn(8, 'RETURN', 'R2')
], [CatchHandler.new(type: :ensure, begin_addr: 2, end_addr: 4, target: 4)])
check.call('JMPUW out of an ensure range refuses at its normal edge under through_handlers',
           unwind.reaching_definitions(4, '2', origin_transfers: true, through_handlers: true).nil?)
check.call('the ensure body is still answered from its handler edge (the JMPUW writes nothing)',
           defs_of.call(unwind, 2, '2', origin_transfers: true, through_handlers: true) == [0])
check.call('codegen walk (through_handlers, no origin) still refuses at the JMPUW',
           unwind.reaching_definitions(4, '2', through_handlers: true).nil?)

# Ops outside the origin transfers keep their default answer: an unmodelled op still refuses.
unmodelled = program.call([insn(0, 'CALL', ''), insn(2, 'RETURN', 'R1')])
check.call('an op without an origin transfer still refuses under the origin walk',
           unmodelled.reaching_definitions(1, '1', origin_transfers: true).nil?)

# ENTER (vm.c OP_ENTER): each slot of its register layout is answered by the transfer for that slot (enter_slot).
# Precondition of every typed slot: the walk reached the ENTER from the method entry, so the register is read after
# ENTER ran. The layout comes from the operand (req:opt:rest:post:key:kdict:block:_); the locals need nlocals.
built_of = ->(prog, index, reg) { prog.reaching_definitions(index, reg, origin_transfers: true)&.map(&:built) }
cause_of = lambda do |prog, index, reg|
  refusal = {}
  prog.reaching_definitions(index, reg, origin_transfers: true, refusal: refusal)
  refusal[:cause]
end
enter = lambda do |fields, nlocals: nil|
  program.call([insn(0, 'ENTER', "#{fields}\t(0x0)"), insn(2, 'MOVE', "R9\tR1"), insn(4, 'RETURN', 'R9')], nlocals: nlocals)
end
# Positive, one per slot kind. "1:1:1:1:1:0:1:0" = req 1, opt 1, rest, post 1, key 1: R1 arg, R2 opt (entry), R3 rest,
# R4 post, R5 kwhash, R6 block, R7.. locals.
full = '1:1:1:1:1:0:1:0'
check.call('ENTER R1 without keywords is the parameter value (:arg)', built_of.call(enter.call('1:1:1:1:0:0:1:0'), 1, '1') == [:arg])
check.call('ENTER R1 with keywords stays the entry value', defs_of.call(enter.call(full), 1, '1', origin_transfers: true) == [:entry])
check.call('ENTER optional argument R2 stays the entry value', defs_of.call(enter.call(full), 1, '2', origin_transfers: true) == [:entry])
check.call('ENTER rest R3', built_of.call(enter.call(full), 1, '3') == [:rest])
check.call('ENTER post R4', built_of.call(enter.call(full), 1, '4') == [:post])
check.call('ENTER keyword hash R5', built_of.call(enter.call(full), 1, '5') == [:hash])
check.call('ENTER block R6', built_of.call(enter.call(full), 1, '6') == [:block])
check.call('ENTER local R7 (nlocals 9) is the nil it clears', built_of.call(enter.call(full, nlocals: 9), 1, '7') == [:local])
check.call('ENTER local R8 (nlocals 9), the last register below nlocals', built_of.call(enter.call(full, nlocals: 9), 1, '8') == [:local])
# Negative: the register at nlocals is a temporary, and an irep that does not say its nlocals has no local to name.
check.call('ENTER register at nlocals is refused as a temporary (negative)',
           cause_of.call(enter.call(full, nlocals: 9), 1, '9') == 'unmodelled:ENTER:temp')
check.call('ENTER local without nlocals is refused as a temporary (negative)', cause_of.call(enter.call(full), 1, '7') == 'unmodelled:ENTER:temp')
check.call('ENTER post with a rest slot before it is not a rest (negative)', built_of.call(enter.call(full), 1, '4') != [:rest])
check.call('ENTER typed slots are origin-only: the default walk still answers the entry value',
           %w[1 3 4 5 6].all? { |r| defs_of.call(enter.call(full), 1, r) == [:entry] })
check.call('ENTER typed slots are origin-only: the default walk still answers the entry value for a local',
           defs_of.call(enter.call(full, nlocals: 9), 1, '7') == [:entry])

# Two facts the default walk shares with the origin walk.
# A predecessor no execution reaches supplies nothing to a live state.
#   0: LOADI_1 R1   1: JMP -> 8   2: JMP -> 8 (dead)   3: LOADI_2 R1 (dead)   4: RETURN R1 (@8, the join)
dead_join = program.call([
  insn(0, 'LOADI_1', 'R1 (1)'), insn(2, 'JMP', '8'), insn(4, 'JMP', '8'), insn(6, 'LOADI_2', 'R1 (2)'),
  insn(8, 'RETURN', 'R1')
])
check.call('a dead predecessor of a live join is skipped by the default walk', defs_of.call(dead_join, 4, '1') == [0])
check.call('a dead predecessor of a live join is skipped by the origin walk',
           defs_of.call(dead_join, 4, '1', origin_transfers: true) == [0])
# A dead query keeps its dead predecessors: skipping them would answer [] (no definition), vacuously true.
#   0: LOADI_1 R1   1: RETURN R1   2: LOADI_2 R1 (dead)   3: RETURN R1 (dead, the query)
dead_tail = program.call([insn(0, 'LOADI_1', 'R1 (1)'), insn(2, 'RETURN', 'R1'), insn(4, 'LOADI_2', 'R1 (2)'),
                          insn(6, 'RETURN', 'R1')])
check.call('a dead query keeps its dead predecessors (never an empty answer)', defs_of.call(dead_tail, 3, '1') == [2])
# Live through a handler edge is live: code a rescue reaches is not skipped, the walk refuses at the handler target.
#   0: LOADNIL R1   1: SEND0 R2 (protected)   2: JMP -> 10   3: LOADI_1 R1 (handler @8)   4: RETURN R1 (@10)
handler_live = program.call([
  insn(0, 'LOADNIL', 'R1 (nil)'), insn(2, 'SEND0', "R2\t:f"), insn(4, 'JMP', '10'), insn(8, 'LOADI_1', 'R1 (1)'),
  insn(10, 'RETURN', 'R1')
], [CatchHandler.new(type: :rescue, begin_addr: 2, end_addr: 4, target: 8)])
check.call('a handler body is live: the join after it refuses', handler_live.reaching_definitions(4, '1').nil?)
check.call('without the handler the same body is dead and skipped',
           defs_of.call(program.call(handler_live.instructions.map(&:source)), 4, '1') == [0])

sharing_flag = ENV['BC2CPP_IR_SHARED_DEFINITIONS']
begin
  ENV['BC2CPP_IR_SHARED_DEFINITIONS'] = '1'
  shared_program = program.call([insn(0, 'LOADI_1', 'R1 (1)'), insn(2, 'RETURN', 'R1')])
  query_reg = '1'.dup
  shared = shared_program.reaching_definitions(1, query_reg, shared: true)
  check.call('shared cache entries are reused and deeply frozen',
             shared.equal?(shared_program.reaching_definitions(1, '1', shared: true)) && shared.frozen? &&
             shared.all? { |definition| definition.frozen? && definition.reg.frozen? })
  check.call('a shared query never freezes the caller register', !query_reg.frozen?)
  mutable = shared_program.reaching_definitions(1, '1')
  mutable.first.index = 99
  mutable.first.reg << 'changed'
  mutable.first.built = :changed
  mutable.clear
  check.call('public mutable results cannot poison shared snapshots',
             shared_program.reaching_definitions(1, '1', shared: true).map { |definition| [definition.index, definition.reg, definition.built] } == [[0, '1', nil]])
  opaque = Set['1']
  check.call('shared mutable opaque query refuses its current register',
             shared_program.reaching_definitions(1, '1', opaque_regs: opaque, shared: true).nil?)
  opaque.clear
  check.call('changing a mutable opaque set is observed by shared queries',
             shared_program.reaching_definitions(1, '1', opaque_regs: opaque, shared: true).map(&:index) == [0])
  cause = { cause: :existing }
  check.call('shared diagnostic query keeps the first caller cause',
             shared_program.reaching_definitions(1, '1', max_states: 0, refusal: cause, shared: true).nil? && cause == { cause: :existing })
  fresh_cause = {}
  shared_program.reaching_definitions(1, '1', max_states: 0, refusal: fresh_cause, shared: true)
  check.call('shared capped query reports its own refusal', fresh_cause == { cause: :state_cap })
  BytecodeIR::DATAFLOW_CACHE_SIZE.times { |index| shared_program.reaching_definitions(index + 2, '1', shared: true) }
  check.call('shared cache saturation keeps answers and the original bound',
             shared_program.reaching_definitions(1, '1', max_states: 401, shared: true).map(&:index) == [0] &&
             shared_program.instance_variable_get(:@reaching_definitions_cache).size == BytecodeIR::DATAFLOW_CACHE_SIZE)
  ENV['BC2CPP_IR_SHARED_DEFINITIONS'] = '0'
  copied_program = program.call([insn(0, 'LOADI_1', 'R1 (1)'), insn(2, 'RETURN', 'R1')])
  copies = 2.times.map { copied_program.reaching_definitions(1, '1', shared: true) }
  check.call('sharing optout retains independent public copies',
             copies.first == copies.last && !copies.first.equal?(copies.last) && !copies.first.first.equal?(copies.last.first))
ensure
  sharing_flag ? ENV['BC2CPP_IR_SHARED_DEFINITIONS'] = sharing_flag : ENV.delete('BC2CPP_IR_SHARED_DEFINITIONS')
end

query_key_flag = ENV['BC2CPP_IR_QUERY_KEYS']
begin
  query_results = %w[0 1].map do |mode|
    ENV['BC2CPP_IR_QUERY_KEYS'] = mode
    key_program = program.call([insn(0, 'LOADI_1', 'R1 (1)'), insn(2, 'RETURN', 'R1')])
    reg = '1'.dup
    before = key_program.reaching_definitions(1, reg, shared: true)
    reg.replace('9')
    check.call("query keys isolate the caller register in mode #{mode}",
               key_program.reaching_definitions(1, '1', shared: true) == before && !reg.frozen?)
    first = Set['2', '3'].freeze
    reordered = Set['3', '2'].freeze
    a = key_program.reaching_definitions(1, '1', opaque_regs: first, shared: true)
    b = key_program.reaching_definitions(1, '1', opaque_regs: reordered, shared: true)
    check.call("opaque-set order remains canonical in mode #{mode}", a.equal?(b))
    mutable_program = program.call([insn(0, 'LOADI_1', 'R1 (1)'), insn(2, 'RETURN', 'R1')])
    mutable_member = '1'.dup
    identity_set = Set.new.compare_by_identity
    identity_set << mutable_member
    identity_set.freeze
    poisoned = mutable_program.reaching_definitions(1, mutable_member, opaque_regs: identity_set, shared: true)
    mutable_member.replace('2')
    recovered = mutable_program.reaching_definitions(1, '1', opaque_regs: identity_set, shared: true)
    check.call("frozen identity sets still observe mutable members in mode #{mode}",
               poisoned.nil? && recovered&.map(&:index) == [0])
    array_program = program.call([insn(0, 'LOADI_1', 'R1 (1)'), insn(2, 'RETURN', 'R1')])
    mutable_array_member = '1'.dup
    array = [mutable_array_member].freeze
    blocked = array_program.reaching_definitions(1, '1', opaque_regs: array, shared: true)
    mutable_array_member.replace('2')
    unblocked = array_program.reaching_definitions(1, '1', opaque_regs: array, shared: true)
    check.call("frozen arrays still observe mutable members in mode #{mode}", blocked.nil? && unblocked&.map(&:index) == [0])
    if mode == '1'
      memo = key_program.instance_variable_get(:@opaque_reg_keys)
      check.call('only deeply immutable sets enter the snapshot identity memo',
                 memo.key?(first) && memo.key?(reordered) &&
                 !mutable_program.instance_variable_get(:@opaque_reg_keys).key?(identity_set) &&
                 !array_program.instance_variable_get(:@opaque_reg_keys).key?(array))
      key = memo[first]
      key_program.reaching_definitions(1, '1', opaque_regs: first, shared: true)
      check.call('immutable opaque snapshots are reused and deeply frozen',
                 memo[first].equal?(key) && key.frozen? && key.all?(&:frozen?))
      BytecodeIR::DATAFLOW_CACHE_SIZE.times do |index|
        key_program.reaching_definitions(1, '1', opaque_regs: Set[(index + 10).to_s].freeze, shared: true)
      end
      check.call('opaque snapshot memo stays bounded without losing old entries',
                 memo.size == BytecodeIR::DATAFLOW_CACHE_SIZE && memo[first].equal?(key))
    end
    [before, a, b, poisoned, recovered, blocked, unblocked]
  end
  check.call('compact query keys preserve reaching definitions across both modes', query_results[0] == query_results[1])
ensure
  query_key_flag ? ENV['BC2CPP_IR_QUERY_KEYS'] = query_key_flag : ENV.delete('BC2CPP_IR_QUERY_KEYS')
end

# The Fixnum proof's audited lists are BytecodeIR's, not copies kept equal by a check.
proof = File.read(File.expand_path('../../../tools/bc2cpp/codegen_fixnum_proof.rb', __dir__))
check.call('FIXNUM_PROOF_STEP_OVER_OPS is WRITES_LEADING_REG_OPS itself',
           proof.include?("FIXNUM_PROOF_STEP_OVER_OPS = BytecodeIR::WRITES_LEADING_REG_OPS\n"))
check.call('FIXNUM_PROOF_READONLY_REG_OPS is derived from BytecodeIR::Ops::READS_LEAD',
           proof.include?('FIXNUM_PROOF_READONLY_REG_OPS = (BytecodeIR::Ops::READS_LEAD & FIXNUM_PROOF_STEP_OVER_OPS)') &&
             (BytecodeIR::Ops::READS_LEAD & BytecodeIR::WRITES_LEADING_REG_OPS) == Set['JMPIF', 'JMPNOT', 'JMPNIL'])
check.call('the Fixnum proof keeps no reaching-definitions walk of its own',
           !proof.include?('def fixnum_proof_reaching_defs?') && proof.include?('every_reaching_definition('))

abort("bc2cpp_origin_transfers_check FAILED: #{failures.join(', ')}") unless failures.empty?
puts 'bc2cpp_origin_transfers_check OK'
