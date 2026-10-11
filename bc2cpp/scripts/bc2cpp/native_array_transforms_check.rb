#!/usr/bin/env ruby
# frozen_string_literal: true

# ADR 0336: native allocation contracts join, rather than replace, Ruby returns.
require 'fileutils'
require_relative 'fixture_runtime'
require ENV.fetch('NAT_AUDIT_TOOL') { File.expand_path('../tools/bc2cpp/native_class_results', __dir__) }

ROOT = File.expand_path('../..', __dir__)
failures = []
check = lambda do |name, ok|
  puts "  #{ok ? 'ok  ' : 'FAIL'} #{name}"
  failures << name unless ok
end
Dir.mktmpdir do |dir|
  copies = %w[3rd/mruby/mrbgems/mruby-io/src/file.c 3rd/mruby/src/string.c 3rd/mruby/src/array.c 3rd/mruby/mrbgems/mruby-array-ext/src/array.c].to_h do |relative|
    path = File.join(dir, relative)
    FileUtils.mkdir_p(File.dirname(path))
    FileUtils.cp(File.join(ROOT, relative), path)
    [relative, path]
  end
  %w[compact flatten __uniq join].each do |name|
    path = copies.fetch(name == 'join' ? '3rd/mruby/src/array.c' : '3rd/mruby/mrbgems/mruby-array-ext/src/array.c')
    paths = name == 'join' ? [path, copies.fetch('3rd/mruby/mrbgems/mruby-io/src/file.c')] : [path]
    kind = name == 'join' ? 'String' : 'Array'
    check.call("audited #{name}", NativeClassResults.kinds(name, paths, string_subclass_free: true) == { '<audited-native>' => kind })
    check.call("missing registration #{name}", NativeClassResults.kinds(name, []).nil?)
    check.call("unknown registration #{name}", NativeClassResults.kinds(name, paths + [File.join(dir, 'unknown.c')], string_subclass_free: true).nil?)
    copies.reject { |relative,| name != 'join' && (relative.end_with?('/string.c') || relative.end_with?('/file.c')) || name == 'join' && relative.include?('mruby-array-ext') }.each do |relative, file|
      original = File.binread(file)
      File.binwrite(file, original + "\nvoid changed_array_contract() {}\n")
      check.call("changed #{relative}: #{name}", NativeClassResults.kinds(name, paths, string_subclass_free: true).nil?)
      File.binwrite(file, original)
    end
    check.call('File join may preserve a String subclass', NativeClassResults.kinds(name, paths).nil?) if name == 'join'
    helper = copies.fetch(name == 'join' ? '3rd/mruby/src/string.c' : '3rd/mruby/src/array.c')
    File.rename(helper, helper + '.saved')
    check.call("missing allocation helper #{name}", NativeClassResults.kinds(name, paths, string_subclass_free: true).nil?)
    File.rename(helper + '.saved', helper)
  end
end

SOURCE = <<~RUBY
  class NatOther
    def size; 91; end
  end
  class NatArray < Array; end
  class NatRunner
    def compact_size(value); value.compact.size; end
    def flatten_size(value); value.flatten.size; end
    def unique(value); value.__uniq.size; end
    def join_size(value); value.join.size; end
    def file_join_size(value); File.join(value).size; end
  end
RUBY
OWNERS = %w[NatOther NatArray NatRunner].freeze
runtime = Bc2cppFixtureRuntime
body_of = ->(code, name) { code[/^mrb_value NatRunner_#{name}_impl\(mrb_state\* M.*?(?=^(?:static )?mrb_value \w+\(mrb_state\* M|\z)/m].to_s }
if ENV['MRBC']
  worlds = [
    ['native transforms', SOURCE, {}, {}, true, true],
    ['String subclass', SOURCE + "class NatString < String; def size; 91; end; end\n", {}, {}, true, true],
    ['transform kill switch', SOURCE, { 'BC2CPP_NATIVE_ARRAY_TRANSFORMS' => '0' }, {}, false, true],
    ['class fact kill switch', SOURCE, { 'BC2CPP_NATIVE_CLASS_RESULTS' => '0' }, {}, false, true],
    ['Ruby return widens join', SOURCE + "class NatOther; def compact; self; end; def flatten; self; end; def __uniq; self; end; def join; self; end; end\n", {}, {}, false, true],
    ['Ruby Array replacement', SOURCE + "class Array; def compact; NatOther.new; end; def flatten; NatOther.new; end; def __uniq; NatOther.new; end; def join; NatOther.new; end; end\n", {}, {}, false, true],
    ['unlinked foreign Ruby', SOURCE, {}, { foreign: [['outside.rb', 'class NatOther; def compact; self; end; def flatten; self; end; def __uniq; self; end; def join; self; end; end']] }, true, false],
    ['unlinked native', SOURCE, {}, { native: [['outside.c', 'void init(mrb_state* mrb) { mrb_define_method(mrb, klass, "compact", unknown, MRB_ARGS_NONE()); mrb_define_method(mrb, klass, "flatten", unknown, MRB_ARGS_NONE()); mrb_define_method(mrb, klass, "__uniq", unknown, MRB_ARGS_NONE()); mrb_define_method(mrb, klass, "join", unknown, MRB_ARGS_NONE()); }']] }, true, false],
    ['singleton installer', SOURCE + "class NatOther; def install; define_singleton_method(:compact) { self }; end; end\n", {}, {}, false, false],
    ['alias replacement', SOURCE + "class NatOther; alias __uniq size; alias join size; end\n", {}, {}, false, false],
    ['method missing', SOURCE + "class NatOther; def method_missing(name); self; end; end\n", {}, {}, false, false],
    ['open world', SOURCE, {}, { closed: false }, false, false]
  ]
  outside_gem = Dir.mktmpdir('native-array-transform-gem')
  at_exit { FileUtils.remove_entry(outside_gem) }
  FileUtils.mkdir_p(File.join(outside_gem, 'src'))
  File.write(File.join(outside_gem, 'src/outside.c'), worlds.find { |row| row.first == 'unlinked native' }[3][:native].first.last)
  worlds << ['unknown linked native', SOURCE, {}, { build_gems: [['native-array-transform-gem', outside_gem]] }, false, false]
  outside_ruby = Dir.mktmpdir('native-array-transform-ruby')
  at_exit { FileUtils.remove_entry(outside_ruby) }
  FileUtils.mkdir_p(File.join(outside_ruby, 'mrblib'))
  File.write(File.join(outside_ruby, 'mrblib/outside.rb'), worlds.find { |row| row.first == 'unlinked foreign Ruby' }[3][:foreign].first.last)
  worlds << ['linked foreign Ruby', SOURCE, {}, { build_gems: [['native-array-transform-ruby', outside_ruby]] }, false, false]
  worlds.each do |name, source, env, options, known, run|
    Dir.mktmpdir do |dir|
      saved = env.to_h { |key,| [key, ENV[key]] }
      begin
        env.each { |key, value| ENV[key] = value }
        code, err = runtime.generate(source, dir, only_owners: OWNERS + ['NatString'], **options)
        %w[compact flatten unique join].each do |method|
          body = body_of.call(code, method == 'unique' ? method : method + '_size')
          marker = method == 'join' ? 'NATIVE_CORE_EXACT :size' : 'CLOSED_WORLD_NATIVE_EXACT :size -> Array'
          # Hash's uncompiled compact/flatten bodies still prevent a name-wide join.
          expected = %w[unique join].include?(method) && known && !(method == 'join' && name == 'String subclass')
          check.call("#{name}: #{method} class", !body.empty? && body.include?(marker) == expected)
        end
        next unless run && ENV['NAT_GENERATED_ONLY'] != '1'

        full = runtime.full || (ENV['BC2CPP_FULL_BUILD_DIR'] && runtime.full_or_build)
        unless full
          puts "-- SKIP #{name} runtime: set BC2CPP_MRUBY_FULL or BC2CPP_FULL_BUILD_DIR"
          next
        end

        runtime_owners = name == 'String subclass' ? OWNERS + ['NatString'] : OWNERS
        harness = <<~CPP
          static int scenario(mrb_state* M) {
            mrb_value runner = mrb_obj_new(M, mrb_class_get(M, "NatRunner"), 0, nullptr);
            mrb_value array = mrb_ary_new(M);
            mrb_ary_push(M, array, mrb_fixnum_value(1));
            mrb_ary_push(M, array, mrb_nil_value());
            mrb_ary_push(M, array, mrb_fixnum_value(1));
            call(M, "compact", runner, "compact_size", 1, &array);
            call(M, "flatten", runner, "flatten_size", 1, &array);
            call(M, "unique", runner, "unique", 1, &array);
            call(M, "join", runner, "join_size", 1, &array);
            mrb_value subclass = mrb_obj_new(M, mrb_class_get(M, "NatArray"), 0, nullptr);
            mrb_ary_push(M, subclass, mrb_fixnum_value(1));
            call(M, "subclass", runner, "compact_size", 1, &subclass);
            call(M, "subunique", runner, "unique", 1, &subclass);
            call(M, "subjoin", runner, "join_size", 1, &subclass);
            #{name == 'String subclass' ? 'mrb_value text = mrb_obj_new(M, mrb_class_get(M, "NatString"), 0, nullptr); call(M, "file_subclass", runner, "file_join_size", 1, &text);' : ''}
            #{name == 'Ruby return widens join' ? 'mrb_value other = mrb_obj_new(M, mrb_class_get(M, "NatOther"), 0, nullptr); call(M, "other", runner, "flatten_size", 1, &other);' : ''}
            return 0;
          }
        CPP
        built, output = runtime.run(dir, err, runtime_owners, harness, build: full, full: true)
        sections = runtime.sections(output).transform_values { |lines| lines.reject { |line| line.start_with?('  dispatches=') } }
        replacement = name == 'Ruby Array replacement'
        ok = built && sections['compiled'] == sections['interpreted'] &&
             output.include?("compact => #{replacement ? 91 : 2}") && output.include?("flatten => #{replacement ? 91 : 3}") &&
             output.include?("unique => #{replacement ? 91 : 2}") && output.include?("join => #{replacement ? 91 : 2}") && output.include?("subclass => #{replacement ? 91 : 1}") &&
             output.include?("subunique => #{replacement ? 91 : 1}") && output.include?("subjoin => #{replacement ? 91 : 1}") &&
             (name != 'String subclass' || output.include?('file_subclass => 91')) &&
             (name != 'Ruby return widens join' || output.include?('other => 91'))
        check.call("#{name}: runtime parity", ok)
        warn output unless ok
      ensure
        saved.each { |key, value| ENV[key] = value }
      end
    end
  end
else
  puts '-- SKIP generated code: set MRBC'
end
abort "FAILED: #{failures.join(', ')}" unless failures.empty?
puts 'bc2cpp native array transforms check: PASS'
