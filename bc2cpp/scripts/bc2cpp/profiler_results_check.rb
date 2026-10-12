#!/usr/bin/env ruby
# frozen_string_literal: true

require_relative 'fixture_runtime'
require Bc2cppFixtureRuntime::BC2CPP

SOURCE = <<~RUBY_SOURCE
  module RGSS; end
  class PfRunner
    def pf_wrap; RGSS::Profiler.section("wrap") { pf_payload }; end
    def direct; RGSS::Profiler.section("direct") { [1, 2] }.size; end
    def next_value; RGSS::Profiler.section("next") { next [1, 2, 3] }.size; end
    def nested; RGSS::Profiler.frame { RGSS::Profiler.section("nested") { [1] } }.size; end
    def loaded; pf_wrap.size; end
    def stored; @pf_items = RGSS::Profiler.section("stored") { pf_payload }; end
    def read; @pf_items.size; end
    def captured(value); RGSS::Profiler.section("captured") { value }.size; end
    def ivar; RGSS::Profiler.section("ivar") { @pf_items }.size; end
    def capture_store
      value = [1]
      RGSS::Profiler.section("store") { value = [1, 2, 3] }
      value.size
    end
    def nested_local(input)
      RGSS::Profiler.frame do
        local = [input, input]
        RGSS::Profiler.section("local") { local }
      end.size
    end
    def breaking; RGSS::Profiler.section("break") { break "different" if @pf_flag; [1] }.size; end
    def nonlocal; RGSS::Profiler.section("return") { return "different" }.size; end
    def parameters; RGSS::Profiler.section("arg") { |value| value }.size; end
    def unknown_arm(value); RGSS::Profiler.section("unknown") { value ? [1] : value }.size; end
    def forwarded(&block); RGSS::Profiler.section("forwarded", &block).size; end
    def merged(flag)
      result = RGSS::Profiler.section("merged") { [1] }
      result = "different" if flag
      result.size
    end
    def nullable(flag); RGSS::Profiler.section("nil") { flag ? nil : [1] }.size; end
    def pf_payload; [1, 2]; end
    def late_wrap; RGSS::Profiler.section("late") { late_payload }; end
    def late_read; late_wrap.size; end
    def late_payload; @pf_flag ? [1] : late_unknown; end
    def late_unknown; Object.new; end
  end
RUBY_SOURCE
OWNERS = %w[PfRunner].freeze
failures = []
check = lambda do |name, ok|
  puts "  #{ok ? 'ok  ' : 'FAIL'} #{name}"
  failures << name unless ok
end
exact = lambda do |code, name|
  body = code[/^mrb_value PfRunner_#{name}_impl\(mrb_state\* M.*?(?=^(?:static )?mrb_value \w+\(mrb_state\* M|\z)/m].to_s
  body.include?('CLOSED_WORLD_NATIVE_EXACT :size -> Array')
end
Dir.mktmpdir do |dir|
  relative = ProfilerResults::PATH
  path = File.join(dir, relative)
  FileUtils.mkdir_p(File.dirname(path))
  FileUtils.cp(File.join(Bc2cppFixtureRuntime::ROOT, relative), path)
  lookup = lambda do
    world = Object.new
    world.define_singleton_method(:native_paths_spelling) { |_name| [path] }
    world.define_singleton_method(:native_exact_direct_name_safe?) { |*_args| true }
    world.define_singleton_method(:native_class_constant_stable?) { |_name, bindings:| bindings == 2 }
    world.define_singleton_method(:stable_constant_identity?) { |_name| true }
    cg = CodeGen.allocate
    cg.instance_variable_set(:@closed_world, world)
    cg.instance_variable_set(:@native_name_sources, { 'section' => [path] })
    cg.instance_variable_set(:@registry, {})
    cg.instance_variable_set(:@prepended_modules, {})
    cg.instance_variable_set(:@unknown_mixins, Set.new)
    cg.define_singleton_method(:symbol_installed_names) { Set.new }
    cg.define_singleton_method(:numeric_aliased_names) { Set.new }
    cg.define_singleton_method(:devirt_blocked_name?) { |_name| false }
    cg.profiler_result_lookup_safe?('section')
  end
  saved_installed = CodeGen.core_result_installed_names
  saved_opaque = CodeGen.core_result_opaque_defs
  begin
    CodeGen.core_result_installed_names = Set.new
    CodeGen.core_result_opaque_defs = Set.new
    check.call('pinned native source admits the lookup', lookup.call)
    File.write(path, File.read(path).sub('return ret;', 'return mrb_nil_value();'))
    check.call('changed native source withdraws the lookup', !lookup.call)
  ensure
    CodeGen.core_result_installed_names = saved_installed
    CodeGen.core_result_opaque_defs = saved_opaque
  end
end
worlds = [
  ['native', SOURCE, {}, true],
  ['kill switch', SOURCE, { 'BC2CPP_PROFILER_RESULTS' => '0' }, false],
  ['Ruby override', SOURCE + "module RGSS::Profiler; def self.section(name, &block); \"different\"; end; end\n", {}, false],
  ['constant rebind', SOURCE + "module RGSS; Profiler = Object.new; end\n", {}, false],
  ['root rebind', SOURCE + "RGSS = Object.new\n", {}, false],
  ['lexical shadow', SOURCE.sub('class PfRunner', 'class PfRunner; module RGSS; module Profiler; end; end'), {}, false],
  ['installer', SOURCE + "module RGSS::Profiler; define_singleton_method(:section) { |name, &block| \"different\" }; end\n", {}, false],
  ['native replacement', SOURCE, {}, false],
  ['foreign replacement', SOURCE, {}, false],
  ['open world', SOURCE, {}, false]
]
worlds.select! { |name, _| name == ENV['PFR_CASE'] } if ENV['PFR_CASE']
abort "unknown PFR_CASE: #{ENV['PFR_CASE']}" if worlds.empty?
if ENV['MRBC']
  worlds.each do |name, source, env, proven|
    Dir.mktmpdir do |dir|
      saved = env.to_h { |key, _| [key, ENV[key]] }
      begin
        env.each { |key, value| ENV[key] = value }
        native = name == 'native replacement' ? [['extra.c', 'void replace(mrb_state *mrb, struct RClass *c) { mrb_define_class_method(mrb, c, "section", replacement, MRB_ARGS_ANY()); }']] : []
        linked = name == 'foreign replacement' ? [['pf-foreign', File.join(dir, 'pf-foreign')]] : []
        FileUtils.mkdir_p(File.join(dir, 'pf-foreign/mrblib')) unless linked.empty?
        foreign = linked.empty? ? [] : [['pf-foreign/mrblib/outside.rb', 'module RGSS::Profiler; def self.section(name, &block); "different"; end; end']]
        code, err = Bc2cppFixtureRuntime.generate(source, dir, only_owners: OWNERS, native: native,
                                                foreign: foreign, build_gems: linked, closed: name != 'open world')
        %w[direct next_value nested loaded read].each do |method|
          check.call("#{name}: #{method} result", exact.call(code, method) == proven)
        end
        %w[captured ivar breaking nonlocal parameters unknown_arm forwarded merged late_read].each do |method|
          check.call("#{name}: #{method} stays unproved", !exact.call(code, method))
        end
        next unless name == 'native' || name == 'kill switch'
        next if ENV['PFR_GENERATED_ONLY'] == '1'

        build = Bc2cppFixtureRuntime.full_or_build
        next puts 'SKIP: full-core mruby unavailable' unless build

        File.write(File.join(dir, 'profiler.hxx'), <<~CPP)
          #pragma once
          #include <cstdint>
          uint64_t profiler_section_begin();
          void profiler_section_end(const char*, uint64_t);
          void profiler_frame_begin();
          void profiler_frame_end();
        CPP
        body = <<~CPP
          #include <mruby/proc.h>
          static bool pf_enabled;
          static int pf_closed;
          uint64_t profiler_section_begin() { return pf_enabled ? 1 : 0; }
          void profiler_section_end(const char*, uint64_t stamp) { if (stamp) ++pf_closed; }
          void profiler_frame_begin() {}
          void profiler_frame_end() {}
          static mrb_value pf_section(mrb_state* M, mrb_value) {
            mrb_value name, block;
            mrb_get_args(M, "S&", &name, &block);
            if (mrb_nil_p(block)) return mrb_nil_value();
            const auto stamp = profiler_section_begin();
            const auto value = mrb_yield_argv(M, block, 0, nullptr);
            profiler_section_end("fixture", stamp);
            return value;
          }
          static mrb_value pf_frame(mrb_state* M, mrb_value) {
            mrb_value block;
            mrb_get_args(M, "&", &block);
            if (mrb_nil_p(block)) return mrb_nil_value();
            return mrb_yield_argv(M, block, 0, nullptr);
          }
          static int scenario(mrb_state* M) {
            RClass* rgss = mrb_module_get(M, "RGSS");
            RClass* prof = mrb_define_module_under(M, rgss, "Profiler");
            mrb_define_module_function(M, prof, "section", pf_section, MRB_ARGS_REQ(1) | MRB_ARGS_BLOCK());
            mrb_define_module_function(M, prof, "frame", pf_frame, MRB_ARGS_BLOCK());
            const auto obj = mrb_obj_new(M, mrb_class_get(M, "PfRunner"), 0, nullptr);
            for (int enabled = 0; enabled < 2; ++enabled) {
              pf_enabled = enabled;
              pf_closed = 0;
              call(M, "direct", obj, "direct");
              call(M, "next", obj, "next_value");
              call(M, "nested", obj, "nested");
              call(M, "loaded", obj, "loaded");
              call(M, "stored", obj, "stored");
              call(M, "read", obj, "read");
              call(M, "late", obj, "late_read");
              const auto text = mrb_str_new_cstr(M, "different");
              call(M, "captured", obj, "captured", 1, &text);
              call(M, "nested local", obj, "nested_local", 1, &text);
              call(M, "capture store", obj, "capture_store");
              call(M, "ivar", obj, "ivar");
              mrb_iv_set(M, obj, mrb_intern_lit(M, "@pf_flag"), mrb_true_value());
              call(M, "break", obj, "breaking");
              call(M, "nonlocal", obj, "nonlocal");
              call(M, "block argument", obj, "parameters");
              const auto yes = mrb_true_value();
              call(M, "nil", obj, "nullable", 1, &yes);
              const auto no = mrb_false_value();
              call(M, "array", obj, "nullable", 1, &no);
              call(M, "unknown nil", obj, "unknown_arm", 1, &no);
              mrb_iv_set(M, obj, mrb_intern_lit(M, "@pf_flag"), mrb_nil_value());
              std::printf("closed=%d\\n", pf_closed);
            }
            return 0;
          }
        CPP
        built, output = Bc2cppFixtureRuntime.run(dir, err, OWNERS, body, build: build, full: true)
        check.call("#{name}: runtime fixture builds", built)
        if built
          runs = Bc2cppFixtureRuntime.sections(output)
          interpreted = runs.fetch('interpreted', []).reject { |line| line.start_with?('  dispatches=') }
          compiled = runs.fetch('compiled', []).reject { |line| line.start_with?('  dispatches=') }
          parity = interpreted == compiled &&
                     output.include?('direct => 2') && output.include?('next => 3') &&
                     output.include?('late => raised NoMethodError') && output.include?('break => 9') &&
                     output.include?('nil => raised NoMethodError') && output.include?('array => 1')
          check.call("#{name}: enabled and disabled runtime parity", parity)
          warn output unless parity
        else
          warn output.lines.last(15).join
        end
      ensure
        saved.each { |key, value| value ? ENV[key] = value : ENV.delete(key) }
      end
    end
  end
else
  puts 'SKIP: set MRBC for generated-code and runtime checks'
end
abort "bc2cpp profiler results check: #{failures.size} failure(s)" unless failures.empty?
puts 'bc2cpp profiler results check: PASS'
