#!/usr/bin/env ruby
# frozen_string_literal: true

# Unit checks for YIELD_REACH (docs/adr/0283, tools/bc2cpp/yield_reach.rb): which compiled frames a
# Fiber.yield can be reached above. Small programs are compiled by mrbc and analysed as a closed
# world; the expectations are about the analysis, the run-time behaviour is checked by
# bc2cpp_block_core_direct_check.rb and bc2cpp_resumable_check.rb.
#
# Usage: MRBC=path/to/host/mrbc ruby scripts/bc2cpp/yield_reach_check.rb

require 'set'
require 'tmpdir'
require_relative '../../tools/bc2cpp/irep'
require_relative '../../tools/bc2cpp/yield_reach'
require_relative '../../tools/bc2cpp/compiled_gems'

ROOT = File.expand_path('../..', __dir__)

unless system(MRBC, '--version', out: File::NULL, err: File::NULL)
  puts '  SKIP: no host mrbc (set MRBC)'
  exit 0
end

failures = []
check = lambda do |what, condition|
  puts "  #{condition ? 'ok  ' : 'FAIL'} #{what}"
  failures << what unless condition
end

def analyse(source, extra_srcs: [], sound: true)
  Dir.mktmpdir do |dir|
    path = File.join(dir, 'fx.rb')
    File.write(path, source)
    ireps, = compile_ireps(extra_srcs + [path], 'fx', dir)
    YieldReach.new(ireps: ireps, sound: sound, opaque_names: Set.new, native_names: Set.new)
  end
end

# The method labelled Klass#name, and the blocks written inside it.
def method_label(reach, klass, name)
  reach.nodes.values.find { |n| n.kind == :method && n.klass == klass && n.name == name }&.label or
    raise "no #{klass}##{name}"
end

def blocks_in(reach, label)
  reach.nodes.values.select { |n| n.kind == :block && n.owner == label }.map(&:label)
end

# -- a closed world without Fibers: everything is yield-free ---------------------------------------

plain = analyse(<<~RUBY)
  class Plain
    def sum(a); s = 0; a.each { |x| s += x }; s; end
    def squares(a); a.map { |x| helper(x) }; end
    def helper(x); x * x; end
    def dyn(n); send(n); end
    def stash(&b); @cb = b; end
    def fire; @cb.call; end
  end
RUBY
check.call('no Fiber.yield anywhere: every method is yield-free',
           plain.method_labels.all? { |l| plain.yield_free?(l) })
check.call('and so is every block', plain.block_labels.all? { |l| plain.yield_free?(l) })
check.call('a world that is not closed proves nothing',
           analyse('class P; def f(a); a.each { |x| x }; end; end', sound: false).then { |r| r.block_labels.none? { |l| r.yield_free?(l) } })

# -- Fiber.yield and its callers, by name, whatever the receiver -----------------------------------

fx = analyse(<<~RUBY)
  class Helper
    def step; Fiber.yield 1; end
    def quiet; 1; end
  end
  class Runner
    def initialize; @h = Helper.new; end
    def direct(a); a.each { |x| Fiber.yield x }; end
    def via_helper(a); a.each { |x| @h.step }; end
    def via_quiet(a); a.each { |x| @h.quiet }; end
    def plain(a); s = 0; a.each { |x| s += x }; s; end
    def start; Fiber.new { @h.step }; end
    def start_quiet; Fiber.new { @h.quiet }; end
    def dyn(n); send(n); end
    def nested(a); a.each { |x| [x].each { |y| @h.step } }; end
  end
RUBY
free = ->(k, m) { fx.yield_free?(method_label(fx, k, m)) }
block_free = ->(k, m) { blocks_in(fx, method_label(fx, k, m)).all? { |b| fx.yield_free?(b) } }
check.call('a block that calls Fiber.yield is not yield-free', !block_free.call('Runner', 'direct'))
check.call('a block that reaches Fiber.yield through an explicit-receiver call in another class is not',
           !block_free.call('Runner', 'via_helper') && !free.call('Runner', 'via_helper'))
check.call('a block calling a quiet method of that class is yield-free', block_free.call('Runner', 'via_quiet'))
check.call('a block that only adds numbers is yield-free', block_free.call('Runner', 'plain') && free.call('Runner', 'plain'))
check.call('a yield two blocks down keeps every enclosing block from being yield-free',
           !block_free.call('Runner', 'nested') && !free.call('Runner', 'nested'))
check.call('a computed send may reach any yielding method', !free.call('Runner', 'dyn'))
check.call('the yielding helper itself is not yield-free', !free.call('Helper', 'step') && free.call('Helper', 'quiet'))

crossable = fx.fiber_crossable
check.call('the Fiber.new body reaches Helper#step across classes', crossable.include?(method_label(fx, 'Helper', 'step')))
unsafe = fx.fiber_unsafe(fx.method_labels).map { |l| fx.nodes[l] }.to_set { |n| [n.klass, n.name] }
check.call('Helper#step is refused: it is reachable from a Fiber and yields (explicit receiver, other class)',
           unsafe.include?(%w[Helper step]))
check.call('Helper#quiet is not refused: it cannot yield', !unsafe.include?(%w[Helper quiet]))

# Outside a closed world nothing is proved yield-free, but the refusal under a Fiber stays best effort:
# it follows every call edge by name (explicit receivers included) and does not treat unknown code
# as yielding, so a program with computed sends and eval keeps its compiled methods.
open_world = analyse(<<~RUBY, sound: false)
  class Helper
    def step; Fiber.yield 1; end
    def relay; step; end
    def quiet; 1; end
  end
  class Runner
    def initialize; @h = Helper.new; end
    def start; Fiber.new { @h.relay; @h.quiet }; end
    def dyn(n); send(n); instance_eval("1"); end
    def other; @h.quiet; end
  end
RUBY
open_unsafe = open_world.fiber_unsafe(open_world.method_labels).map { |l| open_world.nodes[l] }.to_set { |n| [n.klass, n.name] }
check.call('an open world still refuses what a Fiber reaches across classes and may yield',
           open_unsafe.include?(%w[Helper relay]) && open_unsafe.include?(%w[Helper step]))
check.call('and does not refuse what cannot yield, computed sends or eval included',
           !open_unsafe.include?(%w[Helper quiet]) && !open_unsafe.include?(%w[Runner dyn]) && !open_unsafe.include?(%w[Runner other]))

# -- blocks handed to a method that runs them ------------------------------------------------------

iter = analyse(<<~RUBY)
  class Coll
    def each_item(&b); @a.each { |x| b.call(x) }; end
    def each_pair; @a.each { |x| yield x }; end
    def total; s = 0; each_pair { |x| s += x }; s; end
    def total2; s = 0; each_item { |x| s += x }; s; end
  end
RUBY
check.call('a block that runs the received block is yield-free while nothing yielding is passed',
           iter.method_labels.all? { |l| iter.yield_free?(l) } && iter.block_labels.all? { |l| iter.yield_free?(l) })

iter2 = analyse(<<~RUBY)
  class Coll
    def each_pair; @a.each { |x| yield x }; end
    def total; each_pair { |x| Fiber.yield x }; end
    def other; s = 0; @a.each { |x| s += x }; s; end
  end
RUBY
pair = method_label(iter2, 'Coll', 'each_pair')
check.call('once a yielding block is passed to it, the iterator and its inner block may yield',
           !iter2.yield_free?(pair) && blocks_in(iter2, pair).none? { |b| iter2.yield_free?(b) })
check.call('the body of that iterator is still yield-free given a yield-free block', iter2.body_yield_free?(pair))
check.call('unrelated blocks stay yield-free', blocks_in(iter2, method_label(iter2, 'Coll', 'other')).all? { |b| iter2.yield_free?(b) })

# -- Proc values ------------------------------------------------------------------------------------

procs = analyse(<<~RUBY)
  class Keep
    def initialize(&b); @cb = b; end
    def fire(x); @cb.call(x); end
    def other; @a.map { |x| x + 1 }; end
  end
  class Use
    def go; Keep.new { |x| Fiber.yield x }; end
  end
RUBY
check.call('a stored block that yields makes the sites that call unknown procs may-yield',
           !procs.yield_free?(method_label(procs, 'Keep', 'fire')))
check.call('but not blocks that run no unknown Proc', blocks_in(procs, method_label(procs, 'Keep', 'other')).all? { |b| procs.yield_free?(b) })

# -- Fiber escapes ----------------------------------------------------------------------------------

esc = analyse(<<~RUBY)
  class Esc
    def go(f); f.yield(1); end
    def fiber_class; Fiber; end
    def add(a); a.each { |x| x }; end
  end
RUBY
check.call('when the Fiber class flows anywhere, a `yield` on an unknown receiver may be Fiber.yield',
           !esc.yield_free?(method_label(esc, 'Esc', 'go')))

evalr = analyse("class Ev; def go(s); instance_eval(s); end; def ok(a); a.each { |x| x }; end; end")
check.call('instance_eval of a string is unknown code',
           !evalr.yield_free?(method_label(evalr, 'Ev', 'go')) && evalr.yield_free?(method_label(evalr, 'Ev', 'ok')))

# -- the Enumerator machinery of mruby's own Ruby ---------------------------------------------------

core = core_compiled_mrblib_srcs(ROOT)
if core.empty?
  puts '  SKIP core Enumerator checks: no 3rd/mruby'
else
  world = analyse(<<~RUBY, extra_srcs: core)
    class EnFx
      def sum(a); s = 0; a.each { |x| s += x }; s; end
      def gen; Enumerator.new { |y| y << 1; y << 2 }; end
      def each; @a.each { |x| yield x }; end
      def each_named; return to_enum(:each_named) unless block_given?; @a.each { |x| yield x }; end
      def each_plain; @a.each { |x| yield x }; end
      def use; s = 0; each_plain { |x| s += x }; s; end
      def push(a, r); a.each { |x| r << x }; end
    end
  RUBY
  check.call('the Enumerator machinery is modelled explicitly', world.stats[:sealed] == true)
  check.call('a block that adds into an Array is yield-free although Enumerator::Yielder#<< is not',
             blocks_in(world, method_label(world, 'EnFx', 'push')).all? { |b| world.yield_free?(b) })
  check.call('a generator block is not yield-free: a yielder call reaches the Fiber of Enumerator#next',
             blocks_in(world, method_label(world, 'EnFx', 'gen')).none? { |b| world.yield_free?(b) })
  check.call('a plain sum block is yield-free', blocks_in(world, method_label(world, 'EnFx', 'sum')).all? { |b| world.yield_free?(b) })
  check.call('an `each` that runs its block may run the block Enumerator#next supplies',
             !world.yield_free?(method_label(world, 'EnFx', 'each')))
  check.call('so does an iterator an Enumerator is made for (to_enum(:name))',
             !world.yield_free?(method_label(world, 'EnFx', 'each_named')))
  check.call('an iterator no Enumerator can be made for keeps the yield-free proof',
             world.yield_free?(method_label(world, 'EnFx', 'each_plain')))
  check.call('the body of the iterator is yield-free given a yield-free block', world.body_yield_free?(method_label(world, 'EnFx', 'each')))
  check.call('the method that builds a generator is refused when the generator block is reachable from a Fiber',
             world.fiber_unsafe([method_label(world, 'EnFx', 'gen')]).include?(method_label(world, 'EnFx', 'gen')))

  # Anything that lets a yielder go elsewhere unseals the machinery: `<<` is then any object's.
  leaky = analyse(<<~RUBY, extra_srcs: core)
    class Leaky
      def yielder; Enumerator::Yielder; end
      def push(a, r); a.each { |x| r << x }; end
    end
  RUBY
  check.call('a reference to Enumerator::Yielder outside mruby-enumerator unseals the model',
             leaky.stats[:sealed].is_a?(Array) && leaky.stats[:sealed].include?(:yielder_named_outside))
  check.call('and a block that adds into an Array is then no longer proved yield-free',
             blocks_in(leaky, method_label(leaky, 'Leaky', 'push')).none? { |b| leaky.yield_free?(b) })
end

literal_procs = analyse(<<~RUBY)
  class LiteralProcs
    def stash; -> { Fiber.yield 1 }; end
    def quiet; p = -> { 42 }; p.call; end
    def yielding; p = -> { Fiber.yield 2 }; p.call; end
    def unknown(p); p.call; end
    def later(p); p.call; p = -> { 42 }; end
    def conditional(p, flag); p = -> { 42 } if flag; p.call; end
    def start; Fiber.new { quiet }; end
  end
RUBY
check.call('a known literal Proc call excludes unrelated escaped yielding blocks',
           literal_procs.yield_free?(method_label(literal_procs, 'LiteralProcs', 'quiet')))
check.call('a known literal Proc still reaches its own yielding body',
           !literal_procs.yield_free?(method_label(literal_procs, 'LiteralProcs', 'yielding')))
check.call('an unknown Proc still reaches escaped yielding blocks',
           !literal_procs.yield_free?(method_label(literal_procs, 'LiteralProcs', 'unknown')))
%w[later conditional].each do |name|
  check.call("a #{name} literal assignment does not hide the incoming Proc",
             !literal_procs.yield_free?(method_label(literal_procs, 'LiteralProcs', name)))
end

if failures.empty?
  puts 'bc2cpp yield reach check: PASS'
else
  warn "bc2cpp yield reach check: #{failures.size} failure(s)"
  exit 1
end
