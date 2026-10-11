#!/usr/bin/env ruby
# frozen_string_literal: true

# Check CLASS_NARROWING (docs/adr/0375): inside the region a runtime class test dominates, the tested variable's
# class set is narrowed, so `x.name` there is proven where the same call outside the test dispatches by name.
#
# 0. The flow with a stub oracle (host only, no MRBC): a test narrows both edges and a copy chain, a captured register,
#    a rewrite, a call before an ivar's test, a join, `a || b`, `raise` and the chain of `case x when C` do what they say.
# 1. Generated code (needs MRBC): every narrowing form (`is_a?`, `kind_of?`, `instance_of?`, `C === x`, `case/when`
#    with one and several classes and the else-branch complement, `nil?` and `!` as a value, `respond_to?`, early
#    `return`/`raise`/`next`, `&&`, `||` and `?:` joins, an ivar, a core class test) does less dispatch work than the
#    same fixture with BC2CPP_CLASS_NARROWING=0; each negative (a reassignment in the region, a block that writes the
#    variable, a call between the test and an ivar use, a loop back-edge, a handler edge, a global, a join with a path
#    that never tested, the test of another variable) keeps exactly the work it had. Each way of losing the proof (a
#    Ruby `is_a?`, `kind_of?`, `instance_of?`, `===`, `nil?`, `!` or `respond_to?`, an alias or computed definition of
#    them, a singleton, a BasicObject subclass, a dynamic or outside subclass, a subclass of the core class) withdraws
#    it, and only it.
# 2. Behaviour on real mruby (needs a mruby build and g++): the compiled answers equal the interpreted ones for every
#    receiver a wrong proof would mis-dispatch (a subclass of the tested class, an unrelated class, nil, core values),
#    the proven sites make no dynamic dispatch, and a class the proof does not know (made from outside the analysed
#    world) raises the CLASS_NARROWING guard violation instead of calling a body of another class.
#
# Usage: [MRBC=path/to/mrbc BC2CPP_MRUBY_FULL=dir BC2CPP_MRUBY_CORE=dir] ruby scripts/bc2cpp/class_narrowing_check.rb
# CN_UNIT_ONLY=1 runs only the stub-oracle half; CN_GENERATED_ONLY=1 skips the behavioural half; CN_SKIP_WORLDS=1 the withdrawal worlds and CN_WORLDS=<regexp> keeps
# only the worlds it matches (the mutation check uses them to run only what a mutant can break).

require 'fileutils'
require 'set'
require 'tmpdir'
require_relative 'fixture_runtime'
# The flow comes from the tree under test (BC2CPP_TOOL, a mutant copy in the mutation check), not from this checkout.
tool_dir = ENV['BC2CPP_TOOL'] ? File.dirname(File.expand_path(ENV['BC2CPP_TOOL'])) : File.expand_path('../../tools/bc2cpp', __dir__)
%w[irep bytecode_ir numeric_flow].each { |lib| require File.join(tool_dir, lib) }

failures = []
check = lambda do |what, condition|
  puts "  #{condition ? 'ok  ' : 'FAIL'} #{what}"
  failures << what unless condition
end

runtime = Bc2cppFixtureRuntime

CLASSES = <<~RUBY
  class CnShape
    def name; 1; end
    def kind; :shape; end
    def facet; :shape_facet; end
  end

  class CnCircle < CnShape
    def name; 11; end
    def facet; :circle_facet; end
  end

  class CnSquare < CnShape
    def name; 22; end
  end

  # A grandchild: the positive set of `is_a?(CnCircle)` must name it, or the guard violation fires.
  class CnBigCircle < CnCircle
    def name; 111; end
  end

  class CnOther
    def name; 33; end
    def kind; :other; end
  end
RUBY

# `name` is spelled by natives (RGSS, Struct), so an unproven receiver keeps a by-name else.
FIXTURE = <<~RUBY
  class CnFx
    # -- positives: the test dominates x.name
    def pos_is_a(x); if x.is_a?(CnShape) then x.name else 0 end; end
    def pos_kind_of(x); if x.kind_of?(CnShape) then x.name else 0 end; end
    def pos_instance_of(x); if x.instance_of?(CnCircle) then x.name else 0 end; end
    def pos_eqq(x); if CnShape === x then x.name else 0 end; end
    def pos_case(x); case x when CnShape then x.name else 0 end; end
    def pos_case_multi(x); case x when CnCircle, CnSquare then x.name else 0 end; end
    def pos_case_else(f); x = f ? CnCircle.new : CnSquare.new; case x when CnCircle then 1 else x.name end; end
    def pos_early_return(x); return 0 unless x.is_a?(CnShape); x.name; end
    def pos_early_raise(x); raise ArgumentError, 'no' unless x.is_a?(CnShape); x.name; end
    def pos_next(xs); xs.map { |x| next 0 unless x.is_a?(CnShape); x.name }; end
    def pos_and(x); x.is_a?(CnShape) && x.name; end
    def pos_or(x); (x.is_a?(CnCircle) || x.is_a?(CnSquare)) ? x.name : 0; end
    def pos_ternary(x); x.is_a?(CnShape) ? x.name : 0; end
    def pos_copy(x); ok = x.is_a?(CnShape); ok ? x.name : 0; end
    def pos_nil_value(f); x = f ? CnCircle.new : nil; v = x.nil?; if v then 0 else x.name end; end
    def pos_not(f); x = f ? CnCircle.new : nil; if !x then 0 else x.name end; end
    def pos_respond(x); x.respond_to?(:facet) ? x.facet : 0; end
    def pos_class_eq(x); x.class == CnCircle ? x.name : 0; end
    def pos_ivar(x); @cn = x; if @cn.is_a?(CnShape) then @cn.name else 0 end; end
    def pos_loop(x); n = 0; while x.is_a?(CnShape); n += x.name; x = nil; end; n; end
    def pos_array(x); if x.is_a?(Array) then x.size else 0 end; end
    def pos_hash(x); if x.is_a?(Hash) then x.size else 0 end; end
    def pos_string(x); if x.is_a?(String) then x.size else 0 end; end
    def pos_integer(x); x.is_a?(Integer) ? x + 1 : 0; end

    # -- negatives: the narrowing must not reach the use
    def neg_none(x); x.name; end
    def neg_other_var(x, y); if y.is_a?(CnShape) then x.name else 0 end; end
    def neg_reassign(x, y); if x.is_a?(CnShape); x = y; x.name; else 0; end; end
    def neg_block_write(x, y); if x.is_a?(CnShape); [1].each { x = y }; x.name; else 0; end; end
    def neg_call_between(x); @cn = x; if @cn.is_a?(CnShape); bump_cn; @cn.name; else 0; end; end
    def neg_global(x); $cn_g = x; if $cn_g.is_a?(CnShape) then $cn_g.name else 0 end; end
    def neg_loop_swap(x, y)
      n = 0
      if x.is_a?(CnShape)
        i = 0
        while i < 2
          n += x.name
          x = y
          i += 1
        end
      end
      n
    end
    def neg_rescue(x, y)
      return 0 unless x.is_a?(CnShape)
      begin
        x = y
        raise 'boom'
      rescue RuntimeError
        x.name
      end
    end
    def neg_join_test(x, f); v = f ? x.is_a?(CnShape) : true; v ? x.name : 0; end
    def neg_stale_test(x, y); ok = x.is_a?(CnShape); x = y; ok ? x.name : 0; end
    def neg_stale_ivar(x); @cn = x; ok = @cn.is_a?(CnShape); bump_cn; ok ? @cn.name : 0; end
    def neg_false_edge(x); if x.is_a?(CnShape) then 0 else x.name end; end
    def neg_or_other(x, y); (x.is_a?(CnCircle) || y) ? x.name : 0; end
    def bump_cn; @cn = CnOther.new; end
  end
RUBY

OWNERS = %w[CnShape CnCircle CnSquare CnBigCircle CnOther CnFx CnGhost CnList].freeze
POSITIVE = %w[pos_is_a pos_kind_of pos_instance_of pos_eqq pos_case pos_case_multi pos_case_else pos_early_return
              pos_early_raise pos_next pos_and pos_or pos_ternary pos_copy pos_nil_value pos_not pos_respond pos_class_eq pos_ivar
              pos_loop pos_array pos_hash pos_string pos_integer].freeze
NEGATIVE = %w[neg_none neg_other_var neg_reassign neg_block_write neg_call_between neg_global neg_loop_swap neg_rescue
              neg_join_test neg_stale_test neg_stale_ivar neg_false_edge neg_or_other].freeze

# The positives each test spelling carries, so a world that breaks one of them names exactly those.
IS_A = %w[pos_is_a pos_early_return pos_early_raise pos_next pos_and pos_or pos_ternary pos_copy pos_ivar pos_loop
          pos_array pos_hash pos_string pos_integer].freeze
EQQ = %w[pos_eqq pos_case pos_case_multi pos_case_else].freeze
USER_CLASS = %w[pos_is_a pos_kind_of pos_eqq pos_case pos_case_else pos_early_return pos_early_raise pos_next pos_and
                pos_ternary pos_copy pos_ivar pos_loop pos_respond].freeze
RESPOND = %w[pos_respond].freeze
CLASS_EQ = %w[pos_class_eq].freeze

# World name => extra Ruby or outside gem files, and the positives it must withdraw (`kept`): they keep the work
# the kill switch keeps. Every other positive still loses work.
WORLDS = {
  'a Ruby is_a? definition' => { ruby: "class CnOther\n  def is_a?(k); true; end\nend\n", kept: IS_A },
  'a Ruby kind_of? definition' => { ruby: "class CnOther\n  def kind_of?(k); true; end\nend\n", kept: %w[pos_kind_of] },
  'a Ruby instance_of? definition' => { ruby: "class CnOther\n  def instance_of?(k); true; end\nend\n", kept: %w[pos_instance_of] },
  'a Ruby === definition on a class' => { ruby: "class CnShape\n  def self.===(o); true; end\nend\n", kept: EQQ },
  'a Ruby === definition on Module' => { ruby: "class Module\n  def ===(o); true; end\nend\n", kept: EQQ },
  'a Ruby nil? definition' => { ruby: "class CnOther\n  def nil?; true; end\nend\n", kept: %w[pos_nil_value] },
  'a Ruby ! definition' => { ruby: "class CnOther\n  def !; true; end\nend\n", kept: %w[pos_not] },
  'a Ruby == definition on a class object' => { ruby: "class CnShape\n  def self.==(o); true; end\nend\n", kept: CLASS_EQ },
  'a Ruby == definition on Object' => { ruby: "class Object\n  def ==(o); true; end\nend\n", kept: CLASS_EQ },
  # A module mixed into Class can replace `new` too, so the classes `.new` makes lose their exactness as well.
  'a module mixed into Class' => {
    ruby: "module CnMix\n  def ==(o); true; end\nend\nclass Class\n  include CnMix\nend\n",
    kept: CLASS_EQ + %w[pos_case_else pos_nil_value pos_not]
  },
  'a Ruby class definition' => { ruby: "class CnOther\n  def class; CnCircle; end\nend\n", kept: CLASS_EQ },
  'a Ruby respond_to? definition' => { ruby: "class CnOther\n  def respond_to?(n, p = false); true; end\nend\n", kept: RESPOND },
  'a Ruby respond_to_missing? definition' => {
    ruby: "class CnOther\n  def respond_to_missing?(n, p = false); true; end\nend\n", kept: RESPOND
  },
  'an alias of is_a?' => { ruby: "class CnOther\n  alias_method :is_a?, :kind\nend\n", kept: IS_A },
  # A name installed from a computed list may be any name: every gate that reads the installed names withdraws.
  'a definition from a computed list' => {
    ruby: "class CnOther\n  [:is_a?].each { |n| define_method(n) { |k| true } }\nend\n", kept: POSITIVE
  },
  'an alias of facet' => { ruby: "class CnOther\n  alias_method :facet, :kind\nend\n", kept: RESPOND },
  'an instance with a singleton method' => {
    ruby: "class CnFx\n  def single; o = CnCircle.new; def o.name; 99; end; o; end\nend\n", kept: POSITIVE
  },
  'a BasicObject subclass' => {
    ruby: "class CnGhost < BasicObject\nend\n", kept: IS_A + %w[pos_kind_of pos_instance_of pos_nil_value pos_respond pos_class_eq]
  },
  'a subclass of Array' => { ruby: "class CnList < Array\nend\n", kept: %w[pos_array] },
  'a dynamic subclass of CnShape' => {
    ruby: "class CnFx\n  def dyn; Class.new(CnShape).new; end\nend\n", kept: USER_CLASS
  },
  'an outside source subclasses CnShape' => {
    gem: { 'mrblib/cn_kid.rb' => "class CnShapeKid < CnShape\n  def name; 7; end\nend\n" }, kept: USER_CLASS, generated_only: true
  }
}.freeze

gem_dir = lambda do |root, name, files|
  File.join(root, name).tap do |gem|
    files.each { |rel, text| FileUtils.mkdir_p(File.dirname(File.join(gem, rel))) && File.write(File.join(gem, rel), text) }
  end
end

# What a function still does by name or through a chain the narrowing would have shortened, and its by-name lines.
DISPATCH = /\bbc2cpp_send\(|\bmrb_funcall(?:_id|_with_block|_argv)?\(|\bbc2cpp_funcall_argv\(/
WORK = /#{DISPATCH.source}|^\s*\/\/ (?:POLY_SMALL_N|USER_RECEIVER_CASES|NILABLE_RECEIVER)\b|\bbc2cpp_nil_receiver|\bbc2cpp_nomethod\w*\(M|\bbc2cpp_slow_\w+\(M/
# The method body and the bodies of the blocks compiled out of it.
body_all = lambda do |code, fn|
  code.scan(/^(?:static )?mrb_value CnFx_#{fn}_(?:impl|block\w*_impl)\(mrb_state\* M.*?(?=^(?:static )?mrb_value \w+\(mrb_state\* M|\z)/m).join
end
dispatches = ->(code, fn) { body_all.call(code, fn).scan(DISPATCH).size }
work = ->(code, fn) { body_all.call(code, fn).scan(WORK).size }

generate = lambda do |source, dir, closed: true, env: {}, **options|
  saved = env.to_h { |k, _| [k, ENV.fetch(k, nil)] }
  env.each { |k, v| ENV[k] = v }
  begin
    FileUtils.mkdir_p(dir)
    runtime.generate(source, dir, closed: closed, only_owners: OWNERS, **options)
  ensure
    saved.each { |k, v| v ? ENV[k] = v : ENV.delete(k) }
  end
end


# -- 0. the flow, with a stub oracle ------------------------------------------------------

puts '== NumericFlow with a stub oracle (host)'
nf = NumericFlow
nf_other = nf::OTHER
make_insn = ->(addr, op, args) { Insn.new(lineno: 1, addr: addr, op: op, args: args, raw: "#{op} #{args}") }
# The test of `x.is_a?(Array)` / `x.kind_of?(Hash)`: the bit of the class passes, OTHER becomes the class on the true edge.
stub_test = Struct.new(:bit) do
  def narrow(mask, truth)
    return mask & ~bit unless truth

    (mask & bit) | (mask.anybits?(NumericFlow::OTHER) ? bit : 0)
  end
end
array_test = stub_test.new(nf::ARR)
hash_test = stub_test.new(nf::HSH)
stub_oracle = Class.new do
  attr_accessor :slots

  def initialize(array_test, hash_test)
    @slots = []
    @tests = { 'is_a?' => [0, array_test], 'kind_of?' => [0, hash_test] }
  end

  def entry_mask(_irep, _reg) = NumericFlow::OTHER
  def const_mask(_insn) = NumericFlow::OTHER
  def ivar_slots(_irep) = @slots
  def ivar_entry_mask(_irep, _name) = NumericFlow::OTHER
  def ivar_fact_mask(_irep, _name) = NumericFlow::OTHER
  def send_mask(_irep, _index, _insn, _state) = NumericFlow::OTHER
  def pool_mask(_irep, _insn) = NumericFlow::OTHER
  def op_native?(_sym) = false
  def nil_raises?(_sym) = false
  def class_narrowing_active? = true
  def class_test(_irep, _index, insn, _state) = @tests[insn.sym]
  def noreturn_call?(_irep, _index, insn) = insn.sym == 'raise'
end
flow = lambda do |list, opaque = Set.new, slots = []|
  irep = Irep.new(label: "cn#{list.hash}", nregs: 10, instructions: list, catch_handlers: [], reps: [], pool: [])
  NumericFlow.states(irep, stub_oracle.new(array_test, hash_test).tap { |o| o.slots = slots }, opaque)
end
test_send = ->(addr, sym) { make_insn.call(addr, 'SEND', "R5\t:#{sym}\tn=1") }
ret = ->(addr, reg) { make_insn.call(addr, 'RETURN', reg) }
mov = ->(addr, dst, src) { make_insn.call(addr, 'MOVE', "#{dst}\t#{src}") }
# The two arms of `if x.is_a?(Array)`: R6 is what `x` (R1) is on each, read at the RETURN of each arm.
two_arms = [mov.call(0, 'R5', 'R1'), test_send.call(3, 'is_a?'), make_insn.call(7, 'JMPNOT', "R5\t16"), mov.call(11, 'R6', 'R1'),
            ret.call(14, 'R6'), mov.call(16, 'R6', 'R1'), ret.call(19, 'R6')]
states = flow.call(two_arms)
check.call('a test narrows the variable on the edge where it holds', states[4][6] == nf::ARR)
check.call('and drops the class on the other edge (an unknown value stays unknown)', states[6][6] == nf_other)
check.call('a captured register is never narrowed', flow.call(two_arms, Set['1'])[4][6] == nf_other)
stale = [mov.call(0, 'R5', 'R1'), test_send.call(3, 'is_a?'), mov.call(7, 'R4', 'R5'), mov.call(10, 'R1', 'R2'),
         make_insn.call(13, 'JMPNOT', "R4\t22"), mov.call(17, 'R6', 'R1'), ret.call(20, 'R6'), mov.call(22, 'R6', 'R1'),
         ret.call(25, 'R6')]
check.call('NEG a rewrite of the variable forgets the test its copy holds', flow.call(stale)[6][6] == nf_other)
stale_slot = [make_insn.call(0, 'GETIV', "R5\t@cn"), test_send.call(3, 'is_a?'), mov.call(7, 'R4', 'R5'),
              make_insn.call(10, 'SEND0', "R6\t:bump"), make_insn.call(13, 'JMPNOT', "R4\t22"),
              make_insn.call(17, 'GETIV', "R6\t@cn"), ret.call(20, 'R6'), make_insn.call(22, 'GETIV', "R6\t@cn"),
              ret.call(25, 'R6')]
check.call('NEG a call between the test and the branch forgets a test aimed at an ivar',
           flow.call(stale_slot, Set.new, ['cn'])[6][6] == nf_other)
joined = [make_insn.call(0, 'JMPNOT', "R3\t13"), mov.call(4, 'R5', 'R1'), test_send.call(7, 'is_a?'), make_insn.call(11, 'JMP', '15'),
          make_insn.call(13, 'LOADTRUE', "R5\t(true)"), make_insn.call(15, 'JMPNOT', "R5\t24"), mov.call(19, 'R6', 'R1'),
          ret.call(22, 'R6'), mov.call(24, 'R6', 'R1'), ret.call(27, 'R6')]
check.call('NEG a join keeps a test only when both paths hold it', flow.call(joined)[7][6] == nf_other)
either = [mov.call(0, 'R5', 'R1'), test_send.call(3, 'is_a?'), make_insn.call(7, 'JMPIF', "R5\t22"), mov.call(11, 'R5', 'R1'),
          test_send.call(14, 'kind_of?'), make_insn.call(22, 'JMPNOT', "R5\t31"), mov.call(26, 'R6', 'R1'), ret.call(29, 'R6'),
          mov.call(31, 'R6', 'R1'), ret.call(34, 'R6')]
check.call('`a || b` in a condition keeps both narrowings (the second branch is decided by the first edge)',
           flow.call(either)[7][6] == (nf::ARR | nf::HSH))
no_return = [mov.call(0, 'R5', 'R1'), test_send.call(3, 'is_a?'), make_insn.call(7, 'JMPIF', "R5\t18"),
             make_insn.call(11, 'SSEND0', "R6\t:raise"), mov.call(18, 'R6', 'R1'), ret.call(21, 'R6')]
check.call('`raise` has no normal successor, so `raise unless test` narrows what follows', flow.call(no_return)[5][6] == nf::ARR)
copy_chain = [mov.call(0, 'R3', 'R1'), mov.call(3, 'R5', 'R3'), test_send.call(6, 'is_a?'), make_insn.call(10, 'JMPNOT', "R5\t19"),
              mov.call(14, 'R6', 'R1'), ret.call(17, 'R6'), mov.call(19, 'R6', 'R1'), ret.call(22, 'R6')]
check.call('the argument of `case x when C` copies the case temporary, which copies x: all of them are narrowed',
           flow.call(copy_chain)[5][6] == nf::ARR)

if ENV['CN_UNIT_ONLY']
  puts failures.empty? ? 'bc2cpp class narrowing check: PASS (stub oracle only)' : "bc2cpp class narrowing check: #{failures.size} failure(s)"
  exit(failures.empty? ? 0 : 1)
end

# -- 1. generated code -----------------------------------------------------------------

if ENV['MRBC']
  puts '== generated code'
  Dir.mktmpdir do |dir|
    off, = generate.call(CLASSES + FIXTURE, File.join(dir, 'off'), env: { 'BC2CPP_CLASS_NARROWING' => '0' })
    on, = generate.call(CLASSES + FIXTURE, File.join(dir, 'on'))
    POSITIVE.each do |fn|
      check.call("#{fn}: narrowing removes work (#{work.call(off, fn)} -> #{work.call(on, fn)})",
                 work.call(on, fn) < work.call(off, fn))
      # `xs.map { ... }` itself is a by-name call.
      check.call("#{fn}: no by-name dispatch is left", dispatches.call(on, fn).zero?) unless fn == 'pos_next'
    end
    NEGATIVE.each do |fn|
      check.call("NEG #{fn}: the work of x.name stays (#{work.call(on, fn)} = #{work.call(off, fn)})",
                 work.call(on, fn) == work.call(off, fn) && dispatches.call(on, fn).positive?)
    end
    check.call('NEG the kill switch (BC2CPP_CLASS_NARROWING=0) emits no narrowing guard', !off.include?('CLASS_NARROWING'))
    check.call('a narrowed test carries its run-time guard', on.include?('CLASS_NARROWING_GUARD') && on.include?('(CLASS_NARROWING)'))

    unless ENV['CN_SKIP_WORLDS']
      WORLDS.each do |what, world|
        next if ENV['CN_WORLDS'] && !what.match?(Regexp.new(ENV['CN_WORLDS']))

        d = File.join(dir, what.gsub(/\W+/, '_'))
        gems = world[:gem] ? [['cn_outside_gem', gem_dir.call(d, 'cn_outside_gem', world[:gem])]] : []
        source = CLASSES + FIXTURE + world.fetch(:ruby, '')
        wcode, = generate.call(source, File.join(d, 'on'), build_gems: gems)
        wkill, = generate.call(source, File.join(d, 'off'), env: { 'BC2CPP_CLASS_NARROWING' => '0' }, build_gems: gems)
        lost = world[:kept].reject { |fn| work.call(wcode, fn) == work.call(wkill, fn) }
        puts "    narrowed anyway: #{lost.join(' ')}" unless lost.empty?
        check.call("NEG #{what}: the withdrawn positives keep their work", lost.empty?)
        stay = (POSITIVE - world[:kept]).reject { |fn| work.call(wcode, fn) < work.call(wkill, fn) }
        puts "    lost the proof: #{stay.join(' ')}" unless stay.empty?
        check.call("#{what}: the other positives still lose work", stay.empty?)
        negatives = NEGATIVE.reject { |fn| work.call(wcode, fn) == work.call(wkill, fn) }
        puts "    wrong: #{negatives.join(' ')}" unless negatives.empty?
        check.call("#{what}: the negatives keep their work", negatives.empty?)
      end
    end

    ocode, = generate.call(CLASSES + FIXTURE, File.join(dir, 'open'), closed: false)
    check.call('NEG the open world proves nothing', !ocode.include?('CLASS_NARROWING'))
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

if ENV['MRBC'] && !builds.empty? && runtime.compiler? && !ENV['CN_GENERATED_ONLY']
  puts '== fixture on real mruby, interpreted and compiled'
  ctor = ->(klass) { "mrb_obj_new(M, mrb_class_get(M, #{klass.dump}), 0, nullptr)" }
  objects = {
    'circle' => ctor.call('CnCircle'), 'square' => ctor.call('CnSquare'), 'big' => ctor.call('CnBigCircle'),
    'shape' => ctor.call('CnShape'), 'other' => ctor.call('CnOther'),
    'nil' => 'mrb_nil_value()', 'arr' => 'mrb_ary_new(M)', 'hash' => 'mrb_hash_new(M)', 'int' => 'mrb_fixnum_value(5)',
    'flt' => 'mrb_float_value(M, 1.5)', 'str' => 'mrb_str_new_cstr(M, "ab")',
    'sym' => 'mrb_symbol_value(mrb_intern_lit(M, "s"))', 'true' => 'mrb_true_value()', 'false' => 'mrb_false_value()',
    'mixed' => "([&] { mrb_value a = mrb_ary_new(M); mrb_ary_push(M, a, #{ctor.call('CnCircle')}); mrb_ary_push(M, a, mrb_nil_value()); " \
               "mrb_ary_push(M, a, #{ctor.call('CnOther')}); mrb_ary_push(M, a, #{ctor.call('CnSquare')}); return a; })()",
    # A subclass made from outside the analysed world: no program in it could, so the proof does not know it.
    'rogue' => 'mrb_obj_new(M, mrb_define_class(M, "CnRogue", mrb_class_get(M, "CnShape")), 0, nullptr)'
  }
  everything = %w[circle square big shape other nil arr hash int flt str sym true false]
  calls = []
  one = %w[pos_is_a pos_kind_of pos_instance_of pos_eqq pos_case pos_case_multi pos_early_return pos_early_raise pos_and
           pos_or pos_ternary pos_copy pos_respond pos_class_eq pos_ivar pos_loop pos_array pos_hash pos_string pos_integer neg_none
           neg_call_between neg_stale_ivar neg_global neg_false_edge]
  one.each { |m| everything.each { |v| calls << [m, [v]] } }
  %w[pos_case_else pos_nil_value pos_not].each { |m| %w[true false].each { |v| calls << [m, [v]] } }
  calls << ['pos_next', ['mixed']]
  [%w[circle other], %w[other circle], %w[nil circle], %w[circle nil], %w[square big], %w[int circle]].each do |args|
    %w[neg_other_var neg_reassign neg_block_write neg_loop_swap neg_rescue neg_or_other].each { |m| calls << [m, args] }
  end
  [%w[circle true], %w[circle false], %w[other true], %w[nil false]].each { |args| calls << ['neg_join_test', args] }
  [%w[circle other], %w[other circle], %w[nil circle]].each { |args| calls << ['neg_stale_test', args] }
  # The interpreter answers for the rogue class; a narrowed test must raise the guard violation (or the site was not
  # narrowed and answers the same), never call a body of another class.
  rogue_calls = %w[pos_is_a pos_kind_of pos_eqq pos_case pos_early_return pos_and pos_ternary pos_ivar pos_respond].map { |m| [m, ['rogue']] }
  needs_mrblib = %w[pos_next neg_block_write]

  scenario = lambda do |list|
    vars = list.flat_map { |_, args| args }.uniq
    decls = vars.map { |v| "  mrb_value v_#{v} = #{objects.fetch(v)};" }
    lines = list.map do |m, args|
      "  { mrb_value a[] = { #{args.map { |a| "v_#{a}" }.join(', ')} }; call(M, #{"#{m}(#{args.join(',')})".dump}, fx, #{m.dump}, #{args.size}, a); }"
    end
    <<~CPP
      // The guard violation logs to $stderr; capture it on stdout, indented, so it never interleaves with an answer.
      static mrb_value cn_log_puts(mrb_state* M, mrb_value) {
        mrb_value line;
        mrb_get_args(M, "S", &line);
        std::printf("  LOG %.*s\\n", (int)RSTRING_LEN(line), RSTRING_PTR(line));
        return mrb_nil_value();
      }
      static int scenario(mrb_state* M) {
        struct RClass* log = mrb_define_class(M, "CnLog", M->object_class);
        mrb_define_method(M, log, "puts", cn_log_puts, MRB_ARGS_REQ(1));
        mrb_gv_set(M, mrb_intern_lit(M, "$stderr"), mrb_obj_new(M, log, 0, nullptr));
        // mruby's mrblib (absent from a bare core) defines these.
        if (!mrb_class_defined(M, "NameError")) mrb_define_class(M, "NameError", M->eStandardError_class);
        if (!mrb_class_defined(M, "NoMethodError")) mrb_define_class(M, "NoMethodError", mrb_class_get(M, "NameError"));
        if (!mrb_class_defined(M, "ArgumentError")) mrb_define_class(M, "ArgumentError", M->eStandardError_class);
      #{decls.join("\n")}
        mrb_value fx = #{ctor.call('CnFx')};
      #{lines.join("\n")}
        return 0;
      }
    CPP
  end

  builds.each do |build_name, build, mrbc, flags, full_core|
    saved = ENV.values_at('MRBC', 'BC2CPP_CXXFLAGS', 'BC2CPP_BLOCK_DIRECT_ENTRY')
    ENV['MRBC'] = mrbc
    # ADR 0271 keeps a block's entry as an address in an mrb_int: a 32-bit build on a 64-bit host cannot.
    ENV['BC2CPP_BLOCK_DIRECT_ENTRY'] = '0' if flags.include?('MRB_INT32')
    ENV['BC2CPP_CXXFLAGS'] = "#{flags} -I#{File.expand_path('../../include', __dir__)}"
    begin
      # A bare core has no Array#each or #map: the fixtures that need them are left out.
      base_calls = full_core ? calls : calls.reject { |m, _| needs_mrblib.include?(m) }
      { 'the base fixture' => base_calls, 'a subclass made outside the analysed world' => base_calls + rogue_calls }.each do |world, list|
        label = "#{build_name}, #{world}"
        Dir.mktmpdir do |dir|
          _code, err = generate.call(CLASSES + FIXTURE, dir)
          built, output = runtime.run(dir, err, OWNERS, scenario.call(list), build: build, full: full_core)
          check.call("#{label}: the fixture compiles and runs against real mruby", built)
          puts output unless built
          next unless built

          sections = runtime.sections(output)
          values = ->(name) { sections.fetch(name, []).reject { |l| l.start_with?('  ') } }
          interpreted = values.call('interpreted')
          compiled = values.call('compiled')
          lines = sections.fetch('compiled', [])
          if world == 'the base fixture'
            interpreted.zip(compiled).reject { |a, b| a == b }.first(8).each do |a, b|
              puts "    interpreted: #{a}\n    compiled:    #{b}"
            end
            check.call("#{label}: every call answers what the interpreter answers (#{interpreted.size} lines), values and exceptions alike",
                       !interpreted.empty? && interpreted == compiled)
            # The kept else of an unproven receiver dispatches, which proves the compiled bodies ran.
            at = lines.index { |l| l.start_with?('neg_none(arr) =>') }
            check.call("#{label}: the compiled bodies ran (a kept else dispatched)", at && lines[at + 1].to_s[/dispatches=(\d+)/, 1].to_i.positive?)
            proven = %w[pos_is_a pos_kind_of pos_instance_of pos_eqq pos_case pos_case_multi pos_early_return pos_early_raise
                        pos_and pos_ternary pos_copy pos_respond pos_ivar].flat_map { |m| %w[circle square big].map { |v| "#{m}(#{v})" } }
            proven += %w[pos_class_eq(circle)]
            proven += %w[pos_array(arr) pos_hash(hash) pos_string(str) pos_integer(int) pos_case_else(true) pos_case_else(false)
                         pos_or(circle) pos_or(square) pos_nil_value(true) pos_nil_value(false) pos_not(true) pos_not(false)
                         pos_loop(circle)]
            proven.each do |m|
              at = lines.index { |l| l.start_with?("#{m} =>") }
              n = at && lines[at + 1].to_s[/dispatches=(\d+)/, 1]&.to_i
              check.call("#{label}: #{m}: the proven site makes no dynamic dispatch", n == 0)
            end
          else
            rogue = compiled.select { |l| l.include?('(rogue)') }
            check.call("#{label}: the interpreter answers for the rogue class", interpreted.any? { |l| l.start_with?('pos_is_a(rogue) => 1') })
            check.call("#{label}: a narrowed test raises the guard violation instead of calling a body of another class",
                       rogue.any? { |l| l.include?('raised BC2cppGuardViolation') })
            check.call("#{label}: no rogue call answers differently than the interpreter without raising the violation",
                       rogue.all? { |l| interpreted.include?(l) || l.include?('raised BC2cppGuardViolation') })
            others = interpreted.reject { |l| l.include?('(rogue)') }.zip(compiled.reject { |l| l.include?('(rogue)') })
            others.reject { |a, b| a == b }.first(8).each { |a, b| puts "    interpreted: #{a}\n    compiled:    #{b}" }
            check.call("#{label}: every other call still answers what the interpreter answers",
                       others.all? { |a, b| a == b } && interpreted.size == compiled.size)
          end
        end
      end
    ensure
      ENV['MRBC'], ENV['BC2CPP_CXXFLAGS'], block_entry = saved
      block_entry ? ENV['BC2CPP_BLOCK_DIRECT_ENTRY'] = block_entry : ENV.delete('BC2CPP_BLOCK_DIRECT_ENTRY')
    end
  end
else
  puts '-- SKIP run: set MRBC, BC2CPP_MRUBY_FULL (or have rake, g++ and 3rd/mruby) and have g++'
end

if failures.empty?
  puts 'bc2cpp class narrowing check: PASS'
else
  warn "bc2cpp class narrowing check: #{failures.size} failure(s)"
  exit 1
end
