#!/usr/bin/env ruby
# encoding: UTF-8
# frozen_string_literal: true

# FIBER_TRANSFER (tools/bc2cpp/runtime/bc2cpp_fiber.hxx): the rest of the Fiber API on the C++ Fiber, with the fiber
# bodies compiled (a probe class per scenario, so no body runs on mruby-fiber):
#
#   - Fiber#transfer between the root and a fiber (a transfer back to the fiber's resumer is a yield of the value, a
#     transfer to the fiber is a resume), and Fiber.current at the root;
#   - a fiber resumed from inside another fiber's step (block parameters bound from resume arguments, resume(3, 4)
#     packed into one value);
#   - the FiberError cases: a dead fiber, a fiber resumed twice, a fiber resuming itself, a resumed fiber transferred to.
#
#   generated code (needs a host mrbc)
#     - the bodies compile as steps, and no #error is left;
#   behaviour (needs a full-core libmruby, see Bc2cppFixtureRuntime.full_or_build)
#     - interpreted and compiled runs print the same line for every scenario.
#
# Usage: MRBC=path/to/mrbc [BC2CPP_MRUBY_FULL=dir | BC2CPP_FULL_BUILD_DIR=dir] ruby scripts/bc2cpp/fiber_transfer_check.rb

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

# State the bodies read lives in instance variables: a Fiber body does not capture the locals of the method building it.
SRC = <<~'RUBY'
  class FtTransfer
    def start
      @main = Fiber.current
      @f = Fiber.new do
        resumed = @main.transfer(:yielded)
        [:done, resumed]
      end
    end

    def first
      @f.transfer
    end

    def second
      @f.transfer(:resumed)
    end

    def fiber_alive
      @f.alive?
    end

    def main_is_current
      @main.equal?(Fiber.current)
    end
  end

  class FtNested
    def start
      @outer = Fiber.new do |a|
        @a = a
        @inner = Fiber.new do |b|
          Fiber.yield [@a, b]
          :inner_done
        end
        first = @inner.resume(2)
        resumed = Fiber.yield(first)
        [resumed, @inner.resume, @inner.alive?]
      end
    end

    def go(*args)
      @outer.resume(*args)
    end
  end

  class FtErrors
    def start
      @self_resuming = Fiber.new { @self_resuming.resume }
      @short = Fiber.new { :short }
      @a = Fiber.new { @b.resume }
      @b = Fiber.new { @a.resume }
      @yielder = Fiber.new do
        Fiber.yield 1
        2
      end
    end

    def resume_self
      @self_resuming.resume
    end

    def resume_dead
      @short.resume
      @short.resume
    end

    def resume_resuming
      @a.resume
    end

    def transfer_to_yielded
      @yielder.resume
      @yielder.transfer
    end

    def start_more
      @main = Fiber.current
      @away = Fiber.new do
        @main.transfer(1)
        2
      end
      @yields_after_transfer = Fiber.new { Fiber.yield 3 }
      @c = Fiber.new { @d.transfer }
      @d = Fiber.new { @c.resume }
    end

    def resume_transferred
      @away.transfer
      @away.resume
    end

    def yield_after_transfer
      @yields_after_transfer.transfer
    end

    def transfer_to_resuming
      @c.resume
    end
  end

  class FtChain
    def start
      @main = Fiber.current
      @g = Fiber.new do
        r = @f.transfer(:to_f)
        [:g_done, r]
      end
      @f = Fiber.new do
        @g.transfer(:from_f)
        :f_done
      end
    end

    def run
      @g.transfer
    end

    def alive
      [@g.alive?, @f.alive?]
    end
  end
RUBY

OWNERS = %w[FtTransfer FtNested FtErrors FtChain].freeze

baseline_dir = Dir.mktmpdir('bc2cpp-fiber-transfer')
at_exit { FileUtils.remove_entry(baseline_dir) }
puts '-- generated code'
code, baseline_err = Bc2cppFixtureRuntime.generate(SRC, baseline_dir, core: true, only_owners: OWNERS)
%w[FtTransfer FtNested FtErrors FtChain].each do |owner|
  check.call("#{owner}'s fiber bodies compile as steps", code.match?(/static mrb_value #{owner}_start__blk\d+_step\(mrb_state\* M/))
end
check.call('no #error in the generated code', !code.include?('#error'))

DRIVER = <<~'RUBY'
  def show(label)
    puts "#{label}: #{yield.inspect}"
  rescue StandardError => e
    puts "#{label}: raised #{e.class}: #{e.message}"
  end

  t = FtTransfer.new
  t.start
  show('transfer out') { t.first }
  show('transfer alive') { t.fiber_alive }
  show('transfer back') { t.second }
  show('transfer dead') { t.fiber_alive }
  show('root is current') { t.main_is_current }

  n = FtNested.new
  n.start
  show('nested first') { n.go(1) }
  GC.start
  show('nested second') { n.go(3, 4) }

  e = FtErrors.new
  e.start
  show('resume self') { e.resume_self }
  show('resume dead') { e.resume_dead }
  show('resume resuming') { e.resume_resuming }
  show('transfer to yielded') { e.transfer_to_yielded }

  m = FtErrors.new
  m.start
  m.start_more
  show('resume transferred') { m.resume_transferred }
  show('yield after transfer') { m.yield_after_transfer }
  show('transfer to resuming') { m.transfer_to_resuming }

  c = FtChain.new
  c.start
  show('chain') { c.run }
  show('chain alive') { c.alive }
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
    if interpreted && compiled
      interpreted.zip(compiled).reject { |a, b| a == b }.first(12).each { |a, b| puts "    interpreted: #{a}\n    compiled:    #{b}" }
    end
    puts output.lines.last(30).join if ENV['FT_SHOW'] || !(built && interpreted && compiled)
  end
end

if failures.empty?
  puts 'bc2cpp fiber transfer check: PASS'
else
  warn "bc2cpp fiber transfer check: #{failures.size} failure(s)"
  exit 1
end
