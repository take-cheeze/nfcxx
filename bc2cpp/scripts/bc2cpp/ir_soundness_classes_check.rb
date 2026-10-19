#!/usr/bin/env ruby
# frozen_string_literal: true

# IR soundness for the linear walks that the bytecode IR answers (BytecodeIR): a question that read the
# instructions in textual order (the nearest writer, the instructions between two points, the ops before an
# ALIAS) is asked of the control-flow graph, so a branch join, a handler entry or a back-edge cannot give a wrong
# answer. Sections 2 to 4 run on hand-built bytecode (host only). Section 1 compiles snippets with the host mrbc
# and needs MRBC; without it that section prints SKIP and the rest still run.

require 'set'
require 'tmpdir'

# The fixtures declare no RBS; the repository's signatures name engine classes these fixtures lack.
ENV['BC2CPP_SIG_DIRS'] = ''
require_relative '../../tools/bc2cpp/bc2cpp'

failures = []
check = lambda do |what, condition|
  puts "  #{condition ? 'ok  ' : 'FAIL'} #{what}"
  failures << what unless condition
end
# A hand-built instruction (the same Insn the disassembly reader makes).
bc = ->(addr, op, args) { Insn.new(lineno: 1, addr: addr, op: op, args: args, raw: "#{op} #{args}") }

# -- 1. class objects (closed_world.rb class_object_register? / class_constant_target?), compiled -----------------
puts '-- 1. class objects: every path into the SCLASS, not the textually nearest writer (MRBC)'
mrbc = ENV['MRBC']
if mrbc && File.executable?(mrbc)
  # The SCLASS of +ireps+ as [irep, index, insn] (each snippet below has one).
  sclasses = lambda do |ireps|
    ireps.values.flat_map do |irep|
      irep.instructions.each_with_index.filter_map { |insn, idx| [irep, idx, insn] if insn.op == 'SCLASS' }
    end
  end
  # A ClosedWorld over +ireps+ with nothing else known (no SETCONST, no native sources).
  world_for = lambda do |ireps|
    ClosedWorld.new(ireps: ireps, registry: {}, class_decls: {}, walked: {}, native_paths: [], ruby_paths: [])
  end
  CLASS_JOINS = {
    'a join of [] and a constant (the constant is the nearer writer)' =>
      ["c = $c\nx = c ? [] : Foo\nclass << x\nend\n", false, false],
    'a join of a constant and [] (the array is the nearer writer)' =>
      ["c = $c\nx = c ? Foo : []\nclass << x\nend\n", false, false],
    'a join of two constants' => ["c = $c\nx = c ? Foo : Bar\nclass << x\nend\n", true, true],
    'a plain constant' => ["class << Foo\nend\n", true, true],
    'a fresh Object.new (singleton-free)' => ["x = Object.new\nclass << x\nend\n", true, false],
    'new sent to a join of Foo and Object (a Foo instance can have a singleton class)' =>
      ["c = $c\nx = (c ? Foo : Object).new\nclass << x\nend\n", false, false]
  }.freeze
  CLASS_JOINS.each do |what, (source, register, target)|
    Dir.mktmpdir do |dir|
      path = File.join(dir, 'snippet.rb')
      File.write(path, source)
      ireps, = compile_ireps(path, 'ir_soundness_snippet', dir, mrbc: mrbc)
      scs = sclasses.call(ireps)
      check.call("#{what}: one SCLASS", scs.size == 1)
      next unless scs.size == 1

      irep, idx, insn = scs.first
      world = world_for.call(ireps)
      got_register = world.send(:class_object_register?, irep, idx, insn.reg.to_s)
      got_target = world.send(:class_constant_target?, irep, idx, insn.reg.to_s)
      check.call("#{what}: class_object_register? is #{register} (got #{got_register.inspect})", got_register == register)
      check.call("#{what}: class_constant_target? is #{target} (got #{got_target.inspect})", got_target == target)
    end
  end
else
  puts '  SKIP section 1: MRBC is not set to a host mrbc'
end

# -- 2. CallSiteIndex.enum_target (call_site_index.rb): no handler entry between the LOADSYM and the send ----------
puts '-- 2. to_enum name: a handler entry between the LOADSYM and the send (hand-built)'
# idx0 is protected by a rescue whose target (addr 8) is inside the stretch: the exception path reaches the send
# without the LOADSYM, so R2 holds no name there.
enum_irep = lambda do |handlers|
  Irep.new(label: 'enum', instructions: [
             bc.call(0, 'NOP', ''), bc.call(4, 'LOADSYM', "R2\t:set"), bc.call(8, 'NOP', ''),
             bc.call(12, 'SSEND', "R1\t:to_enum\tn=1")
           ], catch_handlers: handlers)
end
plain_sites = CallSiteIndex.build({ 'enum' => enum_irep.call([]) })
check.call('without a handler, the to_enum name is the LOADSYM symbol', plain_sites['set'].map { |*, n| n } == [0])
handled_sites = CallSiteIndex.build({
                                      'enum' => enum_irep.call([CatchHandler.new(type: :rescue, begin_addr: 0,
                                                                                 end_addr: 4, target: 8)])
                                    })
check.call('a handler entry into the stretch leaves the name unknown (no site under :set)',
           handled_sites['set'].empty?)
check.call('... and the site is kept under the computed-name key',
           handled_sites[CallSiteIndex::UNKNOWN_TARGET].size == 1)

# -- 3. CodeGen#lambda_confined_call_consumes? (codegen_runtime_def.rb): no handler entry in the stretch -----------
puts '-- 3. confined lambda call: a handler entry between the MOVE and the :call (hand-built)'
# idx0 may raise before the MOVE at idx1 and reach the handler (addr 8) inside the stretch; R5 is then not the lambda.
confined_irep = lambda do |handlers|
  Irep.new(label: 'lam', nlocals: 3, nregs: 8, reps: [], catch_handlers: handlers, instructions: [
             bc.call(0, 'NOP', ''), bc.call(4, 'MOVE', "R5\tR1"), bc.call(8, 'LOADI_1', "R6\t(1)"),
             bc.call(12, 'SEND', "R5\t:call\tn=0")
           ])
end
confiner = CodeGen.new({}, {}, {})
check.call('without a handler, the call consumes the MOVEd lambda',
           confiner.send(:lambda_confined_call_consumes?, confined_irep.call([]), 1, 5) ==
             { send_addr: 12, dest_reg: 5, n: 0 })
check.call('a handler entry between the MOVE and the call refuses the confinement',
           confiner.send(:lambda_confined_call_consumes?,
                         confined_irep.call([CatchHandler.new(type: :rescue, begin_addr: 0, end_addr: 8,
                                                              target: 8)]), 1, 5).nil?)

# -- 4. CoreRubyResults.opaque_definitions (codegen_core_ruby_results.rb): an exit that skips the ALIAS ------------
puts '-- 4. core alias: an exit reached without passing the ALIAS (a handler path) (hand-built)'
# The core body rescues idx0's raise into a return (idx2) that never reaches the ALIAS at idx3; the normal path
# jumps over the rescue to the ALIAS. A forward branch does not span the ALIAS, so only the flow decides.
core_file = '/x/3rd/mruby/mrblib/core.rb'
alias_body = lambda do |handlers|
  Irep.new(label: 'core', file: core_file, reps: [], catch_handlers: handlers, instructions: [
             bc.call(0, 'SEND0', "R1\t:foo"), bc.call(4, 'JMP', '12'), bc.call(8, 'RETURN', 'R1'),
             bc.call(12, 'ALIAS', ":new\told"), bc.call(16, 'RETURN', 'R1')
           ])
end
core_alias_names = lambda do |handlers|
  sites = [{ irep: 'core', owner: 'Array', old: 'old', new: 'new' }]
  CoreRubyResults.opaque_definitions({}, Set.new, { 'core' => alias_body.call(handlers) }, sites,
                                     { %w[Array old] => ['new'] })
end
check.call('a return that skips the ALIAS on a handler path keeps the alias opaque',
           core_alias_names.call([CatchHandler.new(type: :rescue, begin_addr: 0, end_addr: 4, target: 8)])
                           .include?(%w[Array new]))
check.call('without the handler, the ALIAS is on every path and stays mapped',
           !core_alias_names.call([]).include?(%w[Array new]))

puts
puts(failures.empty? ? 'ir_soundness_classes_check OK' : "FAILED: #{failures.size}")
exit(failures.empty? ? 0 : 1)
