#!/usr/bin/env ruby
# encoding: UTF-8
# frozen_string_literal: true

# ENUMERATOR_MODEL (docs/adr/0418):
#
# 1. The proofs, without generating code (needs MRBC): EnumeratorModel.analyze admits Kernel#to_enum only when it is the
#    program's one to_enum, enum_for is only its alias, the body is exactly `Enumerator.new self, meth, *args, **kwd` and
#    nothing replaces the construction chain; the `Enumerator` constant is stable unless a nested statement, an
#    assignment or a dynamic constant mutation could rebind it. ClassLayout takes `@q = @q.reject { }` as an Array store
#    once every other store of @q is an Array (CHAINED_IVAR_RECEIVER), and not otherwise.
# 2. Generated code (needs MRBC): a `to_enum` / `enum_for` on a proven exact Array, Hash, Range or String in a compiled
#    core body is a checked TO_ENUM_DIRECT site (class test, guard violation else), a module owner or a program that
#    replaces any link of the chain keeps the by-name send, and BC2CPP_ENUMERATOR_MODEL=0 restores it.
# 3. Behaviour on a real mruby (needs MRBC and a full-core build, g++): the compiled core's blockless iterators answer what
#    the interpreter answers (next/peek/rewind/size/inspect, with_index, with_object, each_slice/each_cons, lazy, a
#    user-defined each, a redefined map, Hash and Range sources, break/next/exceptions, GC), and the direct sites make no
#    dispatch.
#
# Usage: [MRBC=path/to/mrbc BC2CPP_MRUBY_FULL=dir] ruby scripts/bc2cpp/enumerator_model_check.rb
# EM_PHASE=behavior runs part 3 only, EM_PHASE=generated parts 1 and 2, EM_PHASE=unit runs part 1 only, EM_PHASE=positive parts 1 and the first generation of part 2 (the mutation check's
# phases); unset runs everything.

require 'fileutils'
require 'tmpdir'
require_relative 'fixture_runtime'
require ENV.fetch('BC2CPP_TOOL') { File.expand_path('../../tools/bc2cpp/bc2cpp.rb', __dir__) }

PHASE = ENV.fetch('EM_PHASE', 'all')
failures = []
check = lambda do |what, condition|
  puts "  #{condition ? 'ok  ' : 'FAIL'} #{what}"
  failures << what unless condition
end
runtime = Bc2cppFixtureRuntime
ROOT = Bc2cppFixtureRuntime::ROOT
ENUMERATOR_RB = File.join(ROOT, '3rd/mruby/mrbgems/mruby-enumerator/mrblib/enumerator.rb')
SUFFIX = 'mruby-enumerator/mrblib/enumerator.rb'

# -- 1. the proofs ------------------------------------------------------------------------------

if ENV['MRBC'] && PHASE != 'behavior'
  puts '== EnumeratorModel.analyze'
  real = File.read(ENUMERATOR_RB)
  model_for = lambda do |enumerator_text: real, extra: nil, enumerator_path: SUFFIX|
    Dir.mktmpdir('em-model') do |dir|
      path = File.join(dir, enumerator_path)
      FileUtils.mkdir_p(File.dirname(path))
      File.write(path, enumerator_text)
      sources = [path]
      if extra
        other = File.join(dir, 'project.rb')
        File.write(other, extra)
        sources << other
      end
      ireps, label = compile_ireps(sources, 'em_model', dir)
      registry, _s, _c, _i, _p, _u, _m, _d, _w, _b, _a, _dm, alias_sites = build_registry(ireps, label)
      EnumeratorModel.analyze(registry, ireps, alias_sites)
    end
  end
  stable = lambda do |extra: nil, foreign: ''|
    Dir.mktmpdir('em-const') do |dir|
      sources = []
      sources << File.join(dir, 'main.rb').tap { |f| File.write(f, "#{real}\n#{extra}") }
      ireps, root = compile_ireps(sources, 'em_const', dir)
      native = File.join(dir, 'native.cxx').tap { |f| File.write(f, '// none') }
      outside = File.join(dir, 'outside.rb').tap { |f| File.write(f, foreign) }
      EnumeratorModel.constant_unstable_reason(ireps, root, [native], [outside])
    end
  end

  m = model_for.call
  check.call('the genuine mruby-enumerator source admits to_enum', m.to_enum_direct == true)
  check.call('NEG: a project Array#to_enum', model_for.call(extra: "class Array\n def to_enum(*a); :mine; end\nend\n").to_enum_direct == false)
  check.call('NEG: a project Object#to_enum', model_for.call(extra: "class Object\n def to_enum(*a); :mine; end\nend\n").to_enum_direct == false)
  check.call('NEG: a project enum_for method', model_for.call(extra: "class Foo\n def enum_for(*a); :mine; end\nend\n").to_enum_direct == false)
  check.call('NEG: another alias of to_enum', model_for.call(extra: "class Foo\n alias_method :ten, :to_enum\nend\nclass Bar\n alias ten2 to_enum\nend\n").to_enum_direct == false)
  check.call('NEG: a second Enumerator#initialize', model_for.call(extra: "class Enumerator\n def initialize(*a); end\nend\n").to_enum_direct == false)
  check.call('NEG: a project Class#new', model_for.call(extra: "class Class\n def new(*a); :mine; end\nend\n").to_enum_direct == false)
  check.call('NEG: a project Enumerator.new', model_for.call(extra: "class Enumerator\n def self.new(*a); :mine; end\nend\n").to_enum_direct == false)
  check.call('NEG: a project Object#initialize', model_for.call(extra: "class Object\n def initialize(*a); end\nend\n").to_enum_direct == false)
  check.call('an unrelated class with its own new/initialize leaves the model alone',
             model_for.call(extra: "class Foo\n def initialize; end\n def new; end\n def allocate; end\nend\n").to_enum_direct == true)
  check.call('NEG: Kernel#to_enum with another body',
             model_for.call(enumerator_text: real.sub('Enumerator.new self, meth, *args, **kwd', 'Enumerator.new(self, meth, *args, **kwd).itself')).to_enum_direct == false)
  check.call('NEG: Kernel#to_enum with a block',
             model_for.call(enumerator_text: real.sub('Enumerator.new self, meth, *args, **kwd', '[1].each { }; Enumerator.new self, meth, *args, **kwd')).to_enum_direct == false)
  check.call('NEG: Kernel#to_enum building another class',
             model_for.call(enumerator_text: real.sub('Enumerator.new self, meth, *args, **kwd', 'Array.new self, meth, *args, **kwd')).to_enum_direct == false)
  # Worlds only one gate refuses (the alias and body checks pass): the definition is on another owner / in another file
  # while the Kernel alias stays in mruby-enumerator's source.
  def_text = real[/^  def to_enum\(meth=:each.*?^  end\n/m]
  without_def = real.sub(def_text) { '' }
  check.call('NEG: to_enum defined on another owner, while the Kernel alias stays in mruby-enumerator (owner gate alone)',
             model_for.call(enumerator_text: "#{without_def}\nclass Foo\n#{def_text}end\n").to_enum_direct == false)
  check.call('NEG: Kernel#to_enum defined outside mruby-enumerator, alias inside it (source gate alone)',
             model_for.call(enumerator_text: without_def, extra: "module Kernel\n#{def_text}end\n").to_enum_direct == false)
  check.call('NEG: a to_enum that is not from mruby-enumerator', model_for.call(enumerator_path: 'other/enumerator.rb').to_enum_direct == false)
  check.call('NEG: BC2CPP_ENUMERATOR_MODEL=0', begin
    saved = ENV.fetch('BC2CPP_ENUMERATOR_MODEL', nil)
    ENV['BC2CPP_ENUMERATOR_MODEL'] = '0'
    model_for.call.to_enum_direct == false
  ensure
    saved ? ENV['BC2CPP_ENUMERATOR_MODEL'] = saved : ENV.delete('BC2CPP_ENUMERATOR_MODEL')
  end)

  puts '== the Enumerator constant'
  check.call('mruby reopening class Enumerator at the top level is stable', stable.call(extra: "class Enumerator\n def zz; end\nend\n").nil?)
  check.call('NEG: Enumerator = 1', !stable.call(extra: "Enumerator = 1\n").nil?)
  check.call('NEG: module Kernel; class Enumerator', !stable.call(extra: "module Kernel\n class Enumerator; end\nend\n").nil?)
  check.call('NEG: a class Enumerator nested in a namespace', !stable.call(extra: "module Ns\n class Enumerator; end\nend\n").nil?)
  check.call('NEG: Object.const_set in the program', !stable.call(extra: "Object.const_set(:Foo, 1)\n").nil?)
  check.call('NEG: remove_const in outside Ruby', !stable.call(foreign: "Object.send(:remove_const, :Enumerator)\n").nil?)
  check.call('NEG: a reassignment in outside Ruby', !stable.call(foreign: "Enumerator = nil\n").nil?)

  puts '== ClassLayout: @q = @q.reject { }'
  chain_source = <<~'RUBY'
    class Q
      def initialize
        @queue = []
        @other = []
        @mixed = []
        @unknown = []
        @hashy = {}
      end
      def solo(x); @solo = x.reject { |b| b }; end
      def refill
        @queue = turn_order
        @queue = @queue.reject { |b| b } if @first
        @other = @other.select { |b| b }
        @mixed = @mixed.reject { |b| b }
        @unknown = @unknown.reject { |b| b }
        @hashy = @hashy.reject { |k, v| v }
      end
      def breaks; @mixed = foo; end
      def adopt(x); @unknown = x; end
      def turn_order
        rolled = [1, 2].map { |b| [b, b] }
        rolled.each_with_index.sort_by { |(b, r), i| [-r, i] }.map { |(b, _r), _i| b }
      end
    end
  RUBY
  Dir.mktmpdir do |dir|
    source = File.join(dir, 'chain.rb')
    File.write(source, chain_source)
    ireps, root = compile_ireps(source, 'em_chain', dir)
    registry, = build_registry(ireps, root)
    layout = ClassLayout.analyze(ireps, registry, {}, {}, ->(name) { name == 'turn_order' })
    check.call('@queue: every other store is an Array, so the reject store is one', layout.dig('Q', 'queue') == 'Array')
    check.call('@other: a lone select-on-itself with an Array initial value', layout.dig('Q', 'other') == 'Array')
    check.call('NEG: a store of an unknown value poisons the chain', layout.dig('Q', 'mixed') == ClassLayout::UNKNOWN)
    check.call('NEG: an argument store poisons the chain', layout.dig('Q', 'unknown') == ClassLayout::UNKNOWN)
    check.call('NEG: reject on a Hash ivar is not an Array', layout.dig('Q', 'hashy') != 'Array')
    check.call('NEG: reject on an unknown receiver is no Array evidence', layout.dig('Q', 'solo') == ClassLayout::UNKNOWN)
  end
else
  puts '-- SKIP proofs: set MRBC'
end

# -- 2. generated code -----------------------------------------------------------------------------

CORE_PATH = '3rd/mruby/mrblib/em_core.rb'
CORE_FIXTURE = <<~'RUBY'
  class Array
    def em_each; to_enum(:each); end
    def em_args(n); to_enum(:each_slice, n); end
    def em_enum_for; enum_for; end
    def em_block; return to_enum(:em_block) unless block_given?; 1; end
    def em_param(o); o.to_enum(:each); end
    def em_in_block; [1].each { |_x| return to_enum(:each) }; end
  end
  class Hash
    def em_h; to_enum(:each); end
  end
  class Range
    def em_r; enum_for(:each); end
  end
  class String
    def em_s; to_enum(:each_char); end
  end
  module Enumerable
    def em_mod; to_enum(:each); end
  end
RUBY
ENGINE_FIXTURE = <<~'RUBY'
  class EmEngine
    def one; 1; end
  end
RUBY
PROVEN = { 'Array#em_each' => 'Array', 'Array#em_args' => 'Array', 'Array#em_enum_for' => 'Array', 'Array#em_block' => 'Array',
           'Hash#em_h' => 'Hash', 'Range#em_r' => 'Range', 'String#em_s' => 'String' }.freeze
chunk = lambda do |code, owner_method|
  code[/^\/\/ #{Regexp.escape(owner_method)} \(compiled from.*?(?=^\/\/ \S+#\S+ \(compiled from|\z)/m].to_s
end
generate = lambda do |dir, engine: ENGINE_FIXTURE, core: CORE_FIXTURE, env: {}|
  saved = env.to_h { |k, _| [k, ENV.fetch(k, nil)] }
  env.each { |k, v| ENV[k] = v }
  begin
    runtime.generate(core, dir, closed: true, only_owners: %w[EmEngine], path: CORE_PATH, core: true,
                                extra: [['em_engine.rb', engine]])
  ensure
    saved.each { |k, v| v ? ENV[k] = v : ENV.delete(k) }
  end
end
# EM_GEN=name,name limits part 2 to the named worlds (the mutation check asks for the one a mutant can change).
gen = ->(name) { ENV['EM_GEN'].nil? || ENV['EM_GEN'].split(',').include?(name) }
direct = ->(text) { text.include?('// TO_ENUM_DIRECT :') && text.include?('bc2cpp_to_enum(') && !text.include?('bc2cpp_send(') }

if ENV['MRBC'] && !%w[unit behavior].include?(PHASE)
  puts '== generated code'
  Dir.mktmpdir do |dir|
    next unless gen.call('positive')

    code, err = generate.call(dir)
    check.call('the model is proven and the constant stable', err.include?('to_enum direct proven') && err.include?('Enumerator constant stable'))
    PROVEN.each do |method, klass|
      text = chunk.call(code, method)
      test = { 'Array' => 'mrb_array_p(self) && mrb_obj_ptr(self)->c == M->array_class', 'Hash' => 'mrb_hash_p(self) && mrb_obj_ptr(self)->c == M->hash_class',
               'Range' => 'mrb_range_p(self) && mrb_obj_ptr(self)->c == M->range_class', 'String' => 'mrb_string_p(self) && mrb_obj_ptr(self)->c == M->string_class' }[klass]
      check.call("#{method}: a checked TO_ENUM_DIRECT site, class test then guard violation, no by-name send",
                 direct.call(text) && text.include?("if (#{test}) {") && text.include?("\"#{method} (CORE_BODY_EXACT)\"") &&
                   text.include?("CORE_BODY_EXACT_CHECKED :#{text[/:(to_enum|enum_for) -> /, 1]} -> #{klass}"))
    end
    check.call('no-argument to_enum passes :each', chunk.call(code, 'Array#em_enum_for').include?('bc2cpp_te_argv[] = { self, mrb_symbol_value'))
    check.call('arguments follow the method name in order', chunk.call(code, 'Array#em_args').match?(/bc2cpp_te_argv\[\] = \{ self, r\d+, r\d+ \}/))
    check.call('NEG: a parameter receiver is no proof', chunk.call(code, 'Array#em_param').include?('bc2cpp_send(') &&
                                                         !chunk.call(code, 'Array#em_param').include?('TO_ENUM_DIRECT'))
    check.call('NEG: a block body is no proof (it may run with another self)', !chunk.call(code, 'Array#em_in_block').include?('TO_ENUM_DIRECT'))
    check.call('NEG: a module owner (Enumerable, any includer) keeps the by-name send',
               chunk.call(code, 'Enumerable#em_mod').include?('bc2cpp_send(') && !chunk.call(code, 'Enumerable#em_mod').include?('TO_ENUM_DIRECT'))
    check.call('the helper is emitted once and builds the class the body names',
               code.scan('static inline mrb_value bc2cpp_to_enum(').size == 1 && code.include?('mrb_obj_new(M, mrb_class_get(M, "Enumerator"), argc, argv)'))
    check.call('the violation sites are listed with the other CORE_BODY_EXACT sites', err.include?('GUARD_VIOLATION_SITE Array#em_each -> to_enum'))
    real_sites = code.scan(/^\/\/ TO_ENUM_DIRECT :/).size
    check.call("the real core bodies take the arm (#{real_sites} sites)", real_sites > PROVEN.size)
    every = code.scan(/^\/\/ (\S+#\S+) \(compiled from[^\n]*\n(.*?)(?=^\/\/ \S+#\S+ \(compiled from|\z)/m)
    check.call('no unchecked TO_ENUM_DIRECT site', every.none? { |_n, text| text.include?('// TO_ENUM_DIRECT :') && !text.include?('CORE_BODY_EXACT_CHECKED') })
  end

  if PHASE == 'positive'
    puts 'EM_PHASE=positive: negative worlds skipped'
  else
  Dir.mktmpdir do |dir|
    next unless gen.call('killswitch')

    code, err = generate.call(dir, env: { 'BC2CPP_ENUMERATOR_MODEL' => '0' })
    check.call('BC2CPP_ENUMERATOR_MODEL=0: every site is a by-name send again',
               !code.include?('TO_ENUM_DIRECT') && !code.include?('bc2cpp_to_enum(') && PROVEN.keys.all? { |m| chunk.call(code, m).include?('bc2cpp_send(') } &&
                 err.include?('to_enum direct refused'))
  end

  {
    'redef' => ['a project Enumerator#initialize (the model refuses, the lookup of to_enum is unchanged)', "class Enumerator\n def initialize(*a, **k); end\nend\n"],
    'nested' => ['a nested class Enumerator', "module Kernel\n class Enumerator; end\nend\n"]
  }.each do |key, (name, extra)|
    Dir.mktmpdir do |dir|
      next unless gen.call(key)

      code, = generate.call(dir, engine: ENGINE_FIXTURE + extra)
      check.call("NEG: #{name} withdraws the direct build",
                 !code.include?('TO_ENUM_DIRECT'))
    end
  end

  Dir.mktmpdir do |dir|
    next unless gen.call('installer')

    code, = generate.call(dir, engine: ENGINE_FIXTURE.sub(/^end\n\z/, "  def installer(k); k.send(:define_method, :to_enum) { 1 }; end\nend\n"))
    check.call('NEG: a runtime installer naming to_enum withdraws the direct build (RUNTIME_DEF_DEVIRT_GUARD)', !code.include?('TO_ENUM_DIRECT'))
  end

  Dir.mktmpdir do |dir|
    next unless gen.call('subclass')

    code, = generate.call(dir, engine: "#{ENGINE_FIXTURE}class EmSubArray < Array; end\n")
    check.call('NEG: an Array subclass in the program withdraws the Array sites (ADR 0381) and leaves Hash proven',
               !chunk.call(code, 'Array#em_each').include?('TO_ENUM_DIRECT') && chunk.call(code, 'Hash#em_h').include?('TO_ENUM_DIRECT'))
  end
  end
else
  puts '-- SKIP generated code: set MRBC (and not EM_PHASE=unit)'
end

# -- 3. behaviour ---------------------------------------------------------------------------------

BEHAVIOUR = <<~'RUBY'
  class EmColl
    include Enumerable
    def initialize(*v); @v = v; end
    def each
      return to_enum(:each) unless block_given?
      @v.each { |x| yield x }
      self
    end
  end
  class EmMapper
    include Enumerable
    def each; yield 1; yield 2; end
    def map; :user_map; end
  end
  class EmFixture
    def array_enum
      a = [10, 20, 30]
      e = a.each_index
      [e.class, e.next, e.next, e.peek, e.next, (begin; e.next; rescue StopIteration => x; x.class; end), e.rewind.equal?(e), e.next, e.to_a, e.size, e.inspect]
    end
    def array_blockless
      a = [3, 1, 2]
      [a.each.to_a, a.map.with_index(1) { |x, i| [x, i] }, a.select.with_index { |x, i| i > 0 }, a.reject.with_index { |x, i| i > 0 },
       a.each_with_index.map { |x, i| x * i }, a.each_with_index.to_a, a.each_with_index.sort_by { |x, i| -i },
       a.sort_by.with_index { |x, i| -i }, a.reverse_each.to_a, a.collect.with_index { |x, i| x + i },
       a.each_slice(2).to_a, a.each_cons(2).to_a, a.each_with_object([]).to_a.size, a.each_with_object([]) { |x, m| m << x * 2 },
       a.find.class, a.delete_if.class, a.keep_if.class, a.map!.class, a.select!.class, a.reject!.class, a.bsearch.class]
    end
    def hash_enum
      h = { a: 1, b: 2 }
      e = h.each
      [e.class, e.next, e.to_a, h.select.class, h.reject.with_index { |(k, v), i| i == 0 }, h.each_key.to_a, h.each_value.to_a,
       h.transform_values.with_index { |v, i| v + i }, h.delete_if.class, h.each_with_index.map { |(k, v), i| [k, v, i] }]
    end
    def range_enum
      r = (1..4)
      [r.each.class, r.each.next, r.each.to_a, r.each_slice(3).to_a, r.each_with_index.to_a, r.each_cons(3).to_a]
    end
    def string_enum
      ["abc".each_char.to_a, "ab\ncd".each_line.to_a, "a".upto("c").to_a, "a".upto("c").size, "abc".each_char.with_index.to_a]
    end
    def explicit
      a = [1, 2, 3]
      [a.to_enum.to_a, a.enum_for.next, a.to_enum(:each_slice, 2).to_a, a.enum_for(:each_with_index).to_a, a.to_enum(:map).with_index(1).to_a,
       a.to_enum(:each_slice, 2).size, {}.to_enum.to_a, (1..2).to_enum(:each).to_a, "ab".to_enum(:each_char).to_a]
    end
    def lazy
      a = [1, 2, 3, 4]
      [a.lazy.map { |x| x * 2 }.select { |x| x > 2 }.first(2), a.each_slice(2).lazy.map(&:sum).to_a, a.lazy.to_a, (1..Float::INFINITY).lazy.map { |x| x * 2 }.first(3)]
    end
    def user_each
      c = EmColl.new(1, 2, 3)
      [c.each.next, c.each.to_a, c.each_slice(2).to_a, c.each_cons(2).to_a, c.each_with_index.to_a, c.map.with_index(1).to_a,
       c.each_with_object([]) { |x, m| m << x }, c.to_enum.next, c.each_entry.to_a, c.sort_by.with_index { |x, i| -i }, c.each.size]
    end
    def redefined_map
      m = EmMapper.new
      [m.map, m.each_with_index.map { |x, i| x + i }, m.each_slice(1).map { |x| x }, m.to_enum.map { |x| x }]
    end
    def control_flow
      a = [1, 2, 3, 4]
      out = []
      out << a.each_with_index.map { |x, i| break :broke if i == 2; x }
      out << a.each_with_index.map { |x, i| next 0 if i == 1; x }
      out << a.map.with_index { |x, i| next x * 10 if i.even?; x }
      out << a.each_slice(2).map { |x, y| break [x, y] }
      out << (begin; a.each_with_index.map { |x, i| raise ArgumentError, "boom#{i}" if i == 1; x }; rescue ArgumentError => e; e.message; end)
      out << (begin; a.each_slice(0); rescue ArgumentError => e; e.class; end)
      out << (begin; a.each_cons(0); rescue ArgumentError => e; e.class; end)
      out << (begin; a.each.next.nope; rescue NoMethodError => e; e.class; end)
      out
    end
    def external_in_fiber
      a = [1, 2, 3]
      f = Fiber.new do
        e = a.each
        Fiber.yield e.next
        Fiber.yield e.next
        e.next
      end
      [f.resume, f.resume, f.resume, f.alive?]
    end
    def mutation_during
      a = [1, 2, 3]
      seen = []
      a.each_with_index.map { |x, i| a << 9 if i == 0 && a.size < 4; seen << x }
      [seen, a]
    end
    def gc
      total = 0
      200.times do |i|
        e = [i, i + 1].each
        e.peek
        GC.start if i % 20 == 0
        total += e.next + [i].each_index.to_a.size
      end
      total
    end
  end
RUBY
METHODS = %w[array_enum array_blockless hash_enum range_enum string_enum explicit lazy user_each redefined_map control_flow
             external_in_fiber mutation_during gc].freeze

if ENV['MRBC'] && %w[all behavior].include?(PHASE)
  build = runtime.full_or_build
  if build && runtime.compiler?
    puts '== fixture on real mruby, interpreted and compiled'
    Dir.mktmpdir do |dir|
      _code, err = runtime.generate(BEHAVIOUR, dir, closed: true, core: true, only_owners: %w[EmColl EmMapper EmFixture])
      harness = <<~CPP
        static int scenario(mrb_state* M) {
          if (compiled) bc2cpp_register_owner_methods(M);
          mrb_value fixture = mrb_obj_new(M, mrb_class_get(M, "EmFixture"), 0, nullptr);
          for (const char* name : {#{METHODS.map { |n| n.dump }.join(', ')}}) call(M, name, fixture, name);
          // The compiled core's own blockless iterators, called straight from C++: the direct sites make no dispatch.
          mrb_value ary = mrb_ary_new(M);
          mrb_ary_push(M, ary, mrb_fixnum_value(1));
          mrb_ary_push(M, ary, mrb_fixnum_value(2));
          mrb_value hash = mrb_hash_new(M);
          mrb_hash_set(M, hash, mrb_symbol_value(mrb_intern_lit(M, "a")), mrb_fixnum_value(1));
          mrb_value range = mrb_range_new(M, mrb_fixnum_value(1), mrb_fixnum_value(3), FALSE);
          mrb_value str = mrb_str_new_cstr(M, "ab");
          call(M, "direct each_index", ary, "each_index");
          call(M, "direct reverse_each", ary, "reverse_each");
          call(M, "direct delete_if", ary, "delete_if");
          call(M, "direct hash each", hash, "each");
          call(M, "direct hash select", hash, "select");
          call(M, "direct range each", range, "each");
          call(M, "direct each_char", str, "each_char");
          return 0;
        }
      CPP
      built, output = runtime.run(dir, err, [], harness, build: build, full: true)
      check.call('the fixture compiles and runs against real mruby', built)
      if built
        sections = runtime.sections(output)
        interpreted = sections.fetch('interpreted', []).reject { |l| l.start_with?('  dispatches') }
        compiled = sections.fetch('compiled', [])
        compiled_values = compiled.reject { |l| l.start_with?('  dispatches') }
        puts output if interpreted != compiled_values || ENV['BC2CPP_CHECK_VERBOSE']
        check.call('every blockless iterator answers what the interpreter answers (including raising the same classes)',
                   !interpreted.empty? && interpreted == compiled_values)
        METHODS.each do |name|
          line = interpreted.find { |l| l.start_with?("#{name} =>") }
          check.call("  #{name} answers a value, not an exception", line && !line.include?('raised'))
        end
        check.call('  Enumerator#next / peek / rewind / size work on an array enumerator',
                   interpreted.any? { |l| l.start_with?('array_enum =>') && l.include?('Enumerator, 0, 1, 2, 2, StopIteration, true, 0, [0, 1, 2], 3') })
        check.call('  a redefined map is still called', interpreted.any? { |l| l.start_with?('redefined_map =>') && l.include?(':user_map') })
        check.call('  break leaves the chain with its value', interpreted.any? { |l| l.start_with?('control_flow =>') && l.include?(':broke') })
        direct_lines = compiled.each_cons(2).select { |a, _b| a.start_with?('direct ') }
        puts direct_lines.map { |a, b| "#{a} #{b}" } if direct_lines.any? { |_, b| b != '  dispatches=0' }
        puts interpreted.grep(/^array_enum/) unless interpreted.any? { |l| l.start_with?('array_enum =>') && l.include?('Enumerator, 0, 1, 2, 2, StopIteration, true, 0, [0, 1, 2], 3') }
        check.call('the direct core iterators answer', direct_lines.size == 7 && direct_lines.none? { |a, _| a.include?('raised') })
        check.call('and make no dispatch at all (the to_enum lookup is gone)', direct_lines.all? { |_, b| b == '  dispatches=0' })
        %w[each_index reverse_each delete_if].each do |what|
          check.call("  direct #{what} builds an Enumerator", direct_lines.any? { |a, _| a.start_with?("direct #{what} =>") && a.include?('#<Enumerator: ') })
        end
      else
        warn output
      end
    end
  else
    puts '-- SKIP behaviour: no full-core build or g++ (set BC2CPP_MRUBY_FULL)'
  end
end

abort "FAILED: #{failures.join(', ')}" unless failures.empty?
puts 'bc2cpp Enumerator model check: PASS'
