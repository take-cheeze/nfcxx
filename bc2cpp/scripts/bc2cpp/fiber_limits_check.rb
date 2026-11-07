#!/usr/bin/env ruby
# encoding: UTF-8
# frozen_string_literal: true

# The known gaps of the C++ Fiber (docs/bc2cpp-cxx-fiber.md, Limits), one scenario each, expected to differ from the
# interpreted run (mruby-fiber) on a no-mruby-fiber build. A differing scenario is an XFAIL (passes); a matching one is an
# XPASS and fails the check: the gap is closed, so remove the scenario and its doc line.
#
# Usage: MRBC=path/to/mrbc [BC2CPP_MRUBY_FULL=dir] [BC2CPP_MRUBY_NOFIBER=dir | BC2CPP_NOFIBER_BUILD_DIR=dir] \
#        ruby scripts/bc2cpp/fiber_limits_check.rb

require_relative 'fixture_runtime'

suite = Bc2cppStepCheck.new('bc2cpp Fiber limits check')

# [label, why it differs, body of a probe method returning the Fiber to drain, world]. The method is compiled, the driver is not.
# World :proc_ext adds mruby-proc-ext's Ruby (Proc#curry) to the closed world; it upsets the Enumerator ones, so it is its own.
LIMITS = [
  ['curry', 'Fiber.yield in a curried lambda (Proc#curry builds lambdas, so it stays bytecode)',
   'Fiber.new { add = lambda { |a, b| Fiber.yield a; a + b }.curry; add[1][2] }', :proc_ext],
  ['lazy', 'Fiber.yield in a block of Enumerator::Lazy (its generator is a super block of Lazy#initialize)',
   'Fiber.new { [1, 2].lazy.map { |x| Fiber.yield x; x * 2 }.first(2) }'],
  ['Fiber#raise', 'Fiber#raise on an mruby-fiber Fiber is a NoMethodError',
   'Fiber.new { g = Fiber.new { Fiber.yield 1 }; g.resume; begin; g.raise(IOError, "x"); rescue IOError => e; e.message; end }']
].freeze

PROBE = lambda do |limits|
  <<~RUBY
    class LimitsProbe
  #{limits.each_with_index.map { |(_, _, body), i| "    def limit_#{i}\n        #{body}\n      end\n" }.join("\n")}
    end
  RUBY
end

OWNERS = %w[LimitsProbe Array Enumerable Hash Integer Range Kernel Proc Enumerator].freeze
EXTRA_RUBY = {
  lazy: '3rd/mruby/mrbgems/mruby-enum-lazy/mrblib/lazy.rb',
  proc_ext: '3rd/mruby/mrbgems/mruby-proc-ext/mrblib/proc.rb'
}.freeze

full = Bc2cppFixtureRuntime.full_or_build
nofiber = Bc2cppFixtureRuntime.nofiber_or_build
# As native_fiber_check: the core mrblib of the gems the no-fiber build has, and the extra gems' as plain Ruby.
core_gems = BC2CPP_CANONICAL_CORE_GEMS - Bc2cppFixtureRuntime::NOFIBER_GEMS - %w[mruby-stringio]

if nofiber.nil? || full.nil? || ENV['CC_GENERATED_ONLY'] == '1'
  puts '  SKIP behavioural comparison: needs a full-core libmruby and a no-fiber one (BC2CPP_MRUBY_FULL, BC2CPP_MRUBY_NOFIBER, or rake, g++ and 3rd/mruby)'
  suite.finish
  exit 0
end

LIMITS.group_by { |limit| limit[3] }.each do |world, limits|
  puts "-- #{limits.size} limit(s)#{" with #{world}" if world}: compiled on mruby without mruby-fiber, interpreted with it"
  extra = [EXTRA_RUBY[:lazy], *EXTRA_RUBY[world]].map { |path| [path, File.read(File.join(Bc2cppFixtureRuntime::ROOT, path))] }
  suite.generate(PROBE.call(limits), OWNERS, guards: true, core_gems: core_gems, extra: extra)
  driver = limits.each_with_index.map { |(label, _), i| "show('#{label}') { drain(LimitsProbe.new.limit_#{i}) }" }
  body = <<~CPP
    static int scenario(mrb_state* M) {
      std::fflush(stdout);
      const char* src = R"RBC(#{Bc2cppStepCheck::SHOW}#{Bc2cppStepCheck::DRAIN}#{driver.join("\n")}
puts 'end')RBC";
      mrb_load_string(M, src);
      std::fflush(stdout);
      if (M->exc) { mrb_print_error(M); M->exc = nullptr; return 1; }
      return 0;
    }
  CPP
  reference_built, reference_output = Bc2cppFixtureRuntime.run(suite.dir, suite.err, OWNERS, body, build: full, full: true)
  suite.check('the program builds and runs on the full-core mruby (the reference)', reference_built)
  native_built, native_output = Bc2cppFixtureRuntime.run(suite.dir, suite.err, OWNERS, body, build: nofiber, full: true)
  suite.check('the program builds and links against the no-fiber mruby', native_built)
  expected = Bc2cppFixtureRuntime.sections(reference_output)['interpreted']
  actual = Bc2cppFixtureRuntime.sections(native_output)['compiled']
  suite.check('both runs reach the end', expected&.last == 'end' && actual&.last == 'end')
  unless expected && actual
    puts native_output.lines.last(20).join
    next
  end
  by_label = ->(lines) { lines.reject { |line| line == 'end' }.to_h { |line| line.split(': ', 2) } }
  interpreted = by_label.(expected)
  compiled = by_label.(actual)
  limits.each do |label, why, _|
    if interpreted[label] != compiled[label]
      puts "  XFAIL #{label} (#{why})\n    interpreted: #{interpreted[label]}\n    compiled:    #{compiled[label]}"
      suite.check("#{label}: differs", true)
    else
      puts "  XPASS #{label}: #{interpreted[label]}"
      suite.check("#{label}: gap closed: remove this scenario and the doc line", false)
    end
  end
end
suite.finish
