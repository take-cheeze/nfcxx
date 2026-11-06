#!/usr/bin/env ruby
# encoding: UTF-8
# frozen_string_literal: true

# BLOCK_STEP (tools/bc2cpp/codegen_resumable.rb block_step_candidate?): a literal block whose Fiber.yield is not its
# last act is compiled a second time as a resumable step. A suspendable method that calls the block makes the C++
# Fiber CALL that step (the block proc's env carries a maker for its frame), so the block's own Fiber.yield suspends
# the fiber, the resumer's value is the yield's result inside the block, and the block's value reaches the method.
#
#   generated code (needs a host mrbc)
#     - the block compiles as a resumable step with a frame maker, and no #error is left;
#   behaviour (needs a full-core libmruby, see Bc2cppFixtureRuntime.full_or_build)
#     - interpreted and compiled runs print the same: three yields, each resumed with a value the block uses, and
#       the method's result (built from the block's values) is the fiber's result.
#
# Usage: MRBC=path/to/mrbc [BC2CPP_MRUBY_FULL=dir | BC2CPP_FULL_BUILD_DIR=dir] ruby scripts/bc2cpp/block_step_check.rb

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

# BsClock#each_mark collects what its block returns; the block yields to the fiber and returns the resumed value + 1.
SRC = <<~'RUBY'
  class BsClock
    def start
      @fiber = Fiber.new { each_mark { |x| got = Fiber.yield x; got.to_i + 1 } }
    end

    def each_mark(&blk)
      out = []
      i = 0
      while i < 3
        out << yield(i)
        i += 1
      end
      out
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

OWNERS = %w[BsClock].freeze

baseline_dir = Dir.mktmpdir('bc2cpp-block-step')
at_exit { FileUtils.remove_entry(baseline_dir) }
puts '-- generated code'
code, baseline_err = Bc2cppFixtureRuntime.generate(SRC, baseline_dir, core: true, only_owners: OWNERS)
check.call('the block compiles as a resumable step', code.match?(/static mrb_value BsClock_start__blk\d+_step\(mrb_state\* M/))
check.call('the block has a frame maker', code.include?('_step_maker(mrb_state* M, struct REnv* bc2cpp_env'))
check.call('the block proc carries the maker (flag bit 2)', code.match?(/mrb_int_value\(M, \d*[4-7]\)/) || code.include?('| 4'))
check.call('no #error in the generated code', !code.include?('#error'))

DRIVER = <<~'RUBY'
  a = BsClock.new
  a.start
  out = []
  out << a.go
  GC.start
  out << a.go_with(10)
  GC.start
  out << a.go_with(20)
  out << a.go_with(30)
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
    check.call('each resumed value reaches the block and the method result is built from them',
               interpreted&.first == '[0, 1, 2, [11, 21, 31], false]')
    if interpreted && compiled
      interpreted.zip(compiled).reject { |a, b| a == b }.first(10).each { |a, b| puts "    interpreted: #{a}\n    compiled:    #{b}" }
    end
    puts output.lines.last(30).join unless built && interpreted && compiled
  end
end

if failures.empty?
  puts 'bc2cpp block step check: PASS'
else
  warn "bc2cpp block step check: #{failures.size} failure(s)"
  exit 1
end
