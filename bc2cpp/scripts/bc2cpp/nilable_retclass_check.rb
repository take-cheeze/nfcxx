#!/usr/bin/env ruby
# encoding: UTF-8
# RETCLASS_NILABLE_JOIN (ADR 0199): a self-called factory that returns one
# class or nil -- through joins, a rescue handler or a POLY name whose every
# definition agrees -- proves that class for ClassLayout, and every shape that
# could let a different value reach the RETURN stays unproven.

require 'tmpdir'
require_relative '../../tools/bc2cpp/bc2cpp'

SRC = <<~'RUBY'
  class Widget
    def draw; end
  end
  class Gadget
    def draw; end
  end
  class Base
    def load_widget
      name = @name
      return nil if name.nil?
      Widget.new
    rescue StandardError => e
      $stderr.puts e.message
      nil
    end
    def build_widget(flag)
      w = Widget.new
      c = flag ? 1 : 2
      w.draw
      w
    end
    def either(flag)
      flag ? Widget.new : Widget.new
    end
    def mixed(flag)
      flag ? Widget.new : Gadget.new
    end
    def only_nil
      nil
    end
    def passthrough(x)
      x
    end
    def block_written(items)
      w = Widget.new
      items.each { |i| w = i }
      w
    end
    def with_ensure
      Widget.new
    ensure
      @done = true
    end
    def chained
      return nil if @name
      load_widget
    end
    def aliased
      Widget.new
    end
    alias_method :aliased, :mixed
  end
  class SceneA < Base
    def make; Widget.new; end
    def pick; Widget.new; end
    def initialize
      @made = make
      @loaded = load_widget
      @chain = chained
      @mixed = mixed(true)
      @built = build_widget(true)
    end
    def reset
      @made = nil
      @loaded = nil
    end
  end
  class SceneB < Base
    def make
      return nil if @name
      Widget.new
    end
    def pick; Gadget.new; end
  end
  class Loose
    def method_missing(name, *args); Gadget.new; end
    def initialize
      @loaded = load_widget
    end
  end
RUBY

failures = []
check = lambda do |what, actual, expected|
  if actual == expected
    puts "  ok  #{what}"
  else
    puts "  FAIL #{what}: expected #{expected.inspect}, got #{actual.inspect}"
    failures << what
  end
end

Dir.mktmpdir do |dir|
  source = File.join(dir, 'nilable_retclass.rb')
  File.write(source, SRC)
  ireps, root_label = compile_ireps(source, 'bc2cpp_nilable_retclass', dir)
  order = dfs_order(ireps, root_label)
  registry, superclass_of = build_registry(ireps, root_label)
  probe = CodeGen.new(ireps, registry, {}, {}, {}, {}, superclass_of, {}, {}, {}, {}, Set.new, Set.new,
                      analysis_only: true)
  proven = probe.class_return_names

  check.call('rescue handler, RETURN_BLK nil and RAISEIF fall-through still prove the class',
             proven['load_widget'], 'Widget')
  check.call('a join that never writes the returned register is looked through',
             proven['build_widget'], 'Widget')
  check.call('a join whose arms agree proves the class', proven['either'], 'Widget')
  check.call('a self-call chain through a nilable factory proves the class', proven['chained'], 'Widget')
  check.call('a POLY name whose definitions all agree (one nilable) proves the class', proven['make'], 'Widget')
  check.call('a POLY name whose definitions disagree stays unproven', proven['pick'], nil)
  check.call('a join whose arms disagree stays unproven', proven['mixed'], nil)
  check.call('a method that only returns nil proves nothing', proven['only_nil'], nil)
  check.call('a returned argument stays unproven', proven['passthrough'], nil)
  check.call('a local a block reassigns (SETUPVAR) stays unproven', proven['block_written'], nil)
  check.call('an ensure handler stays refused', proven['with_ensure'], nil)
  check.call('an alias_method target stays unproven', proven['aliased'], nil)

  check.call('a self-call reaches a def on its own superclass chain',
             probe.self_call_reaches_def?('load_widget', 'SceneA'), true)
  check.call('a self-call from a class with no such def on its chain does not',
             probe.self_call_reaches_def?('load_widget', 'Loose'), false)

  layout = ClassLayout.analyze(ireps, registry, {}, {}, nil,
                               ret_class_proof: ->(n, owner) { probe.class_return_for_self_call(n, owner) })
  check.call('ClassLayout: POLY factory plus a nil reset resolves', layout.dig('SceneA', 'made'), 'Widget')
  check.call('ClassLayout: rescue factory plus a nil reset resolves', layout.dig('SceneA', 'loaded'), 'Widget')
  check.call('ClassLayout: chained nilable factory resolves', layout.dig('SceneA', 'chain'), 'Widget')
  check.call('ClassLayout: joined factory resolves', layout.dig('SceneA', 'built'), 'Widget')
  check.call('ClassLayout: disagreeing factory stays unknown', layout.dig('SceneA', 'mixed'), ClassLayout::UNKNOWN)
  check.call('ClassLayout: a call that may reach method_missing stays unknown',
             layout.dig('Loose', 'loaded'), ClassLayout::UNKNOWN)
end

if failures.empty?
  puts 'bc2cpp nilable class-return proof check: PASS'
else
  warn "bc2cpp nilable class-return proof check: #{failures.size} failure(s)"
  exit 1
end
