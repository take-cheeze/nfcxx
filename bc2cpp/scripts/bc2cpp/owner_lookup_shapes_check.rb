#!/usr/bin/env ruby
# encoding: UTF-8
# frozen_string_literal: true

# The method-lookup shapes behind bc2cpp_owner_call and the bc2cpp_find_method seam (docs/bc2cpp-vm-free-runtime-plan.md,
# Phase 1): singleton methods, include order, method_missing, undefined and private errors, send, respond_to?.
# Compiled output must equal the interpreter's, line for line, and the generated code must keep one lookup call.
# Owner-call sites themselves are in owner_call_icache_check.rb. Also pinned: public_send of a private method raises, and
# `super` from a module's method reaches the superclass through the receiver's include-class.
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
  module Wrap; def tag; "w" + super; end; end
  class Wrapped < Base
    include Wrap
    def go; tag; end
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
  module Late; def size; :late; end; end
  module Pre; def size; :pre; end; end
  class Probe
    def sz(o); o.size; end
    def pk(o); o.pack('C*'); end
    def tg(o); o.tag; end
    def via_send(o); o.send(:hidden); end
    def via_public_send(o); o.public_send(:hidden); end
    def rt(o, name); o.respond_to?(name); end
  end
RUBY

OWNERS = %w[Late Pre Loud Mid Base Kid Ghost Secret Probe Wrap Wrapped Array String Hash Symbol Range Kernel Object BasicObject Module Class
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
  show.call('public_send private') { pr.via_public_send(Secret.new) }
  show.call('module super via dispatch') { pr.tg(Wrapped.new) }
  show.call('module super via self call') { Wrapped.new.go }
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
  # Table writes after the sites are warm (the seam must not keep a stale answer). Only `size`, `pack` and
  # respond_to? reach the table: a method every owner of which is compiled is a direct call, and runtime
  # redefinition of those is outside the closed world (the engine lint forbids it).
  class Base; def size; 9; end; end
  200.times { pr.sz(Base.new); pr.sz(Kid.new); pr.sz(Ghost.new); pr.pk([1]) }
  Base.send(:define_method, :size) { 10 }
  show.call('define_method over a warm site') { [pr.sz(Base.new), pr.sz(Kid.new)] }
  Base.send(:remove_method, :size)
  show.call('remove_method falls to undefined') { pr.sz(Kid.new) }
  class Kid; include Late; end
  show.call('include after warm-up') { pr.sz(Kid.new) }
  class Base; alias_method :size, :class; end
  show.call('alias_method on the superclass') { [pr.sz(Base.new), pr.sz(Kid.new)] }
  class Base; undef_method :size; end
  show.call('undef_method hides the included module') { [pr.sz(Base.new), pr.sz(Kid.new)] }
  class Kid; prepend Pre; end
  show.call('prepend after warm-up') { pr.sz(Kid.new) }
  module Late; def size; :late2; end; end
  show.call('module body redefined') { pr.sz(Kid.new) }
  class Base; def size; 11; end; end
  class Base; private :size; end
  show.call('private after warm-up') { pr.sz(Base.new) }
  class Base; public :size; end
  show.call('public again') { pr.sz(Base.new) }
  show.call('respond_to? private-then-public') { pr.rt(Base.new, :size) }
  class Ghost; undef_method :method_missing; end
  show.call('method_missing undefined') { pr.sz(Ghost.new) }
  class Ghost; def method_missing(name, *args); [:mm2, name]; end; end
  show.call('method_missing redefined') { pr.sz(Ghost.new) }
  class Ghost; def size; :real; end; end
  show.call('real method beats method_missing') { pr.sz(Ghost.new) }
  show.call('respond_to? after define') { pr.rt(Ghost.new, :size) }
  class Ghost; remove_method :size; end
  show.call('respond_to? after remove') { pr.rt(Ghost.new, :size) }
  class Secret; public :size; end
  show.call('private made public') { pr.sz(Secret.new) }
  g = Ghost.new
  g.extend(Late)
  show.call('extend on an instance') { pr.sz(g) }
  class << Base; def size; 33; end; end
  show.call('class-method redefined') { [pr.sz(Base), pr.sz(Kid)] }
  class << Base; remove_method :size; end
  show.call('class-method removed') { pr.sz(Kid) }
  class Array
    alias_method :pack_was, :pack
    def pack(f); 'mine'; end
  end
  show.call('core method redefined') { pr.pk([65]) }
  class Array
    remove_method :pack
    alias_method :pack, :pack_was
  end
  show.call('core method restored') { pr.pk([65]) }
  puts 'end'
RUBY

suite.behaviour(DRIVER) do |interpreted, compiled|
  suite.check('NoMethodError text is the interpreter\'s',
              compiled.to_a.any? { |l| l.start_with?('undefined size: NoMethodError: undefined method') })
  suite.check('include order', compiled.to_a.include?('include order: "loud"'))
  suite.check('public_send of a private method raises',
              compiled.to_a.any? { |l| l.start_with?('public_send private: NoMethodError: private method') })
  suite.check('module super reaches the superclass',
              compiled.to_a.include?('module super via self call: "wbase"'))
  suite.check('the interpreter produced the rows', interpreted.to_a.size > 20)
  [
    'define_method over a warm site: [10, 10]', 'include after warm-up: :late', 'prepend after warm-up: :pre',
    'module body redefined: :pre', 'private after warm-up: NoMethodError: private method \'size\' called for Base',
    'method_missing redefined: [:mm2, :size]', 'real method beats method_missing: :real',
    'extend on an instance: :late2', 'core method redefined: "mine"'
  ].each { |row| suite.check("mutation row after warm-up: #{row}", compiled.to_a.include?(row)) }
end
suite.finish
