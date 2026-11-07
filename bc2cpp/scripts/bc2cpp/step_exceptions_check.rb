#!/usr/bin/env ruby
# encoding: UTF-8
# frozen_string_literal: true

# STEP_HANDLERS (codegen_resumable.rb, runtime bc2cpp_fiber_unwind): rescue/ensure/retry, catch/throw and break/return/next out of
# ensure regions across Fiber.yield and CALL frames, in compiled fiber bodies. Output must equal the interpreted run; Fiber#raise
# (absent from mruby-fiber) is held to CRuby's output.
#
# Usage: MRBC=path/to/mrbc [BC2CPP_MRUBY_FULL=dir | BC2CPP_FULL_BUILD_DIR=dir] ruby scripts/bc2cpp/step_exceptions_check.rb

require_relative 'fixture_runtime'

suite = Bc2cppStepCheck.new('bc2cpp step exceptions check')

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

    # The ensure is inside the block that breaks (the block's plain body has an ensure region).
    def break_in_block_ensure
      Fiber.new do
        r = each3 do |x|
          begin
            Fiber.yield x
            break [:b, x] if x == 2
          ensure
            @events << x
          end
        end
        [r, :after]
      end
    end

    def normal_through_ensure
      Fiber.new { [each_ens { |x| Fiber.yield x }, :after] }
    end

    # RETRY: `retry` in a rescue clause runs the protected region again; a suspension inside it survives the jump.
    def retry_basic
      tries = 0
      begin
        tries += 1
        Fiber.yield [:try, tries]
        raise ArgumentError, "t#{tries}" if tries < 3
        [:ok, tries]
      rescue ArgumentError => e
        @events << e.message
        retry
      end
    end

    # retry with an ensure around the whole region: the ensure runs once, at the end, not on each retry.
    def retry_with_ensure
      tries = 0
      begin
        begin
          tries += 1
          Fiber.yield tries
          raise 'again' if tries < 3
          :done
        rescue RuntimeError
          Fiber.yield :retrying
          retry
        end
      ensure
        @events << :ens
      end
    end

    # retry inside a block step and a rescue that does not match first.
    def retry_in_block
      Fiber.new do
        n = 0
        r = each3 do |x|
          begin
            n += 1
            Fiber.yield [x, n]
            raise IOError, 'io' if n % 2 == 1
          rescue IOError
            retry
          end
        end
        [r.class, n]
      end
    end

    # the region calls a suspendable method that raises: the retry runs the CALL again
    def flaky(n)
      Fiber.yield [:flaky, n]
      raise IOError, "f#{n}" if n < 3
      n
    end

    def retry_call
      n = 0
      begin
        n += 1
        flaky(n)
      rescue IOError => e
        @events << e.message
        retry
      end
    end

    # objects made in the protected region live only in registers when the exception is caught: they must survive the handler
    def locals_survive_rescue
      Fiber.new do
        begin
          s = 'kept' + '!'
          a = [s, s.size, s.dup]
          raise ArgumentError, 'x'
        rescue ArgumentError
          Fiber.yield [s, a]
          GC.start
          [s.upcase, a, a[2].frozen?]
        end
      end
    end

    def retry_basic_fiber
      Fiber.new { retry_basic }
    end

    def retry_ensure_fiber
      Fiber.new { retry_with_ensure }
    end

    def retry_call_fiber
      Fiber.new { retry_call }
    end

    # ENSURE_JUMPS: return, next and break out of a begin/ensure region run the ensure body, then continue the jump.
    def ret_in_ensure(flag)
      begin
        Fiber.yield [:in, flag]
        return :early if flag
        @events << :not_early
        :late
      ensure
        @events << [:ens, flag]
      end
    end

    def ret_nested
      begin
        begin
          return :inner
        ensure
          Fiber.yield :ens1
          @events << :e1
        end
      ensure
        @events << :e2
      end
      :unreached
    end

    # the ensure body's own return replaces the pending one
    def ensure_overrides
      begin
        Fiber.yield :a
        return :first
      ensure
        return :second
      end
    end

    # return from a rescue clause that sits inside an ensure
    def ret_from_rescue
      begin
        Fiber.yield :try
        raise ArgumentError, 'r'
      rescue ArgumentError
        return :rescued
      ensure
        @events << :ens_r
      end
      :unreached
    end

    # a bare `return` is RETNIL, which unwinds through the ensure as RETURN does
    def ret_bare(flag)
      begin
        Fiber.yield [:bare, flag]
        return if flag
        @events << :after_bare
      ensure
        @events << [:ens_bare, flag]
      end
      :late
    end

    # an exception raised by the ensure body replaces the pending return
    def ensure_raises_over_return
      begin
        begin
          return :a
        ensure
          raise ArgumentError, 'from ensure'
        end
      rescue ArgumentError => e
        [:rescued, e.message]
      end
    end

    # return from a loop through two nested ensure regions, each suspending in its turn
    def nested_ret_loop
      i = 0
      while i < 3
        i += 1
        begin
          begin
            Fiber.yield i
            return [:ret, i] if i == 2
          ensure
            Fiber.yield [:inner, i]
            @events << [:inner, i]
          end
        ensure
          @events << [:outer, i]
        end
      end
      :end
    end

    def ret_fiber
      Fiber.new do
        [ret_in_ensure(true), ret_in_ensure(false), ret_nested, ensure_overrides, ret_from_rescue,
         ensure_raises_over_return, nested_ret_loop, ret_bare(true), ret_bare(false)]
      end
    end

    def loop_jumps
      i = 0
      r = []
      while i < 5
        i += 1
        begin
          Fiber.yield i
          next if i == 1
          break if i == 3
          r << i
        ensure
          @events << [:ens, i]
        end
      end
      [r, i]
    end

    def loop_jumps_fiber
      Fiber.new { loop_jumps }
    end

    # `next` out of a begin/ensure region of a block step (a `break` or `return` there keeps the block, and so the method, in the
    # interpreter: the plain compile of a block does not take a break out of an ensure region)
    def block_jumps
      Fiber.new do
        r = each3 do |x|
          begin
            Fiber.yield x
            next if x == 1
            next 5 if x == 2
            x
          ensure
            @events << x
          end
        end
        [r.equal?(self), :after]
      end
    end

    # Fiber#raise: delivered at the Fiber.yield the fiber is suspended at.
    def raise_rescued
      Fiber.new do
        begin
          Fiber.yield :waiting
        rescue ArgumentError => e
          @events << [:rescued, e.class, e.message]
          Fiber.yield :after_rescue
        ensure
          @events << :ens
        end
        :finished
      end
    end

    def raise_through
      Fiber.new do
        begin
          each3 do |x|
            begin
              Fiber.yield x
            ensure
              @events << [:blk, x]
            end
          end
        rescue IOError => e
          @events << [:outer, e.message]
          :recovered
        ensure
          @events << :outer_ens
        end
      end
    end

    def raise_deep_helper
      begin
        Fiber.yield :deep
      ensure
        @events << :deep_ens
      end
    end

    def raise_deep
      Fiber.new { [raise_deep_helper, :after] }
    end

    def raise_ensure_yield
      Fiber.new do
        begin
          Fiber.yield 1
        ensure
          Fiber.yield :in_ensure
          @events << :ens_done
        end
      end
    end

    def raise_retry
      Fiber.new do
        n = 0
        begin
          n += 1
          Fiber.yield [:wait, n]
          :ok
        rescue TypeError
          retry
        end
      end
    end

    def raise_nobody
      Fiber.new { Fiber.yield :a; :b }
    end

    def raise_forms
      Fiber.new do
        out = []
        4.times do
          begin
            Fiber.yield out.size
          rescue Exception => e
            out << [e.class, e.message]
          end
        end
        out
      end
    end

    def raise_self
      Fiber.new do
        begin
          Fiber.current.raise(ArgumentError, 'me')
        rescue ArgumentError => e
          [:self, e.message]
        end
      end
    end

    # A fiber cannot raise into one that is waiting on it.
    def raise_resuming
      @outer = Fiber.new { @inner.resume }
      @inner = Fiber.new do
        begin
          @outer.raise(RuntimeError, 'r')
        rescue FiberError => e
          e.class
        end
      end
      @outer
    end
  end

  # No Fiber: `break` and `return` out of a block that has an ensure region around them, in the block's plain compile.
  class PlainEns
    attr_reader :events

    def initialize
      @events = []
    end

    def each2
      yield 1
      yield 2
      :done
    end

    def break_out
      r = each2 do |x|
        begin
          break [x, :broke]
        ensure
          @events << ['e', x].join
        end
      end
      [r, @events]
    end

    def return_out
      each2 do |x|
        begin
          return [x, :returned]
        ensure
          @events << ('g' * 9)
        end
      end
      :not_reached
    end

    def raise_in_ensure
      each2 do |x|
        begin
          break x
        ensure
          raise 'ens' if x == 1
        end
      end
    rescue RuntimeError => e
      [:rescued, e.message]
    end

    def next_out
      each2 do |x|
        begin
          next x
        ensure
          @events << x
        end
      end
    end
  end
RUBY

OWNERS = %w[StepExc PlainEns].freeze
code = suite.generate(SRC, OWNERS)
suite.check('nested_ensure compiles as a step', code.include?('static mrb_value StepExc_nested_ensure__blk') && code.include?('_step(mrb_state* M'))
suite.check('a step has a handler loop', code.include?('mrb_protect_error(M, bc2cpp_protect_tramp'))
%w[break_out return_out raise_in_ensure next_out].each do |name|
  suite.check("PlainEns##{name} compiles", !suite.err.include?("PlainEns##{name}:"))
end

DRIVER = Bc2cppStepCheck::SHOW + Bc2cppStepCheck::DRAIN + <<~'RUBY'
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
  show('break in block ensure') { [drain(o.break_in_block_ensure), o.events] }
  o = StepExc.new
  show('normal through ensure') { [drain(o.normal_through_ensure), o.events] }
  o = StepExc.new
  show('locals survive rescue') { drain(o.locals_survive_rescue) }
  o = StepExc.new
  show('retry basic') { [drain(o.retry_basic_fiber), o.events] }
  o = StepExc.new
  show('retry with ensure') { [drain(o.retry_ensure_fiber), o.events] }
  o = StepExc.new
  show('retry across call') { [drain(o.retry_call_fiber), o.events] }
  o = StepExc.new
  show('retry in block') { [drain(o.retry_in_block), o.events] }
  o = StepExc.new
  show('return through ensure') { [drain(o.ret_fiber), o.events] }
  o = StepExc.new
  show('loop next break through ensure') { [drain(o.loop_jumps_fiber), o.events] }
  o = StepExc.new
  show('block next through ensure') { [drain(o.block_jumps), o.events] }
  o = PlainEns.new
  show('plain break through ensure') { o.break_out }
  show('plain return through ensure') { [o.return_out, o.events] }
  show('plain raise in ensure') { PlainEns.new.raise_in_ensure }
  o = PlainEns.new
  show('plain next through ensure') { [o.next_out, o.events] }
  # Fiber#raise has no interpreted counterpart in mruby-fiber: these lines are compared with CRuby's output instead.
  o = StepExc.new
  show('raise rescued') do
    f = o.raise_rescued
    a = f.resume
    b = f.raise(ArgumentError, 'boom')
    c = f.resume
    [a, b, c, f.alive?, o.events]
  end
  o = StepExc.new
  show('raise through frames') do
    f = o.raise_through
    a = [f.resume, f.resume]
    [a, f.raise(IOError, 'stop'), f.alive?, o.events]
  end
  o = StepExc.new
  show('raise uncaught') do
    f = o.raise_deep
    a = f.resume
    err = begin
      f.raise(RuntimeError, 'x')
    rescue RuntimeError => e
      [e.class, e.message]
    end
    [a, err, f.alive?, o.events]
  end
  o = StepExc.new
  show('raise yield in ensure') do
    f = o.raise_ensure_yield
    a = f.resume
    b = f.raise(IOError, 'E')
    err = begin
      f.resume
    rescue IOError => e
      e.message
    end
    [a, b, err, f.alive?, o.events]
  end
  o = StepExc.new
  show('raise retry') do
    f = o.raise_retry
    [f.resume, f.raise(TypeError, 't'), f.resume, f.alive?]
  end
  o = StepExc.new
  show('raise forms') do
    f = o.raise_forms
    [f.resume, f.raise(IOError, 'a'), f.raise('b'), f.raise(TypeError.new('c')), f.raise(ArgumentError)]
  end
  o = StepExc.new
  show('raise unborn') do
    f = o.raise_nobody
    begin
      f.raise(RuntimeError, 'x')
    rescue FiberError => e
      [e.class, e.message, f.alive?, f.resume]
    end
  end
  o = StepExc.new
  show('raise dead') do
    f = o.raise_nobody
    f.resume
    f.resume
    begin
      f.raise(RuntimeError, 'x')
    rescue FiberError => e
      # the message is the one a resume of a dead fiber gives
      [e.class, e.message == (f.resume rescue $!.message), f.alive?]
    end
  end
  o = StepExc.new
  show('raise self') { drain(o.raise_self) }
  o = StepExc.new
  show('raise resuming') { drain(o.raise_resuming) }
  puts 'end'
RUBY

suite.behaviour(DRIVER, same: false, diff: false) do |interpreted_all, compiled_all|
  # Fiber#raise: mruby-fiber has none, so the interpreted run only shows its NoMethodError (compared with CRuby's output below).
  interpreted = interpreted_all&.reject { |l| l.start_with?('raise ') }
  compiled = compiled_all&.reject { |l| l.start_with?('raise ') }
  suite.check('interpreted and compiled runs print the same', interpreted == compiled)
  suite.report_diff(interpreted, compiled) if interpreted && compiled
  expected = {
    'nested ensure' => '[[1, 2, :done], [1, 2, "after resume", :outer]]',
    'caught by parent' => '[1, "boom 1", :after]',
    'uncaught' => '[2, "boom 2", false]',
    'through two frames' => '[[3, :end], [:middle_ensure, "boom 3"]]',
    'local rescue' => '[:first, "got 7", false]',
    'wrong class' => '[4, "boom 4", false]',
    'catch throw' => '[:tag, :caught]',
    'catch deep' => '[[:in_deep, [:thrown, :after]], [:deep_ensure]]',
    'break through ensure' => '[[1, 2, [20, :after]], [:each_ens]]',
    'break in block ensure' => '[[1, 2, [[:b, 2], :after]], [1, 2]]',
    'normal through ensure' => '[[1, 2, 3, [:finished, :after]], [:each_ens]]',
    'locals survive rescue' => '[["kept!", ["kept!", 5, "kept!"]], ["KEPT!", ["kept!", 5, "kept!"], false]]',
    'retry basic' => '[[[:try, 1], [:try, 2], [:try, 3], [:ok, 3]], ["t1", "t2"]]',
    'retry with ensure' => '[[1, :retrying, 2, :retrying, 3, :done], [:ens]]',
    'retry across call' => '[[[:flaky, 1], [:flaky, 2], [:flaky, 3], 3], ["f1", "f2"]]',
    'retry in block' => '[[[1, 1], [1, 2], [2, 3], [2, 4], [3, 5], [3, 6], [StepExc, 6]], []]',
    'return through ensure' => '[[[:in, true], [:in, false], :ens1, :a, :try, 1, [:inner, 1], 2, [:inner, 2], ' \
                               '[:bare, true], [:bare, false], [:early, :late, :inner, :second, :rescued, ' \
                               '[:rescued, "from ensure"], [:ret, 2], nil, :late]], ' \
                               '[[:ens, true], :not_early, [:ens, false], :e1, :e2, :ens_r, [:inner, 1], [:outer, 1], [:inner, 2], ' \
                               '[:outer, 2], [:ens_bare, true], :after_bare, [:ens_bare, false]]]',
    'loop next break through ensure' => '[[1, 2, 3, [[2], 3]], [[:ens, 1], [:ens, 2], [:ens, 3]]]',
    'block next through ensure' => '[[1, 2, 3, [true, :after]], [1, 2, 3]]',
    'plain break through ensure' => '[[1, :broke], ["e1"]]',
    'plain return through ensure' => '[[1, :returned], ["e1", "ggggggggg"]]',
    'plain raise in ensure' => '[:rescued, "ens"]',
    'plain next through ensure' => '[:done, [1, 2]]'
  }
  expected.each do |label, line|
    suite.check("#{label} prints what Ruby does", interpreted&.include?("#{label}: #{line}"))
  end
  # The compiled run is held to what CRuby prints for the same program (the dead-fiber message aside, see the driver).
  raise_expected = {
    'raise rescued' => '[:waiting, :after_rescue, :finished, false, [[:rescued, ArgumentError, "boom"], :ens]]',
    'raise through frames' => '[[1, 2], :recovered, false, [[:blk, 1], [:blk, 2], [:outer, "stop"], :outer_ens]]',
    'raise uncaught' => '[:deep, [RuntimeError, "x"], false, [:deep_ens]]',
    'raise yield in ensure' => '[1, :in_ensure, "E", false, [:ens_done]]',
    'raise retry' => '[[:wait, 1], [:wait, 2], :ok, false]',
    'raise forms' => '[0, 1, 2, 3, [[IOError, "a"], [RuntimeError, "b"], [TypeError, "c"], [ArgumentError, "ArgumentError"]]]',
    'raise unborn' => '[FiberError, "cannot raise exception on unborn fiber", true, :a]',
    'raise dead' => '[FiberError, true, false]',
    'raise self' => '[[:self, "me"]]',
    'raise resuming' => 'raised RuntimeError: r'
  }
  raise_expected.each do |label, line|
    ok = compiled_all&.include?("#{label}: #{line}")
    suite.check("#{label} prints what CRuby does", ok)
    puts "    compiled: #{compiled_all&.find { |l| l.start_with?("#{label}:") }}" unless ok
  end
end
suite.finish
