#!/usr/bin/env ruby
# frozen_string_literal: true

# Check the two receiver proofs of docs/adr/0309:
#
#   * ACCESSOR_RETURN_CLASS: an `attr_reader` returns the class set of the ivar slot it reads (the
#     class pool of ADR 0296), so the result of `holder.thing` is an exact receiver for the next send;
#   * EXACT_CORE_ARMS: an Array the exact-class flow proves (a literal, a local, an ivar slot) takes
#     `push` / `<<` with no class test and no dispatch, and the TYPED call of a core class's own
#     compiled body loses its guard.
#
# 1. Generated code (needs MRBC): each positive loses its guard and dispatch; each negative keeps it
#    (an unknown receiver, a subclass, a second class, a nil path); each way of losing a proof
#    (writer, second definition, subclass override, store from a subclass, reflection, alias,
#    `define_method`, a redefined push, a singleton maker, the kill switches, the open world) withdraws it.
# 2. Behaviour on real mruby: the compiled answers equal the interpreted ones in every world, for the
#    receivers a wrong proof would mis-dispatch. Run on a full-core build, a core-only build and, with
#    BC2CPP_MRUBY_FULL32 and BC2CPP_MRBC32, a 32-bit mrb_int build.
#
# Usage: [MRBC=path/to/mrbc BC2CPP_MRUBY_FULL=dir BC2CPP_MRUBY_CORE=dir] ruby scripts/bc2cpp/call_results_check.rb
# CR_GENERATED_ONLY=1 skips the behavioural half (the mutation check uses it).

require 'tmpdir'
require_relative 'fixture_runtime'

failures = []
check = lambda do |what, condition|
  puts "  #{condition ? 'ok  ' : 'FAIL'} #{what}"
  failures << what unless condition
end

runtime = Bc2cppFixtureRuntime

CLASSES = <<~RUBY
  class CrBox
    def initialize; @n = 0; end
    def tag; :box; end
    # `count` is spelled by RGSS natives, so only the guard-free TYPED call can take it.
    def count; :cnt_box; end
  end

  class CrOther
    def tag; :other; end
    def count; :cnt_other; end
  end

  class CrHolder
    attr_reader :thing
    def initialize; @thing = CrBox.new; end
  end

  class CrArr < Array
    def push(x); super(x * 2); end
  end
RUBY

FIXTURE = <<~RUBY
  class CrFx
    # -- ACCESSOR_RETURN_CLASS
    def acc_local; h = CrHolder.new; h.thing.tag; end
    def acc_chain; CrHolder.new.thing.tag; end
    def acc_ivar; @h = CrHolder.new; @h.thing.tag; end
    def acc_typed; h = CrHolder.new; h.thing.count; end
    def acc_param(h); h.thing.tag; end
    def acc_typed_param(h); h.thing.count; end

    # -- EXACT_CORE_ARMS: the push family
    def push_local; a = []; a.push(1); a.push(2); a; end
    def shl_local; a = []; a << 1; a << 2; a; end
    def push_ivar; @xs = []; @xs.push(1); @xs.size; end
    def push_nilable(f); a = f ? [] : nil; a.push(1); end
    def push_frozen; a = [].freeze; a.push(1); end
    def shl_frozen; a = [].freeze; a << 1; end
    def push_param(a); a.push(1); end
    def push_sub; a = CrArr.new; a.push(1); a; end
    def push_mixed(f); a = f ? [] : {}; a.push(1); end
    def push_hash; h = {}; h.push(1); end

    # -- EXACT_CORE_ARMS: the TYPED call of a core class's own body
    def typed_has; a = [1, 2]; a.cr_has?(2); end
    def typed_has_ivar; @a = [1, 2]; @a.cr_has?(2); end
    def typed_has_param(a); a.cr_has?(2); end
    def typed_has_mixed(f); a = f ? [1] : { 1 => 2 }; a.cr_has?(1); end
  end

  # The driver passes every argument from Ruby, so each call site of a parameterised method is visible.
  class CrDrv
    def d_acc_param; CrFx.new.acc_param(CrHolder.new); end
    def d_acc_typed_param; CrFx.new.acc_typed_param(CrHolder.new); end
    def d_push_param_array; CrFx.new.push_param([]); end
    def d_push_param_hash; CrFx.new.push_param({}); end
    def d_push_param_sub; CrFx.new.push_param(CrArr.new); end
    def d_push_mixed_t; CrFx.new.push_mixed(true); end
    def d_push_mixed_f; CrFx.new.push_mixed(false); end
    def d_push_nilable_t; CrFx.new.push_nilable(true); end
    def d_push_nilable_f; CrFx.new.push_nilable(false); end
    def d_typed_param_array; CrFx.new.typed_has_param([2]); end
    def d_typed_param_hash; CrFx.new.typed_has_param({}); end
    def d_typed_mixed_t; CrFx.new.typed_has_mixed(true); end
    def d_typed_mixed_f; CrFx.new.typed_has_mixed(false); end
  end
RUBY

# Array and Hash reopened with a method of the same name: the TYPED target of `cr_has?` for a core class.
CORE_RUBY = <<~RUBY
  class Array
    def cr_has?(x)
      i = 0
      while i < size
        return true if self[i].equal?(x)
        i += 1
      end
      false
    end
  end

  class Hash
    def cr_has?(x); key?(x); end
  end
RUBY

# SCOPED_ACCESSOR_RETURN (this file's section 1b): `slot` is read by two classes with different classes in the slot and
# by `CrSo#slot`, a Ruby method whose result is unmodelled, so the name is not in the return table and only an exact
# receiver selecting its own reader can name the class.
SCOPED_CLASSES = <<~RUBY
  class CrSa
    attr_reader :slot
    def initialize; @slot = CrBox.new; end
  end

  class CrSb
    attr_reader :slot
    def initialize; @slot = CrOther.new; end
  end

  class CrSaSub < CrSa; end

  class CrSo
    def slot; $cr_unknown; end
  end

  class CrScFx
    def sc_a; CrSa.new.slot.tag; end
    def sc_b; CrSb.new.slot.tag; end
    def sc_sub; CrSaSub.new.slot.tag; end
    def sc_ivar; @h = CrSa.new; @h.slot.tag; end
    def sc_param(h); h.slot.tag; end
    def sc_unknown; CrSo.new.slot.tag; end
  end

  class CrScDrv
    def d_sc_param_a; CrScFx.new.sc_param(CrSa.new); end
    def d_sc_param_b; CrScFx.new.sc_param(CrSb.new); end
  end
RUBY

SCOPED_OWNERS = %w[CrSa CrSb CrSaSub CrSo CrSl CrScFx CrScDrv].freeze
OWNERS = (%w[CrBox CrOther CrLazy CrHolder CrHolder2 CrHolderSub CrHolderSub2 CrArr CrFx CrDrv Array Hash] + SCOPED_OWNERS).freeze

# World name => extra Ruby, the methods it reads, and the (method => expected exact class) the scoped proof must still keep.
SCOPED_WORLDS_SRC = {
  'a writer on one class' => [<<~RUBY, { 'sc_a' => nil, 'sc_sub' => nil, 'sc_ivar' => nil, 'sc_b' => 'CrOther' }],
    class CrSa
      attr_writer :slot
    end
  RUBY
  'a store of a second class in the family' => [<<~RUBY, { 'sc_a' => nil, 'sc_sub' => nil, 'sc_ivar' => nil, 'sc_b' => 'CrOther' }],
    class CrSa
      def swap; @slot = CrOther.new; end
    end
  RUBY
  # The subclass's store is a store of the shared slot (the pool is per family), so the base class is withdrawn too.
  'a store from a subclass' => [<<~RUBY, { 'sc_a' => nil, 'sc_sub' => nil, 'sc_ivar' => nil, 'sc_poke' => nil, 'sc_b' => 'CrOther' }],
    class CrSaSub
      def poke; @slot = CrOther.new; end
    end
    class CrScFx
      def sc_poke; a = CrSaSub.new; a.poke; a.slot.tag; end
    end
  RUBY
  'an instance_variable_set of the ivar' => [<<~RUBY, { 'sc_a' => nil, 'sc_sub' => nil, 'sc_ivar' => nil }],
    class CrScFx
      def sc_refl; a = CrSa.new; a.instance_variable_set(:@slot, CrOther.new); a.slot.tag; end
    end
  RUBY
  'a define_method of the name' => [<<~RUBY, { 'sc_a' => nil, 'sc_b' => nil, 'sc_sub' => nil }],
    class CrSb
      define_method(:slot) { CrBox.new }
    end
  RUBY
  'a subclass overriding the reader' => [<<~RUBY, { 'sc_b' => 'CrOther', 'sc_sub' => 'CrOther' }],
    class CrSaSub
      def slot; CrOther.new; end
    end
  RUBY
  'a singleton reader on an object' => [<<~RUBY, { 'sc_a' => nil, 'sc_b' => nil, 'sc_sub' => nil }],
    class CrScFx
      def sc_maker; o = CrSa.new; def o.slot; CrOther.new; end; o; end
    end
  RUBY
  'an unassigned slot' => [<<~RUBY, { 'sc_lazy' => :nilable, 'sc_a' => 'CrBox', 'sc_b' => 'CrOther' }]
    class CrSl
      attr_reader :slot
      def build; @slot = CrBox.new; end
    end
    class CrScFx
      def sc_lazy; CrSl.new.slot.tag; end
      def sc_built; l = CrSl.new; l.build; l.slot.tag; end
    end
  RUBY
}.freeze

# World name => extra Ruby appended to the fixture. Each adds the methods its negative case reads.
WORLDS = {
  'a writer on the ivar' => <<~RUBY,
    class CrHolder
      attr_writer :thing
    end
    class CrFx
      def acc_set; h = CrHolder.new; h.thing = CrOther.new; h.thing.tag; end
      def stash_held; h = CrHolder.new; h.thing = CrOther.new; @held = h.thing; nil; end
      def held_tag; @held.tag; end
      def stash_boxed; @held2 = CrBox.new; nil; end
      def stash_held2; h = CrHolder.new; h.thing = CrOther.new; @held2 = h.thing; nil; end
      def held2_tag; @held2.tag; end
    end
  RUBY
  'a writer the setter pool refuses' => <<~RUBY,
    class CrHolder
      attr_writer :thing
    end
    class CrHolder2
      attr_reader :thing
      def initialize; @thing = CrOther.new; end
    end
    class CrFx
      def acc_named_set; h = CrHolder.new; h.public_send('thing=', CrOther.new); h.thing.tag; end
      def acc_named_any(h); h.thing.tag; end
    end
  RUBY
  'a second class with a reader of the same name' => <<~RUBY,
    class CrHolder2
      attr_reader :thing
      def initialize; @thing = CrOther.new; end
    end
    class CrFx
      def acc_second; CrHolder2.new.thing.tag; end
    end
  RUBY
  'a store of a second class' => <<~RUBY,
    class CrHolder
      def swap; @thing = CrOther.new; end
    end
    class CrFx
      def acc_swap; h = CrHolder.new; h.swap; h.thing.tag; end
    end
  RUBY
  'a store from a subclass' => <<~RUBY,
    class CrHolderSub2 < CrHolder
      def poke; @thing = CrOther.new; end
    end
    class CrFx
      def acc_poke; h = CrHolderSub2.new; h.poke; h.thing.tag; end
    end
  RUBY
  'a subclass overriding the reader' => <<~RUBY,
    class CrHolderSub < CrHolder
      def thing; CrOther.new; end
    end
    class CrFx
      def acc_sub; acc_param(CrHolderSub.new); end
    end
  RUBY
  'a define_method of the name' => <<~RUBY,
    class CrHolder
      define_method(:thing) { CrOther.new }
    end
  RUBY
  'an instance_variable_set of the ivar' => <<~RUBY,
    class CrFx
      def refl; h = CrHolder.new; h.instance_variable_set(:@thing, CrOther.new); h.thing.tag; end
    end
  RUBY
  'an alias of the reader' => <<~RUBY
    class CrHolder
      alias_method :thing_alias, :thing
    end
  RUBY
}.freeze

NIL_WORLD = <<~RUBY
  class CrHolder
    def unset; @thing = nil; end
  end
  class CrFx
    def acc_cleared; h = CrHolder.new; h.unset; h.thing.tag; end
  end
RUBY


# No constructor assigns the slot: until `build` runs the reader answers nil.
LAZY_WORLD = <<~RUBY
  class CrLazy
    attr_reader :cr_slot
    def build; @cr_slot = CrBox.new; end
  end
  class CrFx
    def acc_lazy; CrLazy.new.cr_slot.tag; end
    def acc_built; l = CrLazy.new; l.build; l.cr_slot.tag; end
  end
RUBY

# Worlds where the name stays ambiguous (two readers, an override) but an exact receiver selects one reader.
SCOPED_WORLDS = ['a second class with a reader of the same name', 'a subclass overriding the reader'].freeze

ACCESSOR_METHODS = %w[acc_local acc_chain acc_ivar acc_param].freeze

body_of = lambda do |code, fn|
  code[/^mrb_value CrFx_#{fn}_impl\(mrb_state\* M.*?(?=^(?:static )?mrb_value \w+\(mrb_state\* M|\z)/m].to_s
end
live_of = ->(code, fn) { body_of.call(code, fn).lines.reject { |l| l.lstrip.start_with?('//') }.join }
# `tag` / `count` is sent to an exact CrBox by a guard-free exact or TYPED call.
exact_tag = lambda do |code, fn|
  body_of.call(code, fn).match?(%r{(?:CLOSED_WORLD_EXACT_CLASS :tag -> CrBox#tag|(?:CLOSED_WORLD_EXACT_CLASS|EXACT_TYPED) :count -> CrBox#count)})
end
guarded_tag = lambda do |code, fn|
  body = body_of.call(code, fn)
  !body.empty? && !body.match?(%r{(?:CLOSED_WORLD_EXACT_CLASS :tag -> CrBox#tag|EXACT_TYPED :count -> CrBox#count)})
end
# The ADR 0309 push: no class test and no dispatch left in the live code.
exact_push = lambda do |code, fn|
  live = live_of.call(code, fn)
  body_of.call(code, fn).include?('ADR 0309') && live.include?('mrb_ary_push') && !live.include?('bc2cpp_send(') && !live.include?('->c == M->')
end
plain_push = lambda do |code, fn|
  body = body_of.call(code, fn)
  live = live_of.call(code, fn)
  !body.empty? && !body.include?('ADR 0309') && body.include?('ARRAY_PUSH') &&
    (live.include?('bc2cpp_send(') || live.include?('bc2cpp_slow_lshift('))
end
exact_typed = ->(code, fn) { body_of.call(code, fn).include?('EXACT_TYPED :cr_has? -> Array#cr_has?') }
typed_guarded = lambda do |code, fn|
  body = body_of.call(code, fn)
  !body.empty? && !body.include?('EXACT_TYPED :cr_has?') && body.match?(/(?:TYPED|POLY_SMALL_N) :cr_has\?/)
end

generate = lambda do |source, dir, closed: true, env: {}, **options|
  saved = env.to_h { |k, _| [k, ENV.fetch(k, nil)] }
  env.each { |k, v| ENV[k] = v }
  begin
    runtime.generate(source, dir, closed: closed, only_owners: OWNERS, **options)
  ensure
    saved.each { |k, v| v ? ENV[k] = v : ENV.delete(k) }
  end
end

# -- 1. generated code -----------------------------------------------------------------

if ENV['MRBC']
  puts '== generated code'
  Dir.mktmpdir do |dir|
    code, err = generate.call(CLASSES + CORE_RUBY + FIXTURE, dir)

    ACCESSOR_METHODS.each do |fn|
      check.call("#{fn}: the attr_reader result is an exact CrBox, so tag is called with no guard", exact_tag.call(code, fn))
    end
    check.call('acc_typed / acc_typed_param: a name an RGSS native also spells takes a guard-free exact call',
               exact_tag.call(code, 'acc_typed') && exact_tag.call(code, 'acc_typed_param'))
    check.call('the diagnostic lists the reader in the return table', err.include?('RETCLASS thing (CrBox)'))
    check.call('the exact result of `h.thing` leaves no dispatch of the second send',
               !live_of.call(code, 'acc_local').include?('bc2cpp_send(') && !live_of.call(code, 'acc_chain').include?('bc2cpp_send('))

    %w[push_local shl_local push_ivar].each do |fn|
      check.call("#{fn}: an Array the flow proves exact takes the push with no class test", exact_push.call(code, fn))
    end
    check.call('push_nilable: nil-or-Array takes one nil test, then the guard-free push',
               body_of.call(code, 'push_nilable').include?('NILABLE_RECEIVER :push') && body_of.call(code, 'push_nilable').include?('ADR 0309'))
    check.call('push_frozen / shl_frozen: a frozen exact Array still goes through mrb_ary_push (FrozenError)',
               live_of.call(code, 'push_frozen').include?('mrb_ary_push') && live_of.call(code, 'shl_frozen').include?('mrb_ary_push'))
    %w[push_param push_sub push_mixed push_hash].each do |fn|
      check.call("NEG #{fn}: no proof of an Array receiver keeps the guarded arm", plain_push.call(code, fn))
    end
    %w[typed_has typed_has_ivar].each do |fn|
      check.call("#{fn}: the TYPED call of a core class's own body loses its guard", exact_typed.call(code, fn))
    end
    %w[typed_has_param typed_has_mixed].each do |fn|
      check.call("NEG #{fn}: an unknown or mixed receiver keeps the guard", typed_guarded.call(code, fn))
    end

    WORLDS.each do |what, extra|
      d = File.join(dir, what.gsub(/\W+/, '_'))
      Dir.mkdir(d)
      wcode, werr = generate.call(CLASSES + CORE_RUBY + FIXTURE + extra, d)
      if SCOPED_WORLDS.include?(what)
        # SCOPED_ACCESSOR_RETURN: the name is ambiguous, but an exact CrHolder selects CrHolder's own reader, so
        # the slot's class set still answers.
        check.call("#{what}: an exact CrHolder still gets the slot's class from its own reader (scoped)",
                   %w[acc_local acc_ivar].all? { |fn| exact_tag.call(wcode, fn) })
      else
        check.call("NEG #{what}: acc_local and acc_ivar lose the exact result",
                   %w[acc_local acc_ivar].all? { |fn| guarded_tag.call(wcode, fn) })
      end
      check.call("NEG #{what}: `thing` leaves the return table", !werr.include?('RETCLASS thing (CrBox)'))
      check.call("#{what}: the Array proofs are untouched", exact_push.call(wcode, 'push_local') && exact_typed.call(wcode, 'typed_has'))
      if what == 'a writer the setter pool refuses'
        # The slot has no class pool at all (no group key), which is not an empty pool: a name joined with another
        # class's reader must stay unknown, never become nil-or-that-class's exact call.
        check.call("NEG #{what}: a reader without a pool joins its name as unknown, so the call on `thing` keeps its guard",
                   !body_of.call(wcode, 'acc_named_any').include?('CLOSED_WORLD_EXACT_CLASS :tag') && body_of.call(wcode, 'acc_named_any').include?('POLY_SMALL_N :tag'))
      end
      next unless what == 'a writer on the ivar'

      # The writer's value joins the reader's result: an ivar fed from it must not look like a CrBox or like nil.
      check.call("NEG #{what}: an ivar stored from the reader keeps a chain over both classes, no exact call and no nil arm",
                 %w[held_tag held2_tag].all? do |fn|
                   body_of.call(wcode, fn).match?(/(?:TYPED|POLY_SMALL_N) :tag/) && !exact_tag.call(wcode, fn) &&
                     !body_of.call(wcode, fn).include?('NIL_RECEIVER')
                 end)
    end

    # A nil store makes the pool nil-or-CrBox: one nil test and the exact call, not a plain exact call.
    Dir.mktmpdir do |nd|
      ncode, = generate.call(CLASSES + CORE_RUBY + FIXTURE + NIL_WORLD, nd)
      check.call('a nil store: acc_local takes one nil test, then the exact call',
                 body_of.call(ncode, 'acc_local').include?('NILABLE_RECEIVER :tag') && exact_tag.call(ncode, 'acc_local'))
    end

    # No constructor assigns the slot: the reader may answer nil, so never a plain exact call.
    Dir.mktmpdir do |ld|
      lcode, = generate.call(CLASSES + CORE_RUBY + FIXTURE + LAZY_WORLD, ld)
      check.call('an unassigned slot: the send keeps its guard or takes a nil test, never a plain exact call',
                 guarded_tag.call(lcode, 'acc_lazy') || body_of.call(lcode, 'acc_lazy').include?('NILABLE_RECEIVER :tag'))
      check.call('an unassigned slot: the receiver of the reader is still an exact CrLazy',
                 body_of.call(lcode, 'acc_lazy').include?('receiver proven exactly CrLazy'))
    end

    # A Ruby Array#push (Array#<<) is the exact receiver's own method: no native arm for that name.
    { 'push' => 'push_local', '<<' => 'shl_local' }.each do |op, fn|
      Dir.mktmpdir do |rd|
        rcode, = generate.call(CLASSES + CORE_RUBY + FIXTURE + "class Array\n  def #{op}(x); 1; end\nend\n", rd)
        check.call("a Ruby Array##{op} removes the native arm of that name (no ADR 0309 push) and keeps the other one",
                   !body_of.call(rcode, fn).include?('ADR 0309') && !live_of.call(rcode, fn).include?('mrb_ary_push') &&
                     exact_push.call(rcode, op == 'push' ? 'shl_local' : 'push_local'))
      end
    end
    Dir.mktmpdir do |sd|
      scode, = generate.call(CLASSES + CORE_RUBY + FIXTURE + "class CrFx\n  def maker; a = [1]; def a.other(*); 'x'; end; a; end\nend\n", sd)
      check.call('a def on an object (a singleton maker) withdraws every flow proof',
                 %w[push_local shl_local push_ivar].none? { |fn| exact_push.call(scode, fn) } &&
                   !exact_typed.call(scode, 'typed_has') && ACCESSOR_METHODS.none? { |fn| exact_tag.call(scode, fn) })
    end
    Dir.mktmpdir do |od|
      ocode, = generate.call(CLASSES + CORE_RUBY + FIXTURE, od, closed: false)
      check.call('the open world proves nothing',
                 %w[push_local push_ivar].none? { |fn| exact_push.call(ocode, fn) } && ACCESSOR_METHODS.none? { |fn| exact_tag.call(ocode, fn) })
    end
    Dir.mktmpdir do |kd|
      kcode, = generate.call(CLASSES + CORE_RUBY + FIXTURE, kd, env: { 'BC2CPP_EXACT_CORE_ARMS' => '0' })
      check.call('BC2CPP_EXACT_CORE_ARMS=0: the old guarded push and TYPED call, the accessor proof stays',
                 %w[push_local shl_local push_ivar].all? { |fn| plain_push.call(kcode, fn) } && !exact_typed.call(kcode, 'typed_has') &&
                   ACCESSOR_METHODS.all? { |fn| exact_tag.call(kcode, fn) })
    end
    Dir.mktmpdir do |ad|
      acode, aerr = generate.call(CLASSES + CORE_RUBY + FIXTURE, ad, env: { 'BC2CPP_RETURN_ACCESSORS' => '0' })
      check.call('BC2CPP_RETURN_ACCESSORS=0: the reader leaves the return table, the Array proofs stay',
                 !aerr.include?('RETCLASS thing (CrBox)') && %w[acc_local acc_ivar].all? { |fn| guarded_tag.call(acode, fn) } &&
                   exact_push.call(acode, 'push_local') && exact_typed.call(acode, 'typed_has'))
    end
    Dir.mktmpdir do |pd|
      pcode, perr = generate.call(CLASSES + CORE_RUBY + FIXTURE, pd, env: { 'BC2CPP_CLASS_POOLS' => '0' })
      check.call('BC2CPP_CLASS_POOLS=0: no ivar pool, so no accessor result',
                 !perr.include?('RETCLASS thing (CrBox)') && %w[acc_local acc_ivar].all? { |fn| guarded_tag.call(pcode, fn) })
    end

    # -- 1b. SCOPED_ACCESSOR_RETURN: an exact receiver selects one attr_reader, the name has other definitions
    sc_body = lambda do |text, fn|
      text[/^mrb_value CrScFx_#{fn}_impl\(mrb_state\* M.*?(?=^(?:static )?mrb_value \w+\(mrb_state\* M|\z)/m].to_s
    end
    # A plain exact call: no nil test around it (a nil-or-K receiver is the NILABLE_RECEIVER arm, which proves less).
    sc_exact = lambda do |text, fn, klass|
      body = sc_body.call(text, fn)
      body.match?(/CLOSED_WORLD_EXACT_CLASS :tag -> #{klass}#tag/) && !body.include?('NILABLE_RECEIVER :tag')
    end
    sc_any_exact = lambda do |text, fn|
      body = sc_body.call(text, fn)
      body.match?(/(?:CLOSED_WORLD_EXACT_CLASS|EXACT_TYPED) :tag -> /) && !body.include?('NILABLE_RECEIVER :tag')
    end
    sc_guarded = ->(text, fn) { !sc_body.call(text, fn).empty? && !sc_any_exact.call(text, fn) }
    scoped_src = CLASSES + CORE_RUBY + FIXTURE + SCOPED_CLASSES
    Dir.mktmpdir do |sd|
      scode, serr = generate.call(scoped_src, sd)
      check.call('scoped: `slot` is not in the return table (CrSo#slot is unmodelled), so only the exact receiver names the class',
                 !serr.include?('RETCLASS slot'))
      { 'sc_a' => 'CrBox', 'sc_b' => 'CrOther', 'sc_sub' => 'CrBox', 'sc_ivar' => 'CrBox' }.each do |fn, klass|
        check.call("scoped #{fn}: the exact receiver's own attr_reader gives #{klass}, so tag is called with no guard", sc_exact.call(scode, fn, klass))
      end
      %w[sc_param sc_unknown].each do |fn|
        check.call("NEG scoped #{fn}: an unknown receiver or an unmodelled reader keeps its guard", sc_guarded.call(scode, fn))
      end

      SCOPED_WORLDS_SRC.each do |what, (extra, expected)|
        d = File.join(sd, "sc_#{what.gsub(/\W+/, '_')}")
        Dir.mkdir(d)
        wcode, = generate.call(scoped_src + extra, d)
        expected.each do |fn, klass|
          ok = if klass == :nilable
                 # nil-or-CrBox: one nil test then the exact call, or the old guard; never a plain exact call.
                 sc_body.call(wcode, fn).include?('NILABLE_RECEIVER :tag') || sc_guarded.call(wcode, fn)
               elsif klass
                 sc_exact.call(wcode, fn, klass)
               else
                 !sc_any_exact.call(wcode, fn) && !sc_body.call(wcode, fn).empty?
               end
          check.call(klass == :nilable ? "scoped #{what}: #{fn} takes a nil test or keeps its guard, never a plain exact call" : klass ? "scoped #{what}: #{fn} keeps the exact #{klass}" : "NEG scoped #{what}: #{fn} loses the exact result", ok)
        end
      end
    end
    Dir.mktmpdir do |kd|
      kcode, = generate.call(scoped_src, kd, env: { 'BC2CPP_SCOPED_ACCESSOR_RETURNS' => '0' })
      check.call('BC2CPP_SCOPED_ACCESSOR_RETURNS=0: the scoped sends keep their guards, the name-wide accessor proof stays',
                 %w[sc_a sc_b sc_sub sc_ivar].none? { |fn| sc_any_exact.call(kcode, fn) } && ACCESSOR_METHODS.all? { |fn| exact_tag.call(kcode, fn) })
    end
    Dir.mktmpdir do |od|
      ocode, = generate.call(scoped_src, od, closed: false)
      check.call('scoped: the open world proves nothing', %w[sc_a sc_b sc_sub sc_ivar].none? { |fn| sc_any_exact.call(ocode, fn) })
    end
    Dir.mktmpdir do |pd|
      pcode, = generate.call(scoped_src, pd, env: { 'BC2CPP_CLASS_POOLS' => '0' })
      check.call('BC2CPP_CLASS_POOLS=0: no ivar pool, so no scoped accessor result', %w[sc_a sc_b sc_sub sc_ivar].none? { |fn| sc_any_exact.call(pcode, fn) })
    end
  end
else
  puts '-- SKIP generated code: set MRBC'
end

# -- 2. behaviour ----------------------------------------------------------------------

builds = []
full = runtime.full || (ENV['BC2CPP_FULL_BUILD_DIR'] ? runtime.full_or_build : nil)
builds << ['full-core', full, ENV.fetch('MRBC', nil), '', true] if full
builds << ['core-only', runtime.core, ENV.fetch('MRBC', nil), '', false] if runtime.core
# -no-pie: the fallback glue keeps a block function's address in an mrb_int, which a 32-bit mrb_int on a
# 64-bit host only holds for code below 2 GB (a real 32-bit target has 32-bit pointers).
if ENV['BC2CPP_MRUBY_FULL32'] && ENV['BC2CPP_MRBC32']
  builds << ['mrb_int 32 (full-core)', ENV['BC2CPP_MRUBY_FULL32'], ENV['BC2CPP_MRBC32'], '-DMRB_32BIT -DMRB_INT32 -no-pie', true]
end
builds << ['full-core', runtime.full_or_build, ENV.fetch('MRBC', nil), '', true] if builds.empty? && runtime.compiler? && runtime.full_or_build

if ENV['MRBC'] && !builds.empty? && runtime.compiler? && !ENV['CR_GENERATED_ONLY']
  puts '== fixture on real mruby, interpreted and compiled'
  # Zero-argument methods of CrFx, then of CrDrv: the driver passes the arguments from Ruby, so every
  # call site of a parameterised method is visible to the closed world (a C++ caller would not be).
  fx_calls = %w[acc_local acc_chain acc_ivar acc_typed push_local shl_local push_ivar push_frozen shl_frozen push_sub push_hash
                typed_has typed_has_ivar]
  drv_calls = %w[d_acc_param d_acc_typed_param d_push_param_array d_push_param_hash d_push_param_sub d_push_mixed_t d_push_mixed_f
                 d_push_nilable_t d_push_nilable_f d_typed_param_array d_typed_param_hash d_typed_mixed_t d_typed_mixed_f]
  world_calls = {
    'a writer on the ivar' => [%w[acc_set stash_held held_tag stash_boxed stash_held2 held2_tag], []],
    'a writer the setter pool refuses' => [%w[acc_named_set acc_named_any], []],
    'a second class with a reader of the same name' => [%w[acc_second], []],
    'a store of a second class' => [%w[acc_swap], []],
    'a store from a subclass' => [%w[acc_poke], []],
    'a subclass overriding the reader' => [%w[acc_sub], []],
    'a define_method of the name' => [[], []],
    'an instance_variable_set of the ivar' => [%w[refl], []],
    'an alias of the reader' => [[], []],
    'a nil store' => [%w[acc_cleared], []],
    'an unassigned slot' => [%w[acc_lazy acc_built], []]
  }
  scenario = lambda do |extra_fx, extra_drv|
    fx = (fx_calls + extra_fx).map { |m| "  call(M, \"#{m}\", fx, \"#{m}\");" }
    drv = (drv_calls + extra_drv).map { |m| "  call(M, \"#{m}\", drv, \"#{m}\");" }
    <<~CPP
      static int scenario(mrb_state* M) {
        mrb_value fx = mrb_obj_new(M, mrb_class_get(M, "CrFx"), 0, nullptr);
        mrb_value drv = mrb_obj_new(M, mrb_class_get(M, "CrDrv"), 0, nullptr);
      #{(fx + drv).join("\n")}
        return 0;
      }
    CPP
  end
  worlds = { 'the base fixture' => ['', [], []] }
  # A second definition of a name in the same class (`define_method` after `attr_reader`) shares one C++ symbol with the
  # first, so the compiled call picks the wrong body with or without these proofs: generated code only.
  WORLDS.except('a define_method of the name').each { |what, extra| worlds[what] = [extra, *world_calls.fetch(what)] }
  worlds['a nil store'] = [NIL_WORLD, *world_calls.fetch('a nil store')]
  worlds['an unassigned slot'] = [LAZY_WORLD, *world_calls.fetch('an unassigned slot')]

  builds.each do |build_name, build, mrbc, flags, full_core|
    saved = ENV.values_at('MRBC', 'BC2CPP_CXXFLAGS')
    ENV['MRBC'] = mrbc
    # include/ holds rgss_construct.hxx, which the generated code includes once a probe compile used a native construct.
    ENV['BC2CPP_CXXFLAGS'] = "#{flags} -I#{File.expand_path('../../include', __dir__)}"
    begin
      worlds.each do |world, (extra, extra_fx, extra_drv)|
        label = "#{build_name}, #{world}"
        Dir.mktmpdir do |dir|
          _code, err = generate.call(CLASSES + CORE_RUBY + FIXTURE + extra, dir)
          built, output = runtime.run(dir, err, OWNERS, scenario.call(extra_fx, extra_drv), build: build, full: full_core)
          check.call("#{label}: the fixture compiles and runs against real mruby", built)
          puts output unless built
          next unless built

          sections = runtime.sections(output)
          values = ->(name) { sections.fetch(name, []).reject { |l| l.start_with?('  ') } }
          puts output if ENV['BC2CPP_CHECK_VERBOSE']
          values.call('interpreted').zip(values.call('compiled')).reject { |a, b| a == b }.first(8).each do |a, b|
            puts "    interpreted: #{a}\n    compiled:    #{b}"
          end
          check.call("#{label}: every method answers what the interpreter answers (#{values.call('interpreted').size} lines), values and exceptions alike",
                     !values.call('interpreted').empty? && values.call('interpreted') == values.call('compiled'))
          compiled = values.call('compiled')
          case world
          when 'the base fixture'
            # `raised` names the build's own exception class (a core-only build raises its own NoMethodError text).
            expected = ['acc_local => :box', 'acc_typed => :cnt_box', 'push_local => [1, 2]', 'shl_local => [1, 2]', 'push_frozen => raised',
                        'shl_frozen => raised', 'push_hash => raised', 'push_sub => [2]', 'd_acc_param => :box',
                        'd_push_param_sub => [2]', 'd_push_param_hash => raised', 'd_push_nilable_t => [1]',
                        'd_push_nilable_f => raised', 'd_push_mixed_f => raised', 'typed_has => true',
                        'd_typed_param_hash => false', 'd_typed_mixed_t => true', 'd_typed_mixed_f => true']
            missing = expected.reject { |want| compiled.any? { |line| line.start_with?(want) } }
            puts "  missing compiled answers: #{missing.inspect}" unless missing.empty?
            check.call("#{label}: the answers are the ones Ruby gives", missing.empty?)
            lines = sections.fetch('compiled', [])
            %w[acc_local acc_chain acc_ivar acc_typed push_local shl_local push_ivar typed_has typed_has_ivar].each do |m|
              at = lines.index { |l| l.start_with?("#{m} =>") }
              n = at && lines[at + 1].to_s[/dispatches=(\d+)/, 1]&.to_i
              check.call("#{label}: #{m}: the compiled call makes no dynamic dispatch", n == 0)
            end
          when 'a subclass overriding the reader'
            check.call("#{label}: the subclass reader is the one called (a wrong exact proof would answer :box)",
                       compiled.include?('acc_sub => :other') && compiled.include?('d_acc_param => :box'))
          when 'an unassigned slot'
            check.call("#{label}: an unbuilt holder raises NoMethodError, a built one answers",
                       compiled.any? { |line| line.start_with?('acc_lazy => raised') } && compiled.include?('acc_built => :box'))
          when 'a nil store'
            check.call("#{label}: a cleared holder still raises NoMethodError at the send", compiled.any? { |line| line.start_with?('acc_cleared => raised') })
          end
        end
      end
    ensure
      ENV['MRBC'], ENV['BC2CPP_CXXFLAGS'] = saved
    end
  end
else
  puts '-- SKIP run: set MRBC, BC2CPP_MRUBY_FULL (or have rake, g++ and 3rd/mruby) and have g++'
end

if failures.empty?
  puts 'bc2cpp call results check: PASS'
else
  warn "bc2cpp call results check: #{failures.size} failure(s)"
  exit 1
end
