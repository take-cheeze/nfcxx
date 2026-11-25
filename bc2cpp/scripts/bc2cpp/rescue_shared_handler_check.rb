#!/usr/bin/env ruby
# frozen_string_literal: true

# RESCUE_SHARED_HANDLER (tools/bc2cpp/rescue_shared_handler.rb): a rescue handler's `$stderr.puts "...#{e.message}"`
# run becomes one call of a file-scope helper, shared by the handlers whose runs differ only in their literals.
#
#   generated code (needs a host mrbc)
#     - handlers logging different literals (one in a try body) call one helper, defined once, noinline and cold;
#     - the site keeps the run's closed-world markers and passes each literal as BC2CPP_RH_LIT, a pool string;
#     - a run with a local, `e.class` and `e.message` gets its own helper, a run with one site a `static inline` one;
#     - BC2CPP_RESCUE_SHARED_HANDLER=0 leaves every run inline.
#   behaviour (needs a full-core libmruby; run it on the GC-stress build too)
#     - interpreted, compiled and kill-switch-compiled runs print the same log lines and results (with $stderr pointed
#       at $stdout), for: plain, local and `e.class` interpolations, a `to_s` and a `message` with side effects (order),
#       a `message` that raises from inside the run, a handler whose value is the `puts` result, a nested handler, a
#       reassigned `$stderr`, and GC.stress.
#
# Usage: MRBC=path/to/mrbc [BC2CPP_MRUBY_FULL=dir | BC2CPP_FULL_BUILD_DIR=dir] ruby scripts/bc2cpp/rescue_shared_handler_check.rb

require 'tmpdir'
require_relative 'fixture_runtime'

SRC = <<~'RUBY'
  class RshErr < StandardError; end

  class RshLoud < StandardError
    def message
      RshFx.trace << :message
      "loud #{super}"
    end
  end

  class RshBad < StandardError
    def message
      raise ArgumentError, 'message failed'
    end
  end

  class RshName
    def to_s
      RshFx.trace << :to_s
      'named'
    end
  end

  class RshFx
    def self.trace
      @trace ||= []
    end

    def initialize
      @fallback = nil
    end
    attr_reader :fallback

    def fail_with(kind)
      raise RshErr, 'plain' if kind == :plain
      raise RshLoud, 'loud' if kind == :loud
      raise RshBad, 'bad' if kind == :bad

      kind
    end

    def first(kind)
      fail_with(kind)
    rescue StandardError => e
      $stderr.puts "[RPG2k] first failed: #{e.message}"
      nil
    end

    def second(kind)
      fail_with(kind)
    rescue StandardError => e
      $stderr.puts "[RPG2k] second failed, using a fallback: #{e.message}"
      @fallback = :second
    end

    def named(kind, name)
      fail_with(kind)
    rescue StandardError => e
      $stderr.puts "[RPG2k] named '#{name}' failed: #{e.class}: #{e.message}"
      :named
    end

    def bare(kind)
      fail_with(kind)
    rescue RshErr
      $stderr.puts '[RPG2k] bare failed'
    end

    def nested(kind)
      v = 1
      begin
        v = 2
        fail_with(kind)
      rescue RshErr => e
        $stderr.puts "[RPG2k] nested inner: #{e.message}"
        v = 3
        fail_with(:loud) if kind == :plain
      end
      v
    rescue StandardError => e
      $stderr.puts "[RPG2k] nested outer: #{e.message}"
      [:outer, v]
    end

    def upvar(kind)
      tag = 'up'
      [1].map do
        fail_with(kind)
      rescue StandardError => e
        $stderr.puts "[RPG2k] #{tag}: #{e.message}"
        tag
      end
    end
  end
RUBY

OWNERS = %w[RshFx RshErr RshLoud RshBad RshName].freeze

DRIVER = <<~'RUBY'
  $stderr = $stdout
  def show(label)
    puts "#{label}: #{yield.inspect}"
  rescue Exception => e
    text = begin
      e.message
    rescue ArgumentError
      '(message raises)'
    end
    puts "#{label}: raised #{e.class}: #{text}"
  end
  f = RshFx.new
  %i[ok plain loud bad].each do |k|
    show("first #{k}") { f.first(k) }
    show("second #{k}") { [f.second(k), f.fallback] }
    show("named #{k}") { f.named(k, RshName.new) }
    show("bare #{k}") { f.bare(k) }
    show("nested #{k}") { f.nested(k) }
    show("upvar #{k}") { f.upvar(k) }
  end
  show('trace') { RshFx.trace }
  saved = $stderr
  $stderr = Object.new
  def $stderr.puts(*a) = $stdout.puts("redirected #{a.inspect}")
  show('redirected') { f.first(:plain) }
  $stderr = saved
  GC.stress = true if GC.respond_to?(:stress=)
  show('stress') { [f.first(:plain), f.named(:loud, 'x'), f.nested(:plain), f.second(:bad)] }
  GC.stress = false if GC.respond_to?(:stress=)
  puts 'end'
RUBY

suite = Bc2cppStepCheck.new('bc2cpp rescue shared handler check')
check = suite.method(:check)

def impl_of(code, name)
  code[/^mrb_value RshFx_#{name}_impl\(mrb_state\* M.*?fell off the end of its body"\);\n\}/m].to_s
end

def calls_in(text)
  text.scan(/\bbc2cpp_rh_\w+(?=\()/).uniq
end

def generated(env)
  saved = env.keys.to_h { |k| [k, ENV.fetch(k, nil)] }
  env.each { |k, v| ENV[k] = v }
  Dir.mktmpdir('bc2cpp-rescue-shared') do |dir|
    code, err = Bc2cppFixtureRuntime.generate(SRC, dir, core: true, only_owners: OWNERS)
    File.write(File.join(ENV['BC2CPP_KEEP_DIR'], "err-#{env.values.join}.txt"), err) if ENV['BC2CPP_KEEP_DIR']
    code
  end
ensure
  saved.each { |k, v| ENV[k] = v }
end

puts '-- generated code'
on = generated({})
off = generated('BC2CPP_RESCUE_SHARED_HANDLER' => '0')
if (keep = ENV['BC2CPP_KEEP_DIR'])
  File.write(File.join(keep, 'rescue_shared_on.cpp'), on)
  File.write(File.join(keep, 'rescue_shared_off.cpp'), off)
end
first = calls_in(impl_of(on, 'first'))
nested_try = on[/^static mrb_value RshFx_nested_impl_rescue_try\(.*?fell off the end of its body"\);\n\}/m].to_s
named = calls_in(impl_of(on, 'named'))
check.call('first: the handler calls one helper', first.size == 1)
check.call('first and the two nested handlers share it',
           first.size == 1 && (calls_in(nested_try) + calls_in(impl_of(on, 'nested'))).uniq == first)
check.call('the shared helper is defined once, noinline and cold',
           first.size == 1 && on.scan(/^\[\[gnu::noinline, gnu::cold\]\] static mrb_value #{first.first}\(/).size == 1)
check.call("first's handler no longer reads $stderr itself", !impl_of(on, 'first').include?('mrb_gv_get'))
check.call('second: the handler calls a helper', calls_in(impl_of(on, 'second')).size == 1)
check.call('named: its own helper, static inline (one site)',
           named.size == 1 && named != first && on.include?("static inline mrb_value #{named.first}("))
check.call('bare: the literal-only run is outlined', calls_in(impl_of(on, 'bare')).size == 1)
check.call('nested: the inner handler in the try body is outlined', calls_in(nested_try).size == 1)
check.call('the site hands its literal over as a pool string (BC2CPP_RH_LIT)',
           impl_of(on, 'first').match?(/#{first.first}\(M, self, r\d+, BC2CPP_RH_LIT\("/))
check.call('the site keeps the closed-world markers', impl_of(on, 'first').include?('/* CLOSED_WORLD owner-call: message */'))
check.call('BC2CPP_RESCUE_SHARED_HANDLER=0 leaves every run inline',
           !off.include?('bc2cpp_rh_') && impl_of(off, 'first').include?('mrb_gv_get'))

build = ENV['CC_GENERATED_ONLY'] == '1' ? nil : Bc2cppFixtureRuntime.full_or_build
if build
  runs = {}
  [['RESCUE_SHARED_HANDLER off', { 'BC2CPP_RESCUE_SHARED_HANDLER' => '0' }], ['on', {}]].each do |label, env|
    env.each { |k, v| ENV[k] = v }
    suite.generate(SRC, OWNERS)
    suite.behaviour(DRIVER, banner: "#{label}: interpreted and compiled", build: build) do |interpreted, compiled|
      runs[label] = compiled
      if interpreted && label == 'on'
        check.call('the log line is printed', interpreted.include?('[RPG2k] first failed: plain'))
        check.call('a raising message propagates out of the handler',
              interpreted.include?('first bad: raised ArgumentError: message failed'))
      end
    end
  ensure
    env.each_key { |k| ENV.delete(k) }
  end
  check.call('the kill-switch run prints what the default run prints', runs.values.uniq.size == 1 && !runs.values.first.nil?)
else
  puts '  SKIP behavioural comparison: CC_GENERATED_ONLY or no full-core libmruby'
end

suite.finish
