#!/usr/bin/env ruby
# frozen_string_literal: true

# ArrayElementLayout / HashElementLayout soundness (ELEMENT_CLASS_SUPPORT, tools/bc2cpp/element_layouts.rb). The
# strict hint tier forces ELEMENT hints (docs/adr/0419), so an element fact the program can break is a wrong
# answer, not a failed guard. Each negative case below was a wrong fact before the fix it names:
#   - JOIN_DOMINANCE (ADR 0261): `@a = c ? [A.new] : [B.new]` read only the textually nearest arm;
#   - a call whose result was not resolved let the walk read the register's older, overwritten value
#     (`@a << @b[0].to_s` took @b's element class);
#   - `(@a ||= []) << v` was not attributed to @a, so v was never checked.
# ELEMENT_SIGNATURE_CHECK: an RBS `@x: Array[C]` seed must agree with every traced site.
# Run: MRBC=... ruby scripts/bc2cpp/element_layout_soundness_check.rb

require 'tmpdir'
require_relative '../../tools/bc2cpp/bc2cpp'

SRC = <<~'RUBY'
  class A; def a; end; def to_b; 1; end; end
  class B; def b; end; end
  class Box
    def initialize(c, other)
      @good = [A.new]
      @good << A.new
      @branch = c ? [A.new] : [B.new]
      @either = (other || [])
      @either << A.new
      (@lazy ||= []) << B.new
      @lazy << A.new
      @lazy_ok = []
      (@lazy_ok ||= []) << A.new
      @lazy_ok << A.new
      @src = [A.new]
      @stale = []
      @stale << @src[0].to_b
      @read = []
      @read << @src[0]
      @values = { k: A.new }
      @values_branch = c ? { k: A.new } : { k: B.new }
    end
  end
RUBY

ARRAYS = %w[good branch either lazy lazy_ok src stale read].freeze
HASHES = %w[values values_branch].freeze

failures = []
check = lambda do |what, ok|
  puts "  #{ok ? 'ok  ' : 'FAIL'} #{what}"
  failures << what unless ok
end

Dir.mktmpdir do |dir|
  source = File.join(dir, 'element_layout.rb')
  File.write(source, SRC)
  ireps, root_label = compile_ireps(source, 'bc2cpp_element_layout', dir)
  registry = build_registry(ireps, root_label)[0]
  owners = Set.new(registry.values.flatten.map(&:owner))
  annotations = ElementAnnotations.extract(ireps, registry, owners)
  class_annotations = ClassAnnotations.extract(ireps, registry, owners)
  layout = { 'Box' => ARRAYS.to_h { |n| [n, 'Array'] }.merge(HASHES.to_h { |n| [n, 'Hash'] }) }
  sites = {}
  reason = {}
  raw = ArrayElementLayout.analyze(ireps, registry, layout, class_annotations, annotations,
                                   poison_reason: reason, site_classes: sites)
  known = ArrayElementLayout.known(raw).fetch('Box', {})
  hash_sites = {}
  hash_known = HashElementLayout.known(
    HashElementLayout.analyze(ireps, registry, layout, class_annotations, annotations, raw, site_classes: hash_sites)
  ).fetch('Box', {})

  # Positive: every writer traces to A.
  check.call('straight-line literal and push keep Array<A>', known['good'] == 'A')
  check.call('(@x ||= []) << v with agreeing writes keeps Array<A>', known['lazy_ok'] == 'A')
  check.call('a known-element read (@src[0]) still traces', known['read'] == 'A')
  check.call('Hash literal value keeps Hash<A>', hash_known['values'] == 'A')
  # Negative: each was a wrong fact before.
  check.call('a branch join does not read just the nearest arm', !known.key?('branch'))
  check.call('`other || []` does not hide the other operand', !known.key?('either'))
  check.call('(@x ||= []) << B.new is attributed to @x', !known.key?('lazy') && reason.dig('Box', 'lazy') == :any)
  check.call('an unresolved call does not expose the register\'s older value', known['stale'] != 'A')
  check.call('a Hash branch join does not read just the nearest arm', !hash_known.key?('values_branch'))

  # ELEMENT_SIGNATURE_CHECK.
  sig = lambda do |name, kind, element|
    RbsSignatures::IvarSig.new(owner: 'Box', name: "@#{name}", loc: RbsSignatures::Loc.new('fixture.rbs', 1, 1),
                               type: RbsSignatures::Type.new(kind: kind, element: element, text: element))
  end
  conflicts = lambda do |*sigs|
    AnnotationContradictions.ivar_element_conflicts(sigs.to_h { |s| [[s.owner, s.name], s] }, sites, hash_sites)
  end
  check.call('a declared element every traced site agrees with is accepted',
             conflicts.call(sig.call('good', :array, 'A'), sig.call('values', :hash, 'A')).empty?)
  rows = conflicts.call(sig.call('lazy', :array, 'A'))
  check.call('a declared element a traced site contradicts is reported',
             rows.size == 1 && rows.first[1] == 'Array[A]' && rows.first[2].include?('B'))
  check.call('a declared Hash value a traced site contradicts is reported',
             conflicts.call(sig.call('values', :hash, 'B')).size == 1)
end

if failures.empty?
  puts 'element_layout_soundness_check: all ok'
else
  puts "element_layout_soundness_check: #{failures.size} failure(s)"
  exit 1
end
