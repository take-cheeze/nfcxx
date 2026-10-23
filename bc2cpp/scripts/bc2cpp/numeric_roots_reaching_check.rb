#!/usr/bin/env ruby
# frozen_string_literal: true

# NUMERIC_ROOTS: CodeGen#numeric_root_leaves takes the leaves of a register from the reaching
# definitions (BytecodeIR.reaching_definitions), not from the textually nearest writer plus every later loop
# writer. Each case below states the answer of the textual walk it replaced, which was wrong:
#   - a join: the textually nearest writer is the else branch, and the then branch's write is lost;
#   - a loop: a writer later in the loop body feeds the read through the back edge, and it is not an arithmetic
#     or MOVE write, so the old "later writers" list skipped it;
#   - a write that cannot reach the read (a later arithmetic write of the same register) was counted as a leaf;
#   - a write made above an arithmetic op's register is clobbered on its send fallback: the query refuses, and the
#     leaf is `unproven`, where the old walk reported the write it could see as the only one.
#
# 1. Host only (no mrbc): hand-built instruction lists through the real CodeGen#numeric_root_leaves.
# 2. With MRBC: the same questions on compiled Ruby, through mrbc's own register allocation and catch table.
#
# Usage: [MRBC=path/to/mrbc] ruby scripts/bc2cpp/numeric_roots_reaching_check.rb

require 'set'
require 'tmpdir'
require_relative '../../tools/bc2cpp/bc2cpp'

failures = []
check = lambda do |what, condition|
  puts "  #{condition ? 'ok  ' : 'FAIL'} #{what}"
  failures << what unless condition
end

def insn(addr, op, args)
  Insn.new(lineno: 1, addr: addr, op: op, args: args, raw: "#{op} #{args}")
end

def irep_of(list, handlers = [])
  Irep.new(label: "nr#{list.hash}", nregs: 10, instructions: list, catch_handlers: handlers, reps: [], pool: [])
end

# A CodeGen with no numeric facts: every operand is unmodelled, so each writer's leaf is its own.
def roots_gen(registry = {})
  gen = CodeGen.allocate
  gen.instance_variable_set(:@registry, registry)
  gen.define_singleton_method(:numeric_raw_mask) { |*| nil }
  gen
end

def leaves(gen, irep, at, reg)
  gen.numeric_root_leaves(irep, at, reg, nil)
end

puts '-- join (host)'
# if !R1 then R2 = foo else R2 = 1 end; R5 = R2 (the read is at index 4)
join = irep_of([insn(0, 'JMPNOT', "R1\t8"), insn(3, 'SEND0', "R2\t:foo"), insn(7, 'JMP', '9'),
                insn(8, 'LOADI_1', "R2\t(1)"), insn(9, 'MOVE', "R5\tR2"), insn(10, 'RETURN', 'R5')])
got = leaves(roots_gen, join, 4, 2)
check.call('the then-branch write reaches the join: its send is a leaf (the textual walk saw only LOADI_1)',
           got.size == 1 && got.first.start_with?('send:foo@'))

puts '-- loop-carried non-arithmetic writer (host)'
# R2 = 0; loop { read R2 (index 1); R2 = R2.next (SEND0); break unless R3 }
loop_carried = irep_of([insn(0, 'LOADI_0', "R2\t(0)"), insn(1, 'NOP', ''), insn(2, 'SEND0', "R2\t:next"),
                        insn(5, 'JMPNOT', "R3\t1"), insn(7, 'RETURN', 'R2')])
got = leaves(roots_gen, loop_carried, 1, 2)
check.call('a SEND later in the loop reaches the loop head through the back edge (the old list had only MOVE/arithmetic)',
           got.any? { |l| l.start_with?('send:next@') })

puts '-- a write that cannot reach the read (host)'
# R2 = foo; R5 = R2 (read at index 1); R2 = R2 + R3 later, with R3 = bar.
unreachable = irep_of([insn(0, 'SEND0', "R2\t:foo"), insn(1, 'MOVE', "R5\tR2"), insn(2, 'SEND0', "R3\t:bar"),
                       insn(3, 'ADD', "R2\t(R3)"), insn(4, 'RETURN', 'R2')])
got = leaves(roots_gen, unreachable, 1, 2)
check.call('the read sees only foo: bar is written after the read and never reaches it',
           got.size == 1 && got.first.start_with?('send:foo@'))

puts '-- refused query (host)'
# ADD R2 writes R2 and its send fallback's frame starts at R2: R3 above it may be clobbered on that path.
clobbered = irep_of([insn(0, 'SEND0', "R3\t:foo"), insn(1, 'ADD', "R2\t(R4)"), insn(2, 'MOVE', "R5\tR3"),
                     insn(3, 'RETURN', 'R5')])
got = leaves(roots_gen, clobbered, 2, 3)
check.call('R3 across an ADD of a lower register is unproven (the fallback frame may overwrite it), not foo',
           got == ['unproven:callee_frame_clobber'])

puts '-- entry value through a join (host)'
# R1 is the method's argument; the then branch rebinds it to foo, the else branch keeps the argument.
param_join = irep_of([insn(0, 'ENTER', '1:0:0:0:0:0:0:0 (0x1000)'), insn(3, 'JMPNOT', "R2\t12"),
                      insn(7, 'SEND0', "R1\t:foo"), insn(10, 'JMP', '15'), insn(12, 'NOP', ''),
                      insn(15, 'MOVE', "R5\tR1"), insn(17, 'RETURN', 'R5')])
got = leaves(roots_gen, param_join, 5, 1)
check.call('the join reports both the foo write and the entry value of R1 (param:noowner without an owner)',
           got.any? { |l| l.start_with?('send:foo@') } && got.include?('param:noowner'))

puts '-- report label source (host)'
# The label names the writer every reaching definition shares: a join of two different writers names none.
label_join = irep_of([insn(0, 'JMPNOT', "R1\t8"), insn(3, 'SEND0', "R2\t:foo"), insn(7, 'JMP', '9'),
                      insn(8, 'LOADI_1', "R2\t(1)"), insn(9, 'MOVE', "R5\tR2"), insn(10, 'RETURN', 'R5')])
gen = roots_gen
check.call('a join of different writers has no label source',
           gen.numeric_label_source(label_join, 4, 2) == :unknown)
check.call('a parameter read is an entry label source',
           gen.numeric_label_source(irep_of([insn(0, 'MOVE', "R5\tR2"), insn(1, 'RETURN', 'R5')]), 0, 2) == :entry)

if ENV['MRBC'] && !ENV['MRBC'].empty?
  puts '-- compiled Ruby (MRBC)'
  SRC = <<~'RUBY'
    class NumRootsJoin
      def pick(c)
        if c
          x = fetch_a
        else
          x = 1
        end
        x + 1
      end

      def loop_once(n)
        x = fetch_b
        while n > 0
          x = fetch_c
          n -= 1
        end
        x + 1
      end

      def rescued(c)
        x = fetch_d
        begin
          x = fetch_e
          risky(c)
        rescue
          x + 1
        end
      end
    end
  RUBY

  # The ADDI (`x + 1`) of the named method, as [irep, index, register of the operand it reads].
  def addi_read(ireps, registry, name)
    md = registry.fetch(name).find { |d| d.owner == 'NumRootsJoin' }
    irep = ireps.fetch(md.irep)
    idx = irep.instructions.rindex { |i| i.op == 'ADDI' }
    [irep, idx, irep.instructions[idx].reg]
  end

  Dir.mktmpdir do |dir|
    source = File.join(dir, 'numeric_roots.rb')
    File.write(source, SRC)
    ireps, root_label = compile_ireps(source, 'bc2cpp_numeric_roots', dir)
    registry = build_registry(ireps, root_label)[0]
    gen = roots_gen(registry)

    irep, idx, reg = addi_read(ireps, registry, 'pick')
    got = leaves(gen, irep, idx, reg.to_i)
    check.call('pick: the if-branch fetch_a reaches `x + 1` next to the literal 1 of the else branch',
               got.any? { |l| l.start_with?('send:fetch_a@') })

    irep, idx, reg = addi_read(ireps, registry, 'loop_once')
    got = leaves(gen, irep, idx, reg.to_i)
    check.call('loop_once: fetch_b reaches the read when the loop never runs, fetch_c when it does',
               got.any? { |l| l.start_with?('send:fetch_b@') } && got.any? { |l| l.start_with?('send:fetch_c@') })

    # The rescue body can see fetch_d (the raise may come before fetch_e writes). The IR does not model RESCUE, so
    # the query refuses and the leaf says so; the textual walk answered fetch_e alone.
    irep, idx, reg = addi_read(ireps, registry, 'rescued')
    got = leaves(gen, irep, idx, reg.to_i)
    check.call('rescued: the rescue body is unproven (RESCUE is unmodelled), not the fetch_e write alone',
               !got.empty? && got.all? { |l| l.start_with?('unproven:') })
  end
else
  puts '-- compiled Ruby (MRBC): skipped, MRBC is not set'
end

if failures.empty?
  puts "numeric_roots_reaching_check: all checks passed#{ENV['MRBC'].to_s.empty? ? ' (compiled section skipped)' : ''}"
else
  puts "numeric_roots_reaching_check: #{failures.size} failure(s)"
  exit 1
end
