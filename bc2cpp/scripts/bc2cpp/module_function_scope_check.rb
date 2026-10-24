#!/usr/bin/env ruby
# frozen_string_literal: true

# A bare `module_function` makes every later def in the body a module function (this mruby's MODFUNC scope bit,
# src/class.c): a private instance method plus a public singleton copy. The registry (tools/bc2cpp/registry.rb) must
# list that copy, or the closed world's owner set for `Mod.name` misses `Mod.singleton` and the compiled call raises a
# closed-world owner violation. The named form `module_function :a` changes nothing after it.
#
# Usage: MRBC=path/to/mrbc ruby scripts/bc2cpp/module_function_scope_check.rb

require 'tmpdir'
require_relative '../../tools/bc2cpp/irep'
require_relative '../../tools/bc2cpp/registry'

FIXTURE = <<~RUBY
  module Drv
    module_function

    def load(c) = load_each(c)
    def load_each(c) = c
  end

  module Named
    def a = 1
    module_function :a
    def b = 2
  end
RUBY

mrbc = ENV['MRBC']
unless mrbc && File.executable?(mrbc)
  puts '  SKIP: no host mrbc (set MRBC)'
  exit 0
end

registry = Dir.mktmpdir('module_function_scope') do |dir|
  src = File.join(dir, 'fixture.rb')
  out = File.join(dir, 'fixture.mrb')
  File.write(src, FIXTURE)
  system(mrbc, '-g', '-o', out, src, exception: true)
  ireps, root = load_ireps(Struct.new(:bytes).new(File.binread(out)), cache: nil)
  build_registry(ireps, root)[0]
end

defs = ->(name) { registry[name].to_h { |d| [d.owner, d] } }

failures = []
check = lambda do |description, ok|
  puts "  #{ok ? 'ok  ' : 'FAIL'} #{description}"
  failures << description unless ok
end

%w[load load_each].each do |name|
  d = defs.call(name)
  check.call("bare module_function: Drv.#{name} is a public singleton copy",
             d['Drv.singleton']&.kind == :module_function && d['Drv.singleton'].visibility == :public &&
             d['Drv.singleton'].copy_irep == d['Drv']&.irep)
  check.call("bare module_function: Drv##{name} is private", d['Drv']&.visibility == :private)
end
check.call('named module_function: Named.a is a singleton copy', defs.call('a')['Named.singleton']&.kind == :module_function)
check.call('named module_function: a later def gets no copy', defs.call('b').keys == ['Named'])
check.call('named module_function: a later def stays public', defs.call('b')['Named']&.visibility == :public)

if failures.empty?
  puts 'bc2cpp module_function scope check: PASS'
else
  puts "bc2cpp module_function scope check: FAIL (#{failures.size})"
  exit 1
end
