#!/usr/bin/env ruby
# frozen_string_literal: true

# CLASS_BODY_HOIST (tools/optcarrot_probe/class_body_hoist.rb): which class-body initializers are hoisted into a
# singleton method, that the rewrite keeps every line where it was, and that CRuby gets the same constants from the
# rewritten source as from the original.

require 'open3'
require 'rbconfig'
require_relative '../../tools/optcarrot_probe/class_body_hoist'

failures = 0
check = lambda do |label, ok|
  puts "  #{ok ? 'ok  ' : 'FAIL'} #{label}"
  failures += 1 unless ok
end

# Loads `source` in a fresh CRuby with a stub OptcarrotProbe and prints the named constants.
evaluate = lambda do |source, constants|
  script = <<~RUBY
    module OptcarrotProbe
      CALLS = []
      def self.install_hoisted!(klass, name) = (CALLS << [klass.name, name]) && false
    end
    #{source}
    p [#{constants.join(', ')}]
    p OptcarrotProbe::CALLS
  RUBY
  out, status = Open3.capture2e(RbConfig.ruby, '-e', script)
  raise "fixture failed to run: #{out}" unless status.success?

  out.lines.map(&:chomp)
end

puts '== hoisted'
source = <<~'RUBY'
  module Outer
    BASE = 3
    class Lut
      TILE = [0x0, 0x4].map do |attr|
        (0..3).map do |j|
          (0...8).map { |i| (i[2 - (j % 3)] * 2) | attr }
        end.transpose
      end
      PAIR_A, PAIR_B = [1, 6].map { |s| (0..7).map { |b| b[0] == b[s % 3] ? b / 2 : (b / 2) + BASE } }
      NESTED = [1, 2].map { |a| [3].map { |b| a + b + BASE } }
      PLAIN = [1, 2, 3].sum
    end
  end
RUBY
rewritten, names = ClassBodyHoist.rewrite(source)
check.call('the block initializers are hoisted, in source order',
           names == %w[__bc2cpp_init_tile __bc2cpp_init_pair_a_pair_b __bc2cpp_init_nested])
check.call('no line moves', rewritten.lines.size == source.lines.size &&
                            rewritten.lines.zip(source.lines).count { |a, b| a != b } == 4)
check.call('an initializer without a block stays', rewritten.include?('PLAIN = [1, 2, 3].sum'))
tile_tail = '; end; OptcarrotProbe.install_hoisted!(self, :__bc2cpp_init_tile); TILE = __bc2cpp_init_tile'
check.call('the constant is assigned from the hoisted method', rewritten.include?(tile_tail))
constants = %w[Outer::Lut::TILE Outer::Lut::PAIR_A Outer::Lut::PAIR_B Outer::Lut::NESTED Outer::Lut::PLAIN]
before = evaluate.call(source, constants)
after = evaluate.call(rewritten, constants)
check.call('CRuby builds the same constants', before.first == after.first)
check.call('install_hoisted! is called with the class and the method name',
           after.last == [%w[Outer::Lut __bc2cpp_init_tile], %w[Outer::Lut __bc2cpp_init_pair_a_pair_b],
                          %w[Outer::Lut __bc2cpp_init_nested]].map { |k, n| [k, n.to_sym] }.inspect)

puts '== refused'
{
  'a class-body local' => "class A\n  x = 3\n  T = [1].map { |i| i + x }\nend\n",
  'a call without a receiver' => "class A\n  def self.h(i) = i\n  T = [1].map { |i| h(i) }\nend\n",
  'a constant assignment inside' => "class A\n  T = [1].map { |i| B = i }\nend\n",
  '__LINE__' => "class A\n  T = [1].map { |i| i + __LINE__ }\nend\n",
  'a heredoc' => "class A\n  T = [1].map { |i| <<~S + i.to_s\n    x\n  S\n  }\nend\n",
  'a splat target' => "class A\n  T, *R = [1, 2].map { |i| i }\nend\n",
  'a class << self body' => "class A\n  class << self\n    T = [1].map { |i| i }\n  end\nend\n",
  'a method body' => "class A\n  def f\n    [1].map { |i| i }\n  end\nend\n"
}.each do |label, fixture|
  out, names = ClassBodyHoist.rewrite(fixture)
  check.call("#{label} stays in the class body", names.empty? && out == fixture)
end

puts '== names'
taken = Set.new
check.call('a repeated target name gets a suffix',
           [ClassBodyHoist.unique_name(taken, %w[LUT]), ClassBodyHoist.unique_name(taken, %w[LUT])] ==
             %w[__bc2cpp_init_lut __bc2cpp_init_lut_1])

if failures.zero?
  puts 'class_body_hoist_check: all checks passed'
else
  puts "class_body_hoist_check: #{failures} check(s) failed"
  exit 1
end
