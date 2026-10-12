#!/usr/bin/env ruby
# frozen_string_literal: true

require 'tmpdir'
require_relative 'fixture_runtime'
TOOLS = ENV['BC2CPP_TOOL'] ? File.dirname(ENV['BC2CPP_TOOL']) : File.expand_path('../../tools/bc2cpp', __dir__)
%w[numeric_flow native_core_direct codegen_numeric_native_direct].each { |file| require File.join(TOOLS, file) }
SOURCE = <<~RB.dup
  class NumericConvert
    def small; 42.to_s; end
    def identity; 42.to_i; end
    def large; 0x1_0000_0000_0000_0000.to_s; end
    def large_identity; 0x1_0000_0000_0000_0000.to_i; end
    def arithmetic; (40 + 2).to_s; end
    def radix; 42.to_s(16); end
    def mixed(flag); value = flag ? 42 : 2.5; value.to_s; end
    def unknown(value); value.to_s; end
    def string; "42".to_i; end
    def block; 42.to_s {}; end
  end
RB
if ENV['NN_WIDTH_SAFE'] == '1'
  SOURCE.gsub!('0x1_0000_0000_0000_0000', '2147483647')
end
failures = []
check = lambda do |name, ok|
  puts "  #{ok ? 'ok  ' : 'FAIL'} #{name}"
  failures << name unless ok
end
abort 'SKIP: set MRBC' unless ENV['MRBC']
runtime = Bc2cppFixtureRuntime
enabled = ENV['BC2CPP_NUMERIC_NATIVE_DIRECT'] != '0'
world_type = Struct.new(:visible) do
  def exact_instances_singleton_free? = true
  def visibility_stable?(_name) = visible
end
cg = CodeGen.allocate
cg.instance_variable_set(:@closed_world, world_type.new(true))
cg.define_singleton_method(:numeric_operand_mask) { |*_args| NumericFlow::INT }
cg.define_singleton_method(:numeric_conversion_entries) { |_name| NativeCoreDirect::NUMERIC_CONVERSION_ENTRIES.select { |row| row.name == 'to_s' } }
cg.define_singleton_method(:devirt_blocked_name?) { |_name| true }
check.call('blocked name withdraws numeric exact conversion', cg.numeric_native_direct_code('to_s', '1', 'r1', nil, 0, 1, nil).nil?)
cg.define_singleton_method(:devirt_blocked_name?) { |_name| false }
cg.instance_variable_set(:@closed_world, world_type.new(false))
check.call('unstable visibility withdraws numeric exact conversion', cg.numeric_native_direct_code('to_s', '1', 'r1', nil, 0, 1, nil).nil?)
Dir.mktmpdir('numeric-native') do |dir|
  code, err = runtime.generate(SOURCE, dir, only_owners: %w[NumericConvert])
  body = ->(name) { code[/mrb_value NumericConvert_#{name}_impl\([^\n]*\) \{(.*?)^\}/m, 1].to_s }
  %w[small identity large large_identity arithmetic].each do |name|
    check.call("#{name} has audited Integer direct call", body.call(name).include?('NUMERIC_NATIVE_EXACT') == enabled)
  end
  check.call('decimal ABI uses base ten', !enabled || body.call('small').match?(/mrb_integer_to_str\(M, r\d+, 10\)/))
  %w[radix mixed unknown string block].each { |name| check.call("#{name} stays outside the numeric route", !body.call(name).include?('NUMERIC_NATIVE_EXACT')) }
  %w[to_s to_i].each do |name|
    override = "class Integer; def #{name}; :replacement; end; end"
    override_code, = runtime.generate(SOURCE + override, File.join(dir, name), only_owners: %w[NumericConvert Integer])
    check.call("Integer##{name} override withdraws proof", !override_code.match?(/NUMERIC_NATIVE_EXACT :#{name}/))
  end
  { 'private' => 'class Integer; private :to_s; end',
    'protected' => 'class Integer; protected :to_s; end',
    'dynamic visibility' => 'class Integer; def self.hide(name); private name; end; end' }.each do |label, changes|
    changed_code, = runtime.generate(SOURCE + changes, File.join(dir, label), only_owners: %w[NumericConvert Integer])
    check.call("#{label} withdraws numeric exact conversion", !changed_code.include?('NUMERIC_NATIVE_EXACT :to_s'))
  end
  singleton_source = SOURCE + "class NumericConvert; def singleton_probe; Object.new.singleton_class; end; end"
  singleton_code, = runtime.generate(singleton_source, File.join(dir, 'singleton'), only_owners: %w[NumericConvert])
  check.call('singleton maker withdraws exact world gate', !singleton_code.include?('NUMERIC_NATIVE_EXACT'))
  open_code, = runtime.generate(SOURCE, File.join(dir, 'open'), only_owners: %w[NumericConvert], closed: false)
  check.call('open world withdraws proof', !open_code.include?('NUMERIC_NATIVE_EXACT'))
  if ENV['BC2CPP_KEEP_DIR']
    FileUtils.mkdir_p(ENV['BC2CPP_KEEP_DIR'])
    File.write(File.join(ENV['BC2CPP_KEEP_DIR'], 'numeric.cxx'), code)
  end
  unless ENV['CC_GENERATED_ONLY'] == '1'
    build = runtime.full_or_build
    harness = <<~CPP
      static int scenario(mrb_state* M) {
        mrb_value value = mrb_obj_new(M, mrb_class_get(M, "NumericConvert"), 0, nullptr);
        for (const char* name : {"small", "identity", "large", "large_identity", "arithmetic", "radix", "string", "block"}) call(M, name, value, name);
        for (mrb_value flag : {mrb_true_value(), mrb_false_value()}) call(M, "mixed", value, "mixed", 1, &flag);
        for (mrb_value input : {mrb_int_value(M, 7), mrb_float_value(M, 2.5), mrb_nil_value()}) call(M, "unknown", value, "unknown", 1, &input);
        return 0;
      }
    CPP
    # Generated literal loaders must match the selected library's bigint support.
    previous_flags = ENV['BC2CPP_CXXFLAGS']
    ENV['BC2CPP_CXXFLAGS'] = [previous_flags, ('-DMRB_USE_BIGINT' unless ENV['NN_NO_BIGINT'] == '1')].compact.join(' ')
    begin
      built, output = runtime.run(dir, err, %w[NumericConvert], harness, build: build, full: true)
    ensure
      ENV['BC2CPP_CXXFLAGS'] = previous_flags
    end
    sections = runtime.sections(output).transform_values { |lines| lines.reject { |line| line.start_with?('  dispatches=') } }
    check.call('numeric conversion runtime parity', built && sections['compiled'] == sections['interpreted'])
    warn output unless built && sections['compiled'] == sections['interpreted']
  end
end
abort "FAILED: #{failures.join(', ')}" unless failures.empty?
puts 'bc2cpp numeric native direct check: PASS'
