#!/usr/bin/env ruby
# encoding: UTF-8
# frozen_string_literal: true

# RESUMABLE_ARGS (tools/bc2cpp/codegen_resumable.rb resumable_entry_function): a resumable method takes its required
# positional arguments. The entry builds the frame with each argument in the register the body reads it from, and hands
# the frame to the bytecode driver, whose first step takes it (Bc2cppResumable.take_initial) instead of starting empty.
#
#   generated code (needs a host mrbc)
#     - the entry takes the arguments as mrb_values and fills the frame before the driver runs;
#     - the driver takes the handed-off frame on its first step;
#     - a method with a rest argument is still refused, and stays interpreted (optional arguments: resumable_optional_check.rb).
#   behaviour (needs a full-core libmruby, see Bc2cppFixtureRuntime.full_or_build)
#     - interpreted and compiled runs print the same, with two fiber roots taking arguments in turn and GC.start
#       between resumes, so each call's frame must keep its own arguments.
#
# Usage: MRBC=path/to/mrbc [BC2CPP_MRUBY_FULL=dir | BC2CPP_FULL_BUILD_DIR=dir] ruby scripts/bc2cpp/resumable_args_check.rb

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

# RaClock#run is a Fiber root taking two required arguments; it keeps them across each yield.
SRC = <<~'RUBY'
  class RaClock
    def start(base, step)
      @base = base
      @step = step
      boot
    end

    def boot
      @fiber = Fiber.new { run(@base, @step) }
    end

    def run(base, step)
      acc = base
      i = 0
      while i < 4
        acc += step
        @acc = acc
        wait
        i += 1
      end
      [acc, i]
    end

    def wait
      Fiber.yield @acc
    end

    def go
      @fiber.resume
    end

    def maybe(a, b = 2)
      a + b
    end
  end
RUBY

OWNERS = %w[RaClock].freeze

baseline_dir = Dir.mktmpdir('bc2cpp-resumable-args')
at_exit { FileUtils.remove_entry(baseline_dir) }
puts '-- generated code'
code, baseline_err = Bc2cppFixtureRuntime.generate(SRC, baseline_dir, core: true, only_owners: OWNERS)
check.call('run compiles as a resumable step function', code.include?('static mrb_value RaClock_run_step(mrb_state* M'))
check.call('the entry takes its two arguments as mrb_values',
           code.match?(/^mrb_value RaClock_run_impl\(mrb_state\* M, mrb_value self, mrb_value \w+, mrb_value \w+\) \{/))
check.call('the entry hands the frame to the driver', code.include?('bc2cpp_resumable_handoff(M, frame);'))
check.call('the driver takes the handed-off frame on its first step', code.include?('mrb_define_module_function(M, mod, "take_initial"'))
check.call('the entry fills the argument registers of the frame', code.match?(/F->regs\[\d+\] = \w+;/))
check.call('no #error in the generated code', !code.include?('#error'))
check.call('a method that no fiber root reaches (maybe) gets no step function', !code.include?('RaClock_maybe_step('))

DRIVER = <<~'RUBY'
  a = RaClock.new
  b = RaClock.new
  a.start(10, 3)
  b.start(100, 7)
  out = []
  4.times do
    out << a.go
    GC.start
    out << b.go
  end
  out << a.go
  out << b.go
  p out
  p [a.maybe(1), a.maybe(1, 5)]
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
        const char* src = R"RAC(#{DRIVER})RAC";
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
  puts 'bc2cpp resumable args check: PASS'
else
  warn "bc2cpp resumable args check: #{failures.size} failure(s)"
  exit 1
end
