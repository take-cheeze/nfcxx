#!/usr/bin/env ruby
# encoding: UTF-8
# Checks POLY_TABLE (docs/adr/0227): a POLY name with more candidates than
# POLY_SMALL_N_MAX dispatches through one shared {owner class, `_impl`} table
# instead of a plain mrb_funcall.
#
# 1. Generated code, on a fixture world: past the cap every site of the name
#    shares one table, lists each candidate plus its INHERITED_GUARD subclass,
#    leaves the attr_reader owner and the module's singleton def to the fallback,
#    and keeps the by-name fallback; at the cap the name is still a POLY_SMALL_N
#    chain; a world with no name past the cap emits nothing of the tier.
# 2. The fixture is compiled against real mruby and each call made twice, in
#    two VMs one after the other: every call returns what the interpreter
#    would, a table hit makes no dynamic dispatch and every other receiver
#    (accessor owner, module, a class defined outside the closed world) makes
#    exactly one, from the scan and from the memo alike. Needs BC2CPP_MRUBY_CORE (libmruby_core.a +
#    include/) and g++; skipped without them.
#
# Usage: MRBC=path/to/mrbc [BC2CPP_MRUBY_CORE=build/mruby/host/mrbc] \
#          ruby scripts/bc2cpp/poly_table_check.rb

require 'open3'
require 'shellwords'
require 'tmpdir'
require_relative '../../tools/bc2cpp/bc2cpp'
require_relative '../../tools/bc2cpp/compiled_gems'
require_relative 'cxx'

ROOT = File.expand_path('../..', __dir__)
BC2CPP = File.join(ROOT, 'tools/bc2cpp/bc2cpp.rb')
CAP = CodeGen::POLY_SMALL_N_MAX

failures = []
check = lambda do |what, condition|
  puts "  #{condition ? 'ok  ' : 'FAIL'} #{what}"
  failures << what unless condition
end

# pt_tick: CAP + 1 compiled defs (K0..K<CAP>), an attr_reader (Acc) and a
# module singleton def (Clock); Sub inherits K3's. pt_tock: exactly CAP defs.
over = (0..CAP).map { |i| "class K#{i}\n  def pt_tick; \"k#{i}\"; end\n#{i < CAP ? "  def pt_tock; \"t#{i}\"; end\n" : ''}end\n" }
WORLD = <<~RUBY
  #{over.join}
  class Sub < K3; end

  class Acc
    attr_reader :pt_tick
    def initialize; @pt_tick = "acc"; end
  end

  module Clock
    def self.pt_tick; "clock"; end
  end

  class Probe
    def run_tick(x); x.pt_tick; end
    def run_tick_again(x); x.pt_tick; end
    def run_tock(x); x.pt_tock; end
  end
RUBY

UNDER_CAP = <<~RUBY
  #{(0...CAP).map { |i| "class U#{i}\n  def pt_tock; #{i}; end\nend\n" }.join}
  class Probe
    def run_tock(x); x.pt_tock; end
  end
RUBY

# The exact-class RGSS wrapper arms (dispose, zero-argument natives) end in the
# chain or table for the Ruby definers, not in a plain dispatch.
WRAPPED = <<~RUBY
  #{(0..CAP).map { |i| "class W#{i}\n  def dispose; #{i}; end\nend\n" }.join}
  class WProbe
    def go(x); x.dispose; end
  end
RUBY

def generate(source, dir, native: false, rgss: false)
  src = File.join(dir, 'fixture.rb')
  File.write(src, source)
  gen = File.join(dir, 'fixture_gen.cpp')
  env = { 'MRBC' => MRBC, 'SKIP_UNSUPPORTED' => '1', 'OUT_SYMBOL' => 'fixture', 'OUT_DIR' => dir,
          'BC2CPP_SELF_REGISTERING' => '1', 'BC2CPP_HOT_METHODS' => nil }
  env['NATIVE_SRCS'] = Shellwords.join(core_native_srcs("#{ROOT}/3rd/mruby") + (rgss ? Dir["#{ROOT}/mruby-rgss/src/*.cxx"] : [])) if native
  _out, err, status = Open3.capture3(env, "#{RbConfig.ruby.shellescape} #{BC2CPP.shellescape} " \
                                          "#{src.shellescape} > #{gen.shellescape}")
  abort "bc2cpp.rb failed:\n#{err[-2000..] || err}" unless status.success?
  [File.read(gen), err]
end

def body_of(code, fn)
  code[/^mrb_value #{fn}_impl\(mrb_state\* M.*?(?=^(?:static )?mrb_value \w+\(mrb_state\* M|\z)/m].to_s
end

puts '-- generated code'
Dir.mktmpdir do |dir|
  code, err = generate(WORLD, dir)
  tick = body_of(code, 'Probe_run_tick')
  table = tick[/bc2cpp_poly_lookup\(M, mrb_obj_class\(M, r\d+\), (bc2cpp_poly_table_\d+)\)\) \{/, 1]
  rows = code[/^static const bc2cpp_poly_entry #{table}_rows\[\] = \{\n(.*?)^\};/m, 1].to_s.lines
  check.call("a name with #{CAP + 1} compiled defs dispatches through a table", !table.nil?)
  check.call('a table hit calls the _impl it found, anything else takes the by-name fallback',
             tick.match?(/r\d+ = reinterpret_cast<mrb_value \(\*\)\(mrb_state\*, mrb_value\)>\(bc2cpp_pfn\)\(M, r\d+\);\n\s+\} else \{\n\s+r\d+ = bc2cpp_send\(M, r\d+, \d+, 0\);/))
  check.call("the table lists every compiled def and Sub under K3's _impl (#{CAP + 2} rows)",
             rows.size == CAP + 2 && (0..CAP).all? { |i| rows.any? { |r| r.match?(/\(K#{i}_pt_tick_impl\), \d+\},  \/\/ K#{i}\n/) } } &&
               rows.any? { |r| r.match?(%r{\(K3_pt_tick_impl\), \d+\},  // Sub}) } &&
               tick.include?("(#{CAP + 1} known real definitions, #{CAP + 2} classes)"))
  check.call('the attr_reader owner and the module singleton reach the fallback, not a row',
             rows.none? { |r| r.include?('Acc') || r.include?('Clock') })
  check.call('every site of the name shares that one table, emitted once ahead of them',
             body_of(code, 'Probe_run_tick_again').include?("#{table})) {") &&
               code.scan(/^static const bc2cpp_poly_entry /).size == 1 &&
               code.scan(/^\[\[gnu::noinline\]\] static bc2cpp_poly_fn bc2cpp_poly_lookup\(/).size == 1 &&
               code.include?("static const bc2cpp_poly_table #{table} = {#{table}_rows, #{CAP + 2}, " \
                             'bc2cpp_poly_memos + 0};') &&
               code.index("#{table}_rows[] = {") < code.index('mrb_value Probe_run_tick_impl(mrb_state* M'))
  check.call('its memo is cleared with OWNER_CLASS_CACHE (a later VM can reuse the addresses)',
             code.include?('static bc2cpp_poly_memo bc2cpp_poly_memos[8];') &&
               code.match?(/static void bc2cpp_reset_owner_classes\(\) \{\n.*\n.*\n  for \(bc2cpp_poly_memo& m : bc2cpp_poly_memos\) m = \{\};\n\}/))
  check.call('the stderr summary counts its sites',
             err.include?("== poly table dispatch: pt_tick (#{table}, #{CAP + 2} classes) 2 sites =="))
  tock = body_of(code, 'Probe_run_tock')
  check.call("a name with exactly #{CAP} defs stays a POLY_SMALL_N chain",
             tock.include?("// POLY_SMALL_N :pt_tock -> ") && !tock.include?('bc2cpp_poly'))
end
Dir.mktmpdir do |dir|
  code, err = generate(UNDER_CAP, dir)
  check.call('a world with no name past the cap emits nothing of the tier',
             !code.include?('bc2cpp_poly') && !code.include?('POLY_TABLE') &&
               err.include?('== poly table dispatch: none sites ==') && !code.include?('bc2cpp_poly_memo'))
end

puts '-- RGSS wrapper sites past the chain cap'
Dir.mktmpdir do |dir|
  code, = generate(WRAPPED, dir, native: true, rgss: true)
  go = body_of(code, 'WProbe_go')
  check.call('the RGSS #dispose arms are kept', go.include?('// RGSS #dispose'))
  check.call("#{CAP + 1} Ruby definers behind them dispatch through a table, not a plain send",
             go.include?('POLY_TABLE :dispose') && go.include?('bc2cpp_poly_lookup('))
end

# [Probe method, argument C expression, expected string, dynamic dispatches]
CASES = [
  ['run_tick', 'K0', 'k0', 0],
  ['run_tick', "K#{CAP}", "k#{CAP}", 0],
  ['run_tick', 'K7', 'k7', 0],
  ['run_tick', 'Sub', 'k3', 0],
  ['run_tick_again', 'K9', 'k9', 0],
  ['run_tick', 'Acc', 'acc', 1],
  ['run_tick', :Clock, 'clock', 1],
  ['run_tick', :Foreign, 'foreign', 1],
  ['run_tock', "K#{CAP - 1}", "t#{CAP - 1}", 0]
].freeze

puts '-- fixture on real mruby'
core = [ENV['BC2CPP_MRUBY_CORE'], *Dir[File.join(ROOT, 'build*/mruby/host/mrbc')]].compact.find do |dir|
  File.exist?(File.join(dir, 'lib/libmruby_core.a')) && File.directory?(File.join(dir, 'include'))
end
if core.nil? || !system('g++', '--version', out: File::NULL, err: File::NULL)
  puts '  SKIP run: no libmruby_core.a with include/ found (set BC2CPP_MRUBY_CORE)'
else
  Dir.mktmpdir do |dir|
    _code, err = generate(WORLD, dir, native: true)
    entries = err.split('== compiled entry points ==', 2)[1].to_s.split("\n== ", 2)[0]
                 .scan(%r{^\s+(\w+) / \w+\s+\(([^#]+)#([^,]+), arity \d+\)(.*)$})
    registrations = entries.map do |entry, owner, name, extra|
      holder = owner.delete_suffix('.singleton')
      klass = "mrb_class_ptr(mrb_const_get(M, mrb_obj_value(M->object_class), mrb_intern_cstr(M, #{holder.dump})))"
      fn = if owner.end_with?('.singleton') then 'mrb_define_class_method'
           elsif extra.include?('[private') then 'mrb_define_private_method'
           else 'mrb_define_method'
           end
      "  #{fn}(M, #{klass}, #{name.dump}, #{entry}, MRB_ARGS_ANY());"
    end
    calls = CASES.map do |meth, recv, want, dispatches|
      arg = case recv
            when :Clock then 'mrb_obj_value(mrb_module_get(M, "Clock"))'
            when :Foreign then 'mrb_obj_new(M, foreign, 0, nullptr)'
            else "mrb_obj_new(M, mrb_class_get(M, #{recv.dump}), 0, nullptr)"
            end
      "  expect(M, #{meth.dump}, #{arg}, #{want.dump}, #{dispatches}, #{"#{meth}(#{recv})".dump});"
    end
    File.write(File.join(dir, 'main.cpp'), <<~CPP)
      #include <mruby.h>
      static int dispatches = 0;
      // Count every dynamic dispatch the compiled bodies make.
      #define mrb_funcall_argv(M, ...) (++dispatches, (mrb_funcall_argv)(M, __VA_ARGS__))
      #define mrb_funcall_id(M, ...) (++dispatches, (mrb_funcall_id)(M, __VA_ARGS__))
      #define mrb_funcall(M, ...) (++dispatches, (mrb_funcall)(M, __VA_ARGS__))
      #include "fixture_gen.cpp"
      #include <mruby/irep.h>
      #include <mruby/string.h>
      #include <cstdio>
      #include <fstream>
      #include <iterator>
      #include <vector>
      extern "C" void mrb_init_mrblib(mrb_state*) {}
      static int failed = 0;
      static mrb_value foreign_tick(mrb_state* M, mrb_value) { return mrb_str_new_cstr(M, "foreign"); }
      static void expect(mrb_state* M, const char* meth, mrb_value arg, const char* want, int want_dispatches, const char* what) {
        mrb_value probe = mrb_obj_new(M, mrb_class_get(M, "Probe"), 0, nullptr);
        dispatches = 0;
        mrb_value got = (mrb_funcall)(M, probe, meth, 1, arg);
        if (M->exc) { std::printf("  %s -> raised\\n", what); M->exc = nullptr; ++failed; return; }
        mrb_value again = (mrb_funcall)(M, probe, meth, 1, arg);
        bool ok = !M->exc && mrb_equal(M, got, mrb_str_new_cstr(M, want)) && mrb_equal(M, again, got) &&
                  dispatches == 2 * want_dispatches;
        std::printf("  %s -> %s (%d dynamic dispatch over two calls, want %d)\\n", what, ok ? "ok" : "WRONG",
                    dispatches, 2 * want_dispatches);
        failed += !ok;
        M->exc = nullptr;
      }
      static int run(const std::vector<uint8_t>& bin) {
        mrb_state* M = mrb_open_core();
        mrb_load_irep_buf(M, bin.data(), bin.size());
        if (M->exc) { mrb_print_error(M); return 2; }
        bc2cpp_set_instance_tts(M);
      #{registrations.join("\n")}
        // A class outside the closed world that answers the name.
        struct RClass* foreign = mrb_define_class(M, "Foreign", M->object_class);
        mrb_define_method(M, foreign, "pt_tick", foreign_tick, MRB_ARGS_NONE());
      #{calls.join("\n")}
        mrb_close(M);
        // What each compiled gem's gem_final does.
        bc2cpp_reset_owner_classes();
        return 0;
      }
      int main(int, char** argv) {
        std::ifstream in(argv[1], std::ios::binary);
        std::vector<uint8_t> bin((std::istreambuf_iterator<char>(in)), std::istreambuf_iterator<char>());
        for (int vm = 1; vm <= 2; ++vm) {
          std::printf("  VM %d\\n", vm);
          if (int rc = run(bin)) return rc;
        }
        return failed ? 1 : 0;
      }
    CPP
    binary = File.join(dir, 'fixture')
    built = Bc2cppCxx.system('-std=c++17', '-fexceptions', '-DMRB_USE_CXX_EXCEPTION', '-DMRB_NO_GEMS', '-w',
                   "-I#{dir}", "-I#{core}/include", "-I#{ROOT}/3rd/mruby/include", "-I#{ROOT}/mruby-rgss/src",
                   File.join(dir, 'main.cpp'), "#{core}/lib/libmruby_core.a", '-lm', '-o', binary)
    check.call('the fixture compiles against real mruby', built)
    if built
      output = IO.popen([binary, File.join(dir, 'fixture.mrb')], err: %i[child out], &:read)
      puts output
      check.call('every call returns the interpreter\'s answer; only a table miss dispatches', $?.success?)
    end
  end
end

if failures.empty?
  puts 'bc2cpp poly table check: PASS'
else
  warn "bc2cpp poly table check: #{failures.size} failure(s)"
  exit 1
end
