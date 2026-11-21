#!/usr/bin/env ruby
# frozen_string_literal: true

# DECLARED_ELEMENT_GUARD: `@items: Array[Integer]` (RBS) is checked where an element is read. A GETIDX of the declared
# ivar tests its result after the read, so a non-Integer element raises BC2cppDeclarationViolation in the compiled run
# (the interpreted run has no declaration, so it returns the element). A good element behaves the same in both runs.
# Loops over the ivar (each, map, select, inject, sort_by) test each element they bind (DECLARED_LOOP_ELEMENT).
# Read from the generated code's DECLARED_ELEMENT_GUARD lines and the behaviour comparison.
#
#   MRBC=path/to/mrbc ruby scripts/bc2cpp/element_guard_check.rb
require 'tmpdir'
require_relative 'check_support'
require_relative 'fixture_runtime'

suite = Bc2cppStepCheck.new('element_guard_check')
check = suite.method(:check)

SOURCE = <<~RUBY
  class Shelf
    def initialize
      @items = [1, 2, 3]
      nil
    end

    def at(i)
      @items[i]
    end

    def poison
      @items.replace([1, 2, "a"])
      nil
    end

    def shove(v)
      @items.push(v)
      nil
    end
  end
RUBY

SIG = <<~RBS
  class Shelf
    @items: Array[Integer]
  end
RBS

DRIVER = <<~'RUBY'
  s = Shelf.new
  puts s.at(0).inspect
  s.poison
  begin
    puts s.at(2).inspect
  rescue => e
    puts "raised #{e.class}"
  end
  puts 'end'
RUBY

Dir.mktmpdir('element_guard_sig') do |sig_dir|
  File.write(File.join(sig_dir, 'shelf.rbs'), SIG)
  ENV['BC2CPP_SIG_DIRS'] = sig_dir
  ENV['BC2CPP_DECLARATION_GUARD'] = nil
  Dir.mktmpdir('element_guard') do |dir|
    code, = Bc2cppFixtureRuntime.generate(SOURCE, dir, only_owners: %w[Shelf])
    check.call('the element read of @items is guarded', code.include?('DECLARED_ELEMENT_GUARD Shelf#items'))
    check.call('the guard names the element, not the array', code.include?('"Shelf#@items[]", "Array[Integer]"'))
  end
  ENV.delete('BC2CPP_SIG_DIRS')
end

Dir.mktmpdir('element_guard_nosig') do |dir|
  ENV['BC2CPP_SIG_DIRS'] = ''
  code, = Bc2cppFixtureRuntime.generate(SOURCE, dir, only_owners: %w[Shelf])
  check.call('without a declaration no element guard is emitted', !code.include?('DECLARED_ELEMENT_GUARD'))
ensure
  ENV.delete('BC2CPP_SIG_DIRS')
end

Dir.mktmpdir('element_guard_run') do |sig_dir|
  File.write(File.join(sig_dir, 'shelf.rbs'), SIG)
  ENV['BC2CPP_SIG_DIRS'] = sig_dir
  suite.generate(SOURCE, %w[Shelf])
  suite.behaviour(DRIVER, banner: 'declared element read, interpreted and compiled', same: false) do |interpreted, compiled|
    check.call('the good element reads the same in both runs', interpreted && compiled && interpreted[0] == compiled[0])
    check.call('the interpreted run returns the bad element', interpreted&.include?('"a"') && interpreted.none? { |l| l.start_with?('raised') })
    check.call('the compiled run raises the declaration violation', compiled&.any? { |l| l.start_with?('raised') })
  end
ensure
  ENV.delete('BC2CPP_SIG_DIRS')
end


# A program class: `@things: Array[Thing]` (an exact-class element), with a Thing and an Other.
THING_SOURCE = <<~RUBY
  class Thing
    def ok?
      true
    end
  end

  class Other
    def ok?
      false
    end
  end

  class Crate
    def initialize
      @things = [Thing.new, Thing.new]
      nil
    end

    def at(i)
      @things[i]
    end

    def poison
      @things.replace([Thing.new, Other.new])
      nil
    end

    def shove(v)
      @things.push(v)
      nil
    end

    def front(v)
      @things.unshift(v)
      nil
    end

    def first_ok
      @things[0].ok?
    end

    def put(i, v)
      @things[i] = v
      nil
    end

    def add(v)
      @things << v
      nil
    end
  end
RUBY

THING_SIG = <<~RBS
  class Crate
    @things: Array[Thing]
  end
RBS

THING_DRIVER = <<~'RUBY'
  c = Crate.new
  puts c.at(0).class
  c.poison
  begin
    puts c.at(1).class
  rescue => e
    puts "raised #{e.class}"
  end
  begin
    c.put(1, Other.new)
    puts 'stored'
  rescue => e
    puts "store raised #{e.class}"
  end
  begin
    c.add(Other.new)
    puts 'pushed'
  rescue => e
    puts "push raised #{e.class}"
  end
  begin
    c.shove(Other.new)
    puts 'shoved'
  rescue => e
    puts "shove raised #{e.class}"
  end
  begin
    c.front(Other.new)
    puts 'unshifted'
  rescue => e
    puts "unshift raised #{e.class}"
  end
  puts 'end'
RUBY

Dir.mktmpdir('element_guard_thing_sig') do |sig_dir|
  File.write(File.join(sig_dir, 'crate.rbs'), THING_SIG)
  ENV['BC2CPP_SIG_DIRS'] = sig_dir
  Dir.mktmpdir('element_guard_thing') do |dir|
    code, = Bc2cppFixtureRuntime.generate(THING_SOURCE, dir, only_owners: %w[Crate Thing])
    check.call('a program-class element read is guarded', code.include?('DECLARED_ELEMENT_GUARD Crate#things'))
    check.call('a send to the declared element is a closed-world exact-class call', code.include?('NILABLE_RECEIVER :ok?') && code.include?('CLOSED_WORLD_EXACT_CLASS :ok? -> Thing#ok?'))
  end
  suite.generate(THING_SOURCE, %w[Crate Thing])
  suite.behaviour(THING_DRIVER, banner: 'declared program-class element read, interpreted and compiled', same: false) do |interpreted, compiled|
    check.call('the good program element reads the same in both runs', interpreted && compiled && interpreted[0] == compiled[0])
    check.call('the interpreted run returns the wrong-class element', interpreted&.include?('Other'))
    check.call('the compiled run raises the declaration violation', compiled&.any? { |l| l.start_with?('raised') })
    check.call('a wrong-class store raises before it writes (compiled), and stores (interpreted)', interpreted&.include?('stored') && compiled&.include?('store raised BC2cppDeclarationViolation'))
    check.call('a wrong-class << raises before it runs (compiled), and pushes (interpreted)', interpreted&.include?('pushed') && compiled&.include?('push raised BC2cppDeclarationViolation'))
    check.call('a wrong-class push raises before it runs (compiled), and pushes (interpreted)', interpreted&.include?('shoved') && compiled&.include?('shove raised BC2cppDeclarationViolation'))
    check.call('a wrong-class unshift raises before it runs (compiled), and unshifts (interpreted)', interpreted&.include?('unshifted') && compiled&.include?('unshift raised BC2cppDeclarationViolation'))
  end
ensure
  ENV.delete('BC2CPP_SIG_DIRS')
end

# DECLARED_LOOP_ELEMENT: an inlined each/map/select/inject/sort_by over `@things: Array[Thing]` tests each element it
# binds, so the block parameter is exactly Thing in the body (an exact-class call, not a by-name or owner-class chain).
# A parameter the body reassigns is not the element there and keeps its ordinary dispatch.
LOOP_SOURCE = <<~RUBY
  class Thing
    def ok?
      true
    end

    def hp
      3
    end
  end

  class Other
    def ok?
      false
    end

    def hp
      1
    end
  end

  class Pack
    def initialize
      @things = [Thing.new, Thing.new]
      nil
    end

    def total
      s = 0
      @things.each { |t| s += t.hp }
      s
    end

    def oks
      @things.map { |t| t.ok? }
    end

    def good
      @things.select { |t| t.ok? }.size
    end

    def folded
      @things.inject(0) { |acc, t| acc + t.hp }
    end

    def ordered
      @things.sort_by { |t| t.hp }.size
    end

    def swapped(flag)
      @things.map do |t|
        t = Other.new if flag
        t.ok?
      end
    end

    def poison
      @things.replace([Thing.new, Other.new])
      nil
    end
  end
RUBY

LOOP_SIG = <<~RBS
  class Pack
    @things: Array[Thing]
  end
RBS

LOOP_DRIVER = <<~'RUBY'
  def show(label)
    puts "#{label}: #{yield.inspect}"
  rescue => e
    puts "#{label}: raised #{e.class}"
  end
  p = Pack.new
  show('total') { p.total }
  show('oks') { p.oks }
  show('good') { p.good }
  show('folded') { p.folded }
  show('ordered') { p.ordered }
  show('swapped') { p.swapped(true) }
  p.poison
  show('bad total') { p.total }
  show('bad oks') { p.oks }
  show('bad good') { p.good }
  show('bad folded') { p.folded }
  show('bad ordered') { p.ordered }
  puts 'end'
RUBY

LOOP_METHODS = %w[total oks good folded ordered].freeze

Dir.mktmpdir('element_guard_loop_sig') do |sig_dir|
  File.write(File.join(sig_dir, 'pack.rbs'), LOOP_SIG)
  ENV['BC2CPP_SIG_DIRS'] = sig_dir
  Dir.mktmpdir('element_guard_loop') do |dir|
    code, = Bc2cppFixtureRuntime.generate(LOOP_SOURCE, dir, only_owners: %w[Pack Thing Other])
    bodies = code.split(%r{^// (?=Pack#)}).to_h { |chunk| [chunk[/\APack#(\w+)/, 1], chunk] }
    LOOP_METHODS.each do |name|
      body = bodies[name].to_s
      check.call("the #{name} loop tests each element it binds", body.include?('DECLARED_ELEMENT_GUARD Pack#things iterated'))
      check.call("the #{name} loop body calls the element's method exactly",
                 body.include?('CLOSED_WORLD_EXACT_CLASS :hp -> Thing#hp') || body.include?('CLOSED_WORLD_EXACT_CLASS :ok? -> Thing#ok?') ||
                   body.include?('MONO :hp -> Thing#hp'))
    end
    check.call('a multi-class name on the element is an exact-class call',
               bodies['oks'].to_s.include?('CLOSED_WORLD_EXACT_CLASS :ok? -> Thing#ok?') && !bodies['oks'].to_s.include?('POLY_SMALL_N :ok?'))
    check.call('a reassigned parameter keeps its ordinary dispatch', !bodies['swapped'].to_s.include?('CLOSED_WORLD_EXACT_CLASS :ok? -> Thing#ok?'))
  end
  ENV['BC2CPP_DECLARED_LOOP_ELEMENT'] = '0'
  Dir.mktmpdir('element_guard_loop_off') do |dir|
    code, = Bc2cppFixtureRuntime.generate(LOOP_SOURCE, dir, only_owners: %w[Pack Thing Other])
    check.call('BC2CPP_DECLARED_LOOP_ELEMENT=0 emits no loop guard', !code.include?('iterated */'))
  end
  ENV.delete('BC2CPP_DECLARED_LOOP_ELEMENT')
  suite.generate(LOOP_SOURCE, %w[Pack Thing Other])
  suite.behaviour(LOOP_DRIVER, banner: 'declared element loops, interpreted and compiled', same: false) do |interpreted, compiled|
    good = ->(lines) { lines&.reject { |l| l.start_with?('bad ', '[RPG2k]') } }
    check.call('good elements loop the same in both runs', interpreted && compiled && good.call(interpreted) == good.call(compiled))
    check.call('the interpreted run loops over the wrong-class element', interpreted&.select { |l| l.start_with?('bad ') }&.none? { |l| l.include?('raised') })
    check.call('every compiled loop raises the declaration violation on it',
               compiled&.select { |l| l.start_with?('bad ') }&.size == LOOP_METHODS.size &&
                 compiled.select { |l| l.start_with?('bad ') }.all? { |l| l.end_with?('raised BC2cppDeclarationViolation') })
  end
ensure
  ENV.delete('BC2CPP_SIG_DIRS')
  ENV.delete('BC2CPP_DECLARED_LOOP_ELEMENT')
end

# DECLARED_ARG_ELEMENT: a parameter declared `Array[T]` (or `Array[T]?` behind `xs || []`) types its inlined loop the
# same way, behind the same per-element guard.
ARG_SOURCE = <<~RUBY
  class Thing
    def ok?
      true
    end

    def hp
      3
    end
  end

  class Other
    def ok?
      false
    end

    def hp
      1
    end
  end

  class Roster
    def total(things)
      s = 0
      things.each { |t| s += t.hp }
      s
    end

    def oks(things)
      (things || []).map { |t| t.ok? }
    end

    def swapped(things, flag)
      things.map do |t|
        t = Other.new if flag
        t.ok?
      end
    end

    def other(things)
      things.map { |t| t.ok? }
    end

    def joined(things)
      (things + things).reject { |t| !t.ok? }.map { |t| t.hp }
    end

    def copied(things)
      l = things.dup
      l << Other.new
      l.map { |t| t.ok? }
    end
  end
RUBY

ARG_SIG = <<~RBS
  class Roster
    def total: (Array[Thing]) -> untyped
    def oks: (Array[Thing]?) -> untyped
    def swapped: (Array[Thing], untyped) -> untyped
    def joined: (Array[Thing]) -> untyped
    def copied: (Array[Thing]) -> untyped
  end
RBS

ARG_DRIVER = <<~'RUBY'
  def show(label)
    puts "#{label}: #{yield.inspect}"
  rescue => e
    puts "#{label}: raised #{e.class}"
  end
  r = Roster.new
  good = [Thing.new, Thing.new]
  bad = [Thing.new, Other.new]
  show('total') { r.total(good) }
  show('oks') { r.oks(good) }
  show('oks nil') { r.oks(nil) }
  show('swapped') { r.swapped(good, true) }
  show('other') { r.other(bad) }
  show('joined') { r.joined(good) }
  show('copied') { r.copied(good) }
  show('bad total') { r.total(bad) }
  show('bad oks') { r.oks(bad) }
  puts 'end'
RUBY

Dir.mktmpdir('element_guard_arg_sig') do |sig_dir|
  File.write(File.join(sig_dir, 'roster.rbs'), ARG_SIG)
  ENV['BC2CPP_SIG_DIRS'] = sig_dir
  Dir.mktmpdir('element_guard_arg') do |dir|
    code, = Bc2cppFixtureRuntime.generate(ARG_SOURCE, dir, only_owners: %w[Roster Thing Other])
    bodies = code.split(%r{^// (?=Roster#)}).to_h { |chunk| [chunk[/\ARoster#(\w+)/, 1], chunk] }
    check.call('a declared Array[T] parameter tests each element its loop binds',
               bodies['total'].to_s.include?('DECLARED_ELEMENT_GUARD Roster#total arg1 iterated'))
    check.call('`(xs || [])` of a declared Array[T]? parameter is guarded too',
               bodies['oks'].to_s.include?('DECLARED_ELEMENT_GUARD Roster#oks arg1 iterated'))
    check.call('the guarded loops call the element method exactly',
               bodies['oks'].to_s.include?('CLOSED_WORLD_EXACT_CLASS :ok? -> Thing#ok?') && !bodies['oks'].to_s.include?('POLY_SMALL_N :ok?'))
    check.call('a reassigned block parameter keeps its ordinary dispatch',
               !bodies['swapped'].to_s.include?('CLOSED_WORLD_EXACT_CLASS :ok? -> Thing#ok?'))
    check.call('an undeclared parameter gets no guard', !bodies['other'].to_s.include?('iterated */'))
    check.call('a used-once `xs + xs` keeps the element for the loop over it (DECLARED_ELEMENT_DERIVED)',
               bodies['joined'].to_s.include?('DECLARED_ELEMENT_GUARD Roster#joined arg1 iterated'))
    check.call('a copy something else also reads (and may store into) gets no element',
               !bodies['copied'].to_s.include?('iterated */'))
  end
  ENV['BC2CPP_DECLARED_ARG_ELEMENT'] = '0'
  Dir.mktmpdir('element_guard_arg_off') do |dir|
    code, = Bc2cppFixtureRuntime.generate(ARG_SOURCE, dir, only_owners: %w[Roster Thing Other])
    check.call('BC2CPP_DECLARED_ARG_ELEMENT=0 emits no parameter loop guard', !code.include?('arg1 iterated */'))
  end
  ENV.delete('BC2CPP_DECLARED_ARG_ELEMENT')
  suite.generate(ARG_SOURCE, %w[Roster Thing Other])
  suite.behaviour(ARG_DRIVER, banner: 'declared parameter element loops, interpreted and compiled', same: false) do |interpreted, compiled|
    good = ->(lines) { lines&.reject { |l| l.start_with?('bad ', '[RPG2k]') } }
    check.call('good elements (and nil) loop the same in both runs', interpreted && compiled && good.call(interpreted) == good.call(compiled))
    check.call('every compiled parameter loop raises the declaration violation on a wrong-class element',
               compiled&.select { |l| l.start_with?('bad ') }&.size == 2 &&
                 compiled.select { |l| l.start_with?('bad ') }.all? { |l| l.end_with?('raised BC2cppDeclarationViolation') })
  end
ensure
  ENV.delete('BC2CPP_SIG_DIRS')
  ENV.delete('BC2CPP_DECLARED_ARG_ELEMENT')
end

suite.finish
