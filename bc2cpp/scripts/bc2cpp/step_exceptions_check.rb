#!/usr/bin/env ruby
# encoding: UTF-8
# frozen_string_literal: true

# STEP_HANDLERS (tools/bc2cpp/codegen_resumable.rb resumable_step_function, runtime/bc2cpp_fiber.hxx bc2cpp_fiber_unwind): a
# step may have rescue and ensure handlers, and an exception, a break/return or a throw crosses suspensions.
#
#   generated code (needs a host mrbc)
#     - the methods and blocks with handlers compile as steps, and no #error is left;
#   behaviour (needs a full-core libmruby, see Bc2cppFixtureRuntime.full_or_build)
#     - the fiber bodies of a compiled probe class (nothing here is eval'd) print what the interpreted run prints:
#       begin/rescue/ensure around Fiber.yield in blocks, an exception raised after a resume that crosses CALL frames to a
#       handler in a parent step and out of Fiber#resume (alive? false afterwards), and catch/throw after a yield.
#
# Usage: MRBC=path/to/mrbc [BC2CPP_MRUBY_FULL=dir | BC2CPP_FULL_BUILD_DIR=dir] ruby scripts/bc2cpp/step_exceptions_check.rb

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

# Every scenario is a method returning the Fiber to run, so the bodies, the methods they call and their blocks are compiled.
SRC = <<~'RUBY'
  class StepExc
    attr_reader :events

    def initialize
      @events = []
    end

    # The iterator the blocks run under: it yields to its block, so the block's Fiber.yield suspends through this frame.
    def each3
      i = 1
      while i <= 3
        yield i
        i += 1
      end
      self
    end

    # begin/rescue/ensure around a yielding iterator, and begin/ensure inside its block.
    def nested_ensure
      Fiber.new do
        begin
          each3 do |x|
            begin
              Fiber.yield x
              raise ArgumentError, 'after resume' if x == 2
            ensure
              @events << x
            end
          end
        rescue ArgumentError => e
          @events << e.message
        ensure
          @events << :outer
        end
        :done
      end
    end

    # Yields, then raises: the exception leaves this frame after a resume.
    def boom(n)
      Fiber.yield n
      raise ArgumentError, "boom #{n}"
    end

    # A handler in the parent step takes what the CALLed frame raises.
    def caught_by_parent
      Fiber.new do
        begin
          boom(1)
        rescue ArgumentError => e
          Fiber.yield e.message
        end
        :after
      end
    end

    # No handler anywhere: the exception leaves Fiber#resume.
    def uncaught
      Fiber.new { boom(2) }
    end

    # Two frames deep: the exception crosses an intermediate frame that has none, and an ensure on the way runs.
    def middle
      begin
        boom(3)
      ensure
        @events << :middle_ensure
      end
    end

    def through_two_frames
      Fiber.new do
        begin
          middle
        rescue ArgumentError => e
          @events << e.message
        end
        :end
      end
    end

    # An exception raised in the step itself, after a resume, caught in the same step; the rescue value is the result.
    def local_rescue
      Fiber.new do
        v = Fiber.yield :first
        begin
          raise ArgumentError, "got #{v}"
        rescue ArgumentError => e
          e.message
        end
      end
    end

    # A handler for another class does not take it.
    def wrong_class
      Fiber.new do
        begin
          boom(4)
        rescue TypeError
          :wrong
        end
      end
    end

    # catch/throw across a Fiber.yield.
    def catch_throw
      Fiber.new { catch(:tag) { |tag| Fiber.yield tag; throw tag, :caught } }
    end

    # throw out of a nested call, with an ensure on the way.
    def deep(tag)
      begin
        Fiber.yield :in_deep
        throw tag, :thrown
      ensure
        @events << :deep_ensure
      end
    end

    def catch_deep
      Fiber.new { [catch(:t) { |t| deep(t); :not_reached }, :after] }
    end

    # An iterator with an ensure around its yields: a `break` out of its block ends it from outside, and the ensure runs.
    def each_ens
      i = 1
      begin
        while i <= 3
          yield i
          i += 1
        end
      ensure
        @events << :each_ens
      end
      :finished
    end

    def break_through_ensure
      Fiber.new do
        r = each_ens do |x|
          Fiber.yield x
          break x * 10 if x == 2
        end
        [r, :after]
      end
    end

    def normal_through_ensure
      Fiber.new { [each_ens { |x| Fiber.yield x }, :after] }
    end
  end
RUBY

OWNERS = %w[StepExc].freeze

baseline_dir = Dir.mktmpdir('bc2cpp-step-exceptions')
at_exit { FileUtils.remove_entry(baseline_dir) }
puts '-- generated code'
code, baseline_err = Bc2cppFixtureRuntime.generate(SRC, baseline_dir, core: true, only_owners: OWNERS)
check.call('nested_ensure compiles as a step', code.include?('static mrb_value StepExc_nested_ensure__blk') && code.include?('_step(mrb_state* M'))
check.call('a step has a handler loop', code.include?('mrb_protect_error(M, bc2cpp_protect_tramp'))
check.call('no #error in the generated code', !code.include?('#error'))

DRIVER = <<~'RUBY'
  def show(label)
    puts "#{label}: #{yield.inspect}"
  rescue StandardError => e
    puts "#{label}: raised #{e.class}: #{e.message}"
  end

  def drain(f)
    out = []
    while f.alive?
      out << f.resume
      GC.start
    end
    out
  end

  o = StepExc.new
  show('nested ensure') { [drain(o.nested_ensure), o.events] }
  o = StepExc.new
  show('caught by parent') { drain(o.caught_by_parent) }
  o = StepExc.new
  show('uncaught') do
    f = o.uncaught
    first = f.resume
    err = begin
      f.resume
    rescue ArgumentError => e
      e.message
    end
    [first, err, f.alive?]
  end
  o = StepExc.new
  show('through two frames') { [drain(o.through_two_frames), o.events] }
  o = StepExc.new
  show('local rescue') do
    f = o.local_rescue
    [f.resume, f.resume(7), f.alive?]
  end
  o = StepExc.new
  show('wrong class') do
    f = o.wrong_class
    first = f.resume
    err = begin
      f.resume
    rescue ArgumentError => e
      e.message
    end
    [first, err, f.alive?]
  end
  o = StepExc.new
  show('catch throw') { drain(o.catch_throw) }
  o = StepExc.new
  show('catch deep') { [drain(o.catch_deep), o.events] }
  o = StepExc.new
  show('break through ensure') { [drain(o.break_through_ensure), o.events] }
  o = StepExc.new
  show('normal through ensure') { [drain(o.normal_through_ensure), o.events] }
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
    expected = {
      'nested ensure' => 'nested ensure: [[1, 2, :done], [1, 2, "after resume", :outer]]',
      'caught by parent' => 'caught by parent: [1, "boom 1", :after]',
      'uncaught' => 'uncaught: [2, "boom 2", false]',
      'through two frames' => 'through two frames: [[3, :end], [:middle_ensure, "boom 3"]]',
      'local rescue' => 'local rescue: [:first, "got 7", false]',
      'wrong class' => 'wrong class: [4, "boom 4", false]',
      'catch throw' => 'catch throw: [:tag, :caught]',
      'catch deep' => 'catch deep: [[:in_deep, [:thrown, :after]], [:deep_ensure]]',
      'break through ensure' => 'break through ensure: [[1, 2, [20, :after]], [:each_ens]]',
      'normal through ensure' => 'normal through ensure: [[1, 2, 3, [:finished, :after]], [:each_ens]]'
    }
    expected.each do |label, line|
      check.call("#{label} prints what Ruby does", interpreted&.include?(line))
    end
    if interpreted && compiled
      interpreted.zip(compiled).reject { |a, b| a == b }.first(10).each { |a, b| puts "    interpreted: #{a}\n    compiled:    #{b}" }
    end
    puts output.lines.last(30).join unless built && interpreted && compiled
  end
end

if failures.empty?
  puts 'bc2cpp step exceptions check: PASS'
else
  warn "bc2cpp step exceptions check: #{failures.size} failure(s)"
  exit 1
end
