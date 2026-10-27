#!/usr/bin/env ruby
# encoding: UTF-8
# frozen_string_literal: true

# TRANSPOSE_DIRECT (tools/bc2cpp/codegen_transpose_direct.rb): the compiled core Array#transpose body first tries
# bc2cpp_ary_transpose, which answers an exact Array of exact equal-length Arrays and hands anything else back.
#
#   generated code (needs a host mrbc)
#     - the core body starts with the helper call and the helper is emitted;
#     - BC2CPP_TRANSPOSE_DIRECT=0, a program Array#size, Array#empty?, Kernel#is_a?, Array#each or
#       Array#initialize each leave the body alone, and the pinned TRANSPOSE_BODY is still mruby-array-ext's text;
#   behaviour (needs a full-core libmruby, see Bc2cppFixtureRuntime.full_or_build)
#     - interpreted and compiled runs print the same for square, wide, tall and embedded-size shapes, empty
#       receivers and rows, ragged rows (IndexError), non-Array and to_ary rows (TypeError), Array subclass
#       receivers and rows (a row subclass with its own `[]`), a singleton receiver, frozen receivers and rows, a
#       self-containing row and GC.stress; and in a world whose program redefines Array#transpose.
#
# Usage: MRBC=path/to/mrbc [BC2CPP_MRUBY_FULL=dir | BC2CPP_FULL_BUILD_DIR=dir] ruby scripts/bc2cpp/transpose_direct_check.rb

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
  class TdList < Array
  end
  class TdRow < Array
    def [](i); :row_aref; end
  end
  class TdAry
    def initialize(a); @a = a; end
    def to_ary; @a; end
  end
  class TdT
    def t(a); a.transpose; end
    def lut(n)
      [0, 4].map do |attr|
        (0..3).map { |j| (0...n).map { |i| (i >> j) & 1 == 1 ? attr | j : 0 } }.transpose
      end
    end
  end
RUBY

OWNERS = %w[TdList TdRow TdAry TdT].freeze
CALL = 'bc2cpp_ary_transpose(M, self)'

def transpose_body(code)
  code[/^mrb_value Array_transpose_impl\(mrb_state\* M.*?(?=^(?:static )?mrb_value \w+\(mrb_state\* M|\z)/m].to_s
end

def generate_world(src, env = {})
  saved = env.keys.to_h { |k| [k, ENV.fetch(k, nil)] }
  env.each { |k, v| ENV[k] = v }
  Dir.mktmpdir { |dir| Bc2cppFixtureRuntime.generate(src, dir, core: true, only_owners: OWNERS) }
ensure
  saved&.each { |k, v| v.nil? ? ENV.delete(k) : ENV[k] = v }
end

baseline_dir = Dir.mktmpdir('bc2cpp-transpose-direct')
at_exit { FileUtils.remove_entry(baseline_dir) }
puts '-- generated code'
code, baseline_err = Bc2cppFixtureRuntime.generate(SRC, baseline_dir, core: true, only_owners: OWNERS)
body = transpose_body(code)
check.call('the core Array#transpose body starts with the helper call',
           body.lines[1].to_s.include?('TRANSPOSE_DIRECT') && body.lines[2].to_s.include?(CALL))
check.call('the helper is emitted', code.include?('static mrb_value bc2cpp_ary_transpose('))
check.call('the compiled body stays behind the helper', body.include?('bc2cpp_ary_collect(M, self, '))
check.call('no #error in the generated code', !code.include?('#error'))

REFUSALS = {
  'BC2CPP_TRANSPOSE_DIRECT=0' => [SRC, { 'BC2CPP_TRANSPOSE_DIRECT' => '0' }],
  'a program Array#size' => ["#{SRC}class Array\n  def size; 1; end\nend\n", {}],
  'a program Array#empty?' => ["#{SRC}class Array\n  def empty?; true; end\nend\n", {}],
  'a program Kernel#is_a?' => ["#{SRC}module Kernel\n  def is_a?(c); true; end\nend\n", {}],
  'a program Array#each' => ["#{SRC}class Array\n  def each; self; end\nend\n", {}],
  'a program Array#initialize' => ["#{SRC}class Array\n  def initialize(*a); super; end\nend\n", {}]
}.freeze
REFUSALS.each do |what, (src, env)|
  refused, = generate_world(src, env)
  check.call("#{what} leaves the transpose body alone", !refused.include?(CALL))
end
source = File.read(File.expand_path('../../3rd/mruby/mrbgems/mruby-array-ext/mrblib/array.rb', __dir__))
normalize = ->(text) { text.lines.map(&:strip).reject(&:empty?).join("\n") }
pinned = File.read(File.expand_path('../../tools/bc2cpp/codegen_transpose_direct.rb', __dir__))[/TRANSPOSE_BODY = <<~RUBY\n(.*?)^  RUBY$/m, 1]
check.call("the pinned body is mruby-array-ext's Array#transpose (a drift turns the helper off)",
           pinned && normalize.call(source[/^  def transpose\n.*?^  end\n/m].to_s) == normalize.call(pinned))

DRIVER = <<~'RUBY'
  show = lambda do |name, &blk|
    out = begin
      blk.call.inspect
    rescue Exception => e
      "#{e.class}: #{e.message}"
    end
    puts "#{name}: #{out}"
  end
  t = TdT.new
  show.call('square') { t.t([[1, 2], [3, 4]]) }
  show.call('wide') { t.t([[1, 2, 3, 4, 5], [6, 7, 8, 9, 10]]) }
  show.call('tall') { t.t((1..9).map { |i| [i, -i] }) }
  show.call('embedded sizes') { (1..5).map { |n| t.t(Array.new(n) { |i| Array.new(n) { |j| i * n + j } }) } }
  show.call('result classes') { r = t.t([[1, 2], [3, 4]]); [r.class, r[0].class, r.frozen?, r[0].frozen?] }
  show.call('empty') { t.t([]) }
  show.call('empty rows') { t.t([[], [], []]) }
  show.call('one row') { t.t([[1, 2, 3]]) }
  show.call('ragged') { t.t([[1, 2], [3]]) }
  show.call('ragged then non-Array') { t.t([[1, 2], [3], 4]) }
  show.call('non-Array row') { t.t([[1, 2], 3]) }
  show.call('to_ary row') { t.t([[1, 2], TdAry.new([3, 4])]) }
  show.call('nil row') { t.t([nil]) }
  show.call('subclass receiver') { l = TdList.new; l << [1, 2] << [3, 4]; t.t(l) }
  show.call('subclass rows') { r = TdList.new; r << 5 << 6; t.t([[1, 2], r]) }
  show.call('row with its own []') { r = TdRow.new; r << 5 << 6; t.t([[1, 2], r]) }
  show.call('singleton receiver') do
    a = [[1, 2], [3, 4]]
    def a.each; yield [9, 9]; yield [8, 8]; self; end
    t.t(a)
  end
  show.call('frozen') { t.t([[1, 2].freeze, [3, 4].freeze].freeze) }
  show.call('self-containing row') { a = []; a << a; r = t.t(a); [r.size, r[0].size, r[0][0].equal?(a)] }
  show.call('shared rows') { row = [1, 2]; t.t([row, row, row]) }
  show.call('lut') { t.lut(8) }
  show.call('gc stress') do
    GC.stress = true if GC.respond_to?(:stress=)
    out = t.t(Array.new(7) { |i| Array.new(40) { |j| "s#{i}-#{j}" } })
    GC.stress = false if GC.respond_to?(:stress=)
    [out.size, out[39].join(','), out.map(&:size).uniq]
  end
  show.call('large') { r = t.t(Array.new(8) { |i| Array.new(3000) { |j| i + j } }); [r.size, r[2999], r.flatten.sum] }
  puts 'end'
RUBY

# A program Array#transpose answers every call; the core body (and its helper) is not what runs.
REDEFINED = "#{SRC}class Array\n  def transpose; [:program, size]; end\nend\n"

def scenario_body
  <<~CPP
    static int scenario(mrb_state* M) {
      std::fflush(stdout);
      const char* src = R"TDF(#{DRIVER})TDF";
      mrb_load_string(M, src);
      std::fflush(stdout);
      if (M->exc) { mrb_print_error(M); M->exc = nullptr; return 1; }
      return 0;
    }
  CPP
end

compare = lambda do |label, dir, err, build|
  built, output = Bc2cppFixtureRuntime.run(dir, err, OWNERS, scenario_body, build: build, full: true)
  check.call("#{label}: the fixtures build and run", built)
  sections = Bc2cppFixtureRuntime.sections(output)
  interpreted = sections['interpreted']
  compiled = sections['compiled']
  check.call("#{label}: the driver prints #{interpreted&.size} lines in both runs",
             interpreted && interpreted.last == 'end' && compiled&.last == 'end')
  check.call("#{label}: interpreted and compiled runs print the same", interpreted == compiled)
  if interpreted && compiled
    interpreted.zip(compiled).reject { |a, b| a == b }.first(10).each { |a, b| puts "    interpreted: #{a}\n    compiled:    #{b}" }
  end
  puts output.lines.last(30).join unless built && interpreted && compiled
  interpreted
end

if ENV['CC_GENERATED_ONLY'] == '1'
  puts '  SKIP behavioural comparison: CC_GENERATED_ONLY'
else
  build = Bc2cppFixtureRuntime.full_or_build
  if build.nil?
    puts '  SKIP behavioural comparison: needs a full-core libmruby (BC2CPP_MRUBY_FULL, or rake, g++ and 3rd/mruby)'
  else
    puts '-- fixtures on real mruby, interpreted and compiled'
    lines = compare.call('core transpose', baseline_dir, baseline_err, build)
    check.call('the ragged and non-Array cases raise', lines.to_a.include?('ragged: IndexError: element size differs') &&
                                                        lines.to_a.include?('non-Array row: TypeError: TypeError'))
    redefined_dir = Dir.mktmpdir('bc2cpp-transpose-redefined')
    at_exit { FileUtils.remove_entry(redefined_dir) }
    _, redefined_err = Bc2cppFixtureRuntime.generate(REDEFINED, redefined_dir, core: true, only_owners: OWNERS)
    lines = compare.call('program Array#transpose', redefined_dir, redefined_err, build)
    check.call('the program Array#transpose answers', lines.to_a.include?('square: [:program, 2]'))
  end
end

if failures.empty?
  puts 'bc2cpp transpose direct check: PASS'
else
  warn "bc2cpp transpose direct check: #{failures.size} failure(s)"
  exit 1
end
