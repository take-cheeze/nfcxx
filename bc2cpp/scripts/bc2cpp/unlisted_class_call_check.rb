#!/usr/bin/env ruby
# frozen_string_literal: true

# UNLISTED_CLASS_CALL (docs/adr/0297, 0252, 0259): the exact-class arm of a guard chain for a definer
# class the chain cannot list resolves what mruby's lookup finds from that class instead of
# dispatching by name:
#   - an attr_reader/attr_writer (on the class or inherited) is a direct ivar access;
#   - a private def reached by an implicit/`self.` receiver (SSEND) is a direct call, by an explicit
#     receiver (SEND) the NoMethodError vm.c raises, without running the method;
#   - a class whose lookup chain holds no definition (listed only by simple-name ancestry) raises
#     the NoMethodError bc2cpp_nomethod does;
#   - a name the RGSS natives also register is judged on the class's own chain, not globally.
# Anything the proof cannot cover (protected, an alias/undef/define_method/visibility change, a
# method_missing class, a singleton or prepended definer, ...) keeps the dispatch.
#
# 1. With MRBC: generated code, a positive world and one negative world per withdrawal.
# 2. With MRBC, g++ and a mruby build: the same fixtures on real mruby, interpreted and compiled,
#    must answer alike (values, exception classes and messages) and the compiled arms must make
#    no dynamic dispatch. Builds: BC2CPP_MRUBY_FULL / BC2CPP_FULL_BUILD_DIR (full-core),
#    BC2CPP_MRUBY_CORE (core only), BC2CPP_MRUBY_FULL32 + BC2CPP_MRBC32 (32-bit mrb_int).
# 3. UCC_MUTANTS=1 (needs 1): the generator with one proof removed at a time must fail a check.
#
# Usage: MRBC=path/to/mrbc [BC2CPP_MRUBY_CORE=dir] [BC2CPP_MRUBY_FULL=dir] ruby scripts/bc2cpp/unlisted_class_call_check.rb

require 'fileutils'
require 'tmpdir'

failures = []
check = lambda do |what, condition|
  puts "  #{condition ? 'ok  ' : 'FAIL'} #{what}"
  failures << what unless condition
end

unless ENV['MRBC']
  puts '  SKIP: set MRBC (a host mrbc built from the patched 3rd/mruby)'
  exit 0
end

require_relative 'fixture_runtime'
runtime = Bc2cppFixtureRuntime
body_of = lambda do |code, fn|
  code[/^mrb_value #{fn}_impl\(mrb_state\* M.*?(?=^(?:static )?mrb_value \w+\(mrb_state\* M|\z)/m].to_s
end
sym_names = ->(code) { code[/bc2cpp_sym_names\[\d+\] = \{(.*?)\};/m, 1].to_s.scan(/"((?:[^"\\]|\\.)*)"/).flatten }
# By-name bc2cpp_send sites of `name` inside one body.
sends_of = lambda do |code, body, name|
  # A checked send (ADR 0299) has a slot of its own, so count every slot spelling the name.
  indices = sym_names.call(code).each_index.select { |i| sym_names.call(code)[i] == name }
  indices.sum { |index| body.scan(/bc2cpp_send\(M, [^,]+, #{index},/).size }
end
arm = ->(body, kind, klass) { body.match?(/UNLISTED_CLASS_#{kind} [^\n]*\(receiver exactly #{Regexp.escape(klass)}[,)]/) }

# Compiled owners: everything but the harness, which stays interpreted so it can build objects.
OWNERS = %w[UcState UcShop UcShopKid UcShopOver UcEmb UcEmbKid UcPriv UcPrivKid UcProt UcPrivPub UcGame::Battle
            UcScene::Battle UcScene3::Battle UcMixin UcMixA UcMixB UcMixC UcMixBase UcMixKid UcLvlA UcLvlB UcLvlAttr
            UcLvlAttrKid UcDriver].freeze

WORLD = <<~'RUBY'
  # The traced receiver class: its chain lists only UcState, every other definer is an unlisted arm.
  class UcState
    attr_accessor :coin
    attr_reader :secret
    def initialize; @coin = :state; @secret = :statesecret; end
    def battle_id; :state; end
  end
  # attr on the exact class (never assigned: the ivar reads nil), inherited, and overridden by a subclass.
  class UcShop
    attr_accessor :coin
  end
  class UcShopKid < UcShop
  end
  class UcShopOver < UcShop
    def coin; :over; end
  end
  # An ivar stored in the class's own struct.
  class UcEmb
    attr_accessor :coin
    def initialize; @coin = :emb; end
  end
  class UcEmbKid < UcEmb
  end
  # private def, inherited private def, protected, and a public def of the same name.
  class UcPriv
    def initialize; @secret = :ivar; end
    private
    def secret; :secret; end
  end
  class UcPrivKid < UcPriv
  end
  class UcProt
    protected
    def secret; :never; end
  end
  class UcPrivPub
    def secret; :pub; end
  end
  # UcScene3::Battle < UcScene::Battle shares its simple name with UcGame::Battle, which the
  # simple-name ancestry then counts as a parent that answers battle_id.
  module UcGame
    class Battle
      def battle_id; :game; end
    end
  end
  module UcScene
    class Battle
    end
  end
  module UcScene3
    class Battle < UcScene::Battle
    end
  end
  # Implicit-self and `self.` sends of a private def from a module, one class with a mixin in the way.
  module UcMixin
    def run; mix_value; end
    def dot; self.mix_value; end
  end
  module UcTrick
  end
  class UcMixBase
    include UcMixin
    private
    def mix_value; :base; end
  end
  class UcMixKid < UcMixBase
    include UcTrick
  end
  class UcMixA
    include UcMixin
    private
    def mix_value; :mixa; end
  end
  class UcMixB
    include UcMixin
    def mix_value; :mixb; end
  end
  class UcMixC
    include UcMixin
    def mix_value(a, b = 2); [a, b]; end
  end
  # An attr_reader called with an argument: the ArgumentError the argument check raises.
  class UcLvlA
    def lvl(a); [:a, a]; end
  end
  class UcLvlB
    def lvl(a); [:b, a]; end
  end
  class UcLvlAttr
    attr_accessor :lvl
  end
  class UcLvlAttrKid < UcLvlAttr
  end
  class UcDriver
    def initialize; @state = UcState.new; @states = [UcState.new]; end
    def read; @state.coin; end
    def write(v); @state.coin = v; end
    def sec; @state.secret; end
    def sec_args; @state.secret(1, 2); end
    def bid; @state.battle_id; end
    def call_lvl(x); x.lvl(5); end
    # INLINED_UNLISTED_SITE (ADR 0386): the same send inside an inlined `each` body, whose site has no idx.
    def sec_each; r = nil; @states.each { |s| r = s.secret }; r; end
  end
  # Objects and exceptions, built by interpreted code only.
  class UcRun
    def self.one
      yield
    rescue Exception => e
      [e.class, e.message]
    end
    def self.filled(o)
      o.coin = :set
      o
    end
    def self.state_obj(i)
      return UcState.new if i == 0
      return UcShop.new if i == 1
      return filled(UcShop.new) if i == 2
      return filled(UcShop.new).freeze if i == 3
      return UcShopKid.new if i == 4
      return UcShopOver.new if i == 5
      return UcEmb.new if i == 6
      return UcEmbKid.new if i == 7
      return filled(UcEmb.new).freeze if i == 8
      return UcPriv.new if i == 9
      return UcPrivKid.new if i == 10
      return UcProt.new if i == 11
      return UcPrivPub.new if i == 12
      return UcGame::Battle.new if i == 13
      return UcScene3::Battle.new if i == 14
      return UcScene::Battle.new if i == 15
      return Object.new if i == 16
      return nil if i == 17
      return 42 if i == 18
      return UcState.new.freeze if i == 19
      return UcShopKid.new.freeze if i == 20
      nil
    end
    def self.mix_obj(i)
      return UcMixBase.new if i == 0
      return UcMixKid.new if i == 1
      return UcMixA.new if i == 2
      return UcMixB.new if i == 3
      return UcMixC.new if i == 4
      nil
    end
    def self.lvl_obj(i)
      return UcLvlA.new if i == 0
      return UcLvlB.new if i == 1
      return UcLvlAttr.new if i == 2
      return UcLvlAttrKid.new if i == 3
      return Object.new if i == 4
      nil
    end
  end
RUBY
STATE_OBJECTS = 21
MIX_OBJECTS = 5
LVL_OBJECTS = 5

# The scenario below sets @state from C++; the closed world must scan it as a native source,
# or the class pools (ADR 0296) prove UcDriver#@state is always UcState.
SCENARIO = <<~'CPP'
  static void call_msg(mrb_state* M, const char* label, mrb_value obj, const char* meth, int argc, const mrb_value* argv) {
    dispatches = 0;
    mrb_value r = (mrb_funcall_argv)(M, obj, mrb_intern_cstr(M, meth), argc, argv);
    int made = dispatches;
    if (M->exc) {
      mrb_value e = mrb_obj_value(M->exc);
      M->exc = nullptr;
      mrb_value msg = (mrb_funcall)(M, e, "message", 0);
      std::printf("%s => raised %s: %.*s\n", label, mrb_obj_classname(M, e), (int)RSTRING_LEN(msg), RSTRING_PTR(msg));
    } else {
      show(M, label, r);
    }
    if (compiled) std::printf("  dispatches=%d\n", made);
  }
  static mrb_value make(mrb_state* M, const char* fn, int i) {
    mrb_value a = mrb_fixnum_value(i);
    mrb_value r = (mrb_funcall_argv)(M, mrb_obj_value(mrb_class_get(M, "UcRun")), mrb_intern_cstr(M, fn), 1, &a);
    mrb_gc_protect(M, r);
    return r;
  }
  static int scenario(mrb_state* M) {
    mrb_value driver = mrb_obj_new(M, mrb_class_get(M, "UcDriver"), 0, nullptr);
    mrb_gc_protect(M, driver);
    mrb_value w = mrb_symbol_value(mrb_intern_lit(M, "w"));
    char label[64];
    for (int i = 0; i < STATE_OBJECTS; ++i) {
      // The kept by-name send is mrb_funcall, which ignores `protected` (it answers where the VM raises).
      if (i == PROTECTED_OBJECT) continue;
      mrb_value o = make(M, "state_obj", i);
      mrb_iv_set(M, driver, mrb_intern_lit(M, "@state"), o);
      std::snprintf(label, sizeof label, "s%d.read", i);  call_msg(M, label, driver, "read", 0, nullptr);
      std::snprintf(label, sizeof label, "s%d.write", i); call_msg(M, label, driver, "write", 1, &w);
      std::snprintf(label, sizeof label, "s%d.read2", i); call_msg(M, label, driver, "read", 0, nullptr);
      std::snprintf(label, sizeof label, "s%d.sec", i);   call_msg(M, label, driver, "sec", 0, nullptr);
      std::snprintf(label, sizeof label, "s%d.bid", i);   call_msg(M, label, driver, "bid", 0, nullptr);
      mrb_iv_set(M, driver, mrb_intern_lit(M, "@states"), mrb_ary_new_from_values(M, 1, &o));
      std::snprintf(label, sizeof label, "s%d.each", i);  call_msg(M, label, driver, "sec_each", 0, nullptr);
    }
    for (int i = 0; i < MIX_OBJECTS; ++i) {
      mrb_value o = make(M, "mix_obj", i);
      std::snprintf(label, sizeof label, "m%d.run", i); call_msg(M, label, o, "run", 0, nullptr);
      std::snprintf(label, sizeof label, "m%d.dot", i); call_msg(M, label, o, "dot", 0, nullptr);
    }
    for (int i = 0; i < LVL_OBJECTS; ++i) {
      mrb_value o = make(M, "lvl_obj", i);
      std::snprintf(label, sizeof label, "l%d.lvl", i); call_msg(M, label, driver, "call_lvl", 1, &o);
    }
    return 0;
  }
CPP
HARNESS = [['scenario.cpp', SCENARIO]].freeze

# -- 1. generated code ---------------------------------------------------------------------------

puts '-- generated code, positive closed world'
Dir.mktmpdir do |dir|
  code, = runtime.generate(WORLD, dir, only_owners: OWNERS, native: HARNESS)
  read = body_of.call(code, 'UcDriver_read')
  write = body_of.call(code, 'UcDriver_write')
  sec = body_of.call(code, 'UcDriver_sec')
    bid = body_of.call(code, 'UcDriver_bid')
  lvl = body_of.call(code, 'UcDriver_call_lvl')
  each = body_of.call(code, 'UcDriver_sec_each')
  check.call('the driver methods are compiled', [read, write, sec, bid, lvl].none?(&:empty?))
  check.call('an attr_reader on an exact class is a direct ivar read (unset reads nil through mrb_iv_get)',
             arm.call(read, 'ACCESSOR', 'UcShop') && read.include?('mrb_iv_get(M,') && !read.include?('kept: unlisted_class'))
  check.call('an inherited attr_reader is a direct read for the subclass too',
             arm.call(read, 'ACCESSOR', 'UcShopKid') && read.match?(/receiver exactly UcShopKid\), attr_reader/))
  check.call('an attr_writer is a direct mrb_iv_set (which is what raises FrozenError)',
             arm.call(write, 'ACCESSOR', 'UcShop') && write.include?('mrb_iv_set(M,'))
  check.call('an embedded ivar goes through the owner\'s synthesized accessor, for the subclass as well',
             read.match?(/r2 = UcEmb_coin_impl\(M, r2\);/) && arm.call(read, 'ACCESSOR', 'UcEmb') && arm.call(read, 'ACCESSOR', 'UcEmbKid') &&
               write.match?(/UcEmb_coin_eq_impl\(M, r\d+, r\d+\);/))
  check.call('a subclass override is still dispatched to its own body (the guard is the exact class)',
             arm.call(read, 'CALL', 'UcShopOver') && read.include?('UcShopOver_coin_impl(M, r2);') &&
               !arm.call(read, 'ACCESSOR', 'UcShopOver'))
  check.call('no by-name send of coin is left in the reader and the writer',
             sends_of.call(code, read, 'coin').zero? && sends_of.call(code, write, 'coin=').zero?)
  check.call('a private def called with an explicit receiver raises the NoMethodError OP_SEND raises, without dispatch',
             arm.call(sec, 'PRIVATE', 'UcPriv') && arm.call(sec, 'PRIVATE', 'UcPrivKid') &&
               sec.scan("mrb_no_method_error(M, bc2cpp_mid, mrb_ary_new(M), \"private method '%n' called for %T\"").size == 2 &&
               !sec.include?('kept:'))
  check.call('a public def of the same name is a direct call, a protected one keeps the dispatch',
             arm.call(sec, 'CALL', 'UcPrivPub') && sends_of.call(code, sec, 'secret') == 1 && !arm.call(sec, 'CALL', 'UcProt') &&
               !arm.call(sec, 'PRIVATE', 'UcProt'))
  check.call('a class whose chain holds no definition (simple-name ancestry only) raises the nomethod error',
             arm.call(bid, 'NO_TARGET', 'UcScene3::Battle') && arm.call(bid, 'CALL', 'UcGame::Battle') &&
               bid.scan('bc2cpp_nomethod(M, r2').size == 2 && sends_of.call(code, bid, 'battle_id').zero?)
  check.call('an attr_reader called with an argument raises the ArgumentError of its argument check',
             arm.call(lvl, 'ACCESSOR', 'UcLvlAttr') && lvl.include?('mrb_argnum_error(M, 1, 0, 0);') && sends_of.call(code, lvl, 'lvl').zero?)
  check.call('a private def reached through an inlined block body raises the OP_SEND NoMethodError without dispatch',
             !each.empty? && arm.call(each, 'PRIVATE', 'UcPriv') && arm.call(each, 'PRIVATE', 'UcPrivKid') &&
               sends_of.call(code, each, 'secret') == 1 && !arm.call(each, 'PRIVATE', 'UcProt') && !arm.call(each, 'CALL', 'UcProt'))
  [['run', 'implicit self'], ['dot', '`self.`']].each do |meth, what|
    body = body_of.call(code, "UcMixin_#{meth}")
    check.call("a private def reached by #{what} sends is a direct call for a class the chain cannot list",
               arm.call(body, 'CALL', 'UcMixKid') && body.include?('UcMixBase_mix_value_impl(M, self);') &&
                 sends_of.call(code, body, 'mix_value').zero?)
  end
end

# Kill switch: BC2CPP_INLINED_UNLISTED=0 keeps the by-name arm in an inlined block body (the site has no idx).
Dir.mktmpdir do |dir|
  saved_switch = ENV['BC2CPP_INLINED_UNLISTED']
  ENV['BC2CPP_INLINED_UNLISTED'] = '0'
  begin
    code, = runtime.generate(WORLD, dir, only_owners: OWNERS, native: HARNESS)
  ensure
    ENV['BC2CPP_INLINED_UNLISTED'] = saved_switch
  end
  off = body_of.call(code, 'UcDriver_sec_each')
  check.call('BC2CPP_INLINED_UNLISTED=0: the inlined body keeps its by-name arms, the direct sites are unchanged',
             !off.empty? && !arm.call(off, 'PRIVATE', 'UcPriv') && sends_of.call(code, off, 'secret') > 1 &&
               arm.call(body_of.call(code, 'UcDriver_sec'), 'PRIVATE', 'UcPriv'))
end

# Each world changes one thing that could give a receiver another answer; the affected arm is gone.
READER = %w[UcDriver_read].freeze
NEGATIVES = {
  'an alias_method of coin' => ["class UcShop; alias_method :coin, :hash; end\n", 'UcDriver_read', 'ACCESSOR', 'UcShop'],
  'an alias keyword of coin' => ["class UcShop; alias :coin :hash; end\n", 'UcDriver_read', 'ACCESSOR', 'UcShop'],
  'an undef_method of coin' => ["class UcShop; undef_method :coin; end\n", 'UcDriver_read', 'ACCESSOR', 'UcShop'],
  'a remove_method of coin' => ["class UcShop; remove_method :coin; end\n", 'UcDriver_read', 'ACCESSOR', 'UcShop'],
  'a define_method(:coin) next to the attr' => ["class UcShop; define_method(:coin) { 1 }; end\n", 'UcDriver_read', 'ACCESSOR', 'UcShop'],
  'a computed define_method' => ["class UcShop; n = \"co\" + \"in\"; define_method(n.to_sym) { 1 }; end\n", 'UcDriver_read', 'ACCESSOR', 'UcShop'],
  'a second def of coin on the class' => ["class UcShop; def coin; 7; end; end\n", 'UcDriver_read', 'ACCESSOR', 'UcShop'],
  'a singleton def of coin' => ["class UcShop; def self.coin; 1; end; end\n", 'UcDriver_read', 'ACCESSOR', 'UcShop'],
  'a singleton def on an instance' => ["UC_ONE = UcShop.new\ndef UC_ONE.coin; 9; end\n", 'UcDriver_read', 'ACCESSOR', 'UcShop'],
  'a class << instance block' => ["UC_TWO = UcShop.new\nclass << UC_TWO; def coin; 9; end; end\n", 'UcDriver_read', 'ACCESSOR', 'UcShop'],
  'a define_singleton_method' => ["UcShop.new.define_singleton_method(:coin) { 1 }\n", 'UcDriver_read', 'ACCESSOR', 'UcShop'],
  'a method_missing class' => ["class UcGhost; def method_missing(n, *a); 1; end; end\n", 'UcDriver_read', 'ACCESSOR', 'UcShop'],
  'a prepended module defining coin' => ["module UcPre; def coin; :pre; end; end\nclass UcShop; prepend UcPre; end\n", 'UcDriver_read', 'ACCESSOR', 'UcShop'],
  'an included module defining coin' => ["module UcInc; def coin; :inc; end; end\nclass UcShop; include UcInc; end\n", 'UcDriver_read', 'ACCESSOR', 'UcShop'],
  'an extend of an instance' => ["module UcExt; def coin; :ext; end; end\nUcShop.new.extend(UcExt)\n", 'UcDriver_read', 'ACCESSOR', 'UcShop'],
  'a Struct member named coin' => ["UcStruct = Struct.new(:coin)\n", 'UcDriver_read', 'ACCESSOR', 'UcShop'],
  'a Class.new generated class' => ["UcDyn = Class.new(UcShop) { def coin; 5; end }\n", 'UcDriver_read', 'ACCESSOR', 'UcShop'],
  'a private :coin on an inherited method' => ["class UcShopKid; private :coin; end\n", 'UcDriver_read', 'ACCESSOR', 'UcShopKid'],
  'a dynamic private' => ["UcShop.send(:private, :coin)\n", 'UcDriver_read', 'ACCESSOR', 'UcShop'],
  'a public :secret making the private def public' => ["class UcPriv; public :secret; end\n", 'UcDriver_sec', 'PRIVATE', 'UcPriv'],
  'a public :secret on the inherited private def' => ["class UcPrivKid; public :secret; end\n", 'UcDriver_sec', 'PRIVATE', 'UcPrivKid'],
  'a dynamic public' => ["UcPriv.send(:public, :secret)\n", 'UcDriver_sec', 'PRIVATE', 'UcPriv'],
  'an alias of the private secret' => ["class UcPriv; alias_method :secret, :to_s; end\n", 'UcDriver_sec', 'PRIVATE', 'UcPriv'],
  'a prepended module over the private def' => ["module UcPre; def secret; 1; end; end\nclass UcPriv; prepend UcPre; end\n", 'UcDriver_sec', 'PRIVATE', 'UcPriv'],
  'a singleton secret' => ["class UcPriv; def self.secret; 1; end; end\n", 'UcDriver_sec', 'PRIVATE', 'UcPriv'],
  'a mixin defining battle_id under the simple-name class' => ["module UcInc; def battle_id; 1; end; end\nclass UcScene3::Battle; include UcInc; end\n", 'UcDriver_bid', 'NO_TARGET', 'UcScene3::Battle'],
  'a battle_id on the class itself' => ["class UcScene3::Battle; def battle_id; 3; end; end\n", 'UcDriver_bid', 'NO_TARGET', 'UcScene3::Battle'],
  'an alias creating battle_id' => ["class UcScene3::Battle; alias_method :battle_id, :to_s; end\n", 'UcDriver_bid', 'NO_TARGET', 'UcScene3::Battle'],
  'a method_missing on the simple-name class' => ["class UcScene::Battle; def method_missing(n, *a); 1; end; end\n", 'UcDriver_bid', 'NO_TARGET', 'UcScene3::Battle']
}.freeze

puts '-- generated code, negative worlds keep the dispatch'
NEGATIVES.each do |what, (extra, method, kind, klass)|
  Dir.mktmpdir do |dir|
    code, = runtime.generate(WORLD + extra, dir, only_owners: OWNERS, native: HARNESS)
    body = body_of.call(code, method)
    check.call("#{what}: #{method} has no #{kind} arm for #{klass}", !body.empty? && !arm.call(body, kind, klass))
  end
end

# Sends that only call or probe a method change no method table: the arms stay.
CONTROLS = {
  'a public_send of the private def' => ["UcPriv.new.public_send(:secret) rescue nil\n", 'UcDriver_sec', 'PRIVATE', 'UcPriv'],
  'a send of the private def' => ["UcPriv.new.send(:secret)\n", 'UcDriver_sec', 'PRIVATE', 'UcPriv'],
  'a respond_to? probe of coin' => ["UcShop.new.respond_to?(:coin)\n", 'UcDriver_read', 'ACCESSOR', 'UcShop']
}.freeze
CONTROLS.each do |what, (extra, method, kind, klass)|
  Dir.mktmpdir do |dir|
    code, = runtime.generate(WORLD + extra, dir, only_owners: OWNERS, native: HARNESS)
    check.call("#{what}: #{method} keeps its #{kind} arm for #{klass}", arm.call(body_of.call(code, method), kind, klass))
  end
end

puts '-- generated code, open world'
Dir.mktmpdir do |dir|
  code, = runtime.generate(WORLD, dir, closed: false, only_owners: OWNERS)
  check.call('an open world has no UNLISTED_CLASS arm', !code.include?('UNLISTED_CLASS_'))
end

# A native-registered name is judged on the class's own chain: RGSS registers dispose, x, y ... on
# its classes, so UcScreenKid (no native class in its chain) may call it directly.
NATIVE_WORLD = <<~'RUBY'
  class UcScreen
    def dispose; :screen; end
  end
  module UcScreenTrick
  end
  class UcScreenKid < UcScreen
    include UcScreenTrick
  end
  class UcNativeDriver
    def initialize; @obj = UcScreen.new; end
    def go; @obj.dispose; end
  end
RUBY
puts '-- generated code, a name the RGSS natives register'
Dir.mktmpdir do |dir|
  code, = runtime.generate(NATIVE_WORLD, dir, only_owners: %w[UcScreen UcScreenKid UcNativeDriver])
  go = body_of.call(code, 'UcNativeDriver_go')
  check.call('a class whose chain holds no native definer is a direct call even though natives register the name',
             arm.call(go, 'CALL', 'UcScreenKid') && go.include?('UcScreen_dispose_impl(M, r2);'))
end

# The chain proof itself, over the real native sources: the registrations NativeDirect parses name the
# classes a native `dispose` can reach.
puts '-- the native chain proof'
require_relative '../../tools/bc2cpp/compiled_gems'
require_relative '../../tools/bc2cpp/construct_class_names'
require_relative '../../tools/bc2cpp/closed_world'
Dir.mktmpdir do
  root = File.expand_path('../..', __dir__)
  natives = Dir["#{root}/mruby-rgss/src/*.cxx"] + core_native_srcs("#{root}/3rd/mruby") + external_gem_native_srcs(root)
  decls = { 'UcA' => [{ super: :none, outer_nil: true }], 'UcB' => [{ super: 'UcA', outer_nil: true }],
            'RGSS::Sprite' => [{ super: :none, outer_nil: true }], 'UcS' => [{ super: 'RGSS::Sprite', outer_nil: true }] }
  world = ClosedWorld.new(ireps: {}, registry: Hash.new { |h, k| h[k] = [] }, class_decls: decls, walked: Set.new,
                          native_paths: natives, ruby_paths: [])
  safe = ->(name, klass, *chain) { world.exact_chain_lookup_safe?(name, klass, Set.new(chain + ['Object'])) }
  check.call('a name no native spells is safe on any chain', safe.call('unheard_of', 'UcA', 'UcA') && safe.call('unheard_of', 'UcS', 'UcS', 'RGSS::Sprite'))
  check.call('an RGSS-registered name is safe on a chain without its native class', safe.call('dispose', 'UcA', 'UcA') && safe.call('dispose', 'UcB', 'UcB', 'UcA'))
  check.call('and unsafe on the native class itself or a subclass of it',
             !safe.call('dispose', 'RGSS::Sprite', 'RGSS::Sprite') && !safe.call('dispose', 'UcS', 'UcS', 'RGSS::Sprite'))
  check.call('a name mruby core registers is never safe by this proof', !safe.call('to_s', 'UcA', 'UcA') && !safe.call('class', 'UcA', 'UcA'))
  check.call('a class that is not a declared stable class constant is refused', !safe.call('unheard_of', 'UcNope', 'UcNope'))
end

# -- 2. fixtures on real mruby -----------------------------------------------------------------


# label prefix => the compiled run must make exactly this many dynamic dispatches
NO_DISPATCH = %w[s1.read s1.write s2.read s2.write s3.read s4.read s4.write s5.write s6.read s7.read s9.sec s10.sec s9.each s10.each
                 s12.sec s13.bid m1.run m1.dot l2.lvl l3.lvl].freeze

builds = []
full = runtime.full || (ENV['BC2CPP_FULL_BUILD_DIR'] ? runtime.full_or_build : nil)
builds << ['mrb_int 64, full-core', full, true, ENV['MRBC'], ''] if full && runtime.compiler?
builds << ['mrb_int 64, core only', runtime.core, false, ENV['MRBC'], ''] if runtime.core && runtime.compiler?
if ENV['BC2CPP_MRUBY_FULL32'] && ENV['BC2CPP_MRBC32'] && runtime.compiler?
  builds << ['mrb_int 32, full-core', ENV['BC2CPP_MRUBY_FULL32'], true, ENV['BC2CPP_MRBC32'], '-DMRB_32BIT -DMRB_INT32 -no-pie']
end
builds.clear if ENV['UCC_GENERATED_ONLY']
puts '  SKIP run: set BC2CPP_MRUBY_FULL / BC2CPP_FULL_BUILD_DIR / BC2CPP_MRUBY_CORE and have g++' if builds.empty?

values = lambda do |sections, name|
  sections.fetch(name, []).reject { |l| l.start_with?('  ') }.map { |l| l.gsub(/0x\h+/, '0xADDR') }
end
run_world = lambda do |source, build, full_flag|
  Dir.mktmpdir do |dir|
    _code, err = runtime.generate(source, dir, closed: true, only_owners: OWNERS, native: HARNESS)
    scenario = "static const int STATE_OBJECTS = #{STATE_OBJECTS}, PROTECTED_OBJECT = 11, MIX_OBJECTS = #{MIX_OBJECTS}, LVL_OBJECTS = #{LVL_OBJECTS};\n#{SCENARIO}"
    built, output = runtime.run(dir, err, OWNERS, scenario, build: build, full: full_flag, exact_arity: true)
    puts output unless built
    built ? runtime.sections(output) : nil
  end
end

builds.each do |label, build, full_flag, mrbc, flags|
  puts "-- fixtures on real mruby (#{label}), interpreted and compiled"
  saved = ENV.values_at('MRBC', 'BC2CPP_CXXFLAGS')
  ENV['MRBC'] = mrbc
  ENV['BC2CPP_CXXFLAGS'] = flags
  begin
    sections = run_world.call(WORLD, build, full_flag)
    check.call('the fixture compiles and runs against real mruby', !sections.nil?)
    next unless sections

    interpreted = values.call(sections, 'interpreted')
    compiled = values.call(sections, 'compiled')
    expected = (STATE_OBJECTS - 1) * 6 + MIX_OBJECTS * 2 + LVL_OBJECTS
    # A core-only mruby has no Array#each (it lives in mrblib), so the interpreted run of the inlined-`each`
    # fixture cannot answer there; the compiled inlined body does. Those calls are compared on full-core builds.
    unless full_flag
      interpreted = interpreted.reject { |l| l.match?(/\As\d+\.each /) }
      compiled = compiled.reject { |l| l.match?(/\As\d+\.each /) }
      expected -= STATE_OBJECTS - 1
    end
    check.call("compiled answers what the interpreter answers (#{interpreted.size} calls)", interpreted.size == expected && interpreted == compiled)
    interpreted.zip(compiled).each { |i, c| puts "    interpreted: #{i[0, 300]}\n    compiled:    #{c.to_s[0, 300]}" unless i == c }
    text = interpreted.join("\n")
    # mrb_open_core has no usable exception messages (every raise reads "exception corrupted"): the
    # texts are checked on the full-core builds, the comparison above on all of them.
    if full_flag
      check.call('the private explicit-receiver NoMethodError text is the interpreter\'s own',
                 text.include?("s9.sec => raised NoMethodError: private method 'secret' called for") && text.include?('s10.sec => raised NoMethodError: private method'))
      check.call('an unset attr_reader reads nil; a frozen attr_writer receiver raises FrozenError',
                 text.include?('s1.read => nil') && text.include?('s3.write => raised FrozenError') && text.include?('s8.write => raised FrozenError'))
      check.call('the attr_reader called with an argument raises the interpreter\'s ArgumentError',
                 text.include?('l2.lvl => raised ArgumentError: wrong number of arguments (given 1, expected 0)'))
      check.call('the missing definition raises NoMethodError, the subclass override and the same-named public def answer',
                 text.include?('s14.bid => raised NoMethodError') && text.include?('s5.read => :over') && text.include?('s12.sec => :pub'))
      check.call('private defs answer an implicit or self. receiver',
                 text.include?('m1.run => :base') && text.include?('m1.dot => :base'))
    end
    per = sections.fetch('compiled', []).each_cons(2).select { |l, n| n.include?('dispatches=') }
                  .to_h { |l, n| [l[/\A\S+/], n[/dispatches=(\d+)/, 1].to_i] }
    check.call('the compiled arms make no dynamic dispatch', NO_DISPATCH.all? { |k| per[k]&.zero? })
    check.call('the sends no definer answers still go through the nomethod dispatch', per['s16.read'].to_i.positive?)
  ensure
    ENV['MRBC'], ENV['BC2CPP_CXXFLAGS'] = saved
  end
end

# The same fixture with a rebinding appended: the dispatch stays and still answers like the interpreter.
BEHAVIOUR_NEGATIVES = {
  'an alias of coin' => "class UcShop; alias_method :coin, :frozen?; end\n",
  'a public :secret' => "class UcPriv; public :secret; end\n",
  'a second coin def' => "class UcShop; def coin; 7; end; end\n",
  'a singleton def on an instance' => "UC_ONE = UcShop.new\ndef UC_ONE.coin; 9; end\n",
  'a method_missing class' => "class UcGhost; def method_missing(n, *a); 1; end; end\n"
}.freeze
builds.first(1).each do |label, build, full_flag, mrbc, flags|
  saved = ENV.values_at('MRBC', 'BC2CPP_CXXFLAGS')
  ENV['MRBC'] = mrbc
  ENV['BC2CPP_CXXFLAGS'] = flags
  begin
    BEHAVIOUR_NEGATIVES.each do |what, extra|
      sections = run_world.call(WORLD + extra, build, full_flag)
      # These four answers stay out of the comparison: the by-name send is checked by ADR 0299
      # (scripts/bc2cpp/checked_send_check.rb pins that), but this driver's @state holds several
      # classes behind a single traced one, so a devirtualized arm can still answer here.
      comparable = ->(name) { values.call(sections, name).reject { |l| l.start_with?('s9.sec', 's10.sec', 's9.each', 's10.each', 'l2.lvl', 'l3.lvl') } }
      same = !sections.nil? && comparable.call('interpreted').size.positive? && comparable.call('interpreted') == comparable.call('compiled')
      check.call("#{what} (#{label}): compiled answers what the interpreter answers", same)
      next if same || sections.nil?

      comparable.call('interpreted').zip(comparable.call('compiled')).each do |i, c|
        puts "    interpreted: #{i[0, 300]}\n    compiled:    #{c.to_s[0, 300]}" unless i == c
      end
    end
  ensure
    ENV['MRBC'], ENV['BC2CPP_CXXFLAGS'] = saved
  end
end

# -- 3. mutants ---------------------------------------------------------------------------------

# Each mutant removes one proof from a copy of the generator; the generated-code checks above
# (UCC_GENERATED_ONLY=1 skips the runs) must then fail. The chain gate has no mutant here: its call is
# only reachable for a reopened native class (the native-arm lift refuses it first), so the unit checks
# above pin exact_chain_lookup_safe? itself, and the 'any native registration' mutant breaks them.
MUTANTS = {
  'tools/bc2cpp/codegen_unlisted_class_call.rb' => {
    'a private def called with an explicit receiver is called' =>
      ["return unlisted_private_call(target, klass, name, d, recv, argv, site) unless unlisted_ssend?(site, name)\n", "\n"],
    'an inlined body site is not read' =>
      ["site && (site[:insn] || (CodeGen.inlined_unlisted_site? ? site[:trace_insn] : nil))", 'site && site[:insn]'],
    'a private def called implicitly is refused' =>
      ["!insn.nil? && insn.sym == name && insn.op.start_with?('SSEND')", 'false'],
    'a protected def is called' => ["    else\n      return nil\n    end\n    return nil if target.owner", "    end\n    return nil if target.owner"],
    'a missing definition is called as an attr' => ['return unlisted_no_target_error(klass, name, d, recv, argv, site) unless target', 'return nil unless target'],
    'the accessor argument count is not checked' => ['unless argv.size == arity', 'unless true']
  },
  'tools/bc2cpp/closed_world.rb' => {
    'any native registration is accepted' => ['!registered.nil? && registered.none? { |native_owner| chain.include?(native_owner) }', 'true'],
    'a dynamic visibility change is ignored' => ['!@global_refusal && !@dynamic_visibility && !@visibility_names.include?(name)', '!@global_refusal']
  }
}.freeze
if ENV['UCC_MUTANTS'] && ENV['UCC_GENERATED_ONLY'].nil?
  puts '-- mutants: one proof removed, a generated-code check must fail'
  require_relative 'mutant_pool'
  root = File.expand_path('../..', __dir__)
  # nil when the mutation does not apply, else the run of the check against the mutant.
  mutate = lambda do |(file, _what, from, to)|
    Dir.mktmpdir do |tmp|
      # A copy of the tree's code with the 3rd/ and gem directories linked.
      Dir.children(root).each do |entry|
        next if %w[.git tools scripts build].include?(entry)

        FileUtils.ln_s(File.join(root, entry), File.join(tmp, entry))
      end
      FileUtils.cp_r(File.join(root, 'tools'), tmp)
      FileUtils.cp_r(File.join(root, 'scripts'), tmp)
      path = File.join(tmp, file)
      text = File.read(path)
      mutated = text.sub(from, to)
      next nil if mutated == text

      File.write(path, mutated)
      # Stops at the first FAIL line: the mutant is caught (Bc2cppMutantPool.run).
      Bc2cppMutantPool.run({ 'UCC_GENERATED_ONLY' => '1', 'UCC_MUTANTS' => nil },
                           [RbConfig.ruby, File.join(tmp, 'scripts/bc2cpp/unlisted_class_call_check.rb')], stop_on: /^\s+FAIL /)
    end
  end
  jobs = MUTANTS.flat_map { |file, mutants| mutants.map { |what, (from, to)| [file, what, from, to] } }
  Bc2cppMutantPool.each_ordered(jobs, work: mutate) do |(_file, what), run|
    if run.nil?
      check.call("mutant (#{what}) applies", false)
    else
      check.call("mutant (#{what}) is caught", !run.success && run.out.include?('FAIL'))
    end
  end
end

puts(failures.empty? ? 'bc2cpp_unlisted_class_call_check OK' : "FAILED: #{failures.size}")
exit(failures.empty? ? 0 : 1)
