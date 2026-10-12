#!/usr/bin/env ruby
# frozen_string_literal: true

require 'tmpdir'
require_relative 'fixture_runtime'
TOOLS = ENV['BC2CPP_TOOL'] ? File.dirname(ENV['BC2CPP_TOOL']) : File.expand_path('../../tools/bc2cpp', __dir__)
%w[irep bytecode_ir numeric_flow].each { |file| require File.join(TOOLS, file) }
failures = []
check = lambda do |name, ok|
  puts "  #{ok ? 'ok  ' : 'FAIL'} #{name}"
  failures << name unless ok
end
make = lambda do |rows|
  irep = Irep.new(label: 'literal', nregs: 8, nlocals: 1)
  irep.instructions = rows.each_with_index.map do |(op, args), address|
    Insn.new(lineno: 1, addr: address, op: op, args: args, raw: "#{op} #{args}")
  end
  irep
end
base = [['STRING', 'R1 L[0]'], ['ARRAY', 'R1 1'], ['GETIDX0', 'R2 R1[0]'], ['RETURN', 'R2']]
enabled = ENV['BC2CPP_LITERAL_ELEMENT_PROOF'] != '0'
proof = ->(rows, opaque = Set.new) { irep = make.call(rows); LiteralElementProof.mask(irep, rows.index { |row| row[0].start_with?('GETIDX') }, opaque) }
check.call('fresh String element', (proof.call(base) == NumericFlow::STR) == enabled)
check.call('captured element withdrawn', proof.call(base, Set['1']).nil?)
check.call('call between literal and read withdrawn', proof.call(base.insert(2, ['SEND', 'R1 :clear n=0'])).nil?)
base.delete_at(2)
check.call('effect before construction withdrawn', proof.call([base.first, ['SEND', 'R3 :touch n=0'], *base.drop(1)]).nil?)
check.call('unknown element withdrawn', proof.call([['GETIV', 'R1 @x'], *base.drop(1)]).nil?)
check.call('branch entry withdrawn', proof.call([['JMP', '003'], *base]).nil?)
check.call('index beyond length withdrawn', proof.call([*base.take(2), ['LOADI_1', 'R2 (1)'], ['GETIDX', 'R1 (R2)'], ['RETURN', 'R1']]).nil?)
check.call('unknown index withdrawn', proof.call([*base.take(2), ['MOVE', 'R2 R3'], ['GETIDX', 'R1 (R2)'], ['RETURN', 'R1']]).nil?)
check.call('negative in-bounds index', (proof.call([*base.take(2), ['LOADINEG', 'R2 1'], ['GETIDX', 'R1 (R2)'], ['RETURN', 'R1']]) == NumericFlow::STR) == enabled)
if ENV['MRBC']
  source = <<~RB
    class LiteralFixture
      def string; ["abc"][0].size; end
      def integer; [7][0] + 1; end
      def array; [[1, 2]][0].size; end
      def oob; ["abc"][1].size; end
      def dynamic(i); ["abc"][i].size; end
      def mutate; a = ["abc"]; a[0] = nil; a[0].size; end
    end
  RB
  runtime = Bc2cppFixtureRuntime
  Dir.mktmpdir('literal-element') do |dir|
    code, err = runtime.generate(source, dir, only_owners: %w[LiteralFixture])
    File.write(File.join(ENV['BC2CPP_KEEP_DIR'], 'literal.cxx'), code) if ENV['BC2CPP_KEEP_DIR']
    body = ->(name) { code[/mrb_value LiteralFixture_#{name}_impl\([^\n]*\) \{(.*?)^\}/m, 1].to_s }
    check.call('String native exact arm', body.call('string').include?('NATIVE_CORE_EXACT :size') == enabled)
    check.call('Array native exact arm', body.call('array').include?('CLOSED_WORLD_NATIVE_EXACT :size -> Array') == enabled)
    %w[oob dynamic mutate].each { |name| check.call("#{name} keeps unknown receiver", !body.call(name).include?('CLOSED_WORLD_NATIVE_EXACT :size')) }
    unless ENV['CC_GENERATED_ONLY'] == '1'
      harness = <<~CPP
        static int scenario(mrb_state* M) {
          mrb_value value = mrb_obj_new(M, mrb_class_get(M, "LiteralFixture"), 0, nullptr);
          for (const char* name : {"string", "integer", "array", "oob", "mutate"}) call(M, name, value, name);
          for (mrb_int i : {0, 1, -1}) {
            mrb_value index = mrb_int_value(M, i);
            call(M, "dynamic", value, "dynamic", 1, &index);
          }
          return 0;
        }
      CPP
      build = runtime.full_or_build
      built, output = runtime.run(dir, err, %w[LiteralFixture], harness, build: build, full: true)
      sections = runtime.sections(output).transform_values { |lines| lines.reject { |line| line.start_with?('  dispatches=') } }
      check.call('runtime parity', built && sections['compiled'] == sections['interpreted'])
      warn output unless built && sections['compiled'] == sections['interpreted']
    end
  end
end
abort "FAILED: #{failures.join(', ')}" unless failures.empty?
puts 'bc2cpp literal element check: PASS'
