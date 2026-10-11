#!/usr/bin/env ruby
# frozen_string_literal: true

require 'tmpdir'
require_relative 'fixture_runtime'

SOURCE = <<~RUBY
  class CcA
    def tag; :a; end
  end
  class CcB
    def tag; :b; end
  end
  class CcRelay
    def carry(value); value; end
    def identity; self; end
    def explicit_identity; copy = self; copy; end
    def nested(value); self.carry(value); end
    def optional(value, extra = nil); value; end
    def rest(value, *extra); value; end
    def default(value = CcB.new); value; end
    def trailing(value = CcB.new, *extra, tail); tail; end
    def rest_array(*values); values; end
    def blocked(value, &block); value; end
    def recursive(value); self.recursive(value); self.recursive(value); end
    def closure(value); [1].each { return CcB.new }; value; end
    def readonly(value); [1].each { |item| item }; value; end
    def same_return(value); [1].each { return CcA.new }; value; end
    def discarded_break(value); [1].each { break CcB.new }; value; end
    def captured_write(value); [1].each { value = CcB.new }; value; end
    def nested_return(value); [1].each { [1].each { return CcB.new } }; value; end
    def captured_return(value); [1].each { return value }; CcA.new; end
    def break_result(value); [1].each { break value }; end
    def later_write(value); block = proc { return value }; value = CcB.new; block.call; CcA.new; end
    def deep_capture(value); [1].each { [1].each { return value } }; CcA.new; end
  end
  class CcSubRelay < CcRelay
    def carry(value); CcB.new; end
  end
  class CcParent
    def local_carry(value); value; end
    def run; local_carry(CcA.new).tag; end
    def poison(value); local_carry(value); end
  end
  class CcChild < CcParent
    def local_carry(value); CcB.new; end
  end
  class CcFixture
    def local_carry(value); value; end
    def implicit; local_carry(CcA.new).tag; end
    def poison_local(value); local_carry(value).tag; end
    def a; CcRelay.new.carry(CcA.new).tag; end
    def b; CcRelay.new.carry(CcB.new).tag; end
    def nested; CcRelay.new.nested(CcA.new).tag; end
    def self_chain; CcRelay.new.identity.carry(CcA.new).tag; end
    def explicit_self; CcRelay.new.explicit_identity.carry(CcB.new).tag; end
    def inherited; CcSubRelay.new.identity.carry(CcA.new).tag; end
    def array; CcRelay.new.carry([1, 2]).size; end
    def unknown(value); CcRelay.new.carry(value).tag; end
    def mixed(flag); value = flag ? CcA.new : CcB.new; CcRelay.new.carry(value).tag; end
    def nilable(flag); value = flag ? CcA.new : nil; CcRelay.new.carry(value).tag; end
    def wrong_arity; CcRelay.new.carry(CcA.new, CcB.new).tag; end
    def optional; CcRelay.new.optional(CcA.new).tag; end
    def rest; CcRelay.new.rest(CcA.new).tag; end
    def omitted; CcRelay.new.default.tag; end
    def supplied; CcRelay.new.default(CcA.new).tag; end
    def trailing; CcRelay.new.trailing(CcB.new, CcB.new, CcA.new).tag; end
    def rest_array; CcRelay.new.rest_array(CcA.new, CcB.new).size; end
    def blocked; CcRelay.new.blocked(CcA.new).tag; end
    def poison(value); [CcRelay.new.optional(value), CcRelay.new.rest(value), CcRelay.new.blocked(value)]; end
    def recursive; CcRelay.new.recursive(CcA.new).tag; end
    def closure; CcRelay.new.closure(CcA.new).tag; end
    def readonly; CcRelay.new.readonly(CcA.new).tag; end
    def same_return; CcRelay.new.same_return(CcA.new).tag; end
    def discarded_break; CcRelay.new.discarded_break(CcA.new).tag; end
    def captured_write; CcRelay.new.captured_write(CcA.new).tag; end
    def nested_return; CcRelay.new.nested_return(CcA.new).tag; end
    def captured_return; CcRelay.new.captured_return(CcA.new).tag; end
    def break_result; CcRelay.new.break_result(CcA.new).tag; end
    def deep_capture; CcRelay.new.deep_capture(CcA.new).tag; end
    def captured_b; CcRelay.new.captured_return(CcB.new).tag; end
    def later_write; CcRelay.new.later_write(CcA.new).tag; end
    def poison_blocks(value); CcRelay.new.captured_return(value); end
  end
RUBY
failures = []
check = lambda do |name, ok|
  puts "  #{ok ? 'ok  ' : 'FAIL'} #{name}"
  failures << name unless ok
end
abort 'SKIP: set MRBC' unless ENV['MRBC']
runtime = Bc2cppFixtureRuntime
Dir.mktmpdir('call-context') do |dir|
  code, err = runtime.generate(SOURCE, dir, only_owners: %w[CcA CcB CcRelay CcSubRelay CcParent CcChild CcFixture])
  body = ->(name) { code[/mrb_value CcFixture_#{name}_impl\([^\n]*\) \{(.*?)^\}/m, 1].to_s }
  enabled = ENV['BC2CPP_CALL_CONTEXT_RESULTS'] != '0'
  { 'implicit' => 'CcA', 'a' => 'CcA', 'b' => 'CcB', 'nested' => 'CcA', 'self_chain' => 'CcA', 'explicit_self' => 'CcB', 'inherited' => 'CcB' }.each do |name, klass|
    check.call("#{name}: context carries exact receiver", body.call(name).include?("EXACT_CLASS :tag -> #{klass}#tag") == enabled)
  end
  check.call('array: context carries core receiver', body.call('array').include?('CLOSED_WORLD_NATIVE_EXACT :size -> Array') == enabled)
  %w[readonly same_return discarded_break captured_return deep_capture].each do |name|
    block_enabled = enabled && ENV['BC2CPP_BLOCK_CONTEXT_RESULTS'] != '0'
    check.call("#{name}: block-containing method carries exact receiver", body.call(name).include?('EXACT_CLASS :tag -> CcA#tag') == block_enabled)
  end
  # `optional` and `rest` are asserted exact by the positional-binding block below (ADR 0355),
  # so they are not in this list: a resolved signature is exactly what that proof consumes.
  %w[unknown mixed nilable wrong_arity recursive closure blocked captured_write nested_return break_result captured_b later_write].each do |name|
    check.call("#{name}: uncertain result stays dynamic", !body.call(name).include?('EXACT_CLASS :tag ->'))
  end
  shapes = enabled && ENV['BC2CPP_CONTEXT_ARGUMENT_SHAPES'] != '0'
  { 'optional' => 'CcA', 'rest' => 'CcA', 'omitted' => 'CcB', 'supplied' => 'CcA', 'trailing' => 'CcA' }.each do |name, klass|
    check.call("#{name}: positional binding carries exact receiver", body.call(name).include?("EXACT_CLASS :tag -> #{klass}#tag") == shapes)
  end
  check.call('rest Array result', body.call('rest_array').include?('CLOSED_WORLD_NATIVE_EXACT :size -> Array') == shapes)
  parent_body = code[/mrb_value CcParent_run_impl\([^\n]*\) \{(.*?)^\}/m, 1].to_s
  check.call('subclassed lexical self stays unresolved', !parent_body.include?('EXACT_CLASS :tag -> CcA#tag'))
  outside = File.join(dir, 'outside')
  FileUtils.mkdir_p(File.join(outside, 'cc-foreign/mrblib'))
  outside_code, outside_err = runtime.generate(SOURCE, outside, only_owners: %w[CcA CcB CcRelay CcSubRelay CcParent CcChild CcFixture],
                                   foreign: [['cc-foreign/mrblib/carry.rb', 'class CcRelay; def carry(value); CcB.new; end; end']],
                                   build_gems: [['cc-foreign', File.join(outside, 'cc-foreign')]])
  if ENV['BC2CPP_KEEP_DIR']
    FileUtils.cp_r(dir, ENV['BC2CPP_KEEP_DIR'], remove_destination: true)
    File.write(File.join(ENV['BC2CPP_KEEP_DIR'], 'outside.err'), outside_err)
  end
  outside_body = outside_code[/mrb_value CcFixture_a_impl\([^\n]*\) \{(.*?)^\}/m, 1].to_s
  check.call('outside replacement withdraws the input-specific receiver', !outside_body.include?('EXACT_CLASS :tag -> CcA#tag'))
  FileUtils.mkdir_p(File.join(dir, 'reflective/cc-reflect/src'))
  reflective_code, = runtime.generate(SOURCE, File.join(dir, 'reflective'),
    only_owners: %w[CcA CcB CcRelay CcSubRelay CcParent CcChild CcFixture],
    build_gems: [['cc-reflect', File.join(dir, 'reflective/cc-reflect')]],
    native: [['cc-reflect/src/writer.c', 'static void cc_writer(mrb_state *mrb, struct RClass *klass) { mrb_define_method(mrb, klass, "binding", cc_binding, MRB_ARGS_NONE()); }']])
  reflective_body = reflective_code[/mrb_value CcFixture_readonly_impl\([^\n]*\) \{(.*?)^\}/m, 1].to_s
  check.call('reflective local writer withdraws block context', !reflective_body.include?('EXACT_CLASS :tag -> CcA#tag'))
  unless ENV['CC_GENERATED_ONLY'] == '1'
    build = runtime.full_or_build
    if build
      harness = <<~CPP
        static int scenario(mrb_state* M) {
          mrb_value fixture = mrb_obj_new(M, mrb_class_get(M, "CcFixture"), 0, nullptr);
          for (const char* name : {"implicit", "a", "b", "nested", "self_chain", "explicit_self", "inherited", "array", "wrong_arity", "closure", "optional", "rest", "blocked", "omitted", "supplied", "trailing", "rest_array", "readonly", "same_return", "discarded_break", "captured_write", "nested_return", "captured_return", "break_result", "deep_capture", "captured_b", "later_write"})
            call(M, name, fixture, name);
          for (mrb_value flag : {mrb_true_value(), mrb_false_value()}) {
            call(M, "mixed", fixture, "mixed", 1, &flag);
            call(M, "nilable", fixture, "nilable", 1, &flag);
          }
          for (const char* klass : {"CcA", "CcB"}) {
            mrb_value value = mrb_obj_new(M, mrb_class_get(M, klass), 0, nullptr);
            call(M, "unknown", fixture, "unknown", 1, &value);
          }
          for (const char* klass : {"CcParent", "CcChild"}) {
            mrb_value value = mrb_obj_new(M, mrb_class_get(M, klass), 0, nullptr);
            call(M, klass, value, "run");
          }
          return 0;
        }
      CPP
      built, output = runtime.run(dir, err, %w[CcA CcB CcRelay CcSubRelay CcParent CcChild CcFixture], harness, build: build, full: true)
      sections = runtime.sections(output).transform_values { |lines| lines.reject { |line| line.start_with?('  dispatches=') } }
      check.call('runtime matches interpreter', built && sections['compiled'] == sections['interpreted'])
      warn output unless built && sections['compiled'] == sections['interpreted']
    else
      puts 'SKIP runtime: no full-core build'
    end
  end
end
abort "FAILED: #{failures.join(', ')}" unless failures.empty?
puts 'bc2cpp call context results check: PASS'
