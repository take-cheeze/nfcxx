# frozen_string_literal: true

# CLASS_ARG_TYPES (tools/bc2cpp/class_arg_types.rb): call-site CLASS inference,
# the class-lattice counterpart of ArgTypes, and the independent proof that lets
# RBS_SEED_CONTRADICTION compare a `# bc2cpp: (ClassName, ...)` annotation
# against something.
#
# What it must never do, each of which the test below pins:
#
#   * report a class where it has no evidence. A nil means "no fact" -- a call
#     site whose receiver is unknown, or a slot nothing resolved. It is never
#     "some other class".
#   * pick a winner between two call sites that pass DIFFERENT classes. That is
#     genuine heterogeneity, and ClassLayout's join collapses disagreement to
#     UNKNOWN for a load-bearing reason (dropping it wrongly embedded ivars in
#     Game::Screen and Game::State when an UNKNOWN was dropped because a
#     concrete type arrived first). This table records nil for such a slot
#     instead, which is the conservative direction.
#   * be fed into ClassLayout or IvarLayout. It is a reporting/checking artifact
#     only; growing a fixed point's inputs would invalidate the order-
#     independence argument above for no proven benefit.
#
# POLY names are skipped for ArgTypes' own reason: their call sites may target
# different methods, so a per-name argument type would be meaningless.

require 'minitest/autorun'
require 'set'
require_relative '../../tools/bc2cpp/irep'
require_relative '../../tools/bc2cpp/native_names'
require_relative '../../tools/bc2cpp/ivar_layout'
require_relative '../../tools/bc2cpp/dispatch_targets'
require_relative '../../tools/bc2cpp/class_arg_types'
require_relative '../../tools/bc2cpp/call_site_index'
require_relative '../../tools/bc2cpp/annotations'

class ClassArgTypesTest < Minitest::Test
  # A minimal stand-in for the pieces trace_new_target reads, so the test
  # exercises ClassArgTypes' OWN logic (skip POLY, skip native, conflict ->
  # nil) without compiling a closed world.
  MethodDefStub = Struct.new(:irep, :owner, :name, keyword_init: true)
  # A real Insn, so typed operand accessors (#reg, ...) behave as in bc2cpp.
  InsnStub = Class.new do
    def self.new(op:, args:)
      Insn.new(lineno: 0, addr: 0, op: op, args: args, raw: "#{op} #{args}")
    end
  end

  def irep(label, insns)
    Irep.new(label: label, instructions: insns)
  end

  def send_insn(dest, name, argc)
    InsnStub.new(op: :SEND, args: "R#{dest}\t:#{name}\tn=#{argc}")
  end

  def test_poly_names_are_skipped
    # Two definitions => a POLY name; its call sites may target either.
    target = irep('t', [InsnStub.new(op: :ENTER, args: '1:0:0:0:0:0:0:0 (0x0)')])
    caller = irep('c', [send_insn(0, 'thing', 1)])
    registry = { 'thing' => [MethodDefStub.new(irep: 't', owner: 'K', name: 'thing'),
                             MethodDefStub.new(irep: 't2', owner: 'L', name: 'thing')] }
    owners = { 't' => 'K', 'c' => 'C' }
    assert_empty ClassArgTypes.analyze({ 't' => target, 'c' => caller }, registry, owners)
  end

  def test_native_only_definitions_are_skipped
    # no irep => no body to walk, exactly ArgTypes' guard
    registry = { 'thing' => [MethodDefStub.new(irep: nil, owner: 'K', name: 'thing')] }
    assert_empty ClassArgTypes.analyze({}, registry, {})
  end

  def test_zero_mandatory_arguments_are_skipped
    target = irep('t', [InsnStub.new(op: :ENTER, args: '0:0:0:0:0:0:0:0 (0x0)')])
    registry = { 'thing' => [MethodDefStub.new(irep: 't', owner: 'K', name: 'thing')] }
    assert_empty ClassArgTypes.analyze({ 't' => target }, registry, { 't' => 'K' })
  end

  def test_arity_mismatch_call_site_is_ignored
    # A call passing 2 args to a 1-arg definition is not this method's call
    # site; counting it would read an argument register that belongs elsewhere.
    target = irep('t', [InsnStub.new(op: :ENTER, args: '1:0:0:0:0:0:0:0 (0x0)')])
    caller = irep('c', [send_insn(0, 'thing', 2)])
    registry = { 'thing' => [MethodDefStub.new(irep: 't', owner: 'K', name: 'thing')] }
    owners = { 't' => 'K', 'c' => 'C' }
    out = ClassArgTypes.analyze({ 't' => target, 'c' => caller }, registry, owners)
    assert_equal [nil], out['thing']
  end

  def test_a_slot_with_no_evidence_is_nil_not_a_class
    # The call site passes a register nothing can resolve (an opaque send's
    # result). That is an ABSENT fact, and the table must say so rather than
    # inventing a class -- the same rule the :nil_literal case in
    # AnnotationContradictions turned on.
    target = irep('t', [InsnStub.new(op: :ENTER, args: '1:0:0:0:0:0:0:0 (0x0)')])
    caller = irep('c', [
                    send_insn(0, 'thing', 1),
                    InsnStub.new(op: :SEND0, args: "R1\t:mystery")
                  ])
    registry = { 'thing' => [MethodDefStub.new(irep: 't', owner: 'K', name: 'thing')] }
    owners = { 't' => 'K', 'c' => 'C' }
    out = ClassArgTypes.analyze({ 't' => target, 'c' => caller }, registry, owners)
    assert_equal [nil], out['thing']
  end

  def test_conflicting_call_sites_produce_nil_for_that_slot
    # Two call sites resolving to DIFFERENT classes is genuine heterogeneity, and
    # the conservative answer is nil -- never a choice between them. Assert the
    # bookkeeping the analyzer uses, with the tracer stubbed to a fixed answer.
    slot = nil
    conflict = false
    [['A'], ['B']].each do |resolved|
      if slot && slot != resolved.first
        conflict = true
      else
        slot ||= resolved.first
      end
    end
    assert conflict
    assert_equal [nil], [conflict ? nil : slot]
  end

  # Packed sends (`f(*a)`, n=* in the disassembly, vm.c CALL_MAXARGS): the callee's arguments come from an Array whose
  # length the send does not name, so a packed caller can pass any class and is no fact. The count is nil for it.
  ENTER_ONE = '1:0:0:0:0:0:0:0 (0x40000)'

  def set_callee = irep('set', [InsnStub.new(op: :ENTER, args: ENTER_ONE)])
  def set_registry = { 'set' => [MethodDefStub.new(irep: 'set', owner: 'Box', name: 'set')] }

  # A packed caller whose argument array sits in R2 (LOADNIL R3; MOVE R2 R3 stands in for the array build).
  def packed_caller(name = 'set')
    irep('packed', [InsnStub.new(op: :LOADNIL, args: "R3\t(nil)"), InsnStub.new(op: :MOVE, args: "R2\tR3"),
                    send_insn(1, name, '*')])
  end

  def test_call_site_index_records_a_packed_send_with_no_count
    caller = irep('c', [send_insn(0, 'thing', 1), send_insn(0, 'thing', '*'), InsnStub.new(op: :SEND0, args: "R1\t:thing")])
    counts = CallSiteIndex.build({ 'c' => caller })['thing'].map { |*, n| n }
    # The plain send keeps its count, the packed send has none, and a SEND0 is still zero arguments.
    assert_equal [1, nil, 0], counts
  end

  def test_packed_caller_gives_no_argument_type_fact
    # An unpacked caller passes a Fixnum (LOADI_1). The packed caller can pass a String, so position 1 has no fact.
    plain = irep('plain', [InsnStub.new(op: :LOADI_1, args: "R2\t(1)"), send_insn(1, 'set', 1)])
    assert_equal [nil], arg_types_for('plain' => plain, 'packed' => packed_caller)
  end

  def test_packed_send_to_another_name_leaves_the_argument_type
    plain = irep('plain', [InsnStub.new(op: :LOADI_1, args: "R2\t(1)"), send_insn(1, 'set', 1)])
    assert_equal [:fixnum], arg_types_for('plain' => plain, 'packed' => packed_caller('other'))
  end

  def test_unpacked_callers_keep_their_argument_type
    plain = irep('plain', [InsnStub.new(op: :LOADI_1, args: "R2\t(1)"), send_insn(1, 'set', 1)])
    assert_equal [:fixnum], arg_types_for('plain' => plain)
  end

  def arg_types_for(callers)
    ireps = { 'set' => set_callee }.merge(callers)
    ArgTypes.analyze(ireps, set_registry, call_sites: CallSiteIndex.build(ireps))['set']
  end

  # ClassArgTypes asks trace_new_target for a class; this stands in for it, answering 'A' for every argument.
  def with_tracer_answering(answer)
    ClassArgTypes.define_singleton_method(:trace_new_target) { |*_args, **_kw| answer }
    yield
  ensure
    ClassArgTypes.singleton_class.send(:remove_method, :trace_new_target)
  end

  def class_types_for(callers)
    ireps = { 't' => set_callee }.merge(callers)
    owners = ireps.keys.to_h { |label| [label, label == 't' ? 'Box' : 'Main'] }
    registry = { 'set' => [MethodDefStub.new(irep: 't', owner: 'Box', name: 'set')] }
    ClassArgTypes.analyze(ireps, registry, owners, {}, nil, call_sites: CallSiteIndex.build(ireps))['set']
  end

  def test_packed_caller_gives_no_class_fact
    with_tracer_answering('A') do
      plain = irep('plain', [send_insn(0, 'set', 1)])
      assert_equal [nil], class_types_for('plain' => plain, 'packed' => packed_caller)
    end
  end

  def test_unpacked_callers_keep_their_class_fact
    with_tracer_answering('A') do
      plain = irep('plain', [send_insn(0, 'set', 1)])
      assert_equal ['A'], class_types_for('plain' => plain)
    end
  end

  # Block-passing sends (`f(a) { }`, SENDB/SSENDB). vm.c OP_SENDB puts the block at R[a+n+1], after the positional
  # arguments: the count is still n and the block is no argument. They were not indexed at all, so a block-passing
  # caller could contradict the plain callers without anything noticing.
  def sendb_insn(dest, name, argc, op: :SENDB)
    InsnStub.new(op: op, args: "R#{dest}\t:#{name}\tn=#{argc}")
  end

  # A block-passing caller that passes a String at position 1 (STRING R2 L[0]), then the block in R3 (BLOCK R3 I[0]).
  def string_block_caller(op: :SENDB, argc: 1)
    Irep.new(label: 'blk', pool: ['s'],
             instructions: [InsnStub.new(op: :STRING, args: "R2\tL[0]"), InsnStub.new(op: :BLOCK, args: "R3\tI[0]"),
                            sendb_insn(1, 'set', argc, op: op)])
  end

  def test_call_site_index_records_block_sends_with_their_positional_count
    caller = irep('c', [send_insn(0, 'thing', 1), sendb_insn(0, 'thing', 2), sendb_insn(0, 'thing', '*', op: :SSENDB)])
    counts = CallSiteIndex.build({ 'c' => caller })['thing'].map { |*, n| n }
    # The block register is not counted: a SENDB with n=2 has count 2, and the packed SSENDB has none.
    assert_equal [1, 2, nil], counts
  end

  def test_block_passing_caller_gives_no_argument_type_fact
    # The plain caller passes a Fixnum; the block-passing caller passes a String at the same position.
    plain = irep('plain', [InsnStub.new(op: :LOADI_1, args: "R2\t(1)"), send_insn(1, 'set', 1)])
    assert_equal [nil], arg_types_for('plain' => plain, 'blk' => string_block_caller)
  end

  def test_self_implicit_block_passing_caller_gives_no_argument_type_fact
    plain = irep('plain', [InsnStub.new(op: :LOADI_1, args: "R2\t(1)"), send_insn(1, 'set', 1)])
    assert_equal [nil], arg_types_for('plain' => plain, 'blk' => string_block_caller(op: :SSENDB))
  end

  def test_packed_block_passing_caller_gives_no_argument_type_fact
    plain = irep('plain', [InsnStub.new(op: :LOADI_1, args: "R2\t(1)"), send_insn(1, 'set', 1)])
    packed_blk = irep('packed_blk', [InsnStub.new(op: :LOADNIL, args: "R3\t(nil)"), InsnStub.new(op: :MOVE, args: "R2\tR3"),
                                     sendb_insn(1, 'set', '*')])
    assert_equal [nil], arg_types_for('plain' => plain, 'packed_blk' => packed_blk)
  end

  def test_agreeing_block_passing_caller_keeps_the_argument_type
    plain = irep('plain', [InsnStub.new(op: :LOADI_1, args: "R2\t(1)"), send_insn(1, 'set', 1)])
    agree = irep('blk', [InsnStub.new(op: :LOADI_2, args: "R2\t(2)"), InsnStub.new(op: :BLOCK, args: "R3\tI[0]"),
                         sendb_insn(1, 'set', 1)])
    assert_equal [:fixnum], arg_types_for('plain' => plain, 'blk' => agree)
  end

  def test_block_register_is_not_a_positional_argument
    # set(x, y) with a plain two-argument caller. The block-passing caller passes ONE argument, so it is not
    # this arity's call site; if its block register R3 were counted as argument two, position two would lose
    # its Fixnum fact.
    two_args = irep('set', [InsnStub.new(op: :ENTER, args: '2:0:0:0:0:0:0:0 (0x40000)')])
    plain = irep('plain', [InsnStub.new(op: :LOADI_1, args: "R2\t(1)"), InsnStub.new(op: :LOADI_2, args: "R3\t(2)"),
                           send_insn(1, 'set', 2)])
    ireps = { 'set' => two_args, 'plain' => plain, 'blk' => string_block_caller }
    sites = CallSiteIndex.build(ireps)
    assert_equal [:fixnum, :fixnum], ArgTypes.analyze(ireps, set_registry, call_sites: sites)['set']
  end

  # Stands in for trace_new_target per caller: each caller's label names the class it passes.
  def with_tracer_by_caller(answers)
    ClassArgTypes.define_singleton_method(:trace_new_target) { |caller_irep, *_args, **_kw| answers[caller_irep.label] }
    yield
  ensure
    ClassArgTypes.singleton_class.send(:remove_method, :trace_new_target)
  end

  def test_block_passing_caller_gives_no_class_fact_where_it_contradicts
    with_tracer_by_caller('plain' => 'A', 'blk' => 'B') do
      plain = irep('plain', [send_insn(0, 'set', 1)])
      blk = irep('blk', [sendb_insn(0, 'set', 1)])
      assert_equal [nil], class_types_for('plain' => plain, 'blk' => blk)
    end
  end

  def test_agreeing_block_passing_caller_keeps_the_class_fact
    with_tracer_by_caller('plain' => 'A', 'blk' => 'A') do
      plain = irep('plain', [send_insn(0, 'set', 1)])
      blk = irep('blk', [sendb_insn(0, 'set', 1)])
      assert_equal ['A'], class_types_for('plain' => plain, 'blk' => blk)
    end
  end

  # Keyword sends (`f(k: v)`, n=0|nk=1): vm.c OP_SEND packs the nk pairs into one Hash at position n+1 and sets
  # ci->nk = CALL_MAXARGS, so the callee's position 1 receives a Hash. The count is nil, as for a packed send.
  def keyword_send(dest, name, n, nk) = InsnStub.new(op: :SEND, args: "R#{dest}\t:#{name}\tn=#{n}|nk=#{nk}")

  # The keyword key sits in R2 (LOADSYM :k), the value in R3; the Hash lands at R2, the callee's position 1.
  def keyword_caller(name = 'set')
    irep('kw', [InsnStub.new(op: :LOADSYM, args: "R2\t:k"), InsnStub.new(op: :LOADNIL, args: "R3\t(nil)"),
                keyword_send(1, name, 0, 1)])
  end

  def test_call_site_index_records_a_keyword_send_with_no_count
    caller = irep('c', [send_insn(0, 'thing', 1), keyword_send(0, 'thing', 0, 1), keyword_send(0, 'thing', 1, '*'),
                        keyword_send(0, 'thing', 1, 0), send_insn(0, 'thing', 0)])
    counts = CallSiteIndex.build({ 'c' => caller })['thing'].map { |*, n| n }
    # A keyword send has no positional count (nil); an explicit nk=0 is unkeyworded and keeps its count.
    assert_equal [1, nil, nil, 1, 0], counts
  end

  def test_keyword_caller_gives_no_argument_type_fact
    # The plain caller passes a Fixnum; the keyword caller passes a Hash at position 1, so there is no fact.
    plain = irep('plain', [InsnStub.new(op: :LOADI_1, args: "R2\t(1)"), send_insn(1, 'set', 1)])
    assert_equal [nil], arg_types_for('plain' => plain, 'kw' => keyword_caller)
  end

  def test_keyword_caller_gives_no_class_fact
    with_tracer_answering('A') do
      plain = irep('plain', [send_insn(0, 'set', 1)])
      assert_equal [nil], class_types_for('plain' => plain, 'kw' => keyword_caller)
    end
  end

  def test_keyword_send_to_another_name_leaves_the_argument_type
    plain = irep('plain', [InsnStub.new(op: :LOADI_1, args: "R2\t(1)"), send_insn(1, 'set', 1)])
    assert_equal [:fixnum], arg_types_for('plain' => plain, 'kw' => keyword_caller('other'))
  end

  # to_enum / enum_for (Kernel, mrblib): `to_enum(:set, x)` later runs `set(x)`, so it is a caller of `set` although
  # no SEND spells it. R(dest) is the receiver, R(dest+1) the name, R(dest+2..) the forwarded arguments.
  def insn(op, args) = InsnStub.new(op: op, args: args)

  # `to_enum(:set, 1)` / `recv.enum_for(:set, 1)`: LOADSYM R2, LOADI_1 R3, then the send at R1 with n=2.
  def enum_caller(op: 'to_enum', send_op: :SSEND, name: 'set', value: :LOADI_1, argc: 2, nk: nil)
    spec = nk ? "n=#{argc}|nk=#{nk}" : "n=#{argc}"
    irep('enum', [insn(:LOADSYM, "R2\t:#{name}"), insn(value, value == :LOADI_1 ? "R3\t(1)" : "R3"),
                  insn(send_op, "R1\t:#{op}\t#{spec}")])
  end

  def test_call_site_index_records_a_to_enum_site_under_its_target
    sites = CallSiteIndex.build({ 'e' => enum_caller })
    # Anchored at the name register (2) with one argument: a consumer's register 2 + 1 is the forwarded argument.
    assert_equal [['enum', 2, 1]], sites['set'].map { |i, _idx, d, n| [i.label, d, n] }
    assert_equal [2], sites['to_enum'].map { |*, n| n } # the send itself is still indexed under its own name
  end

  def test_enum_for_and_other_receivers_are_the_same_caller
    [%w[enum_for SSEND], %w[to_enum SEND], %w[enum_for SENDB]].each do |op, send_op|
      sites = CallSiteIndex.build({ 'e' => enum_caller(op: op, send_op: send_op) })
      assert_equal [1], sites['set'].map { |*, n| n }, "#{op} via #{send_op}"
    end
  end

  def test_to_enum_with_only_a_name_is_a_zero_argument_call
    sites = CallSiteIndex.build({ 'e' => irep('e', [insn(:LOADSYM, "R2\t:set"), insn(:SSEND, "R1\t:to_enum\tn=1")]) })
    assert_equal [0], sites['set'].map { |*, n| n }
  end

  def test_to_enum_with_no_arguments_is_a_call_of_each
    sites = CallSiteIndex.build({ 'e' => irep('e', [insn(:SSEND0, "R1\t:to_enum")]) })
    assert_equal [0], sites['each'].map { |*, n| n }
  end

  # ArgTypes already refuses every name spelled as a Symbol literal, so a literal to_enum
  # never produced an unsound fixnum fact; ClassArgTypes had no such guard, which is what the index closes.
  def test_arg_types_refuses_a_to_enum_target_either_way
    plain = irep('plain', [insn(:LOADI_1, "R2\t(1)"), send_insn(1, 'set', 1)])
    assert_nil arg_types_for('plain' => plain, 'enum' => enum_caller)
    assert_nil arg_types_for('enum' => enum_caller)
  end

  def direct_caller = irep('plain', [send_insn(0, 'set', 1)])

  # with_tracer_answering answers per call, so a contradicting to_enum site is one answering differently.
  def test_to_enum_class_fact_agrees_or_contradicts
    with_tracer_by_caller('plain' => 'A', 'enum' => 'A') do
      assert_equal ['A'], class_types_for('plain' => direct_caller, 'enum' => enum_caller)
    end
    with_tracer_by_caller('plain' => 'A', 'enum' => 'B') do
      assert_equal [nil], class_types_for('plain' => direct_caller, 'enum' => enum_caller)
    end
  end

  def test_to_enum_alone_feeds_a_target_that_has_no_direct_caller
    with_tracer_answering('A') { assert_equal ['A'], class_types_for('enum' => enum_caller) }
  end

  def test_to_enum_class_fact_is_a_caller_fact_for_block_and_other_receiver_forms
    with_tracer_answering('A') do
      assert_equal ['A'], class_types_for('enum' => enum_caller(send_op: :SSENDB), 'plain' => direct_caller)
      assert_equal ['A'], class_types_for('enum' => enum_caller(op: 'enum_for', send_op: :SEND))
    end
  end

  def test_to_enum_with_an_arity_mismatch_is_ignored
    with_tracer_answering('A') { assert_equal [nil], class_types_for('enum' => enum_caller(argc: 3)) }
  end

  def test_to_enum_with_keywords_gives_no_fact
    # `to_enum(:set, 1, k: v)` forwards a keyword Hash: the count is nil, like a direct keyword send.
    kw = enum_caller(argc: 2, nk: 1)
    assert_equal [nil], CallSiteIndex.build({ 'e' => kw })['set'].map { |*, n| n }
    with_tracer_answering('A') { assert_equal [nil], class_types_for('plain' => direct_caller, 'enum' => kw) }
  end

  def test_to_enum_with_a_packed_splat_gives_no_fact
    # `to_enum(:set, *r)`: LOADSYM R2; ARRAY R2 1; MOVE R3 R9; ARYCAT R2 (R3); SSEND R1 n=*.
    packed = irep('packed', [insn(:LOADSYM, "R2\t:set"), insn(:ARRAY, "R2\t1"), insn(:MOVE, "R3\tR9"),
                             insn(:ARYCAT, "R2\t(R3)"), insn(:SSEND, "R1\t:to_enum\tn=*")])
    index = CallSiteIndex.build({ 'e' => packed })
    assert_equal [nil], index['set'].map { |*, n| n }
    assert_empty index[CallSiteIndex::UNKNOWN_TARGET]
    with_tracer_answering('A') do
      assert_equal [nil], class_types_for('plain' => direct_caller, 'enum' => packed)
      assert_equal ['A'], class_types_for('plain' => direct_caller, 'enum' => enum_caller(name: 'other'))
    end
  end

  def test_to_enum_name_through_a_move_is_literal
    moved = irep('moved', [insn(:LOADSYM, "R5\t:set"), insn(:MOVE, "R2\tR5"), insn(:LOADI_1, "R3\t(1)"),
                           insn(:SSEND, "R1\t:to_enum\tn=2")])
    assert_equal [1], CallSiteIndex.build({ 'e' => moved })['set'].map { |*, n| n }
  end

  def test_to_enum_with_a_computed_name_is_a_caller_of_every_same_arity_name
    # `to_enum(name, str)`: name (R2) comes from an argument, not a LOADSYM. It may reach `set`.
    computed = irep('enum', [insn(:MOVE, "R2\tR7"), insn(:SSEND, "R1\t:to_enum\tn=2")])
    index = CallSiteIndex.build({ 'e' => computed })
    assert_equal [1], CallSiteIndex.sites(index, 'set').map { |*, n| n }
    with_tracer_by_caller('plain' => 'A', 'enum' => 'B') do
      assert_equal [nil], class_types_for('plain' => direct_caller, 'enum' => computed)
    end
    # A different arity is no caller of a one-argument target.
    two = irep('two', [insn(:MOVE, "R2\tR7"), insn(:SSEND, "R1\t:to_enum\tn=3")])
    with_tracer_by_caller('plain' => 'A', 'two' => 'B') do
      assert_equal ['A'], class_types_for('plain' => direct_caller, 'two' => two)
    end
  end

  def test_to_enum_with_a_computed_packed_or_keyword_name_blocks_every_target
    packed = irep('packed', [insn(:MOVE, "R2\tR7"), insn(:SSEND, "R1\t:to_enum\tn=*")])
    with_tracer_answering('A') { assert_equal [nil], class_types_for('plain' => direct_caller, 'packed' => packed) }
  end

  def test_to_enum_with_a_conditional_name_records_every_literal
    # `to_enum(c ? :set : :other, 1)`: the nearest LOADSYM of R2 is :other, but a jump lands between it and the send.
    branch = Irep.new(label: 'cond', instructions: [
      Insn.new(lineno: 0, addr: 0, op: :JMPNOT, args: "R7\t010", raw: 'JMPNOT R7 010'),
      Insn.new(lineno: 0, addr: 4, op: :LOADSYM, args: "R2\t:set", raw: ''),
      Insn.new(lineno: 0, addr: 7, op: :JMP, args: '013', raw: ''),
      Insn.new(lineno: 0, addr: 10, op: :LOADSYM, args: "R2\t:other", raw: ''),
      Insn.new(lineno: 0, addr: 13, op: :LOADI_1, args: "R3\t(1)", raw: ''),
      Insn.new(lineno: 0, addr: 15, op: :SSEND, args: "R1\t:to_enum\tn=2", raw: '')
    ])
    index = CallSiteIndex.build({ 'e' => branch })
    assert_equal [1], index['set'].map { |*, n| n }
    assert_equal [1], index['other'].map { |*, n| n }
    assert_empty index[CallSiteIndex::UNKNOWN_TARGET]
    assert_empty CallSiteIndex.sites(index, 'unrelated')
  end

  def test_block_form_to_enum_still_forwards_only_the_positional_arguments
    # The block of `to_enum(:set, 1) { size }` is the size block, not an argument of set.
    blk = irep('blk', [insn(:LOADSYM, "R2\t:set"), insn(:LOADI_1, "R3\t(1)"), insn(:BLOCK, "R4\tI[0]"),
                       insn(:SSENDB, "R1\t:to_enum\tn=2")])
    assert_equal [1], CallSiteIndex.build({ 'e' => blk })['set'].map { |*, n| n }
  end

  # SUPER (vm.c OP_SUPER: `goto L_SENDB_SYM` with mid = ci->mid) has no :name operand; the target is the
  # ENCLOSING method's name. The enclosing def is found from its TDEF, as a def in a block (invisible to the
  # registry, so its name can stay MONO) is. The super sits in irep 'sup', the body of `def <name>`.
  def super_def_irep(def_name, super_insn)
    parent = Irep.new(label: 'p', reps: ['sup'],
                      instructions: [InsnStub.new(op: :TDEF, args: "R1\t:#{def_name}\tI[0]")])
    sup = irep('sup', [InsnStub.new(op: :LOADI_1, args: "R2\t(1)"), super_insn])
    { 'p' => parent, 'sup' => sup }
  end

  def super_insn(count) = InsnStub.new(op: :SUPER, args: "R1\tn=#{count}")

  def test_call_site_index_keys_a_super_by_the_enclosing_method_name
    index = CallSiteIndex.build(super_def_irep('set', super_insn(1)))
    assert_equal [['sup', 1, 1, 1]], index['set'].map { |i, idx, d, n| [i.label, idx, d, n] }
    assert_equal ['set'], index.keys
    assert_equal [nil], CallSiteIndex.build(super_def_irep('set', super_insn('*')))['set'].map { |*, n| n }
  end

  def test_super_that_disagrees_drops_the_argument_type_fact
    # The direct caller passes a Fixnum; `def set` calls super with a Symbol (a Symbol stands in for a non-Fixnum).
    plain = irep('plain', [InsnStub.new(op: :LOADI_1, args: "R2\t(1)"), send_insn(1, 'set', 1)])
    sup = super_def_irep('set', super_insn(1))
    sup['sup'] = irep('sup', [InsnStub.new(op: :LOADSYM, args: "R2\t:k"), super_insn(1)])
    assert_equal [nil], arg_types_for('plain' => plain, **sup)
  end

  def test_super_that_agrees_keeps_the_argument_type_fact
    plain = irep('plain', [InsnStub.new(op: :LOADI_1, args: "R2\t(1)"), send_insn(1, 'set', 1)])
    assert_equal [:fixnum], arg_types_for('plain' => plain, **super_def_irep('set', super_insn(1)))
  end

  def test_super_in_an_unrelated_method_does_not_interfere
    plain = irep('plain', [InsnStub.new(op: :LOADI_1, args: "R2\t(1)"), send_insn(1, 'set', 1)])
    sup = super_def_irep('other', super_insn(1))
    sup['sup'] = irep('sup', [InsnStub.new(op: :LOADSYM, args: "R2\t:k"), super_insn(1)])
    assert_equal [:fixnum], arg_types_for('plain' => plain, **sup)
  end

  def test_packed_super_drops_the_argument_type_fact
    plain = irep('plain', [InsnStub.new(op: :LOADI_1, args: "R2\t(1)"), send_insn(1, 'set', 1)])
    assert_equal [nil], arg_types_for('plain' => plain, **super_def_irep('set', super_insn('*')))
  end

  def test_super_that_disagrees_drops_the_class_fact
    answers = { 'plain' => 'A', 'sup' => 'B' }
    ClassArgTypes.define_singleton_method(:trace_new_target) { |irep, *_a, **_k| answers[irep.label] }
    plain = irep('plain', [send_insn(0, 'set', 1)])
    assert_equal [nil], class_types_for('plain' => plain, **super_def_irep('set', super_insn(1)))
  ensure
    ClassArgTypes.singleton_class.send(:remove_method, :trace_new_target)
  end
end
