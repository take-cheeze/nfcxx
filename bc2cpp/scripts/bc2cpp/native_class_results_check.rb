#!/usr/bin/env ruby
# frozen_string_literal: true

# ADR 0333: pinned native results join Ruby returns, never replace them.
require 'fileutils'
require_relative 'fixture_runtime'
require ENV.fetch('NCR_AUDIT_TOOL') { File.expand_path('../../tools/bc2cpp/native_class_results', __dir__) }

# Keep the native-summary withdrawal checks independent of local receiver proofs.
ENV['BC2CPP_CALL_CONTEXT_RESULTS'] = '0'

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
  NativeClassResults::FACTS.each do |name, (kind, allowed)|
    next if %w[to_s join].include?(name) # Dedicated String/array checks cover their subclass and delegate contracts.
    paths = allowed.map { |relative| copies.fetch(relative) }
    expected = { '<audited-native>' => kind }
    check.call("audited result: #{name}", NativeClassResults.kinds(name, paths) == expected)
    check.call("no linked source: #{name}", NativeClassResults.kinds(name, []).nil?)
    outside = File.join(dir, 'outside.c')
    File.write(outside, "mrb_define_method(mrb, klass, \"#{name}\", other_body, MRB_ARGS_NONE());")
    check.call("unmodelled native registration: #{name}", NativeClassResults.kinds(name, paths + [outside]).nil?)
    allowed.each do |relative|
      path = copies.fetch(relative)
      original = File.binread(path)
      File.binwrite(path, original + "\nvoid changed_native_body() {}\n")
      check.call("changed source: #{name}, #{relative}", NativeClassResults.kinds(name, paths).nil?)
      File.binwrite(path, original)
    end
  end
  check.call('snapshot retains every nil return', NativeClassResults::FACTS.fetch('snap_to_bitmap').first == ['RGSS::Bitmap', :nil])
  check.call('numeric range conversion retains nil fallback', NativeClassResults::FACTS.fetch('__num_to_a').first == ['Array', :nil])
  array_helper = copies.fetch('3rd/mruby/src/array.c')
  original_array = File.binread(array_helper)
  File.binwrite(array_helper, original_array + "\nvoid changed_range_array_allocator() {}\n")
  check.call('numeric range conversion audits Array allocation', NativeClassResults.kinds('__num_to_a', [copies.fetch('3rd/mruby/src/range.c')]).nil?)
  File.binwrite(array_helper, original_array)
  nested_switch = ENV['BC2CPP_CORE_RUBY_NESTED_RESULTS']
  begin
    ENV['BC2CPP_CORE_RUBY_NESTED_RESULTS'] = '0'
    check.call('nested switch withdraws native range helper', NativeClassResults.kinds('__num_to_a', [copies.fetch('3rd/mruby/src/range.c')]).nil?)
  ensure
    ENV['BC2CPP_CORE_RUBY_NESTED_RESULTS'] = nested_switch
  end
  check.call('Method parameters requires its Proc delegate',
             NativeClassResults.kinds('parameters', [copies.fetch('3rd/mruby/mrbgems/mruby-method/src/method.c')]).nil?)
  saved = ENV['BC2CPP_NATIVE_CLASS_RESULTS']
  begin
    ENV['BC2CPP_NATIVE_CLASS_RESULTS'] = '0'
    check.call('native fact kill switch', NativeClassResults.kinds('keys', [copies.fetch('3rd/mruby/src/hash.c')]).nil?)
  ensure
    ENV['BC2CPP_NATIVE_CLASS_RESULTS'] = saved
  end
end

SOURCE = <<~RUBY
  class NcOwn
    def keys; [3]; end
    def parameters; [4, 5, 6]; end
  end
  class NcOther
    def size; 9; end
  end
  class NcRunner
    def nc_size(value); value.keys.size; end
    def nc_params(value); value.parameters.size; end
    def own; nc_size(NcOwn.new); end
    def hash; nc_size({a: 1, b: 2}); end
    def params; nc_params(NcOwn.new); end
  end
RUBY
OWNERS = %w[NcOwn NcOther NcRunner].freeze
runtime = Bc2cppFixtureRuntime
body_of = ->(code, name) { code[/^mrb_value NcRunner_#{name}_impl\(mrb_state\* M.*?(?=^(?:static )?mrb_value \w+\(mrb_state\* M|\z)/m].to_s }
array_size = lambda do |code, name|
  body = body_of.call(code, name)
  !body.empty? && body.include?('CLOSED_WORLD_NATIVE_EXACT :size -> Array')
end
if ENV['MRBC']
  worlds = [
    ['audited keys and absent parameters', SOURCE, {}, {}, true, true],
    ['Ruby return joins native return', SOURCE.sub('def keys; [3]; end', 'def keys; NcOther.new; end'), {}, {}, false, true],
    ['native fact kill switch', SOURCE, {}, { 'BC2CPP_NATIVE_CLASS_RESULTS' => '0' }, false, true],
    ['absent definition kill switch', SOURCE, {}, { 'BC2CPP_ABSENT_NATIVE_RETURNS' => '0' }, true, false],
    ['foreign definition', SOURCE, { foreign: [['outside.rb', 'class NcOwn; def keys; other; end; end']] }, {}, false, true],
    ['unlinked native keys', SOURCE, { native: [['outside.c', 'void f(mrb_state* mrb, struct RClass* klass) { mrb_define_method(mrb, klass, "keys", other_body, MRB_ARGS_NONE()); }']] }, {}, true, true],
    ['alias', SOURCE + "class NcOwn; alias keys parameters; end\n", {}, {}, false, true],
    ['open world', SOURCE, { closed: false }, {}, false, false]
  ]
  outside_gem = Dir.mktmpdir('native-result-gem')
  begin
    FileUtils.mkdir_p(File.join(outside_gem, 'src'))
    File.write(File.join(outside_gem, 'src/outside.c'), 'void f(mrb_state* mrb, struct RClass* klass) { mrb_define_method(mrb, klass, "keys", other_body, MRB_ARGS_NONE()); }')
    worlds << ['linked native keys', SOURCE, { build_gems: [['native-result-gem', outside_gem]] }, {}, false, true]
    worlds << ['method missing', SOURCE + "class NcOther; def method_missing(name); self; end; end\n", {}, {}, false, false]
    worlds << ['dynamic installer', SOURCE + "class NcOwn; define_method(:keys) { NcOther.new }; end\n", {}, {}, false, true]
    worlds.each do |name, source, options, env, keys_exact, params_exact|
      Dir.mktmpdir do |dir|
        saved = env.to_h { |key,| [key, ENV[key]] }
        begin
          env.each { |key, value| ENV[key] = value }
          code, err = runtime.generate(source, dir, only_owners: OWNERS, **options)
          check.call("#{name}: keys", !body_of.call(code, 'nc_size').empty? && array_size.call(code, 'nc_size') == keys_exact)
          if name == 'Ruby return joins native return'
            check.call('native return is retained in mixed Ruby/native join', !err.include?('RETCLASS keys (NcOther)'))
          end
          check.call("#{name}: parameters", !body_of.call(code, 'nc_params').empty? && array_size.call(code, 'nc_params') == params_exact)
          next unless ['audited keys and absent parameters', 'Ruby return joins native return'].include?(name) && ENV['NCR_GENERATED_ONLY'] != '1'

          builds = []
          full = runtime.full || (ENV['BC2CPP_FULL_BUILD_DIR'] && runtime.full_or_build)
          builds << ['full-core', full, true] if full
          builds << ['core-only', runtime.core, false] if runtime.core && ENV['NCR_FULL_ONLY'] != '1'
          body = <<~CPP
            static int scenario(mrb_state* M) {
              mrb_value runner = mrb_obj_new(M, mrb_class_get(M, "NcRunner"), 0, nullptr);
              call(M, "own", runner, "own");
              call(M, "hash", runner, "hash");
              call(M, "params", runner, "params");
              return 0;
            }
          CPP
          builds.each do |label, build, full_core|
            built, output = runtime.run(dir, err, OWNERS, body, build: build, full: full_core)
            sections = runtime.sections(output).transform_values { |lines| lines.reject { |line| line.start_with?('  dispatches=') } }
            expected = name == 'Ruby return joins native return' ? 9 : 1
            ok = built && sections['compiled'] == sections['interpreted'] && output.include?("own => #{expected}") &&
                 output.include?('hash => 2') && output.include?('params => 3')
            check.call("#{name}, #{label}: runtime parity", ok)
            warn output unless ok
          end
        ensure
          saved.each { |key, value| ENV[key] = value }
        end
      end
    end
  ensure
    FileUtils.remove_entry(outside_gem)
  end
  exact_core = SOURCE + "class NcOwn; def bytes; NcOther.new; end; end\nclass NcRunner; def core_bytes; 'abc'.bytes.size; end; end\n"
  [
    ['exact String bytes overrides wider name join', exact_core, {}, true],
    ['exact String bytes disabled', exact_core, { 'BC2CPP_NATIVE_CLASS_RESULTS' => '0' }, false],
    ['reopened String bytes', exact_core + "class String; def bytes; NcOther.new; end; end\n", {}, false],
    ['singleton creation', exact_core + "class NcOwn; def nc_singleton; define_singleton_method(:bytes) { NcOther.new }; end; end\n", {}, false]
  ].each do |name, source, env, expected|
    Dir.mktmpdir do |dir|
      saved = env.to_h { |key,| [key, ENV[key]] }
      begin
        env.each { |key, value| ENV[key] = value }
        code, = runtime.generate(source, dir, only_owners: OWNERS)
        check.call(name, !body_of.call(code, 'core_bytes').empty? && array_size.call(code, 'core_bytes') == expected)
      ensure
        saved.each { |key, value| ENV[key] = value }
      end
    end
  end
  snapshot = SOURCE + "class NcRunner; def snapshot; RGSS::Graphics.snap_to_bitmap.width; end; end\n"
  [
    ['nullable snapshot', snapshot, {}, true],
    ['snapshot fact disabled', snapshot, { 'BC2CPP_NATIVE_CLASS_RESULTS' => '0' }, false],
    ['rebound Bitmap', snapshot + "RGSS::Bitmap = NcOther\n", {}, false]
  ].each do |name, source, env, expected|
    Dir.mktmpdir do |dir|
      saved = env.to_h { |key,| [key, ENV[key]] }
      begin
        env.each { |key, value| ENV[key] = value }
        code, = runtime.generate(source, dir, only_owners: OWNERS)
        body = body_of.call(code, 'snapshot')
        check.call(name, !body.empty? && body.include?('NILABLE_RECEIVER :width') == expected)
      ensure
        saved.each { |key, value| ENV[key] = value }
      end
    end
  end
else
  puts '-- SKIP generated code: set MRBC'
end
abort "FAILED: #{failures.join(', ')}" unless failures.empty?
puts 'bc2cpp native class results check: PASS'
