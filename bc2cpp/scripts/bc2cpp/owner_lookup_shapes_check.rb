#!/usr/bin/env ruby
# encoding: UTF-8
# frozen_string_literal: true

# The method-lookup shapes behind bc2cpp_owner_call and the bc2cpp_find_method seam (docs/bc2cpp-vm-free-runtime-plan.md,
# Phase 1): singleton methods, include order, method_missing, undefined and private errors, send, respond_to?.
# Compiled output must equal the interpreter's, line for line, and the generated code must keep one lookup call.
# Owner-call sites themselves are in owner_call_icache_check.rb. Also pinned: public_send of a private method raises, and
# `super` from a module's method reaches the superclass through the receiver's include-class. A `call` on a compiled
# block runs its entry only while Proc#call is the builtin (PROC_CALL_DIRECT): rows for overrides, lambdas, next/break/
# return, a block argument and the Method/Symbol/curry procs.
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
  class OwnProc < Proc; def call(*a); [:own, a]; end; end
  class SubProc < Proc; end
  module Late; def size; :late; end; end
  module Pre; def size; :pre; end; end
  class Probe
    def sz(o); o.size; end
    def pk(o); o.pack('C*'); end
    def tg(o); o.tag; end
    def via_send(o); o.send(:hidden); end
    def via_public_send(o); o.public_send(:hidden); end
    def rt(o, name); o.respond_to?(name); end
    def mk(&b); b; end
    def cl(b, *a); b.call(*a); end
    def cl_aref(b, *a); b[*a]; end
    def cl_blk(b, x, &bl); b.call(x, &bl); end
    def mk_plain; mk { |a, b| [:plain, a, b] }; end
    def mk_next; mk { |x| next :big if x > 1; :small }; end
    def mk_break; mk { |x| break :brk }; end
    def mk_ret; mk { |x| return :ret }; end
    def mk_lam; lambda { |a, b| [:lam, a, b] }; end
    def mk_blk; mk { |x, &bb| [x, bb ? bb.call : nil] }; end
    def mk_sum; n = 0; mk { |x| n += x }; end
  end
RUBY

OWNERS = %w[Late Pre Loud Mid Base Kid Ghost Secret Probe Wrap Wrapped Array String Hash Symbol Range Kernel Object BasicObject Module Class
            Comparable Integer NilClass Proc Method].freeze
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
  # The block-call rows redefine Proc#call, so they run through yield, not a Proc.
  def row(label)
    puts "#{label}: #{yield.inspect}"
  rescue Exception => e
    puts "#{label}: #{e.class}: #{e.message}"
  end
  row('proc call') { [pr.cl(pr.mk_plain, 1, 2), pr.cl(pr.mk_plain, [3, 4]), pr.cl(pr.mk_plain), pr.cl(pr.mk_plain, 1, 2, 3)] }
  row('proc aref') { [pr.cl_aref(pr.mk_plain, 1), pr.cl_aref(pr.mk_plain, [5, 6])] }
  row('proc next') { [pr.cl(pr.mk_next, 5), pr.cl(pr.mk_next, 0)] }
  row('proc break') { pr.cl(pr.mk_break, 1) }
  row('proc return') { pr.cl(pr.mk_ret, 1) }
  row('proc closure') { s = pr.mk_sum; [pr.cl(s, 1), pr.cl(s, 2), pr.cl(s, 3)] }
  row('lambda ok') { pr.cl(pr.mk_lam, 1, 2) }
  row('lambda arity') { pr.cl(pr.mk_lam, 1) }
  row('lambda arity aref') { pr.cl_aref(pr.mk_lam, 1, 2, 3) }
  row('proc block arg') { [pr.cl_blk(pr.mk_blk, 1), pr.cl_blk(pr.mk_blk, 2) { :given }] }
  row('method to_proc') { [pr.cl(5.method(:+).to_proc, 3), pr.cl(5.method(:between?).to_proc, 1, 9)] }
  row('symbol to_proc') { [pr.cl(:upcase.to_proc, 'a'), pr.cl(:upcase.to_proc)] }
  row('curry') { c = pr.mk_lam.curry; [pr.cl(c, 1).class, pr.cl(pr.cl(c, 1), 2)] }
  row('interpreted block') { [pr.cl(proc { |a, b| [a, b] }, 1, 2), pr.cl(proc { |a| a }, [7])] }
  100.times { pr.cl(pr.mk_plain, 1, 2) }
  one = pr.mk_plain
  def one.call(*a); [:single, a]; end
  row('singleton call') { [pr.cl(one, 1), pr.cl_aref(one, 1), pr.cl(pr.mk_plain, 1, 2)] }
  mod = Module.new { def call(*a); [:ext, a]; end }
  ext = pr.mk_plain.extend(mod)
  row('extended call') { [pr.cl(ext, 1), pr.cl(pr.mk_plain, 1, 2)] }
  class Proc; alias_method :call_was, :call; def call(*a); [:ovr, a]; end; end
  row('Proc#call overridden') { [pr.cl(pr.mk_plain, 1), pr.cl_aref(pr.mk_plain, 1), pr.cl(pr.mk_lam, 1)] }
  class Proc; alias_method :call, :call_was; end
  row('Proc#call restored') { [pr.cl(pr.mk_plain, 1, 2), pr.cl(pr.mk_lam, 1, 2)] }
  class Proc; alias_method :aref_was, :[]; def [](*a); [:aref, a]; end; end
  row('Proc#[] overridden') { [pr.cl_aref(pr.mk_plain, 1), pr.cl(pr.mk_plain, 1, 2)] }
  class Proc; alias_method :[], :aref_was; end
  row('subclass override') { [pr.cl(OwnProc.new { |a| a }, 1), pr.cl(OwnProc.new { |a| a }, 2)] }
  row('subclass plain') { pr.cl(SubProc.new { |a| a }, 1) }
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
    'proc call: [[:plain, 1, 2], [:plain, 3, 4], [:plain, nil, nil], [:plain, 1, 2]]', 'proc next: [:big, :small]',
    'singleton call: [[:single, [1]], [:plain, 1, nil], [:plain, 1, 2]]', 'extended call: [[:ext, [1]], [:plain, 1, 2]]',
    'Proc#call restored: [[:plain, 1, 2], [:lam, 1, 2]]', 'subclass plain: 1'
  ].each { |row| suite.check("block call row: #{row}", compiled.to_a.include?(row)) }
  suite.check('overridden Proc#call wins',
              compiled.to_a.include?('Proc#call overridden: [[:ovr, [1]], [:plain, 1, nil], [:ovr, [1]]]'))
  suite.check('a lambda keeps its arity error', compiled.to_a.any? { |l| l.start_with?('lambda arity: ArgumentError: wrong number of arguments') })
  suite.check('a subclass call wins', compiled.to_a.include?('subclass override: [[:own, [1]], [:own, [2]]]'))
  [
    'define_method over a warm site: [10, 10]', 'include after warm-up: :late', 'prepend after warm-up: :pre',
    'module body redefined: :pre', 'private after warm-up: NoMethodError: private method \'size\' called for Base',
    'method_missing redefined: [:mm2, :size]', 'real method beats method_missing: :real',
    'extend on an instance: :late2', 'core method redefined: "mine"'
  ].each { |row| suite.check("mutation row after warm-up: #{row}", compiled.to_a.include?(row)) }
end
suite.finish
