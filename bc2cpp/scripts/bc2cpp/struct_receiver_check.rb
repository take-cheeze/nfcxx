#!/usr/bin/env ruby
# frozen_string_literal: true

# STRUCT_RECEIVER (tools/bc2cpp/registry.rb): the Struct.new receiver and the singleton receiver of `def obj.m` /
# `class << obj` are read from BytecodeIR.reaching_definitions (MOVEs followed), so every definition that reaches
# the send must be the same constant. The old linear read saw only the textually nearest writer: a local holding
# Struct (`k = Struct; k.new`) is a MOVE there, so its members and block defs were missed; a join
# `(c ? Hash : Struct).new` took the Struct branch that happens to come last, which is not the receiver on every path.
# Where the IR cannot prove the set, the linear rule decides as before.
#
# 1. The registrations the shapes must produce (MRBC): the compiled snippet's registry and struct members.
#
# Usage: MRBC=path/to/mrbc ruby scripts/bc2cpp/struct_receiver_check.rb

require_relative 'check_support'

suite = FixtureCheck.new('struct_receiver_check')
suite.require_mrbc!
# The fixtures declare no RBS; the repository's signatures name engine classes these fixtures lack.
ENV['BC2CPP_SIG_DIRS'] = ''
require_relative '../../tools/bc2cpp/bc2cpp'
check = suite.method(:check)

SNIPPET = <<~RUBY
  class Host; end
  k = Struct
  Pt = k.new(:x) do
    def ext; end
  end
  Pt5 = k.new(:z)
  o = Host
  def o.zap; 1; end
  c = true
  Pt3 = (c ? Hash : Struct).new(:x) do
    def amb; end
  end
  Pt0 = Struct.new(:y) do
    def base; end
  end
  Pt7 = (c ? Struct : Struct).new(:w) do
    def both; end
  end
RUBY

# [registry, struct member lists] of the snippet, compiled by mrbc.
registry, members = suite.compile(SNIPPET) do |ireps, root|
  result = build_registry(ireps, root)
  [result[0], result[6]]
end
owner_of = ->(name) { registry.fetch(name, []).map(&:owner) }

puts '-- STRUCT_RECEIVER (registry)'
check.call('a Struct held in a local (MOVE receiver) is recognized: its members are registered',
           members['Pt'] == ['x'])
check.call('a Struct held in a local: its block defs register under the Struct owner', owner_of.call('ext') == ['Pt'])
check.call('a block-less `k.new(:z)` through a local Struct registers its members', members['Pt5'] == ['z'])
check.call('a singleton `def o.zap` with o = Host (MOVE receiver) registers under Host.singleton',
           owner_of.call('zap') == ['Host.singleton'])
check.call('a join `(c ? Hash : Struct).new` is not a Struct on every path: no member list',
           members['Pt3'].nil?)
check.call('a join `(c ? Hash : Struct).new`: its block defs are not registered under that owner',
           owner_of.call('amb').empty?)
check.call('a direct `Struct.new` with a block is still recognized (baseline)', members['Pt0'] == ['y'])
check.call('the direct Struct.new block defs still register under their owner', owner_of.call('base') == ['Pt0'])
check.call('a join where Struct is the receiver on every arm is still recognized (never less)',
           members['Pt7'] == ['w'] && owner_of.call('both') == ['Pt7'])

suite.finish!
