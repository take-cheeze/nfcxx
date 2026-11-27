#!/usr/bin/env ruby
# frozen_string_literal: true

# FLOAT_SHADOW (tools/bc2cpp/codegen_float_shadow.rb): a Float whose every reader is arithmetic, a compare or a MOVE
# stays unboxed in the frame.
#
#   generated code (needs a host mrbc)
#     - a Float chain, a loop-carried Float local and a Float literal are placed; a Float read by a send, a return,
#       an EQ or a closure through a local is not, nor is arithmetic with no Float evidence;
#   behaviour (needs a full-core libmruby, see Bc2cppFixtureRuntime.full_or_build)
#     - interpreted and compiled runs print the same: mixed Integer/Float operands, NaN and infinities, division by
#       zero, a non-numeric operand (the operator send gets a boxed Float), Integer#/ raising, BC2CPP_FLOAT_SHADOW=0.
#
# Usage: MRBC=path/to/mrbc [BC2CPP_MRUBY_FULL=dir | BC2CPP_FULL_BUILD_DIR=dir] ruby scripts/bc2cpp/float_shadow_check.rb

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
  class FsKeep
    attr_reader :got
    def +(other)
      @got = other
      self
    end
  end

  class FsBox
    def curve(n, base, correction)
      inflation = 1.5 + n * 0.01
      result = 0
      i = 0
      while i < n
        term = correction + base
        return -1 if result + term >= 1_000_000
        result += term.to_i
        base *= inflation
        inflation = ((n + 1) * 0.002 + 0.8) * (inflation - 1) + 1
        i += 1
      end
      result
    end

    def mix(a, b)
      [a * 0.5 + b, (a + b) / 4.0, a - 2.5 < b, a * 1.0 >= b, a / 2 * 0.5, (a + 0.25) - 1]
    end

    def special(a)
      x = a * 0.0
      y = a / 0.0
      [x < 1.0, x >= 0.0, y > 1.0e300, y * 0.0 <= 1.0, -y < 0.0]
    end

    def other(obj)
      obj + 0.5 * 2
    end

    def ret(a)
      a * 0.5
    end

    def eq(a)
      a * 0.5 == 1.0
    end

    def closure(a)
      t = a * 0.5
      [1].map { |k| k + t }
    end

    def int_div(a, b)
      (a / b) * 0.5
    end

    def tint(a, b, n)
      a + (b - a) / n.to_f
    end

    def ints(a, b)
      a * b + a
    end
  end
RUBY

OWNERS = %w[FsBox FsKeep].freeze

def method_code(code, name)
  code[/^mrb_value #{name}_impl\(mrb_state\* M.*?(?=^(?:static )?mrb_value \w+\(mrb_state\* M|\z)/m].to_s
end

dir = Dir.mktmpdir('bc2cpp-float-shadow')
at_exit { FileUtils.remove_entry(dir) }
puts '-- generated code'
code, err = Bc2cppFixtureRuntime.generate(SRC, dir, core: true, only_owners: OWNERS)
check.call('no #error in the generated code', !code.include?('#error'))
curve = method_code(code, 'FsBox_curve')
check.call('FsBox#curve: the loop-carried Floats stay unboxed', curve.include?('// FLOAT_SHADOW: the result stays unboxed') &&
                                                              curve.include?('mrb_float bc2cpp_f'))
check.call('FsBox#curve: the literals stay unboxed', curve.include?('// FLOAT_SHADOW: the literal stays unboxed'))
check.call('FsBox#mix: the chains are placed', method_code(code, 'FsBox_mix').include?('FLOAT_SHADOW'))
check.call('FsBox#ints: Integer-only arithmetic is not rewritten', !method_code(code, 'FsBox_ints').include?('bc2cpp_flo_bin'))
%w[ret eq closure].each do |name|
  check.call("FsBox##{name}: a Float that leaves (#{name}) is boxed", !method_code(code, "FsBox_#{name}").include?('FLOAT_SHADOW: the result'))
end

DRIVER = <<~'RUBY'
  o = FsBox.new
  k = FsKeep.new
  rows = [
    -> { o.curve(10, 30.0, 5.0) }, -> { o.curve(99, 25, 7) }, -> { o.curve(50, 300.0, 40.0) },
    -> { o.mix(3, 4) }, -> { o.mix(3.5, 4) }, -> { o.mix(7, 2.25) }, -> { o.mix(-1.5, -0.0) },
    -> { o.special(1) }, -> { o.special(-2.5) }, -> { o.special(0) },
    -> { o.other(k).got }, -> { o.other(3) }, -> { o.other(nil) },
    -> { o.ret(3) }, -> { o.eq(2) }, -> { o.closure(5) },
    -> { o.int_div(7, 2) }, -> { o.int_div(7.0, 2) }, -> { o.int_div(7, 0) }, -> { o.int_div(7.0, 0) },
    -> { o.mix('a', 1) }, -> { o.tint(1, 4, 3) }, -> { o.tint(1.5, 4, 2.0) }, -> { o.tint(1, 4, 0) },
    -> { o.tint(1, 4, 2.5) }, -> { o.ints(3, 4) }, -> { o.ints(3, 0.5) }
  ]
  rows.each_with_index do |row, i|
    begin
      puts "#{i}: #{row.call.inspect}"
    rescue StandardError => e
      puts "#{i}: #{e.class}: #{e.message}"
    end
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
        const char* src = R"FSD(#{DRIVER})FSD";
        mrb_load_string(M, src);
        std::fflush(stdout);
        if (M->exc) { mrb_print_error(M); M->exc = nullptr; return 1; }
        return 0;
      }
    CPP
    built, output = Bc2cppFixtureRuntime.run(dir, err, OWNERS, body, build: build, full: true)
    check.call('the fixtures build and run', built)
    sections = Bc2cppFixtureRuntime.sections(output)
    interpreted = sections['interpreted']
    compiled = sections['compiled']
    check.call('the driver runs to the end in both runs', interpreted&.last == 'end' && compiled&.last == 'end')
    check.call('interpreted and compiled runs print the same', interpreted == compiled)
    puts interpreted.map { |line| "    #{line}" } if interpreted && ENV['FLOAT_SHADOW_VERBOSE'] == '1'
    if interpreted && compiled
      interpreted.zip(compiled).reject { |a, b| a == b }.first(10).each { |a, b| puts "    interpreted: #{a}\n    compiled:    #{b}" }
    else
      puts output.to_s.lines.last(30).join
    end
  end
end

if failures.empty?
  puts 'float_shadow_check: ok'
else
  puts "float_shadow_check: #{failures.size} failure(s)"
  exit 1
end
