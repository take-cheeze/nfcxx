#!/usr/bin/env ruby
# frozen_string_literal: true

# ADR 0305: the by-name `[]` tail of bc2cpp_getidx is an exact-class arm for a program-defined Integer#[] once the
# closed world sees that definition (mruby core has no Integer#[]; optcarrot's shim is the only one). The arm
# never invents bit-reference semantics: it calls the program's own compiled body.
#
# 1. With MRBC: the helper holds an Integer arm after the Array/Hash/String arms and keeps the by-name tail; without
#    a definer it holds no Integer arm.
# 2. With a libmruby: the shim from tools/optcarrot_probe, compiled and interpreted, answers alike over receivers
#    x keys (Fixnum edges, bigint, Float, nil, String, Array, Hash, Proc, a user class) at every width
#    available, and an Integer receiver with an Integer key makes no by-name call.
#
# Builds: BC2CPP_MRUBY_FULL (full-core), BC2CPP_MRUBY_CORE (no gems), BC2CPP_MRUBY_FULL32 + BC2CPP_MRBC32
# (-DMRB_32BIT -DMRB_INT32), BC2CPP_MRUBY_NOBIGINT (no mruby-bigint). GIA_MUTANTS=1 also runs the generator with one
# condition removed at a time, which must fail this check.
#
# Usage: MRBC=path/to/mrbc ruby scripts/bc2cpp/getidx_integer_arm_check.rb

require 'fileutils'
require 'open3'
require 'tmpdir'
require_relative 'fixture_runtime'

runtime = Bc2cppFixtureRuntime
failures = []
check = lambda do |what, condition|
  puts "  #{condition ? 'ok  ' : 'FAIL'} #{what}"
  failures << what unless condition
end

SHIM = File.read(File.join(runtime::ROOT, 'tools/optcarrot_probe/shim_integer_aref.rb'))

CLASSES = <<~RUBY
  class AtPt
    def [](k)
      [:pt, k]
    end

    def inspect
      'pt'
    end
  end

  class AtProbe
    def get(x, i)
      x[i]
    end

    def get0(x)
      x[0]
    end

    def set(x, i, v)
      x[i] = v
    end
  end
RUBY

# Top Fixnum / mrb_int per width, as literals (AGENTS.md: a computed constant that crosses 32 bits breaks irep load).
FMAX = { 64 => '4611686018427387903', 32 => '1073741823', nobig: '2147483647' }.freeze
# mrb_int max per width: a receiver beyond it is a bigint, whose bit shifts the numeric helpers own (ADR 0292).
IMAX = { 64 => 9_223_372_036_854_775_807, 32 => 2_147_483_647, nobig: 2_147_483_647 }.freeze

# Receivers and keys are built at load time from FM, so the same text runs at every width.
def driver(width)
  <<~RUBY
    FM = #{FMAX.fetch(width)}
    $big = begin
      (FM * FM * FM) > FM
    rescue RangeError
      false
    end
    IM = $big ? FM * 2 + 1 : FM
    # Unary minus lives in mrblib, which the core-only build lacks, so negatives are spelled 0 - x.
    nfm = 0 - FM
    nim = 0 - IM
    ints = [0, 1, -1, 2, -2, 5, -5, 255, -256, FM, FM - 1, nfm, nfm - 1, IM, nim, nim - 1]
    ints += [FM + 1, nfm - 2, IM + 1, nim - 2, IM * IM, 0 - IM * IM, 2 ** 100, 0 - 2 ** 100] if $big
    nan = 0.0 / 0.0
    inf = 1.0 / 0.0
    floats = [0.0, -0.0, 0.5, -1.5, 3.0, 1.0e19, nan, inf, 0.0 - inf]
    $recvs = ints + floats + [nil, 's', [1, 2, 3], { 1 => 2 }, AtPt.new, ->(k) { k }]
    counts = [0, 1, -1, 2, 5, 7, 8, 30, 31, 32, 33, 62, 63, 64, 65, 100, -2, -8, -30, -31, -32, -33, -62, -63, -64,
              -65, -100, FM, nfm, IM, nim, nim - 1]
    counts += [FM + 1, nfm - 2, IM + 1, 2 ** 100] if $big
    $keys = counts + [2.5, -2.5, 0.0, 1.0e19, nan, inf, nil, 's', :s, [1], AtPt.new]
  RUBY
end

SCENARIO = <<~'CPP'
  #include <cstring>
  #include <string>
  struct AtCall { mrb_value obj; mrb_sym mid; mrb_int argc; mrb_value argv[3]; };
  static mrb_value at_body(mrb_state* M, void* ud) {
    AtCall* c = (AtCall*)ud;
    return (mrb_funcall_argv)(M, c->obj, c->mid, c->argc, c->argv);
  }
  // inspect is deterministic for these classes; the rest are named by class.
  static std::string at_label(mrb_state* M, mrb_value v) {
    const char* cls = mrb_obj_classname(M, v);
    static const char* const plain[] = { "Integer", "Float", "NilClass", "String", "Symbol", "Array", "Hash" };
    for (const char* p : plain) {
      if (std::strcmp(cls, p) == 0) {
        mrb_value s = mrb_inspect(M, v);
        return std::string(RSTRING_PTR(s), RSTRING_LEN(s));
      }
    }
    return cls;
  }
  static std::string at_describe(mrb_state* M, mrb_value v, bool raised) {
    if (raised) {
      mrb_value msg = (mrb_funcall)(M, v, "message", 0);
      return std::string("raised ") + mrb_obj_classname(M, v) + ": " + std::string(RSTRING_PTR(msg), RSTRING_LEN(msg));
    }
    std::string out = at_label(M, v);
    // The representation (Fixnum / heap Integer / bigint) shows in Integer#hash.
    if (std::strcmp(mrb_obj_classname(M, v), "Integer") == 0) {
      mrb_value h = mrb_inspect(M, (mrb_funcall)(M, v, "hash", 0));
      out += " h=" + std::string(RSTRING_PTR(h), RSTRING_LEN(h));
    }
    return out;
  }
  static void at_row(mrb_state* M, const char* meth, mrb_value recv, mrb_value key, mrb_int argc, mrb_value argv0) {
    AtCall c = { mrb_obj_new(M, mrb_class_get(M, "AtProbe"), 0, nullptr), mrb_intern_cstr(M, meth), argc, {} };
    c.argv[0] = argv0;
    c.argv[1] = key;
    c.argv[2] = mrb_fixnum_value(7);
    int ai = mrb_gc_arena_save(M);
    dispatches = 0;
    mrb_bool raised = FALSE;
    mrb_value got = mrb_protect_error(M, at_body, &c, &raised);
    int made = dispatches;
    std::string text = at_describe(M, got, raised);
    std::printf("%s %s %s => %s\n", meth, at_label(M, recv).c_str(), at_label(M, key).c_str(), text.c_str());
    if (compiled) std::printf("  D %s %s %s %d\n", meth, at_label(M, recv).c_str(), at_label(M, key).c_str(), made);
    mrb_gc_arena_restore(M, ai);
  }
  static int scenario(mrb_state* M) {
    mrb_value recvs = mrb_gv_get(M, mrb_intern_lit(M, "$recvs"));
    mrb_value keys = mrb_gv_get(M, mrb_intern_lit(M, "$keys"));
    // Procs and Hashes of the receiver list are shared, so a stateful call would show in later rows.
    for (mrb_int i = 0; i < RARRAY_LEN(recvs); ++i) {
      mrb_value r = RARRAY_PTR(recvs)[i];
      for (mrb_int j = 0; j < RARRAY_LEN(keys); ++j) at_row(M, "get", r, RARRAY_PTR(keys)[j], 2, r);
      at_row(M, "get0", r, mrb_nil_value(), 1, r);
    }
    for (mrb_int i = 0; i < RARRAY_LEN(recvs); ++i) {
      mrb_value r = RARRAY_PTR(recvs)[i];
      if (mrb_array_p(r) || mrb_hash_p(r) || mrb_string_p(r)) continue;  // `[]=` mutates these
      for (mrb_int j = 0; j < RARRAY_LEN(keys); j += 5) at_row(M, "set", r, RARRAY_PTR(keys)[j], 3, r);
    }
    std::puts("end");
    return 0;
  }
CPP

def function_text(code, name)
  start = code.index(/^static mrb_value #{Regexp.escape(name)}\(/) or return nil
  code[start..code.index(/^\}\n/, start)]
end

def generated_checks(check, runtime)
  puts '-- generated code (closed world)'
  Dir.mktmpdir do |dir|
    code, = runtime.generate(SHIM + CLASSES, dir, closed: true, only_owners: %w[AtProbe Integer])
    getidx = function_text(code, 'bc2cpp_getidx').to_s
    arm = getidx.index(/bc2cpp_owner_class_\d+\(M\) == mrb_obj_class\(M, recv\)/)
    check.call('with Integer#[] defined, the helper has an Integer arm that calls its compiled body',
               getidx.include?('POLY_SMALL_N :[] -> Integer') && getidx.match?(/r0 = Integer_\$5b\$5d_impl\(M, recv, key\);/))
    check.call('the arm follows the Array, Hash and String arms',
               arm && getidx.index('M->string_class') && getidx.index('M->string_class') < arm)
    check.call('the by-name tail stays for every other receiver', arm && getidx[arm..].include?('bc2cpp_send(M, recv'))
  end

  Dir.mktmpdir do |dir|
    code, = runtime.generate(CLASSES, dir, closed: true, only_owners: %w[AtProbe])
    getidx = function_text(code, 'bc2cpp_getidx').to_s
    check.call('without a definer the helper invents no Integer arm (core has no Integer#[])',
               !getidx.empty? && !getidx.include?('Integer') && !getidx.include?('POLY_SMALL_N') &&
                 getidx.include?('bc2cpp_send(M, recv'))
  end
end

unless runtime.mrbc && system(runtime.mrbc, '--version', out: File::NULL, err: File::NULL)
  puts '  SKIP: no host mrbc (set MRBC); the generated-code and behavioural checks need it'
  exit 0
end

generated_checks(check, runtime)

# [label, build dir, mrbc, flags, width, full-core?]
builds = []
full = runtime.full || (ENV['BC2CPP_FULL_BUILD_DIR'] ? runtime.full_or_build : nil)
builds << ['full-core, mrb_int 64', full, ENV['MRBC'], '-DMRB_USE_BIGINT', 64, true] if full
# The core build need not be 64 bits wide, so it gets the Fixnum range every width shares and no bigint.
builds << ['core only (no gems)', runtime.core, ENV['MRBC'], '', :nobig, false] if runtime.core
if ENV['BC2CPP_MRUBY_FULL32'] && ENV['BC2CPP_MRBC32']
  builds << ['full-core, mrb_int 32 (31-bit Fixnums)', ENV['BC2CPP_MRUBY_FULL32'], ENV['BC2CPP_MRBC32'],
             '-DMRB_32BIT -DMRB_INT32 -no-pie -DMRB_USE_BIGINT', 32, true]
end
if ENV['BC2CPP_MRUBY_NOBIGINT']
  builds << ['no mruby-bigint, mrb_int 32', ENV['BC2CPP_MRUBY_NOBIGINT'], ENV['MRBC'], '', :nobig, true]
end
builds = [] unless runtime.compiler?
puts '-- SKIP run: set BC2CPP_MRUBY_FULL / BC2CPP_MRUBY_CORE / BC2CPP_MRUBY_FULL32 (and have g++)' if builds.empty?

builds.each do |label, build, mrbc, flags, width, full|
  puts "-- fixture on real mruby (#{label}), interpreted and compiled"
  saved = ENV.values_at('MRBC', 'BC2CPP_CXXFLAGS')
  ENV['MRBC'] = mrbc
  ENV['BC2CPP_CXXFLAGS'] = flags
  begin
    Dir.mktmpdir do |dir|
      _code, err = runtime.generate(SHIM + CLASSES + driver(width), dir, closed: true, only_owners: %w[AtProbe Integer])
      # Only AtProbe is registered: Integer#[] stays the interpreter's shim, so the compiled body is reached
      # through the helper's arm and nowhere else.
      built, output = runtime.run(dir, err, %w[AtProbe], SCENARIO, build: build, full: full)
      check.call('the fixture compiles and runs against real mruby', built)
      puts output.to_s.lines.last(25).join unless built
      next unless built

      sections = runtime.sections(output)
      interpreted = sections['interpreted'].to_a
      compiled = sections['compiled'].to_a
      strip = ->(lines) { lines.reject { |l| l.start_with?('  ') } }
      check.call('both runs finish', strip.call(interpreted).last == 'end' && strip.call(compiled).last == 'end')
      answers = strip.call(interpreted)
      check.call("the grid is large (#{answers.size} answers)", answers.size > 1500)
      same = answers == strip.call(compiled)
      check.call('every answer is the interpreter\'s: value, Float bits, Integer#hash, exception class and message', same)
      answers.zip(strip.call(compiled)).reject { |a, b| a == b }.first(8).each do |a, b|
        puts "    interpreted: #{a}\n    compiled:    #{b}"
      end
      check.call("the grid reaches exceptions (#{answers.count { |l| l.include?('raised') }})",
                 answers.count { |l| l.include?('raised') } > 100)
      check.call('bit reads are really answered (5[0] = 1, 5[1] = 0, 5[2] = 1)',
                 ['get 5 0 => 1 h=', 'get 5 1 => 0 h=', 'get 5 2 => 1 h='].all? { |p| answers.any? { |l| l.start_with?(p) } })
      if width == :nobig
        check.call('without mruby-bigint an overflow is a RangeError', answers.any? { |l| l.include?('RangeError') })
      end

      # An Integer receiver with an Integer key reaches the shim through the helper's arm: no by-name call. A
      # negative count shifts left and a count of 200 bits and more is out of range; the shift helpers (ADR 0292)
      # own what those do.
      int_rows = compiled.filter_map do |l|
        m = l.match(/\A  D get (-?\d+) (-?\d+) (\d+)\z/)
        m if m && m[2].to_i.between?(0, 199) && m[1].to_i.abs <= IMAX.fetch(width)
      end
      stray = int_rows.reject { |m| m[3] == '0' }
      check.call("an Integer receiver with an Integer key makes no by-name call (#{int_rows.size} rows)",
                 int_rows.size > 100 && stray.empty?)
      stray.first(5).each { |m| puts "    dispatched: #{m[0].strip}" }
      # The arm is exact-class: every other receiver still reaches the by-name tail or its fast arm.
      other = compiled.grep(/\A  D get (nil|-?\d+\.\d+\S*|NaN|Infinity|-Infinity|AtPt|Proc) /)
      check.call("nil, Float, Proc and the user class keep the by-name tail (#{other.size} rows)",
                 other.size > 100 && other.all? { |l| l.split.last.to_i >= 1 })
    end
  ensure
    ENV['MRBC'], ENV['BC2CPP_CXXFLAGS'] = saved
  end
end

# Each mutant is a copy of tools/bc2cpp with one condition of the arm broken; this script, run against it through
# BC2CPP_TOOL, must fail. A survivor means the condition has no negative case.
MUTANTS = [
  ['the exact-class guard is dropped (every receiver takes the arm)', 'codegen_ivar_poly.rb',
   '"#{owner_class_ptr_expr(owner)} == #{recv_class}"', '"1"'],
  ['the arm tests the wrong class (Integer receivers keep the by-name tail)', 'codegen_ivar_poly.rb',
   '"#{owner_class_ptr_expr(owner)} == #{recv_class}"', '"M->float_class == #{recv_class}"']
].freeze

if ENV['GIA_MUTANTS'] && ENV['BC2CPP_TOOL'].nil? && !builds.empty?
  puts '-- mutants'
  require_relative 'mutant_pool'
  # nil when the mutation site is gone, else the run of this check against the mutant.
  mutate = lambda do |(_name, file, pattern, replacement)|
    Dir.mktmpdir do |dir|
      Bc2cppMutantPool.copy_generator(runtime::ROOT, dir)
      path = File.join(dir, 'bc2cpp', file)
      text = File.read(path)
      next nil unless text.include?(pattern)

      File.write(path, text.sub(pattern) { replacement })
      # Stops at the first FAIL line: the mutant is killed (Bc2cppMutantPool.run).
      Bc2cppMutantPool.run({ 'BC2CPP_TOOL' => File.join(dir, 'bc2cpp', 'bc2cpp.rb'), 'GIA_MUTANTS' => nil },
                           [RbConfig.ruby, __FILE__], stop_on: /^\s+FAIL /)
    end
  end
  Bc2cppMutantPool.each_ordered(MUTANTS, work: mutate) do |(name), run|
    if run.nil?
      check.call("mutation site exists for: #{name}", false)
      next
    end
    check.call("mutant killed: #{name}", !run.success && run.out.match?(/^\s+FAIL /))
    run.out.lines.grep(/^\s+FAIL /).first(3).each { |l| puts "       #{l.strip}" }
  end
end

if failures.empty?
  puts 'bc2cpp getidx integer arm check: PASS'
else
  warn "bc2cpp getidx integer arm check: #{failures.size} failure(s)"
  exit 1
end
