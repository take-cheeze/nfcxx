#!/usr/bin/env ruby
# frozen_string_literal: true

# FOREIGN_DEFINER_CALLS (ClosedWorld.foreign_definer_calls) and the Symbol-literal exclusion of RUBY_DYNAMIC: an outside
# Ruby file's dynamic definers decide the closed world's global refusal, so only calls that cannot be
# Module#define_method may be discounted. Host only, well under a second:
#   - three or more arguments (keyword arguments counting as one Hash) is a foreign define_method; one or two is not;
#   - a block pass, a splat, a string or any spelling the scan cannot read keeps the call dynamic;
#   - `member: :attr_reader` is a Symbol, not a definer; `attr_reader name` still is;
#   - a file with only foreign define_method calls and Symbol literals is not dynamic, one with a real definer is;
#   - OUTSIDE_STRUCT_FACTORY (ClosedWorld.ruby_factory_facts): a blockless one-line Struct.new of Symbol members is a
#     struct factory, not a global class factory; Class.new, a Struct.new with a block or another argument, and a
#     namespaced `Foo::Class` the file does not define stay class factories.
#
# Usage: ruby scripts/bc2cpp/foreign_definer_calls_check.rb

require 'tmpdir'
require_relative 'check_support'
require_relative '../../tools/bc2cpp/closed_world'

failures = []
check = lambda do |what, condition|
  puts "  #{condition ? 'ok  ' : 'FAIL'} #{what}"
  failures << what unless condition
end

calls = ->(text) { ClosedWorld.foreign_definer_calls(text) }
check.call('three positional arguments is a foreign define_method', calls.call('define_method(a, b, c)') == 1)
check.call('two arguments may be Module#define_method', calls.call('define_method(a, b)').zero?)
check.call('positional plus keywords counts the keywords as one Hash',
           calls.call('define_method(a, b, k: 1)') == 1 && calls.call('define_method(a, k: 1, j: 2)').zero?)
check.call('a block pass or a splat keeps the call dynamic',
           calls.call('define_method(a, b, &blk)').zero? && calls.call('define_method(*x, y, z)').zero?)
check.call('a string argument stops the scan', calls.call('define_method(a, "s", c)').zero?)
check.call('a multi-line list with a ternary is read',
           calls.call("define_method(\n  a,\n  b,\n  c.d? ? nil : e\n)") == 1)
check.call('an unclosed list is not counted', calls.call('define_method(a, b, c').zero?)

dynamic = ->(text) { text.scan(ClosedWorld::RUBY_DYNAMIC).size }
check.call('a Symbol literal is not a definer', dynamic.call("{ member: :attr_reader, x: :attr_accessor }").zero?)
check.call('a definer with a computed name still is', dynamic.call("attr_reader name\ndefine_method(n) { }") == 2)

factory = ->(text) { ClosedWorld.ruby_factory_facts(text) }
check.call('a blockless Symbol-member Struct.new is a struct factory only',
           factory.call('X = Struct.new(:a, keyword_init: true)') == [false, true] &&
           factory.call("class D < Struct.new(:a, :b)\nend") == [false, true] &&
           factory.call('x = ::Struct.new(:a)') == [false, true])
check.call('a Struct.new with a block or another argument is a class factory',
           factory.call("X = Struct.new(:a) do\n  def f; end\nend") == [true, false] &&
           factory.call('X = Struct.new(:a) { }') == [true, false] && factory.call('X = Struct.new("N", :a)') == [true, false] &&
           factory.call('X = Struct.new(*m)') == [true, false] && factory.call("X = Struct.new(:a,\n :b)") == [true, false])
check.call('Class.new is a class factory, bare or rooted', factory.call('k = Class.new(Foo)') == [true, false] &&
                                                         factory.call('k = ::Class.new') == [true, false])
check.call('a namespaced Class is the file own class only when the file defines it',
           factory.call('n = AST::Declarations::Class.new(') == [true, false] &&
           factory.call("module D\n  class Class\n  end\nend\nn = D::Class.new(") == [false, false])

Dir.mktmpdir('foreign_definer_calls') do |dir|
  foreign = File.join(dir, 'foreign.rb')
  File.write(foreign, <<~RUBY)
    class Builder
      def build(m) = define_method(m, nil, :x, defined_in: nil)
      def define_method(methods, definition, name, defined_in:) = methods
      def to_h = { member: :attr_reader }
    end
  RUBY
  real = File.join(dir, 'real.rb')
  File.write(real, File.read(foreign) + "class Other\n  def self.make(n) = define_method(n) { }\nend\n")
  check.call('a file with only foreign define_method calls and Symbols is not dynamic',
             ClosedWorld.ruby_file_facts(foreign)[:dynamic] == false)
  check.call('a file that also defines by a computed name is dynamic', ClosedWorld.ruby_file_facts(real)[:dynamic] == true)
end

if failures.empty?
  puts 'foreign_definer_calls_check: PASS'
else
  puts "foreign_definer_calls_check: #{failures.size} FAILED"
  exit 1
end
