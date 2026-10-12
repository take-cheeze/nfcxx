#!/usr/bin/env ruby
# frozen_string_literal: true

# ADR 0334: audited native String returns must join every compiled Ruby result.
require 'fileutils'
require_relative 'fixture_runtime'
require ENV.fetch('NSR_AUDIT_TOOL') { File.expand_path('../../tools/bc2cpp/native_class_results', __dir__) }

ROOT = File.expand_path('../..', __dir__)
failures = []
check = lambda do |name, ok|
  puts "  #{ok ? 'ok  ' : 'FAIL'} #{name}"
  failures << name unless ok
end
Dir.mktmpdir do |dir|
  copies = NativeClassResults::FILES.keys.to_h do |relative|
    path = File.join(dir, relative)
    FileUtils.mkdir_p(File.dirname(path))
    FileUtils.cp(File.join(ROOT, relative), path)
    [relative, path]
  end
  paths = NativeClassResults::FACTS.fetch('to_s').last.map { |relative| copies.fetch(relative) }
  check.call('all native sources audited, regexp nil retained', NativeClassResults.kinds('to_s', paths, string_subclass_free: true) == { '<audited-native>' => ['String', :nil] })
  check.call('String subclasses withdraw', NativeClassResults.kinds('to_s', paths).nil?)
  paths.each do |path|
    original = File.binread(path)
    File.binwrite(path, original + "\nvoid changed_string_result() {}\n")
    check.call("changed source #{path.delete_prefix(dir)}", NativeClassResults.kinds('to_s', paths, string_subclass_free: true).nil?)
    File.binwrite(path, original)
  end
  outside = File.join(dir, 'unknown.c')
  File.write(outside, 'void unknown_string_result() {}')
  check.call('unmodelled native source', NativeClassResults.kinds('to_s', paths + [outside], string_subclass_free: true).nil?)
  numeric = copies.fetch('3rd/mruby/src/numeric.c')
  helper = copies.fetch('3rd/mruby/mrbgems/mruby-bigint/core/bigint.c')
  original = File.binread(helper)
  File.binwrite(helper, original + "\nvoid changed_bigint_string() {}\n")
  check.call('bigint delegate audited without name registration', NativeClassResults.kinds('to_s', [numeric], string_subclass_free: true).nil?)
  File.binwrite(helper, original)
  check.call('no linked sources', NativeClassResults.kinds('to_s', [], string_subclass_free: true).nil?)
  saved = ENV['BC2CPP_NATIVE_STRING_RESULTS']
  begin
    ENV['BC2CPP_NATIVE_STRING_RESULTS'] = '0'
    check.call('string result kill switch', NativeClassResults.kinds('to_s', paths, string_subclass_free: true).nil?)
  ensure
    ENV['BC2CPP_NATIVE_STRING_RESULTS'] = saved
  end
end

SOURCE = <<~RUBY
  class NsOwn
    def to_s; 'own'; end
  end
  class NsOther
    def size; 91; end
  end
  class NsRunner
    def text(value); value.to_s.size; end
    def own; text(NsOwn.new); end
    def integer; text(12); end
    def nil_text; text(nil); end
    def array; text([]); end
    def range; text(1..2); end
  end
RUBY
OWNERS = %w[NsOwn NsOther NsRunner NsString].freeze
runtime = Bc2cppFixtureRuntime
body_of = ->(code) { code[/^mrb_value NsRunner_text_impl\(mrb_state\* M.*?(?=^(?:static )?mrb_value \w+\(mrb_state\* M|\z)/m].to_s }
if ENV['MRBC']
  foreign = Dir.mktmpdir('string-result-gem')
  begin
    FileUtils.mkdir_p(File.join(foreign, 'mrblib'))
    FileUtils.mkdir_p(File.join(foreign, 'src'))
    native_onig = File.join(foreign, '3rd/mruby-onig-regexp')
    FileUtils.mkdir_p(File.join(native_onig, 'src'))
    FileUtils.cp(File.join(ROOT, '3rd/mruby-onig-regexp/src/mruby_onig_regexp.c'), File.join(native_onig, 'src'))
    worlds = [
      ['String result', SOURCE, {}, {}, true, 3],
      ['Ruby return joins', SOURCE.sub("def to_s; 'own'; end", 'def to_s; NsOther.new; end'), {}, {}, false, 91],
      ['String subclass', SOURCE.sub("def to_s; 'own'; end", "def to_s; NsString.new('own'); end") + "class NsString < String; def size; 91; end; end\n", {}, {}, false, 91],
      ['kill switch', SOURCE, {}, { 'BC2CPP_NATIVE_STRING_RESULTS' => '0' }, false, 3],
      ['method missing', SOURCE + "class NsOther; def method_missing(name); self; end; end\n", {}, {}, false, nil],
      ['singleton creation', SOURCE + "class NsOwn; def install; define_singleton_method(:to_s) { NsOther.new }; end; end\n", {}, {}, false, nil],
      ['arbitrary alias', SOURCE + "class NsOwn; def inspect; NsOther.new; end; alias to_s inspect; end\n", {}, {}, false, nil],
      ['Struct inspect replacement', SOURCE + "class Struct; def inspect; NsOther.new; end; end\n", {}, {}, false, nil],
      ['Struct inspect alias replacement', SOURCE + "class Struct; def alternative; NsOther.new; end; alias inspect alternative; end\n", {}, {}, false, nil],
      ['Struct prepend', SOURCE + "module NsInspect; def inspect; NsOther.new; end; end\nclass Struct; prepend NsInspect; end\n", {}, {}, false, nil],
      ['dynamic installer', SOURCE + "class NsOwn; define_method(:to_s) { NsOther.new }; end\n", {}, {}, false, nil],
      ['open world', SOURCE, { closed: false }, {}, false, nil],
      ['linked foreign to_s', SOURCE, { build_gems: [['string-result-gem', foreign]] }, {}, false, nil],
      ['linked foreign alias', SOURCE, { build_gems: [['string-result-gem', foreign]] }, {}, false, nil],
      ['linked foreign inspect', SOURCE, { build_gems: [['string-result-gem', foreign]] }, {}, false, nil],
      ['regexp Ruby installers', SOURCE, { build_gems: [['mruby-onig-regexp', File.join(ROOT, '3rd/mruby-onig-regexp')]] }, {}, false, nil],
      ['nullable regexp', SOURCE, { build_gems: [['mruby-onig-regexp', native_onig]] }, {}, nil, nil],
      ['linked ROM inspect', SOURCE, { build_gems: [['string-result-gem', foreign]] }, {}, false, nil],
      ['linked native inspect', SOURCE, { build_gems: [['string-result-gem', foreign]] }, {}, false, nil]
    ]
    worlds.each do |name, source, options, env, expected, own_size|
      FileUtils.rm_f(File.join(foreign, 'mrblib/foreign.rb'))
      FileUtils.rm_f(File.join(foreign, 'src/foreign.c'))
      if name == 'linked foreign to_s'
        File.write(File.join(foreign, 'mrblib/foreign.rb'), 'class NsOwn; def to_s; NsOther.new; end; end')
      elsif name == 'linked foreign alias'
        File.write(File.join(foreign, 'mrblib/foreign.rb'), 'class Struct; alias to_s inspect; end')
      elsif name == 'linked foreign inspect'
        File.write(File.join(foreign, 'mrblib/foreign.rb'), 'class Struct; def inspect; NsOther.new; end; end')
      elsif name == 'linked ROM inspect'
        File.write(File.join(foreign, 'src/foreign.c'), 'static const mrb_mt_entry other_methods[] = { MRB_MT_ENTRY(other_body, MRB_SYM(inspect), MRB_ARGS_NONE()), }; void f(mrb_state* mrb) { struct RClass* klass = mrb_class_get_id(mrb, MRB_SYM(Struct)); MRB_MT_INIT_ROM(mrb, klass, other_methods); }')
      elsif name == 'linked native inspect'
        File.write(File.join(foreign, 'src/foreign.c'), 'void f(mrb_state* mrb) { struct RClass* klass = mrb_class_get(mrb, "Struct"); mrb_define_method(mrb, klass, "inspect", other_body, MRB_ARGS_NONE()); }')
      end
      Dir.mktmpdir do |dir|
        saved = env.to_h { |key,| [key, ENV[key]] }
        begin
          env.each { |key, value| ENV[key] = value }
          code, err = runtime.generate(source, dir, only_owners: OWNERS, **options)
          body = body_of.call(code)
          check.call(name, !body.empty? && (expected.nil? || body.include?('NATIVE_CORE_EXACT :size') == expected))
          check.call('regexp nil reaches caller', body.include?('NILABLE_RECEIVER :size')) if name == 'nullable regexp'
          next if own_size.nil? || ENV['NSR_GENERATED_ONLY'] == '1'

          builds = []
          full = runtime.full || (ENV['BC2CPP_FULL_BUILD_DIR'] && runtime.full_or_build)
          builds << ['full-core', full, true] if full
          builds << ['core-only', runtime.core, false] if runtime.core && ENV['NSR_FULL_ONLY'] != '1'
          harness = <<~CPP
            static int scenario(mrb_state* M) {
              mrb_value runner = mrb_obj_new(M, mrb_class_get(M, "NsRunner"), 0, nullptr);
              call(M, "own", runner, "own");
              call(M, "integer", runner, "integer");
              call(M, "nil", runner, "nil_text");
              call(M, "array", runner, "array");
              call(M, "range", runner, "range");
              mrb_value large = mrb_funcall(M, mrb_str_new_lit(M, "4294967296"), "to_i", 0);
              call(M, "large", runner, "text", 1, &large);
              return 0;
            }
          CPP
          builds.each do |label, build, full_core|
            built, output = runtime.run(dir, err, OWNERS, harness, build: build, full: full_core)
            sections = runtime.sections(output).transform_values { |lines| lines.reject { |line| line.start_with?('  dispatches=') } }
            ok = built && sections['compiled'] == sections['interpreted'] && output.include?("own => #{own_size}") &&
                 output.include?('integer => 2') && output.include?('nil => 0') && output.include?('range => 4') && output.include?('large => 10')
            check.call("#{name}, #{label}: runtime parity", ok)
            warn output unless ok
          end
        ensure
          saved.each { |key, value| ENV[key] = value }
        end
      end
    end
  ensure
    FileUtils.remove_entry(foreign)
  end
else
  puts '-- SKIP generated code: set MRBC'
end
abort "FAILED: #{failures.join(', ')}" unless failures.empty?
puts 'bc2cpp native string results check: PASS'
