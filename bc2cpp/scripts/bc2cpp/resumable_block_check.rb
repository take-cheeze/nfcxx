#!/usr/bin/env ruby
# encoding: UTF-8
# frozen_string_literal: true

# RESUMABLE_BLOCK_CALL (tools/bc2cpp/codegen_resumable.rb resumable_block_site): a resumable method that yields to its
# own block suspends with the yielded values, and the bytecode driver calls the block (Bc2cppResumable.drive). A
# Fiber.yield inside that block then has only VM frames to cross.
#
#   generated code (needs a host mrbc)
#     - the step function reads its block from the frame and yields with BLKCALL as a block-call suspension;
#     - the entry takes the block and stores it in the frame; the driver calls it on a block-call suspension.
#   behaviour (needs a full-core libmruby, see Bc2cppFixtureRuntime.full_or_build)
#     - interpreted and compiled runs print the same: a fiber body passes a block that yields to the
#       Fiber, and the method yields to that block from its own loop.
#
# Usage: MRBC=path/to/mrbc [BC2CPP_MRUBY_FULL=dir | BC2CPP_FULL_BUILD_DIR=dir] ruby scripts/bc2cpp/resumable_block_check.rb

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

# RbClock#each_mark is a Fiber root called with a block from the Fiber body; it yields to that block from its loop.
SRC = <<~'RUBY'
  class RbClock
    def start
      @fiber = Fiber.new { each_mark { |x| Fiber.yield x * 10 } }
    end

    def each_mark(&blk)
      i = 0
      while i < 3
        yield i
        i += 1
      end
      :done
    end

    def go
      @fiber.resume
    end
  end
RUBY

OWNERS = %w[RbClock].freeze

baseline_dir = Dir.mktmpdir('bc2cpp-resumable-block')
at_exit { FileUtils.remove_entry(baseline_dir) }
puts '-- generated code'
code, baseline_err = Bc2cppFixtureRuntime.generate(SRC, baseline_dir, core: true, only_owners: OWNERS)
check.call('each_mark compiles as a resumable step function', code.include?('static mrb_value RbClock_each_mark_step(mrb_state* M'))
check.call('the entry takes the block', code.match?(/^mrb_value RbClock_each_mark_impl\(mrb_state\* M, mrb_value self, mrb_value bc2cpp_blk\) \{/))
check.call('the step suspends for the block call', code.include?('// RESUMABLE_BLOCK_CALL'))
check.call('the driver calls the block on a block-call suspension', code.include?('"block_call?"'))
check.call('no #error in the generated code', !code.include?('#error'))

DRIVER = <<~'RUBY'
  a = RbClock.new
  a.start
  out = []
  3.times { out << a.go; GC.start }
  out << a.go
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
    check.call('the yields reach the fiber (0, 10, 20, then :done)', interpreted&.first == '[0, 10, 20, :done]')
    if interpreted && compiled
      interpreted.zip(compiled).reject { |a, b| a == b }.first(10).each { |a, b| puts "    interpreted: #{a}\n    compiled:    #{b}" }
    end
    puts output.lines.last(30).join unless built && interpreted && compiled
  end
end

if failures.empty?
  puts 'bc2cpp resumable block check: PASS'
else
  warn "bc2cpp resumable block check: #{failures.size} failure(s)"
  exit 1
end
