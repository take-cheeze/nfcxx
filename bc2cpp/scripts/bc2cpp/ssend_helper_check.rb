#!/usr/bin/env ruby
# encoding: UTF-8
# frozen_string_literal: true

# SSEND_HELPER (tools/bc2cpp/codegen_class_body.rb, bc2cpp.rb): a class body's by-name self send (include, attr_*) is one call
# of the shared bc2cpp_ssend helper, not an mrb_funcall at the site. Compiled and interpreted runs define the same
# accessors, include the same module and keep the include hooks and a private-method call of the by-name path.
#
# Usage: MRBC=path/to/mrbc [BC2CPP_MRUBY_FULL=dir | BC2CPP_FULL_BUILD_DIR=dir] ruby scripts/bc2cpp/ssend_helper_check.rb

require_relative 'fixture_runtime'

suite = Bc2cppStepCheck.new('bc2cpp ssend helper check')

SRC = <<~'RUBY'
  module SsMix
    def self.included(base); (@log ||= []) << base.name; end
    def self.log; @log; end
    def mixed; :mixed; end
  end
  class SsBox
    include SsMix
    attr_reader :a, :b
    attr_writer :w
    attr_accessor :x, :y
    def initialize; @a = 1; @w = 2; @x = 3; end
    def w_value; @w; end
  end
  class SsKid < SsBox
    attr_accessor :z
  end
RUBY

OWNERS = %w[SsMix SsBox SsKid].freeze

code = suite.generate(SRC, OWNERS)
suite.check('the sends are bc2cpp_ssend calls', code.scan('bc2cpp_ssend(M, self, ').size >= 5)
suite.check('no site keeps its own by-name argument array', !code.include?('bc2cpp_ssend_args'))

DRIVER = <<~'RUBY'
  b = SsBox.new
  b.x = 7
  b.y = :y
  b.w = 9
  puts [b.a, b.b, b.x, b.y, b.w_value, b.mixed].inspect
  puts SsBox.include?(SsMix).inspect
  puts SsMix.log.uniq.inspect
  k = SsKid.new
  k.z = 5
  k.x = 1
  puts [k.z, k.x, k.a, k.mixed].inspect
  puts SsKid.instance_methods(false).sort.inspect
  puts SsBox.instance_methods(false).sort.inspect
  begin; b.w; rescue NoMethodError => e; puts "NoMethodError"; end
  puts 'end'
RUBY

suite.behaviour(DRIVER)
suite.finish
