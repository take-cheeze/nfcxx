#!/usr/bin/env ruby
# encoding: UTF-8
# frozen_string_literal: true

# Check the dynamic sends bc2cpp removes with proofs instead of dispatch (docs/adr/0274):
#
#   KERNEL_DIRECT           implicit-self `raise` (one or two arguments) and `__id__`
#   BLOCK_PARAM_CALL        `blk.call(...)` on a method's own `&blk` in compiled core Ruby
#   NATIVE_CORE_DIRECT_REST an audited Array native on the method's or block's own `*rest`
#
# 1. the audit: every row verifies against the mruby sources, and a changed body, header,
#    registration or a second spelling of the name drops the row;
# 2. generated code: what is taken and every reason it is withheld (open world, a Ruby
#    definition, a BasicObject class, a dynamic installer, a rewritten parameter, ...);
# 3. behaviour: the fixture compiled against real mruby prints what the interpreter prints
#    (results, exception classes and messages), and the KERNEL_DIRECT sites make no dispatch.
#    Needs BC2CPP_MRUBY_CORE (libmruby_core.a) for the Kernel half and BC2CPP_MRUBY_FULL
#    (libmruby.a with the full-core gems) for the core half; each is skipped without its build.
#
# Usage: MRBC=path/to/mrbc [BC2CPP_MRUBY_CORE=dir] [BC2CPP_MRUBY_FULL=dir] \
#          ruby scripts/bc2cpp/direct_natives_check.rb

require 'fileutils'
require 'shellwords'
require 'tmpdir'
require_relative 'fixture_runtime'
require_relative '../../tools/bc2cpp/compiled_gems'
require_relative '../../tools/bc2cpp/native_core_direct'

ROOT = File.expand_path('../..', __dir__)
runtime = Bc2cppFixtureRuntime

failures = []
check = lambda do |what, condition|
  puts "  #{condition ? 'ok  ' : 'FAIL'} #{what}"
  failures << what unless condition
end

mruby_dir = File.join(ROOT, '3rd/mruby')
native_srcs = Dir[File.join(ROOT, 'mruby-rgss/src/*.cxx')] + core_native_srcs(mruby_dir) + external_gem_native_srcs(ROOT)
kernel_entries = NativeCoreDirect::KERNEL_ENTRIES
rest_entries = NativeCoreDirect::ENTRIES.select { |entry| %w[__svalue to_a].include?(entry.name) }

# -- the audit --------------------------------------------------------------------

audit = NativeCoreDirect.audit(native_srcs)
(kernel_entries + rest_entries).each do |entry|
  check.call("#{entry.owner}##{entry.name}/#{entry.arity} verifies against the mruby sources (#{audit[entry] || 'ok'})",
             audit[entry].nil?)
end
check.call('raise is admitted at one and two arguments only',
           kernel_entries.select { |entry| entry.name == 'raise' }.map(&:arity).sort == [1, 2])
kernel_entries.each do |entry|
  next unless entry.helper

  check.call("#{entry.helper} has helper text and the expression calls it",
             NativeCoreDirect::HELPERS.key?(entry.helper) && entry.expression.include?("#{entry.helper}("))
end

Dir.mktmpdir do |dir|
  fake = File.join(dir, '3rd/mruby')
  FileUtils.mkdir_p(File.join(fake, 'src'))
  FileUtils.cp_r(File.join(mruby_dir, 'include'), File.join(fake, 'include'))
  files = %w[kernel.c class.c array.c].to_h { |name| [name, File.join(fake, 'src', name)] }
  originals = files.to_h { |name, _| [name, File.read(File.join(mruby_dir, 'src', name))] }
  restore = -> { files.each { |name, path| File.write(path, originals.fetch(name)) } }
  other = File.join(fake, 'src/other.c')
  paths = files.values + [other]
  raise1 = kernel_entries.find { |entry| entry.name == 'raise' && entry.arity == 1 }
  raise2 = kernel_entries.find { |entry| entry.name == 'raise' && entry.arity == 2 }
  object_id = kernel_entries.find { |entry| entry.name == '__id__' }
  svalue = rest_entries.find { |entry| entry.name == '__svalue' }
  to_a = rest_entries.find { |entry| entry.name == 'to_a' }
  failed = ->(entry, text) { NativeCoreDirect.audit(paths)[entry].to_s.include?(text) }
  dropped = ->(entry) { !NativeCoreDirect.audit(paths)[entry].nil? }

  restore.call
  check.call('a copy of the sources verifies every row',
             [raise1, raise2, object_id, svalue, to_a].all? { |entry| NativeCoreDirect.audit(paths)[entry].nil? })

  File.write(files['kernel.c'], originals['kernel.c'].sub('mrb_make_exception(mrb, exc, mesg)', 'mrb_make_exception(mrb, mesg, exc)'))
  check.call('a changed mrb_f_raise arm drops both raise rows',
             failed.call(raise1, 'no longer matches') && failed.call(raise2, 'no longer matches'))
  restore.call
  File.write(files['kernel.c'], originals['kernel.c'].sub('mrb->c->ci->mid = 0;', ''))
  check.call('a dropped `ci->mid = 0` (the raise frame stays in the backtrace) drops the raise rows',
             failed.call(raise2, 'no longer matches'))
  restore.call
  File.write(files['kernel.c'], originals['kernel.c'].sub('return mrb_fixnum_value(mrb_obj_id(self));', 'return mrb_nil_value();'))
  check.call('a changed mrb_obj_id_m drops __id__ and leaves raise', failed.call(object_id, 'no longer matches') && !failed.call(raise1, 'matches'))
  restore.call
  File.write(files['class.c'], originals['class.c'].sub(/^\s*MRB_MT_ENTRY\(mrb_obj_id_m,[^\n]*\n/, ''))
  check.call('a class.c that no longer registers __id__ drops it', failed.call(object_id, 'found 0'))
  restore.call
  File.write(other, 'void f(mrb_state* mrb) { mrb_define_method_id(mrb, mrb->string_class, MRB_SYM(raise), g, MRB_ARGS_NONE()); }')
  check.call('a registration of raise on another class drops the raise rows (any receiver reaches it)',
             dropped.call(raise1) && dropped.call(raise2) && !dropped.call(object_id))
  File.write(other, 'void f(mrb_state* mrb, RClass* k) { mrb_define_method_id(mrb, k, MRB_SYM(raise), g, MRB_ARGS_NONE()); }')
  check.call('an unattributable registration of raise drops the raise rows', dropped.call(raise2))
  File.write(other, 'void f(mrb_state* mrb) { mrb_define_method_id(mrb, mrb->string_class, MRB_SYM(__id__), g, MRB_ARGS_NONE()); }')
  check.call('a second __id__ drops __id__ and leaves raise', dropped.call(object_id) && !dropped.call(raise1))
  FileUtils.rm_f(other)
  File.write(files['array.c'], originals['array.c'].sub('return RARRAY_PTR(ary)[0];', 'return RARRAY_PTR(ary)[1];'))
  check.call('a changed mrb_ary_svalue drops __svalue', failed.call(svalue, 'no longer matches'))
  restore.call
  File.write(files['array.c'], originals['array.c'].sub('return mrb_ary_dup(mrb, self);', 'return self;'))
  check.call('a changed mrb_ary_to_a drops to_a', failed.call(to_a, 'no longer matches'))
  restore.call
  internal = File.join(fake, 'include/mruby/internal.h')
  File.write(internal, File.read(internal).sub(/^mrb_value mrb_make_exception[^\n]*\n/, ''))
  check.call('an internal.h without mrb_make_exception drops the raise rows',
             failed.call(raise1, 'is not declared') && !failed.call(object_id, 'is not declared'))
end

# -- generated code: Kernel ---------------------------------------------------------

unless system(runtime.mrbc, '--version', out: File::NULL, err: File::NULL)
  puts '  SKIP generated code and behaviour: needs MRBC'
  puts "\n#{failures.size} check(s) failed" unless failures.empty?
  exit(failures.empty? ? 0 : 1)
end

KERNEL_WORLD = <<~'RUBY'
  class KdFx
    def r1(a); raise a; end
    def r2(a, b); raise a, b; end
    def rs; raise "boom"; end
    def r3(a, b, c); raise a, b, c; end
    def r0; raise; end
    def rk(a); raise a, cause: nil; end
    def rx(o); o.raise "x"; end
    def oid; __id__; end
  end
RUBY

generate = lambda do |source, closed: true, path: 'fixture.rb', extra: nil|
  Dir.mktmpdir do |dir|
    runtime.generate(source, dir, closed: closed, path: path, extra: extra ? [['engine.rb', extra]] : []).first
  end
end
body_of = lambda do |code, klass, fn|
  code[/^mrb_value #{klass}_#{fn}_impl\(mrb_state\* M.*?(?=^(?:static )?mrb_value \w+\(mrb_state\* M|\z)/m].to_s
end
kd = ->(code, fn) { body_of.call(code, 'KdFx', fn) }

closed = generate.call(KERNEL_WORLD)
check.call('raise with one argument calls bc2cpp_raise1 and makes no send',
           kd.call(closed, 'r1').match?(/KERNEL_DIRECT :raise.*\n\s+r\d+ = bc2cpp_raise1\(M, r\d+\);/) && !kd.call(closed, 'r1').include?('bc2cpp_send('))
check.call('raise with a message calls bc2cpp_raise2', kd.call(closed, 'r2').match?(/r\d+ = bc2cpp_raise2\(M, r\d+, r\d+\);/))
check.call('raise "msg" is the one-argument arm', kd.call(closed, 'rs').include?('bc2cpp_raise1('))
check.call('a bare raise (re-raises $!), a third argument, a cause: keyword and an explicit receiver keep their send',
           %w[r0 r3 rk rx].none? { |fn| kd.call(closed, fn).include?('KERNEL_DIRECT') } &&
             kd.call(closed, 'r3').include?('bc2cpp_send('))
check.call('__id__ is mrb_obj_id under the same proof', kd.call(closed, 'oid').match?(/r\d+ = mrb_fixnum_value\(mrb_obj_id\(self\)\);/))
check.call('the helpers are defined once each',
           %w[bc2cpp_raise1 bc2cpp_raise2].all? { |helper| closed.scan(/^static inline mrb_value #{helper}\(/).size == 1 })
check.call('the internal.h declaration is extern "C"', closed.include?('extern "C" mrb_value mrb_make_exception(mrb_state*, mrb_value, mrb_value);'))

check.call('without the closed world no site is taken', !generate.call(KERNEL_WORLD, closed: false).include?('KERNEL_DIRECT'))
{
  'a Ruby raise on the class' => "#{KERNEL_WORLD}\nclass KdFx\n  def raise(*a); 1; end\nend\n",
  'a Ruby raise on Object' => "#{KERNEL_WORLD}\nclass Object\n  def raise(*a); 1; end\nend\n",
  'a Ruby raise in a module' => "#{KERNEL_WORLD}\nmodule KdMod\n  def raise(*a); 1; end\nend\nclass KdFx\n  include KdMod\nend\n",
  'a singleton raise' => "#{KERNEL_WORLD}\nclass KdFx\n  def self.raise(*a); 1; end\nend\n",
  'a class below BasicObject (no Kernel)' => "#{KERNEL_WORLD}\nclass KdBare < BasicObject\nend\n",
  'a dynamic installer' => "#{KERNEL_WORLD}\nclass KdFx\n  def install(n); Object.send(:define_method, n) { 1 }; end\nend\n"
}.each do |what, source|
  check.call("#{what} withdraws raise", !generate.call(source).include?('bc2cpp_raise1('))
end
check.call('a Ruby __id__ withdraws __id__ and leaves raise',
           (code = generate.call("#{KERNEL_WORLD}\nclass KdFx\n  def __id__; 1; end\nend\n")) &&
             !code.include?('mrb_obj_id(') && code.include?('bc2cpp_raise1('))

# -- behaviour: Kernel ----------------------------------------------------------------

BEHAVIOUR = <<~'RUBY'
  class KdError < StandardError
    def initialize(m = "kd default"); super; end
  end
  class KdBadNew
    def self.new(*a); 42; end
  end
  class KdBare; end

  class KdFx
    def r1(a); raise a; end
    def r2(a, b); raise a, b; end
    def rs; raise "boom"; end
    def r3(a, b, c); raise a, b, c; end
    def oid; [__id__ == object_id, __id__.class]; end
    def rescued(a)
      begin
        raise a
      rescue Exception => e
        [e.class, e.message, e.equal?(a)]
      end
    end
    def rescued2(a, b)
      begin
        raise a, b
      rescue Exception => e
        [e.class, e.message, e.equal?(a)]
      end
    end
    def ensured(a)
      log = []
      begin
        begin
          raise a
        ensure
          log << :ensure
        end
      rescue Exception => e
        log << e.class
      end
      log
    end
  end
RUBY

if runtime.core && runtime.compiler?
  dir = Dir.mktmpdir('bc2cpp_direct_natives')
  code, err = runtime.generate(BEHAVIOUR, dir)
  check.call('the behaviour fixture compiles its raise sites directly',
             kd.call(code, 'r1').include?('bc2cpp_raise1(') && kd.call(code, 'r2').include?('bc2cpp_raise2('))
  scenario = <<~'CPP'
    static void describe(mrb_state* M, const char* label, mrb_value v) {
      if (M->exc) {
        mrb_value e = mrb_obj_value(M->exc);
        M->exc = nullptr;
        mrb_value msg = mrb_funcall(M, e, "message", 0);
        std::printf("%s => raised %s: %.*s\n", label, mrb_obj_classname(M, e), (int)RSTRING_LEN(msg), RSTRING_PTR(msg));
      } else {
        mrb_value s = mrb_inspect(M, v);
        std::printf("%s => %.*s\n", label, (int)RSTRING_LEN(s), RSTRING_PTR(s));
      }
    }
    static int scenario(mrb_state* M) {
      mrb_value fx = mrb_obj_new(M, mrb_class_get(M, "KdFx"), 0, nullptr);
      struct RClass* runtime_error = mrb_class_get(M, "RuntimeError");
      struct RClass* arg_error = mrb_class_get(M, "ArgumentError");
      struct RClass* kd_error = mrb_class_get(M, "KdError");
      struct RClass* bad_new = mrb_class_get(M, "KdBadNew");
      struct RClass* bare = mrb_class_get(M, "KdBare");
      mrb_value orig_msg = mrb_str_new_lit(M, "orig");
      mrb_value orig = mrb_obj_new(M, runtime_error, 1, &orig_msg);
      mrb_value msg = mrb_str_new_lit(M, "kaboom");
      mrb_value plain = mrb_str_new_lit(M, "plain");
      mrb_value none[1] = { mrb_nil_value() };
      #define CASE1(label, fn, a) { mrb_value args[1] = { a }; mrb_value r = mrb_funcall_argv(M, fx, mrb_intern_cstr(M, fn), 1, args); describe(M, label, r); }
      #define CASE2(label, fn, a, b) { mrb_value args[2] = { a, b }; mrb_value r = mrb_funcall_argv(M, fx, mrb_intern_cstr(M, fn), 2, args); describe(M, label, r); }
      mrb_value r0 = mrb_funcall(M, fx, "rs", 0);
      describe(M, "rs", r0);
      CASE1("r1 String", "r1", plain)
      CASE1("r1 class", "r1", mrb_obj_value(arg_error))
      CASE1("r1 custom class", "r1", mrb_obj_value(kd_error))
      CASE1("r1 instance", "r1", orig)
      CASE1("r1 nil", "r1", mrb_nil_value())
      CASE1("r1 Integer", "r1", mrb_fixnum_value(1))
      CASE1("r1 Symbol", "r1", mrb_symbol_value(mrb_intern_lit(M, "sym")))
      CASE1("r1 Array", "r1", mrb_ary_new(M))
      CASE1("r1 non-exception class", "r1", mrb_obj_value(bare))
      CASE1("r1 class whose new is not an exception", "r1", mrb_obj_value(bad_new))
      CASE2("r2 class, String", "r2", mrb_obj_value(arg_error), msg)
      CASE2("r2 class, nil", "r2", mrb_obj_value(arg_error), mrb_nil_value())
      CASE2("r2 class, Integer", "r2", mrb_obj_value(arg_error), mrb_fixnum_value(7))
      CASE2("r2 class, Symbol", "r2", mrb_obj_value(runtime_error), mrb_symbol_value(mrb_intern_lit(M, "s")))
      CASE2("r2 custom class, String", "r2", mrb_obj_value(kd_error), msg)
      CASE2("r2 custom class, nil", "r2", mrb_obj_value(kd_error), mrb_nil_value())
      CASE2("r2 instance, String", "r2", orig, msg)
      CASE2("r2 instance, nil", "r2", orig, mrb_nil_value())
      CASE2("r2 String, String", "r2", plain, msg)
      CASE2("r2 nil, String", "r2", mrb_nil_value(), msg)
      CASE2("r2 non-exception class, String", "r2", mrb_obj_value(bare), msg)
      CASE2("r2 bad new, String", "r2", mrb_obj_value(bad_new), msg)
      { mrb_value args[3] = { mrb_obj_value(arg_error), msg, mrb_ary_new(M) };
        describe(M, "r3", mrb_funcall_argv(M, fx, mrb_intern_cstr(M, "r3"), 3, args)); }
      CASE1("rescued String", "rescued", plain)
      CASE1("rescued instance keeps identity", "rescued", orig)
      CASE2("rescued2 instance is cloned", "rescued2", orig, msg)
      CASE2("rescued2 class", "rescued2", mrb_obj_value(kd_error), msg)
      CASE1("ensured", "ensured", mrb_obj_value(arg_error))
      describe(M, "oid", mrb_funcall(M, fx, "oid", 0));
      return 0;
    }
  CPP
  body = <<~CPP
    #include <mruby/error.h>
    #{scenario}
  CPP
  built, output = runtime.run(dir, err, %w[KdFx], body, build: runtime.core)
  check.call('the Kernel fixture compiles against real mruby', built)
  if built
    sections = runtime.sections(output)
    interpreted = sections['interpreted'].to_a
    compiled = sections['compiled'].to_a.grep_v(/^\s+dispatches=/)
    puts output.lines.first(6).map { |l| "       #{l}" }.join if ENV['DN_DUMP']
    check.call('the interpreter ran the scenario', interpreted.size > 20)
    check.call('every raise form raises what the interpreter raises (class, message, identity and clone)',
               interpreted == compiled)
    puts (compiled - interpreted).first(6).map { |l| "       compiled only: #{l}" }.join("\n") unless interpreted == compiled
  end
  FileUtils.rm_rf(dir)
else
  puts '  SKIP Kernel behaviour: no libmruby_core.a (set BC2CPP_MRUBY_CORE) or no g++'
end

# -- generated code: core -----------------------------------------------------------------

# A file below 3rd/mruby/mrblib/ is mruby's own Ruby to bc2cpp, which is what the block-parameter
# and rest-parameter proofs are for.
CORE_PATH = '3rd/mruby/mrblib/dn_core.rb'
CORE_WORLD = <<~'RUBY'
  class DnCore
    def call1(x, &blk); blk.call(x); end
    def call_opt(a, b = 2, &blk); r = []; [a, b].each { |v| r << blk.call(v) }; r; end
    def call_nested(&blk); r = []; [1, 2].each { |v| r << blk.call(v) }; r; end
    def call_reassign(&blk); blk = nil; blk.call(1); end
    def call_maybe(x, &blk); blk = proc { |v| v * 3 } if x; blk.call(2); end
    def call_param(blk); blk.call(1); end
    def call_default(blk = nil, &other); blk.call(1); end
    def call_nested_write(&blk); [1].each { blk = nil }; blk.call(1); end
    def call_argc(x, &blk); blk.call(x, x); end
    def call_zero(&blk); blk.call; end
    def svalue_rest(*v); v.__svalue; end
    def svalue_rewrite(*v); v = [1, 2, 3]; v.__svalue; end
    def svalue_first(*v); v = v.__svalue; v.__svalue; end
    def svalue_mand(a, *v); [a, v.__svalue, v.to_a]; end
    def svalue_param(v); v.__svalue; end
    def svalue_opt(a, b = [1], *v); [b.__svalue, v.__svalue]; end
    def compact_rest(*v); [v.compact, v.index(2)]; end
    def join_rest(*v); v.join; end
    def shift_rest(*v); v.shift; end
    def each_rest(a); a.each { |*v| v.__svalue }; end
  end
RUBY
dn = ->(code, fn) { body_of.call(code, 'DnCore', fn) }

core_closed = generate.call(CORE_WORLD, path: CORE_PATH)
sends = ->(code) { code.scan(/\b(?:bc2cpp_send|mrb_funcall|mrb_funcall_with_block)\(/).size }
%w[call1 call_argc call_zero].each do |fn|
  body = dn.call(core_closed, fn)
  check.call("#{fn}: blk.call on the &blk parameter has a Proc arm and a NoMethodError else",
             body.include?('BLOCK_PARAM_CALL :call') && body.include?('mrb_proc_p(r') && body.include?('bc2cpp_nomethod(M, r') &&
               !body.include?('bc2cpp_send(M, r'))
end
check.call('a call from a block nested in the method, and with an optional parameter, is proven too',
           dn.call(core_closed, 'call_opt').include?('BLOCK_PARAM_CALL :call') &&
             dn.call(core_closed, 'call_nested').include?('BLOCK_PARAM_CALL :call'))
check.call('call1 makes no cached send at all', sends.call(dn.call(core_closed, 'call1')).zero?)
{ 'call_reassign' => 'a block rewritten to nil', 'call_maybe' => 'a block replaced on one path',
  'call_param' => 'a plain parameter', 'call_default' => 'an optional parameter',
  'call_nested_write' => 'a block rewritten by a nested block' }.each do |fn, why|
  body = dn.call(core_closed, fn)
  check.call("#{fn}: #{why} keeps the dynamic send", !body.include?('BLOCK_PARAM_CALL') && body.include?('POLY :call'))
end
check.call('the same fixture outside mruby\'s own Ruby is untouched',
           !generate.call(CORE_WORLD.sub('DnCore', 'DnUser')).include?('BLOCK_PARAM_CALL'))
check.call('without the closed world no core proof is taken (no program facts)',
           !generate.call(CORE_WORLD, closed: false, path: CORE_PATH).include?('BLOCK_PARAM_CALL'))
{
  'a Ruby call on any class' => "class DnOther\n  def call(x); x; end\nend\n",
  'a Ruby call on NilClass' => "class NilClass\n  def call(*); 1; end\nend\n",
  'a method_missing on NilClass' => "class NilClass\n  def method_missing(*); 1; end\nend\n",
  'a singleton call' => "class DnOther\n  def self.call(x); x; end\nend\n",
  'a dynamic installer' => "class DnOther\n  def install(n); Object.send(:define_method, n) { 1 }; end\nend\n"
}.each do |what, extra|
  code = generate.call(CORE_WORLD, path: CORE_PATH, extra: extra)
  check.call("#{what} withdraws BLOCK_PARAM_CALL", !code.include?('BLOCK_PARAM_CALL') && dn.call(code, 'call1').include?('POLY :call'))
end

svalue = ->(fn) { dn.call(core_closed, fn) }
check.call('v.__svalue on the *rest parameter is the inlined helper with no send',
           svalue.call('svalue_rest').match?(/NATIVE_CORE_DIRECT_REST :__svalue.*\n\s+r\d+ = bc2cpp_ary_svalue\(M, r\d+\);/) &&
             !svalue.call('svalue_rest').include?('bc2cpp_send('))
check.call('a rest parameter after mandatory ones and to_a/compact/index/join/shift use the same arm',
           svalue.call('svalue_mand').scan('NATIVE_CORE_DIRECT_REST').size == 2 &&
             svalue.call('compact_rest').scan('NATIVE_CORE_DIRECT_REST').size == 2 &&
             svalue.call('join_rest').include?('NATIVE_CORE_DIRECT_REST :join') &&
             svalue.call('shift_rest').include?('NATIVE_CORE_DIRECT_REST :shift'))
check.call('a rest-only block\'s parameter gets it too',
           core_closed.scan(/DnCore_each_rest_block_fallback_\d+_impl\(mrb_state\* M.*?^\}/m).any? { |fn| fn.include?('NATIVE_CORE_DIRECT_REST :__svalue') })
check.call('a rewritten rest parameter, a plain parameter and a rest after optionals keep the send',
           %w[svalue_rewrite svalue_param svalue_opt].none? { |fn| svalue.call(fn).include?('NATIVE_CORE_DIRECT_REST') })
check.call('reading the rest parameter before rewriting it is still proven',
           svalue.call('svalue_first').scan('NATIVE_CORE_DIRECT_REST').size == 1)
{
  'a Ruby __svalue on Array' => "class Array\n  def __svalue; 1; end\nend\n",
  'a prepend on Array' => "module DnShadow\n  def __svalue; 1; end\nend\nclass Array\n  prepend DnShadow\nend\n",
  'a dynamic installer' => "class DnOther\n  def install(n); Array.send(:define_method, n) { 1 }; end\nend\n"
}.each do |what, extra|
  code = generate.call(CORE_WORLD, path: CORE_PATH, extra: extra)
  check.call("#{what} withdraws the rest-parameter arm", !dn.call(code, 'svalue_rest').include?('NATIVE_CORE_DIRECT_REST'))
end

# -- behaviour: core ----------------------------------------------------------------------------

CORE_DRIVER = <<~'RUBY'
  class DnDriver
    def self.protect
      yield
    rescue Exception => e
      [e.class, e.message]
    end

    def self.rows
      d = DnCore.new
      pairs = Object.new
      def pairs.each; yield 1, 2; yield 3; yield; yield [4, 5]; yield nil; end
      rows = []
      rows << d.call1(3) { |x| x * 2 }
      rows << d.call1(3, &:succ)
      rows << d.call1(3, &lambda { |x| x + 1 })
      rows << d.call1(3, &proc { |x, y| [x, y] })
      rows << d.call1([1, 2], &proc { |x, y| [x, y] })
      rows << d.call1(:m, &1.method(:+)) rescue rows << :method_arg
      rows << protect { d.call1(3) }
      rows << protect { d.call1(3, &nil) }
      rows << protect { d.call_zero }
      rows << d.call_zero { :zero }
      rows << d.call_argc(4) { |a, b| a + b }
      rows << protect { d.call_argc(4) }
      rows << d.call_opt(1) { |v| v + 10 }
      rows << d.call_opt(1, 5) { |v| v + 10 }
      rows << protect { d.call_opt(1) }
      rows << d.call_nested { |v| v * v }
      rows << protect { d.call_nested }
      rows << protect { d.call1(3) { |x| raise ArgumentError, "from block #{x}" } }
      rows << d.call1(3) { |x| next x + 100 }
      rows << [d.call_maybe(true) { |v| v }, d.call_maybe(false) { |v| v }]
      rows << protect { d.call_reassign { 1 } }
      rows << protect { d.call_param(nil) }
      rows << d.call_param(proc { |v| v + 1 })
      rows << protect { d.call_nested_write { 1 } }
      rows << d.svalue_rest
      rows << d.svalue_rest(1)
      rows << d.svalue_rest(1, 2)
      rows << d.svalue_rest([1, 2])
      rows << d.svalue_rest(nil)
      rows << d.svalue_rest(nil, nil)
      rows << protect { d.svalue_first(1, 2) }
      rows << protect { d.svalue_first(5) }
      rows << protect { d.svalue_first }
      rows << d.svalue_mand(1)
      rows << d.svalue_mand(1, 2)
      rows << d.svalue_mand(1, 2, 3)
      rows << d.svalue_rewrite(9)
      rows << d.svalue_opt(1)
      rows << d.svalue_opt(1, [2, 3], 4, 5)
      rows << d.compact_rest(1, nil, 2, nil)
      rows << d.compact_rest
      rows << d.join_rest(1, 2, 3)
      rows << d.shift_rest(7, 8)
      rows << d.shift_rest
      rows << d.each_rest(pairs)
      rows << d.each_rest([[1, 2], [3]])
      rows << protect { d.svalue_param(1) }
      rows << d.svalue_param([4, 5])
      rows << d.svalue_param([6])
      rows << d.svalue_param([])
      rows
    end
  end
RUBY

full = runtime.full
if full && runtime.compiler?
  dir = Dir.mktmpdir('bc2cpp_direct_natives_core')
  code, err = runtime.generate("#{CORE_WORLD}\n#{CORE_DRIVER}", dir, path: CORE_PATH)
  check.call('the core fixture takes all three proofs',
             %w[BLOCK_PARAM_CALL NATIVE_CORE_DIRECT_REST].all? { |marker| code.include?(marker) })
  body = <<~'CPP'
    static int scenario(mrb_state* M) {
      mrb_value rows = mrb_funcall(M, mrb_obj_value(mrb_class_get(M, "DnDriver")), "rows", 0);
      if (M->exc) { mrb_print_error(M); return 2; }
      for (mrb_int i = 0; i < RARRAY_LEN(rows); ++i) {
        mrb_value s = mrb_inspect(M, RARRAY_PTR(rows)[i]);
        std::printf("%d: %.*s\n", (int)i, (int)RSTRING_LEN(s), RSTRING_PTR(s));
      }
      return 0;
    }
  CPP
  built, output = runtime.run(dir, err, %w[DnCore DnDriver], body, build: full, full: true)
  check.call('the core fixture compiles against real mruby', built)
  if built
    sections = runtime.sections(output)
    interpreted = sections['interpreted'].to_a
    compiled = sections['compiled'].to_a.grep_v(/^\s+dispatches=/)
    check.call('the interpreter ran the scenario', interpreted.size > 40)
    check.call('the compiled core methods answer what the interpreted ones do (procs, lambdas, nil blocks, rest arrays)',
               interpreted == compiled)
    unless interpreted == compiled
      interpreted.zip(compiled).each_with_index do |(want, got), i|
        puts "       #{i}: interpreted #{want.inspect} compiled #{got.inspect}" if want != got
      end
    end
  end
  FileUtils.rm_rf(dir)
else
  puts '  SKIP core behaviour: no libmruby.a with the full-core gems (set BC2CPP_MRUBY_FULL) or no g++'
end

if failures.empty?
  puts 'bc2cpp direct natives check: PASS'
else
  warn "bc2cpp direct natives check: #{failures.size} failure(s)"
  exit 1
end
