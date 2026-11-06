#!/usr/bin/env ruby
# encoding: UTF-8
# frozen_string_literal: true

# FIBER_BODY_STEP (tools/bc2cpp/codegen_resumable.rb emit_fiber_body_step_site): a Fiber.new body that is not a single
# tail call (several calls to suspendable methods, a Fiber.yield of its own, a result used after a call) is compiled as
# a step, and the C++ Fiber's root frame is that step's frame. Its calls to suspendable methods are CALLs.
#
#   generated code (needs a host mrbc)
#     - the body compiles as a step and the site builds the fiber from it (bc2cpp_fiber_new_step);
#   behaviour (needs a full-core libmruby, see Bc2cppFixtureRuntime.full_or_build)
#     - interpreted and compiled runs print the same: yields from the helpers and from the body itself, resumed with
#       values the body uses, and the body's result is the fiber's.
#
# Usage: MRBC=path/to/mrbc [BC2CPP_MRUBY_FULL=dir | BC2CPP_FULL_BUILD_DIR=dir] ruby scripts/bc2cpp/fiber_body_step_check.rb

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

# The body asks twice and yields a value of its own between the two calls; it returns what it collected.
SRC = <<~'RUBY'
  class FbClock
    def start
      @fiber = Fiber.new do
        a = ask(3)
        mid = Fiber.yield a * 100
        b = ask(4)
        [a, mid, b]
      end
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

OWNERS = %w[FbClock].freeze

baseline_dir = Dir.mktmpdir('bc2cpp-fiber-body-step')
at_exit { FileUtils.remove_entry(baseline_dir) }
puts '-- generated code'
code, baseline_err = Bc2cppFixtureRuntime.generate(SRC, baseline_dir, core: true, only_owners: OWNERS)
check.call('the body compiles as a step', code.match?(/static mrb_value FbClock_start__blk\d+_step\(mrb_state\* M/))
check.call('the site builds the fiber from the step', code.include?('bc2cpp_fiber_new_step(M, '))
check.call('the body calls ask as a CALL', code.include?('// RESUMABLE_CALL'))
check.call('no #error in the generated code', !code.include?('#error'))

DRIVER = <<~'RUBY'
  a = FbClock.new
  a.start
  out = []
  out << a.go
  GC.start
  out << a.go_with(10)
  out << a.go_with(7)
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
    check.call('the body combines the helper results and its own yield',
               interpreted&.first == '[3, 1300, 4, [13, 7, 24], false]')
    if interpreted && compiled
      interpreted.zip(compiled).reject { |a, b| a == b }.first(10).each { |a, b| puts "    interpreted: #{a}\n    compiled:    #{b}" }
    end
    puts output.lines.last(30).join unless built && interpreted && compiled
  end
end

if failures.empty?
  puts 'bc2cpp fiber body step check: PASS'
else
  warn "bc2cpp fiber body step check: #{failures.size} failure(s)"
  exit 1
end
