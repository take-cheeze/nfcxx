#!/usr/bin/env ruby
# frozen_string_literal: true

# DECLARED_ELEMENT_GUARD: `@items: Array[Integer]` (RBS) is checked where an element is read. A GETIDX of the declared
# ivar tests its result after the read, so a non-Integer element raises BC2cppDeclarationViolation in the compiled run
# (the interpreted run has no declaration, so it returns the element). A good element behaves the same in both runs.
# Loops over the ivar (each, map, select, inject, sort_by) test each element they bind (DECLARED_LOOP_ELEMENT), and a
# block-fallback iterator body tests its element parameters on entry (DECLARED_BLOCK_ELEMENT). A record parameter's
# literal-key field read is tested the same way (DECLARED_RECORD_READ). Only an Integer index is an element read; a
# Range or two-argument index is a slice of the receiver's elements (DECLARED_INDEX_KIND).
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


# DECLARED_RECORD_READ: a record parameter `{ target: String?, ... }` is checked where a literal-key field is read, so
# the read is typed whatever wrote the Hash, and a wrong field raises in the compiled run.
RECORD_SOURCE = <<~RUBY
  class Logline
    def line(e)
      e[:target].to_s + e[:hits].to_s
    end

    def blank?(e)
      e[:target].empty?
    end

    def mutated(e)
      touch(e)
      e[:target].to_s
    end

    def touch(e)
      e[:target] = 7
      nil
    end
  end
RUBY

RECORD_SIG = <<~RBS
  class Logline
    def line: ({ target: String?, ?hits: Integer }) -> untyped
    def blank?: ({ target: String }) -> untyped
    def mutated: ({ target: String? }) -> untyped
  end
RBS

RECORD_DRIVER = <<~'RUBY'
  l = Logline.new
  puts l.line({ target: 'a', hits: 2 })
  puts l.line({})
  puts l.blank?({ target: '' }).inspect
  begin
    puts l.mutated({ target: 'b' })
  rescue => e
    puts "raised #{e.class}"
  end
  begin
    puts l.line({ target: :sym })
  rescue => e
    puts "raised #{e.class}"
  end
  puts 'end'
RUBY

Dir.mktmpdir('record_read_sig') do |sig_dir|
  File.write(File.join(sig_dir, 'logline.rbs'), RECORD_SIG)
  ENV['BC2CPP_SIG_DIRS'] = sig_dir
  Dir.mktmpdir('record_read') do |dir|
    code, = Bc2cppFixtureRuntime.generate(RECORD_SOURCE, dir, only_owners: %w[Logline])
    body = ->(name) { code.split(%r{^(?=// \w+#)}).find { |part| part.start_with?("// Logline##{name} ") }.to_s }
    line = body.call('line')
    check.call('each literal-key field read of a record parameter is guarded',
               line.scan('DECLARED_ELEMENT_GUARD Logline#line arg1[:').size == 2)
    check.call('the guarded String? field is read as nil or exactly a String',
               line.include?('NILABLE_RECEIVER :to_s -- receiver is nil or exactly String'))
    blank = body.call('blank?')
    check.call('a non-nil String field reads exactly a String (no nil allowed by the guard)',
               blank.include?('Logline#blank? arg1[:target]') && !blank.include?('owner-call: empty?') &&
                 !blank[/if \(mrb_unlikely\(!\(mrb_nil_p/])
  end
  Dir.mktmpdir('record_read_off') do |dir|
    ENV['BC2CPP_DECLARED_RECORD_READ'] = '0'
    code, = Bc2cppFixtureRuntime.generate(RECORD_SOURCE, dir, only_owners: %w[Logline])
    check.call('BC2CPP_DECLARED_RECORD_READ=0 leaves the reads unguarded', !code.include?('Logline#line arg1[:'))
  ensure
    ENV.delete('BC2CPP_DECLARED_RECORD_READ')
  end
  suite.generate(RECORD_SOURCE, %w[Logline])
  suite.behaviour(RECORD_DRIVER, banner: 'declared record read, interpreted and compiled', same: false) do |interpreted, compiled|
    check.call('good records read the same in both runs', interpreted && compiled && interpreted.first(3) == compiled.first(3))
    raised = compiled&.count('raised BC2cppDeclarationViolation')
    check.call('a field mutated through an alias before the read raises in the compiled run',
               raised && raised >= 1 && compiled.any? { |l| l.include?('Logline#mutated argument 1[:target]') } &&
                 interpreted[3] == '7')
    check.call('a field of another class raises in the compiled run',
               raised == 2 && compiled.any? { |l| l.include?('Logline#line argument 1[:target]') } && interpreted[4] == 'sym')
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

    def rescued
      s = 0
      @things.each { |t| s += t.hp }
      s
    rescue StandardError
      -1
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
  show('rescued') { p.rescued }
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
    # DECLARED_ELEMENT_HANDLERS: the loop sits in the rescue's try body, emitted ahead of the method's own header.
    try_body = code[/^static mrb_value Pack_rescued_impl_rescue_try\(.*?^}$/m].to_s
    check.call('a loop inside a rescue tests each element it binds',
               try_body.include?('DECLARED_ELEMENT_GUARD Pack#things iterated') && try_body.include?('Thing#hp'))
  end
  ENV['BC2CPP_DECLARED_ELEMENT_HANDLERS'] = '0'
  Dir.mktmpdir('element_guard_loop_handlers_off') do |dir|
    code, = Bc2cppFixtureRuntime.generate(LOOP_SOURCE, dir, only_owners: %w[Pack Thing Other])
    try_body = code[/^static mrb_value Pack_rescued_impl_rescue_try\(.*?^}$/m].to_s
    check.call('BC2CPP_DECLARED_ELEMENT_HANDLERS=0 leaves the rescued loop unguarded',
               !try_body.empty? && !try_body.include?('DECLARED_ELEMENT_GUARD Pack#things iterated'))
  end
  ENV.delete('BC2CPP_DECLARED_ELEMENT_HANDLERS')
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

    def ordered(things)
      things.sort { |a, b| a.hp <=> b.hp }.size
    end

    def ranked(n, things = [])
      things.sort { |a, b| a.hp <=> b.hp }.size + n
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
    def ordered: (Array[Thing]) -> untyped
    def ranked: (Integer, ?Array[Thing]) -> untyped
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
  show('ordered') { r.ordered(good) }
  show('ranked') { r.ranked(1, good) }
  show('ranked default') { r.ranked(1) }
  show('bad total') { r.total(bad) }
  show('bad oks') { r.oks(bad) }
  show('bad ordered') { r.ordered(bad) }
  show('bad ranked') { r.ranked(1, bad) }
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
    ordered_block = code[/^static mrb_value Roster_ordered_block_fallback\w*_impl\(.*?^}\n/m].to_s
    check.call('a block-fallback iterator body tests its element parameters on entry (DECLARED_BLOCK_ELEMENT)',
               ordered_block.scan('DECLARED_ELEMENT_GUARD Roster#ordered arg1 yielded').size == 2)
    ranked_block = code[/^static mrb_value Roster_ranked_block_fallback\w*_impl\(.*?^}\n/m].to_s
    check.call('an optional `?Array[T]` parameter with an empty-literal default is guarded the same way',
               ranked_block.include?('DECLARED_ELEMENT_GUARD Roster#ranked arg2 yielded'))
    check.call('so its sends on them are exact, with no owner call',
               !ordered_block.empty? && !ordered_block.include?('owner-call: hp') && !ordered_block.include?('POLY_SMALL_N :hp'))
  end
  ENV['BC2CPP_DECLARED_ARG_ELEMENT'] = '0'
  Dir.mktmpdir('element_guard_arg_off') do |dir|
    code, = Bc2cppFixtureRuntime.generate(ARG_SOURCE, dir, only_owners: %w[Roster Thing Other])
    check.call('BC2CPP_DECLARED_ARG_ELEMENT=0 emits no parameter loop guard', !code.include?('arg1 iterated */'))
  end
  ENV['BC2CPP_DECLARED_ARG_ELEMENT'] = nil
  ENV['BC2CPP_DECLARED_BLOCK_ELEMENT'] = '0'
  Dir.mktmpdir('element_guard_block_off') do |dir|
    code, = Bc2cppFixtureRuntime.generate(ARG_SOURCE, dir, only_owners: %w[Roster Thing Other])
    check.call('BC2CPP_DECLARED_BLOCK_ELEMENT=0 emits no block entry guard', !code.include?('yielded */'))
  end
  ENV.delete('BC2CPP_DECLARED_ARG_ELEMENT')
  ENV.delete('BC2CPP_DECLARED_BLOCK_ELEMENT')
  suite.generate(ARG_SOURCE, %w[Roster Thing Other])
  suite.behaviour(ARG_DRIVER, banner: 'declared parameter element loops, interpreted and compiled', same: false) do |interpreted, compiled|
    good = ->(lines) { lines&.reject { |l| l.start_with?('bad ', '[RPG2k]') } }
    check.call('good elements (and nil) loop the same in both runs', interpreted && compiled && good.call(interpreted) == good.call(compiled))
    check.call('every compiled parameter loop raises the declaration violation on a wrong-class element',
               compiled&.select { |l| l.start_with?('bad ') }&.size == 4 &&
                 compiled.select { |l| l.start_with?('bad ') }.all? { |l| l.end_with?('raised BC2cppDeclarationViolation') })
  end
ensure
  ENV.delete('BC2CPP_SIG_DIRS')
  ENV.delete('BC2CPP_DECLARED_ARG_ELEMENT')
  ENV.delete('BC2CPP_DECLARED_BLOCK_ELEMENT')
end

# DECLARED_CORE_ELEMENT: an `Array[String]` / `Array[Integer]` element is trusted the same way (String, Array and Hash
# only in a build with no subclass of them), so its loop and block parameters are tested on entry too.
CORE_SOURCE = <<~RUBY
  class Doc
    def initialize(lines, ids)
      @lines = lines
      @ids = ids
      nil
    end

    def total
      t = 0
      @lines.each { |l| t += l.length }
      t
    end

    def longest
      @lines.sort { |a, b| a.length <=> b.length }.size
    end

    def zeros
      @ids.count { |i| i.nil? }
    end
  end
RUBY

CORE_SIG = <<~RBS
  class Doc
    @lines: Array[String]
    @ids: Array[Integer]
  end
RBS

CORE_DRIVER = <<~'RUBY'
  def show(label)
    puts "#{label}: #{yield.inspect}"
  rescue => e
    puts "#{label}: raised #{e.class}"
  end
  d = Doc.new(%w[a bb], [1, 2])
  show('total') { d.total }
  show('longest') { d.longest }
  show('zeros') { d.zeros }
  b = Doc.new(['a', :b], [1, 'x'])
  show('bad total') { b.total }
  show('bad longest') { b.longest }
  show('bad zeros') { b.zeros }
  puts 'end'
RUBY

Dir.mktmpdir('element_guard_core_sig') do |sig_dir|
  File.write(File.join(sig_dir, 'doc.rbs'), CORE_SIG)
  ENV['BC2CPP_SIG_DIRS'] = sig_dir
  Dir.mktmpdir('element_guard_core') do |dir|
    code, = Bc2cppFixtureRuntime.generate(CORE_SOURCE, dir, only_owners: %w[Doc])
    bodies = code.split(%r{^// (?=Doc#)}).to_h { |chunk| [chunk[/\ADoc#(\w+)/, 1], chunk] }
    check.call('an Array[String] loop tests each element with mrb_string_p',
               bodies['total'].to_s.match?(/mrb_string_p\(\w+\)\)\)\) bc2cpp_declared_ivar_violation.*DECLARED_ELEMENT_GUARD Doc#lines iterated/))
    check.call('an Array[String] block-fallback body tests its element parameters on entry',
               code.scan('DECLARED_ELEMENT_GUARD Doc#lines yielded').size == 2)
    check.call('an Array[Integer] loop is guarded and `i.nil?` on the element folds to false',
               bodies['zeros'].to_s.include?('DECLARED_ELEMENT_GUARD Doc#ids iterated') &&
                 !bodies['zeros'].to_s.include?('owner-call: nil?'))
  end
  ENV['BC2CPP_DECLARED_CORE_ELEMENT'] = '0'
  Dir.mktmpdir('element_guard_core_off') do |dir|
    code, = Bc2cppFixtureRuntime.generate(CORE_SOURCE, dir, only_owners: %w[Doc])
    check.call('BC2CPP_DECLARED_CORE_ELEMENT=0 leaves core elements unguarded',
               !code.include?('Doc#lines iterated') && !code.include?('Doc#ids iterated') && !code.include?('yielded */'))
  end
  ENV.delete('BC2CPP_DECLARED_CORE_ELEMENT')
  suite.generate(CORE_SOURCE, %w[Doc])
  suite.behaviour(CORE_DRIVER, banner: 'declared core element loops, interpreted and compiled', same: false) do |interpreted, compiled|
    good = ->(lines) { lines&.reject { |l| l.start_with?('bad ', '[RPG2k]') } }
    check.call('good core elements loop the same in both runs', interpreted && compiled && good.call(interpreted) == good.call(compiled))
    check.call('every compiled core element loop raises the declaration violation on a wrong-class element',
               compiled&.select { |l| l.start_with?('bad ') }&.size == 3 &&
                 compiled.select { |l| l.start_with?('bad ') }.all? { |l| l.end_with?('raised BC2cppDeclarationViolation') })
  end
ensure
  ENV.delete('BC2CPP_SIG_DIRS')
  ENV.delete('BC2CPP_DECLARED_CORE_ELEMENT')
end


# DECLARED_INDEX_KIND: a declared element receiver's `[]` is an element read (guarded, typed) only for an Integer index.
# A Range or two-argument read is a slice: no element guard, an Array-or-nil result, and the loop or read over it keeps
# the declared element (tested there). An index the flow does not prove is tested at run time and typed nothing.
INDEX_SOURCE = <<~RUBY
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

  class Stack
    def initialize
      @items = []
      nil
    end

    def head(frames)
      frames[0...-1].size
    end

    def rest(frames)
      frames[1..].map { |t| t.ok? }
    end

    def at(frames, i)
      frames[i].ok?
    end

    def win(frames, a, b)
      frames[a..b][0].ok?
    end

    def pair(frames, a, n)
      frames[a, n].map { |t| t.ok? }
    end

    def pair_head(frames, a, n)
      frames[a, n][0].ok?
    end

    def any(frames, k)
      frames[k]
    end

    def any_ok(frames, k)
      frames[k].ok?
    end

    def fill(v)
      @items = v
      nil
    end

    def ihead
      @items[0...-1].map { |t| t.ok? }
    end

    def iat(i)
      @items[i].ok?
    end
  end
RUBY

INDEX_SIG = <<~RBS
  class Stack
    @items: Array[Thing]
    def head: (Array[Thing]?) -> untyped
    def rest: (Array[Thing]) -> untyped
    def at: (Array[Thing], Integer) -> untyped
    def win: (Array[Thing], Integer, Integer) -> untyped
    def pair: (Array[Thing], Integer, Integer) -> untyped
    def pair_head: (Array[Thing], Integer, Integer) -> untyped
    def any: (Array[Thing], untyped) -> untyped
    def any_ok: (Array[Thing], untyped) -> untyped
    def iat: (Integer) -> untyped
  end
RBS

INDEX_DRIVER = <<~'RUBY'
  def show(label)
    puts "#{label}: #{yield.inspect}"
  rescue => e
    puts "#{label}: raised #{e.class}"
  end
  s = Stack.new
  good = [Thing.new, Thing.new, Thing.new]
  bad = [Thing.new, Other.new, Thing.new]
  show('head') { s.head(good) }
  show('head bad') { s.head(bad) }
  show('rest') { s.rest(good) }
  show('at') { s.at(good, 1) }
  show('win') { s.win(good, 1, 2) }
  show('pair') { s.pair(good, 1, 2) }
  show('pair_head') { s.pair_head(good, 1, 2) }
  show('pair_head past end') { s.pair_head(good, 4, 1) }
  show('any range') { s.any(bad, 0..1).size }
  show('any past end') { s.any(good, 9) }
  show('any_ok range') { s.any_ok(good, 0..1) }
  s.fill(good)
  show('ihead') { s.ihead }
  show('iat') { s.iat(2) }
  show('bad rest') { s.rest(bad) }
  show('bad at') { s.at(bad, 1) }
  show('bad win') { s.win(bad, 1, 2) }
  show('bad pair') { s.pair(bad, 0, 2) }
  show('bad pair_head') { s.pair_head(bad, 1, 1) }
  show('bad any') { s.any(bad, 1).ok? }
  s.fill(bad)
  show('bad ihead') { s.ihead }
  show('bad iat') { s.iat(1) }
  puts 'end'
RUBY

Dir.mktmpdir('element_guard_index_sig') do |sig_dir|
  File.write(File.join(sig_dir, 'stack.rbs'), INDEX_SIG)
  ENV['BC2CPP_SIG_DIRS'] = sig_dir
  split = ->(code) { code.split(%r{^// (?=Stack#)}).to_h { |chunk| [chunk[/\AStack#(\w+)/, 1], chunk] } }
  fallback = ->(code, name) { code[/^static mrb_value Stack_#{name}_block_fallback\w*_impl\(.*?^}\n/m].to_s }
  Dir.mktmpdir('element_guard_index') do |dir|
    code, = Bc2cppFixtureRuntime.generate(INDEX_SOURCE, dir, only_owners: %w[Stack Thing Other])
    bodies = split.call(code)
    check.call('a Range read of a declared Array[T]? parameter is a slice, with no element guard',
               !code.include?('DECLARED_ELEMENT_GUARD Stack#head'))
    rest = fallback.call(code, 'rest')
    check.call('the loop over `xs[1..]` tests its element and calls it exactly',
               rest.include?('DECLARED_ELEMENT_GUARD Stack#rest arg1 yielded') &&
                 rest.include?('CLOSED_WORLD_EXACT_CLASS :ok? -> Thing#ok?') && !rest.include?('owner-call: ok?'))
    check.call('an Integer index is still an element read, guarded with no index test',
               bodies['at'].to_s.include?('DECLARED_ELEMENT_GUARD Stack#at arg1 read') && !bodies['at'].to_s.include?('mrb_bigint_p(r'))
    check.call('`xs[a..b][0]` is a slice read as an Array, then a typed element read',
               bodies['win'].to_s.scan('DECLARED_ELEMENT_GUARD Stack#win arg1 read').size == 1 &&
                 bodies['win'].to_s.include?('receiver is nil or exactly Array') &&
                 bodies['win'].to_s.include?('CLOSED_WORLD_EXACT_CLASS :ok? -> Thing#ok?'))
    check.call('the loop over `xs[a, n]` keeps the declared element',
               fallback.call(code, 'pair').include?('DECLARED_ELEMENT_GUARD Stack#pair arg1 yielded'))
    check.call('`xs[a, n][0]` is a slice read as an Array, then a typed element read (ARRAY_SLICE2_RESULT)',
               bodies['pair_head'].to_s.scan('DECLARED_ELEMENT_GUARD Stack#pair_head arg1 read').size == 1 &&
                 bodies['pair_head'].to_s.include?('receiver is nil or exactly Array') &&
                 bodies['pair_head'].to_s.include?('CLOSED_WORLD_EXACT_CLASS :ok? -> Thing#ok?'))
    check.call('an unproven index is tested at run time before the element guard',
               bodies['any'].to_s.match?(/if \(mrb_integer_p\((r\d+)\) \|\| mrb_bigint_p\(\1\)\) \{\n.*DECLARED_ELEMENT_GUARD Stack#any arg1 read/))
    check.call('and gives the read no element class', !bodies['any_ok'].to_s.include?('CLOSED_WORLD_EXACT_CLASS :ok? -> Thing#ok?'))
    ihead = fallback.call(code, 'ihead')
    check.call('a Range read of a declared @items is a slice whose loop keeps the element',
               !bodies['ihead'].to_s.include?('Stack#items read') && ihead.include?('DECLARED_ELEMENT_GUARD Stack#items yielded'))
    check.call('an Integer read of @items is still guarded', bodies['iat'].to_s.include?('DECLARED_ELEMENT_GUARD Stack#items read'))
  end
  ENV['BC2CPP_DECLARED_INDEX_KIND'] = '0'
  Dir.mktmpdir('element_guard_index_off') do |dir|
    code, = Bc2cppFixtureRuntime.generate(INDEX_SOURCE, dir, only_owners: %w[Stack Thing Other])
    bodies = split.call(code)
    check.call('BC2CPP_DECLARED_INDEX_KIND=0 guards every read as an element again',
               bodies['head'].to_s.include?('DECLARED_ELEMENT_GUARD Stack#head arg1 read') &&
                 bodies['ihead'].to_s.include?('DECLARED_ELEMENT_GUARD Stack#items read') && !code.include?('mrb_bigint_p(r'))
  end
  ENV.delete('BC2CPP_DECLARED_INDEX_KIND')
  ENV['BC2CPP_ARRAY_SLICE2_RESULT'] = '0'
  Dir.mktmpdir('element_guard_slice2_off') do |dir|
    code, = Bc2cppFixtureRuntime.generate(INDEX_SOURCE, dir, only_owners: %w[Stack Thing Other])
    check.call('BC2CPP_ARRAY_SLICE2_RESULT=0 leaves `xs[a, n]` untyped',
               !split.call(code)['pair_head'].to_s.include?('receiver is nil or exactly Array'))
  end
  ENV.delete('BC2CPP_ARRAY_SLICE2_RESULT')
  suite.generate(INDEX_SOURCE, %w[Stack Thing Other])
  suite.behaviour(INDEX_DRIVER, banner: 'declared element index kinds, interpreted and compiled', same: false) do |interpreted, compiled|
    good = ->(lines) { lines&.reject { |l| l.start_with?('bad ', '[RPG2k]') } }
    check.call('slices, Integer reads and unproven indexes return the same in both runs',
               interpreted && compiled && good.call(interpreted) == good.call(compiled))
    check.call('the interpreted run returns every wrong element', interpreted&.none? { |l| l.include?('raised BC2cpp') })
    check.call('every compiled element read and slice loop raises on a wrong element',
               compiled&.select { |l| l.start_with?('bad ') }&.size == 8 &&
                 compiled.select { |l| l.start_with?('bad ') }.all? { |l| l.end_with?('raised BC2cppDeclarationViolation') })
  end
ensure
  ENV.delete('BC2CPP_SIG_DIRS')
  ENV.delete('BC2CPP_DECLARED_INDEX_KIND')
  ENV.delete('BC2CPP_ARRAY_SLICE2_RESULT')
end

# DECLARED_ELEMENT_READER: `@pack.things`, where the flow proves `@pack` exactly Pack (or a subclass that keeps the
# reader) and Pack#things is the attr_reader of the declared `@things: Array[Thing]`, is that ivar: its loop and its
# Integer read are guarded and typed as `@things` is. A subclass overriding the reader gets nothing.
READER_SOURCE = <<~RUBY
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
    attr_reader :things

    def initialize
      @things = [Thing.new, Thing.new]
      nil
    end

    def poison
      @things.replace([Thing.new, Thing.new, Other.new])
      nil
    end
  end

  class Kept < Pack
  end

  class Fake < Pack
    def things
      [Other.new]
    end
  end

  class Team
    def initialize
      @pack = Pack.new
      @kept = Kept.new
      @fake = Fake.new
      nil
    end

    def total
      s = 0
      @pack.things.each { |t| s += t.hp }
      s
    end

    def at(i)
      @pack.things[i].ok?
    end

    def kept_total
      s = 0
      @kept.things.each { |t| s += t.hp }
      s
    end

    def fake_total
      s = 0
      @fake.things.each { |t| s += t.hp }
      s
    end

    def poison
      @pack.poison
      @kept.poison
    end
  end
RUBY

READER_SIG = <<~RBS
  class Pack
    @things: Array[Thing]
  end
  class Team
    def at: (Integer) -> untyped
  end
RBS

READER_DRIVER = <<~'RUBY'
  def show(label)
    puts "#{label}: #{yield.inspect}"
  rescue => e
    puts "#{label}: raised #{e.class}"
  end
  t = Team.new
  show('total') { t.total }
  show('at') { t.at(1) }
  show('at past end') { t.at(9) }
  show('kept') { t.kept_total }
  show('fake') { t.fake_total }
  t.poison
  show('bad total') { t.total }
  show('bad at') { t.at(2) }
  show('bad kept') { t.kept_total }
  show('fake after') { t.fake_total }
  puts 'end'
RUBY

Dir.mktmpdir('element_guard_reader_sig') do |sig_dir|
  File.write(File.join(sig_dir, 'pack.rbs'), READER_SIG)
  ENV['BC2CPP_SIG_DIRS'] = sig_dir
  owners = %w[Team Pack Kept Fake Thing Other]
  split = ->(code) { code.split(%r{^// (?=Team#)}).to_h { |chunk| [chunk[/\ATeam#(\w+)/, 1], chunk] } }
  Dir.mktmpdir('element_guard_reader') do |dir|
    code, = Bc2cppFixtureRuntime.generate(READER_SOURCE, dir, only_owners: owners)
    bodies = split.call(code)
    check.call('a loop over an exact receiver\'s attr_reader of a declared ivar tests each element',
               bodies['total'].to_s.include?('DECLARED_ELEMENT_GUARD Pack#things iterated') &&
                 bodies['total'].to_s.include?('CLOSED_WORLD_EXACT_CLASS :hp -> Thing#hp'))
    check.call('an Integer read through the reader is guarded and typed',
               bodies['at'].to_s.include?('DECLARED_ELEMENT_GUARD Pack#things read') &&
                 bodies['at'].to_s.include?('CLOSED_WORLD_EXACT_CLASS :ok? -> Thing#ok?'))
    check.call('a subclass keeping the reader reads the declaring class\'s ivar',
               bodies['kept_total'].to_s.include?('DECLARED_ELEMENT_GUARD Pack#things iterated'))
    check.call('a subclass overriding the reader gets no element', !bodies['fake_total'].to_s.include?('DECLARED_ELEMENT_GUARD'))
  end
  ENV['BC2CPP_DECLARED_ELEMENT_READER'] = '0'
  Dir.mktmpdir('element_guard_reader_off') do |dir|
    code, = Bc2cppFixtureRuntime.generate(READER_SOURCE, dir, only_owners: owners)
    check.call('BC2CPP_DECLARED_ELEMENT_READER=0 leaves reader results unguarded', split.call(code).select { |name, _| name }.values.none? { |body| body.include?('DECLARED_ELEMENT_GUARD') })
  end
  ENV.delete('BC2CPP_DECLARED_ELEMENT_READER')
  suite.generate(READER_SOURCE, owners)
  suite.behaviour(READER_DRIVER, banner: 'declared elements through an attr_reader, interpreted and compiled', same: false) do |interpreted, compiled|
    good = ->(lines) { lines&.reject { |l| l.start_with?('bad ', '[RPG2k]') } }
    check.call('good elements read the same through the reader in both runs', interpreted && compiled && good.call(interpreted) == good.call(compiled))
    check.call('the interpreted run reads the wrong-class element', interpreted&.none? { |l| l.include?('raised BC2cpp') })
    check.call('every compiled read through the reader raises on it',
               compiled&.select { |l| l.start_with?('bad ') }&.size == 3 &&
                 compiled.select { |l| l.start_with?('bad ') }.all? { |l| l.end_with?('raised BC2cppDeclarationViolation') })
  end
ensure
  ENV.delete('BC2CPP_SIG_DIRS')
  ENV.delete('BC2CPP_DECLARED_ELEMENT_READER')
end

suite.finish
