#!/usr/bin/env ruby
# frozen_string_literal: true

require 'tmpdir'
require_relative 'fixture_runtime'

SOURCE = <<~RUBY
  class EffA
    def tag; :a; end
  end
  class EffB
    def tag; :b; end
  end
  class EffObserver
    def read; @ignored; end
  end
  class EffOtherObserver
    def read; self; end
  end
  class EffBadObserver
    def initialize(target); @target = target; end
    def read; @target.poison(EffB.new); end
  end
  class EffFixture
    def read; @value; end
    def identity; self; end
    def change; @value = EffB.new; end
    def nested_change; change; end
    def alloc; EffA.new; end
    def opt(value = nil); value; end
    def closure; [1].each { @value = EffB.new }; end
    def poison(value); @value = value; end
    def keep; @value = EffA.new; read; @value.tag; end
    def explicit; @value = EffA.new; self.read; @value.tag; end
    def self_result; @value = EffA.new; identity; @value.tag; end
    def other; observer = EffObserver.new; @value = EffA.new; observer.read; @value.tag; end
    def write; @value = EffA.new; change; @value.tag; end
    def nested; @value = EffA.new; nested_change; @value.tag; end
    def allocation; @value = EffA.new; alloc; @value.tag; end
    def optional; @value = EffA.new; opt; @value.tag; end
    def block; @value = EffA.new; closure; @value.tag; end
    def uncertain(receiver); @value = EffA.new; receiver.read; @value.tag; end
    def union(flag); observer = flag ? EffObserver.new : EffOtherObserver.new; @value = EffA.new; observer.read; @value.tag; end
    def unsafe_union(flag); observer = flag ? EffObserver.new : EffBadObserver.new(self); @value = EffA.new; observer.read; @value.tag; end
    def partial(receiver, flag); observer = flag ? EffObserver.new : receiver; @value = EffA.new; observer.read; @value.tag; end
    def native; @value = EffA.new; [1].size; @value.tag; end
  end
RUBY
abort 'SKIP: set MRBC' unless ENV['MRBC']
failures = []
check = lambda do |name, condition|
  puts "  #{condition ? 'ok  ' : 'FAIL'} #{name}"
  failures << name unless condition
end
require File.join(File.dirname(Bc2cppFixtureRuntime::BC2CPP), 'readonly_call_effects')
FakeInsn = Struct.new(:op, :enter_fields)
FakeProgram = Struct.new(:resolved, :handlers) do
  def resolved? = resolved
  def handlers? = handlers
end
FakeBody = Struct.new(:enter, :reps, :instructions, :program)
original_for = BytecodeIR.method(:for)
BytecodeIR.define_singleton_method(:for) { |body| body.is_a?(FakeBody) ? body.program : original_for.call(body) }
make_body = lambda do |fields: Array.new(8, 0), reps: [], resolved: true, handlers: false, ops: %w[ENTER GETIV RETURN]|
  enter = FakeInsn.new('ENTER', fields)
  FakeBody.new(enter, reps, ops.map { |op| FakeInsn.new(op, nil) }, FakeProgram.new(resolved, handlers))
end
check.call('safe getter body', ReadonlyCallEffects.safe?(make_body.call))
check.call('nested body refuses', !ReadonlyCallEffects.safe?(make_body.call(reps: [1])))
check.call('handler body refuses', !ReadonlyCallEffects.safe?(make_body.call(handlers: true)))
check.call('unresolved body refuses', !ReadonlyCallEffects.safe?(make_body.call(resolved: false)))
(0..7).each do |field|
  fields = Array.new(8, 0)
  fields[field] = 1
  check.call("argument field #{field} refuses", !ReadonlyCallEffects.safe?(make_body.call(fields: fields)))
end
%w[SEND SETIV LOADL ARRAY STRING GETUPVAR METHOD EXEC SENDB RAISEIF UNKNOWN].each do |op|
  check.call("#{op} refuses", !ReadonlyCallEffects.safe?(make_body.call(ops: ['ENTER', op, 'RETURN'])))
end
FakeWorld = Struct.new(:safe) do
  def exact_instances_singleton_free? = safe
end
FakeDefinition = Struct.new(:owner, :irep)
FakeSend = Struct.new(:op, :reg, :sym)
codegen = CodeGen.allocate
codegen.instance_variable_set(:@rc_scoped_ready, true)
codegen.instance_variable_set(:@closed_world, FakeWorld.new(true))
bit = 1 << NumericFlow::CLASS_BIT_BASE
codegen.instance_variable_set(:@numeric_class_bits, { 'EffA' => bit })
codegen.instance_variable_set(:@ireps, { 'safe' => make_body.call })
definition = FakeDefinition.new('EffA', 'safe')
codegen.instance_variable_set(:@registry, { 'read' => [definition] })
codegen.define_singleton_method(:closed_world_exact_target) { |_name, _klass| definition }
insn = FakeSend.new('SEND0', '0', 'read')
check.call('exact readonly target', codegen.readonly_class_call?(nil, insn, [bit]) == (ENV['BC2CPP_READONLY_CALL_EFFECTS'] != '0'))
check.call('partial unknown receiver refuses', !codegen.readonly_class_call?(nil, insn, [bit | NumericFlow::OTHER]))
codegen.define_singleton_method(:closed_world_exact_target) { |_name, _klass| nil }
check.call('unresolved lookup refuses despite registry', !codegen.readonly_class_call?(nil, insn, [bit]))
BytecodeIR.define_singleton_method(:for, original_for)
FakeCall = Struct.new(:op, :reg)
flow_oracle = Object.new
flow_oracle.define_singleton_method(:send_mask) { |*_args| NumericFlow::STR }
flow_oracle.define_singleton_method(:preserves_ivar_slots?) { |*_args| true }
ctx = { oracle: flow_oracle, irep: nil, nregs: 4, slots: ['@value'], facts: [NumericFlow::OTHER],
        slot_of: { '@value' => 4 }, prov_base: 5, opaque: Set.new, writes: nil }
state = [NumericFlow::OTHER, NumericFlow::STR, NumericFlow::INT, NumericFlow::OTHER,
         NumericFlow::INT, 0, 0, 1, 0]
call_insn = FakeCall.new('SEND0', '1')
after = NumericFlow.transfer(0, call_insn, state, ctx)
check.call('normal readonly flow preserves slot', after[4] == NumericFlow::INT)
check.call('normal readonly flow clears provenance', after[5, 4].all?(&:zero?))
raised = NumericFlow.raise_state(call_insn, state, after, ctx)
check.call('exceptional flow still widens slot', raised[4] == (NumericFlow::INT | NumericFlow::OTHER))
check.call('exceptional flow clears provenance', raised[5, 4].all?(&:zero?))
flow_oracle.define_singleton_method(:preserves_ivar_slots?) { |*_args| false }
unknown = NumericFlow.transfer(0, call_insn, state, ctx)
check.call('unknown call still widens slot', unknown[4] == (NumericFlow::INT | NumericFlow::OTHER))
runtime = Bc2cppFixtureRuntime
owners = %w[EffA EffB EffObserver EffOtherObserver EffBadObserver EffFixture]
Dir.mktmpdir('readonly-effects') do |dir|
  code, err = runtime.generate(SOURCE, dir, only_owners: owners)
  body = ->(name) { code[/mrb_value EffFixture_#{name}_impl\([^\n]*\) \{(.*?)^\}/m, 1].to_s }
  enabled = ENV['BC2CPP_READONLY_CALL_EFFECTS'] != '0'
  %w[keep explicit self_result other union].each do |name|
    check.call("#{name}: readonly call preserves exact ivar", body.call(name).include?('EXACT_CLASS :tag -> EffA#tag') == enabled)
  end
  %w[write nested allocation optional block uncertain native unsafe_union partial].each do |name|
    check.call("#{name}: effect stays unknown", !body.call(name).include?('EXACT_CLASS :tag -> EffA#tag'))
  end
  outside = File.join(dir, 'outside')
  FileUtils.mkdir_p(File.join(outside, 'eff-foreign/mrblib'))
  code_outside, = runtime.generate(SOURCE, outside, only_owners: owners,
                                 foreign: [['eff-foreign/mrblib/read.rb', 'class EffFixture; def read; @value = EffB.new; end; end']],
                                 build_gems: [['eff-foreign', File.join(outside, 'eff-foreign')]])
  outside_body = code_outside[/mrb_value EffFixture_keep_impl\([^\n]*\) \{(.*?)^\}/m, 1].to_s
  check.call('outside write withdraws readonly proof', !outside_body.include?('EXACT_CLASS :tag -> EffA#tag'))
  unless ENV['CC_GENERATED_ONLY'] == '1'
    build = runtime.full_or_build
    if build
      harness = <<~CPP
        static int scenario(mrb_state* M) {
          mrb_value value = mrb_obj_new(M, mrb_class_get(M, "EffFixture"), 0, nullptr);
          for (const char* name : {"keep", "explicit", "self_result", "other", "write", "nested", "allocation", "optional", "block", "native"})
            call(M, name, value, name);
          for (mrb_value flag : {mrb_true_value(), mrb_false_value()}) {
            call(M, "union", value, "union", 1, &flag);
            call(M, "unsafe_union", value, "unsafe_union", 1, &flag);
          }
          return 0;
        }
      CPP
      built, output = runtime.run(dir, err, owners, harness, build: build, full: true)
      sections = runtime.sections(output).transform_values { |lines| lines.reject { |line| line.start_with?('  dispatches=') } }
      check.call('runtime matches interpreter', built && sections['compiled'] == sections['interpreted'])
      warn output unless built && sections['compiled'] == sections['interpreted']
    end
  end
end
abort "FAILED: #{failures.join(', ')}" unless failures.empty?
puts 'readonly call effects: PASS'
