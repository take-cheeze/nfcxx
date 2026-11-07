#!/usr/bin/env ruby
# encoding: UTF-8
# frozen_string_literal: true

# ENUMERATOR_FIBER: Enumerator#next runs its Fiber body as a C++ Fiber step (BC2CPP_ENUMERATOR_FIBER=0 keeps bytecode), and DYN_CALL
# carries a splat, keywords and a forwarded block (Enumerator#each's `__send__ @meth, *@args, **@kwd, &block`): an empty keyword
# Hash dispatches to the registered step, a non-empty one runs as an ordinary send. Interpreted and compiled runs print the same.
#
# Usage: MRBC=path/to/mrbc [BC2CPP_MRUBY_FULL=dir | BC2CPP_FULL_BUILD_DIR=dir] ruby scripts/bc2cpp/enumerator_next_check.rb

require_relative 'fixture_runtime'

suite = Bc2cppStepCheck.new('bc2cpp enumerator next check')

# KwClock forwards to a target chosen at run time: a suspendable method (no keywords) and a method with keywords.
SRC = <<~RUBY
  class KwTarget
    def kw_count(n)
      out = []
      i = 0
      while i < n
        out << yield(i)
        i += 1
      end
      out
    end

    def kw_scaled(n, scale: 1)
      out = []
      n.times { |i| out << yield(i * scale) }
      out
    end
  end

  class KwClock
    def initialize(target)
      @target = target
    end

    def start
      @fiber = Fiber.new { run }
    end

    def run
      yielded = forward(:kw_count, [3], {}) { |x| back = Fiber.yield x; back.to_i + 1 }
      scaled = forward(:kw_scaled, [2], { scale: 10 }) { |x| x + 1 }
      [yielded, scaled]
    end

    def forward(meth, args, kwd, &block)
      @target.__send__ meth, *args, **kwd, &block
    end

    #{Bc2cppStepCheck::CLOCK_API}
  end
RUBY

# EnColl: a collection with its own each, reached through to_enum with an argument.
SRC2 = <<~'RUBY'
  class EnColl
    def initialize(items)
      @items = items
    end

    def each_item(extra = 0)
      i = 0
      while i < @items.size
        yield @items[i] + extra
        i += 1
      end
      self
    end

    def enum
      to_enum(:each_item, 100)
    end
  end
RUBY

# EnSource: an Enumerable over its own each, walked externally (Enumerable's enumerator-returning forms) and lazily.
SRC3 = <<~'RUBY'
  class EnSource
    include Enumerable

    def each(start = 1)
      i = start
      while i <= 3
        yield i
        i += 1
      end
      self
    end
  end
RUBY

OWNERS = %w[KwTarget KwClock EnColl EnSource Enumerator Enumerator::Lazy Enumerator::Generator Enumerator::Yielder Array Enumerable Range Integer Kernel].freeze
code = suite.generate(SRC + SRC2 + SRC3, OWNERS)
suite.check('run compiles as a resumable step function', code.include?('static mrb_value KwClock_run_step(mrb_state* M'))
suite.check('forward compiles as a resumable step function', code.include?('static mrb_value KwClock_forward_step(mrb_state* M'))
suite.check('the splat-and-keywords send is a dynamic call', code.include?('// RESUMABLE_DYN_CALL'))
suite.check('kw_count registers a dispatcher', code.include?('KwTarget_kw_count_impl_dyn'))
suite.check('Enumerator#next_values builds its Fiber from a step', code.match?(/static mrb_value Enumerator_next_values__blk\d+_step\(mrb_state\* M/))
suite.check('the iteration block of next_values is a step', code.scan(/static mrb_value Enumerator_next_values__blk\d+_step\(mrb_state\* M/).size >= 2)

DRIVER = <<~'RUBY'
  c = KwClock.new(KwTarget.new)
  c.start
  out = []
  out << c.go
  GC.start
  out << c.go_with(10)
  out << c.go_with(20)
  out << c.go_with(30)
  out << c.fiber_alive
  p out

  en = [10, 20, 30].each
  r = []
  r << en.next
  GC.start
  r << en.next
  r << en.peek
  r << en.next
  begin
    en.next
  rescue StopIteration => e
    r << e.class
  end
  p r

  eu = EnColl.new([1, 2, 3]).enum
  u = []
  u << eu.next
  u << eu.next
  u << eu.next
  begin
    eu.next
  rescue StopIteration => e
    u << e.class
  end
  eu.rewind
  u << eu.next
  p u

  es = [5, 6].each_with_index
  s = []
  s << es.next
  s << es.next
  eh = { a: 1, b: 2 }.each
  s << eh.next
  et = 3.times
  s << et.next
  s << et.next
  p s

  def shown(label)
    puts "#{label}: #{yield.inspect}"
  rescue StandardError => e
    puts "#{label}: raised #{e.class}: #{e.message}"
  end

  src = EnSource.new
  shown('to_enum') { e = src.to_enum; [e.next, e.next, e.next, (e.next rescue :stop)] }
  shown('to_enum size') { src.to_enum.size }
  shown('map enum') { e = src.map; [e.next, e.next] }
  shown('select enum') { e = src.select; [e.next, e.peek, e.next] }
  shown('each_with_index enum') { e = src.each_with_index; [e.next, e.next] }
  shown('each_slice enum') { e = src.each_slice(2); [e.next, e.next, (e.next rescue :stop)] }
  shown('each_cons enum') { e = src.each_cons(2); [e.next, e.next] }
  shown('each_with_object enum') { e = src.each_with_object([]); [e.next, e.next] }
  shown('with_index') { e = src.each.with_index(1); [e.next, e.next] }
  shown('rewind') { e = src.to_enum; a = e.next; e.rewind; [a, e.next] }
  shown('lazy next') { e = src.lazy.map { |x| x * 2 }.select { |x| x > 2 }.to_enum; [e.next, e.next] }
  shown('lazy first') { src.lazy.map { |x| x * 3 }.first(2) }
  shown('two enumerators') { a = src.to_enum; b = src.to_enum; [a.next, b.next, a.next, b.next] }
  puts 'end'
RUBY

# Known gaps: the compiled run does not match yet, and must keep failing until the gap is closed (then remove it).
#   lazy next -- mruby-enum-lazy is not among the core gems bc2cpp compiles (compiled_gems.rb), and its generator block wraps the
#                iteration in begin/rescue StopIteration, which a step cannot contain yet.
GAP = ->(line) { line.to_s.start_with?('lazy next:') }

suite.behaviour(DRIVER, same: false, diff: false) do |interpreted, compiled|
  next unless interpreted && compiled

  pairs = interpreted.zip(compiled)
  suite.check('interpreted and compiled runs print the same outside the known gaps', pairs.all? { |a, b| a == b || GAP.(a) })
  suite.check('every known gap still fails', pairs.select { |a, _| GAP.(a) }.all? { |a, b| a != b })
  suite.check('the suspendable target yields through the CALL and the keyword target gets its keyword',
              interpreted.first == '[0, 1, 2, [[11, 21, 31], [1, 11]], false]')
  suite.check('Enumerator#next walks Array#each, a user each with an argument, each_with_index, Hash#each and Integer#times',
              interpreted[1] == '[10, 20, 30, 30, StopIteration]' &&
              interpreted[2] == '[101, 102, 103, StopIteration, 101]' &&
              interpreted[3] == '[[5, 0], [6, 1], [:a, 1], 0, 1]')
  pairs.reject { |a, b| a == b || GAP.(a) }.first(20).each { |a, b| puts "    interpreted: #{a}\n    compiled:    #{b}" }
end
suite.finish
