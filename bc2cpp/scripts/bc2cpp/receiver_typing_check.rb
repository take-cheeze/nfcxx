#!/usr/bin/env ruby
# encoding: UTF-8
# Checks the receiver/callee resolutions of docs/adr/0258 in tools/bc2cpp:
#
#   MODULE_SINGLETON_SELF  an implicit-self call inside `def self.x` of a
#       declared module is a direct call under a closed world (which has no
#       exact-class answer for a module).
#   KEYWORDLESS_CALL  a send with no keywords to the one definition of a name
#       that takes keywords is a direct `_impl` call (every keyword "not passed").
#   MODULE_FUNCTION_COPY  a constant-object call to a `module_function` copy
#       whose body has blocks or reads self, but no ivar/cvar/super state.
#   CONSTANT_OBJECT_ACCESSOR  `Const.attr` / `Const.attr = v` on a stable
#       module's singleton attr_accessor is a bare mrb_iv_get / mrb_iv_set.
#
# 1. Fixtures pin each refusal (outside definer, prepend, duplicate def,
#    required keyword, explicit receiver to a private method, ivar state, ...).
# 2. The fixture is generated, compiled against real mruby and run: every call
#    must return what the interpreter would, without a dynamic dispatch. Needs
#    BC2CPP_MRUBY_CORE (libmruby_core.a + include/) and g++; skipped without them.
#
# Usage: MRBC=path/to/mrbc [BC2CPP_MRUBY_CORE=build/mruby/host/mrbc] \
#          ruby scripts/bc2cpp/receiver_typing_check.rb

require 'open3'
require 'shellwords'
require 'tmpdir'
require_relative '../../tools/bc2cpp/bc2cpp'
require_relative '../../tools/bc2cpp/compiled_gems'
require_relative '../../tools/bc2cpp/nomethod_reviewed_probe'
require_relative 'cxx'

ROOT = File.expand_path('../..', __dir__)
BC2CPP = File.join(ROOT, 'tools/bc2cpp/bc2cpp.rb')

failures = []
check = lambda do |what, condition|
  puts "  #{condition ? 'ok  ' : 'FAIL'} #{what}"
  failures << what unless condition
end

WIO_GEMS = NomethodReviewedProbe.wio_gems(ROOT)
OUTSIDE_NATIVE, OUTSIDE_RUBY = bc2cpp_closed_world_outside_srcs('wio', WIO_GEMS, ROOT)

# Compiles `source` under a closed world and yields a lambda returning one
# method's generated body. `embed` marks an owner as embedding ivars.
def fixture(source, name, embed: nil)
  Dir.mktmpdir do |dir|
    path = File.join(dir, "#{name}.rb")
    File.write(path, source)
    ireps, root_label = compile_ireps(path, "bc2cpp_#{name}", dir)
    registry, superclass_of, _containers, included, prepended, unknown, _s, class_decls, walked, _b, _c, modules =
      build_registry(ireps, root_label)
    UniqueClassNames.table = UniqueClassNames.analyze(ireps, root_label, [], [])
    ConstructClassNames.table = ConstructClassNames.analyze(ireps, root_label, UniqueClassNames.table.values)
    world = ClosedWorld.new(ireps: ireps, registry: registry, class_decls: class_decls, walked: walked,
                            native_paths: OUTSIDE_NATIVE, ruby_paths: OUTSIDE_RUBY, module_names: modules)
    gen = CodeGen.new(ireps, registry, {}, {}, {}, {}, superclass_of, {}, {}, {}, {}, Set.new, nil, nil, nil,
                      included, prepended, unknown, closed_world: world)
    gen.instance_variable_get(:@ivar_layout)[embed] = { 'lvl' => :value } if embed
    yield(->(owner, meth) { gen.compile_method(registry.fetch(meth).find { |d| d.owner == owner }.irep).fetch(:code) })
  end
end

# A generated dynamic dispatch, not a marker comment that names mrb_funcall.
DISPATCH = /\bmrb_funcall\w*\(|\bbc2cpp_funcall_(?:explicit|noarg)\(|\bbc2cpp_send\(/

RUNTIME = <<~'RUBY'
  module RtUtil
    def self.rt_term(t, n); "t#{t}#{n}"; end
    def self.rt_act(t, n); rt_term(t, n); end
    def self.rt_twice(n); rt_double(n) + rt_double(1); end
    def self.rt_double(n); n * 2; end
  end

  # Second definitions, so the names are POLY rather than MONO.
  class RtOther
    def rt_term(t, n); "other"; end
    def rt_double(n); 0; end
  end

  class RtActor
    def initialize; @lvl = 1; end
    def rt_set_level(level, preserve: true); @lvl = level; preserve ? level : -level; end
    def rt_reset; rt_set_level(5); end
    def rt_flip(x, y = 2, keep: 1); x + y + keep; end
    def rt_hidden(v, tag: 0); v + tag; end
    private :rt_hidden
    def rt_use_hidden; rt_hidden(4); end
    def rt_need(v, must:); v + must; end
  end

  class RtProbe
    def call_set(a); a.rt_set_level(3); end
    def call_flip(a); a.rt_flip(1); end
    def call_hidden(a); a.rt_hidden(1); end
    def call_act; RtUtil.rt_act("x", 7); end
    def call_twice; RtUtil.rt_twice(5); end
    def call_enc; RtCodec.rt_enc(4); end
    def call_state; RtCodec.rt_state; end
    def call_conf; RtConf.rt_level = 9; RtConf.rt_level; end
  end

  module RtCodec
    def rt_enc(n)
      out = []
      [n, n + 1].each { |x| out << x * 2 }
      out.size + n + (self.equal?(RtCodec) ? 100 : 0)
    end

    def rt_state
      @rt_state = (@rt_state || 0) + 1
    end
    module_function :rt_enc, :rt_state
  end

  module RtConf
    class << self
      attr_accessor :rt_level
    end
  end
RUBY

puts '-- MODULE_SINGLETON_SELF'
fixture(RUNTIME, 'rt_self') do |code_of|
  act = code_of.call('RtUtil.singleton', 'rt_act')
  check.call('an implicit-self call in a module singleton method is a direct call under a closed world',
             act.match?(/LEXICAL_SELF :rt_term -> RtUtil\.singleton#rt_term.*\n\s+r\d+ = RtUtil_singleton_rt_term_impl\(M, self, /) &&
               !act.match?(DISPATCH))
end
[['a prepend onto the singleton', "module Hook; end\nmodule RtPre\n  class << self; prepend Hook; end\n  def self.rt_term(a); a; end\n  def self.rt_act(a); rt_term(a); end\nend\n", 'RtPre'],
 ['a duplicate singleton def', "module RtDup\n  def self.rt_term(a); a; end\n  def self.rt_term(a); a + 1; end\n  def self.rt_act(a); rt_term(a); end\nend\n", 'RtDup'],
 ['an outside definer of the name', "module RtOut\n  def self.puts(a); a; end\n  def self.rt_act(a); puts(a); end\nend\n", 'RtOut'],
 ['a name installed by define_method', "module RtInst\n  def self.rt_term(a); a; end\n  define_singleton_method(:other) { 1 }\n  def self.rt_act(a); rt_term(a); end\nend\n", 'RtInst']].each do |what, source, owner|
  fixture(source, 'rt_self_refused') do |code_of|
    check.call("#{what} keeps the implicit-self call dynamic", !code_of.call("#{owner}.singleton", 'rt_act').include?('LEXICAL_SELF'))
  end
end

puts '-- KEYWORDLESS_CALL'
fixture(RUNTIME, 'rt_kw') do |code_of|
  reset = code_of.call('RtActor', 'rt_reset')
  check.call('an implicit-self send without keywords to a keyword method is a direct call with the keyword not passed',
             reset.match?(/MONO :rt_set_level -> RtActor#rt_set_level \(keyword call\).*\n\s+r\d+ = RtActor_rt_set_level_impl\(M, self, r\d+, mrb_nil_value\(\), 0\)/) &&
               !reset.match?(DISPATCH))
  check.call('an explicit-receiver send to a public keyword method is a direct call',
             code_of.call('RtProbe', 'call_set').include?('RtActor_rt_set_level_impl(M, r'))
  check.call('an optional positional keeps its placeholder and given count',
             code_of.call('RtProbe', 'call_flip').match?(/RtActor_rt_flip_impl\(M, r\d+, r\d+, mrb_nil_value\(\), 0, mrb_nil_value\(\), 0\)/))
  check.call('an implicit-self send to a private keyword method is a direct call',
             code_of.call('RtActor', 'rt_use_hidden').include?('RtActor_rt_hidden_impl'))
  check.call('an explicit receiver never reaches a private keyword method directly',
             !code_of.call('RtProbe', 'call_hidden').include?('RtActor_rt_hidden_impl'))
end
fixture(RUNTIME, 'rt_kw_embed', embed: 'RtActor') do |code_of|
  guarded = code_of.call('RtProbe', 'call_set')
  check.call('an embedding owner keeps a runtime class guard; the closed world proves its else arm a nomethod (ADR 0386)',
             guarded.include?('RtActor_rt_set_level_impl') && guarded.include?('mrb_obj_class(M, r') &&
               guarded.include?('bc2cpp_nomethod_named(M, r') && !guarded.match?(DISPATCH))
  check.call('an implicit self in the embedding owner itself, with no subclass, drops the guard',
             !code_of.call('RtActor', 'rt_reset').include?('mrb_obj_class'))
end
# KEYWORDLESS_FALLBACK kill switch and refusal: the else arm is the old by-name dispatch.
saved_kw = ENV['BC2CPP_KEYWORDLESS_FALLBACK']
ENV['BC2CPP_KEYWORDLESS_FALLBACK'] = '0'
begin
  fixture(RUNTIME, 'rt_kw_embed_off', embed: 'RtActor') do |code_of|
    check.call('BC2CPP_KEYWORDLESS_FALLBACK=0 keeps the dynamic fallback of the embedding guard',
               code_of.call('RtProbe', 'call_set').match?(DISPATCH))
  end
ensure
  ENV['BC2CPP_KEYWORDLESS_FALLBACK'] = saved_kw
end
fixture("#{RUNTIME}class RtGhost\n  def method_missing(n, *a); 1; end\nend\n", 'rt_kw_embed_mm', embed: 'RtActor') do |code_of|
  check.call('a method_missing class keeps the dynamic fallback of the embedding guard',
             code_of.call('RtProbe', 'call_set').match?(DISPATCH))
end
fixture("#{RUNTIME}class RtActor2\n  def rt_need(v, must:); v + must; end\n  def go; rt_need(1); end\nend\n", 'rt_kw_required') do |code_of|
  check.call('a missing required keyword keeps the dynamic call (the interpreter raises ArgumentError)',
             !code_of.call('RtActor2', 'go').include?('RtActor2_rt_need_impl'))
end
fixture("#{RUNTIME}class RtActor3\n  def rt_set_level(l, preserve: true); l; end\nend\n", 'rt_kw_two_defs') do |code_of|
  check.call('a name with two definitions is not resolved by the keywordless path',
             !code_of.call('RtProbe', 'call_set').include?('_rt_set_level_impl'))
end

puts '-- MODULE_FUNCTION_COPY and CONSTANT_OBJECT_ACCESSOR'
fixture(RUNTIME, 'rt_copy') do |code_of|
  enc = code_of.call('RtProbe', 'call_enc')
  check.call('a module_function copy whose body has a block and reads self is a direct call',
             enc.include?('CLOSED_WORLD_CONSTANT_OBJECT :rt_enc') && enc.include?('RtCodec_rt_enc_impl(M, r') &&
               !enc.match?(DISPATCH))
  check.call('a module_function copy whose body reads an ivar keeps dispatch',
             !code_of.call('RtProbe', 'call_state').include?('CLOSED_WORLD_CONSTANT_OBJECT :rt_state'))
  conf = code_of.call('RtProbe', 'call_conf')
  check.call('a singleton attr_accessor on a stable module is a bare ivar access',
             conf.scan('CLOSED_WORLD_CONSTANT_OBJECT :rt_level').size == 2 && conf.include?('mrb_iv_set(M, r') &&
               conf.include?('mrb_iv_get(M, r') && !conf.match?(DISPATCH))
end
fixture("#{RUNTIME}module RtConf\n  def self.rt_level=(v); 1; end\nend\n", 'rt_conf_dup') do |code_of|
  check.call('a second definition of the accessor name keeps the dynamic call',
             !code_of.call('RtProbe', 'call_conf').include?('CLOSED_WORLD_CONSTANT_OBJECT :rt_level= '))
end

# [method, argument class (nil: none), expected, dynamic dispatches allowed];
# each runs on a new RtProbe.
CASES = [
  ['call_act', nil, 'tx7', 0],
  ['call_twice', nil, 12, 0],
  ['call_set', 'RtActor', 3, 0],
  ['call_flip', 'RtActor', 4, 0],
  ['call_enc', nil, 106, 0],
  ['call_conf', nil, 9, 0]
].freeze

puts '-- fixture on real mruby'
core = [ENV['BC2CPP_MRUBY_CORE'], *Dir[File.join(ROOT, 'build*/mruby/host/mrbc')]].compact.find do |dir|
  File.exist?(File.join(dir, 'lib/libmruby_core.a')) && File.directory?(File.join(dir, 'include'))
end
if core.nil? || !system('g++', '--version', out: File::NULL, err: File::NULL)
  puts '  SKIP run: no libmruby_core.a with include/ found (set BC2CPP_MRUBY_CORE)'
else
  Dir.mktmpdir do |dir|
    src = File.join(dir, 'fixture.rb')
    File.write(src, RUNTIME)
    gen = File.join(dir, 'fixture_gen.cpp')
    env = { 'MRBC' => MRBC, 'SKIP_UNSUPPORTED' => '1', 'OUT_SYMBOL' => 'fixture',
            'OUT_DIR' => dir, 'BC2CPP_SELF_REGISTERING' => '1',
            'NATIVE_SRCS' => Shellwords.join(core_native_srcs("#{ROOT}/3rd/mruby")),
            'BC2CPP_CLOSED_WORLD' => '1', 'BC2CPP_BUILD_NAME' => 'wio',
            'BC2CPP_BUILD_GEMS' => Shellwords.join(WIO_GEMS.map { |n, d| "#{n}=#{d}" }),
            NomethodReviewed::ALLOW_ENV => 'allow' }
    _out, err, status = Open3.capture3(env, "#{RbConfig.ruby.shellescape} #{BC2CPP.shellescape} " \
                                            "#{src.shellescape} > #{gen.shellescape}")
    abort "bc2cpp.rb failed:\n#{err[-2000..]}" unless status.success?

    entries = err.split('== compiled entry points ==', 2)[1].to_s.split("\n== ", 2)[0]
                 .scan(%r{^\s+(\w+) / \w+\s+\(([^#]+)#([^,]+), arity \d+\)(.*)$})
    registrations = entries.map do |entry, owner, name, extra|
      klass = "mrb_class_ptr(mrb_const_get(M, mrb_obj_value(M->object_class), mrb_intern_cstr(M, #{owner.delete_suffix('.singleton').dump})))"
      fn = if owner.end_with?('.singleton') then 'mrb_define_class_method'
           elsif extra.include?('[private') then 'mrb_define_private_method'
           else 'mrb_define_method'
           end
      "  #{fn}(M, #{klass}, #{name.dump}, #{entry}, MRB_ARGS_ANY());"
    end
    calls = CASES.map do |meth, arg_class, want, allowed|
      want_expr = want.is_a?(String) ? "mrb_str_new_cstr(M, #{want.dump})" : "mrb_fixnum_value(#{want})"
      arg = arg_class ? "mrb_obj_new(M, mrb_class_get(M, #{arg_class.dump}), 0, nullptr)" : 'mrb_nil_value()'
      "  expect(M, #{meth.dump}, #{arg}, #{arg_class ? 1 : 0}, #{want_expr}, #{allowed}, #{meth.dump});"
    end
    File.write(File.join(dir, 'main.cpp'), <<~CPP)
      #include <mruby.h>
      static int fallbacks = 0;
      // Count every dynamic dispatch the compiled bodies make.
      #define mrb_funcall_id(M, ...) (++fallbacks, (mrb_funcall_id)(M, __VA_ARGS__))
      #define mrb_funcall(M, ...) (++fallbacks, (mrb_funcall)(M, __VA_ARGS__))
      #include "fixture_gen.cpp"
      #include <mruby/irep.h>
      #include <mruby/string.h>
      #include <cstdio>
      #include <fstream>
      #include <iterator>
      #include <vector>
      extern "C" void mrb_init_mrblib(mrb_state*) {}
      static int failed = 0;
      static void expect(mrb_state* M, const char* meth, mrb_value arg, int argc, mrb_value want, int allowed, const char* what) {
        mrb_value probe = mrb_obj_new(M, mrb_class_get(M, "RtProbe"), 0, nullptr);
        fallbacks = 0;
        mrb_value got = (mrb_funcall)(M, probe, meth, argc, arg);
        if (M->exc) { mrb_print_error(M); std::printf("  %s -> raised\\n", what); M->exc = nullptr; ++failed; return; }
        bool ok = mrb_equal(M, got, want) && fallbacks <= allowed;
        std::printf("  %s -> %s (%d dynamic dispatch, %d allowed)\\n", what, ok ? "ok" : "WRONG", fallbacks, allowed);
        failed += !ok;
      }
      int main(int, char** argv) {
        mrb_state* M = mrb_open_core();
        std::ifstream in(argv[1], std::ios::binary);
        std::vector<uint8_t> bin((std::istreambuf_iterator<char>(in)), std::istreambuf_iterator<char>());
        mrb_load_irep_buf(M, bin.data(), bin.size());
        if (M->exc) { mrb_print_error(M); return 2; }
        bc2cpp_set_instance_tts(M);
      #{registrations.join("\n")}
      #{calls.join("\n")}
        mrb_close(M);
        return failed ? 1 : 0;
      }
    CPP
    binary = File.join(dir, 'fixture')
    built = Bc2cppCxx.system('-std=c++17', '-fexceptions', '-DMRB_USE_CXX_EXCEPTION', '-DMRB_NO_GEMS', '-w',
                   "-I#{dir}", "-I#{core}/include", "-I#{ROOT}/3rd/mruby/include", "-I#{ROOT}/mruby-rgss/src",
                   File.join(dir, 'main.cpp'), "#{core}/lib/libmruby_core.a", '-lm', '-o', binary)
    check.call('the receiver typing fixture compiles against real mruby', built)
    if built
      output = IO.popen([binary, File.join(dir, 'fixture.mrb')], err: %i[child out], &:read)
      puts output
      check.call("every call returns the interpreter's answer without a dynamic dispatch", $?.success?)
    end
  end
end

if failures.empty?
  puts 'bc2cpp receiver typing check: PASS'
else
  warn "bc2cpp receiver typing check: #{failures.size} failure(s)"
  exit 1
end
