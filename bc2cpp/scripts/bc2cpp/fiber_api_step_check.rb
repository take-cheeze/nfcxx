#!/usr/bin/env ruby
# encoding: UTF-8
# frozen_string_literal: true

# FIBER_API (tools/bc2cpp/runtime/bc2cpp_fiber.hxx, codegen_resumable.rb): the parts of the Fiber API a compiled body
# can use on the C++ Fiber with no mruby-fiber fiber under it.
#
#   - the body's block parameters bind from the first resume's arguments (`Fiber.new { |a, b| ... }.resume(1, 2)`);
#   - `Fiber.yield a, b` hands the resumer [a, b]; `resume(a, b)` makes Fiber.yield return [a, b];
#   - Fiber.current is the C++ Fiber inside it and the root fiber outside;
#   - a fiber whose body raised is dead.
#
#   generated code (needs a host mrbc)
#     - the bodies compile as steps, and no #error is left;
#   behaviour (needs a full-core libmruby, see Bc2cppFixtureRuntime.full_or_build)
#     - interpreted and compiled runs print the same.
#
# Usage: MRBC=path/to/mrbc [BC2CPP_MRUBY_FULL=dir | BC2CPP_FULL_BUILD_DIR=dir] ruby scripts/bc2cpp/fiber_api_step_check.rb

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

# FaClock's body takes parameters, yields several values and reads Fiber.current; FaBoom's body raises after a yield.
SRC = <<~'RUBY'
  class FaClock
    def start
      @fiber = Fiber.new do |a, b|
        first = Fiber.yield(a, b)
        second = Fiber.yield(first)
        third = Fiber.yield
        Fiber.yield(1, 2, 3)
        [a, b, first, second, third, Fiber.current.equal?(@fiber)]
      end
    end

    def go(*args)
      @fiber.resume(*args)
    end

    def current_is_fiber
      Fiber.current.equal?(@fiber)
    end

    def fiber_alive
      @fiber.alive?
    end
  end

  class FaBoom
    def start
      @fiber = Fiber.new do
        Fiber.yield 1
        raise 'boom'
      end
    end

    def go
      @fiber.resume
    end

    def fiber_alive
      @fiber.alive?
    end
  end
RUBY

OWNERS = %w[FaClock FaBoom].freeze

baseline_dir = Dir.mktmpdir('bc2cpp-fiber-api')
at_exit { FileUtils.remove_entry(baseline_dir) }
puts '-- generated code'
code, baseline_err = Bc2cppFixtureRuntime.generate(SRC, baseline_dir, core: true, only_owners: OWNERS)
check.call('the body with parameters compiles as a step', code.match?(/static mrb_value FaClock_start__blk\d+_step\(mrb_state\* M/))
check.call('the body that raises compiles as a step', code.match?(/static mrb_value FaBoom_start__blk\d+_step\(mrb_state\* M/))
check.call('no #error in the generated code', !code.include?('#error'))

DRIVER = <<~'RUBY'
  a = FaClock.new
  a.start
  out = []
  out << a.go(1, 2)          # a=1, b=2; yields [1, 2]
  GC.start
  out << a.go(:x, :y)        # Fiber.yield returned [:x, :y]; yields it
  out << a.go(9)             # second=9; Fiber.yield with no value yields nil
  out << a.go                # third=nil; yields [1, 2, 3]
  out << a.current_is_fiber  # outside the fiber
  out << a.go(7)             # the body finishes
  out << a.fiber_alive
  p out
  b = FaBoom.new
  b.start
  r = []
  r << b.go
  begin
    b.go
  rescue => e
    r << e.message
  end
  r << b.fiber_alive
  p r
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
    check.call('parameters bind, several values round-trip, Fiber.current is the fiber inside only',
               interpreted&.first == '[[1, 2], [:x, :y], nil, [1, 2, 3], false, [1, 2, [:x, :y], 9, nil, true], false]')
    check.call('a fiber whose body raised is dead', interpreted&.[](1) == '[1, "boom", false]')
    if interpreted && compiled
      interpreted.zip(compiled).reject { |a, b| a == b }.first(10).each { |a, b| puts "    interpreted: #{a}\n    compiled:    #{b}" }
    end
    puts output.lines.last(30).join unless built && interpreted && compiled
  end
end

if failures.empty?
  puts 'bc2cpp fiber api step check: PASS'
else
  warn "bc2cpp fiber api step check: #{failures.size} failure(s)"
  exit 1
end
