#!/usr/bin/env ruby
# frozen_string_literal: true

# ADR 0371: the Hash arm of the `< <= > >=` helpers calls the compiled `Hash#<` family of the run's own core
# Ruby instead of dispatching by name, where the CORE_COMPILED_DEFINERS view proves that body is the live one.
#
# 1. With MRBC: a closed world that compiles mruby's own mrblib (`core: true`) puts the compiled call in all four
#    closed helpers (an exact-Hash test in front, the by-name proof violation behind it, no by-name call of the
#    operator); the `#if` arm kept for Complex/Rational builds is unchanged; and each NEG world below (Hash#<
#    reopened or prepended, a Hash `<` installer, a user `==` that may yield, a `==` computed installer,
#    method_missing, a singleton, a build without mruby-hash-ext, an open world, no core compile, the kill
#    switch BC2CPP_CORE_COMPILED_CMP=0) keeps the by-name Hash arm of the operator it touches.
# 2. With a full-core libmruby (BC2CPP_MRUBY_FULL): each compiled helper is run against the interpreted operator
#    over Hash receivers and operands (subsets, NaN and user `==` values, default procs, subclasses, non-Hash
#    operands, nested hashes) and must give the same value or exception class and message.
#
# Usage: MRBC=path/to/mrbc [BC2CPP_MRUBY_FULL=dir] ruby scripts/bc2cpp/core_compiled_cmp_check.rb

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

OPS = { 'lt' => '<', 'le' => '<=', 'gt' => '>', 'ge' => '>=' }.freeze
OWNERS = %w[CcOpen CcBox].freeze
FIXTURE = <<~RUBY
  class CcBox
    def inspect = "box"
  end
  class CcOpen
    def lt(a, b) = a < b
    def le(a, b) = a <= b
    def gt(a, b) = a > b
    def ge(a, b) = a >= b
  end
RUBY

# The closed form of helper `key` (the `#else` arm of the Complex/Rational `#if`), or nil.
def closed_form(code, key)
  wrapped = code[/^#if defined\(MRB_USE_COMPLEX\) \|\| defined\(MRB_USE_RATIONAL\)\n(?:static mrb_value bc2cpp_slow_#{key}\(.*?^\}\n\n)#else\n(?:static mrb_value bc2cpp_slow_#{key}\(.*?^\}\n\n)#endif\n/m]
  wrapped && wrapped.split("#else\n", 2).last.sub(/#endif\n\z/, '')
end

def by_name_form(code, key)
  code[/^#if defined\(MRB_USE_COMPLEX\) \|\| defined\(MRB_USE_RATIONAL\)\n(?:static mrb_value bc2cpp_slow_#{key}\(.*?^\}\n\n)#else/m]
end

# The operators whose closed helper calls the compiled body.
def compiled_ops(code)
  OPS.keys.select { |key| (form = closed_form(code, key)) && form.include?('CORE_COMPILED_HASH_CMP') && form.include?('_impl(M, a, b)') }
end

def generate(runtime, extra: '', **opts)
  Dir.mktmpdir do |dir|
    code, err = runtime.generate("#{FIXTURE}#{extra}", dir, closed: true, only_owners: OWNERS, core: true, **opts)
    return [code, err]
  end
end

puts '-- generated code'
ALL = OPS.keys.freeze
NONE = [].freeze
REST = %w[le gt ge].freeze
code, err = generate(runtime)
check.call('POS: core compiled in a closed world: all four helpers call the compiled Hash body', compiled_ops(code) == ALL)
OPS.each do |key, op|
  form = closed_form(code, key)
  check.call("bc2cpp_slow_#{key}: exact-Hash test, proof violation for anything else, no by-name call of #{op}",
             form && form.include?('mrb_obj_ptr(a)->c != M->hash_class') && form.include?('bc2cpp_nomethod(') &&
             form.scan('bc2cpp_send(').empty? && form.scan('mrb_funcall(').empty?)
  by_name = by_name_form(code, key)
  check.call("bc2cpp_slow_#{key}: the Complex/Rational arm keeps its by-name call", by_name && by_name.include?('bc2cpp_send(') &&
             !by_name.include?('CORE_COMPILED_HASH_CMP'))
end
check.call('the compiled Hash body is declared before the helpers use it',
           code.index('mrb_value Hash_$3c_impl(mrb_state*, mrb_value, mrb_value);').to_i < code.index('static mrb_value bc2cpp_slow_lt(').to_i)

CC_WORLDS = [
  ['Hash#< reopened by the program', "class Hash\n  def <(o) = true\nend\n", REST],
  ['Hash#<= reopened by the program', "class Hash\n  def <=(o) = true\nend\n", %w[lt gt ge]],
  ['a module prepended to Hash (every Hash name is then unplain)', "module CcP\n  def >(o) = true\nend\nHash.prepend(CcP)\n", NONE],
  ['a user `==` that may yield a Fiber', "class CcY\n  def ==(o) = Fiber.yield(1)\nend\n", NONE],
  ['a module prepended to Hash that defines an unrelated name', "module CcQ\n  def cc_other = 1\nend\nHash.prepend(CcQ)\n", NONE],
  ['a computed installer on Hash', "Hash.send(:define_method, ARGV[0].to_sym) { |o| true }\n", NONE],
  ['an alias installing Hash#<', "class Hash\n  def cc_other(o) = true\n  alias_method :<, :cc_other\nend\n", REST]
].freeze
CC_WORLDS.each do |what, extra, expected|
  c, = generate(runtime, extra: extra)
  got = compiled_ops(c)
  puts "    got #{got.inspect}" unless got == expected
  check.call("#{expected == ALL ? 'POS' : 'NEG'}: #{what}: compiled Hash arm on [#{expected.join(' ')}]", got == expected)
end

c, = generate(runtime, foreign: [['cc_outside.rb', "class Hash\n  def <(o) = true\nend\n"]])
check.call('NEG: an outside Ruby source (not compiled here) that defines Hash#< takes `<` off', compiled_ops(c) == REST)

%w[BC2CPP_CORE_COMPILED_CMP].each do |var|
  saved = ENV[var]
  ENV[var] = '0'
  begin
    c, = generate(runtime)
  ensure
    ENV[var] = saved
  end
  check.call("#{var}=0 keeps the by-name Hash arm", compiled_ops(c).empty? && closed_form(c, 'lt')&.include?('bc2cpp_send('))
end

c, = generate(runtime, drop_gems: %w[mruby-hash-ext])
check.call('NEG: a build without mruby-hash-ext has no Hash definer to replace', compiled_ops(c).empty?)
c, = generate(runtime, extra: "class CcMm\n  def method_missing(n, *a) = 1\nend\n")
check.call('NEG: a method_missing class turns the closed helpers off', compiled_ops(c).empty? && closed_form(c, 'lt').nil?)
c, = generate(runtime, extra: "class CcS\n  def self.run\n    h = {}\n    def h.<(o) = true\n    h\n  end\nend\n")
check.call('NEG: a singleton method on an object (singleton-free instances unproven) keeps every by-name Hash arm', compiled_ops(c).empty?)
Dir.mktmpdir do |dir|
  c, = runtime.generate(FIXTURE, dir, closed: false, only_owners: OWNERS, core: true)
  check.call('NEG: an open world keeps the by-name helpers', compiled_ops(c).empty?)
end
Dir.mktmpdir do |dir|
  c, = runtime.generate(FIXTURE, dir, closed: true, only_owners: OWNERS, core: false)
  check.call('NEG: no core compile in the run: no compiled Hash body to call', compiled_ops(c).empty? &&
             closed_form(c, 'lt')&.include?('bc2cpp_send('))
end

# ----- run
full = runtime.full || (ENV['BC2CPP_FULL_BUILD_DIR'] ? runtime.full_or_build : nil)
if ENV['CC_GENERATED_ONLY'] == '1'
  puts '-- generated code only (mutation run)'
elsif full && runtime.compiler?
  puts '-- run (compiled helper against the interpreted operator)'
  RUN_DRIVER = <<~RUBY
    class CcNanBox
      def ==(o) = false
      def inspect = "nanbox"
    end
    class CcEq
      def initialize(v) = @v = v
      def ==(o) = o.is_a?(CcEq) && o.v == @v
      attr_reader :v
      def inspect = "eq\#{@v}"
    end
    class CcHash < Hash
    end
    $recvs = [{}, {a: 1}, {a: 1, b: 2}, {b: 1}, {a: 2}, {a: 1, b: 3}, {a: Float::NAN}, {a: CcNanBox.new}, {a: CcEq.new(1)},
              {"k" => [1, 2]}, {1 => {2 => 3}}, {nil => nil}, Hash.new(0), Hash.new { |h, k| h[k] = 1 }, {a: 1, "b" => 2, 3 => :c}]
    nan = Float::NAN
    $recvs << {a: nan}
    $vals = $recvs + [CcHash.new, CcHash[a: 1], nil, 1, 1.5, "a", :a, [1], [], 1..2, Object.new, Hash, true, {a: 1}.freeze]
    def lbl(v)
      s = v.inspect
      s.include?(':0x') ? "\#<\#{v.class}>" : s
    end
    puts 'end'
  RUBY
  SCENARIO = <<~CPP
    #include <string>
    typedef mrb_value (*CmpFn)(mrb_state*, mrb_value, mrb_value);
    struct CmpCase { const char* op; CmpFn fn; };
    static const CmpCase cmp_cases[] = { { "<", bc2cpp_slow_lt }, { "<=", bc2cpp_slow_le }, { ">", bc2cpp_slow_gt }, { ">=", bc2cpp_slow_ge } };
    struct CmpCall { const CmpCase* c; mrb_value a, b; bool method; };
    static mrb_value cmp_body(mrb_state* M, void* ud) {
      CmpCall* k = (CmpCall*)ud;
      if (k->method) return (mrb_funcall)(M, k->a, k->c->op, 1, k->b);
      return k->c->fn(M, k->a, k->b);
    }
    static std::string cmp_describe(mrb_state* M, mrb_value v, bool raised) {
      if (raised) {
        mrb_value msg = (mrb_funcall)(M, v, "message", 0);
        return std::string("raised ") + mrb_obj_classname(M, v) + ": " + std::string(RSTRING_PTR(msg), RSTRING_LEN(msg));
      }
      mrb_value s = mrb_inspect(M, v);
      return std::string(RSTRING_PTR(s), RSTRING_LEN(s));
    }
    static int scenario(mrb_state* M) {
      std::fflush(stdout);
      mrb_load_string(M, R"BCD(__SOURCE__)BCD");
      if (M->exc) { mrb_print_error(M); M->exc = nullptr; return 1; }
      mrb_value recvs = mrb_gv_get(M, mrb_intern_lit(M, "$recvs"));
      mrb_value vals = mrb_gv_get(M, mrb_intern_lit(M, "$vals"));
      int total = 0, bad = 0, hashes = 0, errors = 0, trues = 0;
      for (int round = 0; round < 3; ++round) for (const CmpCase& c : cmp_cases) for (mrb_int i = 0; i < RARRAY_LEN(recvs); ++i)
        for (mrb_int j = 0; j < RARRAY_LEN(vals); ++j) {
          mrb_value a = RARRAY_PTR(recvs)[i], b = RARRAY_PTR(vals)[j];
          int ai = mrb_gc_arena_save(M);
          CmpCall got_call = { &c, a, b, false }, want_call = { &c, a, b, true };
          mrb_bool e1 = FALSE, e2 = FALSE;
          mrb_value got = mrb_protect_error(M, cmp_body, &got_call, &e1);
          std::string g = cmp_describe(M, got, e1);
          mrb_value want = mrb_protect_error(M, cmp_body, &want_call, &e2);
          std::string w = cmp_describe(M, want, e2);
          mrb_gc_arena_restore(M, ai);
          if (round == 2) mrb_full_gc(M);
          ++total;
          if (mrb_hash_p(a)) ++hashes;
          if (e1) ++errors;
          if (!e1 && mrb_true_p(got)) ++trues;
          if (g != w) {
            ++bad;
            if (bad <= 8) std::printf("  MISMATCH %s helper=%s method=%s\\n", c.op, g.c_str(), w.c_str());
          }
        }
      std::printf("  summary %d cases, %d mismatches, %d Hash receivers, %d exceptions, %d true\\n", total, bad, hashes, errors, trues);
      return 0;
    }
  CPP
  Dir.mktmpdir do |dir|
    code, err = runtime.generate(FIXTURE, dir, closed: true, only_owners: OWNERS, core: true)
    built, output = runtime.run(dir, err, OWNERS, SCENARIO.sub('__SOURCE__', RUN_DRIVER), build: full, full: true, vms: [true])
    check.call('the run builds', built)
    summary = output.to_s[/summary (\d+) cases, (\d+) mismatches, (\d+) Hash receivers, (\d+) exceptions, (\d+) true/, 0]
    puts output.to_s.lines.select { |l| l.include?('MISMATCH') || l.include?('summary') }.first(10).join
    check.call('every compiled helper call agrees with the interpreted operator', output.to_s.include?(' 0 mismatches,'))
    check.call('the matrix has Hash receivers, exceptions and true answers',
               output.to_s =~ /(\d+) Hash receivers, (\d+) exceptions, (\d+) true/ && $1.to_i > 100 && $2.to_i > 100 && $3.to_i > 20)
  end
else
  puts '-- SKIP run: set BC2CPP_MRUBY_FULL (full-core libmruby.a) and have g++'
end

if failures.empty?
  puts 'OK'
else
  puts "FAILED: #{failures.size}"
  exit 1
end
