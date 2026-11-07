#!/usr/bin/env ruby
# frozen_string_literal: true

# SDEF_CONST_OWNER: `def Const.name` inside a body is registered on the constant the lexical lookup finds, not always
# on "<namespace>::Const". `class Enumerator; def Enumerator.produce` owns "Enumerator.singleton"; the nested spelling
# "Enumerator::Enumerator.singleton" names no class, and a registration that const_gets it raises NameError at gem init
# (the closed sweep then lost every later registration, e.g. File.open: "undefined method 'open' for Class").
#
# Usage: MRBC=path/to/mrbc ruby scripts/bc2cpp/singleton_const_owner_check.rb

unless ENV['MRBC']
  puts '  SKIP: set MRBC (a host mrbc built from the patched 3rd/mruby)'
  exit 0
end

ENV['BC2CPP_SIG_DIRS'] = ''
require_relative '../../tools/bc2cpp/bc2cpp'
require_relative 'fixture_runtime'

failures = []
check = lambda do |what, condition|
  puts "  #{condition ? 'ok  ' : 'FAIL'} #{what}"
  failures << what unless condition
end

SOURCE = <<~RUBY
  class Outer
    def self.own; end
    def Outer.produce; end
    class Inner
      def Inner.make; end
      def Outer.reopened; end
    end
    def Sibling.later; end
  end
  class Sibling; end
RUBY

owners = lambda do |name, registry|
  registry.fetch(name, []).map(&:owner)
end

Bc2cppFixtureRuntime.registry_snapshot(SOURCE) { |_registry, _ireps| [[], []] }.then do |registry, *|
  check.call('def Outer.produce inside class Outer is Outer.singleton', owners.call('produce', registry) == ['Outer.singleton'])
  check.call('def self.own is Outer.singleton', owners.call('own', registry) == ['Outer.singleton'])
  check.call('def Inner.make inside class Inner is Outer::Inner.singleton', owners.call('make', registry) == ['Outer::Inner.singleton'])
  check.call('def Outer.reopened from a nested body finds the enclosing Outer', owners.call('reopened', registry) == ['Outer.singleton'])
  check.call('a constant no scope declared yet keeps the innermost spelling', owners.call('later', registry) == ['Outer::Sibling.singleton'])
end

if failures.empty?
  puts "singleton const owner: #{5} checks passed"
else
  warn "FAIL: #{failures.join('; ')}"
  exit 1
end
