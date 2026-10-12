#!/usr/bin/env ruby
# frozen_string_literal: true

# Check docs/adr/0382 (ivar typing): the two rules that add class facts to the pools of ADR 0295/0313, each with its
# preconditions and its refusals, and the diagnostics that count what is left.
#
#   * CONSTRUCTOR_KEYWORDS: an `initialize` with keyword parameters, and a `new` / `super` call with literal keywords,
#     join the argument pools of ADR 0313. Positions 1..mand are the first mand positionals whatever the keywords do.
#     Refused (the initialize stays unpooled, reason on stderr): a `**opts` or splat call, a keyword call with fewer
#     positionals than mandatory parameters, a bare `super`, a `new` on a receiver that is not a named class, a
#     post-mandatory parameter, and BC2CPP_CTOR_KEYWORDS=0.
#   * POOL_SELF_CLASS: `self` in the body of a uniquely owned instance method of a declared class is that class (and its
#     visible descendants), so `Holder.new(self)` pools the caller's class. Refused: a block body (its self may be
#     rebound), a module method, a method two owners share, an alias into another class, a body of a class whose
#     descendants are not all visible, and BC2CPP_POOL_SELF_CLASS=0.
#   * the diagnostics: the OPAQUE ivar list bucketed by cause, and the dropped pool list by blocker.
#
# Each positive loses its guard and its dispatch; each negative keeps it; both kill switches restore the old code.
#
# Usage: MRBC=path/to/mrbc ruby scripts/bc2cpp/ivar_typing_check.rb

require 'tmpdir'
require_relative 'fixture_runtime'

failures = []
check = lambda do |what, condition|
  puts "  #{condition ? 'ok  ' : 'FAIL'} #{what}"
  failures << what unless condition
end

abort 'SKIP: set MRBC' unless ENV['MRBC']
runtime = Bc2cppFixtureRuntime

CLASSES = <<~RUBY
  class IvBox
    def tag; :box; end
  end

  class IvOther
    def tag; :other; end
  end
RUBY

# -- CONSTRUCTOR_KEYWORDS ---------------------------------------------------------------------------------------------
KEYWORDS = <<~RUBY
  # A keyword parameter and a keyword call: every site visible, one class.
  class KwOne
    def initialize(box, n, mode: :a, quit: false); @box = box; @n = n; @mode = mode; end
    def read_box; @box.tag; end
  end
  class KwOneDrv
    def d1; KwOne.new(IvBox.new, 1, mode: :b); end
    def d2; KwOne.new(IvBox.new, 2); end
    def d3; KwOne.new(IvBox.new, 3, quit: true, mode: :c); end
  end

  # NEG: a second class at one keyword site.
  class KwTwo
    def initialize(box, n, mode: :a); @box = box; end
    def read_box; @box.tag; end
  end
  class KwTwoDrv
    def d1; KwTwo.new(IvBox.new, 1, mode: :b); end
    def d2; KwTwo.new(IvOther.new, 2, mode: :c); end
  end

  # NEG: `**opts` hides the positionals' count.
  class KwSplat
    def initialize(box, mode: :a); @box = box; end
    def read_box; @box.tag; end
  end
  class KwSplatDrv
    def d1(opts); KwSplat.new(IvBox.new, **opts); end
  end

  # NEG: a splat of positionals.
  class KwPacked
    def initialize(box, n, mode: :a); @box = box; end
    def read_box; @box.tag; end
  end
  class KwPackedDrv
    def d1(args); KwPacked.new(*args, mode: :x); end
  end

  # NEG: a keyword call with fewer positionals than mandatory parameters (the hash would stand in for one).
  class KwShort
    def initialize(box, mode = nil); @box = box; end
    def read_box; @box.tag; end
  end
  class KwShortDrv
    def d1; KwShort.new(mode: IvOther.new); end
    def d2; KwShort.new(IvBox.new); end
  end

  # A keyword call to an initialize without keyword parameters: the Hash is an extra trailing positional.
  class KwPlain
    def initialize(box, opts = nil); @box = box; @opts = opts; end
    def read_box; @box.tag; end
  end
  class KwPlainDrv
    def d1; KwPlain.new(IvBox.new, flag: 1); end
  end

  # super with keywords reaches the base initialize.
  class KwBase
    def initialize(box, mode: :a); @box = box; end
    def read_box; @box.tag; end
  end
  class KwSub < KwBase
    def initialize(box, extra, mode: :z); super(box, mode: mode); @extra = extra; end
  end
  class KwSubDrv
    def d1; KwSub.new(IvBox.new, 1, mode: :q); end
    def d2; KwBase.new(IvBox.new); end
  end

  # NEG: a bare super forwards arguments the flow does not model.
  class KwZBase
    def initialize(box, mode: :a); @box = box; end
    def read_box; @box.tag; end
  end
  class KwZSub < KwZBase
    def initialize(box, mode: :z); super; end
  end
  class KwZDrv
    def d1; KwZSub.new(IvBox.new, mode: :q); end
    def d2; KwZBase.new(IvBox.new); end
  end

  # NEG: a super with keywords and fewer positionals than the base initialize's mandatory parameters.
  class KwSShortBase
    def initialize(box, mode: :a); @box = box; end
    def read_box; @box.tag; end
  end
  class KwSShortSub < KwSShortBase
    def initialize(mode: :z); super(mode: mode); end
  end
  class KwSShortDrv
    def d1; KwSShortSub.new(mode: :q); end
    def d2; KwSShortBase.new(IvBox.new); end
  end

  # NEG: a post-mandatory parameter is still refused.
  class KwPost
    def initialize(box, *rest, last, mode: :a); @box = box; end
    def read_box; @box.tag; end
  end
  class KwPostDrv
    def d1; KwPost.new(IvBox.new, 1, mode: :b); end
  end
RUBY

# -- POOL_SELF_CLASS --------------------------------------------------------------------------------------------------
SELF_CLASS = <<~RUBY
  class SfHolder
    def initialize(parent); @parent = parent; end
    def read_parent; @parent.tag; end
  end

  # One class, no subclass: self is exactly SfOwner.
  class SfOwner
    def tag; :owner; end
    def build; SfHolder.new(self); end
  end

  # Two classes through a subclass: the pool is the pair, never a single-class arm.
  class SfHolderPair
    def initialize(parent); @parent = parent; end
    def read_parent; @parent.tag; end
  end
  class SfPairBase
    def tag; :base; end
    def build; SfHolderPair.new(self); end
  end
  class SfPairSub < SfPairBase
    def tag; :sub; end
  end

  # NEG: self from a block body (instance_exec may rebind it).
  class SfHolderBlock
    def initialize(parent); @parent = parent; end
    def read_parent; @parent.tag; end
  end
  class SfBlockOwner
    def tag; :block_owner; end
    def build; [1].each { |_| SfHolderBlock.new(self) }; end
    def other; SfHolderBlock.new(SfHolderOther.new); end
  end
  class SfHolderOther
    def tag; :holder_other; end
  end

  # NEG: self from a module method (any includer).
  class SfHolderMod
    def initialize(parent); @parent = parent; end
    def read_parent; @parent.tag; end
  end
  module SfMixin
    def build; SfHolderMod.new(self); end
  end
  class SfMixedA
    include SfMixin
    def tag; :a; end
  end
  class SfMixedB
    include SfMixin
    def tag; :b; end
  end

  # NEG: another site passes a value that is not the owner's self.
  class SfHolderMixed
    def initialize(parent); @parent = parent; end
    def read_parent; @parent.tag; end
  end
  class SfMixedOwner
    def tag; :mixed_owner; end
    def build; SfHolderMixed.new(self); end
    def build_other; SfHolderMixed.new(IvOther.new); end
  end
RUBY

OWNERS = %w[IvBox IvOther KwOne KwOneDrv KwTwo KwTwoDrv KwSplat KwSplatDrv KwPacked KwPackedDrv KwShort KwShortDrv KwPlain KwPlainDrv
            KwBase KwSub KwSubDrv KwZBase KwZSub KwZDrv KwSShortBase KwSShortSub KwSShortDrv KwPost KwPostDrv KwOpenDrv
            SfHolder SfOwner SfHolderPair SfPairBase SfPairSub SfHolderBlock SfBlockOwner SfHolderOther SfHolderMod SfMixin
            SfMixedA SfMixedB SfHolderMixed SfMixedOwner SfRebind].freeze
EXACT_TAG = /(?:EXACT_TYPED|CLOSED_WORLD_EXACT_CLASS) :\w+[?!]? /

body_of = lambda do |code, owner, fn|
  code[/^mrb_value #{owner}_#{fn}_impl\(mrb_state\* M.*?(?=^(?:static )?mrb_value \w+\(mrb_state\* M|\z)/m].to_s
end
# Guard-free and dispatch-free: an exact arm with no class test.
exact = ->(code, owner, fn) { body_of.call(code, owner, fn).match?(EXACT_TAG) && !body_of.call(code, owner, fn).include?('mrb_nil_p') }
# The old shape: a receiver the flow could not name.
guarded = lambda do |code, owner, fn|
  body = body_of.call(code, owner, fn)
  !body.empty? && !body.match?(EXACT_TAG)
end

generate = lambda do |source, dir, env: {}, **options|
  saved = env.to_h { |k, _| [k, ENV.fetch(k, nil)] }
  env.each { |k, v| ENV[k] = v }
  begin
    runtime.generate(source, dir, closed: true, only_owners: OWNERS, **options)
  ensure
    saved.each { |k, v| v ? ENV[k] = v : ENV.delete(k) }
  end
end

puts '== generated code'
Dir.mktmpdir do |dir|
  code, err = generate.call(CLASSES + KEYWORDS + SELF_CLASS, dir)

  puts ' -- CONSTRUCTOR_KEYWORDS'
  check.call('KwOne: keyword parameters and keyword calls, one class at every site: the read is exact',
             exact.call(code, 'KwOne', 'read_box'))
  check.call('KwPlain: a keyword call to an initialize without keyword parameters keeps positions 1..mand', exact.call(code, 'KwPlain', 'read_box'))
  check.call('KwBase: a super(box, mode: mode) from a subclass is a site of the base initialize and every site agrees',
             exact.call(code, 'KwBase', 'read_box'))
  check.call('NEG KwTwo: a second class at one keyword site keeps the guard', guarded.call(code, 'KwTwo', 'read_box'))
  check.call('NEG KwSplat: a **opts call withdraws the initialize', guarded.call(code, 'KwSplat', 'read_box'))
  check.call('NEG KwPacked: a splat of positionals withdraws the initialize', guarded.call(code, 'KwPacked', 'read_box'))
  check.call('NEG KwShort: a keyword call with fewer positionals than mandatory parameters withdraws the initialize',
             guarded.call(code, 'KwShort', 'read_box'))
  check.call('NEG KwZBase: a bare super withdraws the base initialize', guarded.call(code, 'KwZBase', 'read_box'))
  check.call('NEG KwSShortBase: a super with keywords and too few positionals withdraws the base initialize',
             guarded.call(code, 'KwSShortBase', 'read_box'))
  check.call('NEG KwPost: a post-mandatory parameter is refused', guarded.call(code, 'KwPost', 'read_box'))
  check.call('the refusals are on stderr with their reason',
             err.include?('CTOR KwShort#initialize refused: keyword new with fewer positionals than mandatory parameters') ||
               err.include?('CTOR KwShort#initialize refused'))
  check.call('the keyword sites are counted',
             err[/SITES [^\n]*keyword_named=(\d+)/, 1].to_i >= 5 && err.match?(/keyword_refused_short=\d+/) && err.match?(/super_keyword=\d+/))
  check.call('the pooled keyword constructor is listed', err.include?('CTOR KwOne#initialize pooled'))

  puts ' -- POOL_SELF_CLASS'
  check.call('SfHolder: self of a uniquely owned instance method is its class: the read is exact', exact.call(code, 'SfHolder', 'read_parent'))
  check.call('NEG SfHolderPair: a base and a subclass make a pair, never a single-class guard-free arm',
             !exact.call(code, 'SfHolderPair', 'read_parent'))
  check.call('NEG SfHolderBlock: self in a block body is not a method receiver', guarded.call(code, 'SfHolderBlock', 'read_parent'))
  check.call('NEG SfHolderMod: self in a module method is any includer', guarded.call(code, 'SfHolderMod', 'read_parent'))
  check.call('NEG SfHolderMixed: a second site passes a non-self value', guarded.call(code, 'SfHolderMixed', 'read_parent'))
  check.call('the pool is listed with the class of self',
             err.include?('CLASSARG SfHolder#initialize arg1 (SfOwner)') && err.include?('CLASSIVAR SfHolder#@parent (SfOwner)') &&
               err.include?('POOL_SELF_CLASS on'))

  puts ' -- worlds that withdraw the keyword pools'
  # A `new` on a receiver that is not a named class could build any class with any arguments: it withdraws every initialize
  # it can get past ENTER for. A keyword call it makes has no known count, so it withdraws all of them.
  { 'a keyword new on an unknown receiver' => "class KwOpenDrv\n  def d1(klass); klass.new(IvOther.new, mode: :b); end\nend\n",
    'a new with a packed kdict on an unknown receiver' => "class KwOpenDrv\n  def d1(klass, o); klass.new(IvOther.new, **o); end\nend\n",
    'an explicit initialize call' => "class KwOpenDrv\n  def d1(o); o.send(:initialize, IvOther.new); end\nend\n" }.each do |what, extra|
    Dir.mktmpdir do |wdir|
      wcode, werr = generate.call(CLASSES + KEYWORDS + SELF_CLASS + extra, wdir)
      check.call("#{what}: the keyword initializers lose their pools",
                 %w[KwOne KwPlain KwBase].all? { |o| guarded.call(wcode, o, 'read_box') } && werr.include?('refused'))
    end
  end

  puts ' -- worlds that withdraw POOL_SELF_CLASS'
  # A body reached through an UnboundMethod, or installed from a Method object, may run with a receiver of another class.
  { 'an UnboundMethod bound to another object' => "class SfRebind\n  def run(o); SfOwner.instance_method(:build).bind(o).call; end\nend\n",
    'a define_method from a Method object' => "class SfRebind\n  define_method(:again, SfOwner.new.method(:build))\nend\n" }.each do |what, extra|
    Dir.mktmpdir do |wdir|
      wcode, werr = generate.call(CLASSES + KEYWORDS + SELF_CLASS + extra, wdir)
      check.call("#{what}: LOADSELF stays unknown and the refusal is on stderr",
                 guarded.call(wcode, 'SfHolder', 'read_parent') && werr.match?(/POOL_SELF_CLASS off: (instance_method|define_method) at/))
    end
  end

  puts ' -- kill switches'
  { 'BC2CPP_CTOR_KEYWORDS' => [['KwOne', 'read_box'], ['KwPlain', 'read_box'], ['KwBase', 'read_box']],
    'BC2CPP_POOL_SELF_CLASS' => [['SfHolder', 'read_parent']] }.each do |var, sites|
    Dir.mktmpdir do |off_dir|
      off_code, = generate.call(CLASSES + KEYWORDS + SELF_CLASS, off_dir, env: { var => '0' })
      check.call("#{var}=0: #{sites.map(&:join).join(', ')} keep the old guard",
                 sites.all? { |owner, fn| guarded.call(off_code, owner, fn) })
    end
  end

  puts ' -- diagnostics'
  Dir.mktmpdir do |rep_dir|
    _rep_code, rep_err = generate.call(CLASSES + KEYWORDS + SELF_CLASS, rep_dir, env: { 'BC2CPP_POOL_DROP_REPORT' => '1' })
    check.call('the OPAQUE list is bucketed by cause', rep_err.include?('== ivar-class OPAQUE causes') &&
                                                       rep_err.match?(/OPAQUE_CAUSE \w+ \d+/) && rep_err.match?(/OPAQUE_ATOM \S+ \d+/))
    check.call('the dropped pools are listed by state and blocker', rep_err.include?('== class pools dropped: causes') &&
                                                                    rep_err.match?(/POOL_DROPPED \d+/) &&
                                                                    rep_err.match?(/POOL_DROP_BLOCKER \S+ .* pools=\d+/))
    check.call('the pool report does not tag the generated text', !_rep_code.include?('/*SR:'))
  end
end

if failures.empty?
  puts 'bc2cpp ivar typing check: PASS'
else
  warn "bc2cpp ivar typing check: #{failures.size} failure(s)"
  exit 1
end
