#!/usr/bin/env ruby
# encoding: UTF-8
# Check HOT_ONLY (docs/adr/0214): with BC2CPP_HOT_METHODS, bc2cpp compiles only
# the listed methods and an excluded one is exactly a method bc2cpp never
# compiled.
#
#   - wiring: build_config.rb opts the single-format builds in; every compiled
#     gem passes the list through the checked env; BC2CPP_HOT_ONLY=0 turns it off;
#     compiled gems that disagree are refused; the checked-in list parses and
#     names only methods that exist;
#   - generated code, on a fixture world: a list naming every method is
#     byte-identical to no list; an excluded method has no `_impl`, no entry,
#     no declaration; its callers (MONO, singleton, POLY chain, another gem's
#     OTHER_OWNERS run) reach it by name; an ivar it touches is not embedded;
#     a hand-written registration naming it still compiles and does nothing;
#     static-dispatch-only entries are registered again;
#   - run against the real mruby core: the excluded methods run their
#     bytecode, the kept ones run C++, and every answer matches.

require 'open3'
require 'set'
require 'shellwords'
require 'tmpdir'
require_relative '../../tools/bc2cpp/compiled_gems'
require_relative '../../tools/bc2cpp/hot_methods'
require_relative 'cxx'
require_relative '../../tools/bc2cpp/closed_world_env'

root = File.expand_path('../..', __dir__)
failures = []
check = lambda do |what, condition|
  puts "  #{condition ? 'ok  ' : 'FAIL'} #{what}"
  failures << what unless condition
end

# -- wiring ----------------------------------------------------------------------

config = File.read(File.join(root, 'build_config.rb'), encoding: 'UTF-8')
check.call('build_config.rb enables hot-only for the single-format builds only',
           config.include?('closed_world = proc { enable_bc2cpp_hot_only }') &&
             BC2CPP_COMPILED_GEMS.keys.all? { |g| config.include?("#{g}\", &closed_world if bc2cpp") })
check.call('every compiled gem passes the list through the checked env and rebuilds when it changes',
           BC2CPP_COMPILED_GEMS.keys.all? do |g|
             rake = File.read(File.join(root, g, 'mrbgem.rake'))
             rake.include?('extend Bc2cppHotOnlyOption') && rake.include?('Bc2cppCompiledGemGeneration.generate(spec, ') &&
               rake.match?(/BC2CPP_HOT_METHODS_PATH[,\]][^\n]*(?:\n[^\n]*)?do \|t\|/)
           end && File.read(File.join(root, 'tools/bc2cpp/compiled_gems.rb'))[/^def bc2cpp_compiled_gem_job.*?^end$/m]
                      .to_s.include?('.merge(bc2cpp_hot_only_env(spec))'))

spec = Struct.new(:name, :build) { include Bc2cppHotOnlyOption }
build = Struct.new(:name, :gems)
specs = ->(flags) { BC2CPP_COMPILED_GEMS.keys.zip(flags).map { |n, f| spec.new(n, nil).tap { |s| s.enable_bc2cpp_hot_only if f } } }
gem_count = BC2CPP_COMPILED_GEMS.size
open_build = build.new('host', specs.call(Array.new(gem_count, false)))
hot_build = build.new('closed', specs.call(Array.new(gem_count, true)))
mixed = build.new('closed', specs.call([true, false] + Array.new(gem_count - 2, true)))
check.call('a build that did not opt in is not hot-only', !bc2cpp_hot_only_build?(open_build, env: {}))
check.call('an opted-in build is, and passes the list', bc2cpp_hot_only_build?(hot_build, env: {}) &&
           bc2cpp_hot_only_env(spec.new('x', hot_build), env: {}) == { 'BC2CPP_HOT_METHODS' => BC2CPP_HOT_METHODS_PATH })
check.call('BC2CPP_HOT_ONLY=1 does not turn a desktop build hot-only, =0 turns a flash build off',
           !bc2cpp_hot_only_build?(open_build, env: { 'BC2CPP_HOT_ONLY' => '1' }) &&
             !bc2cpp_hot_only_build?(hot_build, env: { 'BC2CPP_HOT_ONLY' => '0' }))
refused = begin
  bc2cpp_hot_only_build?(mixed, env: {})
  false
rescue RuntimeError => e
  e.message.include?('disagree')
end
check.call('compiled gems that disagree are refused (one would call _impls the other never emitted)', refused)

Dir.mktmpdir do |dir|
  list = File.join(dir, 'hot.txt')
  File.write(list, "# comment\n\nFoo#bar\n  Foo::Baz.singleton#[]=   # trailing note\n")
  check.call('the list format: comments, blank lines, trailing notes',
             HotMethods.load(list) == Set['Foo#bar', 'Foo::Baz.singleton#[]='])
  File.write(list, "Foo bar\n")
  bad = begin
    HotMethods.load(list)
    false
  rescue ArgumentError
    true
  end
  check.call('a line that is not one Owner#name entry fails loudly', bad)
end


mrbc = ENV['MRBC'] || 'mrbc'
ENV['MRBC'] = mrbc
require_relative '../../tools/bc2cpp/bc2cpp'

# The checked-in profile names real methods (a rename leaves the method
# excluded, i.e. silently interpreted: regenerate, or rename the entry).
listed = HotMethods.load(HotMethods::DEFAULT_PATH)
stale = Dir.mktmpdir do |dir|
  ireps, root_label = compile_ireps(closed_world_mrblib_srcs(root), 'hot_only_probe', dir)
  HotMethods.stale(build_registry(ireps, root_label).first, listed)
end
check.call("tools/bc2cpp/hot_methods.txt (#{listed.size} methods) names only methods the closed world defines" \
           "#{stale.empty? ? '' : " -- stale: #{stale.first(5).join(', ')}"}", !listed.empty? && stale.empty?)

# -- generated code ---------------------------------------------------------------

WORLD = <<~'RUBY'
  class HoCallee
    def hot(a); a + 1; end
    def cold(a); a * 2; end
    def self.cold_s(a); a - 1; end
  end
  class HoPet
    def ho_speak; 1; end
  end
  class HoRobot
    def ho_speak; 2; end
  end
  class HoCounter
    def initialize; @n = 0; end
    def bump; @n = @n + 1; end
    def peek; @n; end
  end
  class HoCaller
    def call_hot(x); x.hot(1); end
    def call_cold(x); x.cold(1); end
    def call_cold_s; HoCallee.cold_s(3); end
    def talk(x); x.ho_speak; end
    def count(c); c.bump; c.bump; c.peek; end
  end
RUBY
EXCLUDED = %w[HoCallee#cold HoCallee.singleton#cold_s HoRobot#ho_speak HoCounter#peek].freeze

# The generated C++ symbol for each excluded method, derived through the real
# CodeGen#cpp_name rather than written out by hand. `HoCallee.singleton` has a
# `.` in it, so the symbol depends on the mangling in codegen.rb#sanitize;
# hardcoding it here made this check break the moment that mapping changed.
require_relative '../../tools/bc2cpp/codegen'
CPP_NAME = CodeGen.instance_method(:cpp_name).bind(CodeGen.allocate)
EXCLUDED_SYMS = EXCLUDED.map { |k|
  owner, meth = k.split('#', 2)
  CPP_NAME.call(owner, meth)
}.freeze

world_registry = nil
Dir.mktmpdir do |dir|
  path = File.join(dir, 'world.rb')
  File.write(path, WORLD)
  ireps, root_label = compile_ireps(path, 'bc2cpp_hot_world', dir)
  world_registry = [ireps, *build_registry(ireps, root_label)]
end
ireps, registry, superclass_of, _containers, included, prepended, unknown = world_registry
all_keys = registry.values.flatten.select(&:irep).map { |d| HotMethods.key(d) }.uniq

generate = lambda do |list_keys, only: nil, other: nil|
  Dir.mktmpdir do |dir|
    path = File.join(dir, 'world.rb')
    File.write(path, WORLD)
    env = { 'MRBC' => mrbc, 'OUT_SYMBOL' => 'hot_world', 'OUT_DIR' => dir, 'SKIP_UNSUPPORTED' => '1',
            'BC2CPP_SELF_REGISTERING' => '1', 'BC2CPP_HOT_METHODS' => nil }
    env['ONLY_OWNERS'] = only if only
    env['OTHER_OWNERS'] = other if other
    if list_keys
      env['BC2CPP_HOT_METHODS'] = File.join(dir, 'hot.txt')
      File.write(env['BC2CPP_HOT_METHODS'], list_keys.join("\n") + "\n")
    end
    out, err, status = Open3.capture3(bc2cpp_closed_world_probe_env(env), RbConfig.ruby, File.join(root, 'tools/bc2cpp/bc2cpp.rb'), '--annotated', path)
    abort "bc2cpp.rb failed:\n#{err[-3000..] || err}" unless status.success?
    [out, err, File.read(File.join(dir, 'hot_world_decls.h'))]
  end
end
body_of = lambda do |code, fn|
  code[/^mrb_value #{fn}_impl\(mrb_state\* M.*?(?=^(?:static )?mrb_value \w+\(mrb_state\* M|\z)/m].to_s
end
# Whether HoCounter's @n really lives in the RData struct: the final embedding
# (after drop_unsafe_embeddings), not the raw `== ivar embedding ==` sweep.
embedded = lambda do |err, code|
  tt = err[/== classes needing MRB_SET_INSTANCE_TT\(\.\.\., MRB_TT_DATA\) ==\n(.*?)\n\n/m, 1].to_s
  tt.include?('HoCounter') && code.include?('DATA_PTR(self)')
end

plain_code, plain_err, plain_decls = generate.call(nil)
all_code, _, all_decls = generate.call(all_keys)
check.call("a list naming every method (#{all_keys.size}) is byte-identical to no list (code and decls header)",
           plain_code == all_code && plain_decls == all_decls)
check.call('the fixture embeds @n and calls every kept target directly without a list',
           embedded.call(plain_err, plain_code) && plain_code.include?('HoCallee_cold_impl(') &&
             body_of.call(plain_code, 'HoCaller_talk').include?('HoRobot_ho_speak_impl('))

hot_keys = all_keys - EXCLUDED
hot_code, hot_err, hot_decls = generate.call(hot_keys)
check.call('the run reports the exclusion',
           hot_err.include?("== hot-only (BC2CPP_HOT_METHODS): #{hot_keys.size} listed, #{EXCLUDED.size} of"))
excluded_impls_re = Regexp.union(EXCLUDED_SYMS.map { |sym| "#{sym}_impl" })
excluded_syms_re = Regexp.union(EXCLUDED_SYMS)
check.call('an excluded method has no _impl, no entry wrapper, no declaration, no compiled entry',
           !hot_code.match?(excluded_impls_re) &&
             !hot_code.include?("static mrb_value #{EXCLUDED_SYMS[0]}(") &&
             !hot_decls.match?(excluded_syms_re) &&
             EXCLUDED.none? { |k| hot_err[/== compiled entry points ==.*/m].include?("(#{k},") })
check.call('a kept MONO target is still called directly',
           body_of.call(hot_code, 'HoCaller_call_hot').include?('HoCallee_hot_impl('))
check.call('callers reach an excluded method by name: MONO and singleton sends dispatch',
           %w[HoCaller_call_cold HoCaller_call_cold_s].all? do |fn|
             b = body_of.call(hot_code, fn)
             b.include?('bc2cpp_send(') && !b.include?('_impl(M')
           end)
talk = body_of.call(hot_code, 'HoCaller_talk')
check.call('a POLY chain keeps only the kept candidate, with the by-name fallback',
           talk.include?('HoPet_ho_speak_impl(') && !talk.include?('HoRobot') && talk.include?('bc2cpp_send('))
check.call('an ivar an excluded method touches is not embedded (it would read the iv_tbl)',
           !embedded.call(hot_err, hot_code) && hot_code.include?('mrb_iv_get(M, self'))
check.call('a hand-written registration of an excluded entry resolves to the no-op overload',
           hot_code.include?('static inline void mrb_define_method(mrb_state*, struct RClass*, const char*, ' \
                             'bc2cpp_hot_only_excluded, mrb_aspec) {}') &&
             EXCLUDED_SYMS.all? do |e|
               hot_code.include?("[[maybe_unused]] static constexpr bc2cpp_hot_only_excluded #{e}{};")
             end)
check.call('without an exclusion none of that is emitted', !plain_code.include?('bc2cpp_hot_only_excluded'))

# Another compiled gem's run (OTHER_OWNERS) reads the same list: it never
# calls the excluded _impl either.
caller_code, = generate.call(hot_keys, only: 'HoCaller', other: 'HoCallee,HoPet,HoRobot,HoCounter')
check.call("another gem's caller calls the kept _impl across gems and dispatches to the excluded one",
           body_of.call(caller_code, 'HoCaller_call_hot').include?('HoCallee_hot_impl(') &&
             !caller_code.match?(/HoCallee_cold_impl|HoRobot_ho_speak_impl|HoCounter_peek_impl/))

module_copy = MethodDef.new(name: 'mf', owner: 'HoMod.singleton', irep: nil, visibility: :public,
                            kind: :module_function, copy_irep: 'HoMod#mf', copy_owner: 'HoMod')
module_source = MethodDef.new(name: 'mf', owner: 'HoMod', irep: 'HoMod#mf', visibility: :public)
module_hot_registry = { 'mf' => [module_source, module_copy] }
check.call('hot-method validation recognizes a module_function copy as its source body',
           HotMethods.stale(module_hot_registry, Set['HoMod.singleton#mf']).empty? &&
             HotMethods.excluded_labels(module_hot_registry, Set['HoMod.singleton#mf']).empty?)

# STATIC_DISPATCH_UNREGISTRATION is proven over the full compile; with an
# exclusion every such compiled entry is registered again.
gen = CodeGen.new(ireps, registry, {}, {}, {}, {}, superclass_of, {}, {}, {}, {}, Set.new, nil, nil, nil,
                  included, prepended, unknown)
compiled = gen.compile_all
unregistered = Set['HoCallee#hot', 'HoPet#ho_speak']
plain_reg = gen.emit_owner_registrations(compiled, ['HoPet'], unregistered: unregistered)
CodeGen.hot_only_excluded = HotMethods.excluded_labels(registry, hot_keys.to_set)
gen_hot = CodeGen.new(ireps, registry, {}, {}, {}, {}, superclass_of, {}, {}, {}, {}, Set.new, nil, nil, nil,
                      included, prepended, unknown)
compiled_hot = gen_hot.compile_all
hot_reg = gen_hot.emit_owner_registrations(compiled_hot, ['HoPet'], unregistered: unregistered)
CodeGen.hot_only_excluded = nil
check.call('a full build leaves static-dispatch-only entries unregistered',
           !plain_reg.include?(', HoCallee_hot, ') && !plain_reg.include?(', HoPet_ho_speak, ') &&
             plain_reg.include?('HoPet#ho_speak left unregistered'))
check.call('a hot-only build registers them again, wired owner or not',
           hot_reg.include?(', HoCallee_hot, MRB_ARGS_REQ(1));') && hot_reg.include?(', HoPet_ho_speak, MRB_ARGS_NONE());'))
check.call('an excluded method is never registered', !hot_reg.include?('HoCallee_cold'))

# -- run against the real mruby core ------------------------------------------------

candidates = [ENV['BC2CPP_MRUBY_CORE']].compact + Dir[File.join(root, 'build*/mruby/host/mrbc')]
core = candidates.find { |d| File.exist?(File.join(d, 'lib/libmruby_core.a')) && File.directory?(File.join(d, 'include')) }
if core.nil? || !system('g++', '--version', out: File::NULL, err: File::NULL)
  puts '  SKIP behavioural comparison: no libmruby_core.a with include/ found (set BC2CPP_MRUBY_CORE)'
else
  Dir.mktmpdir do |dir|
    File.write(File.join(dir, 'gen.cpp'), hot_code)
    harness = File.join(dir, 'harness.cpp')
    File.write(harness, <<~CPP)
      #include "gen.cpp"
      #include <mruby/compile.h>
      #include <mruby/proc.h>
      #include <cstdio>
      #include <cstdlib>
      extern "C" void mrb_init_mrblib(mrb_state*) {}
      static const char* str(mrb_state* M, mrb_value v) { return mrb_str_to_cstr(M, mrb_inspect(M, v)); }
      static void load(mrb_state* M, const char* ruby) {
        mrb_load_string(M, ruby);
        if (M->exc) { std::printf("uncaught %s\\n", str(M, mrb_obj_value(M->exc))); std::exit(1); }
      }
      static const char* kind(mrb_state* M, const char* klass, const char* meth) {
        mrb_method_t m = mrb_method_search(M, mrb_class_get(M, klass), mrb_intern_cstr(M, meth));
        return MRB_METHOD_CFUNC_P(m) ? "C++" : "bytecode";
      }
      int main() {
        mrb_state* M = mrb_open_core();
        load(M, #{WORLD.inspect});
        // What a hand-written register.cxx does: every method, excluded or not.
        struct RClass* callee = mrb_class_get(M, "HoCallee");
        struct RClass* robot = mrb_class_get(M, "HoRobot");
        struct RClass* pet = mrb_class_get(M, "HoPet");
        struct RClass* counter = mrb_class_get(M, "HoCounter");
        struct RClass* caller = mrb_class_get(M, "HoCaller");
        mrb_define_method(M, callee, "hot", HoCallee_hot, MRB_ARGS_REQ(1));
        mrb_define_method(M, callee, "cold", HoCallee_cold, MRB_ARGS_REQ(1));
        mrb_define_class_method(M, callee, "cold_s", #{EXCLUDED_SYMS[1]}, MRB_ARGS_REQ(1));
        mrb_define_method(M, pet, "ho_speak", HoPet_ho_speak, MRB_ARGS_NONE());
        mrb_define_method(M, robot, "ho_speak", HoRobot_ho_speak, MRB_ARGS_NONE());
        mrb_define_private_method(M, counter, "initialize", HoCounter_initialize, MRB_ARGS_NONE());
        mrb_define_method(M, counter, "bump", HoCounter_bump, MRB_ARGS_NONE());
        mrb_define_method(M, counter, "peek", HoCounter_peek, MRB_ARGS_NONE());
        const char* callers[] = { "call_hot", "call_cold", "call_cold_s", "talk", "count" };
        mrb_func_t fns[] = { HoCaller_call_hot, HoCaller_call_cold, HoCaller_call_cold_s, HoCaller_talk, HoCaller_count };
        mrb_aspec argc[] = { MRB_ARGS_REQ(1), MRB_ARGS_REQ(1), MRB_ARGS_NONE(), MRB_ARGS_REQ(1), MRB_ARGS_REQ(1) };
        for (int i = 0; i < 5; ++i) mrb_define_method(M, caller, callers[i], fns[i], argc[i]);
        std::printf("kinds %s %s %s %s %s\\n", kind(M, "HoCallee", "hot"), kind(M, "HoCallee", "cold"),
                    kind(M, "HoRobot", "ho_speak"), kind(M, "HoCounter", "peek"), kind(M, "HoCounter", "bump"));
        load(M, "c = HoCaller.new; $v = [c.call_hot(HoCallee.new), c.call_cold(HoCallee.new), c.call_cold_s, "
                "c.talk(HoPet.new), c.talk(HoRobot.new), c.count(HoCounter.new), HoCallee.new.cold(5)]");
        std::printf("values %s\\n", str(M, mrb_gv_get(M, mrb_intern_lit(M, "$v"))));
        mrb_close(M);
        return 0;
      }
    CPP
    binary = File.join(dir, 'harness')
    built = Bc2cppCxx.system('-std=c++17', '-w', '-fexceptions', '-DMRB_USE_CXX_EXCEPTION', '-DMRB_NO_GEMS',
                   "-I#{dir}", "-I#{core}/include", "-I#{root}/3rd/mruby/include", harness,
                   "#{core}/lib/libmruby_core.a", '-o', binary)
    check.call('the hot-only code and a hand-written registration of every method compile against real mruby', built)
    if built
      output = IO.popen(binary, err: %i[child out], &:read)
      puts output.lines.map { |l| "  #{l}" }.join
      check.call('excluded methods keep their bytecode, kept ones are C++',
                 output.include?('kinds C++ bytecode bytecode bytecode C++'))
      check.call('every call answers as the interpreter would', output.include?('values [2, 2, 2, 1, 2, 2, 10]'))
    end
  end
end

if failures.empty?
  puts 'bc2cpp hot-only check: PASS'
else
  warn "bc2cpp hot-only check: #{failures.size} failure(s)"
  exit 1
end
