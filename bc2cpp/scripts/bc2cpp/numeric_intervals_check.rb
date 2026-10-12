#!/usr/bin/env ruby
# frozen_string_literal: true

# Check NUMERIC_INTERVAL_OPERANDS (docs/adr/0326): the interval proof of ADR 0318 also vouches for the operands of
# Fixnum-proof consumers. `HEAD + 1` with `HEAD = LINE + B * 2` (not an IntegerConstants name: MUL), `HEAD * 3 + COLS - 2`
# and an Array index that is such an expression lose their tag test and the `[]`/slow-helper else.
#
# 1. Generated code (needs MRBC): positives lose the test; negatives keep it (a parameter, a constant above 32 bits,
#    a Float constant, an arithmetic result of an unproven operand, a non-exact Array receiver, an index parameter);
#    withdrawal worlds (a reopened String constant, a native definition, const_set, a redefined Integer#+, the open
#    world) and both kill switches keep the tests. NI_GENERATED_ONLY=1 stops here (what the mutation check runs).
# 2. Behaviour on real mruby: the fixture runs interpreted and compiled and must answer alike (values and exceptions),
#    full-core, core-only and 32-bit mrb_int (BC2CPP_MRUBY_FULL32 + BC2CPP_MRBC32).
#
# Usage: [MRBC=path/to/mrbc BC2CPP_MRUBY_FULL=dir BC2CPP_MRUBY_CORE=dir BC2CPP_MRUBY_FULL32=dir BC2CPP_MRBC32=mrbc32]
#        ruby scripts/bc2cpp/numeric_intervals_check.rb

require 'fileutils'
require 'tmpdir'
require_relative 'fixture_runtime'

failures = []
check = lambda do |what, condition|
  puts "  #{condition ? 'ok  ' : 'FAIL'} #{what}"
  failures << what unless condition
end

runtime = Bc2cppFixtureRuntime

HOLDER = <<~RUBY
  class NiCons
    W = 320
    LINE = 16
    B = 4
    HEAD = LINE + B * 2
    COLS = W / LINE + 1
    BIG = 3_000_000_000
    FLT = 2.5

    # -- positives
    def add_c; HEAD + 1; end
    def sub_c; COLS - HEAD; end
    def chain; HEAD * 3 + COLS - 2; end
    def cmp_c; HEAD < COLS; end
    def idx_c; a = [10, 20, 30]; a[HEAD - 22]; end
    def idx_set; a = [10, 20, 30]; a[HEAD - 23] = 7; a; end
    def idx_lit; a = [10, 20, 30]; a[1]; end

    # -- negatives
    def add_p(x); HEAD + x; end
    def add_big; BIG + 1; end
    def add_flt; FLT + 1; end
    def unproven_chain(x); (x + 1) + 2; end
    def idx_param(a); a[HEAD - 22]; end
    def idx_arg(i); a = [10, 20, 30]; a[i]; end
    def idx_flt; a = [10, 20, 30]; a[FLT]; end
  end
RUBY

OWNERS = %w[NiCons].freeze
POSITIVES = %w[add_c sub_c chain cmp_c].freeze
INDEX_POSITIVES = %w[idx_c idx_set idx_lit].freeze
NEGATIVES = %w[add_p add_big add_flt unproven_chain].freeze
INDEX_NEGATIVES = %w[idx_param idx_arg idx_flt].freeze

body_of = lambda do |code, fn|
  code.scan(/^(?:static )?mrb_value NiCons_#{fn}(?:_\w*?)?_impl\w*\(mrb_state\* M.*?(?=^(?:static )?mrb_value \w+\(mrb_state\* M|\z)/m).join
end
live_of = lambda do |code, fn|
  body_of.call(code, fn).lines.reject { |l| l.lstrip.start_with?('//') }.join
end
# No runtime check and no by-name or slow-helper else.
proven = lambda do |code, fn|
  live = live_of.call(code, fn)
  !live.empty? && body_of.call(code, fn).include?('operands proven Fixnum') && !live.include?('bc2cpp_slow_') && !live.include?('bc2cpp_send(')
end
proven_index = lambda do |code, fn|
  live = live_of.call(code, fn)
  !live.empty? && body_of.call(code, fn).include?('NUMERIC_INTERVAL_OPERANDS') && !live.include?('mrb_integer_p(') && !live.include?('bc2cpp_send(')
end
kept = lambda do |code, fn|
  live = live_of.call(code, fn)
  !live.empty? && !body_of.call(code, fn).include?('operands proven Fixnum') && live.include?('mrb_fixnum_p(')
end
kept_index = lambda do |code, fn|
  live = live_of.call(code, fn)
  !live.empty? && !body_of.call(code, fn).include?('NUMERIC_INTERVAL_OPERANDS') && (live.include?('mrb_integer_p(') || live.include?('bc2cpp_getidx('))
end
# The whole fixture's proven sites, as one list of [label, lambda-result] for the worlds below.
all_proven = lambda do |code|
  POSITIVES.all? { |fn| proven.call(code, fn) } && INDEX_POSITIVES.all? { |fn| proven_index.call(code, fn) }
end
none_proven = lambda do |code|
  POSITIVES.none? { |fn| body_of.call(code, fn).include?('operands proven Fixnum') && proven.call(code, fn) } &&
    %w[idx_c idx_set].none? { |fn| body_of.call(code, fn).include?('NUMERIC_INTERVAL_OPERANDS') }
end

generate = lambda do |source, dir, env: {}, **options|
  saved = env.to_h { |k, _| [k, ENV.fetch(k, nil)] }
  env.each { |k, v| ENV[k] = v }
  begin
    runtime.generate(source, dir, only_owners: OWNERS, **options)
  ensure
    saved.each { |k, v| v ? ENV[k] = v : ENV.delete(k) }
  end
end

# -- 1. generated code -----------------------------------------------------------------

if ENV['MRBC']
  puts '== generated code'
  Dir.mktmpdir do |dir|
    code, = generate.call(HOLDER, dir)
    POSITIVES.each { |fn| check.call("#{fn}: the arithmetic has no tag test, no slow helper", proven.call(code, fn)) }
    INDEX_POSITIVES.each { |fn| check.call("#{fn}: the Array index has no integer test and no `[]` else", proven_index.call(code, fn)) }
    NEGATIVES.each { |fn| check.call("NEG #{fn}: keeps the tag test", kept.call(code, fn)) }
    INDEX_NEGATIVES.each { |fn| check.call("NEG #{fn}: keeps the integer test", kept_index.call(code, fn)) }

    variants = [
      ['a reopened constant bound to a String', "class NiCons\n  LINE = 'wide'\nend\n", {}],
      ['a native source defining the constant', '',
       { native: [['ni_def.cxx', "static void ni_def(mrb_state* M, RClass* c) { mrb_define_const(M, c, \"B\", mrb_float_value(M, 1.5)); }\n"]] }],
      ['const_set', "class NiSet\n  def go(k); k.const_set(:ZZ, 1); end\nend\n", {}],
      ['a redefined Integer#+', "class Integer\n  def +(o); 7; end\nend\n", {}],
      ['a const_missing', "class NiCons\n  def self.const_missing(n); 1.5; end\nend\n", {}]
    ]
    variants.each do |what, extra, options|
      d = File.join(dir, what.gsub(/\W+/, '_'))
      Dir.mkdir(d)
      vcode, = generate.call(HOLDER + extra, d, **options)
      check.call("NEG #{what}: no operand is vouched for by an interval", none_proven.call(vcode))
    end

    Dir.mktmpdir do |open_dir|
      open_code, = generate.call(HOLDER, open_dir, closed: false)
      check.call('the open world proves nothing', none_proven.call(open_code))
    end
    { 'BC2CPP_NUMERIC_INTERVALS' => 'the interval operands kill switch', 'BC2CPP_NUMERIC_CONSTANTS' => 'the constant ranges kill switch' }.each do |var, what|
      Dir.mktmpdir do |off_dir|
        off_code, = generate.call(HOLDER, off_dir, env: { var => '0' })
        check.call("#{what} (#{var}=0): every site keeps its test", none_proven.call(off_code) &&
                   (INDEX_POSITIVES - %w[idx_lit]).none? { |fn| proven_index.call(off_code, fn) } &&
                   (var == 'BC2CPP_NUMERIC_CONSTANTS' || INDEX_POSITIVES.none? { |fn| proven_index.call(off_code, fn) }))
      end
    end
  end
else
  puts '-- SKIP generated code: set MRBC'
end

# -- 2. behaviour ----------------------------------------------------------------------

builds = []
if ENV['MRBC'] && runtime.compiler? && !ENV['NI_GENERATED_ONLY']
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
      mrb_value c = mrb_obj_new(M, mrb_class_get(M, "NiCons"), 0, nullptr);
      static const char* plain[] = { "add_c", "sub_c", "chain", "cmp_c", "idx_c", "idx_set", "idx_lit", "add_big", "add_flt", "idx_flt" };
      for (const char* fn : plain) call(M, fn, c, fn);
      mrb_value i = mrb_fixnum_value(2), f = mrb_float_value(M, 1.5), s = mrb_str_new_lit(M, "s"), n = mrb_nil_value();
      call(M, "add_p int", c, "add_p", 1, &i);
      call(M, "add_p float", c, "add_p", 1, &f);
      call(M, "add_p string", c, "add_p", 1, &s);
      call(M, "add_p nil", c, "add_p", 1, &n);
      call(M, "unproven_chain int", c, "unproven_chain", 1, &i);
      call(M, "unproven_chain float", c, "unproven_chain", 1, &f);
      call(M, "idx_arg int", c, "idx_arg", 1, &i);
      call(M, "idx_arg float", c, "idx_arg", 1, &f);
      call(M, "idx_arg nil", c, "idx_arg", 1, &n);
      mrb_value ary = mrb_ary_new(M);
      mrb_ary_push(M, ary, mrb_fixnum_value(5));
      mrb_ary_push(M, ary, mrb_fixnum_value(6));
      mrb_ary_push(M, ary, mrb_fixnum_value(8));
      mrb_value h = mrb_hash_new(M);
      mrb_hash_set(M, h, mrb_fixnum_value(2), mrb_fixnum_value(99));
      call(M, "idx_param array", c, "idx_param", 1, &ary);
      call(M, "idx_param hash", c, "idx_param", 1, &h);
      call(M, "idx_param string", c, "idx_param", 1, &s);
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
        # A core-only mruby has no bigint: its 32-bit Integer cannot hold a 3_000_000_000 literal at all.
        source = with_gems ? HOLDER : HOLDER.gsub('3_000_000_000', '2_000_000_000')
        code, gen_err = runtime.generate(source, dir, closed: true, only_owners: OWNERS)
        registered = runtime.registrations(gen_err, OWNERS)
        check.call("#{label}: the harness registers the fixture's own class (#{registered.size} entry points)",
                   registered.any? { |l| l.include?('"add_c"') } && registered.any? { |l| l.include?('"idx_param"') })
        check.call("#{label}: the proven sites are in the compiled code", all_proven.call(code))
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
                   interpreted.size == 22 && interpreted == compiled)
        line = ->(fn) { compiled.find { |l| l.start_with?("#{fn} =>") }.to_s }
        # A core-only mruby raises the base Exception class, so there only the interpreter's own line is the pin.
        ['add_p string', 'add_p nil', 'idx_arg nil'].each do |fn|
          want = interpreted.find { |l| l.start_with?("#{fn} =>") }
          check.call("#{label}: #{fn} raises as the interpreter does", line.call(fn).include?('raised') && line.call(fn) == want)
        end
        pins = { 'add_c' => '25', 'sub_c' => '-3', 'chain' => '91', 'cmp_c' => 'false', 'idx_c' => '30', 'idx_set' => '[10, 7, 30]',
                 'idx_lit' => '20', 'add_flt' => '3.5', 'add_p int' => '26', 'add_p float' => '25.5', 'idx_arg int' => '30',
                 'idx_param array' => '8', 'idx_param hash' => '99' }
        pins.each { |fn, want| check.call("#{label}: #{fn} => #{want}", line.call(fn) == "#{fn} => #{want}") }
        lines = sections.fetch('compiled', [])
        %w[add_c sub_c chain cmp_c idx_c idx_set idx_lit].each do |m|
          at = lines.index { |l| l.start_with?("#{m} =>") }
          n = at && lines[at + 1].to_s[/dispatches=(\d+)/, 1]&.to_i
          check.call("#{label}: #{m}: the compiled call makes no dynamic dispatch", n == 0)
        end
      end
    ensure
      ENV['MRBC'], ENV['BC2CPP_CXXFLAGS'] = saved
    end
  end
end

if failures.empty?
  puts 'bc2cpp numeric intervals check: PASS'
else
  warn "bc2cpp numeric intervals check: #{failures.size} failure(s)"
  exit 1
end
