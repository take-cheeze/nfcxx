#!/usr/bin/env ruby
# frozen_string_literal: true

# EXACT_DECLARED_RETURN: a runtime-checked declared return (DECLARED_RETURN_GUARD) raises on a violation, so a call of
# a method declared `-> Foo` (a program class nothing derives from) yields exactly a Foo in the exact-class flow, and a
# send on the result resolves to Foo's one method-table entry instead of a class-test chain over every class that
# answers the name. `-> Float` is the FLT bit, `-> Integer` the INT bit. Where the guard is not emitted (the plain
# declaration with BC2CPP_DECLARATION_GUARD=0), the class is subclassed, or a definition is not declared alike, the
# declaration stays the ceiling it was. BC2CPP_EXACT_DECLARED_RETURNS=0 is the output before it.
# Generated end to end by bc2cpp.rb (no mruby build needed).
#
#   MRBC=path/to/mrbc ruby scripts/bc2cpp/exact_declared_return_check.rb
require 'tmpdir'
require_relative 'check_support'
require_relative 'fixture_runtime'
require_relative '../../tools/bc2cpp/codegen'
require_relative '../../tools/bc2cpp/codegen_send'
require_relative '../../tools/bc2cpp/codegen_declared_returns'
require_relative '../../tools/bc2cpp/codegen_return_classes'

suite = FixtureCheck.new('exact_declared_return_check')
check = suite.method(:check)
suite.require_mrbc!

SOURCE = <<~RUBY
  class Item
    def initialize
      @v = 3
      nil
    end

    def value
      @v
    end
  end

  class Other
    def value
      2
    end
  end

  class Base
    def value
      4
    end
  end

  class Derived < Base
    def value
      5
    end
  end

  class Shelf
    def initialize
      @store = {}
      @store[:item] = Item.new
      @store[:base] = Base.new
      nil
    end

    def fetch
      @store[:item]
    end

    def plain_fetch
      @store[:item]
    end

    def base_fetch
      @store[:base]
    end

    def ratio
      1.5
    end

    def use
      fetch.value
    end

    def use_plain
      plain_fetch.value
    end

    def use_base
      base_fetch.value
    end

    def total
      Other.new.value + Derived.new.value + use + use_plain + use_base
    end
  end
RUBY

SIGNATURES = <<~RBS
  class Shelf
    %a{bc2cpp:hint}
    def fetch: () -> Item
    def plain_fetch: () -> Item
    %a{bc2cpp:hint}
    def base_fetch: () -> Base
    %a{bc2cpp:hint}
    def ratio: () -> Float
  end
RBS

# { "Owner#name" => generated body } of one run with the given switches.
bodies = lambda do |env|
  env.each { |k, v| ENV[k] = v }
  Dir.mktmpdir('exact_declared_return') do |dir|
    sigs = File.join(dir, 'sig')
    Dir.mkdir(sigs)
    File.write(File.join(sigs, "shelf.rbs"), SIGNATURES)
    ENV['BC2CPP_SIG_DIRS'] = sigs
    code, = Bc2cppFixtureRuntime.generate(SOURCE, dir, only_owners: %w[Item Other Base Derived Shelf])
    code.split(%r{^(?=// \w+#)}).to_h { |part| [part[%r{\A// (\S+)}, 1], part] }
  end
ensure
  ENV.delete('BC2CPP_SIG_DIRS')
  env.each_key { |k| ENV.delete(k) }
end
on = bodies.call({})
off = bodies.call('BC2CPP_EXACT_DECLARED_RETURNS' => '0')
unguarded = bodies.call('BC2CPP_DECLARATION_GUARD' => '0')
class_tests = ->(body) { body.to_s.scan(/bc2cpp_(?:obj_class|class_is)\(M,/).size }

check.call('the guards are emitted for the hinted declarations',
           on['Shelf#fetch'].to_s.include?('DECLARED_RETURN_GUARD Shelf#fetch -> Item'))
check.call('before, a send on the declared result tests the classes that answer the name',
           class_tests.call(off['Shelf#use']) > class_tests.call(on['Shelf#use']) || off['Shelf#use'].to_s.include?('POLY'))
check.call('a send on a `-> Item` result has no class-test chain: the result is exactly an Item',
           class_tests.call(on['Shelf#use']) == 0 && !on['Shelf#use'].to_s.include?('POLY') &&
             on['Shelf#use'].to_s.include?('EXACT_TYPED :value -> Item#value'))
check.call('a plain declaration whose guard is dropped stays a ceiling (no exact result)',
           class_tests.call(unguarded['Shelf#use_plain']) == class_tests.call(off['Shelf#use_plain']))
check.call('a subclassed declared class is not exact (Derived < Base)',
           class_tests.call(on['Shelf#use_base']) == class_tests.call(off['Shelf#use_base']))

# The mask each kind gives the exact-class flow (NumericFlow bits: INT = 1, FLT = 2; the immediate classes only with
# their bits enabled), over hand-set declarations.
class MaskHarness < CodeGen
  def initialize(entries, subclassed: [])
    @declared_returns_final = true
    @entries = entries.group_by(&:name)
    @superclass_of = subclassed.to_h { |k| ["Sub#{k}", k] }
    @numeric_class_bits = {}
  end

  def declared_return_by_name = @entries
  def declared_return_refusal(_name) = nil
  def declared_return_guard(label) = label
  def instance_class?(klass) = klass != 'Mod'
  def native_table_name_visible?(_name, _klass) = true
  def immediate_class_bits_enabled? = ENV['BC2CPP_IMMEDIATE_CLASS_BITS'] != '0'
end
decl = lambda do |name, kind, cls, nilable: false|
  DeclaredReturns::Entry.new(owner: 'Foo', name: name, label: "L_#{name}", kind: kind, cls: cls, nilable: nilable, text: cls.to_s,
                             loc: nil, hint: true)
end
entries = [decl.call('int', :fixnum, 'Integer'), decl.call('flt', :float, 'Float'), decl.call('sym', :symbol, 'Symbol'),
           decl.call('bool', :bool, nil), decl.call('nilv', :nil, nil), decl.call('foo', :class, 'Foo'),
           decl.call('foo_or_nil', :class, 'Foo', nilable: true), decl.call('sub', :class, 'Base'),
           decl.call('str', :string, 'String'), decl.call('mod', :class, 'Mod')]
masks = MaskHarness.new(entries, subclassed: ['Base'])
masks.instance_variable_set(:@ireps, entries.to_h { |e| [e.label, true] })
masks.instance_variable_set(:@owner_of, entries.to_h { |e| [e.label, true] })
masks.define_singleton_method(:declared_return_proven?) { |_e| false }
check.call('-> Integer is the INT bit and -> Float the FLT bit', masks.declared_exact_return_mask('int') == NumericFlow::INT &&
                                                                  masks.declared_exact_return_mask('flt') == NumericFlow::FLT)
check.call('-> Symbol and bool take the immediate class bits', masks.declared_exact_return_mask('sym') == masks.numeric_class_bit('Symbol') &&
                                                               masks.declared_exact_return_mask('bool') == (masks.numeric_class_bit('TrueClass') | masks.numeric_class_bit('FalseClass')))
check.call('-> nil is the NIL bit', masks.declared_exact_return_mask('nilv') == NumericFlow::NIL)
check.call('-> Foo is Foo\'s class bit and -> Foo? adds NIL', masks.declared_exact_return_mask('foo') == masks.numeric_class_bit('Foo') &&
                                                           masks.declared_exact_return_mask('foo_or_nil') == (masks.numeric_class_bit('Foo') | NumericFlow::NIL))
check.call('a subclassed class, a string (subclasses pass mrb_string_p) and a non-instance class stay ceilings',
           masks.declared_exact_return_mask('sub').nil? && masks.declared_exact_return_mask('str').nil? &&
             masks.declared_exact_return_mask('mod').nil?)
ENV['BC2CPP_IMMEDIATE_CLASS_BITS'] = '0'
off_bits = MaskHarness.new(entries, subclassed: ['Base'])
off_bits.instance_variable_set(:@ireps, entries.to_h { |e| [e.label, true] })
off_bits.instance_variable_set(:@owner_of, entries.to_h { |e| [e.label, true] })
off_bits.define_singleton_method(:declared_return_proven?) { |_e| false }
check.call('with BC2CPP_IMMEDIATE_CLASS_BITS=0 Symbol and bool give no mask, Integer and Float still do',
           off_bits.declared_exact_return_mask('sym').nil? && off_bits.declared_exact_return_mask('bool').nil? &&
             off_bits.declared_exact_return_mask('int') == NumericFlow::INT)
ENV.delete('BC2CPP_IMMEDIATE_CLASS_BITS')
unguarded_mask = MaskHarness.new(entries)
unguarded_mask.instance_variable_set(:@ireps, entries.to_h { |e| [e.label, true] })
unguarded_mask.instance_variable_set(:@owner_of, entries.to_h { |e| [e.label, true] })
unguarded_mask.define_singleton_method(:declared_return_guard) { |_label| nil }
unguarded_mask.define_singleton_method(:declared_return_proven?) { |_e| false }
check.call('a declaration whose guard is not emitted gives no exact mask', unguarded_mask.declared_exact_return_mask('foo').nil?)

suite.finish!
