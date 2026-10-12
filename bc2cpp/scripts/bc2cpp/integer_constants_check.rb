#!/usr/bin/env ruby
# frozen_string_literal: true

# Check INTEGER_CONSTANT_PROOF's two poison sources (docs/adr/0324): a bare constant name is admitted as an Integer only
# when every definition of it is visible and integral.
#
#  - a native `mrb_define_const` / `mrb_define_const_id` / `mrb_define_global_const` / `mrb_const_set` of the name
#    withdraws it (the scan used to match nothing: a lazy `.{0,200}?` window);
#  - a SETCONST that a conditional jump lands on (`X = c || 1`, `X = c && 1`) is not an Integer definition: the register
#    holds `c` on the other path.
#
# 1. Unit cases (needs MRBC): the analyzer's admitted set for each form, positives and negatives.
# 2. Generated code (needs MRBC): the diagnostic lists exactly the sound constants.
# 3. Behaviour on real mruby: the fixture runs interpreted and compiled; the constants a native source or a jump makes a
#    Float, nil, false or String must give the interpreter's value or exception when used as an Integer operand. Run it on
#    a full-core and a core-only mruby, and on a 32-bit mrb_int build (BC2CPP_MRUBY_FULL32 + BC2CPP_MRBC32).
#    IC_GENERATED_ONLY=1 stops after 2 (what the mutation check runs).
#
# Usage: [MRBC=path/to/mrbc BC2CPP_MRUBY_FULL=dir BC2CPP_MRUBY_CORE=dir BC2CPP_MRUBY_FULL32=dir BC2CPP_MRBC32=mrbc32]
#        ruby scripts/bc2cpp/integer_constants_check.rb

require 'fileutils'
require 'tmpdir'
require_relative 'fixture_runtime'
# The unit cases load the same generator the fixture run uses (BC2CPP_TOOL names a mutant copy).
require Bc2cppFixtureRuntime::BC2CPP

failures = []
check = lambda do |what, condition|
  puts "  #{condition ? 'ok  ' : 'FAIL'} #{what}"
  failures << what unless condition
end

runtime = Bc2cppFixtureRuntime

# Consts of IcNat are defined natively (scenario below) and never by Ruby; IcOther gives the same bare names an Integer.
HOLDER = <<~RUBY
  FLTV = 2.5
  NILV = nil
  class IcNat; end
  class IcOther
    NATF = 1
    NATN = 1
    NATS = 1
    NATK = 1
    NATI = 1
  end

  class IcHold
    PLAIN = 100
    SUM = PLAIN + 1
    ORC = FLTV || 1
    ANDN = NILV && 1
    ANDF = (FLTV > 9) && 1
    TERN = [].size > 0 ? 1 : 2.5
    ARIT = 1 + (FLTV || 2)
    # Last: the jump past it lands on the next write, which the proof refuses to walk through.
    # Sound: a conditional assignment of an Integer is an Integer or no binding at all.
    IFY = 100 if [].size == 0
    def or_in; ORC + 1; end
  end

  # SETMCNST: the scoped form of the same assignment.
  IcHold::ORM = FLTV || 1

  class IcUse
    def orm; IcHold::ORM + 1; end
    def nat_f; IcNat::NATF + 1; end
    def nat_n; IcNat::NATN + 1; end
    def nat_s; NATS + 1; end
    def nat_k; IcNat::NATK * 2; end
    def nat_i; IcNat::NATI - 1; end
    def nat_lt; IcNat::NATF < 3; end
    def other_ok; IcOther::NATF + 1; end
    def or_c; IcHold::ORC + 1; end
    def and_n; IcHold::ANDN + 1; end
    def and_f; IcHold::ANDF + 1; end
    def tern; IcHold::TERN + 1; end
    def arit; IcHold::ARIT + 1; end
    def plain; IcHold::PLAIN + 1; end
    def ify; IcHold::IFY + 1; end
    def sum; IcHold::SUM + 1; end
    def or_in; IcHold.new.or_in; end
  end
RUBY

OWNERS = %w[IcNat IcOther IcHold IcUse].freeze

# What the fixture's own scenario defines; the closed world scans the same text.
NATIVE_TEXT = <<~CXX
  static void ic_native(mrb_state* M, RClass* c) {
    mrb_define_const(M, c, "NATF", mrb_float_value(M, 2.5));
    mrb_define_const_id(M, c, MRB_SYM(NATN), mrb_nil_value());
    mrb_define_global_const(M, "NATS", mrb_str_new_lit(M, "s"));
    mrb_const_set(M, mrb_obj_value(c), mrb_intern_lit(M, "NATK"), mrb_float_value(M, 1.5));
    mrb_define_const(M,
                     c,
                     "NATI",
                     mrb_float_value(M, 0.5));
  }
CXX

# Sound names the proof must keep, and the names it must withdraw.
KEEP = %w[PLAIN SUM IFY].freeze
WITHDRAWN = %w[ORC ORM ANDN ANDF TERN ARIT NATF NATN NATS NATK NATI].freeze

# -- 1. unit cases ---------------------------------------------------------------------

if ENV['MRBC']
  puts '== unit cases'
  Dir.mktmpdir do |dir|
    source = File.join(dir, 'ic.rb')
    File.write(source, HOLDER)
    ireps, = compile_ireps(source, 'bc2cpp_ic', dir)
    native = File.join(dir, 'native.cxx')
    File.write(native, NATIVE_TEXT)
    clean = File.join(dir, 'clean.cxx')
    File.write(clean, "void f(mrb_state* M) { mrb_gc_arena_restore(M, 0); }\n")

    names = IntegerConstants.native_defined_const_names([native])
    check.call('native_defined_const_names reads each native definition form (a quoted name, MRB_SYM, a call over several lines, mrb_const_set)',
               names >= Set.new(%w[NATF NATN NATS NATK NATI]))
    check.call('native_defined_const_names reads nothing from a source without a constant definition',
               IntegerConstants.native_defined_const_names([clean]).empty?)

    admitted = IntegerConstants.analyze(ireps, [native], [])
    KEEP.each { |n| check.call("#{n}: sound, still admitted", admitted.include?(n)) }
    WITHDRAWN.each { |n| check.call("NEG #{n}: not an Integer constant", !admitted.include?(n)) }
    values = IntegerConstants.analyze_values(ireps, admitted)
    check.call('no withdrawn name has an inlined value', WITHDRAWN.none? { |n| values.key?(n) })
    check.call('the sound sums keep their value', values['PLAIN'] == 100 && values['SUM'] == 101)

    without = IntegerConstants.analyze(ireps, [clean], [])
    check.call('without the native source the native names are Ruby Integers (the control for the poison)',
               %w[NATF NATN NATS NATK NATI].all? { |n| without.include?(n) })
  end
else
  puts '-- SKIP unit cases: set MRBC'
end

# -- 2. generated code -----------------------------------------------------------------

if ENV['MRBC']
  puts '== generated code'
  Dir.mktmpdir do |dir|
    _, err = runtime.generate(HOLDER, dir, only_owners: OWNERS, native: [['ic_native.cxx', NATIVE_TEXT]])
    listed = err.lines.grep(/^  CONST /).reject { |l| l.include?(' = ') }.map { |l| l.split[1] }
    KEEP.each { |n| check.call("the diagnostic lists #{n}", listed.include?(n)) }
    WITHDRAWN.each { |n| check.call("NEG the diagnostic does not list #{n}", !listed.include?(n)) }
  end
end

# -- 3. behaviour ----------------------------------------------------------------------

builds = []
if ENV['MRBC'] && runtime.compiler? && !ENV['IC_GENERATED_ONLY']
  flags = ENV.fetch('BC2CPP_CXXFLAGS', '')
  full = runtime.full || (ENV['BC2CPP_FULL_BUILD_DIR'] ? runtime.full_or_build : nil)
  builds << ['mrb_int 64, full-core', full, ENV.fetch('MRBC'), flags, true] if full
  builds << ['mrb_int 64, core-only', runtime.core, ENV.fetch('MRBC'), flags, false] if runtime.core
  if ENV['BC2CPP_MRUBY_FULL32'] && ENV['BC2CPP_MRBC32']
    builds << ['mrb_int 32, full-core', ENV['BC2CPP_MRUBY_FULL32'], ENV['BC2CPP_MRBC32'], '-DMRB_32BIT -DMRB_INT32 -no-pie', true]
  end
end
if builds.empty?
  puts '-- SKIP run: set MRBC, BC2CPP_MRUBY_FULL (or have rake, g++ and 3rd/mruby) and have g++'
else
  puts '== fixture on real mruby, interpreted and compiled'
  scenario = <<~'CPP'
    static int scenario(mrb_state* M) {
      RClass* c = mrb_class_get(M, "IcNat");
      mrb_define_const(M, c, "NATF", mrb_float_value(M, 2.5));
      mrb_define_const(M, c, "NATN", mrb_nil_value());
      mrb_define_global_const(M, "NATS", mrb_str_new_lit(M, "s"));
      mrb_const_set(M, mrb_obj_value(c), mrb_intern_lit(M, "NATK"), mrb_float_value(M, 1.5));
      mrb_define_const(M, c, "NATI", mrb_float_value(M, 0.5));
      mrb_value use = mrb_obj_new(M, mrb_class_get(M, "IcUse"), 0, nullptr);
      static const char* calls[] = { "orm", "nat_f", "nat_n", "nat_s", "nat_k", "nat_i", "nat_lt", "other_ok", "or_c", "and_n", "and_f",
                                     "tern", "arit", "plain", "ify", "sum", "or_in" };
      for (const char* fn : calls) call(M, fn, use, fn);
      return 0;
    }
  CPP
  builds.each do |label, build, mrbc, flags, with_gems|
    puts "-- fixture on real mruby (#{label}), interpreted and compiled"
    saved = ENV.values_at('MRBC', 'BC2CPP_CXXFLAGS')
    ENV['MRBC'] = mrbc
    ENV['BC2CPP_CXXFLAGS'] = flags
    begin
      Dir.mktmpdir do |dir|
        code, gen_err = runtime.generate(HOLDER, dir, closed: true, only_owners: OWNERS, native: [['ic_native.cxx', NATIVE_TEXT]])
        registered = runtime.registrations(gen_err, OWNERS)
        check.call("#{label}: the harness registers the fixture's own classes (#{registered.size} entry points)",
                   registered.any? { |l| l.include?('"nat_f"') } && registered.any? { |l| l.include?('"plain"') })
        check.call("#{label}: the fixture's methods are compiled", code.include?('IcUse_nat_f') && code.include?('IcUse_plain'))
        built, output = runtime.run(dir, gen_err, OWNERS, scenario, build: build, full: with_gems)
        check.call("#{label}: the fixture compiles and runs against real mruby", built)
        puts output unless built
        next unless built

        sections = runtime.sections(output)
        values = ->(name) { sections.fetch(name, []).reject { |l| l.start_with?('  ') } }
        puts output if ENV['BC2CPP_CHECK_VERBOSE'] || values.call('interpreted') != values.call('compiled')
        interpreted = values.call('interpreted')
        compiled = values.call('compiled')
        check.call("#{label}: every call answers what the interpreter does (#{interpreted.size} lines)",
                   interpreted.size == 17 && interpreted == compiled)
        line = ->(lines, fn) { lines.find { |l| l.start_with?("#{fn} =>") }.to_s }
        # A core-only mruby raises the base Exception class, so there only the interpreter's own line is the pin.
        %w[nat_n nat_s and_n and_f].each do |fn|
          check.call("#{label}: #{fn} raises as the interpreter does", line.call(compiled, fn).include?('raised') && line.call(compiled, fn) == line.call(interpreted, fn))
        end
        if with_gems
          pins = { 'nat_f' => '3.5', 'nat_k' => '3.0', 'nat_i' => '-0.5', 'nat_lt' => 'true', 'or_c' => '3.5', 'orm' => '3.5', 'tern' => '3.5', 'arit' => '4.5',
                   'other_ok' => '2', 'plain' => '101', 'ify' => '101', 'sum' => '102', 'or_in' => '3.5',
                   'nat_n' => 'raised NoMethodError', 'nat_s' => 'raised TypeError', 'and_n' => 'raised NoMethodError', 'and_f' => 'raised NoMethodError' }
          pins.each { |fn, want| check.call("#{label}: #{fn} => #{want}", line.call(compiled, fn) == "#{fn} => #{want}") }
        end
      end
    ensure
      ENV['MRBC'], ENV['BC2CPP_CXXFLAGS'] = saved
    end
  end
end

if failures.empty?
  puts 'bc2cpp integer constants check: PASS'
else
  warn "bc2cpp integer constants check: #{failures.size} failure(s)"
  exit 1
end
