#!/usr/bin/env ruby
# frozen_string_literal: true

# RETURN_CLASS_TABLE and EXACT_TYPED (docs/adr/0289): a receiver that holds a fresh instance of
# one closed-world class on every path -- through a local, an ivar slot, or the result of a call
# whose name only ever returns such instances -- calls its target directly, with no class guard and
# no dynamic-send fallback. Everything else keeps the guarded TYPED arm.
#
# 1. Generated code of a closed-world fixture (needs MRBC): every positive shape must say
#    EXACT_TYPED, every negative one must keep the guard, and each way of losing the proof
#    (an alias, a runtime installer, a second definition of the name, a prepended module, a
#    method_missing class, a redefined `new`, a world that can make a singleton class) must
#    withdraw it.
# 2. On real mruby (needs MRBC, g++ and a full-core build: BC2CPP_MRUBY_FULL, or rake to build one
#    into BC2CPP_FULL_BUILD_DIR): the fixture runs interpreted and compiled and must answer alike,
#    including for the receivers a wrong proof would mis-dispatch (a method that returns either of
#    two classes, nil, a subclass).
#
# Usage: MRBC=path/to/mrbc [BC2CPP_MRUBY_FULL=dir] ruby scripts/bc2cpp/return_class_check.rb

require 'tmpdir'
require_relative 'fixture_runtime'

failures = []
check = lambda do |what, condition|
  puts "  #{condition ? 'ok  ' : 'FAIL'} #{what}"
  failures << what unless condition
end

unless ENV['MRBC']
  puts '  SKIP: set MRBC (the host mrbc); generated-code and behavioural checks need it'
  exit 0
end

runtime = Bc2cppFixtureRuntime

CLASSES = <<~RUBY
  class RcBox
    def initialize; @v = 0; end
    def bump(x); @v += x; end
    def val; @v; end
    def tag; :box; end
    def count; :cnt_box; end
    def handoff; RcOther.new; end
    def mixed_handoff(flag); flag ? RcOther.new : RcBox.new; end
  end

  class RcSub < RcBox
    def tag; :sub; end
    def count; :cnt_sub; end
  end

  class RcOther
    def bump(x); x * 10; end
    def val; 7; end
    def tag; :other; end
    def count; :cnt_other; end
    def handoff; RcBox.new; end
  end
RUBY

FX_OPEN = <<~RUBY
  class RcFx
    def make_box; RcBox.new; end
    def make_other; RcOther.new; end
    def make_sub; RcSub.new; end
    def forward_box; b = make_box; b; end
    def rec(n); n == 0 ? RcBox.new : rec(n - 1); end
    def make_rescued
      begin
        RcBox.new
      rescue ArgumentError
        RcBox.new
      end
    end
    def first_box(xs)
      xs.each { |x| return RcBox.new if x }
      RcBox.new
    end
    def make_mixed(f); f ? RcBox.new : RcOther.new; end
    def maybe(f); f ? RcBox.new : nil; end
    def pass(o); o; end
    def yielded; yield; end
    def set_c; @c = RcBox.new; end
    def helper; 1; end
    def make_ensured
      begin
        RcBox.new
      ensure
        @n = 1
      end
    end

    # -- exact: the receiver is one fresh class on every path
    def e_local; b = RcBox.new; b.tag; end
    def e_call; b = make_box; [b.bump(1), b.bump(2), b.val, b.tag]; end
    def e_chain; make_box.tag; end
    def e_scoped_chain_box; make_box.handoff.tag; end
    def e_scoped_chain_other; make_other.handoff.tag; end
    def e_scoped_inherited_chain; make_sub.handoff.tag; end
    def e_scoped_mixed_chain(flag); make_box.mixed_handoff(flag).tag; end
    def e_forward; b = forward_box; b.tag; end
    def e_recursive; rec(2).tag; end
    def e_rescue; make_rescued.tag; end
    def e_block_return(xs); first_box(xs).tag; end
    def e_ivar; @b = RcBox.new; @b.tag; end
    def e_sub; make_sub.tag; end
    def e_sub_inherited; make_sub.val; end
    def e_moved; b = make_box; c = b; c.tag; end
    # `count` is spelled by RGSS natives, so the closed-world lookup refuses it (CLOSED_WORLD_EXACT_CLASS)
    # and only the guard-free TYPED call can take the site.
    def e_typed; b = make_box; b.count; end
    def e_typed_ivar; @b = RcBox.new; @b.count; end

    # -- guarded: some path can hold another class (or nothing we can name)
    def g_mixed(f); make_mixed(f).tag; end
    def g_nil(f); maybe(f).tag; end
    def g_param(o); pass(o).tag; end
    def g_ivar_read; set_c; @c.tag; end
    def g_after_call; @b = RcBox.new; helper; @b.tag; end
    def g_yield; yielded { RcBox.new }.tag; end
    def g_reassigned(o); b = make_box; b = o; b.tag; end
    def g_branch(f); b = f ? make_box : make_other; b.tag; end
    def g_captured; b = make_box; 1.times { b = make_other }; b.tag; end
    def g_ensure; make_ensured.tag; end
    def g_typed(f); make_mixed(f).count; end
  end
RUBY

OWNERS = %w[RcBox RcSub RcOther RcFx RcMM RcPre RcDrv].freeze
EXACT = %w[e_local e_call e_chain e_scoped_chain_box e_scoped_chain_other e_scoped_inherited_chain e_forward e_recursive e_rescue
           e_block_return e_ivar e_sub e_sub_inherited e_moved e_typed e_typed_ivar].freeze
GUARDED = %w[g_mixed g_param g_ivar_read g_yield g_reassigned g_branch g_captured g_ensure g_typed].freeze
# ADR 0356: `g_after_call` writes `@b = RcBox.new`, calls `helper` (which cannot touch `@b`) and
# reads `@b.tag`. The readonly-call proof keeps the ivar slot alive across the call, so the
# read becomes a guard-free CLOSED_WORLD_EXACT_CLASS. It was a GUARDED case before that proof
# and is exact after it; the runtime section below still pins its value.
READONLY_IVAR = %w[g_after_call].freeze
# The sends that go through the table (the others in EXACT are the fresh `.new` of the same proof).
TABLE_ONLY = %w[e_call e_chain e_forward e_recursive e_rescue e_block_return e_sub e_sub_inherited e_moved e_typed].freeze

body_of = lambda do |code, fn|
  code[/^mrb_value RcFx_#{fn}_impl\(mrb_state\* M.*?(?=^(?:static )?mrb_value \w+\(mrb_state\* M|\z)/m].to_s
end
# Either guard-free form: the closed-world lookup, or the TYPED call for a name it refuses.
EXACT_TAG = /(?:EXACT_TYPED|CLOSED_WORLD_EXACT_CLASS) :\w+[?!]? /
exact = ->(code, fn) { body_of.call(code, fn).match?(EXACT_TAG) }
guarded = ->(code, fn) { body = body_of.call(code, fn); !body.empty? && !body.match?(EXACT_TAG) }

generate = lambda do |source, dir, closed: true|
  runtime.generate(source, dir, closed: closed, only_owners: OWNERS)
end

Dir.mktmpdir do |dir|
  code, err = generate.call(CLASSES + FX_OPEN, dir)

  EXACT.each do |fn|
    check.call("#{fn}: a guard-free direct call", exact.call(code, fn) &&
                 !body_of.call(code, fn).match?(/runtime-class-checked direct C\+\+ call/))
  end
  GUARDED.each do |fn|
    check.call("NEG #{fn}: keeps its guard or its dispatch", guarded.call(code, fn))
  end
  # ADR 0356's readonly-call proof, on the case it newly frees. With the proof off the read
  # falls back to the guarded form the other NEG cases keep, so both directions are pinned.
  READONLY_IVAR.each do |fn|
    enabled = ENV['BC2CPP_READONLY_CALL_EFFECTS'] != '0'
    check.call("#{fn}: the readonly call keeps the ivar slot (#{enabled ? 'exact' : 'guarded'})",
               enabled ? exact.call(code, fn) : guarded.call(code, fn))
  end
  # nil-or-one-class (ADR 0296): one nil test, and the non-nil path is the exact call.
  check.call('g_nil: a nil-or-one-class result takes a nil test and a guard-free call',
             body_of.call(code, 'g_nil').include?('NILABLE_RECEIVER :tag') && exact.call(code, 'g_nil') &&
               !body_of.call(code, 'g_nil').include?('runtime-class-checked direct C++ call'))
  check.call('the exact sends call the owner\'s body directly',
             body_of.call(code, 'e_call').scan(/EXACT_CLASS :bump -> RcBox#bump/).size == 2 &&
               body_of.call(code, 'e_sub').include?('EXACT_CLASS :tag -> RcSub#tag') &&
               body_of.call(code, 'e_sub_inherited').include?('EXACT_CLASS :val -> RcBox#val'))
  check.call('receiver-scoped returns carry distinct results through an ambiguous method name',
             body_of.call(code, 'e_scoped_chain_box').include?('EXACT_CLASS :handoff -> RcBox#handoff') &&
               body_of.call(code, 'e_scoped_chain_box').include?('EXACT_CLASS :tag -> RcOther#tag') &&
               body_of.call(code, 'e_scoped_chain_other').include?('EXACT_CLASS :handoff -> RcOther#handoff') &&
               body_of.call(code, 'e_scoped_chain_other').include?('EXACT_CLASS :tag -> RcBox#tag') &&
               body_of.call(code, 'e_scoped_inherited_chain').include?('EXACT_CLASS :handoff -> RcBox#handoff') &&
               body_of.call(code, 'e_scoped_inherited_chain').include?('EXACT_CLASS :tag -> RcOther#tag') &&
               !err.include?('RETCLASS handoff '))
  check.call('a receiver-specific method with mixed return classes does not prove the next receiver',
             !body_of.call(code, 'e_scoped_mixed_chain').include?('EXACT_CLASS :tag ->'))
  unrelated_foreign = "class RcUnrelated; def handoff; RcBox.new; end; end\n"
  foreign_dir = File.join(dir, 'unrelated_foreign')
  Dir.mkdir(foreign_dir)
  foreign_code, = runtime.generate(CLASSES + FX_OPEN, foreign_dir, only_owners: OWNERS,
                                   foreign: [['outside.rb', unrelated_foreign]])
  check.call('an outside Ruby definition on an unrelated class keeps the receiver-scoped chain exact',
             body_of.call(foreign_code, 'e_scoped_chain_box').include?('EXACT_CLASS :handoff -> RcBox#handoff') &&
               body_of.call(foreign_code, 'e_scoped_chain_box').include?('EXACT_CLASS :tag -> RcOther#tag'))
  native_other = <<~'C'
    static mrb_value rc_other_handoff(mrb_state* M, mrb_value self) { return self; }
    void rc_other_init(mrb_state* M) {
      struct RClass *owner = mrb_define_class(M, "RcNativeOther", M->object_class);
      mrb_define_method(M, owner, "handoff", rc_other_handoff, MRB_ARGS_NONE());
    }
  C
  native_dir = File.join(dir, 'unrelated_native')
  Dir.mkdir(native_dir)
  native_code, = runtime.generate(CLASSES + FX_OPEN, native_dir,
                                  only_owners: OWNERS, native: [['unrelated.c', native_other]])
  check.call('a known native registration on an unrelated class keeps the receiver-scoped chain exact',
             body_of.call(native_code, 'e_scoped_chain_box').include?('EXACT_CLASS :handoff -> RcBox#handoff') &&
               body_of.call(native_code, 'e_scoped_chain_box').include?('EXACT_CLASS :tag -> RcOther#tag'))
  unknown_native = 'void rc_unknown_init(mrb_state* M, struct RClass *owner) { mrb_define_method(M, owner, "handoff", body, MRB_ARGS_NONE()); }'
  unknown_dir = File.join(dir, 'unknown_native')
  Dir.mkdir(unknown_dir)
  unknown_code, = runtime.generate(CLASSES + FX_OPEN, unknown_dir,
                                   only_owners: OWNERS, native: [['unknown.c', unknown_native]])
  check.call('a native registration with an unresolved owner withdraws the receiver-scoped chain',
             !body_of.call(unknown_code, 'e_scoped_chain_box').include?('EXACT_CLASS :handoff'))
  native_same_owner = <<~'C'
    static mrb_value rc_box_handoff(mrb_state* M, mrb_value self) { return self; }
    void rc_box_init(mrb_state* M) {
      struct RClass *owner = mrb_class_get_id(M, MRB_SYM(RcBox));
      mrb_define_method(M, owner, "handoff", rc_box_handoff, MRB_ARGS_NONE());
    }
  C
  same_owner_dir = File.join(dir, 'same_owner_native')
  Dir.mkdir(same_owner_dir)
  same_owner_code, = runtime.generate(CLASSES + FX_OPEN, same_owner_dir,
                                      only_owners: OWNERS, native: [['same_owner.c', native_same_owner]])
  check.call('a known native registration on the receiver ancestry withdraws its scoped chain',
             !body_of.call(same_owner_code, 'e_scoped_chain_box').include?('EXACT_CLASS :handoff'))
  saved_call_facts = ENV['BC2CPP_CALL_FACTS']
  begin
    ENV['BC2CPP_CALL_FACTS'] = '0'
    disabled_dir = File.join(dir, 'call_facts_disabled')
    Dir.mkdir(disabled_dir)
    disabled_code, = runtime.generate(CLASSES + FX_OPEN, disabled_dir, only_owners: OWNERS)
    check.call('the call-facts kill switch withdraws receiver-scoped exact lookup',
               !body_of.call(disabled_code, 'e_scoped_chain_box').include?('EXACT_CLASS :handoff'))
  ensure
    ENV['BC2CPP_CALL_FACTS'] = saved_call_facts
  end
  d = File.join(dir, 'scoped_runtime_definition')
  Dir.mkdir(d)
  scoped_code, = generate.call(CLASSES + FX_OPEN +
                               "class RcBox\n  define_method(:handoff) { RcBox.new }\nend\n", d)
  check.call('a runtime-installed class-specific method keeps the ambiguous chain dynamic',
             !body_of.call(scoped_code, 'e_scoped_chain_box').include?('EXACT_CLASS :handoff'))
  check.call('a name an RGSS native also spells takes a guard-free call from the table and an ivar slot',
             body_of.call(code, 'e_typed').match?(/(?:EXACT_TYPED|EXACT_CLASS) :count -> RcBox#count/) &&
               body_of.call(code, 'e_typed_ivar').match?(/(?:EXACT_TYPED|EXACT_CLASS) :count -> RcBox#count/) &&
               body_of.call(code, 'g_typed').include?(ENV['BC2CPP_USER_RECEIVER_UNIONS'] == '0' ? 'POLY_SMALL_N :count' : 'USER_RECEIVER_CASES :count') &&
               !body_of.call(code, 'g_typed').include?('EXACT_TYPED'))
  check.call('the exact send leaves no guard: no owner-class comparison in an exact-only body',
             !body_of.call(code, 'e_chain').include?('mrb_obj_class(M, r'))
  check.call('the diagnostic lists the names the table proves exact',
             %w[make_box make_sub forward_box rec make_rescued first_box].all? { |n| err.include?("RETCLASS #{n} ") } &&
               %w[make_mixed maybe pass yielded make_ensured].none? { |n| err.include?("RETCLASS #{n} ") })
  check.call('a name that returns two classes is not exact, a nil-or-one-class name is not either',
             !err.include?('RETCLASS make_mixed ') && !err.include?('RETCLASS maybe '))

  # Global summaries withdraw; an exact lexical receiver can still select its
  # own unchanged body when only an unrelated lookup gains a definition.
  variants = {
    'alias_method on the name' => "class RcFx\n  alias_method :make_box_alias, :make_box\nend\n",
    'define_method of the name' => "class RcFx\n  define_method(:make_box) { RcOther.new }\nend\n",
    'a second definition of the name in another class' => "class RcOther\n  def make_box; RcOther.new; end\nend\n",
    'a prepended module defining the name' => "module RcPre\n  def make_box; RcOther.new; end\nend\nclass RcFx\n  prepend RcPre\nend\n",
    'a method_missing class' => "class RcMM\n  def method_missing(n, *a); 1; end\nend\n",
    'a singleton make_box on a class' => "class RcFx\n  def self.make_box; RcOther.new; end\nend\n"
  }
  variants.each do |what, extra|
    d = File.join(dir, what.gsub(/\W+/, '_'))
    Dir.mkdir(d)
    vcode, verr = generate.call(CLASSES + FX_OPEN + extra, d)
    check.call("#{what} withdraws the table's proof for the name", !verr.include?('RETCLASS make_box '))
    scoped_safe = ENV['BC2CPP_CALL_CONTEXT_RESULTS'] != '0' &&
                  ['a second definition of the name in another class', 'a method_missing class', 'a singleton make_box on a class'].include?(what)
    check.call("#{what}: lexical receiver follows its own lookup",
               %w[e_call e_chain e_forward].all? { |fn| exact.call(vcode, fn) == scoped_safe })
    check.call("#{what} leaves the fresh `Klass.new` shape exact", exact.call(vcode, 'e_local'))
  end

  # A redefined `new` (or allocate) makes `RcBox.new` more than a constructor: nothing is exact.
  d = File.join(dir, 'new')
  Dir.mkdir(d)
  ncode, nerr = generate.call(CLASSES + FX_OPEN + "class RcBox\n  def self.new(*a); RcOther.new; end\nend\n", d)
  check.call('a redefined RcBox.new withdraws every RcBox proof',
             %w[e_local e_call e_chain e_ivar].none? { |fn| exact.call(ncode, fn) } && !nerr.include?('RETCLASS make_box '))

  # A world where an object can gain a singleton class proves nothing through the flow.
  [['singleton_class', "class RcFx\n  def maker(o); o.singleton_class; end\nend\n"],
   ['instance_eval', "class RcFx\n  def maker(o); o.instance_eval { 1 }; end\nend\n"],
   ['a def on an object', "class RcFx\n  def maker; a = [1]; def a.other(*); 'x'; end; a; end\nend\n"]].each_with_index do |(what, extra), i|
    d = File.join(dir, "maker#{i}")
    Dir.mkdir(d)
    mcode, merr = generate.call(CLASSES + FX_OPEN + extra, d)
    check.call("#{what} withdraws the table and the flow", TABLE_ONLY.none? { |fn| exact.call(mcode, fn) } && !merr.include?('RETCLASS '))
  end

  # Nothing is proven without the closed world.
  d = File.join(dir, 'open')
  Dir.mkdir(d)
  ocode, oerr = generate.call(CLASSES + FX_OPEN, d, closed: false)
  check.call('without the closed world no name and no send is exact',
             TABLE_ONLY.none? { |fn| exact.call(ocode, fn) } && !oerr.include?('RETCLASS '))
end

# -- behaviour -------------------------------------------------------------------------------------

# The fixture iterates with blocks, so it needs the mrblib of a full-core build.
full = runtime.compiler? ? runtime.full_or_build : nil
if full.nil?
  puts '  SKIP run: set BC2CPP_MRUBY_FULL (libmruby.a and include/ of a full-core build of the patched 3rd/mruby), ' \
       'or have rake, g++ and 3rd/mruby to build one'
else
  puts '-- fixture on real mruby, interpreted and compiled'
  driver = <<~RUBY
    class RcDrv
      def go(fx)
        [fx.e_local, fx.e_call, fx.e_chain, fx.e_scoped_chain_box, fx.e_scoped_chain_other,
         fx.e_scoped_inherited_chain, fx.e_scoped_mixed_chain(true), fx.e_scoped_mixed_chain(false),
         fx.e_forward, fx.e_recursive, fx.e_rescue,
         fx.e_block_return([nil, 1]), fx.e_ivar, fx.e_sub, fx.e_sub_inherited, fx.e_moved,
         fx.g_mixed(true), fx.g_mixed(false), fx.g_param(RcOther.new), fx.g_param(RcSub.new),
         fx.g_ivar_read, fx.g_after_call, fx.g_yield, fx.g_reassigned(RcOther.new),
         fx.g_branch(true), fx.g_branch(false), fx.g_captured, fx.g_ensure]
      end
    end
  RUBY
  Dir.mktmpdir do |dir|
    _code, err = runtime.generate(CLASSES + FX_OPEN + driver, dir, closed: true, only_owners: OWNERS)
    body = <<~CPP
      static int scenario(mrb_state* M) {
        mrb_value fx = mrb_obj_new(M, mrb_class_get(M, "RcFx"), 0, nullptr);
        static const char* const plain[] = {
          "e_local", "e_call", "e_chain", "e_scoped_chain_box", "e_scoped_chain_other",
          "e_scoped_inherited_chain", "e_forward", "e_recursive", "e_rescue", "e_ivar", "e_sub",
          "e_sub_inherited", "e_moved", "g_ivar_read", "g_after_call", "g_yield", "g_captured", "g_ensure"
        };
        for (const char* name : plain) call(M, name, fx, name);
        mrb_value t = mrb_true_value();
        mrb_value f = mrb_false_value();
        call(M, "g_mixed true", fx, "g_mixed", 1, &t);
        call(M, "g_mixed false", fx, "g_mixed", 1, &f);
        call(M, "g_nil true", fx, "g_nil", 1, &t);
        call(M, "g_nil false", fx, "g_nil", 1, &f);
        call(M, "g_branch true", fx, "g_branch", 1, &t);
        call(M, "g_branch false", fx, "g_branch", 1, &f);
        mrb_value other = mrb_obj_new(M, mrb_class_get(M, "RcOther"), 0, nullptr);
        mrb_value sub = mrb_obj_new(M, mrb_class_get(M, "RcSub"), 0, nullptr);
        call(M, "g_param other", fx, "g_param", 1, &other);
        call(M, "g_param sub", fx, "g_param", 1, &sub);
        call(M, "g_reassigned other", fx, "g_reassigned", 1, &other);
        mrb_value xs = mrb_ary_new(M);
        mrb_ary_push(M, xs, mrb_nil_value());
        mrb_ary_push(M, xs, mrb_fixnum_value(1));
        call(M, "e_block_return", fx, "e_block_return", 1, &xs);
        mrb_value drv = mrb_obj_new(M, mrb_class_get(M, "RcDrv"), 0, nullptr);
        call(M, "driver", drv, "go", 1, &fx);
        return 0;
      }
    CPP
    built, output = runtime.run(dir, err, OWNERS, body, build: full, full: true)
    check.call('the fixture compiles and runs against real mruby', built)
    puts output unless built
    if built
      sections = runtime.sections(output)
      values = ->(name) { sections.fetch(name, []).reject { |l| l.start_with?('  ') } }
      same = !values.call('interpreted').empty? && values.call('interpreted') == values.call('compiled')
      check.call("every method answers what the interpreter answers (#{values.call('interpreted').size} lines), values and exceptions alike", same)
      puts output if ENV['BC2CPP_CHECK_VERBOSE'] || !same
      lines = values.call('compiled')
      check.call('the two-class method reached both classes (a wrong exact proof would answer :box twice)',
                 lines.include?('g_mixed true => :box') && lines.include?('g_mixed false => :other'))
      check.call('a nil result still raises NoMethodError at the send', lines.include?('g_nil false => raised NoMethodError'))
      check.call('the subclass result dispatches to the subclass body', lines.include?('e_sub => :sub'))
      check.call('receiver-scoped method chains answer through both direct and inherited methods',
                 lines.include?('e_scoped_chain_box => :other') &&
                   lines.include?('e_scoped_chain_other => :box') &&
                   lines.include?('e_scoped_inherited_chain => :other'))
    end
  end
end

if failures.empty?
  puts 'bc2cpp return class check: PASS'
else
  warn "bc2cpp return class check: #{failures.size} failure(s)"
  exit 1
end
