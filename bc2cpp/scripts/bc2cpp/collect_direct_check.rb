#!/usr/bin/env ruby
# encoding: UTF-8
# frozen_string_literal: true

# COLLECT_DIRECT (tools/bc2cpp/codegen_collect_direct.rb): `map`/`collect` on an exact Array calls bc2cpp_ary_collect
# instead of the compiled Enumerable#collect. NEQ_INTEGER_PAIR and POLY_INTEGER_TAG, which the startup also leans on,
# have their generated-code checks in array_write_inline_check.rb; this one keeps their behaviour cases.
#
#   generated code (needs a host mrbc)
#     - a literal-block `map` on an exact Array calls bc2cpp_ary_collect, and so does Array#transpose's inner map;
#     - BC2CPP_COLLECT_DIRECT=0 keeps the Enumerable#collect call;
#   behaviour (needs a full-core libmruby, see Bc2cppFixtureRuntime.full_or_build)
#     - interpreted and compiled runs print the same for map with break/next, a block that resizes its receiver,
#       destructuring, an Array subclass, nested maps, transpose, GC.stress, a Fiber, `[]` over Integer, bignum,
#       program and core receivers, and `!=` over mixed operands.
#
# Usage: MRBC=path/to/mrbc [BC2CPP_MRUBY_FULL=dir | BC2CPP_FULL_BUILD_DIR=dir] ruby scripts/bc2cpp/collect_direct_check.rb

require 'tmpdir'
require_relative 'fixture_runtime'

# The fixture is its own closed world: the repository signatures name classes it does not define.
ENV['BC2CPP_SIG_DIRS'] = ''

failures = []
check = lambda do |what, condition|
  puts "  #{condition ? 'ok  ' : 'FAIL'} #{what}"
  failures << what unless condition
end

unless Bc2cppFixtureRuntime.mrbc && system(Bc2cppFixtureRuntime.mrbc, '--version', out: File::NULL, err: File::NULL)
  puts '  SKIP: no host mrbc (set MRBC); the generated-code and behavioural checks need it'
  exit 0
end

SRC = <<~'RUBY'
  # optcarrot's shim (tools/optcarrot_probe/shim_integer_aref.rb): the full-core build has no Integer#[].
  class Integer
    def [](i)
      (self >> i) & 1
    end
  end
  class CdBox
    def [](i); i * 10; end
  end
  class CdList < Array
    def tag; :list; end
  end
  class CdEq
    def initialize(v); @v = v; end
    def v; @v; end
    def ==(other); other.is_a?(CdEq) && other.v % 10 == @v % 10; end
  end
  class CdMaps
    def squares(a); a.map { |x| x * x }; end
    def with_index(a); i = 0; a.map { |x| i += 1; [x, i] }; end
    def broke(a); a.map { |x| break :early if x == 3; x }; end
    def skipped(a); a.map { |x| next :odd if x.odd?; x }; end
    def growing(a); a.map { |x| a << x + 10 if a.size < 6; x }; end
    def shrinking(a); a.map { |x| a.pop; x }; end
    def pairs(a); a.map { |k, v| "#{k}=#{v}" }; end
    def nested(n); (0...n).to_a.map { |i| (0...n).to_a.map { |j| i * n + j } }; end
    def lut(n)
      [0, 4].map do |attr|
        (0..3).map do |j|
          (0...n).map do |i|
            clr = i[3 - j] * 2 + i[1 - j]
            clr != 0 ? attr | clr : 0
          end
        end.transpose
      end
    end
    def strings(a); a.collect { |s| s.upcase }; end
    def any(a); a.map { |x| x.to_s }; end
    def neq(a, b); a != b; end
    def bits(xs, i); xs.map { |x| x[i] }; end
  end
RUBY

OWNERS = %w[Integer CdBox CdList CdEq CdMaps].freeze

def method_code(code, name)
  code[/^mrb_value #{name}_impl\(mrb_state\* M.*?(?=^(?:static )?mrb_value \w+\(mrb_state\* M|\z)/m].to_s
end

def generate_world(env = {})
  saved = env.keys.to_h { |k| [k, ENV.fetch(k, nil)] }
  env.each { |k, v| ENV[k] = v }
  Dir.mktmpdir { |dir| Bc2cppFixtureRuntime.generate(SRC, dir, core: true, only_owners: OWNERS) }
ensure
  saved&.each { |k, v| v.nil? ? ENV.delete(k) : ENV[k] = v }
end

baseline_dir = Dir.mktmpdir('bc2cpp-collect-direct')
at_exit { FileUtils.remove_entry(baseline_dir) }
puts '-- generated code'
code, baseline_err = Bc2cppFixtureRuntime.generate(SRC, baseline_dir, core: true, only_owners: OWNERS)
check.call('a literal-block map on an Array calls bc2cpp_ary_collect',
           code.include?('static mrb_value bc2cpp_ary_collect(') && code.scan(/= bc2cpp_ary_collect\(M, /).size >= 3)
check.call("Array#transpose's inner map calls bc2cpp_ary_collect",
           method_code(code, 'Array_transpose').include?('bc2cpp_ary_collect(M, self, '))
check.call('no #error in the generated code', !code.include?('#error'))
off, = generate_world('BC2CPP_COLLECT_DIRECT' => '0')
check.call('BC2CPP_COLLECT_DIRECT=0: no bc2cpp_ary_collect', !off.include?('bc2cpp_ary_collect('))

DRIVER = <<~'RUBY'
  show = lambda do |name, &blk|
    out = begin
      blk.call.inspect
    rescue Exception => e
      "#{e.class}: #{e.message}"
    end
    puts "#{name}: #{out}"
  end
  m = CdMaps.new
  show.call('squares') { m.squares([1, 2, 3]) }
  show.call('empty') { m.squares([]) }
  show.call('with_index') { m.with_index(%w[a b c]) }
  show.call('broke') { [m.broke([1, 2, 3, 4]), m.broke([1, 2])] }
  show.call('skipped') { m.skipped([1, 2, 3, 4]) }
  show.call('growing') { a = [1, 2]; [m.growing(a), a] }
  show.call('shrinking') { a = [1, 2, 3, 4]; [m.shrinking(a), a] }
  show.call('pairs') { m.pairs([[:a, 1], [:b, 2], 3]) }
  show.call('subclass') { l = CdList.new; l << 1 << 2; [m.squares(l), l.tag] }
  show.call('nested') { m.nested(3) }
  show.call('lut') { m.lut(16) }
  show.call('transpose') { [[1, 2, 3], [4, 5, 6]].transpose }
  show.call('transpose ragged') { [[1, 2], [3]].transpose }
  show.call('strings') { m.strings(%w[x y]) }
  show.call('raise') { m.squares([1, 'a']) }
  show.call('gc stress') do
    GC.stress = true if GC.respond_to?(:stress=)
    out = m.any((1..30).to_a) + m.nested(4).flatten.map(&:to_s)
    GC.stress = false if GC.respond_to?(:stress=)
    out
  end
  f = Fiber.new do
    a = m.squares([1, 2])
    Fiber.yield a
    m.with_index([:p, :q])
  end
  show.call('fiber') { [f.resume, f.resume] }
  big = 2**70
  show.call('bits') { m.bits([5, 6, -3, CdBox.new, [7, 8], { 1 => :h }], 1) }
  show.call('neq') do
    [m.neq(1, 1), m.neq(1, 2), m.neq(1, 1.0), m.neq(1.5, 1.5), m.neq(big, big), m.neq(big, 1), m.neq('a', 'a'),
     m.neq(:a, :b), m.neq(nil, false), m.neq(CdEq.new(1), CdEq.new(11)), m.neq(CdEq.new(1), CdEq.new(2)),
     m.neq(-(2**40), -(2**40)), m.neq(2**40, 2**40 + 1)]
  end
  puts 'end'
RUBY

if ENV['CC_GENERATED_ONLY'] == '1'
  puts '  SKIP behavioural comparison: CC_GENERATED_ONLY'
else
  build = Bc2cppFixtureRuntime.full_or_build
  if build.nil?
    puts '  SKIP behavioural comparison: needs a full-core libmruby (BC2CPP_MRUBY_FULL, or rake, g++ and 3rd/mruby)'
  else
    puts '-- fixtures on real mruby, interpreted and compiled'
    body = <<~CPP
      static int scenario(mrb_state* M) {
        std::fflush(stdout);
        const char* src = R"CDF(#{DRIVER})CDF";
        mrb_load_string(M, src);
        std::fflush(stdout);
        if (M->exc) { mrb_print_error(M); M->exc = nullptr; return 1; }
        return 0;
      }
    CPP
    built, output = Bc2cppFixtureRuntime.run(baseline_dir, baseline_err, OWNERS, body, build: build, full: true)
    check.call('the fixtures build and run', built)
    sections = Bc2cppFixtureRuntime.sections(output)
    interpreted = sections['interpreted']
    compiled = sections['compiled']
    check.call("the driver prints #{interpreted&.size} lines in both runs",
               interpreted && interpreted.last == 'end' && compiled&.last == 'end')
    check.call('interpreted and compiled runs print the same', interpreted == compiled)
    if interpreted && compiled
      interpreted.zip(compiled).reject { |a, b| a == b }.first(10).each { |a, b| puts "    interpreted: #{a}\n    compiled:    #{b}" }
    end
    puts output.lines.last(30).join unless built && interpreted && compiled
  end
end

if failures.empty?
  puts 'bc2cpp collect direct check: PASS'
else
  warn "bc2cpp collect direct check: #{failures.size} failure(s)"
  exit 1
end
