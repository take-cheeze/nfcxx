#!/usr/bin/env ruby
# encoding: UTF-8
# frozen_string_literal: true

# The method-lookup shapes behind bc2cpp_owner_call and the bc2cpp_find_method seam (docs/bc2cpp-vm-free-runtime-plan.md,
# Phase 1): singleton methods, include order, method_missing, undefined and private errors, send, respond_to?.
# Compiled output must equal the interpreter's, line for line, and the generated code must keep one lookup call.
# Owner-call sites themselves are in owner_call_icache_check.rb; known divergences kept out of the rows: `super` through
# an included module from a direct _impl call, and public_send of a private method (both also on master).
#
# Usage: MRBC=path/to/mrbc [BC2CPP_MRUBY_FULL=dir | BC2CPP_FULL_BUILD_DIR=dir] ruby scripts/bc2cpp/owner_lookup_shapes_check.rb

require_relative 'fixture_runtime'

suite = Bc2cppStepCheck.new('bc2cpp owner lookup shapes check')

SRC = <<~'RUBY'
  module Loud; def tag; "loud"; end; end
  module Mid;  def tag; "mid"; end; end
  class Base
    def tag; "base"; end
    def size; 7; end
    def self.size; 3; end
  end
  class Kid < Base
    include Mid
    include Loud
    def other; "kid"; end
  end
  class Ghost
    def method_missing(name, *args); name == :size ? [:mm, args] : super; end
    def respond_to_missing?(name, priv = false); name == :size; end
  end
  class Secret
    def size; 1; end
    private :size
    def hidden; :h; end
    private :hidden
  end
  class Probe
    def sz(o); o.size; end
    def pk(o); o.pack('C*'); end
    def tg(o); o.tag; end
    def via_send(o); o.send(:hidden); end
    def rt(o, name); o.respond_to?(name); end
  end
RUBY

OWNERS = %w[Loud Mid Base Kid Ghost Secret Probe Array String Hash Symbol Range Kernel Object BasicObject Module Class
            Comparable Integer NilClass].freeze
code = suite.generate(SRC, OWNERS)
lookups = code.scan(/\bmrb_method_search_vm\(/).size
suite.check("one method-table lookup call in the generated unit (the seam), found #{lookups}", lookups == 1)
suite.check('the seam is used', code.include?('bc2cpp_find_method('))

DRIVER = <<~'RUBY'
  pr = Probe.new
  show = lambda do |label, &blk|
    begin
      puts "#{label}: #{blk.call.inspect}"
    rescue Exception => e
      puts "#{label}: #{e.class}: #{e.message}"
    end
  end
  show.call('array size') { pr.sz([1, 2, 3]) }
  show.call('pack owner call') { pr.pk([65, 66]) }
  50.times { pr.pk([67]) }
  show.call('pack after warm-up') { pr.pk([68]) }
  show.call('string size') { pr.sz('ab') }
  show.call('hash size') { pr.sz({ a: 1 }) }
  show.call('instance size') { pr.sz(Base.new) }
  show.call('class-method size (singleton)') { pr.sz(Base) }
  show.call('inherited class-method size') { pr.sz(Kid) }
  show.call('method_missing size') { pr.sz(Ghost.new) }
  show.call('method_missing other') { pr.tg(Ghost.new) }
  show.call('undefined size') { pr.sz(Object.new) }
  show.call('undefined on nil') { pr.sz(nil) }
  show.call('private size') { pr.sz(Secret.new) }
  show.call('include order') { pr.tg(Kid.new) }
  show.call('base tag') { pr.tg(Base.new) }
  show.call('send private') { pr.via_send(Secret.new) }
  show.call('send undefined') { pr.via_send(Object.new) }
  show.call('respond_to? public') { pr.rt(Base.new, :size) }
  show.call('respond_to? private') { pr.rt(Secret.new, :size) }
  show.call('respond_to? missing') { pr.rt(Ghost.new, :size) }
  show.call('respond_to? absent') { pr.rt(Object.new, :size) }
  100.times { pr.sz([1]); pr.sz('x'); pr.sz(Base.new) }
  show.call('after warm-up array') { pr.sz([1, 2]) }
  show.call('after warm-up undefined') { pr.sz(Object.new) }
  class Base; def size; 8; end; end
  show.call('redefined size') { pr.sz(Base.new) }
  class Base; undef_method :size; end
  show.call('undef size') { pr.sz(Base.new) }
  puts 'end'
RUBY

suite.behaviour(DRIVER) do |interpreted, compiled|
  suite.check('NoMethodError text is the interpreter\'s',
              compiled.to_a.any? { |l| l.start_with?('undefined size: NoMethodError: undefined method') })
  suite.check('include order', compiled.to_a.include?('include order: "loud"'))
  suite.check('the interpreter produced the rows', interpreted.to_a.size > 20)
end
suite.finish
