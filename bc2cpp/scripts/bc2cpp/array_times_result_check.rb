#!/usr/bin/env ruby
# encoding: UTF-8
# frozen_string_literal: true

# ARRAY_TIMES_RESULT (tools/bc2cpp/codegen_native_results.rb native_array_times_result): `[x] * n` with an Integer
# n is a fresh, exact Array, so an ivar every writer fills that way gets an Array class pool.
#
#   generated code (needs a host mrbc)
#     - `@cells = [0] * 8` gets an Array pool and the index read of @cells drops its class test, even in a world
#       whose computed send (`send(*op)`) counts as a possible removal of every method;
#     - a String argument (`[1, 2] * ","`), an argument of unknown class, a program `Integer#to_str`, a program
#       `Object#*` (what a removed Array#* would reach) and BC2CPP_ARRAY_TIMES_RESULT=0 give no pool.
#   behaviour (needs a full-core libmruby, see Bc2cppFixtureRuntime.full_or_build)
#     - interpreted and compiled runs print the same, the String join and the negative-count error included.
#
# Usage: MRBC=path/to/mrbc [BC2CPP_MRUBY_FULL=dir | BC2CPP_FULL_BUILD_DIR=dir] ruby scripts/bc2cpp/array_times_result_check.rb

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
  class AtGrid
    OPS = [[:put, 1, 7], [:put, 3, 9]].freeze
    def initialize
      @cells = [0] * 8
    end
    def reset; @cells = [nil] * 4; self; end
    def cell(i); @cells[i]; end
    def put(i, v); @cells[i] = v; end
    def run; OPS.each { |op| send(*op) }; @cells; end
  end
  class AtText
    def initialize(sep); @parts = [1, 2] * sep; end
    def parts; @parts; end
  end
RUBY

UNKNOWN_ARG = SRC.sub('@cells = [0] * 8', '@cells = [0] * $at_count')
TO_STR = SRC + "class Integer\n  def to_str; to_s; end\nend\n"
# What a removed Array#* would reach.
OBJECT_TIMES = SRC + "class Object\n  def *(other); :object; end\nend\n"

OWNERS = %w[AtGrid AtText].freeze
POOL = 'CLASSIVAR AtGrid#@cells (ARR)'

def cell_body(code)
  code[/^mrb_value AtGrid_cell_impl\(mrb_state\* M.*?^}/m].to_s
end

def generate(src)
  Dir.mktmpdir { |dir| Bc2cppFixtureRuntime.generate(src, dir, core: true, only_owners: OWNERS) }
end

baseline_dir = Dir.mktmpdir('bc2cpp-array-times')
at_exit { FileUtils.remove_entry(baseline_dir) }
puts '-- generated code'
code, baseline_err = Bc2cppFixtureRuntime.generate(SRC, baseline_dir, core: true, only_owners: OWNERS)
check.call('an ivar written only with Array * Integer gets an Array pool', baseline_err.include?(POOL))
check.call('the index read of that ivar drops its class test',
           cell_body(code).include?('INDEX_EXACT') && !cell_body(code).include?('bc2cpp_getidx('))
check.call('Array * String gives no Array pool', !baseline_err.include?('CLASSIVAR AtText#@parts (ARR)'))
check.call('no #error in the generated code', !code.include?('#error'))
_, unknown = generate(UNKNOWN_ARG)
check.call('an argument of unknown class gives no pool', !unknown.include?(POOL))
_, to_str = generate(TO_STR)
check.call('a program Integer#to_str gives no pool', !to_str.include?(POOL))
_, object_times = generate(OBJECT_TIMES)
check.call('a program Object#* gives no pool', !object_times.include?(POOL))
ENV['BC2CPP_ARRAY_TIMES_RESULT'] = '0'
_, off = generate(SRC)
ENV.delete('BC2CPP_ARRAY_TIMES_RESULT')
check.call('BC2CPP_ARRAY_TIMES_RESULT=0 gives no pool', !off.include?(POOL))

DRIVER = <<~'RUBY'
  g = AtGrid.new
  p [g.cell(0), g.cell(7), g.cell(8), g.run]
  p [g.reset.cell(3), g.cell(4)]
  p AtText.new(',').parts
  p AtText.new(2).parts
  begin
    AtText.new(-1)
  rescue ArgumentError => e
    p e.class
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
        const char* src = R"ATR(#{DRIVER})ATR";
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
  puts 'bc2cpp array times result check: PASS'
else
  warn "bc2cpp array times result check: #{failures.size} failure(s)"
  exit 1
end
