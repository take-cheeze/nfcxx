#!/usr/bin/env ruby
# frozen_string_literal: true

# ADR 0335: native copies preserve class, not element identities or immutability.
require 'fileutils'
require_relative 'fixture_runtime'
tools_dir = ENV.fetch('NCR2_TOOLS_DIR', File.expand_path('../../tools/bc2cpp', __dir__))
%w[native_core_direct codegen_return_classes codegen_native_results].each { |name| require File.join(tools_dir, name) }

ROOT = File.expand_path('../..', __dir__)
failures = []
check = lambda do |name, ok|
  puts "  #{ok ? 'ok  ' : 'FAIL'} #{name}"
  failures << name unless ok
end
Dir.mktmpdir do |dir|
  copies = %w[class kernel array].to_h do |file|
    relative = "3rd/mruby/src/#{file}.c"
    path = File.join(dir, relative)
    FileUtils.mkdir_p(File.dirname(path))
    FileUtils.cp(File.join(ROOT, relative), path)
    [file, path]
  end
  compact_relative = '3rd/mruby/mrbgems/mruby-array-ext/src/array.c'
  compact_path = File.join(dir, compact_relative)
  FileUtils.mkdir_p(File.dirname(compact_path))
  FileUtils.cp(File.join(ROOT, compact_relative), compact_path)
  world = Struct.new(:paths) do
    def exact_instances_singleton_free? = true
    def native_paths_spelling(_name) = paths
  end
  probe = CodeGen.allocate
  probe.instance_variable_set(:@native_name_sources, {})
  probe.instance_variable_set(:@closed_world, world.new(copies.values_at('class', 'kernel')))
  def probe.ownerless_native_dispatch_safe?(_name) = true
  def probe.native_core_entry_safe?(_entry) = true
  check.call('pinned dup sources', probe.audit_native_dup_result)
  %w[class kernel].each do |file|
    path = copies.fetch(file)
    original = File.binread(path)
    File.binwrite(path, original + "\nvoid changed_dup_contract() {}\n")
    check.call("changed dup source #{file}", !probe.audit_native_dup_result)
    File.binwrite(path, original)
  end
  probe.instance_variable_set(:@closed_world, world.new([copies.fetch('kernel')]))
  check.call('dup requires its allocation helper', !probe.audit_native_dup_result)
  probe.instance_variable_set(:@closed_world, world.new([copies.fetch('array')]))
  check.call('unmodelled dup registration', !probe.audit_native_dup_result)
  probe.instance_variable_set(:@closed_world, world.new([copies.fetch('array'), compact_path]))
  check.call('compact returns Array', probe.compute_native_result_kind('compact', 'Array') == 'Array')
  check.call('join returns String', probe.compute_native_result_kind('join', 'Array') == 'String')
  path = copies.fetch('array')
  original = File.binread(path)
  File.binwrite(path, original + "\nvoid changed_join_helper() {}\n")
  check.call('changed join helper', probe.compute_native_result_kind('join', 'Array').nil?)
  check.call('changed compact helper', probe.compute_native_result_kind('compact', 'Array').nil?)
  File.binwrite(path, original)
  original = File.binread(compact_path)
  File.binwrite(compact_path, original + "\nvoid changed_compact_contract() {}\n")
  check.call('changed compact implementation', probe.compute_native_result_kind('compact', 'Array').nil?)
  File.binwrite(compact_path, original)
end

SOURCE = <<~RUBY
  class CrBox
    def tag; 7; end
    def initialize_copy(other); CrOther.new; end
  end
  class CrOther
    def size; 91; end
    def tag; 91; end
  end
  class CrRunner
    def copy; CrBox.new.dup.tag; end
    def ary; [1, nil, 2].dup.size; end
    def hash; {a: 1}.dup.size; end
    def string; 'abc'.dup.size; end
    def compact; [1, nil, 2].compact.size; end
    def join; [1, 2].join.size; end
  end
RUBY
OWNERS = %w[CrBox CrOther CrRunner Array Kernel].freeze
runtime = Bc2cppFixtureRuntime
body_of = ->(code, name) { code[/^mrb_value CrRunner_#{name}_impl\(mrb_state\* M.*?(?=^(?:static )?mrb_value \w+\(mrb_state\* M|\z)/m].to_s }
if ENV['MRBC']
  worlds = [
    ['native copies', SOURCE, {}, true, true, true, 7, 3, 2, 2],
    ['kill switch', SOURCE, { 'BC2CPP_NATIVE_COLLECTION_RESULTS' => '0' }, false, false, false, 7, 3, 2, 2],
    ['Ruby dup override', SOURCE + "class CrBox; def dup; CrOther.new; end; end\n", {}, false, true, true, 91, 3, 2, 2],
    ['Ruby Array compact override', SOURCE + "class Array; def compact; CrOther.new; end; end\n", {}, true, false, true, 7, 3, 91, 2],
    ['Ruby Array join override', SOURCE + "class Array; def join; CrOther.new; end; end\n", {}, true, true, false, 7, 3, 2, 91],
    ['singleton creation', SOURCE + "class CrBox; def install; define_singleton_method(:dup) { CrOther.new }; end; end\n", {}, false, false, false, nil, nil, nil, nil]
  ]
  worlds.each do |name, source, env, dup_known, compact_known, join_known, copy, ary, compact, join|
    Dir.mktmpdir do |dir|
      saved = env.to_h { |key,| [key, ENV[key]] }
      begin
        env.each { |key, value| ENV[key] = value }
        code, err = runtime.generate(source, dir, only_owners: OWNERS)
        check.call("#{name}: dup class", body_of.call(code, 'copy').include?('CLOSED_WORLD_EXACT_CLASS :tag -> CrBox') == dup_known)
        check.call("#{name}: compact class", body_of.call(code, 'compact').include?('CLOSED_WORLD_NATIVE_EXACT :size -> Array') == compact_known)
        check.call("#{name}: join class", body_of.call(code, 'join').include?('NATIVE_CORE_EXACT :size') == join_known)
        next if copy.nil? || ENV['NCR2_GENERATED_ONLY'] == '1'

        builds = []
        full = runtime.full || (ENV['BC2CPP_FULL_BUILD_DIR'] && runtime.full_or_build)
        builds << ['full-core', full, true] if full
        builds << ['core-only', runtime.core, false] if runtime.core && ENV['NCR2_FULL_ONLY'] != '1'
        harness = <<~CPP
          static int scenario(mrb_state* M) {
            mrb_value runner = mrb_obj_new(M, mrb_class_get(M, "CrRunner"), 0, nullptr);
            call(M, "copy", runner, "copy");
            call(M, "array", runner, "ary");
            call(M, "hash", runner, "hash");
            call(M, "string", runner, "string");
            if (mrb_respond_to(M, mrb_ary_new(M), mrb_intern_lit(M, "compact"))) call(M, "compact", runner, "compact");
            call(M, "join", runner, "join");
            return 0;
          }
        CPP
        builds.each do |label, build, full_core|
          built, output = runtime.run(dir, err, OWNERS, harness, build: build, full: full_core)
          sections = runtime.sections(output).transform_values { |lines| lines.reject { |line| line.start_with?('  dispatches=') } }
          ok = built && sections['compiled'] == sections['interpreted'] && output.include?("copy => #{copy}") &&
               output.include?("array => #{ary}") && (full_core || name == 'Ruby Array compact override' ? output.include?("compact => #{compact}") : true) && output.include?("join => #{join}")
          check.call("#{name}, #{label}: runtime parity", ok)
          warn output unless ok
        end
      ensure
        saved.each { |key, value| ENV[key] = value }
      end
    end
  end
else
  puts '-- SKIP generated code: set MRBC'
end
abort "FAILED: #{failures.join(', ')}" unless failures.empty?
puts 'bc2cpp native collection results check: PASS'
