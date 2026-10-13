#!/usr/bin/env ruby
# frozen_string_literal: true

require 'tmpdir'
require_relative '../../tools/bc2cpp/bc2cpp'

failures = []
check = ->(name, condition) { failures << name unless condition }
Dir.mktmpdir('cpu-dispatch-ir-check') do |tmp|
  path = File.join(tmp, 'cpu.rb')
  File.write(path, <<~RUBY_SOURCE)
    module Optcarrot
      class CPU
        def r_op(instr, mode); send(mode, true, false); send(instr); end
        def _brk; @count = 1; end
        def _bcc; @count = 2; end
        def store_mem; @count += 100; end
        def w_op(instr, mode, store); send(mode, false, true); send(instr); send(store); end
        def run
          while @continue
            send(*DISPATCH[@opcode])
            break if @done
          end
        end
      end
    end
  RUBY_SOURCE
  ireps, root = compile_ireps([path], 'cpu_check', tmp)
  registry = build_registry(ireps, root).first
  run = registry.fetch('run').first
  original = ireps.fetch(run.irep)
  originals = ireps.dup
  check.call('fixed native core contract required', !BytecodeIR::CPUDispatch.apply(ireps, registry))
  check.call('pass accepts original splatted dispatch', BytecodeIR::CPUDispatch.apply(ireps, registry, fixed_core: true))
  rewritten = ireps.fetch(run.irep)
  program = BytecodeIR::Program.new(rewritten)
  wrapper = ireps.fetch(registry.fetch('r_op').first.irep)
  check.call('nested wrapper computed sends have literal arms', wrapper.instructions.any? { |insn| insn.op == 'SSEND' && insn.sym == '_brk' })
  store_wrapper = ireps.fetch(registry.fetch('w_op').first.irep)
  check.call('plain-name store operation has a literal arm', store_wrapper.instructions.any? { |insn| insn.op == 'SSEND' && insn.sym == 'store_mem' })
  check.call('input IR stays intact', original.instructions.size < rewritten.instructions.size)
  check.call('one shape comparison per distinct argument count', rewritten.instructions.count { |insn| insn.op == 'LOADI8' } == 3)
  check.call('all original and introduced branch targets resolve', program.resolved?)
  calls = rewritten.instructions.select { |insn| insn.op == 'SSEND' }
  check.call('literal wrapper arm is visible to analyses', calls.any? { |insn| insn.sym == 'r_op' && insn.n_spec == '2' })
  check.call('literal instruction arm is visible to analyses', calls.any? { |insn| insn.sym == '_brk' && insn.n_spec == '0' })
  check.call('original dynamic fallback remains', calls.count { |insn| insn.sym == 'send' && insn.n_spec == '*' } == 1)
  check.call('scratch registers fit the new frame', rewritten.instructions.flat_map(&:regs).map(&:to_i).max < rewritten.nregs)
  check.call('literal Symbol is comparison receiver', rewritten.instructions.any? do |insn|
    insn.op == 'LOADSYM' && rewritten.instructions[rewritten.index_of_addr(insn.addr) + 2]&.op == 'EQ'
  end)

  %w[length == send].each do |name|
    contaminated = registry.transform_values(&:dup)
    contaminated[name] = [MethodDef.new(owner: name == '==' ? 'Symbol' : 'Array', name: name)]
    check.call("refuses replaced core #{name}", !BytecodeIR::CPUDispatch.apply(originals.dup, contaminated, fixed_core: true))
  end
  overridden_integer = registry.merge('==' => [MethodDef.new(owner: 'Integer', name: '==')])
  check.call('Integer equality replacement withdraws guards', !BytecodeIR::CPUDispatch.apply(originals.dup, overridden_integer, fixed_core: true))
  overridden_subclass = registry.merge('length' => [MethodDef.new(owner: 'ArraySubclass', name: 'length')])
  check.call('subclass length replacement conservatively refuses', !BytecodeIR::CPUDispatch.apply(originals.dup, overridden_subclass, fixed_core: true))
  with_handler = Irep.new(**original.to_h.merge(catch_handlers: [CatchHandler.new(type: :rescue, begin_addr: 0, end_addr: 1, target: 2)]))
  ireps[run.irep] = with_handler
  check.call('handlers conservatively refuse', !BytecodeIR::CPUDispatch.apply(ireps, registry, fixed_core: true))
end
# Execute the transformed register graph independently of codegen. Unknown
# names and wrong arities must reach the original splatted operation.
host = Object.new
host.define_singleton_method(:r_op) { |a, b| [a, b] }
host.define_singleton_method(:_brk) { :brk }
source = Irep.new(label: 'eval', nregs: 5, nlocals: 1, catch_handlers: [], instructions: [
  Insn.new(addr: 0, op: 'SSEND', args: 'R2 :send n=*'),
  Insn.new(addr: 1, op: 'RETURN', args: 'R2')
])
graph = BytecodeIR::CPUDispatch.rewrite(source, 0, [['r_op', 2], ['_brk', 0]])
evaluate = lambda do |args|
  regs = Array.new(graph.nregs)
  regs[3] = args.dup
  pc = 0
  loop do
    node = graph.instructions.fetch(pc)
    d = node.reg&.to_i
    jump = nil
    case node.op
    when 'MOVE' then regs[d] = regs[node.regs.last.to_i]
    when 'AREF' then regs[d] = regs[node.regs.last.to_i][node.typed.last.value]
    when 'SEND0' then regs[d] = regs[d].length
    when 'LOADI8' then regs[d] = node.typed.last.value
    when 'LOADSYM' then regs[d] = node.sym.to_sym
    when 'EQ' then regs[d] = regs[d] == regs[d + 1]
    when 'JMPNOT' then jump = node.branch_target unless regs[d]
    when 'JMP' then jump = node.branch_target
    when 'SSEND'
      values = node.n_spec == '*' ? regs[d + 1] : regs[(d + 1), node.n_spec.to_i]
      regs[d] = host.send(node.sym, *values)
    when 'RETURN' then break regs[d]
    else raise "unmodelled #{node.op}"
    end
    pc = jump || pc + 1
  end
end
outcome = lambda do |&block|
  [:value, block.call]
rescue NoMethodError, ArgumentError, TypeError => error
  [:error, error.class, error.message]
end
[[:r_op, :a, :b], [:_brk], ['r_op', :a, :b], [:unknown], [:r_op, :a],
 [:r_op, :a, :b, nil], [nil], []].each do |args|
  expected = outcome.call { host.send(*args) }
  actual = outcome.call { evaluate.call(args) }
  check.call("differential graph result #{args.inspect}", actual == expected)
end
if ENV['BC2CPP_MRUBY_FULL'] || ENV['BC2CPP_CPU_IR_NATIVE'] == '1'
  require_relative 'fixture_runtime'
  runtime = Bc2cppFixtureRuntime
  native_build = ENV['BC2CPP_CPU_IR_NATIVE'] == '1' ? runtime.full_or_build : runtime.full
  abort 'native CPU IR fixture requires a compatible full-core mruby library' unless native_build
  native_source = <<~RUBY_SOURCE
    module Optcarrot
      class CPU
        DISPATCH = [[:r_op, :_brk, :imm], [:_brk], [:unknown],
                    ['r_op', :_brk, :imm], [:r_op, :_brk], [:r_op, :_brk, :imm, nil], [:w_op, :_sta, :imm, :store_mem]]
        def initialize(opcode); @opcode = opcode; @count = 0; end
        def r_op(instr, mode); send(mode, true, false); send(instr); end
        def imm(read, write); @count += read ? 10 : 1; end
        def w_op(instr, mode, store); send(mode, false, true); send(instr); send(store); end
        def _sta; @count += 2; end
        def store_mem; @count += 100; end
        def _brk; @count += 1; end
        def run; send(*DISPATCH[@opcode]); @count; end
      end
    end
  RUBY_SOURCE
  body = <<~CPP
    static int scenario(mrb_state* M) {
      struct RClass* mod = mrb_module_get(M, "Optcarrot");
      struct RClass* klass = mrb_class_get_under(M, mod, "CPU");
      for (int opcode = 0; opcode < 7; ++opcode) {
        mrb_value arg = mrb_fixnum_value(opcode);
        mrb_value obj = mrb_obj_new(M, klass, 1, &arg);
        call(M, "run", obj, "run");
      }
      return 0;
    }
  CPP
  saved = ENV.values_at('BC2CPP_IR_CPU_DISPATCH', 'BC2CPP_OPTCARROT_FIXED_CORE')
  begin
    ENV['BC2CPP_IR_CPU_DISPATCH'] = '1'
    ENV['BC2CPP_OPTCARROT_FIXED_CORE'] = '1'
    Dir.mktmpdir('cpu-ir-native-check') do |dir|
      _code, err = runtime.generate(native_source, dir, closed: false, only_owners: ['Optcarrot::CPU'])
      ok, output = runtime.run(dir, err, ['Optcarrot::CPU'], body, build: native_build, full: true)
      check.call('native fixture compiles and runs', ok)
      if ok
        sections = runtime.sections(output)
        values = ->(key) { sections.fetch(key).reject { |line| line.include?('dispatches=') } }
        check.call('native output, side effects and exceptions match interpreter', values.call('interpreted') == values.call('compiled'))
      else
        warn output
      end
    end
  ensure
    ENV['BC2CPP_IR_CPU_DISPATCH'], ENV['BC2CPP_OPTCARROT_FIXED_CORE'] = saved
  end
else
  puts 'SKIP native CPU IR fixture: set BC2CPP_MRUBY_FULL and matching BC2CPP_CXXFLAGS'
end
abort failures.join("\n") unless failures.empty?
puts 'bytecode IR CPU dispatch check: PASS'
