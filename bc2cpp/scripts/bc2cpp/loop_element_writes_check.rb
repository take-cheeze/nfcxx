#!/usr/bin/env ruby
# frozen_string_literal: true

# CodeGen#loop_flow_position (codegen_send.rb) refuses a receiver an inlined loop body reassigns from its element R1.
# A nested block writes the body's locals only by SETUPVAR, which is not one of the body's own instructions, so the
# body's own write test cannot see it. This check pins what decides each case: a nested write refuses the receiver's
# reaching definitions (opaque_regs: own_upvar_written_regs) before the element check runs; a write in the body itself
# refuses as :element_reassigned; a rescue after the send does not reassign the element.
#
# 1. Host (hand-built bytecode, no mrbc): the four bodies below.
# 2. With MRBC: the same four compiled from Ruby (the RITE bytecode the generator reads).
#
# Usage: [MRBC=path/to/mrbc] ruby scripts/bc2cpp/loop_element_writes_check.rb
# BC2CPP_TOOL=path/to/bc2cpp.rb runs it against another tools tree (the before/after comparison).

require 'set'
require 'tmpdir'

TOOLS = ENV['BC2CPP_TOOL'] ? File.dirname(ENV['BC2CPP_TOOL']) : File.expand_path('../../tools/bc2cpp', __dir__)
%w[irep bytecode_ir numeric_flow codegen dynamic_names codegen_numeric_proof codegen_numeric_args codegen_captured_locals
   codegen_class_object_args codegen_fixnum_proof codegen_send codegen_loop_regions].each { |file| require File.join(TOOLS, file) }

failures = []
check = lambda do |what, condition|
  puts "  #{condition ? 'ok  ' : 'FAIL'} #{what}"
  failures << what unless condition
end

# [result, refusal reasons, accepted?] of the loop-flow decision for the send at +idx+ of +irep+.
def decide(cg, irep, idx)
  result = cg.loop_flow_position(irep, idx, irep.instructions[idx], 0)
  refused = CodeGen::LOOP_FLOW_REFUSALS.keys.select { |k| k[0] == irep.label && k[1] == idx }.map { |k| k[2] }
  accepted = CodeGen::LOOP_FLOW_ACCEPTED.keys.any? { |k| k[0] == irep.label && k[1] == idx }
  [result, refused, accepted]
end

# The four loop bodies, by what their element receiver meets. `bodies` maps a name to [body irep, send index].
def expect_decisions(check, prefix, cg, bodies)
  plain, pidx = bodies.fetch(:plain)
  result, refused, accepted = decide(cg, plain, pidx)
  check.call("#{prefix}: a plain element receiver is accepted", !result.nil? && accepted && refused.empty?)

  nested, nidx = bodies.fetch(:nested)
  check.call("#{prefix}: a nested block writes the body R1 (own_upvar_written_regs)",
             BytecodeIR.own_upvar_written_regs(nested).include?(1))
  cause = {}
  BytecodeIR.for(nested).reaching_definitions(nidx, nested.instructions[nidx].reg,
                                             opaque_regs: BytecodeIR.own_upvar_written_regs(nested),
                                             follow_moves: true, refusal: cause)
  check.call("#{prefix}: a receiver fed by a nested write is refused as opaque, before any element check",
             cause[:cause] == :opaque_reg)
  result, refused, = decide(cg, nested, nidx)
  check.call("#{prefix}: a receiver fed by a nested block write is not a loop-flow position",
             result.nil? && refused == [:unproven_definition])

  direct, didx = bodies.fetch(:direct)
  result, refused, = decide(cg, direct, didx)
  check.call("#{prefix}: a body write of the element refuses as element_reassigned",
             result.nil? && refused == [:element_reassigned])

  rescued, ridx = bodies.fetch(:rescued)
  result, refused, accepted = decide(cg, rescued, ridx)
  check.call("#{prefix}: a rescue in the body does not reassign the element", !result.nil? && accepted && refused.empty?)
end

puts '-- loop_flow_position on hand-built bytecode (host)'
ENTER_ONE = "1:0:0:0:0:0:0:0\t(0x0)"
ELEMENT = [:MOVE, "R3\tR1"]

# A body from [op, args] rows, addressed by position (the row index is the instruction index the walk uses).
def hand_irep(label, rows, reps: [])
  list = rows.each_with_index.map { |(op, args), i| Insn.new(lineno: 1, addr: i * 2, op: op, args: args, raw: "#{op} #{args}") }
  Irep.new(label: label, nlocals: 2, nregs: 8, pool: [], syms: [], reps: reps, instructions: list, catch_handlers: [],
           file: 'loop_element.rb')
end

lam = hand_irep('lam', [[:ENTER, '0:0:0:0:0:0:0:0\t(0x0)'], [:LOADI_2, 'R2\t(2)'], [:SETUPVAR, "R2\t1\t0"], [:RETURN, 'R2']])
hand = {
  plain: hand_irep('plain', [[:ENTER, ENTER_ONE], ELEMENT, [:SEND0, "R3\t:succ"], [:RETURN, 'R3']]),
  nested: hand_irep('nested', [[:ENTER, ENTER_ONE], ELEMENT, [:LAMBDA, "R4\tI[0]"], [:SEND0, "R4\t:call"],
                               [:SEND0, "R3\t:pred"], [:RETURN, 'R3']], reps: ['lam']),
  direct: hand_irep('direct', [[:ENTER, ENTER_ONE], ELEMENT, [:LOADI_2, "R1\t(2)"], [:SEND0, "R3\t:next"],
                               [:RETURN, 'R3']]),
  rescued: hand_irep('rescued', [[:ENTER, ENTER_ONE], ELEMENT, [:SEND0, "R3\t:ord"], [:EXCEPT, 'R4'],
                                 [:LOADI_1, "R5\t(1)"], [:RESCUE, "R4\tR5"], [:RETURN, 'R3']])
}
hand_tree = (hand.values + [lam]).to_h { |irep| [irep.label, irep] }
hand_tree.each_value { |irep| irep.tree = hand_tree }
bodies = { plain: [hand[:plain], 2], nested: [hand[:nested], 4], direct: [hand[:direct], 3], rescued: [hand[:rescued], 2] }
expect_decisions(check, 'hand-built', CodeGen.allocate, bodies)

if ENV['MRBC']
  puts '-- loop_flow_position on compiled bodies'
  source = <<~RUBY
    def plain(list)
      list.each { |x| x.succ }
    end

    def nested(list)
      list.each do |x|
        f = -> { x = 2 }
        f.call
        x.pred
      end
    end

    def direct(list)
      list.each do |x|
        y = x
        x = 2
        y.next
      end
    end

    def rescued(list)
      list.each do |x|
        y = x
        y.ord
        begin
          z = 1
        rescue StandardError
          z = 2
        end
      end
    end
  RUBY
  Dir.mktmpdir('loop-element-writes') do |directory|
    path = File.join(directory, 'fixture.rb')
    File.write(path, source)
    ireps = load_ireps(run_mrbc([path], 'loop_element', directory)).first
    body_of = lambda do |name|
      ireps.values.find { |irep| irep.instructions.any? { |i| i.op == :SEND0 && i.sym == name } }
    end
    send_index = ->(irep, name) { irep.instructions.index { |i| i.op == :SEND0 && i.sym == name } }
    compiled = { plain: 'succ', nested: 'pred', direct: 'next', rescued: 'ord' }.to_h do |key, name|
      body = body_of.call(name)
      [key, [body, send_index.call(body, name)]]
    end
    expect_decisions(check, 'compiled', CodeGen.allocate, compiled)
  end
end

if ENV['MRBC']
  # A Hash parameter written after an inlined block call: the back-edge write reaches the call, so the call's
  # captured container is no longer the host parameter (inline_hash_capture_hints).
  Dir.mktmpdir('hash-capture') do |directory|
    annotation = Struct.new(:arg_containers, :arg_elements)
    capture = lambda do |source|
      path = File.join(directory, 'fixture.rb')
      File.write(path, source)
      ireps = load_ireps(run_mrbc([path], 'hash_capture', directory)).first
      host = ireps.values.find { |irep| irep.instructions.any? { |i| i.op == :SENDB && i.sym == 'each' } }
      sendb = host.instructions.find { |i| i.op == :SENDB && i.sym == 'each' }
      block = ireps.values.find { |irep| irep.instructions.any? { |i| i.op == :GETUPVAR } }
      gen = CodeGen.allocate
      gen.instance_variable_set(:@element_annotations, { host.label => annotation.new(['Hash', nil], ['Symbol', nil]) })
      gen.send(:inline_hash_capture_hints, host, { block_irep: block, sendb_addr: sendb.addr })
    end
    check.call('a Hash parameter written after the block call in the loop is not a capture',
               capture.call("def host(h, n)\n  while n > 0\n    [1].each { |x| h[x] }\n    h = []\n    n -= 1\n  end\nend\n").empty?)
    check.call('a Hash parameter read straight-line before the block call is still captured',
               !capture.call("def host(h, n)\n  [1].each { |x| h[x] }\n  n\nend\n").empty?)
  end
end

if failures.empty?
  puts 'loop element writes checks passed'
else
  warn "loop element writes checks FAILED: #{failures.join('; ')}"
  exit 1
end
