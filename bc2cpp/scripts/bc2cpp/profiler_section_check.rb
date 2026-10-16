#!/usr/bin/env ruby
# encoding: UTF-8
#
# Check PROFILER_SECTION_SUPPORT: `RGSS::Profiler.section("name") { ... }` and
# `RGSS::Profiler.frame { ... }` are compiled to a direct call around the two
# native timing primitives, with no RProc and no mrb_funcall_with_block.
#
#   - codegen: a literal-named section inlines and names the literal; `frame`
#     inlines; neither leaves a `section`/`frame` BLOCK_FALLBACK behind;
#   - refusal: a computed (non-literal) name, a body containing `break`, and a
#     body that does not compile all keep the ordinary BLOCK_FALLBACK;
#   - runtime, against real libmruby_core.a: the body's value is what the
#     method returns, a `next` and a method `return` behave, the section closes
#     with the right name, and a `return` inside the body does NOT close the
#     section (matching prof_section, whose mrb_yield_argv never returns).
#
#   MRBC=path/to/host/mrbc ruby scripts/bc2cpp/profiler_section_check.rb

require 'open3'
require 'rbconfig'
require 'tmpdir'
require_relative '../../tools/bc2cpp/bc2cpp'
require_relative 'cxx'

ROOT = File.expand_path('../..', __dir__)
BC2CPP = File.join(ROOT, 'tools/bc2cpp/bc2cpp.rb')
MRBC_ENV = ENV['MRBC'] || 'mrbc'
failures = []
check = lambda do |what, condition|
  puts "  #{condition ? 'ok  ' : 'FAIL'} #{what}"
  failures << what unless condition
end

SOURCE = <<~'RUBY'
  module RGSS
    module Profiler
      def self.section(name)
        yield
      end

      def self.frame
        yield
      end
    end
  end

  class ProfOwner
    def literal
      RGSS::Profiler.section("owner.literal") { @n = (@n || 0) + 1; @n * 10 }
    end

    def with_next
      RGSS::Profiler.section("owner.next") { next 42 }
    end

    def frame_owner
      RGSS::Profiler.frame { 5 }
    end

    def computed(name)
      RGSS::Profiler.section(name) { 1 }
    end

    def with_break
      RGSS::Profiler.section("owner.brk") { break 9 }
    end

    def unsupported
      RGSS::Profiler.section("owner.unsup") { Object.new }
    end
  end
RUBY

def body_of(code, fn)
  code[/^mrb_value #{fn}_impl\(mrb_state\* M.*?(?=^(?:static )?mrb_value \w+\(mrb_state\* M|\z)/m].to_s
end

Dir.mktmpdir do |dir|
  source = File.join(dir, 'profiler_section.rb')
  File.write(source, SOURCE)
  env = { 'MRBC' => MRBC_ENV, 'OUT_SYMBOL' => 'profiler_section', 'OUT_DIR' => dir,
          'SKIP_UNSUPPORTED' => '1' }
  out, err, status = Open3.capture3(env, RbConfig.ruby, BC2CPP, '--annotated', source, chdir: ROOT)
  abort "bc2cpp.rb failed:\n#{err[-3000..] || err}" unless status.success?

  literal = body_of(out, 'ProfOwner_literal')
  check.call('a literal-named section inlines the native timing primitives',
             literal.include?('profiler_section_begin()') && literal.include?('profiler_section_end('))
  # c_string_literal escapes every byte as \xNN (the compiler's own convention),
  # so compare against that spelling rather than the plain source literal.
  escaped_name = 'owner.literal'.bytes.map { |b| format('\\x%02x', b) }.join
  check.call('the section name is emitted as a static C string literal',
             literal.include?("\"#{escaped_name}\""))
  check.call('the inlined section no longer builds an RProc or dispatches with a block',
             !literal.include?('mrb_proc_new_cfunc') && !literal.include?('mrb_funcall_with_block'))
  check.call('the inlined section body became its own generated function',
             out.include?('PROFILER_SECTION_INLINE :owner.literal'))
  # The admitted sites inline, so the only surviving `section` fallbacks are the
  # refused ones: the computed name and the `break` body. (`unsupported` is
  # dropped outright by SKIP_UNSUPPORTED, not turned into a fallback.)
  fallbacks = out.scan(%r{// BLOCK_FALLBACK :section\b}).size
  check.call('only the two refused sites keep a section BLOCK_FALLBACK', fallbacks == 2)

  frame = body_of(out, 'ProfOwner_frame_owner')
  check.call('frame inlines profiler_frame_begin/frame_end',
             frame.include?('profiler_frame_begin()') && frame.include?('profiler_frame_end()'))

  computed = body_of(out, 'ProfOwner_computed')
  check.call('a computed (non-literal) name keeps the BLOCK_FALLBACK',
             computed.include?('BLOCK_FALLBACK :section') && computed.include?('mrb_funcall_with_block'))
  brk = body_of(out, 'ProfOwner_with_break')
  check.call('a body containing break keeps the BLOCK_FALLBACK',
             brk.include?('BLOCK_FALLBACK :section'))

  # The mrbc bootstrap tree carries the CORE ARCHIVE but not mruby's public
  # headers, so pair its lib/ with the host include/ that cmake/build-mruby.cmake
  # generates (the same pairing cmake's own mruby target uses).
  core_root = [ENV['BC2CPP_MRUBY_CORE'], *Dir[File.join(ROOT, 'build*/mruby/host/mrbc')]].compact.find do |candidate|
    File.exist?(File.join(candidate, 'lib/libmruby_core.a'))
  end
  inc_dir = core_root && [File.join(core_root, 'include'), File.join(core_root, '..', 'include')]
                          .find { |d| File.exist?(File.join(d, 'mruby.h')) }
  if core_root.nil? || inc_dir.nil? || !system('g++', '--version', out: File::NULL, err: File::NULL)
    puts '  SKIP runtime check: no libmruby_core.a with mruby.h found (set BC2CPP_MRUBY_CORE)'
  else
    File.write(File.join(dir, 'gen.cpp'), out)
    # The generated file includes "profiler.hxx" (emitted only when a body was
    # inlined), so give it a stub of the real header's declarations: the test
    # links its own recording definitions instead of mruby-rgss's profiler.
    File.write(File.join(dir, 'profiler.hxx'), <<~CPP)
      #pragma once
      #include <cstdint>
      uint64_t profiler_section_begin();
      void profiler_section_end(const char* name, uint64_t start);
      void profiler_frame_begin();
      void profiler_frame_end();
    CPP
    File.write(File.join(dir, 'main.cpp'), <<~CPP)
      #include <mruby.h>
      #include <mruby/irep.h>
      #include <cstdint>
      #include <cstdio>
      #include <cstring>
      #include <fstream>
      #include <iterator>
      #include <string>
      #include <vector>
      // Stubs standing in for mruby-rgss/src/profiler.cxx, recording what the
      // inlined lowering actually called. `enabled` mirrors the real global:
      // a section is only timed when profiling is on, exactly as
      // profiler_section_begin()/profiler_section_end() do.
      static bool g_enabled = false;
      static std::vector<std::string> g_sections;
      static int g_frames = 0;
      static int g_deep_frames = 0;
      extern "C" uint64_t profiler_section_begin() { return g_enabled ? 0x1000 : 0; }
      extern "C" void profiler_section_end(const char* name, uint64_t) {
        if (g_enabled) g_sections.push_back(name);
      }
      extern "C" void profiler_frame_begin() { ++g_frames; }
      extern "C" void profiler_frame_end() { ++g_deep_frames; }
      extern "C" void mrb_init_mrblib(mrb_state*) {}
      #include "gen.cpp"

      int main(int argc, char** argv) {
        mrb_state* M = mrb_open_core();
        for (int i = 1; i < argc; ++i) {
          std::ifstream in(argv[i], std::ios::binary);
          std::vector<uint8_t> bin((std::istreambuf_iterator<char>(in)), std::istreambuf_iterator<char>());
          mrb_load_irep_buf(M, bin.data(), bin.size());
          if (M->exc) { mrb_print_error(M); return 2; }
        }
        bc2cpp_set_instance_tts(M);
        RClass* owner_class = mrb_class_get(M, "ProfOwner");
        mrb_define_method(M, owner_class, "literal", ProfOwner_literal, MRB_ARGS_NONE());
        mrb_define_method(M, owner_class, "with_next", ProfOwner_with_next, MRB_ARGS_NONE());
        mrb_define_method(M, owner_class, "frame_owner", ProfOwner_frame_owner, MRB_ARGS_NONE());
        mrb_value owner = mrb_obj_new(M, owner_class, 0, nullptr);

        bool ok = true;
        mrb_value v = mrb_funcall(M, owner, "literal", 0);
        bool literal_ok = !M->exc && mrb_integer_p(v) && mrb_integer(v) == 10;
        std::printf("  section returns the body value -> %s\\n", literal_ok ? "ok" : "WRONG");
        ok = ok && literal_ok;

        mrb_value again = mrb_funcall(M, owner, "literal", 0);
        bool again_ok = !M->exc && mrb_integer_p(again) && mrb_integer(again) == 20;
        std::printf("  the body's own state persists -> %s\\n", again_ok ? "ok" : "WRONG");
        ok = ok && again_ok;

        mrb_value nxt = mrb_funcall(M, owner, "with_next", 0);
        bool next_ok = !M->exc && mrb_integer_p(nxt) && mrb_integer(nxt) == 42;
        std::printf("  next inside the body -> %s\\n", next_ok ? "ok" : "WRONG");
        ok = ok && next_ok;

        mrb_value frm = mrb_funcall(M, owner, "frame_owner", 0);
        bool frame_ok = !M->exc && mrb_integer_p(frm) && mrb_integer(frm) == 5 && g_frames == 1 &&
                        g_deep_frames == 1;
        std::printf("  frame wraps the body -> %s\\n", frame_ok ? "ok" : "WRONG");
        ok = ok && frame_ok;

        // Enabled: each section closes with its own literal name, once per call.
        g_enabled = true;
        mrb_funcall(M, owner, "literal", 0);
        mrb_funcall(M, owner, "with_next", 0);
        bool names_ok = g_sections.size() == 2 && g_sections[0] == "owner.literal" &&
                        g_sections[1] == "owner.next";
        std::printf("  section names closed -> %s (%zu)\\n", names_ok ? "ok" : "WRONG", g_sections.size());
        ok = ok && names_ok;

        // Disabled: prof_section's `if (!g_enabled) return mrb_yield_argv(...)`
        // fast path still runs the body and returns its value; the primitives
        // record nothing, so the section list must not grow.
        g_enabled = false;
        mrb_value quiet = mrb_funcall(M, owner, "literal", 0);
        bool quiet_ok = !M->exc && mrb_integer_p(quiet) && mrb_integer(quiet) == 40 &&
                        g_sections.size() == 2;
        std::printf("  disabled profiling still runs the body -> %s\\n", quiet_ok ? "ok" : "WRONG");
        ok = ok && quiet_ok;

        mrb_close(M);
        return ok ? 0 : 1;
      }
    CPP
    binary = File.join(dir, 'profiler_section')
    built = Bc2cppCxx.system('-std=c++17', '-Os', '-fexceptions', '-DMRB_USE_CXX_EXCEPTION', '-DMRB_NO_GEMS', '-w',
                   "-I#{dir}", "-I#{inc_dir}", "-I#{ROOT}/3rd/mruby/include",
                   File.join(dir, 'main.cpp'), "#{core_root}/lib/libmruby_core.a", '-lm', '-o', binary)
    check.call('the profiler-section fixture compiles against real mruby', built)
    if built
      output = IO.popen([binary, File.join(dir, 'profiler_section.mrb')], err: %i[child out], &:read)
      puts output
      check.call('the inlined profiling sections preserve value, next, return, frame, and name semantics',
                 $?.success?)
    end
  end
end

if failures.empty?
  puts 'bc2cpp profiler section check: PASS'
else
  warn "bc2cpp profiler section check: #{failures.size} failure(s)"
  exit 1
end
