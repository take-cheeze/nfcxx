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
  module SsHook
    def self.included(base); (@log ||= []) << [:included, base.name]; end
    def self.log; @log; end
    def hooked; :hooked; end
  end
  module SsA; def a_m; :a; end; end
  module SsB; def b_m; :b; end; end
  class SsOrder
    include SsA, SsB
    include SsA
    include SsHook
    include SsHook
  end
  class SsVis
    attr_reader :pa
    private
    attr_accessor :pv
    attr_writer :pw
    protected
    attr_reader :pt
    public
    attr_reader :pub
    def initialize; @pa = 0; @pv = 1; @pw = 2; @pt = 3; @pub = 4; end
    def peek; [pv, (self.pv = 9), pt]; end
    def cmp(o); o.pt; end
  end
  class SsRet
    $ss_ret = [(attr_reader :r1, :r2), (attr_writer :r3), (attr_accessor :r4), (include SsA)]
    $ss_str = (attr_reader 'sr', :sr2)
  end
  class SsBad
    $ss_bad = []
    [:"1x", :"a b", :"x?", :"X"].each { |n| $ss_bad << n }
    begin; attr_reader :"1x"; rescue => e; $ss_bad << [:r, e.class, e.message]; end
    begin; attr_writer :"a b"; rescue => e; $ss_bad << [:w, e.class, e.message]; end
    begin; attr_accessor :"x?"; rescue => e; $ss_bad << [:a, e.class, e.message]; end
    begin; attr_reader 3; rescue => e; $ss_bad << [:t, e.class]; end
    begin; include Integer; rescue => e; $ss_bad << [:i, e.class]; end
    begin; include 3; rescue => e; $ss_bad << [:i2, e.class]; end
  end
  class SsFrozen
    freeze
    $ss_frozen = []
    begin; attr_reader :fz; rescue => e; $ss_frozen << [:r, e.class]; end
    begin; attr_accessor :fz; rescue => e; $ss_frozen << [:a, e.class]; end
    begin; include SsA; rescue => e; $ss_frozen << [:i, e.class]; end
  end
RUBY

OWNERS = %w[SsMix SsBox SsKid SsHook SsA SsB SsOrder SsVis SsRet SsBad SsFrozen].freeze

code = suite.generate(SRC, OWNERS)
suite.check('include and attr_* call their own helpers', code.scan('bc2cpp_mod_include(M, self, ').size >= 5 &&
                                                       code.scan('bc2cpp_mod_attr(M, self, ').size >= 10)
suite.check('no include or attr_* goes by name', code.scan(/bc2cpp_ssend\(M, self, mrb_intern_cstr\(M, "(?:include|attr\w*)"/).empty?)
suite.check('the helpers make no by-name send of include or attr_*', !code[/bc2cpp_mod_attr\(.*?\n    \}\n/m].to_s.include?('funcall'))
suite.check('no site keeps its own by-name argument array', !code.include?('bc2cpp_ssend_args'))

DRIVER = <<~'RUBY'
  b = SsBox.new
  b.x = 7
  b.y = :y
  b.w = 9
  puts [b.a, b.b, b.x, b.y, b.w_value, b.mixed].inspect
  puts SsBox.include?(SsMix).inspect
  puts "H:#{SsMix.log.size}"
  puts SsMix.log.uniq.inspect
  k = SsKid.new
  k.z = 5
  k.x = 1
  puts [k.z, k.x, k.a, k.mixed].inspect
  puts SsKid.instance_methods(false).sort.inspect
  puts SsBox.instance_methods(false).sort.inspect
  begin; b.w; rescue NoMethodError => e; puts "NoMethodError"; end
  puts SsOrder.ancestors.take(5).inspect
  puts "H:#{SsHook.log.size}"
  puts SsHook.log.uniq.inspect
  puts SsOrder.new.then { |o| [o.a_m, o.b_m, o.hooked] }.inspect
  puts $ss_ret.inspect, $ss_str.inspect
  puts $ss_bad.inspect
  puts $ss_frozen.inspect
  puts SsVis.public_instance_methods(false).sort.inspect
  puts SsVis.private_instance_methods(false).sort.inspect
  puts SsVis.protected_instance_methods(false).sort.inspect
  v = SsVis.new
  puts v.peek.inspect, v.cmp(SsVis.new).inspect
  puts [v.respond_to?(:pub), v.respond_to?(:pv), v.respond_to?(:pt)].inspect
  begin; v.pt; rescue NoMethodError => e; puts "pt: #{e.message}"; end
  begin; v.pv = 1; rescue NoMethodError => e; puts "pv=: #{e.message}"; end
  puts [:pa, :pub, :r1, :r3=, :x=].map { |m| (SsBox.instance_method(m).arity rescue (SsVis.instance_method(m).arity rescue SsRet.instance_method(m).arity)) }.inspect
  puts SsRet.instance_method(:r3=).arity, SsRet.instance_method(:r1).arity
  puts 'end'
RUBY

# The fixture VM loads the bytecode (running every class body once) and then gem_init runs the compiled unit, so a compiled
# run fires each hook exactly twice what the interpreter does; the closed build has no bytecode load. The "H:" counts pin
# once per run of the body, the rest must print the same.
suite.behaviour(DRIVER, same: false, diff: false) do |interpreted, compiled|
  plain = ->(lines) { lines.reject { |l| l.start_with?('H:') } }
  count = ->(lines) { lines.grep(/\AH:/).map { |l| l[2..].to_i } }
  suite.check('interpreted and compiled runs print the same', plain.(interpreted) == plain.(compiled))
  suite.check('the interpreter fires each included hook once', count.(interpreted) == [1, 2])
  suite.check('the compiled body fires each included hook once per run of the body', count.(compiled) == [2, 4])
end
suite.finish
