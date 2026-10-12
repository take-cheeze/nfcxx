#!/usr/bin/env ruby
# frozen_string_literal: true

# DEFINE_METHOD_SITES (docs/adr/0288): `define_method(:name) { |a, b| ... }` written straight in
# a class or module body, with a block a `def` could have spelled, is an ordinary method
# definition to the closed world: calls to it are devirtualized and the body is compiled. Every
# other way to install a method by name keeps poisoning that name.
#
# 1. With MRBC: generated code. The positive fixture calls its define_method methods directly
#    (also from inside another define_method body); each negative keeps the dynamic send, raises
#    the arity error, or stays an unresolved name, and the dynamic-installer cases keep
#    withdrawing the devirtualizations of the names they can reach.
# 2. With MRBC, rake and g++: the same fixtures on real mruby, interpreted and compiled, must
#    answer alike, including strict arity, `next`, `@ivars`, inherited and overridden methods.
#
# Usage: MRBC=path/to/mrbc [BC2CPP_MRUBY_FULL=dir] ruby scripts/bc2cpp/define_method_sites_check.rb

require 'tmpdir'

failures = []
check = lambda do |what, condition|
  puts "  #{condition ? 'ok  ' : 'FAIL'} #{what}"
  failures << what unless condition
end

unless ENV['MRBC']
  puts '  SKIP: set MRBC (a host mrbc built from the patched 3rd/mruby)'
  exit 0
end

require_relative 'fixture_runtime'
runtime = Bc2cppFixtureRuntime
body_of = lambda do |code, fn|
  code[/^mrb_value #{fn}_impl\(mrb_state\* M.*?(?=^(?:static )?mrb_value \w+\(mrb_state\* M|\z)/m].to_s
end

WORLD = <<~RUBY
  class DmFx
    def initialize; @n = 10; end
    define_method(:dm_add) { |a, b| a + b + @n }
    define_method(:dm_zero) { @n * 2 }
    define_method(:dm_next) { |a| next 99 if a > 5; a }
    define_method(:dm_sum) { |list| t = 0; list.each { |v| t += v }; t + @n }
    define_method(:dm_rescue) { |a| Integer(a) rescue -1 }
    define_method(:dm_caller) { |x| dm_add(x, 1) + dm_zero }
    def run(x); dm_add(x, 2) + dm_zero + dm_caller(x) + dm_next(x); end
    def run_wrong_arity; dm_add(1); end
  end
  class DmSub < DmFx
    def dm_zero; 7; end
  end
RUBY

# Class-body shapes that are not a method a `def` could spell. Each calls `dm_add(x, 2)` from `run`.
HEAD = "class NgFx\n  def initialize; @n = 10; end\n  def run(x); dm_add(x, 2); end\n"
NEGATIVES = {
  'a String name' => "  define_method('dm_add') { |a, b| a + b + @n }\n",
  'a computed name' => "  n = :dm_add\n  define_method(n) { |a, b| a + b + @n }\n",
  'a block reading a class-body local' => "  k = 3\n  define_method(:dm_add) { |a, b| a + b + k }\n",
  'a block that returns' => "  define_method(:dm_add) { |a, b| return a if b; a + b }\n",
  'an optional parameter' => "  define_method(:dm_add) { |a, b = 1| a + b }\n",
  'a rest parameter' => "  define_method(:dm_add) { |a, *b| a }\n",
  'block_given?' => "  define_method(:dm_add) { |a, b| block_given? }\n",
  'a nested def' => "  define_method(:dm_add) { |a, b| def zz; end; a }\n",
  'super' => "  define_method(:dm_add) { |a, b| super(a, b) }\n",
  'a conditional install' => "  define_method(:dm_add) { |a, b| a } if $flag\n",
  'an install in a loop body' => "  2.times { define_method(:dm_add) { |a, b| a } }\n",
  'two bodies for one name' => "  define_method(:dm_add) { |a, b| a }\n  define_method(:dm_add) { |a, b| b }\n",
  'a singleton class body' => "  class << self; define_method(:dm_add) { |a, b| a }; end\n",
  'a private scope' => "  private\n  define_method(:dm_add) { |a, b| a }\n",
  'a computed-name installer elsewhere' =>
    "  define_method(:dm_add) { |a, b| a }\n  def self.inst(n); send(:define_method, n) { 1 }; end\n",
  'a redefined define_method' =>
    "  define_method(:dm_add) { |a, b| a }\n  def self.define_method(*a, &b); super; end\n",
  'an aliased define_method' =>
    "  define_method(:dm_add) { |a, b| a }\n  class << self; alias_method :define_method, :define_method; end\n"
}.freeze
ARITY = {
  'a block of one parameter called with two' => "  define_method(:dm_add) { |a| a }\n",
  'a block of no parameter called with two' => "  define_method(:dm_add) { 4 }\n"
}.freeze

# bc2cpp.rb's own count of what the registry took and what it withdrew.
SITES_LINE = /== define_method sites \((\d+) registered as definitions, (\d+) left as installers\)/

puts '-- generated code'
Dir.mktmpdir do |dir|
  code, err = runtime.generate(WORLD, dir)
  run = body_of.call(code, 'DmFx_run')
  check.call('the six sites register as definitions', err[SITES_LINE, 1] == '6' && err[SITES_LINE, 2] == '0')
  check.call('run calls dm_add, dm_zero, dm_caller and dm_next directly',
             %w[dm_add dm_zero dm_caller dm_next].all? { |m| run.include?("DmFx_#{m}_impl(M, self") })
  check.call('the define_method bodies are compiled', %w[dm_add dm_zero dm_next dm_sum dm_rescue dm_caller].all? { |m| code.include?("DmFx_#{m}_impl(mrb_state* M") })
  caller_body = body_of.call(code, 'DmFx_dm_caller')
  check.call('a define_method body calls another one directly',
             caller_body.include?('DmFx_dm_add_impl(M, self') && caller_body.include?('DmFx_dm_zero_impl(M, self'))
  check.call('the send that remains is the arithmetic fallback, not a dispatch by name',
             !run.include?('bc2cpp_nomethod(') && run.scan('bc2cpp_send(').size == run.scan(/bc2cpp_send\(M, r\d+, \d+, 1, r\d+\)/).size)
end

# Candidates the registry collects and settle withdraws (the rest never match the shape).
SETTLED = ['two bodies for one name', 'a computed-name installer elsewhere', 'a redefined define_method',
           'an aliased define_method'].freeze
NEGATIVES.each do |what, body|
  Dir.mktmpdir do |dir|
    code, err = runtime.generate("#{HEAD}#{body}end\n", dir)
    run = body_of.call(code, 'NgFx_run')
    kept, dropped = err.match(SITES_LINE)&.captures.to_a.map(&:to_i)
    check.call("#{what} keeps dm_add dynamic", !run.empty? && !run.include?('NgFx_dm_add_impl(') && run.include?('bc2cpp_send('))
    check.call("#{what} registers no definition", kept.to_i.zero?)
    check.call("#{what} is withdrawn after the registry took it", dropped.to_i.positive?) if SETTLED.include?(what)
  end
end
ARITY.each do |what, body|
  Dir.mktmpdir do |dir|
    code, = runtime.generate("#{HEAD}#{body}end\n", dir)
    run = body_of.call(code, 'NgFx_run')
    check.call("#{what} is not called directly", !run.empty? && !run.include?('NgFx_dm_add_impl('))
  end
end

# An ordinary `def` of the same name next to the define_method is ambiguous to the registry. The
# `def` keeps the devirtualization it always had (this check does not widen or narrow it); the
# define_method candidate must not be registered, or compiling it would add a second body.
Dir.mktmpdir do |dir|
  code, err = runtime.generate("#{HEAD}  def dm_add(a, b); a; end\n  define_method(:dm_add) { |a, b| b }\nend\n", dir)
  check.call('a def and a define_method of one name compile one body', code.scan(/^mrb_value NgFx_dm_add_impl\(mrb_state\* M/).size == 1)
  check.call('the define_method is withdrawn, the def kept', err[SITES_LINE, 1] == '0' && err[SITES_LINE, 2] == '1')
end

# A computed-name installer anywhere in the program withdraws every recognized site: it could
# replace any of them, and the registry cannot say which.
Dir.mktmpdir do |dir|
  code, = runtime.generate("#{WORLD}\nclass DmOther\n  def install(n); Array.send(:define_method, n) { 1 }; end\nend\n", dir)
  run = body_of.call(code, 'DmFx_run')
  check.call('a send-installer next to recognized sites withdraws them', !run.empty? && !run.include?('DmFx_dm_add_impl('))
end

full = runtime.full_or_build
if full.nil? || !runtime.compiler?
  puts '  SKIP run: needs rake, g++ and 3rd/mruby (or BC2CPP_MRUBY_FULL)'
else
  puts '-- fixtures on real mruby, interpreted and compiled'
  scenario_world = <<~RUBY
    #{WORLD}
    # Not compiled: calls through OP_SEND, where the VM checks a registered entry's aspec as it
    # checks a proc's ENTER (mrb_funcall_argv, which the harness uses, checks neither).
    class DmProbe
      def self.zero1(o); o.dm_zero(1); end
      def self.add1(o); o.dm_add(1); end
      def self.add3(o); o.dm_add(1, 2, 3); end
      def self.add2(o); o.dm_add(1, 2); end
    end
    class DmUp
      k = 3
      define_method(:dm_up) { |a| a + k }
      define_method(:dm_ret) { |a| [1, 2].each { |q| return q }; a }
      define_method(:dm_opt) { |a, b = 5| a + b }
      define_method(:dm_rest) { |*a| a.size }
      def call_up(x); dm_up(x) + dm_ret(x) + dm_opt(x) + dm_rest(1, 2, 3); end
    end
    class DmTwice
      def initialize; @n = 1; end
      define_method(:dm_val) { |a| a + 1 }
      def call_val(x); dm_val(x); end
      def dm_val(a); a + 100; end
    end
  RUBY
  Dir.mktmpdir do |dir|
    _code, err = runtime.generate(scenario_world, dir, closed: true, only_owners: %w[DmFx DmSub DmUp DmTwice])
    body = <<~CPP
      static mrb_value num(int n) { return mrb_fixnum_value(n); }
      static mrb_value inst(mrb_state* M, const char* cls) { return mrb_obj_new(M, mrb_class_get(M, cls), 0, nullptr); }
      static int scenario(mrb_state* M) {
        mrb_value fx = inst(M, "DmFx"), sub = inst(M, "DmSub"), up = inst(M, "DmUp"), two = inst(M, "DmTwice");
        mrb_value a1[2] = { num(1), num(2) };
        mrb_value a3[3] = { num(1), num(2), num(3) };
        mrb_value a7 = num(7), a4 = num(4);
        call(M, "fx.run(4)", fx, "run", 1, &a4);
        call(M, "sub.run(4)", sub, "run", 1, &a4);
        call(M, "fx.run(7)", fx, "run", 1, &a7);
        call(M, "fx.dm_add(1, 2)", fx, "dm_add", 2, a1);
        call(M, "fx.dm_add(1)", fx, "dm_add", 1, a1);
        call(M, "fx.dm_add(1, 2, 3)", fx, "dm_add", 3, a3);
        mrb_value probe = mrb_obj_value(mrb_class_get(M, "DmProbe"));
        call(M, "probe.zero1", probe, "zero1", 1, &fx);
        call(M, "probe.add1", probe, "add1", 1, &fx);
        call(M, "probe.add2", probe, "add2", 1, &fx);
        call(M, "probe.add3", probe, "add3", 1, &fx);
        call(M, "fx.dm_zero", fx, "dm_zero");
        call(M, "sub.dm_zero", sub, "dm_zero");
        call(M, "fx.dm_next(3)", fx, "dm_next", 1, &a4);
        call(M, "fx.dm_next(7)", fx, "dm_next", 1, &a7);
        mrb_value list = mrb_ary_new(M);
        mrb_ary_push(M, list, num(1)); mrb_ary_push(M, list, num(2)); mrb_ary_push(M, list, num(3));
        call(M, "fx.dm_sum", fx, "dm_sum", 1, &list);
        mrb_value bad = mrb_str_new_cstr(M, "zz"), good = mrb_str_new_cstr(M, "42");
        call(M, "fx.dm_rescue(bad)", fx, "dm_rescue", 1, &bad);
        call(M, "fx.dm_rescue(good)", fx, "dm_rescue", 1, &good);
        call(M, "fx.run_wrong_arity", fx, "run_wrong_arity");
        mrb_value sym = mrb_symbol_value(mrb_intern_cstr(M, "dm_add"));
        call(M, "respond_to", fx, "respond_to?", 1, &sym);
        call(M, "up.call_up", up, "call_up", 1, &a4);
        call(M, "up.dm_up", up, "dm_up", 1, &a4);
        call(M, "up.dm_ret", up, "dm_ret", 1, &a4);
        call(M, "up.dm_opt", up, "dm_opt", 1, &a4);
        call(M, "up.dm_opt(1, 2)", up, "dm_opt", 2, a1);
        call(M, "up.dm_rest", up, "dm_rest", 3, a3);
        call(M, "two.call_val", two, "call_val", 1, &a4);
        call(M, "two.dm_val", two, "dm_val", 1, &a4);
        return 0;
      }
    CPP
    built, output = runtime.run(dir, err, %w[DmFx DmSub DmUp DmTwice], body, build: full, full: true, exact_arity: true)
    check.call('the fixture compiles and runs against real mruby', built)
    puts output unless built
    if built
      sections = runtime.sections(output)
      values = ->(name) { sections.fetch(name, []).reject { |l| l.start_with?('  ') } }
      interpreted = values.call('interpreted')
      compiled = values.call('compiled')
      check.call("compiled answers what the interpreter answers (#{interpreted.size} calls)",
                 !interpreted.empty? && interpreted == compiled)
      check.call('the interpreter enforces the strict arity the compiled methods must match',
                 interpreted.grep(/dm_add\(1\) => raised ArgumentError/).any? &&
                   interpreted.grep(/probe\.zero1 => raised ArgumentError/).any?)
      check.call('the inherited and overridden methods answer per class',
                 interpreted.grep(/fx\.run\(4\)/) != interpreted.grep(/sub\.run\(4\)/))
      dispatches = sections.fetch('compiled', []).each_cons(2).select { |call, n| call.include?('fx.run(') && n.include?('dispatches=') }
      check.call('a compiled run of a recognized method makes no dynamic dispatch', dispatches.any? && dispatches.all? { |_, n| n.strip == 'dispatches=0' })
      puts output if ENV['BC2CPP_CHECK_VERBOSE'] || interpreted != compiled
    end
  end
end

puts(failures.empty? ? 'bc2cpp_define_method_sites_check OK' : "FAILED: #{failures.size}")
exit(failures.empty? ? 0 : 1)
