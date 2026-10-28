#!/usr/bin/env ruby
# frozen_string_literal: true

# CORE_ENUMERATOR_FREE (tools/bc2cpp/core_enumerator_free.rb): the proof that no Enumerator is made in the closed build,
# which releases the methods of mruby-enumerator's Fiber machinery. Each fixture is a small world: a core file at
# mruby-enumerator's path (the released methods), one at array.rb's (the iterators that make an Enumerator), an optional
# native, and the engine's Ruby.
#
#   creators
#     - `return to_enum(:each) unless block_given?`, `unless blk`, and the short circuit `args.size == 1 && !blk` make an
#       Enumerator only without a block (:blockless); `Enumerator.new` after a block test (chunk) and a `zip` that wraps its
#       arguments make one for any call (:always); a method that forwards its block, an alias, and a native `to_enum` call
#       (with the no-argument test the C text states) are creators of their own name;
#     - the methods of Enumerator, Generator and Yielder are not creators: they run on an existing instance;
#   sites and receivers (both directions)
#     - a block (literal, Symbol, or the caller's own where it is given) is no site to prove; an argument to a no-argument
#       native is none either;
#     - a blockless site is proven by the receiver: an engine class that defines the name itself, `new` of one, an ivar, a
#       parameter, an attr_accessor, a self send; and refused for a literal Array, an Enumerable includer, an untyped call
#       result, an element, a parameter some caller gives an Array;
#   other ways in: an engine `to_enum` or Enumerator constant, a Symbol that names a creator and reaches a lookup, a native
#     that spells a creator name, a `method_missing`.
#
# Usage: MRBC=path/to/mrbc ruby scripts/bc2cpp/core_enumerator_free_check.rb

require 'set'
require 'tmpdir'
require 'fileutils'
require_relative 'check_support'
require_relative '../../tools/bc2cpp/static_dispatch_registrations'
require_relative '../../tools/bc2cpp/bc2cpp'

suite = FixtureCheck.new('core_enumerator_free_check')
suite.require_mrbc!
EF = CoreEnumeratorFree

# The released file: Enumerator and friends, Kernel#to_enum, Enumerable#zip/#chunk.
ENUMERATOR_RB = <<~'RUBY'
  class Enumerator
    def initialize(obj, meth = :each, *args, &block)
      @obj = obj
      @meth = meth
    end

    def each(&block)
      @obj.__send__(@meth, &block)
    end

    def with_index(offset = 0, &block)
      return to_enum(:with_index, offset) unless block
      each { |x| block.call(x, offset) }
    end

    class Generator
      def initialize(&block); @b = block; end
      def each(&block); Yielder.new(&block); end
    end

    class Yielder
      def initialize(&block); @b = block; end
      def yield(x); @b.call(x); end
    end
  end

  module Kernel
    def to_enum(meth = :each, *args)
      Enumerator.new self, meth, *args
    end
    alias enum_for to_enum
  end

  module Enumerable
    def zip(*args, &block)
      args = args.map { |a| a.to_enum(:each) }
      args
    end

    def chunk(&block)
      return to_enum(:chunk) unless block
      Enumerator.new { |y| y.yield 1 }
    end
  end
RUBY

# The iterators: every shape of guard, an alias, a forwarder, a block-less-only creator and one that never makes one.
ARRAY_RB = <<~'RUBY'
  module Enumerable
    def each_pair_of(&block)
      return to_enum(:each_pair_of) unless block_given?
      each(&block)
    end

    def keep(&blk)
      return to_enum(:keep) unless blk
      each(&blk)
    end

    def sub_all(*args, &blk)
      return to_enum(:sub_all, *args) if args.size == 1 && !blk
      args
    end

    def collect(&block)
      return to_enum(:collect) unless block
      each(&block)
    end
    alias map collect

    def peek_all
      each { |x| x }
    end
  end

  class Array
    include Enumerable

    def each(&block)
      return to_enum(:each) unless block_given?
      i = 0
      while i < size
        block.call(self[i])
        i += 1
      end
      self
    end

    def reverse_each(&block)
      each(&block)
    end
  end

  module Kernel
    def loop
      return to_enum(:loop) unless block_given?
      yield
    end
  end
RUBY

# array.c's shape: Array#index answers an Enumerator only without an argument and without a block.
INDEX_C = <<~'C'
  static mrb_value
  fx_ary_index(mrb_state *mrb, mrb_value self)
  {
    mrb_value obj, blk;

    if (mrb_get_args(mrb, "|o&", &obj, &blk) == 0 && mrb_nil_p(blk)) {
      return mrb_funcall_id(mrb, self, MRB_SYM(to_enum), 1, mrb_symbol_value(MRB_SYM(index)));
    }
    return mrb_nil_value();
  }

  #define MRB_MT_CLASS Array
  static const mrb_mt_entry array_rom_entries[] = {
    MRB_MT_ENTRY(fx_ary_index, MRB_SYM(index), MRB_ARGS_OPT(1))
  };
  #undef MRB_MT_CLASS

  void
  mrb_init_array(mrb_state *mrb)
  {
    struct RClass *a;

    mrb->array_class = a = mrb_define_class_id(mrb, MRB_SYM(Array), mrb->object_class);
    MRB_MT_INIT_ROM(mrb, a, array_rom_entries);
  }
C

# Compiles a world: +core+ maps a path below the world's root to its source (added to the two fixed core files), +engine+ is
# one source. The block gets the compiled pieces while the files exist.
def with_world(suite, engine:, core: {}, native: nil)
  Dir.mktmpdir('core_enumerator_free_fixture') do |root|
    compile = lambda do |rel, source, label|
      path = File.join(root, rel)
      FileUtils.mkdir_p(File.dirname(path))
      File.write(path, source)
      ireps, top = compile_ireps([path], label, root, mrbc: suite.mrbc)
      { ireps: ireps, tuple: build_registry(ireps, top), path: path }
    end
    core_files = ({ 'mruby-enumerator/mrblib/enumerator.rb' => ENUMERATOR_RB, 'mruby/mrblib/array.rb' => ARRAY_RB }.merge(core))
                 .each_with_index.map { |(rel, source), i| compile.call(rel, source, "core#{i}") }
    native_paths = []
    entries = []
    if native
      path = File.join(root, 'native.c')
      File.write(path, native)
      native_paths << path
      entries.concat(CoreNativeCandidates.entries([path]))
    end
    yield(engine: compile.call('engine/main.rb', engine, 'engine'), core: core_files, native: native_paths, entries: entries)
  end
end

def inputs_of(world, symbol_names = nil)
  sdr = StaticDispatchRegistrations
  lookups = StaticDispatchSymbolUses.lookups(world[:engine][:ireps])
  EF.inputs(engine: world[:engine], core: world[:core], native: world[:native], entries: world[:entries],
            map: NativeOwnerMap.build([]), symbol_lookups: symbol_names || lookups, strip: sdr.method(:strip_c_comments),
            tokens: ->(text, found) { sdr.native_name_tokens(text, found, []) }, entry_name: CoreNativeCandidates::ENTRY_NAME,
            implicit_names: StaticDispatchRegistrations::ALWAYS_DYNAMIC | IMPLICIT_DISPATCH_NAMES.values)
end

# The proof of a world.
def prove(suite, engine:, core: {}, native: nil)
  with_world(suite, engine: engine, core: core, native: native) { |world| EF.prove(inputs_of(world)) }
end

def creators(result)
  result.creators.to_h { |c| ["#{c.owner}##{c.name}", c.mode] }
end

def unproven_for(result, name)
  result.unproven.select { |u| u.name == name }
end

# --- creators ---------------------------------------------------------------------------------------------------------
base = prove(suite, engine: "class Quiet\nend\n", native: INDEX_C)
found = creators(base)
suite.check("a bare `unless block_given?` guard makes a blockless creator (#{found['Enumerable#each_pair_of']})",
            found['Enumerable#each_pair_of'] == :blockless && found['Array#each'] == :blockless && found['Kernel#loop'] == :blockless)
suite.check('`unless blk` on the block parameter does too', found['Enumerable#keep'] == :blockless)
suite.check('so does a short circuit `args.size == 1 && !blk` (the jump on the second test has one feasible edge)',
            found['Enumerable#sub_all'] == :blockless)
suite.check('an alias copies the creator (`alias map collect`)', found['Enumerable#map'] == :blockless)
suite.check('a method that passes its own block on makes an Enumerator without one', found['Array#reverse_each'] == :blockless)
suite.check('Enumerator.new after the block test (chunk) and a zip that wraps its arguments make one for any call',
            found['Enumerable#chunk'] == :always && found['Enumerable#zip'] == :always && found['Kernel#to_enum'] == :always)
suite.check('the methods of Enumerator, Generator and Yielder are not creators (they need an instance)',
            found.none? { |k, _| k.start_with?('Enumerator#', 'Enumerator::Generator#', 'Enumerator::Yielder#') })
suite.check('a native to_enum call is a creator of its name, without an argument (array.c)',
            base.creators.any? { |c| c.owner == 'Array' && c.name == 'index' && c.noarg })
suite.check('an iterator that makes none (peek_all) is no creator', !found.key?('Enumerable#peek_all'))

# --- the engine holds ---------------------------------------------------------------------------------------------------
engine_ok = <<~'RUBY'
  class Route
    attr_accessor :index

    def initialize
      @index = 0
    end

    def each
      @index
    end

    def step(count)
      @index += count
    end
  end

  class Holder
    def initialize(route)
      @route = route
    end

    def current
      @route.index
    end

    def walk
      @route.each
    end
  end

  class Game
    def initialize
      @route = Route.new
      @holder = Holder.new(@route)
    end

    def run
      @route.index
      @holder.walk
      [1, 2, 3].each { |x| x }
      [4].map { |x| x + 1 }
      [5].reverse_each { |x| x }
      [6, 7].index(6)
      loop { break }
      route = Route.new
      go(route)
    end

    def go(r)
      r.each
      r.index
    end

    def captured
      held = Route.new
      [1].each { held.index }
      held.each
    end

    def rescued
      yield
    rescue StandardError => e
      e.each
    end

    def counted(n)
      total = n + 1
      total.index
    end
  end

  class Cell < Route
    def each
      super
    end
  end
RUBY
ok = prove(suite, engine: engine_ok, native: INDEX_C)
suite.check("blocks, an argument to Array#index, and receivers that are engine classes defining the name hold (#{ok.unproven.map(&:why).first(2).inspect})",
            ok.holds)
suite.check('the receiver-proven sites are counted', ok.proven[:receiver].to_i >= 4 && ok.proven[:given].to_i >= 4)

# --- the engine does not hold -------------------------------------------------------------------------------------------
cases = {
  'a literal Array receiver' => ["class A\n  def run\n    [1].each\n  end\nend\n", 'each'],
  'an Array in a parameter' => ["class A\n  def run\n    take([1])\n  end\n\n  def take(x)\n    x.each\n  end\nend\n", 'each'],
  'an untyped call result' => ["class A\n  def run(box)\n    box.items.map\n  end\nend\n", 'map'],
  'an element read' => ["class A\n  def run(list)\n    list[0].each\n  end\nend\n", 'each'],
  'an Enumerable includer' => ["class Bag\n  include Enumerable\n  def each\n    yield 1\n  end\nend\n\nclass A\n  def run\n    Bag.new.map\n  end\nend\n", 'map'],
  'a blockless Array#index' => ["class A\n  def run\n    [1].index\n  end\nend\n", 'index'],
  'a zip, with or without a block' => ["class A\n  def run(a)\n    a.zip([1]) { |p| p }\n  end\nend\n", 'zip'],
  'a blockless loop' => ["class A\n  def run\n    loop\n  end\nend\n", 'loop'],
  'a subclass of Array' => ["class Stack < Array\nend\n\nclass A\n  def run\n    Stack.new.each\n  end\nend\n", 'each'],
  'a parameter that gets an Array from one caller' => ["class Route\n  def each\n    1\n  end\nend\n\nclass A\n  def run\n    take(Route.new)\n    take([1])\n  end\n\n  def take(x)\n    x.each\n  end\nend\n", 'each'],
  'an ivar that holds an Array in another method' => ["class A\n  def initialize\n    @items = Object.new\n  end\n\n  def run\n    @items = [1]\n    @items.each\n  end\nend\n", 'each'],
  'a block that is nil' => ["class A\n  def run(a)\n    a.each(&nil)\n  end\nend\n", 'each']
}
# A method nobody calls has no argument at all; the driver hands every `run` something the model cannot type.
DRIVER = "\nA.new.run($stdin)\n"
cases.each do |label, (source, name)|
  result = prove(suite, engine: source + DRIVER, native: INDEX_C)
  suite.check("#{label} is unproven (#{unproven_for(result, name).map(&:why).first.to_s[0, 60]})",
              !result.holds && unproven_for(result, name).any? { |u| u.line.to_i.positive? })
end

forwarder = <<~'RUBY'
  class Wrapper
    def initialize(items)
      @items = items
    end

    def each(&block)
      @items.each(&block)
    end
  end

  class A
    def run
      Wrapper.new([1]).each
    end
  end
RUBY
result = prove(suite, engine: forwarder + DRIVER, native: INDEX_C)
suite.check('an engine method that forwards a nil block is a creator, and its blockless caller is unproven',
            creators(result)['Wrapper#each'] == :blockless && !result.holds && unproven_for(result, 'each').any?)
result = prove(suite, engine: forwarder.sub('Wrapper.new([1]).each', 'Wrapper.new([1]).each { |x| x }') + DRIVER, native: INDEX_C)
suite.check('the same caller with a block holds', result.holds)

direct = prove(suite, engine: "class A\n  def run(x)\n    x.to_enum(:each) { |y| y }\n    Enumerator.new { |y| y }\n  end\nend\n")
suite.check('an engine to_enum or Enumerator constant is a way in',
            !direct.holds && direct.unproven.any? { |u| u.why == 'an engine method calls to_enum' && u.where == 'A#run' && u.line.to_i.positive? })

symbol = prove(suite, engine: "class A\n  def run(list)\n    list.map(&:each)\n  end\nend\n")
suite.check('a Symbol naming a creator that reaches a lookup is unproven (map(&:each) calls each with no block)',
            !symbol.holds && symbol.unproven.any? { |u| u.why.include?('Symbol :each') })
suite.check('a lookup that takes a computed name refuses the proof',
            !prove(suite, engine: "class A\n  def run(o, n)\n    o.send(n)\n  end\nend\n").holds)

missing = prove(suite, engine: "class A\n  def method_missing(n, *a)\n    nil\n  end\nend\n")
suite.check('a method_missing refuses the proof', !missing.holds && missing.unproven.any? { |u| u.name == 'method_missing' })

native_spells = prove(suite, engine: "class Quiet\nend\n", native: INDEX_C + "static const char *probe = \"each\";\n")
suite.check('native text that spells a creator name refuses the proof',
            !native_spells.holds && native_spells.unproven.any? { |u| u.why.include?('native text spells the creator name each') })
suite.check('the native creator\'s own to_enum call is not a spelling', base.holds)

# --- the hook into the closed-list proof ---------------------------------------------------------------------------------
reasons = {
  'Enumerator#each' => "#{CoreMethods::ENUMERATOR_REASON} (Fiber machinery)",
  'Kernel#to_enum' => "#{CoreMethods::ENUMERATOR_REASON} (Fiber machinery)",
  'Enumerable#zip' => "#{CoreMethods::ENUMERATOR_REASON} (Fiber machinery)",
  'Enumerator::Yielder#<<' => "#{CoreMethods::ENUMERATOR_REASON} (Fiber machinery)",
  'Hash#to_proc' => 'builds a lambda'
}
sdr = StaticDispatchRegistrations
released = ->(engine) do
  with_world(suite, engine: engine, native: INDEX_C) do |w|
    sdr.enumerator_free_keys(reasons, w[:core], w[:engine][:ireps], w[:native], w[:entries], NativeOwnerMap.build([]), w[:engine][:tuple],
                             StaticDispatchSymbolUses.lookups(w[:engine][:ireps]))
  end
end
suite.check("a holding proof lists the identifier-named methods of the group, and the alias of to_enum (#{released.call(engine_ok).sort.join(', ')})",
            released.call(engine_ok).sort == %w[Enumerable#zip Enumerator#each Kernel#enum_for Kernel#to_enum])
suite.check('a failing one lists none, and keeps the result for the report',
            released.call(cases.fetch('a literal Array receiver').first + DRIVER).empty? && !sdr.enumerator_free.holds)

suite.finish!
