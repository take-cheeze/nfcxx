#!/usr/bin/env ruby
# encoding: UTF-8
# Prove the ANCESTOR_MIXINS_SUPPORT whole-world `include`/`prepend` scan
# (tools/bc2cpp/bc2cpp.rb's build_registry) and the `super`-soundness guard
# it feeds (CodeGen#super_reaches_superclass?) both read a real closed world
# correctly -- the fact SUPER_SUPPORT used to assert by hand per SUPER_TARGETS
# entry (docs/adr: no `include`d module sits between a class and its declared
# superclass, so a `super` really lands on the superclass).
#
# This is a *static* check on a purpose-built synthetic closed world (not the
# real gems), so every expected outcome is known by construction -- it drives
# the real mrbc + the real build_registry + the real CodeGen guard rather than
# reimplementing any of them. The real-project golden coverage check
# (scripts/bc2cpp/coverage_check.bash) proves the same guard never wrongly
# declines a shipped `super`; this proves it also never WRONGLY ACCEPTS one a
# module would intercept, and that the scan recognizes every include/prepend
# shape (self-implicit, transitive, prepend, and an unresolvable explicit
# receiver flagged as unknown).
# It also checks typed method lookup through included/prepended modules, lexical
# constant resolution, and the Ruby precedence order before emitting a guarded
# direct call for a fresh instance.
#
# It also drives ZSUPER_GENERAL_SUPPORT (CodeGen#zsuper_forward_plan +
# compile_zsuper_forward, docs/adr/0159): the general bare-`super`-forwards-own-
# args-to-a-compiled-superclass plan, asserting it fires for the clean shape
# (and agrees from either half of the ARGARY/SUPER pair) and declines on a
# block-param method and on an owner the mixin guard refuses -- the recognition
# the optcarrot APU `#initialize`/`#poke_*` sites exercise end-to-end.
#
# Usage: MRBC=path/to/host/mrbc ruby scripts/bc2cpp/include_ancestor_check.rb

require 'tmpdir'

ROOT = File.expand_path('../..', __dir__)
require_relative '../../tools/bc2cpp/bc2cpp'

SRC = <<~'RUBY'
  module Mfoo
    def foo; :modfoo; end
  end
  def object_mixin_method; :object_method; end
  module Mbar
    def bar; :mbar; end
  end
  module MfooLatest
    def foo; :latest; end
  end
  module Mtrans_b
    def foo; :via_b; end
  end
  module Mtrans_a
    include Mtrans_b
  end
  class Included
    include Mfoo
  end
  class IncludedOverride
    include Mfoo
    def foo; :class_foo; end
  end
  class IncludesOrder
    include Mfoo
    include MfooLatest
  end
  class IncludesTransitive
    include Mtrans_a
  end
  class IncludesObject
    include Mbar
  end
  class IncludedCaller
    def call; Included.new.foo; end
  end
  module Game
    module Mlocal
      def local; :local; end
    end
    class IncludesLocal
      include Mlocal
    end
    class IncludesQualified
      include Game::Mlocal
    end
    class IncludesAbsolute
      include ::Game::Mlocal
    end
  end
  class Base
    def foo; :base; end
  end
  class Intervening < Base
    include Mfoo
    def foo; super; end
  end
  class Safe < Base
    include Mbar
    def foo; super; end
  end
  class Transitive < Base
    include Mtrans_a
    def foo; super; end
  end
  class Prepended < Base
    prepend Mfoo
    def foo; super; end
  end
  class PlainSuper < Base
    def foo; super; end
  end
  class UnknownMixin < Base
    String.include Mfoo
    def foo; super; end
  end
  # ZSUPER_GENERAL_SUPPORT shapes (the general zsuper-forward plan):
  class ZBase
    def initialize(a, b)
      @a = a
      @b = b
    end
  end
  class ZClean < ZBase
    def initialize(p, q)
      super
      @c = 1
    end
  end
  class ZBlock < ZBase
    def initialize(p, q, &blk)
      super
    end
  end
  class ZInclude < ZBase
    include Mbar
    def initialize(p, q)
      super
    end
  end
RUBY

failures = []
check = lambda do |what, actual, expected|
  if actual == expected
    puts "  ok  #{what}"
  else
    puts "  FAIL #{what}: expected #{expected.inspect}, got #{actual.inspect}"
    failures << what
  end
end

Dir.mktmpdir do |dir|
  src = File.join(dir, 'synthetic.rb')
  File.write(src, SRC)

  symbol = 'bc2cpp_include_ancestor_check'
  ireps, root_label = compile_ireps(src, symbol, dir)
  order = dfs_order(ireps, root_label)
  registry, superclass_of, _container_constants, included_modules, prepended_modules, unknown_mixins,
    _struct_members, class_decls, walked = build_registry(ireps, root_label)

  # -- build_registry's own whole-world mixin scan (presence/shape only) --
  check.call('Intervening records an include', included_modules['Intervening'].is_a?(Array), true)
  check.call('Safe records an include', included_modules['Safe'].is_a?(Array), true)
  check.call('Transitive records an include', included_modules['Transitive'].is_a?(Array), true)
  check.call('Mtrans_a itself records an include', included_modules['Mtrans_a'].is_a?(Array), true)
  check.call('Prepended records a prepend', prepended_modules['Prepended'].is_a?(Array), true)
  check.call('Prepended records no plain include', included_modules['Prepended'], nil)
  check.call('PlainSuper records no include', included_modules['PlainSuper'], nil)
  check.call('UnknownMixin (explicit-receiver include) is flagged unknown',
             unknown_mixins.include?('UnknownMixin'), true)
  check.call('Intervening is NOT flagged unknown', unknown_mixins.include?('Intervening'), false)
  check.call('unqualified include resolves through lexical nesting to Game::Mlocal',
             included_modules['Game::IncludesLocal'], ['Game::Mlocal'])
  check.call('qualified include retains its explicit module path',
             included_modules['Game::IncludesQualified'], ['Game::Mlocal'])
  check.call('absolute include retains its root module path',
             included_modules['Game::IncludesAbsolute'], ['Game::Mlocal'])

  # -- CodeGen's own re-derived super-soundness guard (conservative: any plain
  #    include -> decline; prepend-only / no-include -> reach; unknown -> decline) --
  gen = CodeGen.new(ireps, registry, {}, {}, {}, {}, superclass_of, {}, {}, {}, {}, Set.new, nil, nil, nil,
                    included_modules, prepended_modules, unknown_mixins, analysis_only: true)
  lookup_world = Object.new
  lookup_world.define_singleton_method(:inherited_lookup_safe?) { |_name, _owner| true }
  lookup_world.define_singleton_method(:stable_constant_identity?) { |_owner| true }
  lookup_gen = CodeGen.new(ireps, registry, {}, {}, {}, {}, superclass_of, {}, {}, {}, {}, Set.new, nil, nil, nil,
                           included_modules, prepended_modules, unknown_mixins, closed_world: lookup_world)
  included_target = lookup_gen.send(:closed_world_lookup_target, 'foo', 'Included', Set.new)
  typed_included_target = lookup_gen.send(:closed_world_inherited_target, 'foo', 'Included')
  override_target = lookup_gen.send(:closed_world_lookup_target, 'foo', 'IncludedOverride', Set.new)
  include_order_target = lookup_gen.send(:closed_world_lookup_target, 'foo', 'IncludesOrder', Set.new)
  prepend_target = lookup_gen.send(:closed_world_lookup_target, 'foo', 'Prepended', Set.new)
  transitive_target = lookup_gen.send(:closed_world_lookup_target, 'foo', 'IncludesTransitive', Set.new)
  object_target = lookup_gen.send(:closed_world_lookup_target, 'object_mixin_method', 'IncludesObject', Set.new)
  check.call('included module method resolves to its implementation',
             [included_target[0]&.owner, included_target[0]&.name, included_target[1]], ['Mfoo', 'foo', true])
  check.call('typed receiver can select the included module method under its exact class guard',
             [typed_included_target&.owner, typed_included_target&.name], ['Mfoo', 'foo'])
  check.call('class method wins over an included module method',
             [override_target[0]&.owner, override_target[0]&.name, override_target[1]],
             ['IncludedOverride', 'foo', true])
  check.call('most recently included module wins method lookup',
             [include_order_target[0]&.owner, include_order_target[0]&.name, include_order_target[1]],
             ['MfooLatest', 'foo', true])
  check.call('prepended module wins over the class method',
             [prepend_target[0]&.owner, prepend_target[0]&.name, prepend_target[1]],
             ['Mfoo', 'foo', true])
  check.call('nested module include resolves transitively',
             [transitive_target[0]&.owner, transitive_target[0]&.name, transitive_target[1]],
             ['Mtrans_b', 'foo', true])
  check.call('default superclass lookup continues through Object after included modules',
             [object_target[0]&.owner, object_target[0]&.name, object_target[1]],
             ['Object', 'object_mixin_method', true])
  reaches = lambda do |owner|
    def_ = registry['foo'].find { |d| d.owner == owner }
    raise "no foo def for #{owner}" unless def_

    gen.super_reaches_superclass?(def_)
  end
  check.call('Intervening: has an include -> decline', reaches.call('Intervening'), false)
  check.call('Safe: has an include -> decline (conservative)', reaches.call('Safe'), false)
  check.call('Transitive: has an include -> decline', reaches.call('Transitive'), false)
  check.call('Prepended: prepend never intervenes -> reaches Base', reaches.call('Prepended'), true)
  check.call('PlainSuper: no includes -> reaches Base', reaches.call('PlainSuper'), true)
  check.call('UnknownMixin: unresolvable include -> decline', reaches.call('UnknownMixin'), false)

  # -- ZSUPER_GENERAL_SUPPORT: the general zsuper-forward plan + emitted call --
  zsuper_plan = lambda do |owner, meth|
    def_ = registry[meth].find { |d| d.owner == owner }
    raise "no #{owner}##{meth} in registry" unless def_

    ir = ireps[def_.irep]
    sup = ir.instructions.index { |i| i.op == 'SUPER' }
    ary = ir.instructions.index { |i| i.op == 'ARGARY' }
    # `idx` may name either half of the pair -- assert BOTH agree.
    [gen.zsuper_forward_plan(def_, ir, sup), gen.zsuper_forward_plan(def_, ir, ary)]
  end
  clean = zsuper_plan.call('ZClean', 'initialize')
  check.call('ZClean: general zsuper plan (m=2 -> ZBase#initialize)',
             clean[0] && [clean[0][:m], clean[0][:target_def].owner, clean[0][:target_def].name],
             [2, 'ZBase', 'initialize'])
  check.call('ZClean: plan agrees from the ARGARY and the SUPER index', clean[0], clean[1])
  check.call('ZBlock: block-param method -> no plan', zsuper_plan.call('ZBlock', 'initialize')[0], nil)
  check.call('ZInclude: include guard -> no plan', zsuper_plan.call('ZInclude', 'initialize')[0], nil)
  target = registry['initialize'].find { |d| d.owner == 'ZBase' }
  check.call('compile_zsuper_forward forwards self + r1, r2 into the superclass _impl',
             !!gen.compile_zsuper_forward(target, 4, 2)[/=\s*\w+_impl\(M, self, r1, r2\);/], true)
end

Dir.mktmpdir do |dir|
  source = File.join(dir, 'included_dispatch.rb')
  File.write(source, <<~'RUBY')
    module IncludedDispatchModule
      def value; 7; end
    end
    class IncludedDispatchClass
      include IncludedDispatchModule
    end
    class OtherDispatchClass
      def value; 9; end
    end
    class IncludedDispatchCaller
      def call; IncludedDispatchClass.new.value; end
    end
  RUBY
  dispatch_ireps, dispatch_root = compile_ireps(source, 'bc2cpp_included_dispatch_check', dir)
  dispatch_registry, dispatch_supers, _classes, dispatch_included, dispatch_prepended, dispatch_unknown,
    _structs, dispatch_decls, dispatch_walked = build_registry(dispatch_ireps, dispatch_root)
  UniqueClassNames.table = UniqueClassNames.analyze(dispatch_ireps, dispatch_root, [], [])
  ConstructClassNames.table = ConstructClassNames.analyze(dispatch_ireps, dispatch_root, UniqueClassNames.table.values)
  dispatch_world = ClosedWorld.new(ireps: dispatch_ireps, registry: dispatch_registry,
                                  class_decls: dispatch_decls, walked: dispatch_walked,
                                  native_paths: [], ruby_paths: [])
  dispatch_gen = CodeGen.new(dispatch_ireps, dispatch_registry, {}, {}, {}, {}, dispatch_supers, {}, {}, {}, {}, Set.new,
                             nil, nil, nil, dispatch_included, dispatch_prepended, dispatch_unknown,
                             closed_world: dispatch_world)
  caller_def = dispatch_registry.fetch('call').find { |definition| definition.owner == 'IncludedDispatchCaller' }
  caller_code = dispatch_gen.compile_method(caller_def.irep).fetch(:code)
  # The receiver is a fresh `Klass.new` (ADR 0289: EXACT_TYPED), so the guard of the inherited TYPED call
  # can only be true and goes with its mrb_funcall fallback.
  check.call('fresh exact-class receiver emits a guard-free direct call to the included module method',
             caller_code.include?('EXACT_TYPED :value -> IncludedDispatchModule#value') &&
               caller_code.include?('IncludedDispatchModule_value_impl') && !caller_code.include?('CLOSED_WORLD_TYPED_INHERITED'), true)
end

if failures.empty?
  puts 'bc2cpp include/prepend ancestor + general zsuper check: PASS'
else
  warn "bc2cpp include/prepend ancestor + general zsuper check: #{failures.size} failure(s)"
  exit 1
end
