#!/usr/bin/env ruby
# encoding: UTF-8
# frozen_string_literal: true

# RESUMABLE_REST (tools/bc2cpp/codegen_resumable.rb resumable_shape_problem, resumable_entry_function): a resumable method
# takes a rest positional argument (`*steps`), alone or after optional ones. The registered wrapper checks the argument
# count and builds the rest Array (codegen_method.rb, has_rest), and passes it to the impl as the rest parameter, so the
# step reads the Array from its register. The impl checks nothing itself, since its argument count is the rest's.
#
#   generated code (needs a host mrbc)
#     - the impl takes the rest as an mrb_value, and has no argument check of its own;
#     - a method with optional and rest arguments takes the given count after the rest, as the wrapper passes it;
#     - a method with a post or keyword argument is still refused, and stays interpreted.
#   behaviour (needs a full-core libmruby, see Bc2cppFixtureRuntime.full_or_build)
#     - fiber roots call a rest method with 0, 1 and 2 extra arguments, and one with optional and rest arguments, with
#       GC.start between resumes; interpreted and compiled runs print the same, and the same as MRI.
#
# Usage: MRBC=path/to/mrbc [BC2CPP_MRUBY_FULL=dir | BC2CPP_FULL_BUILD_DIR=dir] ruby scripts/bc2cpp/resumable_rest_check.rb

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
  class RestClock
    def make(kind, base)
      case kind
      when :a then @f = Fiber.new { run(base) }
      when :b then @f = Fiber.new { run(base, 5) }
      when :c then @f = Fiber.new { run(base, 5, 6) }
      when :d then @f = Fiber.new { run_opt(base) }
      when :e then @f = Fiber.new { run_opt(base, 3) }
      when :f then @f = Fiber.new { run_opt(base, 3, 4, 9) }
      end
      self
    end

    def run(base, *steps)
      acc = base
      i = 0
      while i < 3
        acc += steps.empty? ? 1 : steps.first
        @acc = acc
        wait
        i += 1
      end
      [acc, steps, i]
    end

    def run_opt(base, step = base * 2, *more)
      acc = base
      i = 0
      while i < 3
        acc += step + more.size
        @acc = acc
        wait
        i += 1
      end
      [acc, step, more, i]
    end

    def wait
      Fiber.yield @acc
    end

    def go
      @f.resume
    end
  end
RUBY

OWNERS = %w[RestClock].freeze

baseline_dir = Dir.mktmpdir('bc2cpp-resumable-rest')
at_exit { FileUtils.remove_entry(baseline_dir) }
puts '-- generated code'
code, baseline_err = Bc2cppFixtureRuntime.generate(SRC, baseline_dir, core: true, only_owners: OWNERS)
check.call('run compiles as a resumable step function', code.include?('static mrb_value RestClock_run_step(mrb_state* M'))
check.call('run_opt compiles as a resumable step function', code.include?('static mrb_value RestClock_run_opt_step(mrb_state* M'))
check.call('the impl takes the rest as an Array argument',
           code.match?(/^mrb_value RestClock_run_impl\(mrb_state\* M, mrb_value self, mrb_value \w+, mrb_value \w+\) \{/))
run_body = code[/^mrb_value RestClock_run_impl\(.*?\n\}\n/m].to_s
check.call('the impl of run checks no argument count itself', !run_body.empty? && !run_body.include?('bc2cpp_check_argc'))
check.call('the impl of run_opt takes the given count after the rest',
           code.match?(/^mrb_value RestClock_run_opt_impl\(mrb_state\* M, mrb_value self, mrb_value \w+, mrb_value \w+, mrb_value \w+, mrb_int bc2cpp_given_opt\) \{/))
check.call('the wrapper checks the count and builds the rest Array',
           code.include?('bc2cpp_check_argc(M, 1, -1);') && code.include?('mrb_ary_new_from_values(M, bc2cpp_rest_len, bc2cpp_rest_ptr)'))
check.call('no #error in the generated code', !code.include?('#error'))

DRIVER = <<~'RUBY'
  objs = [:a, :b, :c, :d, :e, :f].each_with_index.map { |k, i| RestClock.new.make(k, i + 1) }
  out = []
  4.times do
    objs.each { |o| out << o.go }
    GC.start
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
    # MRI's own output for the driver: each frame keeps its rest Array and its given optional count.
    check.call('the compiled run prints what MRI prints',
               compiled&.first == '[2, 7, 8, 12, 8, 11, 3, 12, 13, 20, 11, 16, 4, 17, 18, 28, 14, 21, [4, [], 3], [17, [5], 3], [18, [5, 6], 3], [28, 8, [], 3], [14, 3, [], 3], [21, 3, [4, 9], 3]]')
    if interpreted && compiled
      interpreted.zip(compiled).reject { |a, b| a == b }.first(10).each { |a, b| puts "    interpreted: #{a}\n    compiled:    #{b}" }
    end
    puts output.lines.last(30).join unless built && interpreted && compiled
  end
end

if failures.empty?
  puts 'bc2cpp resumable rest check: PASS'
else
  warn "bc2cpp resumable rest check: #{failures.size} failure(s)"
  exit 1
end
