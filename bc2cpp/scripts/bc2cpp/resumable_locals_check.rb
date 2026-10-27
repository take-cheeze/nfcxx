#!/usr/bin/env ruby
# encoding: UTF-8
# frozen_string_literal: true

# RESUMABLE_LOCAL_REGISTERS (tools/bc2cpp/codegen_resumable.rb resumable_step_function): a resumable step
# function keeps its registers in C++ locals, loads them from the frame on entry and stores them back at each
# yield, instead of reading and writing the frame on every access.
#
#   generated code (needs a host mrbc)
#     - the step function declares its registers as locals and every yield stores them back before returning;
#     - a step function that takes a register's address (a stack block capturing a local) keeps references;
#     - BC2CPP_RESUMABLE_LOCALS=0 keeps the registers as references into the frame and emits no stores.
#   behaviour (needs a full-core libmruby, see Bc2cppFixtureRuntime.full_or_build)
#     - interpreted and compiled runs print the same, with heap values held across yields and GC.start
#       between resumes.
#
# Usage: MRBC=path/to/mrbc [BC2CPP_MRUBY_FULL=dir | BC2CPP_FULL_BUILD_DIR=dir] ruby scripts/bc2cpp/resumable_locals_check.rb

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

# RlClock#main_loop is a Fiber root with two yielding helpers; `row` is a fresh Array held across both yields.
# RlBlock#main_loop hands a block capturing its locals to a compiled method between yields.
SRC = <<~'RUBY'
  class RlClock
    def initialize
      @hclk = 0
      @target = 3
      @log = []
      @fiber = Fiber.new { main_loop }
    end

    def main_loop
      i = 0
      while i < 6
        row = [i, @hclk]
        wait_two
        @log << row
        wait_one
        @log << [row.size, i * 2, @hclk]
        i += 1
      end
      @log.size
    end

    def wait_one
      @hclk += 1
      Fiber.yield @hclk if @target <= @hclk
    end

    def wait_two
      @hclk += 2
      Fiber.yield if @target <= @hclk
    end

    def step(target)
      @target = target
      @fiber.resume
    end

    def running
      @fiber.alive?
    end

    def log
      @log
    end
  end

  class RlBlock
    def initialize
      @fiber = Fiber.new { main_loop }
    end

    def twice
      yield 1
      yield 2
    end

    def main_loop
      sum = 0
      i = 0
      while i < 3
        twice { |x| sum += x + i }
        Fiber.yield sum
        i += 1
      end
      sum
    end

    def step
      @fiber.resume
    end
  end
RUBY

OWNERS = %w[RlClock RlBlock].freeze

def step_function(code, klass = 'RlClock')
  code[/^static mrb_value #{klass}_main_loop_step\(mrb_state\* M.*?(?=^static mrb_value #{klass}_main_loop_step_thunk)/m].to_s
end

baseline_dir = Dir.mktmpdir('bc2cpp-resumable-locals')
at_exit { FileUtils.remove_entry(baseline_dir) }
puts '-- generated code'
code, baseline_err = Bc2cppFixtureRuntime.generate(SRC, baseline_dir, core: true, only_owners: OWNERS)
step = step_function(code)
yields = step.scan('return bc2cpp_frame_value;').size
spills = step.scan(/^  (?:R\[\d+\] = r\d+; )*R\[\d+\] = r\d+;\n  mrb_write_barrier\(M, \(struct RBasic\*\)mrb_ary_ptr\(bc2cpp_regs_ary\)\);\n  return bc2cpp_frame_value;/).size
check.call('main_loop compiles as a resumable step function', !step.empty? && yields >= 2)
check.call('the step function marks its registers local', step.include?('// RESUMABLE_LOCAL_REGISTERS'))
check.call('registers are locals loaded from the frame', step.match?(/^  mrb_value r\d+ = R\[\d+\];$/) &&
                                                         !step.match?(/^  mrb_value& r\d+ = R\[\d+\];$/))
check.call("every yield (#{yields}) stores the registers back before returning", spills == yields)
check.call('no #error in the generated code', !code.include?('#error'))
block_step = step_function(code, 'RlBlock')
check.call('a step function taking a register address keeps references into the frame',
           block_step.match?(/mrb_cptr_value\(M, &r\d+\)/) && block_step.match?(/^  mrb_value& r\d+ = R\[\d+\];$/) &&
           !block_step.include?('RESUMABLE_LOCAL_REGISTERS'))
ENV['BC2CPP_RESUMABLE_LOCALS'] = '0'
off, = Dir.mktmpdir { |dir| Bc2cppFixtureRuntime.generate(SRC, dir, core: true, only_owners: OWNERS) }
ENV.delete('BC2CPP_RESUMABLE_LOCALS')
off_step = step_function(off)
check.call('BC2CPP_RESUMABLE_LOCALS=0 keeps references into the frame',
           off_step.match?(/^  mrb_value& r\d+ = R\[\d+\];$/) && !off_step.include?('RESUMABLE_LOCAL_REGISTERS') &&
           !off_step.match?(/^  R\[(?:[2-9]|\d{2,})\] = r\d+;/))

DRIVER = <<~'RUBY'
  c = RlClock.new
  out = []
  t = 1
  while c.running
    out << c.step(t)
    GC.start
    t += 2
  end
  p out
  p c.log
  b = RlBlock.new
  p [b.step, b.step, b.step, b.step]
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
        const char* src = R"RLC(#{DRIVER})RLC";
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
  puts 'bc2cpp resumable locals check: PASS'
else
  warn "bc2cpp resumable locals check: #{failures.size} failure(s)"
  exit 1
end
