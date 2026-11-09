#!/usr/bin/env ruby
# encoding: UTF-8
# frozen_string_literal: true

# JMPUW_PLAIN (tools/bc2cpp/numeric_flow.rb plain_jmpuw?): NumericFlow models an irep whose `break`/`next` compiles
# to OP_JMPUW when the irep has no catch handler, where vm.c runs it as a plain OP_JMP. Such an irep used to be
# unmodelled, which failed every ivar it writes for the whole program: a resumable `main_loop` with a
# `while true ... break` left its counters without a class proof in the step function and in every method.
#
#   generated code (needs a host mrbc)
#     - the ivars a resumable root with a `while`/`break` writes are proven (NUMIVAR), and the step function and its
#       inlined helper take the NUMERIC_OPERAND_PROOF arms for them;
#     - a plain method with a `while`/`break` is modelled the same way;
#     - a `break` inside `begin ... ensure` is a JMPUW that may run the ensure, so that ivar stays unproven;
#     - BC2CPP_NUMERIC_JMPUW=0 leaves the JMPUW ireps unmodelled again.
#   behaviour (needs a full-core libmruby, see Bc2cppFixtureRuntime.full_or_build)
#     - interpreted and compiled runs print the same, with an Integer that overflows to a bigint between two yields,
#       a bigint held in a register across a resume, and a Float stored into a proven ivar.
#
# Usage: MRBC=path/to/mrbc [BC2CPP_MRUBY_FULL=dir | BC2CPP_FULL_BUILD_DIR=dir] ruby scripts/bc2cpp/numeric_jmpuw_check.rb

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

# NjClock#main_loop is a Fiber root whose loops end in `break`/`next` (JMPUW). Every ivar is assigned first in
# #initialize, so no read sees the nil of an unassigned slot. The value near the Fixnum maximum overflows to a bigint
# in wait_one, between two yields; `big` holds one across a resume.
SRC = <<~'RUBY'
  class NjClock
    def initialize
      @hclk = 0
      @scale = 1
      @target = 3
      @log = []
      @fiber = Fiber.new { main_loop }
    end

    def main_loop
      while true
        wait_one
        @log << @hclk * @scale
        if @hclk >= 7
          @hclk = 4611686018427387900
          @scale = 0.5
          break
        end
      end
      i = 0
      while i < 6
        i += 1
        big = @hclk
        wait_one
        next if i == 2

        @log << [big + 1, @hclk - big, @hclk * @scale, @hclk.class]
      end
      @log.size
    end

    def wait_one
      @hclk += 1
      Fiber.yield @hclk if @target <= @hclk
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

  class NjCount
    def initialize
      @acc = 0
    end

    def run(n)
      while true
        @acc = @acc * 2 + 1
        break if @acc > n
      end
      @acc
    end
  end

  class NjEnsure
    def initialize
      @count = 0
      @log = []
    end

    def drain
      while true
        @count += 1
        break if @count > 3
      end
      @count
    ensure
      @log << @count
    end

    def log
      @log
    end
  end
RUBY

OWNERS = %w[NjClock NjCount NjEnsure].freeze

def step_function(code)
  code[/^static mrb_value NjClock_main_loop_step\(mrb_state\* M.*?(?=^static mrb_value NjClock_main_loop_step_thunk)/m].to_s
end

def numivar(err, name)
  err[/^  NUMIVAR #{Regexp.escape(name)} \(([^)]*)\)$/, 1]
end

baseline_dir = Dir.mktmpdir('bc2cpp-numeric-jmpuw')
at_exit { FileUtils.remove_entry(baseline_dir) }
puts '-- generated code'
code, baseline_err = Bc2cppFixtureRuntime.generate(SRC, baseline_dir, core: true, only_owners: OWNERS)
step = step_function(code)
check.call('main_loop compiles as a resumable step function', !step.empty? && step.include?('RESUMABLE_YIELD'))
check.call('the resumable root writes a proven Integer ivar (NjClock#@hclk)', numivar(baseline_err, 'NjClock#@hclk') == 'INT')
check.call('a Float stored in main_loop joins the ivar proof (NjClock#@scale)',
           numivar(baseline_err, 'NjClock#@scale') == 'INT|FLT')
check.call('the step function multiplies the proven ivars with the core body',
           step.include?('NUMERIC_OPERAND_PROOF :*'))
check.call('the inlined helper adds to the proven ivar with the core body', step.include?('NUMERIC_OPERAND_PROOF :+'))
check.call('a plain method with a while/break is modelled (NjCount#@acc)', numivar(baseline_err, 'NjCount#@acc') == 'INT')
check.call('a break inside begin/ensure leaves its ivar unproven (NjEnsure#@count)',
           numivar(baseline_err, 'NjEnsure#@count').nil?)
check.call('no #error in the generated code', !code.include?('#error'))
ENV['BC2CPP_NUMERIC_JMPUW'] = '0'
off, off_err = Dir.mktmpdir { |dir| Bc2cppFixtureRuntime.generate(SRC, dir, core: true, only_owners: OWNERS) }
ENV.delete('BC2CPP_NUMERIC_JMPUW')
check.call('BC2CPP_NUMERIC_JMPUW=0 leaves the JMPUW ireps unmodelled',
           numivar(off_err, 'NjClock#@hclk').nil? && numivar(off_err, 'NjCount#@acc').nil? &&
           !step_function(off).include?('NUMERIC_OPERAND_PROOF :*'))

DRIVER = <<~'RUBY'
  c = NjClock.new
  out = []
  t = 1
  while c.running
    out << c.step(t)
    GC.start
    t += 1
  end
  p out
  p c.log
  c2 = NjClock.new
  p [c2.step(2.5), c2.step(2.5), c2.step(9.0)]
  p NjCount.new.run(100)
  e = NjEnsure.new
  p [e.drain, e.log]
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
        const char* src = R"NJC(#{DRIVER})NJC";
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
    check.call('the run overflows to a bigint', interpreted&.any? { |l| l.include?('4611686018427387904') })
    check.call('interpreted and compiled runs print the same', interpreted == compiled)
    if interpreted && compiled
      interpreted.zip(compiled).reject { |a, b| a == b }.first(10).each { |a, b| puts "    interpreted: #{a}\n    compiled:    #{b}" }
    end
    puts output.lines.last(30).join unless built && interpreted && compiled
  end
end

if failures.empty?
  puts 'bc2cpp numeric JMPUW check: PASS'
else
  warn "bc2cpp numeric JMPUW check: #{failures.size} failure(s)"
  exit 1
end
