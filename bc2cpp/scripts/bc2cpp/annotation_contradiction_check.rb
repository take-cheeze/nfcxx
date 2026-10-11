# frozen_string_literal: true

# RBS_SEED_CONTRADICTION (tools/bc2cpp/annotation_contradictions.rb): a
# `# bc2cpp:` annotation that names a DIFFERENT comparable type than the one the
# analysis proved is a build error.
#
# The rule is deliberately narrow, and each exclusion below is a real case from
# this repository rather than a hypothetical:
#
#   * :nil_literal does NOT contradict. RGSS::Scene::Battle#battle_level_up_lines
#     annotates `before_level` as fixnum, and its one call site is guarded
#     (`... if before_level`), so ArgTypes proves :nil_literal. Both statements
#     are true -- the annotation is a claim about the non-nil case -- so refusing
#     it would refuse a correct annotation of the shape annotations most often
#     take. Spinel reaches the same conclusion: a signature that only turns out
#     wrong at run time "is reinterpreted rather than widened".
#   * a class name does NOT contradict. ClassAnnotations is a different lattice
#     (no shared representation with IvarLayout's :fixnum/:symbol), so comparing
#     the two would invent a disagreement rather than find one.
#   * UNKNOWN / an unrepresented type does NOT contradict. That is an absent
#     fact, not a conflicting one.
#
# So a contradiction is :fixnum against :symbol, or :symbol against :fixnum, and
# nothing else.

require 'minitest/autorun'
require 'set'
require_relative '../../tools/bc2cpp/ivar_layout'
require_relative '../../tools/bc2cpp/annotation_contradictions'

class AnnotationContradictionsTest < Minitest::Test
  C = AnnotationContradictions
  # Annotations::Annotation is args/ret keyword_init; a local stand-in keeps this
  # file from requiring the whole compiler.
  Annotation = Struct.new(:args, :ret, keyword_init: true)
  MethodDefStub = Struct.new(:irep, :owner, :name, keyword_init: true)

  def test_fixnum_against_symbol_is_a_contradiction
    assert C.contradicting?(:fixnum, :symbol)
    assert C.contradicting?(:symbol, :fixnum)
  end

  def test_agreement_is_not_a_contradiction
    refute C.contradicting?(:fixnum, :fixnum)
    refute C.contradicting?(:symbol, :symbol)
  end

  def test_nil_literal_is_a_narrowing_not_a_contradiction
    # The battle_level_up_lines shape: annotated fixnum, proved :nil_literal
    # because the only call site is behind `if before_level`.
    refute C.contradicting?(:fixnum, IvarLayout::NIL)
    refute C.contradicting?(:fixnum, :nil_literal)
  end

  def test_unknown_and_class_names_never_contradict
    refute C.contradicting?(:fixnum, IvarLayout::UNKNOWN)
    refute C.contradicting?(:fixnum, 'Game::Actor')
    refute C.contradicting?(:fixnum, nil)
    refute C.contradicting?(:array, :fixnum)
  end

  def test_find_reports_nothing_without_a_proof
    registry = { 'thing' => [MethodDefStub.new(irep: 'irep1', owner: 'K', name: 'thing')] }
    anns = { 'irep1' => Annotation.new(args: [:fixnum], ret: nil) }
    # No inferred table at all: an annotation that cannot be checked is not a
    # contradiction, it is an unverified hint -- which is the pre-existing
    # behaviour and stays sound because every consumer re-checks at runtime.
    assert_empty C.find(nil, registry, anns, nil, nil)
    assert_empty C.find(nil, registry, anns, { 'thing' => [nil] }, Set.new)
  end

  def test_find_reports_a_real_contradiction
    md = MethodDefStub.new(irep: 'irep1', owner: 'K', name: 'thing')
    registry = { 'thing' => [md] }
    anns = { 'irep1' => Annotation.new(args: [:symbol], ret: nil) }
    found = C.find(nil, registry, anns, { 'thing' => [:fixnum] }, Set.new)
    assert_equal 1, found.size
    owner, name, pos, declared, inferred = found.first
    assert_equal 'K', owner
    assert_equal 'thing', name
    assert_equal 0, pos
    assert_equal :symbol, declared
    assert_equal :fixnum, inferred
  end

  def test_return_contradiction_uses_the_fixnum_return_set
    md = MethodDefStub.new(irep: 'irep1', owner: 'K', name: 'thing')
    registry = { 'thing' => [md] }
    anns = { 'irep1' => Annotation.new(args: nil, ret: :symbol) }
    # A MEMBER of the Set is a proof that the method returns :fixnum, so a
    # `-> symbol` annotation conflicts with it.
    found = C.find(nil, registry, anns, nil, Set.new(['thing']))
    assert_equal 1, found.size
    assert_equal :return, found.first[2]
    # A NON-member is an ABSENT fact, not a conflicting one, so an empty Set
    # finds nothing -- the same rule the argument side applies.
    assert_empty C.find(nil, registry, anns, nil, Set.new)
  end
end
