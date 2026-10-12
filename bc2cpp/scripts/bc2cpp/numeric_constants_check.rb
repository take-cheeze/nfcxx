#!/usr/bin/env ruby
# frozen_string_literal: true

# Check NUMERIC_CONSTANT_RANGES and NATIVE_INT_ARGS (docs/adr/0318): an `RGSS::Bitmap.new(w, h)` whose arguments are
# provably Fixnums (a constant, an arithmetic expression of constants whose interval fits the narrowest target Fixnum,
# a local copy of either) has no `mrb_integer_p` test and no by-name `new` else.
#
# 1. Generated code (needs MRBC): positives lose the test; negatives keep it (a parameter, a constant above 32 bits, a
#    Float constant, an arithmetic join, a constant that is not assigned yet, an interval that overflows); every
#    withdrawal world (a reopened constant bound to a String, a reassignment out of range, const_set, remove_const, a
#    native or foreign Ruby definition, const_missing, a module named like the constant, a same-named constant of
#    another class out of range, a redefined Integer#*, the open world, the kill switch) keeps the tests it must.
#    The diagnostic lists the intervals. NC_GENERATED_ONLY=1 stops here (what the mutation check runs).
# 2. Behaviour on real mruby: the fixture runs interpreted and compiled against a stand-in for rgss::bitmap_new_direct
#    (the real one needs SDL) and must record the same constructor arguments and raise alike, while the proven methods
#    make no dynamic dispatch; every proven constant's interpreted value lies in its interval. Run it on a full-core and
#    a core-only mruby, and on a 32-bit mrb_int build (BC2CPP_MRUBY_FULL32 + BC2CPP_MRBC32).
#
# Usage: [MRBC=path/to/mrbc BC2CPP_MRUBY_FULL=dir BC2CPP_MRUBY_CORE=dir BC2CPP_MRUBY_FULL32=dir BC2CPP_MRBC32=mrbc32]
#        ruby scripts/bc2cpp/numeric_constants_check.rb

require 'fileutils'
require 'tmpdir'
require_relative 'fixture_runtime'

# This check owns the Fixnum proof's tag-test machinery (ADR 0318); ADR 0372's unboxing converts the second argument of
# Bitmap.new instead of testing it (scripts/bc2cpp/native_param_unbox_check.rb), so it is off here.
ENV['BC2CPP_NATIVE_PARAM_UNBOX'] = '0'

failures = []
check = lambda do |what, condition|
  puts "  #{condition ? 'ok  ' : 'FAIL'} #{what}"
  failures << what unless condition
end

runtime = Bc2cppFixtureRuntime

HOLDER = <<~RUBY
  module RGSS
    class Bitmap; def initialize(*); end; end
  end

  class NcCons
    W = 320
    H = 240
    B = 4
    LINE = 16
    HEAD = LINE + B * 2
    COLS = W / LINE + 1
    ROWS = H / LINE + 1
    NEG = -5
    ZERO = 0
    ONE = 1
    SCALE = (W - H) * 3 - 2
    SHARED = 8
    BIG = 3_000_000_000
    FLT = 2.5
    LATE = 5 if [].size > 0
    DIVR = 3
    # A jump lands on the SETCONST: the register is `false` on one path, the literal on the other.
    ANDC = [].size > 0 && 1
    QQ = 1_000_000_000 / DIVR

    # -- positives
    def lit; RGSS::Bitmap.new(W, H); 1; end
    def arith; RGSS::Bitmap.new(W - B * 2, HEAD * 3); 1; end
    def divs; RGSS::Bitmap.new(COLS * LINE, H / 8 - 1); 1; end
    def neg; RGSS::Bitmap.new(NEG + 10, ZERO + ONE); 1; end
    def local; w = W - 2; RGSS::Bitmap.new(w, w * 2); 1; end
    def shared; RGSS::Bitmap.new(SHARED * 2, 1); 1; end
    def scale; RGSS::Bitmap.new(SCALE, ONE); 1; end
    def cols; RGSS::Bitmap.new(COLS, ROWS); 1; end
    # One argument is proven, the other keeps its test.
    def partial(x); RGSS::Bitmap.new(W, x); 1; end

    # -- negatives
    def param(x); RGSS::Bitmap.new(x, 1); 1; end
    def big; RGSS::Bitmap.new(BIG, 1); 1; end
    def flt; RGSS::Bitmap.new(FLT, 1); 1; end
    def join(c); x = c ? W - 1 : H - 1; RGSS::Bitmap.new(x, 1); 1; end
    def late; RGSS::Bitmap.new(LATE, 1); 1; end
    def wide; RGSS::Bitmap.new(W * W * W * W, 1); 1; end
    # The divisor's hull [-2, 3] holds 0: no quotient interval.
    def qq; RGSS::Bitmap.new(QQ, 1); 1; end
    def andc; RGSS::Bitmap.new(ANDC, 1); 1; end
    # The use sits in a protected range, which is compiled apart from the code that wrote `w`.
    def guarded; w = W - 1; begin; RGSS::Bitmap.new(w, 1); rescue NameError; 0; end; 1; end
  end
  class NcDiv; DIVR = -2; end

  # `Scene::Map::TILE = Game::TILE` reads a value of its own name.
  module NcG; TILE2 = 16; end
  class NcMap
    TILE2 = NcG::TILE2
    def tile2; RGSS::Bitmap.new(TILE2 * 2, TILE2); 1; end
  end

  # The same bare name in two classes: the hull of both values is what a read can see.
  class NcP2; T = 10; end
  class NcQ2; T = 20; end
  class NcUse2; def shadow_ok; RGSS::Bitmap.new(NcP2::T + 1, 1); 1; end; end
  class NcP; S = 10; end
  class NcQ; S = 3_000_000_000; end
  class NcUse; def shadow_bad; RGSS::Bitmap.new(NcP::S + 1, 1); 1; end; end
  class NcOther; SHARED = 8000; end
RUBY

OWNERS = HOLDER.scan(/^\s*class (Nc\w+)/).flatten.freeze

POSITIVES = [%w[NcMap tile2], %w[NcCons late], %w[NcCons lit], %w[NcCons arith], %w[NcCons divs], %w[NcCons neg], %w[NcCons local], %w[NcCons shared],
             %w[NcCons scale], %w[NcCons cols], %w[NcUse2 shadow_ok]].freeze
NEGATIVES = [%w[NcCons param], %w[NcCons big], %w[NcCons flt], %w[NcCons join], %w[NcCons wide], %w[NcCons qq], %w[NcCons andc], %w[NcCons guarded],
             %w[NcUse shadow_bad]].freeze

body_of = lambda do |code, owner, fn|
  code.scan(/^(?:static )?mrb_value #{owner}_#{fn}(?:_\w*?)?_impl\w*\(mrb_state\* M.*?(?=^(?:static )?mrb_value \w+\(mrb_state\* M|\z)/m).join
end
live_of = lambda do |code, owner, fn|
  body_of.call(code, owner, fn).lines.reject { |l| l.lstrip.start_with?('//') }.join
end
# No tag test and no by-name `new` else: the constructor call is unconditional.
proven = lambda do |code, owner, fn|
  with_comments = body_of.call(code, owner, fn)
  live = live_of.call(code, owner, fn)
  !live.empty? && with_comments.include?('NATIVE_INT_ARGS, ADR 0318') && live.include?('rgss::bitmap_new_direct(') &&
    !live.include?('bc2cpp_send(')
end
# The by-name `new` is still there: behind a tag test, or as the plain send of a world that builds no direct constructor.
unproven = lambda do |code, owner, fn|
  live = live_of.call(code, owner, fn)
  !live.empty? && !body_of.call(code, owner, fn).include?('NATIVE_INT_ARGS, ADR 0318') && live.include?('bc2cpp_send(')
end
kept = lambda do |code, owner, fn|
  live = live_of.call(code, owner, fn)
  !live.empty? && body_of.call(code, owner, fn).include?('Argument tags checked first') && live.include?('bc2cpp_send(')
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
    code, err = generate.call(HOLDER, dir)

    POSITIVES.each { |owner, fn| check.call("#{owner}##{fn}: Bitmap.new has no tag test and no by-name else", proven.call(code, owner, fn)) }
    NEGATIVES.each { |owner, fn| check.call("NEG #{owner}##{fn}: keeps the tag test and the else", kept.call(code, owner, fn)) }
    partial = body_of.call(code, 'NcCons', 'partial')
    tested = partial[/Argument tags checked first \((.*?)\), falling back/, 1].to_s
    check.call('NcCons#partial: only the unproven argument is tested', tested.scan('mrb_integer_p(').size == 1 && !tested.include?('&&'))
    ranges = err.lines.grep(/^  CONST_RANGE /).to_h { |l| _, name, lo, hi = l.split; [name, [lo.to_i, hi.to_i]] }
    check.call('the diagnostic lists the intervals (literal, ADD, MUL, DIV, hull of two definitions)',
               ranges['W'] == [320, 320] && ranges['HEAD'] == [24, 24] && ranges['COLS'] == [21, 21] && ranges['NEG'] == [-5, -5] &&
               ranges['SCALE'] == [238, 238] && ranges['SHARED'] == [8, 8000] && ranges['T'] == [10, 20])
    check.call('a constant above 32 bits, a Float, a quotient by an interval holding 0 and a never-evaluated name have no interval',
               !ranges.key?('BIG') && !ranges.key?('FLT') && !ranges.key?('S') && !ranges.key?('QQ') && !ranges.key?('ANDC') && ranges['DIVR'] == [-2, 3])
    check.call('a constant that reads its own bare name keeps the interval of its other definitions', ranges['TILE2'] == [16, 16])

    # [what, extra source, options, probes that must keep the test, probes that must stay proven]
    all = POSITIVES.reject { |owner, _| owner == 'NcUse2' }
    variants = [
      ['a reopened constant bound to a String', "class NcCons\n  W = 'wide'\nend\n", {},
       [%w[NcCons lit], %w[NcCons arith], %w[NcCons divs], %w[NcCons local], %w[NcCons cols]], [%w[NcCons neg], %w[NcCons shared]]],
      ['a reassigned Integer constant keeps its hull', "class NcCons\n  B = 400\nend\n", {}, [], [%w[NcCons arith], %w[NcCons lit]]],
      ['a reassignment out of range', "class NcCons\n  B = 600_000_000\nend\n", {}, [%w[NcCons arith]], [%w[NcCons lit], %w[NcCons neg]]],
      ['const_set', "class NcSet\n  def go(k); k.const_set(:ZZ, 1); end\nend\n", {}, all, []],
      ['remove_const', "class NcRm\n  def go(k); k.remove_const(:W); end\nend\n", {}, all, []],
      ['a native source defining the constant', '', { native: [['nc_def.cxx', "static void nc_def(mrb_state* M, RClass* c) { mrb_define_const(M, c, \"H\", mrb_float_value(M, 1.5)); }\n"]] },
       [%w[NcCons lit], %w[NcCons divs], %w[NcCons scale]], [%w[NcCons arith], %w[NcCons neg], %w[NcCons shared]]],
      ['a foreign Ruby source defining the constant', '', { foreign: [['nc_foreign.rb', "B = 1.5\n"]] },
       [%w[NcCons arith]], [%w[NcCons lit], %w[NcCons shared], %w[NcCons neg]]],
      # The closed world reads the build gems' sources; the constant analysis reads the outside source lists.
      ['a build gem whose Ruby calls const_set', '', { gem: ['nc_ruby_gem', { 'mrblib/nc.rb' => "def nc_cs(k); k.const_set(:W, 'x'); end\n" }] }, all, []],
      ['a build gem whose native code sets a computed constant name', '',
       { gem: ['nc_native_gem', { 'src/nc.cxx' => "static void nc_cs(mrb_state* M, RClass* c, const char* n) { mrb_const_set(M, mrb_obj_value(c), mrb_intern_cstr(M, n), mrb_float_value(M, 1.5)); }\n" }] },
       all, []],
      ['a build gem whose native code sets W', '',
       { gem: ['nc_named_gem', { 'src/nc.cxx' => "static void nc_cs(mrb_state* M, RClass* c) { mrb_const_set(M, mrb_obj_value(c), mrb_intern_cstr(M, \"W\"), mrb_float_value(M, 1.5)); }\n" }] },
       [%w[NcCons lit], %w[NcCons arith], %w[NcCons divs], %w[NcCons local], %w[NcCons cols]], [%w[NcCons neg], %w[NcCons shared]]],
      ['a const_missing', "class NcCons\n  def self.const_missing(n); 1.5; end\nend\n", {}, all, []],
      ['a module named like the constant', "module B; end\n", {}, [%w[NcCons arith]], [%w[NcCons lit], %w[NcCons neg]]],
      ['a redefined Integer#*', "class Integer\n  def *(o); 7; end\nend\n", {},
       all, []]
    ]
    variants.each do |what, extra, options, guarded, stay|
      d = File.join(dir, what.gsub(/\W+/, '_'))
      Dir.mkdir(d)
      gem = options[:gem]
      options = options.except(:gem)
      if gem
        gem_path = File.join(d, gem[0])
        gem[1].each { |rel, text| FileUtils.mkdir_p(File.dirname(File.join(gem_path, rel))) && File.write(File.join(gem_path, rel), text) }
        options[:build_gems] = [[gem[0], gem_path]]
        # What the closed world scans (the gem) is also an outside source of the constant analysis.
        gem[1].each do |rel, text|
          key = rel.end_with?('.rb') ? :foreign : :native
          options[key] = (options[key] || []) + [["#{gem[0]}_#{File.basename(rel)}", text]]
        end
      end
      vcode, = generate.call(HOLDER + extra, d, **options)
      guarded.each { |owner, fn| check.call("NEG #{what}: #{owner}##{fn} keeps its tag test", unproven.call(vcode, owner, fn)) }
      stay.each { |owner, fn| check.call("#{what}: #{owner}##{fn} stays proven", proven.call(vcode, owner, fn)) }
    end

    Dir.mktmpdir do |open_dir|
      open_code, = generate.call(HOLDER, open_dir, closed: false)
      check.call('the open world proves nothing', POSITIVES.all? { |owner, fn| unproven.call(open_code, owner, fn) })
    end
    Dir.mktmpdir do |off_dir|
      off_code, off_err = generate.call(HOLDER, off_dir, env: { 'BC2CPP_NUMERIC_CONSTANTS' => '0' })
      check.call('the kill switch (BC2CPP_NUMERIC_CONSTANTS=0): the old tag test on every positive',
                 POSITIVES.all? { |owner, fn| kept.call(off_code, owner, fn) } && !off_code.include?('NATIVE_INT_ARGS, ADR 0318'))
      check.call('the kill switch lists no interval', off_err.lines.grep(/^  CONST_RANGE /).empty?)
    end
  end
else
  puts '-- SKIP generated code: set MRBC'
end

# -- 2. behaviour ----------------------------------------------------------------------

# [label, build dir, host mrbc, extra compiler flags, full-core?]
builds = []
if ENV['MRBC'] && runtime.compiler? && !ENV['NC_GENERATED_ONLY']
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
  # The stand-in records what the constructor received; the interpreter reaches the same record through a native
  # Bitmap#initialize, the compiled fallback of a kept tag test through Class#new into it.
  scenario = <<~'CPP'
    #include <string>
    static mrb_state* nc_M = nullptr;
    static std::string nc_log;
    static std::string nc_show(mrb_state* M, mrb_value v) {
      if (mrb_integer_p(v)) return std::to_string((long long)mrb_integer(v));
      return std::string("<") + mrb_obj_classname(M, v) + ">";
    }
    namespace rgss {
    RClass* native_bitmap_class(void) { return mrb_class_get_under(nc_M, mrb_module_get(nc_M, "RGSS"), "Bitmap"); }
    mrb_value bitmap_new_direct(mrb_state* M, RClass* klass, mrb_int w, mrb_int h) {
      nc_log += "Bitmap#initialize(" + std::to_string((long long)w) + "," + std::to_string((long long)h) + ");";
      return mrb_obj_value(mrb_obj_alloc(M, MRB_TT_OBJECT, klass));
    }
    }  // namespace rgss
    static mrb_value nc_init(mrb_state* M, mrb_value) {
      const mrb_value* argv;
      mrb_int argc;
      mrb_get_args(M, "*", &argv, &argc);
      nc_log += "Bitmap#initialize(";
      for (mrb_int i = 0; i < argc; ++i) nc_log += (i ? "," : "") + nc_show(M, argv[i]);
      nc_log += ");";
      return mrb_nil_value();
    }
    static void nc_call(mrb_state* M, const char* label, mrb_value obj, const char* meth, int argc = 0,
                        const mrb_value* argv = nullptr) {
      dispatches = 0;
      nc_log.clear();
      mrb_value r = (mrb_funcall_argv)(M, obj, mrb_intern_cstr(M, meth), argc, argv);
      int made = dispatches;
      if (M->exc) show_exc(M, label);
      else std::printf("%s => %s log=%s\n", label, nc_show(M, r).c_str(), nc_log.c_str());
      if (compiled) std::printf("  dispatches=%d\n", made);
    }
    static int scenario(mrb_state* M) {
      nc_M = M;
      mrb_define_method(M, mrb_class_get_under(M, mrb_module_get(M, "RGSS"), "Bitmap"), "initialize", nc_init, MRB_ARGS_ANY());
      mrb_value cons = mrb_obj_new(M, mrb_class_get(M, "NcCons"), 0, nullptr);
      static const char* plain[] = { "lit", "arith", "divs", "neg", "local", "shared", "scale", "cols", "big", "flt", "late", "wide", "qq", "andc", "guarded" };
      for (const char* fn : plain) nc_call(M, fn, cons, fn);
      mrb_value x = mrb_fixnum_value(7);
      nc_call(M, "partial int", cons, "partial", 1, &x);
      mrb_value f = mrb_float_value(M, 2.5);
      nc_call(M, "partial float", cons, "partial", 1, &f);
      nc_call(M, "param int", cons, "param", 1, &x);
      nc_call(M, "param float", cons, "param", 1, &f);
      mrb_value t = mrb_true_value(), fl = mrb_false_value();
      nc_call(M, "join true", cons, "join", 1, &t);
      nc_call(M, "join false", cons, "join", 1, &fl);
      nc_call(M, "shadow_ok", mrb_obj_new(M, mrb_class_get(M, "NcUse2"), 0, nullptr), "shadow_ok");
      nc_call(M, "shadow_bad", mrb_obj_new(M, mrb_class_get(M, "NcUse"), 0, nullptr), "shadow_bad");
      nc_call(M, "tile2", mrb_obj_new(M, mrb_class_get(M, "NcMap"), 0, nullptr), "tile2");
      static const char* consts[] = { "W", "H", "B", "LINE", "HEAD", "COLS", "ROWS", "NEG", "ZERO", "ONE", "SCALE", "SHARED" };
      for (const char* name : consts) {
        mrb_value v = mrb_const_get(M, mrb_obj_value(mrb_class_get(M, "NcCons")), mrb_intern_cstr(M, name));
        std::printf("const %s = %s\n", name, nc_show(M, v).c_str());
      }
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
        # A core-only mruby has no bigint: its 32-bit Integer cannot hold a 3_000_000_000 literal at all, so the constants that
        # sit above the Fixnum range take the widest value it can.
        source = with_gems ? HOLDER : HOLDER.gsub('3_000_000_000', '2_000_000_000')
        code, gen_err = runtime.generate(source, dir, closed: true, only_owners: OWNERS)
        registered = runtime.registrations(gen_err, OWNERS)
        check.call("#{label}: the harness registers the fixture's own classes (#{registered.size} entry points)",
                   registered.any? { |l| l.include?('"lit"') } && registered.any? { |l| l.include?('"shadow_ok"') })
        check.call("#{label}: the proven sites are in the compiled code", POSITIVES.all? { |owner, fn| proven.call(code, owner, fn) })
        built, output = runtime.run(dir, gen_err, OWNERS, scenario, build: build, full: with_gems)
        check.call("#{label}: the fixture compiles and runs against real mruby", built)
        puts output unless built
        next unless built

        sections = runtime.sections(output)
        values = ->(name) { sections.fetch(name, []).reject { |l| l.start_with?('  ') } }
        puts output if ENV['BC2CPP_CHECK_VERBOSE'] || values.call('interpreted') != values.call('compiled')
        interpreted = values.call('interpreted')
        compiled = values.call('compiled')
        check.call("#{label}: every call records and answers what the interpreter does (#{interpreted.size} lines)",
                   !interpreted.empty? && interpreted == compiled)
        check.call("#{label}: the arguments reach the constructor", compiled.include?('lit => 1 log=Bitmap#initialize(320,240);') &&
                   compiled.include?('arith => 1 log=Bitmap#initialize(312,72);') && compiled.include?('divs => 1 log=Bitmap#initialize(336,29);') &&
                   compiled.include?('neg => 1 log=Bitmap#initialize(5,1);') && compiled.include?('local => 1 log=Bitmap#initialize(318,636);') &&
                   compiled.include?('shadow_ok => 1 log=Bitmap#initialize(11,1);') &&
                   compiled.include?('tile2 => 1 log=Bitmap#initialize(32,16);') && compiled.include?('qq => 1 log=Bitmap#initialize(333333333,1);'))
        check.call("#{label}: a Float reaches the constructor through the kept test", compiled.include?('param float => 1 log=Bitmap#initialize(<Float>,1);') &&
                   compiled.include?('partial float => 1 log=Bitmap#initialize(320,<Float>);') && compiled.include?('flt => 1 log=Bitmap#initialize(<Float>,1);'))
        # A name that is not assigned yet raises; a core-only mruby has no mrblib, so there the check is that both sides raised.
        late = ->(lines) { lines.find { |l| l.start_with?('late =>') }.to_s }
        check.call("#{label}: a constant read before its assignment raises as the interpreter does",
                   late.call(compiled) == late.call(interpreted) && late.call(compiled).include?('raised') &&
                   (!with_gems || late.call(compiled).include?('NameError')))
        ranges = gen_err.lines.grep(/^  CONST_RANGE /).to_h { |l| _, name, lo, hi = l.split; [name, [lo.to_i, hi.to_i]] }
        const_lines = interpreted.grep(/^const /).to_h { |l| _, name, _, value = l.split; [name, value.to_i] }
        check.call("#{label}: every proven constant's value lies in its interval",
                   const_lines.size == 12 && const_lines.all? { |name, v| ranges[name] && v >= ranges[name][0] && v <= ranges[name][1] })
        lines = sections.fetch('compiled', [])
        %w[lit arith divs neg local shared scale cols shadow_ok tile2].each do |m|
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
  puts 'bc2cpp numeric constants check: PASS'
else
  warn "bc2cpp numeric constants check: #{failures.size} failure(s)"
  exit 1
end
