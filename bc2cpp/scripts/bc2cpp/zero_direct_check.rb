#!/usr/bin/env ruby
# frozen_string_literal: true

# ADR 0374: the `zero?` helper (bc2cpp_slow_zero) calls the compiled Numeric#zero? of the run's own core Ruby for every
# Numeric that is not a Float, raises the ArgumentError of File.zero? / FileTest.zero? for those class objects, and
# dispatches by name only to raise the proven NoMethodError.
#
# 1. With MRBC: a closed world that compiles mruby's own mrblib (`core: true`) has the closed form (the compiled
#    `Numeric_zero$3f_impl` call, the File arm, no by-name call), the `#if` arm kept for Complex/Rational builds is
#    unchanged, and each NEG world (a reopened Numeric/Integer/Float#zero?, a module, a prepend, a singleton or class-level
#    definer, a computed installer, method_missing, a `==` that may yield, a build without mruby-numeric-ext or
#    mruby-io, an open world, no core compile, the kill switches) keeps the by-name helper.
# 2. With a full-core libmruby (BC2CPP_MRUBY_FULL, and BC2CPP_MRUBY_FULL32 + BC2CPP_MRBC32 and BC2CPP_MRUBY_NOBIGINT
#    for the other widths): the helper is called directly against the real `zero?` over Integer, bigint, Float,
#    Numeric.new and subclasses (with and without their own `==` / `zero?`, a `==` that raises or logs), class
#    objects (File, FileTest, a File subclass, others), nil / String / Symbol / Object, frozen receivers, in worlds that
#    reopen Integer#zero?, give an object a singleton `zero?`, define `method_missing`, or lack a gem, comparing the
#    result, the error class and message, and the number of by-name calls.
#
# Usage: MRBC=path/to/mrbc [BC2CPP_MRUBY_FULL=dir ...] ruby scripts/bc2cpp/zero_direct_check.rb

require 'tmpdir'
require_relative 'fixture_runtime'

runtime = Bc2cppFixtureRuntime
failures = []
check = lambda do |what, condition|
  puts "  #{condition ? 'ok  ' : 'FAIL'} #{what}"
  failures << what unless condition
end

unless runtime.mrbc && system(runtime.mrbc, '--version', out: File::NULL, err: File::NULL)
  puts '  SKIP: no host mrbc (set MRBC)'
  exit 0
end

OWNERS = %w[ZdOpen ZdBox ZdN1 ZdN2 ZdN3 ZdN4 ZdN5 ZdN6 ZdFile ZdPlain].freeze
# Every class the run sends `zero?` to is in the program: the closed world is proven for these and mruby's own.
FIXTURE = <<~RUBY
  $zlog = []
  class ZdBox
    def inspect = "box"
  end
  class ZdOpen
    def zero(a) = a.zero?
  end
  class ZdN1 < Numeric; end
  class ZdN2 < Numeric
    def ==(o) = ($zlog << :eq; o == 0)
  end
  class ZdN3 < Numeric
    def ==(o) = raise(ArgumentError, "zd eq")
  end
  class ZdN4 < Numeric
    def ==(o) = :weird
  end
  class ZdN5 < Numeric
    def <=>(o) = 0
  end
  class ZdN6 < ZdN2; end
  class ZdFile < File; end
  class ZdPlain; end
RUBY

# The closed form of the zero helper (the `#else` arm of the Complex/Rational `#if`), or nil.
def closed_form(code)
  wrapped = code[/^#if defined\(MRB_USE_COMPLEX\) \|\| defined\(MRB_USE_RATIONAL\)\n(?:static mrb_value bc2cpp_slow_zero\(.*?^\}\n\n)#else\n(?:static mrb_value bc2cpp_slow_zero\(.*?^\}\n\n)#endif\n/m]
  wrapped && wrapped.split("#else\n", 2).last.sub(/#endif\n\z/, '')
end

def by_name_form(code)
  code[/^static mrb_value bc2cpp_slow_zero\(.*?^\}\n/m] || code[/^#if defined\(MRB_USE_COMPLEX\) \|\| defined\(MRB_USE_RATIONAL\)\n(?:static mrb_value bc2cpp_slow_zero\(.*?^\}\n\n)#else/m]
end

def generate(runtime, extra: '', **opts)
  Dir.mktmpdir do |dir|
    code, err = runtime.generate("#{FIXTURE}#{extra}", dir, closed: true, only_owners: OWNERS, core: true, **opts)
    return [code, err]
  end
end

def direct?(code)
  form = closed_form(code)
  !form.nil? && form.include?('CORE_COMPILED_ZERO') && form.include?('Numeric_zero$3f_impl(M, a)')
end

puts '-- generated code'
code, = generate(runtime)
check.call('POS: core compiled in a closed world: the helper calls the compiled Numeric#zero?', direct?(code))
form = closed_form(code).to_s
check.call('the closed form makes no by-name call and no dynamic dispatch of its own',
           !form.include?('bc2cpp_send(') && !form.include?('mrb_funcall(') && form.include?('bc2cpp_nomethod('))
check.call('the kind_of Numeric test guards the compiled call, and the Float arm and the test come first, the File arm raises the arity error of File.zero?',
           form.index('mrb_float_p(a)').to_i < form.index('Numeric_zero$3f_impl').to_i &&
           form.include?('if (mrb_obj_is_kind_of(M, a, mrb_class_get(M, "Numeric"))) {') &&
           form.include?('mrb_argnum_error(M, 0, 1, 1)') && form.include?('mrb_module_get(M, "FileTest")'))
check.call('the Complex/Rational arm keeps its by-name call', by_name_form(code)&.include?('bc2cpp_send('))
check.call('the compiled body is declared before the helper uses it',
           code.index('mrb_value Numeric_zero$3f_impl(mrb_state*, mrb_value);').to_i < code.index('static mrb_value bc2cpp_slow_zero(').to_i)

NEG_WORLDS = [
  ['Numeric#zero? reopened', "class Numeric\n  def zero? = false\nend\n"],
  ['Integer#zero? reopened', "class Integer\n  def zero? = false\nend\n"],
  ['Float#zero? reopened', "class Float\n  def zero? = false\nend\n"],
  ['a Numeric subclass with its own zero?', "class ZdSub < Numeric\n  def zero? = true\nend\n"],
  ['a module with zero? included into a Numeric subclass', "module ZdMod\n  def zero? = true\nend\nclass ZdInc < Numeric\n  include ZdMod\nend\n"],
  ['a module prepended to Numeric', "module ZdPre\n  def zero? = true\nend\nNumeric.prepend(ZdPre)\n"],
  ['a class method zero? on a user class', "class ZdCls\n  def self.zero? = 1\nend\n"],
  ['a singleton zero? on an object', "class ZdS\n  def self.run\n    o = Object.new\n    def o.zero? = true\n    o\n  end\nend\n"],
  ['a computed installer', "Numeric.send(:define_method, ARGV[0].to_sym) { true }\n"],
  ['an alias installing zero?', "class Numeric\n  alias_method :zero?, :nonzero?\nend\n"],
  ['method_missing on a user class', "class ZdMm\n  def method_missing(n, *a) = 1\nend\n"],
  ['a Numeric `==` that may yield a Fiber', "class ZdY < Numeric\n  def ==(o) = Fiber.yield(1)\nend\n"]
].freeze
NEG_WORLDS.each do |what, extra|
  c, = generate(runtime, extra: extra)
  check.call("NEG: #{what}: not the compiled arm", !direct?(c))
end

c, = generate(runtime, drop_gems: %w[mruby-numeric-ext])
check.call('NEG: a build without mruby-numeric-ext has no Numeric#zero? to call', !direct?(c))
c, = generate(runtime, drop_gems: %w[mruby-io])
check.call('NEG: a build without mruby-io (the File natives are spelled in the scanned sources) keeps the by-name helper', !direct?(c))
Dir.mktmpdir do |dir|
  c, = runtime.generate(FIXTURE, dir, closed: false, only_owners: OWNERS, core: true)
  check.call('NEG: an open world keeps the by-name helper', !direct?(c))
end
Dir.mktmpdir do |dir|
  c, = runtime.generate(FIXTURE, dir, closed: true, only_owners: OWNERS, core: false)
  check.call('NEG: no core compile in the run (every shipped firmware build): no compiled body to call', !direct?(c) && by_name_form(c)&.include?('bc2cpp_send('))
end
%w[BC2CPP_CORE_COMPILED_ZERO BC2CPP_NUMERIC_SLOW_CLOSED].each do |var|
  saved = ENV[var]
  ENV[var] = '0'
  begin
    c, = generate(runtime)
  ensure
    ENV[var] = saved
  end
  check.call("#{var}=0 keeps the by-name helper", !direct?(c) && by_name_form(c)&.include?('bc2cpp_send('))
end

# ----- run
DRIVER = <<~RUBY
  $big = begin; 2 ** 70; rescue RangeError; 0; end
  $recvs = [0, 1, -1, 2, 1 << 30, -(1 << 30), $big, -$big, $big - $big, 0.0, -0.0, 1.5, Float::NAN, Float::INFINITY,
            -Float::INFINITY, Numeric.new, ZdN1.new, ZdN2.new, ZdN3.new, ZdN4.new, ZdN5.new, ZdN6.new,
            ZdN1.new.freeze, ZdN2.new.freeze, 3.freeze, File, FileTest, ZdFile, Class.new(File), Class.new(ZdFile), Object,
            Integer, Numeric, Comparable, Kernel, Class.new, Module.new, File.singleton_class, nil, true, false, "s", :s, [], {},
            Object.new, ZdPlain.new, ZdBox.new, 1..2, proc { 1 }, "s".freeze]
  # Calls the helper makes by name: 1 for the proof's dispatch that raises, 0 for a Float or a class object it answers; a
  # Numeric runs the compiled body, whose `==` is by name once a program `==` exists (the body's own site): -1, at most one.
  $exp = $recvs.map do |r|
    if r.is_a?(Float) || r.equal?(FileTest) || (r.is_a?(Class) && r.ancestors.include?(File)) then 0
    elsif r.is_a?(Numeric) then -1
    else 1
    end
  end
  puts 'end'
RUBY

# A program `==` makes the compiled bodies' `==` arms name rgss's native Rect/Color/Tone; libmruby does not link rgss.
RGSS_STUBS = <<~CPP
  namespace rgss {
  RClass* native_rect_class(void) { return nullptr; }
  RClass* native_color_class(void) { return nullptr; }
  RClass* native_tone_class(void) { return nullptr; }
  mrb_value rect_eq_direct(mrb_state*, mrb_value, mrb_value) { return mrb_false_value(); }
  mrb_value color_eq_direct(mrb_state*, mrb_value, mrb_value) { return mrb_false_value(); }
  mrb_value tone_eq_direct(mrb_state*, mrb_value, mrb_value) { return mrb_false_value(); }
  }
CPP

STUB = <<~CPP
  static mrb_value bc2cpp_slow_zero(mrb_state* M, mrb_value a) {
    mrb_value o = mrb_obj_new(M, mrb_class_get(M, "ZdOpen"), 0, nullptr);
    return (mrb_funcall)(M, o, "zero", 1, a);
  }
CPP

SCENARIO = <<~CPP
  #include <string>
  static std::string zd_describe(mrb_state* M, mrb_value v, bool raised) {
    if (raised) {
      mrb_value msg = (mrb_funcall)(M, v, "message", 0);
      return std::string("raised ") + mrb_obj_classname(M, v) + ": " + std::string(RSTRING_PTR(msg), RSTRING_LEN(msg));
    }
    mrb_value s = mrb_inspect(M, v);
    return std::string(RSTRING_PTR(s), RSTRING_LEN(s));
  }
  struct ZdCall { mrb_value a; bool method; };
  static mrb_value zd_body(mrb_state* M, void* ud) {
    ZdCall* k = (ZdCall*)ud;
    return k->method ? (mrb_funcall)(M, k->a, "zero?", 0) : bc2cpp_slow_zero(M, k->a);
  }
  static int scenario(mrb_state* M) {
    std::fflush(stdout);
    mrb_load_string(M, R"BCD(__SOURCE__)BCD");
    if (M->exc) { mrb_print_error(M); M->exc = nullptr; return 1; }
    mrb_value recvs = mrb_gv_get(M, mrb_intern_lit(M, "$recvs"));
    mrb_value exps = mrb_gv_get(M, mrb_intern_lit(M, "$exp"));
    mrb_value zlog = mrb_gv_get(M, mrb_intern_lit(M, "$zlog"));
    bool closed = mrb_test(mrb_gv_get(M, mrb_intern_lit(M, "$closed")));
    int total = 0, bad = 0, wrong_calls = 0, errors = 0, trues = 0, falses = 0, classes = 0, numerics = 0, logs = 0;
    for (int round = 0; round < 3; ++round) for (mrb_int i = 0; i < RARRAY_LEN(recvs); ++i) {
      mrb_value a = RARRAY_PTR(recvs)[i];
      mrb_int expect = mrb_integer(RARRAY_PTR(exps)[i]);
      int ai = mrb_gc_arena_save(M);
      ZdCall got_call = { a, false }, want_call = { a, true };
      mrb_bool e1 = FALSE, e2 = FALSE;
      mrb_ary_clear(M, zlog);
      dispatches = 0;
      mrb_value got = mrb_protect_error(M, zd_body, &got_call, &e1);
      int made = dispatches;
      mrb_int got_log = RARRAY_LEN(zlog);
      std::string g = zd_describe(M, got, e1);
      mrb_ary_clear(M, zlog);
      mrb_value want = mrb_protect_error(M, zd_body, &want_call, &e2);
      std::string w = zd_describe(M, want, e2);
      mrb_int want_log = RARRAY_LEN(zlog);
      mrb_gc_arena_restore(M, ai);
      if (round == 2) mrb_full_gc(M);
      ++total;
      if (e1) ++errors;
      if (!e1 && mrb_true_p(got)) ++trues;
      if (!e1 && mrb_false_p(got)) ++falses;
      if (mrb_class_p(a)) ++classes;
      if (mrb_obj_is_kind_of(M, a, mrb_class_get(M, "Numeric"))) ++numerics;
      logs += (int)got_log;
      bool calls_ok = !closed || (expect < 0 ? made <= 1 : made == expect);
      if (!calls_ok) {
        ++wrong_calls;
        if (wrong_calls <= 8) std::printf("  MISCOUNT %d by-name calls, expected %d: %s\\n", made, (int)expect, g.c_str());
      }
      // The user `==` ran as often as the method ran it.
      if (g != w || got_log != want_log) {
        ++bad;
        if (bad <= 8) {
          mrb_value as = mrb_inspect(M, a);
          std::printf("  MISMATCH %.*s helper=%s (log %d) method=%s (log %d)\\n", (int)RSTRING_LEN(as), RSTRING_PTR(as), g.c_str(),
                      (int)got_log, w.c_str(), (int)want_log);
        }
      }
    }
    std::printf("  summary %d cases, %d mismatches, %d wrong dispatch counts, %d exceptions, %d true, %d false, %d class objects, %d Numerics, %d user == calls\\n",
                total, bad, wrong_calls, errors, trues, falses, classes, numerics, logs);
    return 0;
  }
CPP

builds = []
full = runtime.full || (ENV['BC2CPP_FULL_BUILD_DIR'] ? runtime.full_or_build : nil)
builds << ['mrb_int 64', full, ENV['MRBC'], '-DMRB_USE_BIGINT'] if full && runtime.compiler?
if ENV['BC2CPP_MRUBY_FULL32'] && ENV['BC2CPP_MRBC32'] && runtime.compiler?
  builds << ['mrb_int 32 (MRB_INT32, 31-bit Fixnums)', ENV['BC2CPP_MRUBY_FULL32'], ENV['BC2CPP_MRBC32'], '-DMRB_32BIT -DMRB_INT32 -no-pie -DMRB_USE_BIGINT']
end
builds << ['no mruby-bigint (32-bit mrb_int)', ENV['BC2CPP_MRUBY_NOBIGINT'], ENV['MRBC'], ''] if ENV['BC2CPP_MRUBY_NOBIGINT'] && runtime.compiler?

if ENV['ZD_GENERATED_ONLY'] == '1'
  puts '-- generated code only (mutation run)'
elsif builds.empty?
  puts '-- SKIP run: set BC2CPP_MRUBY_FULL (full-core libmruby.a) and have g++'
else
  # [label, extra program source compiled with the fixture, extra driver source, whether the closed form must be on]
  worlds = [
    ['the closed world', '', '', true],
    ['Integer#zero? reopened', "class Integer\n  def zero? = :reopened\nend\n", '', false],
    ['Numeric#zero? reopened', "class Numeric\n  def zero? = :num\nend\n", '', false],
    ['a singleton zero? on an object', "class ZdS\n  def self.run\n    o = Object.new\n    def o.zero? = :singleton\n    o\n  end\nend\n",
     "$recvs << ZdS.run\n$exp << 1\n", false],
    ['method_missing on a user class', "class ZdMm\n  def method_missing(n, *a) = :mm\nend\n", "$recvs << ZdMm.new\n$exp << 1\n", false]
  ]
  builds.each do |label, build, mrbc, flags|
    worlds.each do |world, program, driver_extra, closed|
      puts "-- helper against the real zero? on real mruby (#{label}; #{world}), interpreted"
      saved = ENV.values_at('MRBC', 'BC2CPP_CXXFLAGS')
      ENV['MRBC'] = mrbc
      ENV['BC2CPP_CXXFLAGS'] = flags
      begin
        Dir.mktmpdir do |dir|
          code, err = runtime.generate("#{FIXTURE}#{program}", dir, closed: true, only_owners: OWNERS, core: true)
          check.call("#{world}: the closed form is #{closed ? 'on' : 'off'}", direct?(code) == closed)
          source = DRIVER.sub("puts 'end'\n", "$closed = #{closed}\n#{driver_extra}puts 'end'\n")
          # A world without the helper has no site to call it from: the compiled call site stands in.
          stub = code.include?('static mrb_value bc2cpp_slow_zero(') ? '' : STUB
          built, output = runtime.run(dir, err, OWNERS + %w[Numeric], RGSS_STUBS + stub + SCENARIO.sub('__SOURCE__') { source }, build: build, full: true, vms: [true])
          check.call("#{world}: the fixture builds and runs", built)
          puts output.to_s.lines.last(15).join unless built
          next unless built

          puts output.to_s.lines.select { |l| l.include?('MISMATCH') || l.include?('MISCOUNT') || l.include?('summary') }.first(12).join
          check.call("#{world}: every helper call agrees with the real zero? (value, error class and message, user == calls)", output.to_s.include?(' 0 mismatches,'))
          # A world that turned the closed form off holds the by-name helper, which calls once for every non-Float receiver.
          check.call("#{world}: by-name call counts are as proven", !closed || output.to_s.include?(' 0 wrong dispatch counts,'))
          check.call("#{world}: the matrix has class objects, Numerics, exceptions, true and false answers", !closed ||
                     output.to_s =~ /(\d+) exceptions, (\d+) true, (\d+) false, (\d+) class objects, (\d+) Numerics/ &&
                     $1.to_i > 30 && $2.to_i > 10 && $3.to_i > 10 && $4.to_i > 20 && $5.to_i > 40)
        end
      ensure
        ENV['MRBC'], ENV['BC2CPP_CXXFLAGS'] = saved
      end
    end
  end
end

if failures.empty?
  puts 'OK'
else
  puts "FAILED: #{failures.size}"
  exit 1
end
