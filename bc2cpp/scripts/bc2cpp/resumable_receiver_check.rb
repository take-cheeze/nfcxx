#!/usr/bin/env ruby
# encoding: UTF-8
# frozen_string_literal: true

# RECEIVER_ROOTS (tools/bc2cpp/codegen_block_fallback.rb, codegen_method.rb): a Fiber.new body that calls a method on
# another receiver (`arr.each_index { ... }`) makes every definition of that name a candidate fiber root. A core
# iterator that yields to its block is then compiled as a resumable step function, so a Fiber.yield in the block
# suspends through the bytecode driver's VM frames only.
#
#   generated code (needs a host mrbc)
#     - Array#each_index is a resumable step function, and its entry takes the block.
#   behaviour (needs a full-core libmruby, see Bc2cppFixtureRuntime.full_or_build)
#     - interpreted and compiled runs print the same: a fiber yields each index of an array, then the array.
#
# Usage: MRBC=path/to/mrbc [BC2CPP_MRUBY_FULL=dir | BC2CPP_FULL_BUILD_DIR=dir] ruby scripts/bc2cpp/resumable_receiver_check.rb

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

# RvClock#start's fiber body calls each_index on an array it was given: a method on another receiver.
SRC = <<~'RUBY'
  class RvClock
    def start(arr)
      @fiber = Fiber.new { arr.each_index { |i| Fiber.yield i } }
    end

    def go
      @fiber.resume
    end
  end
RUBY

OWNERS = %w[RvClock Array].freeze

baseline_dir = Dir.mktmpdir('bc2cpp-resumable-receiver')
at_exit { FileUtils.remove_entry(baseline_dir) }
puts '-- generated code'
code, baseline_err = Bc2cppFixtureRuntime.generate(SRC, baseline_dir, core: true, only_owners: OWNERS)
check.call('Array#each_index compiles as a resumable step function (its variant)', code.include?('static mrb_value Array_each_index_rsm_step(mrb_state* M'))
check.call('the entry takes the block', code.match?(/^mrb_value Array_each_index_impl\(mrb_state\* M, mrb_value self, mrb_value bc2cpp_blk\) \{/))
check.call('no #error in the generated code', !code.include?('#error'))

DRIVER = <<~'RUBY'
  a = RvClock.new
  arr = [10, 20, 30]
  a.start(arr)
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
        const char* src = R"RRC(#{DRIVER})RRC";
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
    check.call('the fiber yields 0, 1, 2 and then the array', interpreted&.first == '[0, 1, 2, [10, 20, 30]]')
    if interpreted && compiled
      interpreted.zip(compiled).reject { |a, b| a == b }.first(10).each { |a, b| puts "    interpreted: #{a}\n    compiled:    #{b}" }
    end
    puts output.lines.last(30).join unless built && interpreted && compiled
  end
end

if failures.empty?
  puts 'bc2cpp resumable receiver check: PASS'
else
  warn "bc2cpp resumable receiver check: #{failures.size} failure(s)"
  exit 1
end
