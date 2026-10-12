#!/usr/bin/env ruby
# frozen_string_literal: true

# BytecodeIR reaching definitions (tools/bc2cpp/bytecode_ir_dataflow.rb):
# hand-built shapes with fixed answers, then a cross-check of every
# (instruction, register) query of mrbc-compiled sources against an
# independent FORWARD fixpoint. With DATAFLOW_REAL=1 the cross-check also runs
# over the closed-world gems' mrblib (slow).
require 'open3'
require 'set'
require 'tmpdir'
require_relative '../../tools/bc2cpp/irep'
require_relative '../../tools/bc2cpp/bytecode_ir'

def insn(addr, op, args)
  Insn.new(lineno: 1, addr: addr, op: op, args: args, raw: "#{op} #{args}")
end

failures = []
check = ->(label, ok) { failures << label unless ok }
program = ->(list, handlers = []) { BytecodeIR::Program.new(Irep.new(label: 't', instructions: list, catch_handlers: handlers)) }
defs_of = lambda do |prog, index, reg, **opts|
  found = prog.reaching_definitions(index, reg, **opts)
  found && found.map { |d| d.entry? ? :entry : d.index }
end

# x = c ? 5 : 7; use x        (both arms reach the join)
join = program.call([
  insn(0, 'JMPNOT', "R1\t8"), insn(3, 'LOADI_5', 'R2 (5)'), insn(5, 'JMP', '10'),
  insn(8, 'LOADI_7', 'R2 (7)'), insn(10, 'RETURN', 'R2')
])
check.call('both branch arms reach the join', defs_of.call(join, 4, '2') == [1, 3])
check.call('a register no path writes comes from the entry', defs_of.call(join, 4, '1') == [:entry])
check.call('a use inside one arm sees only that arm', defs_of.call(join, 2, '2') == [1] && defs_of.call(join, 3, '2') == [:entry])

# The write dominates the use across an unrelated branch.
across = program.call([
  insn(0, 'LOADNIL', 'R2 (nil)'), insn(2, 'JMPNOT', "R1\t8"), insn(5, 'LOADI_1', 'R3 (1)'),
  insn(8, 'MOVE', "R4\tR2"), insn(10, 'RETURN', 'R4')
])
check.call('an unrelated branch does not hide the dominating write', defs_of.call(across, 3, '2') == [0])
check.call('MOVE is followed to its source definitions', defs_of.call(across, 4, '4') == [0])
check.call('follow_moves: false stops at the MOVE', defs_of.call(across, 4, '4', follow_moves: false) == [3])

# Loop: x defined before, redefined in the body; the use in the header sees both.
loop_ = program.call([
  insn(0, 'LOADNIL', 'R2 (nil)'), insn(2, 'JMPNOT', "R1\t10"), insn(5, 'LOADI_1', 'R2 (1)'),
  insn(7, 'JMP', '2'), insn(10, 'RETURN', 'R2')
])
check.call('a loop-carried value has both definitions', defs_of.call(loop_, 1, '2') == [0, 2])
check.call('after the loop exit the same set reaches', defs_of.call(loop_, 4, '2') == [0, 2])

# A callee's frame may overwrite every register above the call's own.
call = program.call([
  insn(0, 'LOADNIL', 'R5 (nil)'), insn(2, 'SEND0', "R3\t:f"), insn(4, 'MOVE', "R7\tR5"), insn(6, 'RETURN', 'R7')
])
check.call('a register above a call is clobbered after it, not before',
           defs_of.call(call, 1, '5') == [0] && call.reaching_definitions(2, '5').nil?)
check.call('the call result is a definition of its own register', defs_of.call(call, 2, '3') == [1])
check.call('a register below the call is untouched', defs_of.call(call, 2, '0') == [:entry])

# A yield pushes its block frame at R(a) too (vm.c OP_BLKCALL: cipush(mrb, a, ...)), so a register above it is clobbered.
yield_frame = program.call([
  insn(0, 'LOADI_5', 'R3 (5)'), insn(2, 'BLKPUSH', "R2\t0:0:0:0 (0)"), insn(6, 'BLKCALL', "R2\t0"),
  insn(8, 'SEND0', "R3\t:foo"), insn(10, 'RETURN', 'R3')
])
check.call('a register above a yield frame is clobbered, not passed through', yield_frame.reaching_definitions(3, '3').nil?)
check.call('the yield result is a definition of its own register', defs_of.call(yield_frame, 3, '2') == [2])
check.call('a register below the yield frame is untouched', defs_of.call(yield_frame, 3, '1') == [:entry])

# ARGARY R(a) writes R(a) and R(a+1), and R(a+2) when kd is set (vm.c OP_ARGARY); a register below a passes through.
argary = program.call([
  insn(0, 'LOADNIL', 'R3 (nil)'), insn(2, 'ARGARY', "R2\t1:0:0:0 (0)"), insn(4, 'RETURN', 'R3')
])
check.call('ARGARY defines R(a) and R(a+1), killing the earlier write of R(a+1)',
           defs_of.call(argary, 2, '3') == [1] && defs_of.call(argary, 2, '2') == [1])
check.call('ARGARY without kd leaves R(a+2) to the entry value', defs_of.call(argary, 2, '4') == [:entry])
check.call('ARGARY leaves a register below R(a) to the entry value', defs_of.call(argary, 2, '1') == [:entry])
argary_kd = program.call([
  insn(0, 'LOADNIL', 'R4 (nil)'), insn(2, 'ARGARY', "R2\t0:0:0:1 (0)"), insn(4, 'RETURN', 'R4')
])
check.call('ARGARY with kd also defines R(a+2)', defs_of.call(argary_kd, 2, '4') == [1])

# APOST R(a) pre:post writes R(a) through R(a+post) (vm.c OP_APOST), whatever the array's length.
apost = program.call([
  insn(0, 'LOADNIL', 'R3 (nil)'), insn(2, 'APOST', "R1\t0\t2"), insn(4, 'RETURN', 'R3')
])
check.call('APOST defines R(a) through R(a+post), killing the earlier write of R(a+post)',
           defs_of.call(apost, 2, '3') == [1] && defs_of.call(apost, 2, '1') == [1] && defs_of.call(apost, 2, '2') == [1])
check.call('APOST leaves the register above R(a+post) to the entry value', defs_of.call(apost, 2, '4') == [:entry])
apost_move = program.call([
  insn(0, 'LOADNIL', 'R3 (nil)'), insn(2, 'APOST', "R1\t0\t2"), insn(4, 'MOVE', 'R5	R3'), insn(6, 'RETURN', 'R5')
])
check.call('a MOVE of an APOST-written register follows to the APOST', defs_of.call(apost_move, 3, '5') == [1])

# A raising ARGARY inside a protected range: through_handlers sees the entered value and the completed write.
raising_argary = program.call([
  insn(0, 'LOADI_1', 'R2 (1)'), insn(2, 'ARGARY', "R2\t0:0:0:0 (0)"), insn(4, 'JMP', '10'),
  insn(8, 'NOP', ''), insn(10, 'RETURN', 'R2')
], [CatchHandler.new(type: :rescue, begin_addr: 2, end_addr: 4, target: 8)])
check.call('a raising ARGARY refuses in its handler without through_handlers', raising_argary.reaching_definitions(3, '2').nil?)
check.call('a raising ARGARY reaches the handler as both the old and the completed value',
           defs_of.call(raising_argary, 3, '2', through_handlers: true) == [0, 1])

# An op outside the write model refuses.
unknown = program.call([insn(0, 'RESCUE', "R3\tR2"), insn(2, 'RETURN', 'R1')])
check.call('an unmodelled op refuses', unknown.reaching_definitions(1, '1').nil?)
opaque = program.call([insn(0, 'LOADNIL', 'R1 (nil)'), insn(2, 'RETURN', 'R1')])
check.call('an opaque register refuses', opaque.reaching_definitions(1, '1', opaque_regs: Set['1']).nil? &&
  !opaque.reaching_definitions(1, '1', opaque_regs: Set['2']).nil?)
check.call('a state cap refuses', opaque.reaching_definitions(1, '1', max_states: 0).nil?)
dead = program.call([insn(0, 'RETURN', 'R1'), insn(2, 'RETURN', 'R2')])
check.call('an unreachable use refuses', dead.reaching_definitions(1, '1').nil?)
dangling = program.call([insn(0, 'JMP', '77'), insn(2, 'RETURN', 'R1')])
check.call('an unresolved CFG refuses', dangling.reaching_definitions(1, '1').nil?)

# Exception flow: the handler target and the protected range refuse.
guarded_list = [
  insn(0, 'LOADNIL', 'R1 (nil)'), insn(2, 'SEND0', "R2\t:f"), insn(4, 'JMP', '10'),
  insn(8, 'LOADI_1', 'R3 (1)'), insn(10, 'RETURN', 'R1')
]
handler = [CatchHandler.new(type: :rescue, begin_addr: 2, end_addr: 4, target: 8)]
guarded = program.call(guarded_list, handler)
check.call('the handler target refuses', guarded.reaching_definitions(3, '1').nil?)
check.call('a use in the protected range refuses', guarded.reaching_definitions(1, '1').nil?)
check.call('the join after the range refuses through the protected instruction', guarded.reaching_definitions(4, '1').nil?)
check.call('the same code without a handler still refuses at the dead handler body',
           program.call(guarded_list).reaching_definitions(4, '1').nil?)

# through_handlers (RECORD_HASH_PROOF, docs/adr/0285) crosses handler edges instead of refusing at them.
check.call('through_handlers answers a use in the handler body from before the raise',
           defs_of.call(guarded, 3, '1', through_handlers: true) == [0])
check.call('through_handlers answers a use in the protected range', defs_of.call(guarded, 1, '1', through_handlers: true) == [0])
check.call('through_handlers answers the join after the range', defs_of.call(guarded, 4, '1', through_handlers: true) == [0])
# An instruction that writes the register and can raise contributes both the old and the new value.
raising_write = program.call([
  insn(0, 'LOADI_1', 'R1 (1)'), insn(2, 'SEND0', "R1\t:f"), insn(4, 'JMP', '10'),
  insn(8, 'NOP', ''), insn(10, 'RETURN', 'R1')
], [CatchHandler.new(type: :rescue, begin_addr: 2, end_addr: 4, target: 8)])
check.call('a raising write reaches the handler as both the old and the completed value',
           defs_of.call(raising_write, 3, '1', through_handlers: true) == [0, 1])
check.call('without the option the same query still refuses', raising_write.reaching_definitions(3, '1').nil?)

# Nested blocks: SETUPVAR writes of the level that reaches the parent.
parent = Irep.new(label: 'p', nlocals: 3, reps: ['c'], instructions: [insn(0, 'RETURN', 'R1')])
child = Irep.new(label: 'c', nlocals: 2, reps: ['g'], instructions: [insn(0, 'SETUPVAR', "R1\t2\t0")])
grand = Irep.new(label: 'g', nlocals: 1, reps: [], instructions: [insn(0, 'SETUPVAR', "R1\t1\t1"), insn(2, 'SETUPVAR', "R1\t2\t0")])
tree = { 'p' => parent, 'c' => child, 'g' => grand }
parent.tree = child.tree = grand.tree = tree
check.call('own_upvar_written_regs counts only the reaching level', BytecodeIR.own_upvar_written_regs(parent) == Set['2', '1'])
check.call('a childless irep writes no upvar', BytecodeIR.own_upvar_written_regs(grand).empty?)
orphan = Irep.new(label: 'o', nlocals: 3, reps: ['x'], instructions: [insn(0, 'RETURN', 'R1')])
check.call('without a tree every local of a block-creating irep is opaque', BytecodeIR.own_upvar_written_regs(orphan) == Set['1', '2'])

# The write whitelist stays the Fixnum proof's audited list.
source = File.read(File.expand_path('../../tools/bc2cpp/codegen_fixnum_proof.rb', __dir__))
listed = source[/FIXNUM_PROOF_STEP_OVER_OPS = Set\[(.*?)\]\.freeze/m, 1].scan(/'([A-Z0-9_]+)'/).flatten.to_set
check.call('WRITES_LEADING_REG_OPS equals FIXNUM_PROOF_STEP_OVER_OPS', listed == BytecodeIR::WRITES_LEADING_REG_OPS)

# ENTER's rest, keyword-hash, block, R1, post and local slots are typed definitions of the ENTER in the origin walk
# (Definition#built); a temporary above nlocals refuses; self, required and optional parameters (R2 and up, or R1 with
# keywords) stay the entry value. Codegen's default walk is unchanged: ENTER passes there, so every slot answers the
# entry value.
enter_built = ->(prog, index, reg) { prog.reaching_definitions(index, reg, origin_transfers: true)&.map(&:built) }
enter_origin_refuses = ->(prog, index, reg) { prog.reaching_definitions(index, reg, origin_transfers: true).nil? }
enter_codegen = ->(prog, index, reg) { prog.reaching_definitions(index, reg)&.map(&:entry?) }
enter_rest = program.call([insn(0, 'ENTER', "0:0:1:0:0:0:0:0\t(0x0)"), insn(2, 'MOVE', "R2\tR1"), insn(4, 'RETURN', 'R2')])
check.call('ENTER rest slot: origin walk types it as the Array (rest)', enter_built.call(enter_rest, 1, '1') == [:rest])
check.call('ENTER rest slot: codegen default answers the entry value', enter_codegen.call(enter_rest, 1, '1') == [true])
enter_hash = program.call([insn(0, 'ENTER', "1:0:0:0:1:0:0:0\t(0x0)"), insn(2, 'MOVE', "R4\tR2"), insn(4, 'RETURN', 'R4')])
check.call('ENTER keyword hash slot: origin walk types it as the Hash', enter_built.call(enter_hash, 1, '2') == [:hash])
check.call('ENTER keyword hash slot: codegen default answers the entry value', enter_codegen.call(enter_hash, 1, '2') == [true])
enter_block = program.call([insn(0, 'ENTER', "1:0:0:0:0:0:1:0\t(0x0)"), insn(2, 'MOVE', "R3\tR2"), insn(4, 'RETURN', 'R3')])
check.call('ENTER block slot: origin walk types it as the block', enter_built.call(enter_block, 1, '2') == [:block])
check.call('ENTER block slot: codegen default answers the entry value', enter_codegen.call(enter_block, 1, '2') == [true])
enter_kwblock = program.call([insn(0, 'ENTER', "1:0:0:0:1:0:1:0\t(0x0)"), insn(2, 'MOVE', "R4\tR3"), insn(4, 'RETURN', 'R4')])
check.call('ENTER keyword hash and block after it: R2 is the Hash, R3 the block (origin)',
           enter_built.call(enter_kwblock, 1, '2') == [:hash] && enter_built.call(enter_kwblock, 1, '3') == [:block])
enter_post = program.call([insn(0, 'ENTER', "1:0:1:1:0:0:0:0\t(0x0)"), insn(2, 'MOVE', "R4\tR3"), insn(4, 'RETURN', 'R4')])
check.call('ENTER post slot: origin walk types it as the post parameter (an argument, or nil when none was passed)',
           enter_built.call(enter_post, 1, '3') == [:post])
check.call('ENTER post slot: codegen default answers the entry value', enter_codegen.call(enter_post, 1, '3') == [true])
check.call('ENTER rest slot of a method with a post argument stays typed (origin)', enter_built.call(enter_post, 1, '2') == [:rest])
check.call('ENTER local slot past the block, nlocals unknown: origin walk refuses', enter_origin_refuses.call(enter_block, 1, '3'))
check.call('ENTER optional and required slots stay the entry value (origin)',
           enter_built.call(program.call([insn(0, 'ENTER', "1:1:0:0:0:0:0:0\t(0x0)"), insn(2, 'RETURN', 'R2')]), 1, '2') == [nil])

# ---------------------------------------------------------------------------
# Independent forward fixpoint. IN[i][reg] is the set of definitions that may
# reach instruction i: an instruction index, :entry, :clobber (a callee frame
# above the call's register) or :unknown (an op the write model does not
# cover, which taints every register until a later write kills it).
# ---------------------------------------------------------------------------
# The register run an ARGARY/APOST writes, parsed from the disassembly text (independent of the decoder):
# APOST "R<a>\t<pre>\t<post>" writes a..a+post; ARGARY "R<a>\tm1:r:m2:kd (lv)" writes a, a+1, and a+2 iff kd.
def run_of_text(insn)
  case insn.op
  when 'APOST'
    m = insn.args.match(/\AR(\d+)\t\d+\t(\d+)(?!\d)/) or return nil
    m[1].to_i..(m[1].to_i + m[2].to_i)
  when 'ARGARY'
    m = insn.args.match(/\AR(\d+)\t\d+:\d+:\d+:([01]) \(\d+\)/) or return nil
    m[1].to_i..(m[1].to_i + (m[2] == '1' ? 2 : 1))
  end
end

def forward_reaching(irep)
  prog = BytecodeIR.for(irep)
  ins = irep.instructions
  return nil unless prog.resolved?

  regs = (0...[irep.nregs.to_i, 1].max + 8).map(&:to_s)
  inn = Array.new(ins.length) { {} }
  regs.each { |r| (inn[0][r] ||= Set.new) << :entry }
  reads = %w[JMPIF JMPNOT JMPNIL RAISEIF MATCHERR SETUPVAR]
  calls = %w[SEND SEND0 SENDB SSEND SSEND0 SSENDB SUPER EXEC]
  work = [0]
  visited = Set[0]
  until work.empty?
    i = work.pop
    insn = ins[i]
    out = inn[i].transform_values(&:dup)
    if reads.include?(insn.op)
      nil
    elsif (run = run_of_text(insn))
      # ARGARY/APOST write a run (vm.c): every register of it gets this instruction as its definition.
      run.each { |r| out[r.to_s] = Set[i] }
    elsif BytecodeIR::WRITES_LEADING_REG_OPS.include?(insn.op) || insn.op.start_with?('LOADI')
      lead = insn.reg
      if calls.include?(insn.op) && lead
        regs.each { |r| out[r] = Set[:clobber] if r.to_i > lead.to_i }
      end
      out[lead] = Set[i] if lead
    else
      regs.each { |r| (out[r] ||= Set.new) << :unknown }
    end
    prog.instruction_at(i).successors.each do |s|
      changed = false
      out.each do |r, set|
        cur = (inn[s][r] ||= Set.new)
        changed = true unless set.subset?(cur)
        cur.merge(set)
      end
      work << s if changed || visited.add?(s)
    end
  end
  inn
end

def crosscheck(irep, stats)
  program = BytecodeIR.for(irep)
  forward = forward_reaching(irep)
  opaque = BytecodeIR.own_upvar_written_regs(irep)
  mismatches = []
  irep.instructions.each_index do |i|
    (0...[irep.nregs.to_i, 1].max).each do |reg|
      r = reg.to_s
      got = BytecodeIR.reaching_definitions(irep, i, r, follow_moves: false)
      want = forward && forward[i][r]
      stats[:queries] += 1
      if got.nil?
        stats[:refused] += 1
        next
      end
      if opaque.include?(r) || forward.nil?
        mismatches << [irep.label, i, r, 'answered despite opaque/unresolved']
        next
      end
      if want.nil? && program.handlers?
        stats[:handler_region] += 1 # code only an exception reaches: forward has no edge into it
        next
      end
      bad = want.nil? || want.empty? || want.include?(:clobber) || want.include?(:unknown)
      mapped = got.map { |d| d.entry? ? :entry : d.index }
      # A definition sitting in dead code that jumps into the join is a
      # harmless superset (it only costs a proof), so it may exceed +want+.
      dead_extras = (mapped.to_set - want).all? { |d| d.is_a?(Integer) && forward[d].empty? }
      if bad || !want.subset?(mapped.to_set) || !dead_extras
        mismatches << [irep.label, i, r, want&.to_a, mapped, irep.instructions.each_with_index.map { |x, n| "#{n} #{x.op} #{x.args}" }.join("\n")]
      else
        stats[:answered] += 1
        stats[:multi] += 1 if got.size > 1
      end
    end
  end
  mismatches
end

SAMPLE = <<~'RUBY'
  class K; def m(a, b = 1); a.foo; end; end
  class A; def ok; 1; end; end
  class B; def ok; 2; end; end
  def ternary(c); x = c ? A.new : B.new; x.ok; end
  def same(c); x = c ? A.new : A.new; x.ok; end
  def if_else(c); if c; y = 1; else; y = 2; end; y + 1; end
  def loop_carried(n); x = A.new; while n > 0; x.ok; x = B.new; n -= 1; end; x; end
  def unrelated(c); k = A; if c; z = 1; else; z = 2; end; k.new; end
  def or_default(a); a ||= []; a.size; end
  def blocks(list); t = 0; list.each { |e| t += e }; t; end
  def nested_blocks(list); t = A.new; list.each { |e| e.each { |f| t = f } }; t.ok; end
  def rescued(c); x = A.new; begin; x.ok; rescue StandardError; x = B.new; end; x; end
  def ensured(c); x = 1; begin; x = 2; ensure; x = 3; end; x; end
  def kwargs(a, b: 2, **rest); a + b; end
  def case_when(v); case v; when 1 then r = A.new; when 2 then r = B.new; else r = A.new; end; r.ok; end
  def and_or(a, b); (a && b) || A.new; end
  def multi(a); q, w = a; q.foo + w.foo; end
  def opt(a, b = A.new); b.ok; end
  class Z < A; def ok(a, b = 2, *r, c); super; end; end
  class Y < A; def ok(a, k: 1); super; end; end
  def splat_post(a); h, *m, t = a; m.size + t.ok; end
RUBY

stats = Hash.new(0)
mismatches = []
check_source = lambda do |src, name|
  Dir.mktmpdir do |dir|
    path = File.join(dir, "#{name}.rb")
    File.write(path, src)
    ireps, = compile_ireps(path, "bc2cpp_dataflow_#{name}", dir)
    ireps.each_value { |irep| mismatches.concat(crosscheck(irep, stats)) }
  end
end
if ENV['MRBC']
  check_source.call(SAMPLE, 'sample')
  if ENV['DATAFLOW_REAL']
    require_relative '../../tools/bc2cpp/compiled_gems'
    root = File.expand_path('../..', __dir__)
    closed_world_mrblib_srcs(root).each_slice(8).with_index do |srcs, n|
      Dir.mktmpdir do |dir|
        ireps, = compile_ireps(srcs, "bc2cpp_dataflow_real#{n}", dir)
        ireps.each_value { |irep| mismatches.concat(crosscheck(irep, stats)) }
      end
    end
  end
  check.call("forward fixpoint agrees on every answered query (#{mismatches.first(3).inspect})", mismatches.empty?)
  warn mismatches.first[5].to_s unless mismatches.empty?
  check.call('the sample answers joins and loops', stats[:multi].positive? && stats[:answered] > stats[:refused] / 4)
else
  warn 'bc2cpp_bytecode_ir_dataflow_check: MRBC unset, skipping the compiled cross-check'
end

# The same slots against mrbc's own output: each ENTER operand and the register each parameter lands in.
if ENV['MRBC']
  enter_src = <<~'RUBY'
    def rest_m(a, *r); [a, r]; end
    def kw_m(a, k: 1); [a, k]; end
    def blk_m(a, &b); [a, b]; end
    def kwblk_m(a, *r, k: 1, &b); [r, k, b]; end
    def post_m(a, *r, z); [r, z]; end
    def opt_m(a, o = 2); [a, o]; end
    def local_m(a); x = 5 if a; x; end
  RUBY
  Dir.mktmpdir do |dir|
    path = File.join(dir, 'enter_slots.rb')
    File.write(path, enter_src)
    ireps, = compile_ireps(path, 'bc2cpp_dataflow_enter_slots', dir)
    by_fields = lambda do |fields|
      ireps.each_value.find { |irep| irep.instructions.first.op == 'ENTER' && irep.instructions.first.enter_fields.join(':') == fields }
    end
    compiled = lambda do |fields, reg|
      irep = by_fields.call(fields)
      irep && BytecodeIR.reaching_definitions(irep, 1, reg, origin_transfers: true)
    end
    check.call('mrbc: every ENTER shape above compiled to its own irep',
               %w[1:0:1:0:0:0:0:0 1:0:0:0:1:0:0:0 1:0:0:0:0:0:1:0 1:0:1:0:1:0:1:0 1:0:1:1:0:0:0:0 1:1:0:0:0:0:0:0]
                 .all? { |fields| by_fields.call(fields) })
    check.call('mrbc: rest_m, the rest parameter in R2, is typed as the Array',
               compiled.call('1:0:1:0:0:0:0:0', '2')&.map(&:built) == [:rest])
    check.call('mrbc: kw_m, the keyword Hash in R2, is typed as the Hash',
               compiled.call('1:0:0:0:1:0:0:0', '2')&.map(&:built) == [:hash])
    check.call('mrbc: blk_m, the block in R2 (no keywords), is typed as the block',
               compiled.call('1:0:0:0:0:0:1:0', '2')&.map(&:built) == [:block])
    check.call('mrbc: kwblk_m puts the rest Array in R2, the Hash in R3 and the block in R4',
               compiled.call('1:0:1:0:1:0:1:0', '2')&.map(&:built) == [:rest] &&
               compiled.call('1:0:1:0:1:0:1:0', '3')&.map(&:built) == [:hash] &&
               compiled.call('1:0:1:0:1:0:1:0', '4')&.map(&:built) == [:block])
    check.call('mrbc: post_m, the post argument in R3, is typed as the post parameter',
               compiled.call('1:0:1:1:0:0:0:0', '3')&.map(&:built) == [:post])
    check.call('mrbc: the required parameter in R1 (no keywords) is typed as the parameter value',
               compiled.call('1:0:0:0:0:0:0:0', '1')&.map(&:built) == [:arg] || compiled.call('1:0:1:0:0:0:0:0', '1')&.map(&:built) == [:arg])
    check.call('mrbc: with keywords R1 stays the entry value',
               compiled.call('1:0:0:0:1:0:0:0', '1')&.map(&:built) == [nil])
    # local_m: R3 is the local x (R1 a, R2 the block slot), written on one path only, so its read joins the LOADI and
    # the nil ENTER clears it to. R5 is above nlocals (4), a temporary ENTER does not touch: refused with its own cause.
    local_irep = ireps.each_value.find { |irep| irep.instructions.first.op == 'ENTER' && irep.instructions.any? { |i| i.op == 'LOADI_5' } }
    ret = local_irep&.instructions&.index { |i| i.op == 'RETURN' }
    local_defs = ret && BytecodeIR.reaching_definitions(local_irep, ret, '3', origin_transfers: true)
    check.call('mrbc: local_m, the local written on one path, joins the LOADI and the ENTER-stored nil',
               local_defs&.map(&:built)&.to_set == Set[:local, nil])
    temp_cause = {}
    ret && BytecodeIR.reaching_definitions(local_irep, ret, (local_irep.nlocals + 1).to_s, origin_transfers: true, refusal: temp_cause)
    check.call('mrbc: the register at nlocals is a temporary, refused with its own cause', temp_cause[:cause] == 'unmodelled:ENTER:temp')
    check.call('mrbc: opt_m, the optional argument in R2, stays the entry value',
               compiled.call('1:1:0:0:0:0:0:0', '2')&.map(&:built) == [nil])
    check.call('mrbc: the ENTER-built slots are not answered by codegen (entry values, unchanged)',
               BytecodeIR.reaching_definitions(by_fields.call('1:0:1:0:1:0:1:0'), 1, '4')&.map(&:entry?) == [true])
  end
end

# ---------------------------------------------------------------------------
# Generated-code regressions: the receiver-class trace (trace_new_target) asks
# every reaching definition when its backward walk finds nothing.
# ---------------------------------------------------------------------------
TRACE_SOURCE = <<~'RUBY'
  class RdFoo
    def bar; 1; end
  end
  class RdOther
    def bar; 2; end
  end
  class RdCaller
    # The textually last write of x is on an arm that returns, so it never
    # reaches x.bar: the only reaching definition is RdFoo.new.
    def early_return(c, y)
      x = RdFoo.new
      if c
        x = y.helper
        return x
      end
      x.bar
    end

    # An opaque definition does reach the join: the class stays unproven.
    def opaque_arm(c, y)
      x = c ? RdFoo.new : y.helper
      x.bar
    end
  end
RUBY

def generate_cpp(source, name)
  Dir.mktmpdir do |dir|
    path = File.join(dir, "#{name}.rb")
    File.write(path, source)
    env = { 'MRBC' => ENV.fetch('MRBC'), 'OUT_SYMBOL' => name, 'OUT_DIR' => dir, 'SKIP_UNSUPPORTED' => '1' }
    out, err, status = Open3.capture3(env, RbConfig.ruby, File.expand_path('../../tools/bc2cpp/bc2cpp.rb', __dir__), path)
    abort "bc2cpp.rb failed for #{name}:\n#{err[-3000..] || err}" unless status.success?
    out
  end
end

def cpp_body(code, fn)
  code[/^mrb_value #{fn}_impl\(mrb_state\* M.*?(?=^(?:static )?mrb_value \w+\(mrb_state\* M|\z)/m].to_s
end

if ENV['MRBC']
  code = generate_cpp(TRACE_SOURCE, 'bc2cpp_reaching_trace')
  early = cpp_body(code, 'RdCaller_early_return')
  opaque_arm = cpp_body(code, 'RdCaller_opaque_arm')
  check.call('a write that never reaches the use does not hide the reaching class',
             early.include?('TYPED :bar -> RdFoo#bar') && !early.include?('POLY_SMALL_N :bar'))
  check.call('a reaching opaque definition keeps the class unproven',
             opaque_arm.include?('POLY_SMALL_N :bar') && !opaque_arm.include?('TYPED :bar'))
end

abort("bc2cpp_bytecode_ir_dataflow_check FAILED: #{failures.join(', ')}") unless failures.empty?
puts "bc2cpp_bytecode_ir_dataflow_check OK (#{stats.inspect})"
