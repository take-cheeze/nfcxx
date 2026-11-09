#!/usr/bin/env ruby
# frozen_string_literal: true

# `public def x` / `private def x` pass the Symbol that the (T)DEF just before the send wrote into the argument
# register, not a LOADSYM. The registry (tools/bc2cpp/registry.rb) must apply that visibility to x, or a compiled
# build registers it with the section's default: `public def` inside a `private` section was installed private, so an
# explicit-receiver call raised NoMethodError (ClosedWorld#singleton_arm_modules in bc2cpp-self).
#
# Usage: MRBC=path/to/mrbc ruby scripts/bc2cpp/inline_visibility_check.rb

require 'tmpdir'
require_relative '../../tools/bc2cpp/irep'
require_relative '../../tools/bc2cpp/registry'

FIXTURE = <<~RUBY
  class Shown
    private

    def hidden = 1
    public def shown = 2
    def after_public = 3
  end

  class Hidden
    def open = 1
    private def closed = 2
    def after_private = 3
  end
RUBY

mrbc = ENV['MRBC']
unless mrbc && File.executable?(mrbc)
  puts '  SKIP: no host mrbc (set MRBC)'
  exit 0
end

registry = Dir.mktmpdir('inline_visibility') do |dir|
  src = File.join(dir, 'fixture.rb')
  out = File.join(dir, 'fixture.mrb')
  File.write(src, FIXTURE)
  system(mrbc, '-g', '-o', out, src, exception: true)
  ireps, root = load_ireps(Struct.new(:bytes).new(File.binread(out)), cache: nil)
  build_registry(ireps, root)[0]
end

visibility = ->(owner, name) { registry[name]&.find { |d| d.owner == owner }&.visibility }

failures = []
check = lambda do |description, ok|
  puts "  #{ok ? 'ok  ' : 'FAIL'} #{description}"
  failures << description unless ok
end

check.call('a def after bare private is private', visibility.call('Shown', 'hidden') == :private)
check.call('`public def` in a private section is public', visibility.call('Shown', 'shown') == :public)
check.call('`public def` leaves the private section private', visibility.call('Shown', 'after_public') == :private)
check.call('a def in the default section is public', visibility.call('Hidden', 'open') == :public)
check.call('`private def` in a public section is private', visibility.call('Hidden', 'closed') == :private)
check.call('`private def` leaves the public section public', visibility.call('Hidden', 'after_private') == :public)

if failures.empty?
  puts 'bc2cpp inline visibility check: PASS'
else
  puts "bc2cpp inline visibility check: FAIL (#{failures.size})"
  exit 1
end
