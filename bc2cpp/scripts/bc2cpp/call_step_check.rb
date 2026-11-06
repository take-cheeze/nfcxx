#!/usr/bin/env ruby
# encoding: UTF-8
# frozen_string_literal: true

# CALL_STEP (tools/bc2cpp/codegen_resumable.rb resumable_call_site): a suspendable method that calls another
# suspendable method with arguments no longer needs the callee inlined. The caller's step makes the callee's frame
# (the callee's entry parks it when its own id is armed) and suspends with it; the C++ Fiber CALLs the frame, the
# callee's Fiber.yield reaches the resumer, and its result is the caller's resume value.
#
#   generated code (needs a host mrbc)
#     - the caller has a call site (RESUMABLE_CALL) and no #error is left;
#   behaviour (needs a full-core libmruby, see Bc2cppFixtureRuntime.full_or_build)
#     - interpreted and compiled runs print the same: two calls with different arguments, each yielding and resumed
#       with a value the callee uses, and the caller combines the results.
#
# Usage: MRBC=path/to/mrbc [BC2CPP_MRUBY_FULL=dir | BC2CPP_FULL_BUILD_DIR=dir] ruby scripts/bc2cpp/call_step_check.rb

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

# CsClock#run calls ask(3) and ask(4); each yields its argument and returns what it was resumed with plus the argument.
SRC = <<~'RUBY'
  class CsClock
    def start
      @fiber = Fiber.new { run }
    end

    def run
      a = ask(3)
      b = ask(4)
      [a, b, a + b]
    end

    def ask(n)
      got = Fiber.yield n
      got.to_i + n
    end

    def go
      @fiber.resume
    end

    def go_with(value)
      @fiber.resume(value)
    end

    def fiber_alive
      @fiber.alive?
    end
  end
RUBY

OWNERS = %w[CsClock].freeze

baseline_dir = Dir.mktmpdir('bc2cpp-call-step')
at_exit { FileUtils.remove_entry(baseline_dir) }
puts '-- generated code'
code, baseline_err = Bc2cppFixtureRuntime.generate(SRC, baseline_dir, core: true, only_owners: OWNERS)
check.call('run compiles as a resumable step function', code.include?('static mrb_value CsClock_run_step(mrb_state* M'))
check.call('ask compiles as a resumable step function', code.include?('static mrb_value CsClock_ask_step(mrb_state* M'))
check.call('run calls ask as a CALL (RESUMABLE_CALL)', code.include?('// RESUMABLE_CALL'))
check.call('no #error in the generated code', !code.include?('#error'))

DRIVER = <<~'RUBY'
  a = CsClock.new
  a.start
  out = []
  out << a.go
  GC.start
  out << a.go_with(10)
  GC.start
  out << a.go_with(20)
  out << a.fiber_alive
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
        const char* src = R"RBC(#{DRIVER})RBC";
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
    check.call('both runs reach the end', interpreted&.last == 'end' && compiled&.last == 'end')
    check.call('interpreted and compiled runs print the same', interpreted == compiled)
    check.call('each call yields its argument and the results combine', interpreted&.first == '[3, 4, [13, 24, 37], false]')
    if interpreted && compiled
      interpreted.zip(compiled).reject { |a, b| a == b }.first(10).each { |a, b| puts "    interpreted: #{a}\n    compiled:    #{b}" }
    end
    puts output.lines.last(30).join unless built && interpreted && compiled
  end
end

if failures.empty?
  puts 'bc2cpp call step check: PASS'
else
  warn "bc2cpp call step check: #{failures.size} failure(s)"
  exit 1
end
