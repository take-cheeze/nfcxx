#!/usr/bin/env ruby
# encoding: UTF-8
# frozen_string_literal: true

# RESUMABLE_OPTIONAL (tools/bc2cpp/codegen_resumable.rb resumable_entry_function, resumable_step_function): a resumable
# method takes optional positional arguments, the shape its jump table (optional_arg_table) recognises. The entry takes
# every positional argument, and records in the frame state how many optionals the call gave as -(given + 1). The step
# starts from that state: the body's jump-table glue switches on bc2cpp_given_opt, and the default-value code of each
# omitted optional runs in the step, so a default may read an earlier argument.
#
#   generated code (needs a host mrbc)
#     - the step reads bc2cpp_given_opt from a negative frame state, and the jump-table glue switches on it;
#     - the entry stores -(given + 1) and takes all the positional arguments;
#     - a method with a rest argument is still refused, and stays interpreted.
#   behaviour (needs a full-core libmruby, see Bc2cppFixtureRuntime.full_or_build)
#     - three Fiber roots with 0, 1 and 2 optionals run in turn, with GC.start between resumes, so each frame keeps
#       its own given count and its own defaults; interpreted and compiled runs print the same.
#
# Usage: MRBC=path/to/mrbc [BC2CPP_MRUBY_FULL=dir | BC2CPP_FULL_BUILD_DIR=dir] ruby scripts/bc2cpp/resumable_optional_check.rb

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

# OptClock#run is a Fiber root with two optionals; each Fiber calls it with 0, 1 or 2 of them.
SRC = <<~'RUBY'
  class OptClock
    def make(kind, base)
      case kind
      when :a then @f = Fiber.new { run(base) }
      when :b then @f = Fiber.new { run(base, 5) }
      when :c then @f = Fiber.new { run(base, 5, 'y') }
      end
      self
    end

    def run(base, step = base * 2, extra = 'x')
      acc = base
      i = 0
      while i < 3
        acc += step
        @acc = acc
        wait
        i += 1
      end
      [acc, extra, i]
    end

    def wait
      Fiber.yield @acc
    end

    def go
      @f.resume
    end
  end
RUBY

OWNERS = %w[OptClock].freeze

baseline_dir = Dir.mktmpdir('bc2cpp-resumable-optional')
at_exit { FileUtils.remove_entry(baseline_dir) }
puts '-- generated code'
code, baseline_err = Bc2cppFixtureRuntime.generate(SRC, baseline_dir, core: true, only_owners: OWNERS)
check.call('run compiles as a resumable step function', code.include?('static mrb_value OptClock_run_step(mrb_state* M'))
check.call('the entry takes all three positional arguments and the given count last',
           code.match?(/^mrb_value OptClock_run_impl\(mrb_state\* M, mrb_value self, mrb_value \w+, mrb_value \w+, mrb_value \w+, mrb_int bc2cpp_given_opt\) \{/))
check.call('the entry records the given count as a negative frame state',
           code.include?('F->state = -(bc2cpp_given_opt + 1);'))
check.call('the step reads the given count from a negative frame state',
           code.include?('const mrb_int bc2cpp_given_opt = bc2cpp_state < 0 ? -bc2cpp_state - 1 : 0;'))
check.call('the jump-table glue switches on the given count inside the step',
           code[/static mrb_value OptClock_run_step\(.*?\n\}\n/m].to_s.include?('switch (bc2cpp_given_opt)'))
check.call('the entry hands the frame to the driver', code.include?('bc2cpp_resumable_handoff(M, frame);'))
check.call('no #error in the generated code', !code.include?('#error'))

DRIVER = <<~'RUBY'
  x = OptClock.new.make(:a, 1)
  y = OptClock.new.make(:b, 2)
  z = OptClock.new.make(:c, 3)
  out = []
  4.times do
    out << x.go
    GC.start
    out << y.go
    out << z.go
  end
  p out
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
    # MRI's own output for the driver (ruby 3.x): the three frames keep their own defaults and given counts.
    check.call('the compiled run prints what MRI prints',
               compiled&.first == '[3, 7, 8, 5, 12, 13, 7, 17, 18, [7, "x", 3], [17, "x", 3], [18, "y", 3]]')
    if interpreted && compiled
      interpreted.zip(compiled).reject { |a, b| a == b }.first(10).each { |a, b| puts "    interpreted: #{a}\n    compiled:    #{b}" }
    end
    puts output.lines.last(30).join unless built && interpreted && compiled
  end
end

if failures.empty?
  puts 'bc2cpp resumable optional check: PASS'
else
  warn "bc2cpp resumable optional check: #{failures.size} failure(s)"
  exit 1
end
