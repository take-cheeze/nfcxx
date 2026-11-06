#!/usr/bin/env ruby
# encoding: UTF-8
# frozen_string_literal: true

# BLOCKS_IN_STEPS (tools/bc2cpp/codegen_resumable.rb resumable_block_call_glue): a resumable step may build blocks.
#
#   - a block that cannot suspend and captures the step's locals runs as in any method (the callee is synchronous);
#   - a call on self to a suspendable method with a literal block whose own body reaches Fiber.yield becomes a CALL
#     carrying the block's heap proc (with its step maker), so the callee's `yield` CALLs the block's step.
#
#   generated code (needs a host mrbc)
#     - the caller and the block compile as steps, the call carries RESUMABLE_CALL, and no #error is left;
#   behaviour (needs a full-core libmruby, see Bc2cppFixtureRuntime.full_or_build)
#     - interpreted and compiled runs print the same.
#
# Usage: MRBC=path/to/mrbc [BC2CPP_MRUBY_FULL=dir | BC2CPP_FULL_BUILD_DIR=dir] ruby scripts/bc2cpp/block_in_step_check.rb

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

# BiClock#run builds a local-capturing block, then calls each_mark with a block that yields to the fiber.
SRC = <<~'RUBY'
  class BiClock
    def start
      @fiber = Fiber.new { run }
    end

    def run
      xs = []
      [1, 2, 3].each { |v| xs << v * 2 }
      got = Fiber.yield xs.size
      ys = []
      xs.each { |v| ys << v + got.to_i }
      marks = each_mark(2) { |x| back = Fiber.yield x; back.to_i + 1 }
      [xs, ys, marks]
    end

    def each_mark(n)
      out = []
      i = 0
      while i < n
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

OWNERS = %w[BiClock].freeze

baseline_dir = Dir.mktmpdir('bc2cpp-block-in-step')
at_exit { FileUtils.remove_entry(baseline_dir) }
puts '-- generated code'
code, baseline_err = Bc2cppFixtureRuntime.generate(SRC, baseline_dir, core: true, only_owners: OWNERS)
check.call('run compiles as a resumable step function', code.include?('static mrb_value BiClock_run_step(mrb_state* M'))
check.call('each_mark compiles as a resumable step function', code.include?('static mrb_value BiClock_each_mark_step(mrb_state* M'))
check.call('the block compiles as a resumable step', code.match?(/static mrb_value BiClock_run__blk\d+_step\(mrb_state\* M/))
check.call('run calls each_mark with its block as a CALL (RESUMABLE_CALL)', code.include?('// RESUMABLE_CALL'))
check.call('no #error in the generated code', !code.include?('#error'))

DRIVER = <<~'RUBY'
  a = BiClock.new
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
    check.call('the local-capturing block and the yielding block both give their values', interpreted&.first == '[3, 0, 1, [[2, 4, 6], [12, 14, 16], [21, 31]], false]')
    if interpreted && compiled
      interpreted.zip(compiled).reject { |a, b| a == b }.first(10).each { |a, b| puts "    interpreted: #{a}\n    compiled:    #{b}" }
    end
    puts output.lines.last(30).join unless built && interpreted && compiled
  end
end

if failures.empty?
  puts 'bc2cpp block in step check: PASS'
else
  warn "bc2cpp block in step check: #{failures.size} failure(s)"
  exit 1
end
