#!/usr/bin/env ruby
# encoding: UTF-8
# frozen_string_literal: true

# PROFILER_SCOPE (docs/adr/0391): two widenings of the RGSS::Profiler section/frame inliner (ADR 0232).
#
#   RESCUE_PROFILER_INLINE: a `Profiler.section { }` inside a `rescue`-protected range is inlined in the extracted
#     try function. ADR 0376 kept it out believing the block call it replaces closes the section when the body raises;
#     prof_section/prof_frame (mruby-rgss/src/profiler.cxx) call profiler_section_end/frame_end after
#     mrb_yield_argv returns and have no unwinding guard, so a raise skips the end call there exactly as it skips the
#     inlined one. The behavioural half pins that: the begin/end calls recorded by the natives and by the inlined code
#     are the same sequence for a body that returns and for a body that raises.
#   PROFILER_NAME_SCOPED: `RGSS::Profiler.frame` is inlined although other classes define a Ruby `frame` (the lookup
#     on the module object finds Profiler's own native first). A Ruby `frame`/`section` on RGSS::Profiler itself, or a
#     rebinding of the constant, still stops it.
#
#   MRBC=path/to/host/mrbc [BC2CPP_MRUBY_FULL=dir] ruby scripts/bc2cpp/profiler_scope_check.rb
#   PSC_GENERATED_ONLY=1 skips the runtime half.

require 'tmpdir'
require_relative 'fixture_runtime'

failures = []
check = lambda do |what, condition|
  puts "  #{condition ? 'ok  ' : 'FAIL'} #{what}"
  failures << what unless condition
end

unless Bc2cppFixtureRuntime.mrbc && system(Bc2cppFixtureRuntime.mrbc, '--version', out: File::NULL, err: File::NULL)
  puts '  SKIP: no host mrbc (set MRBC)'
  exit 0
end

SRC = <<~'RUBY'
  module RGSS; end
  class PsOther
    def self.frame(a, b); a + b; end
    def self.section(a); a; end
    def frame; 1; end
  end
  class PsFx
    def plain; RGSS::Profiler.section("ps.plain") { 1 }; end
    def protected_ok
      begin
        RGSS::Profiler.section("ps.protected") { 2 }
      rescue RuntimeError
        :rescued
      end
    end
    def protected_raise
      begin
        RGSS::Profiler.section("ps.raising") { raise "boom" }
      rescue RuntimeError
        :rescued
      end
    end
    def protected_nested
      begin
        RGSS::Profiler.section("ps.outer") { RGSS::Profiler.section("ps.inner") { 3 } }
      rescue RuntimeError
        :rescued
      end
    end
    def protected_return
      begin
        RGSS::Profiler.section("ps.returning") { return :early }
      rescue RuntimeError
        :rescued
      end
    end
    def framed; RGSS::Profiler.frame { RGSS::Profiler.section("ps.in_frame") { 4 } }; end
    def framed_raise
      RGSS::Profiler.frame { raise "frame boom" }
    rescue RuntimeError
      :rescued
    end
  end
RUBY
OWNERS = %w[PsFx].freeze

def generate(extra = '', env = {})
  saved = env.to_h { |k, _| [k, ENV.fetch(k, nil)] }
  env.each { |k, v| ENV[k] = v }
  Dir.mktmpdir do |dir|
    return Bc2cppFixtureRuntime.generate(SRC + extra, dir, only_owners: OWNERS)
  end
ensure
  saved&.each { |k, v| v.nil? ? ENV.delete(k) : ENV[k] = v }
end

def body_of(code, name)
  code[/^mrb_value PsFx_#{name}_impl\(mrb_state\* M.*?(?=^(?:static )?mrb_value \w+\(mrb_state\* M|\z)/m].to_s +
    code.scan(/^static mrb_value PsFx_#{name}_impl_rescue_try\w*\(.*?^\s*mrb_raise\(M, [^\n]*fell off the end[^\n]*\n\}/m).join
end

def inlined?(code, name, marker = 'PROFILER_SECTION_INLINE')
  code.include?("// #{marker}") && body_of(code, name).include?('profiler_') && !body_of(code, name).include?('BLOCK_FALLBACK')
end

def fallback_in?(code, name, meth)
  body_of(code, name).include?("BLOCK_FALLBACK :#{meth}")
end

puts '-- generated code'
code, = generate
check.call('plain: a section outside a rescue range is inlined', code.include?('PROFILER_SECTION_INLINE :ps.plain'))
%w[protected_ok protected_raise protected_nested].each do |name|
  check.call("#{name}: a section inside a rescue range is inlined in the try function",
             !fallback_in?(code, name, 'section') && body_of(code, name).include?('profiler_section_begin()'))
end
check.call('protected_nested: the nested section is inlined too',
           code.include?('PROFILER_SECTION_INLINE :ps.outer') && code.include?('PROFILER_SECTION_INLINE :ps.inner'))
check.call('protected_return: a method return through the block keeps the call (RETURN_BLK cannot leave a try function)',
           fallback_in?(code, 'protected_return', 'section') || !body_of(code, 'protected_return').include?('PROFILER_SECTION_INLINE'))
check.call('framed: Profiler.frame is inlined although PsOther defines frame', code.include?('profiler_frame_begin()') &&
           !fallback_in?(code, 'framed', 'frame'))
check.call('framed: the section inside the frame is inlined', code.include?('PROFILER_SECTION_INLINE :ps.in_frame'))
check.call('no #error anywhere', !code.include?('#error'))
defined = code.scan(/^static mrb_value (\w+_profiler_\w+)\(/).flatten
check.call('no inlined-section function is defined twice (a nested section at the enclosing section\'s address)',
           !defined.empty? && defined.uniq.size == defined.size && code.include?('PROFILER_SECTION_INLINE :ps.inner'))

puts '-- the switches'
off, = generate('', 'BC2CPP_RESCUE_PROFILER_INLINE' => '0')
check.call('BC2CPP_RESCUE_PROFILER_INLINE=0: a protected section keeps the call',
           %w[protected_ok protected_raise protected_nested].all? { |n| fallback_in?(off, n, 'section') })
check.call('BC2CPP_RESCUE_PROFILER_INLINE=0: an unprotected section is still inlined', off.include?('PROFILER_SECTION_INLINE :ps.plain'))
unscoped, = generate('', 'BC2CPP_PROFILER_NAME_SCOPED' => '0')
check.call('BC2CPP_PROFILER_NAME_SCOPED=0: frame keeps the call while PsOther defines it', fallback_in?(unscoped, 'framed', 'frame'))
check.call('BC2CPP_PROFILER_NAME_SCOPED=0: section keeps the call too while PsOther defines it',
           fallback_in?(unscoped, 'plain', 'section') && !unscoped.include?('PROFILER_SECTION_INLINE :ps.plain'))
check.call('PROFILER_NAME_SCOPED on: section is inlined although PsOther defines it', code.include?('PROFILER_SECTION_INLINE :ps.plain'))

puts '-- a definition on the module itself stops it'
[
  ['a Ruby frame on RGSS::Profiler', "module RGSS::Profiler; def self.frame; yield; end; end\n", 'frame'],
  ['a Ruby section on RGSS::Profiler', "module RGSS::Profiler; def self.section(n); yield; end; end\n", 'section'],
  ['a rebound constant', "module RGSS; Profiler = Object.new; end\n", 'frame'],
  # A top-level module named Profiler is not RGSS::Profiler, but the owner test matches the last name segment
  # (profiler_owner? in codegen_profiler_results.rb); a qualified-only test would inline past it.
  ['a top-level Profiler module: frame keeps the call', "module Profiler; def self.frame(&b); b.call; end; end\n", 'frame']
].each do |what, extra, meth|
  c, = generate(extra)
  check.call("#{what}: #{meth} keeps the call", c.include?("BLOCK_FALLBACK :#{meth}") && !c.include?('#error'))
end

# ---------------------------------------------------------------------------------------------------------
if ENV['PSC_GENERATED_ONLY'] == '1'
  puts '  SKIP behavioural comparison: PSC_GENERATED_ONLY'
else
  build = Bc2cppFixtureRuntime.full_or_build
  if build.nil?
    puts '  SKIP behavioural comparison: needs a full-core libmruby (BC2CPP_MRUBY_FULL, or rake, g++ and 3rd/mruby)'
  else
    puts '-- begin/end calls: the natives and the inlined code record the same sequence'
    Dir.mktmpdir do |dir|
      code, err = Bc2cppFixtureRuntime.generate(SRC, dir, only_owners: OWNERS)
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
        #include <string>
        static bool ps_enabled;
        static std::string ps_log;
        uint64_t profiler_section_begin() { ps_log += "B "; return ps_enabled ? 1 : 0; }
        void profiler_section_end(const char* name, uint64_t stamp) { ps_log += std::string("E:") + name + (stamp ? "+ " : "- "); }
        void profiler_frame_begin() { ps_log += "FB "; }
        void profiler_frame_end() { ps_log += "FE "; }
        // The natives of mruby-rgss/src/profiler.cxx, reduced to the calls this check records (same order, same
        // absence of an unwinding guard).
        static mrb_value ps_section(mrb_state* M, mrb_value) {
          mrb_value name, block;
          mrb_get_args(M, "S&", &name, &block);
          if (mrb_nil_p(block)) return mrb_nil_value();
          const auto stamp = profiler_section_begin();
          const auto value = mrb_yield_argv(M, block, 0, nullptr);
          profiler_section_end(RSTRING_PTR(name), stamp);
          return value;
        }
        static mrb_value ps_frame(mrb_state* M, mrb_value) {
          mrb_value block;
          mrb_get_args(M, "&", &block);
          if (mrb_nil_p(block)) return mrb_nil_value();
          profiler_frame_begin();
          const auto value = mrb_yield_argv(M, block, 0, nullptr);
          profiler_frame_end();
          return value;
        }
        static int scenario(mrb_state* M) {
          RClass* rgss = mrb_module_get(M, "RGSS");
          RClass* prof = mrb_define_module_under(M, rgss, "Profiler");
          mrb_define_module_function(M, prof, "section", ps_section, MRB_ARGS_REQ(1) | MRB_ARGS_BLOCK());
          mrb_define_module_function(M, prof, "frame", ps_frame, MRB_ARGS_BLOCK());
          const auto obj = mrb_obj_new(M, mrb_class_get(M, "PsFx"), 0, nullptr);
          for (int enabled = 0; enabled < 2; ++enabled) {
            ps_enabled = enabled;
            for (const char* name : { "plain", "protected_ok", "protected_raise", "protected_nested", "protected_return",
                                      "framed", "framed_raise" }) {
              ps_log.clear();
              call(M, name, obj, name);
              std::printf("  log: %s\\n", ps_log.c_str());
            }
          }
          return 0;
        }
      CPP
      built, output = Bc2cppFixtureRuntime.run(dir, err, OWNERS, body, build: build, full: true)
      check.call('the fixture builds and runs', built)
      if built
        runs = Bc2cppFixtureRuntime.sections(output)
        strip = ->(lines) { lines.reject { |line| line.start_with?('  dispatches=') } }
        interpreted = strip.call(runs.fetch('interpreted', []))
        compiled = strip.call(runs.fetch('compiled', []))
        check.call('interpreted and compiled runs print the same values and the same begin/end sequences', !interpreted.empty? && interpreted == compiled)
        interpreted.zip(compiled).reject { |a, b| a == b }.first(6).each { |a, b| puts "    interpreted: #{a}\n    compiled:    #{b}" }
        check.call('a raising section begins and never ends, in both runs', interpreted.any? { |l| l == '  log: B ' })
        check.call('a raising frame begins and never ends, in both runs', interpreted.any? { |l| l == '  log: FB ' })
        check.call('a returning protected section ends once under its own name', interpreted.any? { |l| l.include?('B E:ps.protected') })
        warn output unless interpreted == compiled
      else
        warn output.lines.last(15).join
      end
    end
  end
end

if failures.empty?
  puts 'bc2cpp profiler scope check: PASS'
else
  warn "bc2cpp profiler scope check: #{failures.size} failure(s)"
  exit 1
end
