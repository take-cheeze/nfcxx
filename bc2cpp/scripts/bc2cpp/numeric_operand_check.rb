#!/usr/bin/env ruby
# frozen_string_literal: true

# NUMERIC_OPERAND_PROOF: guarded arithmetic and compare arms lose
# their dynamic-send else when both operands are PROVEN Integer/Float, and keep it
# for every operand a proof cannot cover.
#
# 1. Host only (no mrbc): NumericFlow, the forward dataflow behind the proof, on
#    hand-built instruction lists -- literals, the arithmetic closure, loops,
#    joins, nil and its branch refinement, optional-argument entry, calls,
#    captured registers, unmodelled ireps.
# 2. With MRBC: the generated code of a closed-world fixture. Positive cases
#    (ivars written only with numbers, pooled arguments, Array#size, constants,
#    loop counters, recursion) must lose the send; negative cases (an ivar also
#    written a String/nil/Float-vs-Integer mix, written by attr_writer or
#    instance_variable_set, written by a subclass, read before it is assigned,
#    an argument some call site passes a String, a name a native also defines)
#    must keep it.
# 3. With BC2CPP_MRUBY_CORE and g++: the fixture runs on real mruby, interpreted
#    and compiled, and must answer alike -- values, exceptions and Integer
#    overflow -- while the proven methods make no dynamic dispatch at all.
#
# Usage: [MRBC=path/to/mrbc BC2CPP_MRUBY_CORE=dir] ruby scripts/bc2cpp/numeric_operand_check.rb

require 'set'
require 'tmpdir'
require_relative '../../tools/bc2cpp/irep'
require_relative '../../tools/bc2cpp/bytecode_ir'
require_relative '../../tools/bc2cpp/numeric_flow'

failures = []
check = lambda do |what, condition|
  puts "  #{condition ? 'ok  ' : 'FAIL'} #{what}"
  failures << what unless condition
end

NF = NumericFlow
INT = NF::INT
FLT = NF::FLT
ARR = NF::ARR
NIL_ = NF::NIL
OTHER = NF::OTHER

def insn(addr, op, args)
  Insn.new(lineno: 1, addr: addr, op: op, args: args, raw: "#{op} #{args}")
end

def irep_of(list, handlers: [], nregs: 8)
  Irep.new(label: "nf#{list.hash}", nregs: nregs, instructions: list, catch_handlers: handlers, reps: [], pool: [])
end

# An oracle answering what each test configures and OTHER/false otherwise.
class StubOracle
  attr_accessor :entry, :slots, :entry_slot, :fact, :nil_raises, :native, :sends

  def initialize
    @entry = {}
    @slots = []
    @entry_slot = {}
    @fact = {}
    @nil_raises = true
    @native = true
    @sends = {}
  end

  def entry_mask(_irep, reg) = @entry.fetch(reg, NumericFlow::OTHER)
  def const_mask(_insn) = NumericFlow::OTHER
  def ivar_slots(_irep) = @slots
  def ivar_entry_mask(_irep, name) = @entry_slot.fetch(name, NumericFlow::OTHER)
  def ivar_fact_mask(_irep, name) = @fact.fetch(name, NumericFlow::OTHER)
  def send_mask(_irep, _index, insn, _state) = @sends.fetch(insn.sym, NumericFlow::OTHER)
  def pool_mask(_irep, insn) = insn.pool_index.to_i.zero? ? NumericFlow::FLT : NumericFlow::INT
  def op_native?(_sym) = @native
  def nil_raises?(_sym) = @nil_raises
end

flow = lambda do |list, oracle = StubOracle.new, opaque = Set.new, **irep_options|
  NumericFlow.states(irep_of(list, **irep_options), oracle, opaque)
end
names = ->(mask) { { INT => 'INT', FLT => 'FLT', ARR => 'ARR', NIL_ => 'NIL', OTHER => 'OTHER' }.select { |bit, _| mask.anybits?(bit) }.values.join('|') }

puts '-- NumericFlow (host)'
straight = [insn(0, 'LOADI_1', "R2\t(1)"), insn(2, 'LOADI_2', "R3\t(2)"), insn(4, 'ADD', "R2\t(R3)"),
            insn(6, 'MUL', "R2\t(R3)"), insn(8, 'RETURN', 'R2')]
states = flow.call(straight)
check.call('Integer literals stay Integer through ADD and MUL', states[4][2] == INT && states[3][2] == INT)
check.call('a register never written is unknown, not numeric', states[0][5] == OTHER)
check.call('a non-native operator gives no fact',
           begin
             oracle = StubOracle.new.tap { |o| o.native = false }
             (flow.call(straight, oracle)[4][2] & OTHER) != 0
           end)

float_mix = [insn(0, 'LOADI_1', "R2\t(1)"), insn(2, 'LOADL', "R3\tL[0]"), insn(5, 'ADD', "R2\t(R3)"), insn(7, 'RETURN', 'R2')]
check.call('Integer + Float is Float', flow.call(float_mix)[3][2] == FLT)
join = [insn(0, 'JMPNOT', "R1\t9"), insn(4, 'LOADI_1', "R2\t(1)"), insn(6, 'JMP', '12'), insn(9, 'LOADL', "R2\tL[0]"),
        insn(12, 'RETURN', 'R2')]
check.call('a join of an Integer arm and a Float arm holds both classes', flow.call(join)[4][2] == (INT | FLT))
opaque_arm = [insn(0, 'JMPNOT', "R1\t9"), insn(4, 'LOADI_1', "R2\t(1)"), insn(6, 'JMP', '11'), insn(9, 'SEND0', "R2\t:f"),
              insn(11, 'RETURN', 'R2')]
check.call('an arm of unknown class makes the join unknown', flow.call(opaque_arm)[4][2].anybits?(OTHER))

counter = [insn(0, 'LOADI_0', "R2\t(0)"), insn(2, 'JMPNOT', "R1\t12"), insn(6, 'ADDI', "R2\t1"), insn(9, 'JMP', '2'),
           insn(12, 'RETURN', 'R2')]
check.call('a loop-carried counter is Integer at the loop head', flow.call(counter)[1][2] == INT)
float_loop = [insn(0, 'LOADI_0', "R2\t(0)"), insn(2, 'JMPNOT', "R1\t13"), insn(6, 'LOADL', "R3\tL[0]"),
              insn(9, 'ADD', "R2\t(R3)"), insn(11, 'JMP', '2'), insn(13, 'RETURN', 'R2')]
check.call('a loop that turns the counter into a Float is Integer-or-Float, never plain Integer',
           flow.call(float_loop)[1][2] == (INT | FLT))
poisoned_loop = [insn(0, 'LOADI_0', "R2\t(0)"), insn(2, 'JMPNOT', "R1\t11"), insn(6, 'SEND0', "R2\t:next"), insn(9, 'JMP', '2'),
                 insn(11, 'RETURN', 'R2')]
check.call('a loop that also stores an unknown call result is unknown', flow.call(poisoned_loop)[1][2].anybits?(OTHER))

oracle = StubOracle.new.tap { |o| o.entry = { 2 => INT | NIL_ } }
nil_then = [insn(0, 'ADDI', "R2\t1"), insn(3, 'RETURN', 'R2')]
check.call('nil in a receiver only raises when nil has no such operator: the result is Integer',
           flow.call(nil_then, oracle)[1][2] == INT)
oracle.nil_raises = false
check.call('a nil receiver that could answer `+` makes the result unknown', flow.call(nil_then, oracle)[1][2].anybits?(OTHER))
oracle.nil_raises = true
refine = [insn(0, 'JMPNOT', "R2\t8"), insn(4, 'ADDI', "R2\t1"), insn(7, 'RETURN', 'R2'), insn(8, 'RETURN', 'R2')]
states = flow.call(refine, oracle)
check.call('a truthiness test removes nil from the register on the truthy edge', states[1][2] == INT)
check.call('and leaves only nil on the falsy edge', states[3][2] == NIL_)
jmpnil = [insn(0, 'JMPNIL', "R2\t8"), insn(4, 'RETURN', 'R2'), insn(8, 'RETURN', 'R2')]
states = flow.call(jmpnil, oracle)
check.call('JMPNIL: not nil on the fall-through edge, nil on the taken edge', states[1][2] == INT && states[2][2] == NIL_)
alias_test = [insn(0, 'MOVE', "R3\tR2"), insn(3, 'JMPNOT', "R3\t9"), insn(7, 'RETURN', 'R2'), insn(9, 'RETURN', 'R2')]
states = flow.call(alias_test, oracle)
check.call('testing a copy narrows the variable it was copied from', states[2][2] == INT && states[3][2] == NIL_)
stale_alias = [insn(0, 'MOVE', "R3\tR2"), insn(3, 'LOADNIL', "R2\t(nil)"), insn(5, 'JMPNOT', "R3\t11"),
               insn(9, 'RETURN', 'R2'), insn(11, 'RETURN', 'R2')]
states = flow.call(stale_alias, oracle)
check.call('a copy no longer mirrors a variable written after the copy', states[3][2] == NIL_ && states[3][3] == INT)
dead_edge = [insn(0, 'LOADI_1', "R2\t(1)"), insn(2, 'JMPNIL', "R2\t9"), insn(6, 'RETURN', 'R2'), insn(9, 'RETURN', 'R2')]
check.call('an edge the tested register can never take is infeasible (nil state)', flow.call(dead_edge)[3].nil?)

# Boolean and Symbol literals carry their class bits (ExactOracle#literal_class_mask); FalseClass is falsy like nil.
class LiteralBitOracle < StubOracle
  TRUE_BIT = 1 << 9
  FALSE_BIT = 1 << 10
  SYM_BIT = 1 << 11

  def literal_class_mask(insn) = { 'LOADTRUE' => TRUE_BIT, 'LOADFALSE' => FALSE_BIT, 'LOADSYM' => SYM_BIT }[insn.op]
  def false_class_bit = FALSE_BIT
end
bits = LiteralBitOracle.new
check.call('a true literal is its own class bit',
           flow.call([insn(0, 'LOADTRUE', "R2\t(true)"), insn(2, 'RETURN', 'R2')], bits)[1][2] == LiteralBitOracle::TRUE_BIT)
check.call('a Symbol literal is its own class bit',
           flow.call([insn(0, 'LOADSYM', "R2\t:a"), insn(2, 'RETURN', 'R2')], bits)[1][2] == LiteralBitOracle::SYM_BIT)
check.call('without the oracle a true literal stays unknown', flow.call([insn(0, 'LOADTRUE', "R2\t(true)"), insn(2, 'RETURN', 'R2')])[1][2] == OTHER)
false_jmpif = [insn(0, 'LOADFALSE', "R2\t(false)"), insn(2, 'JMPIF', "R2\t8"), insn(6, 'RETURN', 'R2'), insn(8, 'RETURN', 'R2')]
states = flow.call(false_jmpif, bits)
check.call('a false literal reaches the falsy edge of a truthiness test', states[2][2] == LiteralBitOracle::FALSE_BIT)
check.call('and makes the truthy edge infeasible (false is not truthy)', states[3].nil?)
true_jmpnot = [insn(0, 'LOADTRUE', "R2\t(true)"), insn(2, 'JMPNOT', "R2\t8"), insn(6, 'RETURN', 'R2'), insn(8, 'RETURN', 'R2')]
states = flow.call(true_jmpnot, bits)
check.call('a true literal reaches the truthy edge of a negated test', states[2][2] == LiteralBitOracle::TRUE_BIT)
check.call('and makes the falsy edge infeasible (true is not falsy)', states[3].nil?)
false_jmpnil = [insn(0, 'LOADFALSE', "R2\t(false)"), insn(2, 'JMPNIL', "R2\t8"), insn(6, 'RETURN', 'R2'), insn(8, 'RETURN', 'R2')]
states = flow.call(false_jmpnil, bits)
check.call('JMPNIL on a false literal: the taken edge is infeasible (false is not nil)', states[3].nil?)
# A class bit that arrives from outside the method (a call result, a pool) is narrowed by the FalseClass bit the oracle
# names; an oracle that names none must keep it on both edges, since it may be false.
entered = [insn(0, 'JMPIF', "R2\t4"), insn(2, 'RETURN', 'R2'), insn(4, 'RETURN', 'R2')]
named = LiteralBitOracle.new.tap { |o| o.entry = { 2 => LiteralBitOracle::FALSE_BIT } }
states = flow.call(entered, named)
check.call('a FalseClass value from outside reaches the falsy edge of a truthiness test', states[1][2] == LiteralBitOracle::FALSE_BIT)
check.call('and makes the truthy edge infeasible when the oracle names the bit', states[2].nil?)
unnamed = StubOracle.new.tap { |o| o.entry = { 2 => LiteralBitOracle::FALSE_BIT } }
states = flow.call(entered, unnamed)
check.call('an oracle that names no FalseClass bit keeps a class bit on the falsy edge', states[1][2] == LiteralBitOracle::FALSE_BIT)
check.call('and on the truthy edge (it may be truthy too)', states[2][2] == LiteralBitOracle::FALSE_BIT)

called = [insn(0, 'LOADI_1', "R3\t(1)"), insn(2, 'LOADI_2', "R1\t(2)"), insn(4, 'SEND0', "R2\t:f"), insn(6, 'RETURN', 'R2')]
states = flow.call(called)
check.call('a call clobbers every register above its receiver', states[3][3] == OTHER)
check.call('and leaves the ones below untouched', states[3][1] == INT)
check.call('the call result is what the oracle says', begin
  oracle = StubOracle.new.tap { |o| o.sends = { 'f' => FLT } }
  flow.call(called, oracle)[3][2] == FLT
end)

check.call('a register a nested block writes is never numeric',
           flow.call(straight, StubOracle.new, Set['2'])[4][2] == OTHER)
check.call('an irep whose handler target is not an instruction has no facts',
           flow.call(straight, StubOracle.new, Set.new, handlers: [CatchHandler.new(type: :rescue, begin_addr: 0,
                                                                                    end_addr: 4, target: 99)]).nil?)
rescued = [insn(0, 'LOADI_1', "R2\t(1)"), insn(2, 'LOADI_2', "R4\t(2)"), insn(4, 'SEND0', "R3\t:f"),
           insn(6, 'LOADNIL', "R2\t(nil)"), insn(8, 'JMP', '14'), insn(10, 'RETURN', 'R2'), insn(14, 'RETURN', 'R2')]
rescue_states = flow.call(rescued, StubOracle.new, Set.new,
                          handlers: [CatchHandler.new(type: :rescue, begin_addr: 4, end_addr: 8, target: 10)])
check.call('a handler starts from the state at any raise in its range: the value before or after the write',
           rescue_states && rescue_states[5][2] == (INT | NIL_))
check.call('a raising call clobbers the registers from its own up in the handler',
           rescue_states && rescue_states[5][4].anybits?(OTHER))
check.call('the normal path past the range is unaffected by the handler', rescue_states && rescue_states[6][2] == NIL_)
check.call('a handler target nothing can raise into stays unreached',
           flow.call(rescued, StubOracle.new, Set.new,
                     handlers: [CatchHandler.new(type: :rescue, begin_addr: 100, end_addr: 104, target: 10)])[5].nil?)
check.call('EXCEPT and RESCUE are modelled: the match flag is unknown, the exception register too',
           flow.call([insn(0, 'EXCEPT', 'R2'), insn(2, 'RESCUE', "R2\tR3"), insn(5, 'RETURN', 'R3')])[2][3] == OTHER)
check.call('a Range literal is exactly a Range', flow.call([insn(0, 'LOADI_1', "R2\t(1)"), insn(2, 'LOADI_2', "R3\t(2)"),
                                                            insn(4, 'RANGE_INC', 'R2'), insn(6, 'RETURN', 'R2')])[3][2] == NF::RNG)
check.call('an opcode outside the audited write list has no facts',
           flow.call([insn(0, 'APOST', "R2\t1\t0"), insn(4, 'RETURN', 'R2')]).nil?)

optional = [insn(0, 'ENTER', '0:1:0:0:0:0:0:0 (0x1000)'), insn(4, 'JMP', '14'), insn(7, 'JMP', '16'),
            insn(10, 'NOP', ''), insn(11, 'NOP', ''), insn(14, 'LOADI_5', "R1\t(5)"), insn(16, 'ADDI', "R1\t1"),
            insn(19, 'RETURN', 'R1')]
states = flow.call(optional)
check.call('the jump table after an OP_ENTER with optional arguments is reachable through every slot',
           !states[2].nil? && !states[5].nil?)
check.call('a default the caller may or may not supply is Integer-or-unknown', states[6][1] == (INT | OTHER))

slot_oracle = StubOracle.new.tap do |o|
  o.slots = ['a']
  o.entry_slot = { 'a' => INT | NIL_ }
  o.fact = { 'a' => INT }
end
slots = [insn(0, 'GETIV', "R2\t@a"), insn(3, 'LOADI_1', "R3\t(1)"), insn(5, 'SETIV', "@a\tR3"), insn(8, 'GETIV', "R4\t@a"),
         insn(11, 'RETURN', 'R4')]
states = flow.call(slots, slot_oracle)
check.call('an ivar not yet assigned reads its entry class or nil', states[1][2] == (INT | NIL_))
check.call('after SETIV the slot is the assigned value', states[4][4] == INT)
slot_test = [insn(0, 'GETIV', "R2\t@a"), insn(3, 'JMPNOT', "R2\t12"), insn(7, 'GETIV', "R3\t@a"), insn(10, 'RETURN', 'R3'),
             insn(12, 'RETURN', 'R2')]
states = flow.call(slot_test, slot_oracle)
check.call('testing a register loaded from a slot narrows the slot itself', states[3][3] == INT && states[3][2] == INT)
called_slot = [insn(0, 'LOADNIL', "R3\t(nil)"), insn(2, 'SETIV', "@a\tR3"), insn(5, 'SEND0', "R2\t:f"), insn(7, 'GETIV', "R4\t@a"),
               insn(10, 'RETURN', 'R4')]
states = flow.call(called_slot, slot_oracle)
check.call('a call may store anything the ivar\'s whole-program fact allows', states[4][4] == (NIL_ | INT))
idx_oracle = StubOracle.new.tap do |o|
  o.slots = ['a']
  o.entry_slot = { 'a' => INT }
  o.fact = { 'a' => NIL_ }
end
idx_slot = lambda do |op, operand|
  [insn(0, 'LOADI_1', "R3\t(1)"), insn(2, 'SETIV', "@a\tR3"), insn(5, 'LOADNIL', "R2\t(nil)"),
   insn(7, operand ? 'ARRAY' : 'LOADNIL', operand ? "R4\t0" : "R4\t(nil)"), insn(10, 'LOADI_1', "R5\t(1)"),
   insn(12, op, "R4\t(R5)\t(R5)"), insn(14, 'GETIV', "R6\t@a"), insn(17, 'RETURN', 'R6')]
end
states = flow.call(idx_slot.call('SETIDX', false), idx_oracle)
check.call('SETIDX on a receiver that is not an exact Array may run a user #[]=: the slot is reset to its fact',
           states[7][6] == (INT | NIL_))
states = flow.call(idx_slot.call('SETIDX', true), idx_oracle)
check.call('SETIDX on an exact Array with an Integer index runs no Ruby: the slot keeps its class', states[7][6] == INT)

if ENV['MRBC']
  require_relative 'fixture_runtime'
  runtime = Bc2cppFixtureRuntime

  fixture = <<~RUBY
    module NqConfig
      NQ_W = 4
      NQ_H = NQ_W * 2 + 1
      NQ_MIX = 1
      NQ_RATIO = NQ_H / 2.0
    end

    module NqOther
      NQ_MIX = "s"
    end

    class NqBox
      def initialize
        @nq_refl_v = 0
        @nq_a = 0
        @nq_f = 2.5
        @nq_list = []
        @nq_lazy = nil
        @nq_mix = 0
        @nq_flt = 0
        @nq_late = nil
      end

      def nq_step
        @nq_a += 1
        @nq_a * 3
      end

      def nq_scale(n)
        @nq_f * n
      end

      def nq_area(w, h)
        w * h + 1
      end

      def nq_half(v)
        v / 2
      end

      def nq_less(a, b)
        a < b
      end

      def nq_push
        @nq_list << 1
      end

      def nq_len
        @nq_list.size + 1
      end

      def nq_sum(n)
        i = 0
        s = 0
        while i < n
          s += i * 2
          i += 1
        end
        s
      end

      def nq_fact(n)
        n < 2 ? 1 : n * nq_fact(n - 1)
      end

      def nq_rescued
        x = @nq_a + 1
        begin
          x = x * 2 + (@nq_a + 3)
        rescue ArgumentError
          x = 0
        end
        x + 1
      end

      def nq_rescued_str
        x = @nq_a + 1
        begin
          x = "s"
        rescue ArgumentError
          x = 0
        end
        x + 1
      end

      def nq_block_ret
        [1].each { |_v| return 5 }
        3
      end

      def nq_block_ret_use
        nq_block_ret + 1
      end

      def nq_edge
        x = @nq_list.size + 2_000_000_000
        x * x * x
      end

      def nq_taint
        @nq_mix = "s"
      end

      def nq_mix_use
        @nq_mix + 1
      end

      def nq_lazy_bump
        @nq_lazy += 1
      end

      def nq_setf
        @nq_flt = 1.5
      end

      def nq_flt_use
        @nq_flt + 1
      end

      def nq_refl
        instance_variable_set(:@nq_refl_v, "s")
      end

      def nq_refl_use
        @nq_refl_v + 1
      end

      def nq_refl_float
        @nq_refl_v = 1.5
      end

      def nq_late_set
        @nq_late = 5
      end

      def nq_late_use
        @nq_late + 1
      end

      def nq_guarded
        return 0 unless @nq_late

        @nq_late + 1
      end

      def nq_mixed_arg(x)
        x + 1
      end

      def nq_const_use
        NqConfig::NQ_H * 3 + 1
      end

      def nq_ratio_use
        NqConfig::NQ_RATIO + 1
      end

      def nq_mix_const
        NqConfig::NQ_MIX + 1
      end

      def nq_find(x)
        x > 0 ? 1 : nil
      end

      def nq_find_unchecked
        r = nq_find(2)
        r + 1
      end

      def nq_find_checked
        r = nq_find(2)
        r ? r + 1 : 0
      end

      def nq_send_target(x)
        x + 1
      end

      def nq_send_call
        nq_send_target(1)
        send(:nq_send_target, "s")
      end

      def nq_captured(list)
        w = 3
        f = 1.5
        list.each { |e| w * w + f }
        w
      end

      def nq_captured_written(list)
        total = 0
        list.each { |e| total += 1 }
        total + 1
      end

      def nq_captured_late(list)
        late = nil
        list.each { |e| 1 + late }
        late = 1
      end

      def nq_argsize(list)
        list.size + 1
      end

      def nq_mixsize(list)
        list.size + 1
      end

      def nq_run
        nq_step
        nq_scale(2)
        nq_area(3, 4)
        nq_area(2, 5)
        nq_half(9.0)
        nq_half(4)
        nq_less(1, 2)
        nq_less(1.5, 2)
        nq_push
        nq_len
        nq_sum(5)
        nq_fact(5)
        nq_mixed_arg(1)
        nq_mixed_arg("a")
        nq_const_use
        nq_ratio_use
        nq_mix_const
        nq_find_unchecked
        nq_find_checked
        nq_refl_use
        nq_send_call
        nq_captured([1, 2])
        nq_captured_written([1])
        nq_captured_late([1])
        nq_argsize([1, 2])
        nq_argsize([])
        nq_mixsize([1])
        nq_mixsize(:ab)
      end
    end

    class NqWriter
      attr_accessor :nq_acc

      def initialize
        @nq_acc = 0
      end

      def nq_acc_use
        @nq_acc + 1
      end

      def nq_acc_float
        @nq_acc = 1.5
      end
    end

    class NqBase
      def initialize
        @nq_shared = 0
        @nq_up = 0
      end

      def nq_shared_use
        @nq_shared + 1
      end

      def nq_up_use
        @nq_up + 1
      end
    end

    class NqSub < NqBase
      def initialize
        super
        @nq_own = 0
      end

      def nq_poison
        @nq_shared = "s"
      end

      def nq_own_use
        @nq_own + 1
      end
    end

    class NqLatePar
      def initialize
        nq_late_hook
        @nq_lp = 0
      end

      def nq_late_hook; end

      def nq_lp_use
        @nq_lp + 1
      end
    end

    class NqSizeShadow
      def size
        "x"
      end

      def nq_use(o)
        o.size + 1
      end
    end

    class NqHidden
      def initialize
        @nq_h = 1
      end

      def []=(_i, _v)
        @nq_h = "s"
      end

      def to_s
        @nq_h = "s"
        "t"
      end

      def +(_other)
        @nq_h = "s"
        self
      end

      def nq_setidx
        @nq_h = 1
        self[0] = 2
        @nq_h + 1
      end

      def nq_interp
        @nq_h = 1
        @nq_s = "x\#{self}"
        @nq_h + 1
      end

      def nq_operator
        @nq_h = 1
        self + 1
        @nq_h + 1
      end
    end

    class NqDrv
      def nq_go
        b = NqBox.new
        b.nq_run
        w = NqWriter.new
        w.nq_acc = "str"
        w.nq_acc_use
        NqSub.new.nq_own_use
        NqSizeShadow.new.nq_use(NqSizeShadow.new)
      end
    end
  RUBY

  # The guarded arms tag themselves; an arm that lost its send has neither tag.
  retained_tag = %r{// (?:FIXNUM_ARITHMETIC|FIXNUM_COMPARE|FLOAT_DIV_RECEIVER) :}
  chunk_of = lambda do |code, owner_method|
    # Block functions of the next method are emitted before its header comment.
    code[/^\/\/ #{Regexp.escape(owner_method)} \(compiled from.*?(?=^\/\/ \S+#\S+ \(compiled from|^static mrb_value \S+_block_fallback_|\z)/m].to_s
  end
  # The method's own code plus the functions compiled for the blocks it creates.
  with_blocks = lambda do |code, owner_method|
    prefix = Regexp.escape(owner_method.tr('#', '_'))
    chunk_of.call(code, owner_method) + code.scan(/^static mrb_value #{prefix}_block_fallback_\d+_impl.*?^\}\n(?=\nstatic mrb_value )/m).join
  end

  puts '-- generated code (closed world)'
  code = nil
  err = nil
  Dir.mktmpdir do |dir|
    code, err = runtime.generate(fixture, dir)
  end
  # Every arithmetic/compare site of the method is proven (by the numeric proof or
  # by the Fixnum proof) and none kept its dynamic-send else.
  proven = lambda do |method|
    chunk = with_blocks.call(code, method)
    !chunk.empty? && !chunk.match?(retained_tag) &&
      (chunk.include?('NUMERIC_OPERAND_PROOF') || chunk.include?('operands proven Fixnum'))
  end
  kept = lambda do |method|
    chunk = with_blocks.call(code, method)
    !chunk.empty? && chunk.match?(retained_tag)
  end
  numeric_note = ->(method) { chunk_of.call(code, method).include?('NUMERIC_OPERAND_PROOF') }

  check.call('an ivar written only Integer literals and `+= 1` proves (embedded or not)', proven.call('NqBox#nq_step'))
  check.call('a Float-only ivar times a pooled Integer argument', proven.call('NqBox#nq_scale') && numeric_note.call('NqBox#nq_scale'))
  check.call('arguments every call site passes an Integer prove', proven.call('NqBox#nq_area'))
  check.call('an argument passed an Integer at one site and a Float at another proves as Integer-or-Float',
             proven.call('NqBox#nq_half') && numeric_note.call('NqBox#nq_half'))
  check.call('a comparison of pooled numeric arguments loses its send', proven.call('NqBox#nq_less'))
  check.call('Array#size of an ivar that only ever holds an exact Array is an Integer',
             proven.call('NqBox#nq_len') && numeric_note.call('NqBox#nq_len'))
  check.call('Array#size of an argument an exact Array at every call site is an Integer',
             proven.call('NqBox#nq_argsize'))
  check.call('NEG: Array#size of an argument one site passes a Symbol keeps its send',
             kept.call('NqBox#nq_mixsize'))
  check.call('a while-loop counter, accumulator and a pooled bound prove', proven.call('NqBox#nq_sum'))
  check.call('a recursive method proves itself: argument, `n - 1`, product and return',
             proven.call('NqBox#nq_fact'))
  check.call('Integer arithmetic past the fixnum range still proves, through the overflow-checked tier',
             proven.call('NqBox#nq_edge') && chunk_of.call(code, 'NqBox#nq_edge').include?('mrb_int_mul_overflow') &&
               chunk_of.call(code, 'NqBox#nq_edge').include?('mrb_num_mul(M'))
  check.call('an ivar that is Integer or Float proves for both classes', proven.call('NqBox#nq_flt_use'))
  check.call('reading an ivar after a nil test on it proves (the test narrows the slot)', proven.call('NqBox#nq_guarded'))

  check.call('NEG: an ivar also assigned a String keeps its send', kept.call('NqBox#nq_mix_use'))
  check.call('NEG: `@x += 1` where @x starts nil keeps its send', kept.call('NqBox#nq_lazy_bump'))
  check.call('NEG: an ivar first assigned outside #initialize may be nil at the read', kept.call('NqBox#nq_late_use'))
  check.call('NEG: an ivar that instance_variable_set can write keeps its send', kept.call('NqBox#nq_refl_use'))
  check.call('constants defined from constants, `*`, `+` and `/` prove as Integer/Float',
             proven.call('NqBox#nq_const_use') && proven.call('NqBox#nq_ratio_use'))
  check.call('NEG: a constant name another scope binds to a String keeps its send', kept.call('NqBox#nq_mix_const'))
  check.call('a method with a rescue clause has facts: both paths leave an Integer', proven.call('NqBox#nq_rescued'))
  check.call('NEG: a rescued region that may leave a String keeps its send', kept.call('NqBox#nq_rescued_str'))
  check.call('a `return` inside a block joins the method result: Integer either way', proven.call('NqBox#nq_block_ret_use'))
  check.call('NEG: `r = maybe_nil; r + 1` keeps its send', kept.call('NqBox#nq_find_unchecked'))
  check.call('a nil test on the result narrows it: `r ? r + 1 : 0` proves', proven.call('NqBox#nq_find_checked'))
  check.call('NEG: an argument also reachable by `send(:name, ...)` keeps its send', kept.call('NqBox#nq_send_target'))
  check.call('NEG: an ivar an attr_accessor lets a caller assign a String keeps its send', kept.call('NqWriter#nq_acc_use'))
  check.call('NEG: a subclass storing a String into the inherited ivar keeps the base class\'s send',
             kept.call('NqBase#nq_shared_use'))
  check.call('a base-class ivar the subclass never touches still proves (family-wide constructor assurance)',
             proven.call('NqBase#nq_up_use'))
  check.call('an ivar the subclass constructor assigns after `super` (which lets self out nowhere) proves',
             proven.call('NqSub#nq_own_use'))
  check.call('NEG: an ivar assigned after a call that can let self out keeps its send', kept.call('NqLatePar#nq_lp_use'))
  check.call('a block reading a captured local the method assigned before creating it proves',
             proven.call('NqBox#nq_captured'))
  check.call('NEG: a captured local assigned only after the block was created keeps its send',
             kept.call('NqBox#nq_captured_late'))
  check.call('NEG: a captured local a block writes is unknown, in the block and after it',
             kept.call('NqBox#nq_captured_written'))
  check.call('NEG: an argument one call site passes a String keeps its send', kept.call('NqBox#nq_mixed_arg'))
  check.call('NEG: `o.size + 1` where a Ruby class also defines #size keeps its send',
             kept.call('NqSizeShadow#nq_use'))
  %w[nq_setidx nq_interp nq_operator].each do |m|
    check.call("NEG: an ivar slot read after an op that runs unseen Ruby (#{m}) keeps its send",
               kept.call("NqHidden##{m}"))
  end
  facts = err.lines.grep(/NUM(ARG|IVAR|RET|CONST) /).join
  check.call('the diagnostic lists the proven ivar classes', facts.include?('NUMIVAR NqBox#@nq_f (FLT)') &&
                                                          facts.include?('NUMIVAR NqBox#@nq_list (ARR)'))
  check.call('the diagnostic never lists an ivar with an unmodelled class', !facts.include?('NUMIVAR NqBox#@nq_mix') ||
                                                                          !facts.match?(/@nq_mix \([^)]*OTHER/))

  # A full-core build (with mruby-bigint) also exercises Integer overflow into a
  # bigint; the bare core build raises RangeError for it, as the interpreter does.
  full = runtime.full
  core = runtime.core
  if (full.nil? && core.nil?) || !runtime.compiler?
    puts '  SKIP run: set BC2CPP_MRUBY_CORE or BC2CPP_MRUBY_FULL (libmruby*.a and include/, from the patched 3rd/mruby) ' \
         'and have g++'
  else
    puts '-- fixture on real mruby, interpreted and compiled'
    Dir.mktmpdir do |dir|
      owners = %w[NqBox NqWriter NqBase NqSub NqLatePar NqSizeShadow NqHidden NqDrv NqConfig NqOther]
      _code, err = runtime.generate(fixture, dir, only_owners: owners)
      body = <<~CPP
        static mrb_value nq_new(mrb_state* M, const char* klass) {
          return mrb_obj_new(M, mrb_class_get(M, klass), 0, nullptr);
        }
        static int scenario(mrb_state* M) {
          mrb_value box = nq_new(M, "NqBox");
          call(M, "step 1", box, "nq_step");
          call(M, "step 2", box, "nq_step");
          // Proven methods are only called with what their static call sites pass:
          // a native or harness caller is outside the closed world the proof assumes.
          mrb_value two = mrb_fixnum_value(2);
          call(M, "scale", box, "nq_scale", 1, &two);
          mrb_value ab[2] = { mrb_fixnum_value(3), mrb_fixnum_value(4) };
          call(M, "area", box, "nq_area", 2, ab);
          mrb_value cd[2] = { mrb_fixnum_value(2), mrb_fixnum_value(5) };
          call(M, "area 2", box, "nq_area", 2, cd);
          mrb_value nine = mrb_float_value(M, 9.0);
          call(M, "half float", box, "nq_half", 1, &nine);
          mrb_value four = mrb_fixnum_value(4);
          call(M, "half int", box, "nq_half", 1, &four);
          mrb_value ls[2] = { mrb_fixnum_value(1), mrb_fixnum_value(2) };
          call(M, "less", box, "nq_less", 2, ls);
          mrb_value lf[2] = { mrb_float_value(M, 1.5), mrb_fixnum_value(2) };
          call(M, "less float", box, "nq_less", 2, lf);
          call(M, "len 0", box, "nq_len");
          call(M, "push", box, "nq_push");
          call(M, "len 1", box, "nq_len");
          mrb_value five = mrb_fixnum_value(5);
          call(M, "sum", box, "nq_sum", 1, &five);
          call(M, "fact", box, "nq_fact", 1, &five);
          call(M, "edge (Integer overflow)", box, "nq_edge");
          call(M, "flt_use before", box, "nq_flt_use");
          call(M, "setf", box, "nq_setf");
          call(M, "flt_use after", box, "nq_flt_use");
          call(M, "lazy_bump on nil", box, "nq_lazy_bump");
          call(M, "late_use on nil", box, "nq_late_use");
          call(M, "guarded on nil", box, "nq_guarded");
          call(M, "late_set", box, "nq_late_set");
          call(M, "late_use", box, "nq_late_use");
          call(M, "guarded", box, "nq_guarded");
          call(M, "mix_use before", box, "nq_mix_use");
          call(M, "taint", box, "nq_taint");
          call(M, "mix_use after taint", box, "nq_mix_use");
          call(M, "refl_use before", box, "nq_refl_use");
          call(M, "refl", box, "nq_refl");
          call(M, "refl_use after", box, "nq_refl_use");
          call(M, "const_use", box, "nq_const_use");
          call(M, "ratio_use", box, "nq_ratio_use");
          call(M, "mix_const", box, "nq_mix_const");
          call(M, "find_unchecked", box, "nq_find_unchecked");
          call(M, "find_checked", box, "nq_find_checked");
          mrb_value neg1 = mrb_fixnum_value(-1);
          call(M, "find nil", box, "nq_find", 1, &neg1);
          call(M, "send_call", box, "nq_send_call");
          mrb_value str = mrb_str_new_cstr(M, "a");
          call(M, "mixed_arg int", box, "nq_mixed_arg", 1, &two);
          call(M, "mixed_arg str", box, "nq_mixed_arg", 1, &str);
          call(M, "run", box, "nq_run");
          call(M, "rescued", box, "nq_rescued");
          call(M, "rescued_str", box, "nq_rescued_str");
          #{full ? 'call(M, "block_ret_use", box, "nq_block_ret_use");' : '// block_ret_use needs Array#each, which the core-only mruby lacks: its interpreter raises where the compiled loop runs.'}

          mrb_value ar = mrb_ary_new(M);
          call(M, "argsize", box, "nq_argsize", 1, &ar);
          mrb_value sx = mrb_symbol_value(mrb_intern_lit(M, "xyz"));
          call(M, "mixsize symbol", box, "nq_mixsize", 1, &sx);
          call(M, "mixsize array", box, "nq_mixsize", 1, &ar);

          mrb_value w = nq_new(M, "NqWriter");
          call(M, "acc_use", w, "nq_acc_use");
          call(M, "acc_float", w, "nq_acc_float");
          call(M, "acc_use float", w, "nq_acc_use");
          mrb_value s = mrb_str_new_cstr(M, "str");
          call(M, "acc=", w, "nq_acc=", 1, &s);
          call(M, "acc_use after a String", w, "nq_acc_use");

          mrb_value sub = nq_new(M, "NqSub");
          call(M, "base shared_use", sub, "nq_shared_use");
          call(M, "base up_use", sub, "nq_up_use");
          call(M, "sub own_use", sub, "nq_own_use");
          call(M, "sub poison", sub, "nq_poison");
          call(M, "base shared_use after poison", sub, "nq_shared_use");

          mrb_value late = nq_new(M, "NqLatePar");
          call(M, "late parent lp_use", late, "nq_lp_use");
          mrb_value shadow = nq_new(M, "NqSizeShadow");
          call(M, "size shadow", shadow, "nq_use", 1, &shadow);
          mrb_value hid = nq_new(M, "NqHidden");
          call(M, "hidden setidx", hid, "nq_setidx");
          call(M, "hidden interp", hid, "nq_interp");
          call(M, "hidden operator", hid, "nq_operator");
          mrb_value drv = nq_new(M, "NqDrv");
          call(M, "driver", drv, "nq_go");
          return 0;
        }
      CPP
      built, output = runtime.run(dir, err, owners, body, build: full || core, full: !full.nil?)
      check.call('the fixture compiles and runs against real mruby', built)
      puts output unless built
      if built
        sections = runtime.sections(output)
        values = ->(name) { sections.fetch(name, []).reject { |l| l.start_with?('  ') } }
        check.call('every method answers what the interpreter answers, values and exceptions alike',
                   !values.call('interpreted').empty? && values.call('interpreted') == values.call('compiled'))
        puts output if ENV['BC2CPP_CHECK_VERBOSE'] || values.call('interpreted') != values.call('compiled')
        dispatches = lambda do |label|
          lines = sections.fetch('compiled', [])
          at = lines.index { |l| l.start_with?("#{label} =>") }
          at && lines[at + 1].to_s[/dispatches=(\d+)/, 1]&.to_i
        end
        %w[step\ 2 scale area half\ int less len\ 1 sum fact].each do |label|
          check.call("#{label}: the compiled call makes no dynamic dispatch", dispatches.call(label) == 0)
        end
      end
    end
  end
end

if failures.empty?
  puts 'bc2cpp numeric operand check: PASS'
else
  warn "bc2cpp numeric operand check: #{failures.size} failure(s)"
  exit 1
end
