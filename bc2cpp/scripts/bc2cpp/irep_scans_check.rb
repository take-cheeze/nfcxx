#!/usr/bin/env ruby
# frozen_string_literal: true

# IrepScans: the backward register walk every analysis pass shares. Each option
# (skip_ops, barrier, follow_moves, max_moves, exhausted) mirrors a rule the
# hand-rolled walks used to spell out, so each is pinned here.
require_relative '../../tools/bc2cpp/irep'

def insn(addr, op, args)
  Insn.new(lineno: 1, addr: addr, op: op, args: args, raw: "#{op} #{args}")
end

def irep(*insns)
  Irep.new(label: 't', instructions: insns)
end

failures = []
check = ->(label, ok) { failures << label unless ok }

# R3 = nil; R4 = R3; R5 = R4; R6 = foo; return R5
chain = irep(insn(0, 'LOADNIL', 'R3 (nil)'), insn(2, 'MOVE', "R4\tR3"), insn(5, 'MOVE', "R5\tR4"),
             insn(8, 'SEND', "R6\t:foo\tn=0"), insn(12, 'RETURN', 'R5'))

# follow_moves follows MOVEs without yielding them.
seen = []
res = chain.walk_writers(3, '5', follow_moves: true) { |i, index, reg| seen << [i.op, index, reg]; i.op }
check.call('follow_moves yields the rooted writer only', seen == [['LOADNIL', 0, '3']] && res == 'LOADNIL')

# Without follow_moves the block sees the MOVE and continues with Follow.
ops = []
res = chain.walk_writers(3, '5') do |i, _index, _reg|
  ops << i.op
  i.op == 'MOVE' ? IrepScans.follow(i.regs[1]) : i.op
end
check.call('manual MOVE follow', ops == %w[MOVE MOVE LOADNIL] && res == 'LOADNIL')

# The block value ends the walk, even when it is nil or false.
check.call('block nil ends the walk', chain.walk_writers(3, '5') { nil }.nil? && chain.walk_writers(3, '5') { false } == false)

# KEEP continues with the same register.
kept = irep(insn(0, 'LOADI_1', 'R1 (1)'), insn(2, 'SEND0', "R1\t:freeze"), insn(5, 'RETURN', 'R1'))
res = kept.walk_writers(1, '1') { |i| i.op == 'SEND0' ? IrepScans::KEEP : i.op }
check.call('KEEP keeps the register', res == 'LOADI_1')

# A MOVE with no source, or too many MOVEs, ends the walk with nil.
check.call('follow(nil) ends with nil', chain.walk_writers(3, '5') { IrepScans.follow(nil) }.nil?)
check.call('max_moves caps the chain', chain.walk_writers(3, '5', follow_moves: true, max_moves: 1) { 'x' }.nil?)
check.call('max_moves allows the chain', chain.walk_writers(3, '5', follow_moves: true, max_moves: 2) { 'x' } == 'x')

# exhausted receives the register the walk ended on; nil when absent.
entry = irep(insn(0, 'MOVE', "R4\tR2"), insn(3, 'RETURN', 'R4'))
check.call('exhausted gets the incoming register', entry.walk_writers(0, '4', follow_moves: true, exhausted: ->(r) { r }) { 'x' } == '2')
check.call('no exhausted -> nil', entry.walk_writers(0, '4', follow_moves: true) { 'x' }.nil?)
check.call('never written', entry.walk_writers(0, '9', exhausted: ->(r) { "entry #{r}" }) { 'x' } == 'entry 9')

# from past the end is clamped; before the start yields nothing.
check.call('from is clamped', chain.walk_writers(99, '6') { |i| i.op } == 'SEND')
check.call('from before start', chain.walk_writers(-1, '3') { 'x' }.nil?)

# skip_ops ignore an instruction even when it names the register.
skipped = irep(insn(0, 'LOADI_1', 'R1 (1)'), insn(2, 'BLOCK', "R1\tI[0]"), insn(5, 'SEND', "R2\t:x\tn=0"))
check.call('skip_ops steps over BLOCK', skipped.walk_writers(2, '1', skip_ops: %w[BLOCK]) { |i| i.op } == 'LOADI_1')
check.call('without skip_ops BLOCK is a writer', skipped.walk_writers(2, '1') { |i| i.op } == 'BLOCK')

# barrier (ops or lambda) ends the walk with barrier_result, ahead of skip_ops
# and whether or not it names the register.
barred = irep(insn(0, 'LOADI_1', 'R1 (1)'), insn(2, 'JMPUW', '9'), insn(5, 'RETURN', 'R1'))
check.call('barrier ops', barred.walk_writers(1, '1', barrier: %w[JMPUW], barrier_result: :stop) { |i| i.op } == :stop)
check.call('barrier default nil', barred.walk_writers(1, '1', barrier: %w[JMPUW]) { |i| i.op }.nil?)
check.call('barrier before skip', barred.walk_writers(1, '1', barrier: %w[JMPUW], skip_ops: %w[JMPUW], barrier_result: 1) { 'x' } == 1)
check.call('barrier lambda sees the followed register',
           chain.walk_writers(3, '5', follow_moves: true, barrier: ->(i, r) { i.op == 'LOADNIL' && r == '3' }, barrier_result: :hit) { 'x' } == :hit)

# RESCUE writes its second register: walks that must treat it as a barrier.
resc = irep(insn(0, 'EXCEPT', 'R2'), insn(2, 'RESCUE', "R2\tR3"), insn(6, 'RETURN', 'R3'))
rescue_write = ->(i, r) { i.op == 'RESCUE' && i.regs[1] == r }
check.call('rescue output is a barrier', resc.walk_writers(1, '3', barrier: rescue_write, skip_ops: %w[RESCUE], barrier_result: :w) { 'x' } == :w)
check.call('rescue input is skipped', resc.walk_writers(1, '2', barrier: rescue_write, skip_ops: %w[RESCUE]) { |i| i.op } == 'EXCEPT')

# constant_path
paths = irep(insn(0, 'GETCONST', "R1\tGame"), insn(3, 'GETMCNST', "R1\t(R1)::Sub"), insn(6, 'MOVE', "R2\tR1"),
             insn(9, 'OCLASS', 'R4'), insn(11, 'LOADNIL', 'R5 (nil)'), insn(14, 'LOADSELF', 'R6 (R0)'))
ref = paths.constant_path(2, '2')
check.call('constant_path const with scope', ref&.root == :const && ref.name == 'Game' && ref.segments == %w[Sub] &&
                                              ref.root_index == 0 && ref.qualified)
ref = paths.constant_path(0, '1')
check.call('constant_path bare const', ref&.root == :const && ref.segments.empty? && !ref.qualified)
check.call('constant_path OCLASS', paths.constant_path(5, '4')&.root == :object)
check.call('constant_path LOADNIL', paths.constant_path(5, '5')&.root == :nil)
check.call('constant_path other writer', paths.constant_path(5, '6').nil?)
check.call('constant_path never written', paths.constant_path(5, '8').nil?)
nested = irep(insn(0, 'GETCONST', "R1\tA"), insn(3, 'GETMCNST', "R1\t(R1)::B"), insn(6, 'GETMCNST', "R1\t(R1)::C"))
check.call('constant_path segments outermost first', nested.constant_path(2, '1').segments == %w[B C])
barred_path = irep(insn(0, 'GETCONST', "R1\tA"), insn(3, 'BLOCK', "R2\tI[0]"), insn(5, 'SEND', "R1\t:x\tn=0"))
check.call('constant_path barrier', barred_path.constant_path(1, '1', barrier: %w[BLOCK]).nil?)
skippable = irep(insn(0, 'GETCONST', "R1\tA"), insn(3, 'RETURN', 'R1'))
check.call('constant_path skip_ops', skippable.constant_path(1, '1', skip_ops: %w[RETURN])&.name == 'A')

# preceding_run
run = irep(insn(0, 'LOADSYM', "R1\t:a"), insn(2, 'LOADSYM', "R2\t:b"), insn(4, 'LOADSYM', "R3\t:c"), insn(6, 'SSEND', "R0\t:p\tn=3"))
check.call('preceding_run in program order', run.preceding_run('LOADSYM', 2).map(&:sym) == %w[a b c])
check.call('preceding_run limit keeps the newest', run.preceding_run('LOADSYM', 2, limit: 2).map(&:sym) == %w[b c])
check.call('preceding_run stops at another op', run.preceding_run('LOADSYM', 3).empty?)
check.call('preceding_run limit zero', run.preceding_run('LOADSYM', 2, limit: 0).empty?)
check.call('preceding_run before start', run.preceding_run('LOADSYM', -1).empty?)

# enter / each_with_op / previous_real_index
with_enter = irep(insn(0, 'ENTER', '1:0:0:0:0:0:0'), insn(4, 'LOADNIL', 'R2'), insn(6, 'SETIV', "@a\tR1"), insn(8, 'SETIV', "@b\tR2"))
check.call('enter finds ENTER', with_enter.enter&.op == 'ENTER' && with_enter.enter_index.zero?)
check.call('enter nil without ENTER', run.enter.nil? && run.enter_index.nil?)
hits = []
with_enter.each_with_op('SETIV', 'LOADNIL') { |i, index| hits << [i.op, index] }
check.call('each_with_op order and index', hits == [['LOADNIL', 1], ['SETIV', 2], ['SETIV', 3]])
exts = irep(insn(0, 'TCLASS', 'R1'), insn(2, 'EXT2', ''), insn(3, 'EXT1', ''), insn(4, 'METHOD', "R2\tI[3]"))
check.call('previous_real_index skips EXT lines', exts.previous_real_index(2) == 0 && exts.previous_real_index(3) == 3)
check.call('previous_real_index only EXT before', irep(insn(0, 'EXT1', '')).previous_real_index(0) == -1)

abort("bc2cpp_irep_scans_check FAILED: #{failures.join(', ')}") unless failures.empty?
puts 'bc2cpp_irep_scans_check OK'
