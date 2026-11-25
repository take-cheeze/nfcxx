#!/usr/bin/env ruby
# frozen_string_literal: true

# RESCUE_LIVE_REFS (tools/bc2cpp/codegen_rescue.rb, rescue_read_outside) and RESCUE_TRY_COLD (rescue_try_insn_text):
# a try body aliases only the locals something outside its range can read, and its instructions go through
# COLD_COMPACT as a method's do.
#
#   generated code (needs a host mrbc)
#     - a try body whose handler reads only the argument and the exception aliases none of the locals it writes;
#     - a local the handler reads, one a block made before the range reads, and every write of a range a loop runs
#       again stay aliases (`mrb_value&`);
#     - a try body's Integer arithmetic calls its COLD_COMPACT helper;
#     - BC2CPP_RESCUE_LIVE_REFS=0 aliases every written local again, BC2CPP_RESCUE_TRY_COLD=0 keeps the arms inline.
#   behaviour (needs a full-core libmruby; run it on the GC-stress build too)
#     - interpreted, compiled and both kill-switch-compiled runs print the same for: a body that raises mid-way with
#       locals the handler reads, a local updated in a loop the handler reads, a range a loop runs again, a block made
#       before the range reading a local the range writes, a non-StandardError passing a `rescue StandardError`,
#       nested rescues with a raise from the inner handler, rescue with ensure, `return`, `break` and `next` through a
#       range, retry, `$!` after the rescue, GC.start in the body and the handler, and GC.stress.
#
# Usage: MRBC=path/to/mrbc [BC2CPP_MRUBY_FULL=dir | BC2CPP_FULL_BUILD_DIR=dir] ruby scripts/bc2cpp/rescue_try_lean_check.rb

require 'tmpdir'
require_relative 'fixture_runtime'

SRC = <<~'RUBY'
  class RtlErr < StandardError; end

  class RtlFx
    attr_reader :log
    def initialize; @log = []; end

    # The handler reads the argument and the exception only.
    def quiet(n)
      a = n * 3
      b = a + n
      raise RtlErr, "q#{b}" if n > 1
      [a, b]
    rescue StandardError => e
      [:quiet, n, e.message]
    end

    # Locals the handler reads: one written before the raise, one after it (still nil).
    def mid(n)
      a = n * 2
      b = "s#{a}"
      raise RtlErr, "at #{n}" if n > 1
      c = a + 1
      [a, b, c]
    rescue StandardError => e
      [:rescued, n, a, b, c, e.message]
    end

    # A local updated in a loop inside the range, read by the handler.
    def counted(limit)
      i = 0
      total = 0
      while i < 10
        total += i
        raise RtlErr, 'stop' if i == limit
        i += 1
      end
      total
    rescue RtlErr
      [:stopped, i, total]
    end

    # The loop runs the range again: `acc` is read inside it before it is written, and nowhere outside.
    def again(n)
      i = 0
      while i < n
        begin
          acc = (acc || 0) + i
          @log << [:again, acc]
          raise RtlErr, 'two' if i == 2
        rescue RtlErr
          @log << :again_rescued
        end
        i += 1
      end
      i
    end

    # A block made before the range reads the local the range writes.
    def seen(n)
      x = 0
      peek = -> { x }
      begin
        x = n
        raise RtlErr, 'seen' if n > 1
      rescue RtlErr
        @log << :seen_rescued
      end
      peek.call
    end

    # A non-StandardError passes a `rescue StandardError`.
    def hard(kind)
      raise NotImplementedError, 'hard' if kind == :hard
      raise RtlErr, 'soft' if kind == :soft
      :ok
    rescue StandardError => e
      [:caught, e.class]
    end

    def nested(kind)
      x = 1
      begin
        x = 2
        begin
          x = 3
          raise RtlErr, 'inner' if kind == :inner
          raise ArgumentError, 'outer' if kind == :outer
          x = 4
        rescue RtlErr => e
          @log << [:inner, x, e.message]
          raise TypeError, 'from handler' if kind == :inner
        end
        x
      rescue ArgumentError, TypeError => e
        [:outer, x, e.class, e.message]
      end
    end

    def with_ensure(fail)
      v = 0
      begin
        v = 1
        raise RtlErr, 'x' if fail
        v = 2
      rescue RtlErr
        @log << [:rescue, v]
        v = 3
      ensure
        @log << [:ensure, v]
      end
      v
    end

    def early(n)
      return :early if n.zero?
      raise RtlErr, 'late' if n > 1
      :mid
    rescue RtlErr => e
      e.message
    end

    def returns(n)
      [1, 2, 3].each do |i|
        begin
          return i * 10 if i == n
        rescue RtlErr
          return :never
        end
      end
      :done
    rescue StandardError
      :rescued
    end

    def breaks
      [1, 2, 3].each do |i|
        begin
          break i + 100 if i == 2
        rescue RtlErr
          :never
        end
      end
    end

    def nexts
      [1, 2, 3].map do |i|
        begin
          next(-i) if i == 2
          raise RtlErr, 'odd' if i == 3
          i
        rescue RtlErr
          :odd
        end
      end
    end

    def retrying
      tries = 0
      begin
        tries += 1
        raise RtlErr, "try #{tries}" if tries < 3
        tries
      rescue RtlErr
        retry
      end
    end

    def errinfo
      begin
        raise RtlErr, 'seen'
      rescue RtlErr
        @log << $!.message
      end
      $!
    end

    def garbage(n)
      parts = []
      n.times { |i| parts << "p#{i}" * 4 }
      GC.start
      raise RtlErr, parts.join(',') if n > 2
      parts.size
    rescue RtlErr => e
      GC.start
      [e.message.size, parts.size, parts.last]
    end
  end
RUBY

OWNERS = %w[RtlFx RtlErr].freeze

DRIVER = <<~'RUBY'
  def show(label)
    puts "#{label}: #{yield.inspect}"
  rescue Exception => e
    puts "#{label}: raised #{e.class}: #{e.message}"
  end
  f = RtlFx.new
  [0, 1, 2, 5].each { |n| show("quiet #{n}") { f.quiet(n) } }
  [0, 1, 2, 5].each { |n| show("mid #{n}") { f.mid(n) } }
  [3, 20].each { |n| show("counted #{n}") { f.counted(n) } }
  show('again') { f.again(4) }
  [1, 2].each { |n| show("seen #{n}") { f.seen(n) } }
  %i[ok soft hard].each { |k| show("hard #{k}") { f.hard(k) } }
  %i[none inner outer].each { |k| show("nested #{k}") { f.nested(k) } }
  [true, false].each { |k| show("ensure #{k}") { f.with_ensure(k) } }
  [0, 1, 2].each { |n| show("early #{n}") { f.early(n) } }
  [2, 5].each { |n| show("returns #{n}") { f.returns(n) } }
  show('breaks') { f.breaks }
  show('nexts') { f.nexts }
  show('retrying') { f.retrying }
  show('errinfo') { [f.errinfo, $!] }
  [1, 3, 40].each { |n| show("garbage #{n}") { f.garbage(n) } }
  show('log') { f.log }
  GC.stress = true if GC.respond_to?(:stress=)
  show('stress') { [f.mid(3), f.quiet(4), f.garbage(5), f.again(3), f.nested(:inner)] }
  GC.stress = false if GC.respond_to?(:stress=)
  puts 'end'
RUBY

suite = Bc2cppStepCheck.new('bc2cpp rescue try lean check')
check = suite.method(:check)

# The try functions of RtlFx#name.
def try_of(code, name)
  code.scan(/^static mrb_value RtlFx_#{name}_impl_rescue_try\w*\(mrb_state\* M.*?fell off the end of its body"\);\n\}/m).join
end

def aliases(code, name)
  try_of(code, name).scan(/mrb_value& r(\d+) = /).flatten.map(&:to_i).sort
end

def generated(env)
  saved = env.keys.to_h { |k| [k, ENV.fetch(k, nil)] }
  env.each { |k, v| ENV[k] = v }
  Dir.mktmpdir('bc2cpp-rescue-try-lean') do |dir|
    Bc2cppFixtureRuntime.generate(SRC, dir, core: true, only_owners: OWNERS).first
  end
ensure
  saved.each { |k, v| ENV[k] = v }
end

puts '-- generated code'
on = generated({})
refs_off = generated('BC2CPP_RESCUE_LIVE_REFS' => '0')
cold_off = generated('BC2CPP_RESCUE_TRY_COLD' => '0')
%w[quiet mid counted again seen].each do |name|
  check.call("#{name}: compiled with a try function", !try_of(on, name).empty?)
end
check.call('quiet: the try body aliases none of the locals it writes', aliases(on, 'quiet').empty?)
check.call('quiet: without RESCUE_LIVE_REFS it aliases them', aliases(refs_off, 'quiet').size >= 2)
check.call('mid: the locals the handler reads stay aliases', aliases(on, 'mid').size >= 3)
check.call('counted: the loop counters the handler reads stay aliases', aliases(on, 'counted').size >= 2)
check.call('again: a range a loop runs again keeps every alias', aliases(on, 'again') == aliases(refs_off, 'again') &&
                                                                 !aliases(on, 'again').empty?)
check.call('seen: the local a block made before the range reads stays an alias', !aliases(on, 'seen').empty?)
check.call('a try body calls its COLD_COMPACT helper', try_of(on, 'quiet').include?('bc2cpp_compact_'))
check.call('BC2CPP_RESCUE_TRY_COLD=0 keeps the arms inline', !try_of(cold_off, 'quiet').include?('bc2cpp_compact_'))

if ENV['CC_GENERATED_ONLY'] == '1'
  puts '  SKIP behavioural comparison: CC_GENERATED_ONLY'
else
  build = Bc2cppFixtureRuntime.full_or_build
  runs = {}
  [['RESCUE_LIVE_REFS off', { 'BC2CPP_RESCUE_LIVE_REFS' => '0' }],
   ['RESCUE_TRY_COLD off', { 'BC2CPP_RESCUE_TRY_COLD' => '0' }],
   ['both on', {}]].each do |label, env|
    env.each { |k, v| ENV[k] = v }
    suite.generate(SRC, OWNERS)
    suite.behaviour(DRIVER, banner: "#{label}: interpreted and compiled", build: build) do |interpreted, compiled|
      runs[label] = compiled
      if interpreted && label == 'both on'
        check.call('the handler reads the locals written before the raise',
                   interpreted.include?('mid 2: [:rescued, 2, 4, "s4", nil, "at 2"]'))
        check.call('a non-StandardError passes the rescue', interpreted.include?('hard hard: raised NotImplementedError: hard'))
      end
    end
  ensure
    env.each_key { |k| ENV.delete(k) }
  end
  check.call('the kill-switch runs print what the default run prints', runs.values.uniq.size == 1 && !runs.values.first.nil?)
end

suite.finish
