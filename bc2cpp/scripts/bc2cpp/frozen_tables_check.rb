#!/usr/bin/env ruby
# frozen_string_literal: true

# FROZEN_TABLES (docs/adr/0306): the element classes of a frozen Array/Hash literal feed the numeric
# class flow, and a receiver that is only such tables is an exact Array/Hash.
#
# 1. Model (CRuby, no mrbc): FrozenTables::Registry reads, per shape, exactly what the literal stores.
# 2. Generated code (MRBC): a closed-world fixture. Each positive shape (literal index, negative
#    index, out-of-range, `||` default, first/last/sample/size, Hash literal keys, Float slot,
#    nested literal, a table through an argument, an ivar, a return value or a local) loses the
#    dynamic arm of its arithmetic and the class test of its index; each refusal (not frozen, frozen
#    later, a grown or computed literal, a copy, a second constant of the same name, a subclass
#    argument, reflection on the holder) keeps them. One hostile world per soundness condition
#    (a redefined `[]`/`first`/`size`/`freeze`, an installer, a singleton maker, a native or foreign
#    definition, the open world, the kill switch) proves nothing; Marshal and send leave it alone.
# 3. Behaviour (BC2CPP_MRUBY_FULL / BC2CPP_MRUBY_CORE, g++): the fixture runs on real mruby,
#    interpreted and compiled, and answers alike, including every attempt to change a frozen table
#    (FrozenError, contents unchanged) and a Float/bignum slot. The run repeats on the core-only
#    build and on a 32-bit-`mrb_int` build (BC2CPP_MRUBY_FULL32, BC2CPP_MRBC32;
#    scripts/bc2cpp/width_build.rb int32).
#
# Usage: MRBC=path/to/mrbc [BC2CPP_MRUBY_FULL=dir BC2CPP_MRUBY_CORE=dir BC2CPP_MRUBY_FULL32=dir
#         BC2CPP_MRBC32=mrbc32 FT_GENERATED_ONLY=1] ruby scripts/bc2cpp/frozen_tables_check.rb

require 'tmpdir'
require_relative '../../tools/bc2cpp/frozen_tables'
require_relative 'fixture_runtime'

failures = []
check = lambda do |what, condition|
  puts "  #{condition ? 'ok  ' : 'FAIL'} #{what}"
  failures << what unless condition
end
runtime = Bc2cppFixtureRuntime
NF = NumericFlow
INT = NF::INT
FLT = NF::FLT
NIL_ = NF::NIL
STR = NF::STR
ARR = NF::ARR
OTHER = NF::OTHER

# ---------------------------------------------------------------------------
puts '-- model (host)'
reg = FrozenTables::Registry.new
ints = reg.intern(:array, [INT, INT, INT], nil)
check.call('an identical shape is one kind', reg.intern(:array, [INT, INT, INT], nil).equal?(ints))
check.call('kinds sit above the LCF object kinds', ints.bit >= 1 << FrozenTables::FIRST_BIT &&
                                                   FrozenTables::FIRST_BIT >= NF::OBJECT_KIND_BASE + 256)
check.call('a literal index in range reads exactly that slot', reg.read(ints, 1, true) == INT)
mixed = reg.intern(:array, [INT, FLT, NIL_], nil)
check.call('slots are per position, not joined, for a literal index', reg.read(mixed, 1, true) == FLT && reg.read(mixed, 2, true) == NIL_)
check.call('a negative literal index counts from the end', reg.read(mixed, -3, true) == INT && reg.read(mixed, -1, true) == NIL_)
check.call('a literal index out of range reads nil', reg.read(ints, 3, true) == NIL_ && reg.read(ints, -4, true) == NIL_)
check.call('an Integer index that is not a literal reads any slot or nil', reg.read(mixed, nil, true) == (INT | FLT | NIL_))
check.call('an index that may be a Range proves nothing', reg.read(ints, nil, false) == OTHER)
check.call('first/last read the end slots, sample every slot',
           reg.end_read(mixed, 'first') == INT && reg.end_read(mixed, 'last') == NIL_ && reg.end_read(mixed, 'sample') == (INT | FLT | NIL_))
empty = reg.intern(:array, [], nil)
check.call('an empty literal reads nil everywhere', reg.read(empty, 0, true) == NIL_ && reg.end_read(empty, 'first') == NIL_ &&
                                                   reg.read(empty, nil, true) == NIL_)
hash = reg.intern(:hash, [INT, STR, INT], [8, :up, 8])
check.call('a literal key reads the last slot stored under it', reg.read(hash, 8, false) == INT && reg.read(hash, :up, false) == STR)
check.call('a literal key that is absent reads nil (a literal has no default)', reg.read(hash, 6, false) == NIL_ && reg.read(hash, :down, false) == NIL_)
check.call('any other key reads a value or nil', reg.read(hash, nil, false) == (INT | STR | NIL_))
unkeyed = reg.intern(:hash, [INT, INT], nil)
check.call('a Hash whose keys are not all literal Integers/Symbols reads value-or-nil for every key',
           reg.read(unkeyed, 8, false) == (INT | NIL_))
check.call('names group runs', reg.name(ints.bit) == 'FROZEN:Array[INT*3]' && reg.name(mixed.bit) == 'FROZEN:Array[INT,FLT,NIL]')
check.call('the registry mask is the union of the bits', reg.mask == reg.shapes.sum(&:bit))

# ---------------------------------------------------------------------------
FIXTURE = <<~RUBY
  module EcTables
    IDX = [10, 20, 30].freeze
    WALK = [1, 2, 1, 0].freeze
    SAME = [7, 7].freeze
    MIXED = [1, 2.5].freeze
    BIG = [1_500_000_000, 2_000_000_000].freeze
    NAMES = [:a, :b].freeze
    DIRS = { 8 => 0, 6 => 1, 2 => 2, 4 => 3 }.freeze
    LABELS = { up: 8, down: 2 }.freeze
    NESTED = [[1, 2], [3]].freeze
    EMPTY = [].freeze
    MUT = [1, 2, 3]
    SHARED = [1, 2].freeze
    LIST = [1, 2].freeze
  end

  module EcOther
    SHARED = ["s"].freeze
    LIST = [1, 2]
  end

  class EcSubArr < Array
    def [](_i); "x"; end
  end

  class EcUse
    def initialize
      @t = EcTables::IDX
      @p = EcTables::IDX
    end

    # -- positives: arithmetic and the index lose their dynamic arms
    def lit_idx; EcTables::IDX[1] + 1; end
    def neg_idx; EcTables::IDX[-1] + 1; end
    def oob_default; (EcTables::IDX[5] || 7) + 1; end
    def var_calc; i = EcTables::SAME.size * 3 - 5; (EcTables::IDX[i] || 0) + 1; end
    def var_calc_oob; i = EcTables::SAME.size * 3; (EcTables::IDX[i] || 0) + 1; end
    def ends; EcTables::IDX.first + EcTables::IDX.last; end
    def pick; EcTables::SAME.sample + 1; end
    def counts; EcTables::IDX.size + EcTables::WALK.length; end
    def hash_lit; EcTables::DIRS[8] + EcTables::DIRS[4]; end
    def hash_sym; EcTables::LABELS[:up] + EcTables::LABELS[:down]; end
    def hash_var(d); (EcTables::DIRS[d] || 9) + 1; end
    def hash_absent; (EcTables::DIRS[3] || 5) + 1; end
    def float_slot; EcTables::MIXED[1] + 1; end
    def big_sum; EcTables::BIG[0] + EcTables::BIG[1]; end
    def nested; EcTables::NESTED[0].size + 1; end
    def empty_first; (EcTables::EMPTY.first || 4) + 1; end
    def local_alias; t = EcTables::IDX; t[2] + 1; end
    def ivar_read; @t[0] + 1; end
    def arg_read(t); t[0] + 1; end
    def via_arg; arg_read(EcTables::IDX); end
    def table; EcTables::IDX; end
    def via_return; table[1] + 1; end

    # -- negatives: the same shapes with the proof missing
    def var_idx(i); (EcTables::IDX[i] || 0) + 1; end
    def mutable_idx; EcTables::MUT[0] + 1; end
    def shared_name; EcTables::SHARED[0] + 1; end
    def list_name; EcTables::LIST[0] + 1; end
    def dup_idx; EcTables::IDX.dup[0] + 1; end
    def concat_frozen; ([1, 2] + [3]).freeze[0] + 1; end
    def late_freeze; a = [1, 2]; c = a; c[0] = "s"; b = a.freeze; b[0] + 1; end
    def oob_plain; EcTables::IDX[5] + 1; end
    def hash_absent_plain; EcTables::DIRS[3] + 1; end
    def splat_freeze(l); [*l, 1].freeze[0] + 1; end
    def sub_pick(t); t[0] + 1; end
    def p_read; @p[0] + 1; end
    def poke(v); instance_variable_set(:@p, v); end
    def self.poison(a); a[0] = "s"; end

    # -- every way to change a frozen table raises and leaves it as it was
    def m_push; EcTables::IDX << 1; end
    def m_set; EcTables::IDX[0] = "s"; end
    def m_alias; t = EcTables::IDX; t.push("s"); end
    def m_pop; EcTables::IDX.pop; end
    def m_shift; EcTables::IDX.shift; end
    def m_unshift; EcTables::IDX.unshift("s"); end
    def m_insert; EcTables::IDX.insert(1, "s"); end
    def m_concat; EcTables::IDX.concat(["s"]); end
    def m_replace; EcTables::IDX.replace(["s"]); end
    def m_fill; EcTables::IDX.fill("s"); end
    def m_map; EcTables::IDX.map! { "s" }; end
    def m_sort; EcTables::IDX.sort!; end
    def m_reverse; EcTables::IDX.reverse!; end
    def m_rotate; EcTables::IDX.rotate!; end
    def m_delete_at; EcTables::IDX.delete_at(0); end
    def m_delete; EcTables::IDX.delete(10); end
    def m_delete_if; EcTables::IDX.delete_if { true }; end
    def m_compact; EcTables::MIXED.compact!; end
    def m_slice; EcTables::IDX.slice!(0, 2); end
    def m_hset; EcTables::DIRS[8] = "s"; end
    def m_hstore; EcTables::DIRS.store(8, "s"); end
    def m_hdelete; EcTables::DIRS.delete(8); end
    def m_hmerge; EcTables::DIRS.merge!({ 8 => "s" }); end
    def m_hdefault; EcTables::DIRS.default = "s"; end
    def m_hreplace; EcTables::DIRS.replace({ 8 => "s" }); end
    def m_hshift; EcTables::DIRS.shift; end
    def m_hdelete_if; EcTables::DIRS.delete_if { true }; end
  end

  class EcDrv
    def sub_table(use); use.sub_pick(EcTables::IDX); end
    def sub_sub(use); use.sub_pick(EcSubArr.new); end
  end
RUBY
OWNERS = %w[EcTables EcOther EcSubArr EcUse EcDrv].freeze

POSITIVE = {
  'lit_idx' => 'a literal index reads its slot',
  'neg_idx' => 'a negative literal index reads from the end',
  'oob_default' => 'an out-of-range literal index is nil, narrowed by `||`',
  'var_calc' => 'a computed Integer index reads a slot or nil, narrowed by `||`',
  'var_calc_oob' => 'a computed Integer index past the end reads nil, narrowed by `||`',
  'ends' => 'first and last of a non-empty literal are slots, never nil',
  'pick' => 'sample of a non-empty literal is a slot, never nil',
  'counts' => 'size and length are Integer',
  'hash_lit' => 'a literal key of a Hash literal reads its value',
  'hash_sym' => 'a literal Symbol key reads its value',
  'hash_var' => 'any other key reads a value or nil, narrowed by `||`',
  'hash_absent' => 'an absent literal key is nil, narrowed by `||`',
  'float_slot' => 'a Float slot reads Float',
  'big_sum' => 'Integer slots past the 31-bit fixnum range are Integer',
  'nested' => 'a nested literal is an exact Array',
  'empty_first' => 'first of an empty literal is nil, narrowed by `||`',
  'local_alias' => 'a local holding the table',
  'ivar_read' => 'an ivar only ever holding the table',
  'via_arg' => 'an argument every call site passes the table',
  # A scoped read K::NAME resolves to K's own definition (ADR 0423); EcOther's binding is not reachable from EcTables.
  'shared_name' => 'a scoped read of a constant another scope also binds (to a table of other slots)',
  'list_name' => 'a scoped read of a constant another scope also binds (to a mutable Array)'
}.freeze
ARG_SITE = { 'arg_read' => 'an argument every call site passes the table' }.freeze
RETURN_SITE = { 'via_return' => 'a method that returns the table' }.freeze
NEGATIVE = {
  'var_idx' => 'an index not shown to be an Integer (it may be a Range, whose result is an Array)',
  'oob_plain' => 'a literal index past the end is nil',
  'hash_absent_plain' => 'a literal key the Hash does not hold is nil',
  'mutable_idx' => 'a literal that is not frozen',
  'dup_idx' => 'a copy of the table (mutable)',
  'concat_frozen' => 'a computed Array frozen afterwards',
  'late_freeze' => 'an Array frozen after a call could have changed it',
  'splat_freeze' => 'a literal grown by a splat',
  'sub_pick' => 'an argument one call site passes an Array subclass instance',
  'p_read' => 'an ivar instance_variable_set can write'
}.freeze

body_of = lambda do |code, owner, fn|
  code[/^mrb_value #{owner}_#{fn}_impl\(mrb_state\* M.*?(?=^(?:static )?mrb_value \w+\(mrb_state\* M|\z)/m].to_s
end
# Every arithmetic site of the method lost its dynamic send (the numeric proof or the Fixnum proof took it).
proven = lambda do |code, fn|
  body = body_of.call(code, 'EcUse', fn)
  !body.empty? && !body.match?(/bc2cpp_slow_\w+\(M/) &&
    (body.include?('NUMERIC_OPERAND_PROOF') || body.include?('operands proven Fixnum'))
end
numeric_proof = ->(code, fn) { body_of.call(code, 'EcUse', fn).include?('NUMERIC_OPERAND_PROOF') }
kept = lambda do |code, fn|
  body = body_of.call(code, 'EcUse', fn)
  !body.empty? && body.match?(/bc2cpp_slow_\w+\(M/)
end
indexed_exact = ->(code, fn) { body_of.call(code, 'EcUse', fn).include?('INDEX_EXACT') }

generate = lambda do |source, dir, closed: true, env: {}, **options|
  saved = env.to_h { |k, _| [k, ENV.fetch(k, nil)] }
  env.each { |k, v| ENV[k] = v }
  begin
    runtime.generate(source, dir, closed: closed, only_owners: OWNERS, **options)
  ensure
    saved.each { |k, v| v ? ENV[k] = v : ENV.delete(k) }
  end
end

# ---------------------------------------------------------------------------
# Every world this check generates, by name. FT_WORLDS=slug[,slug...] runs only those, so the
# mutation check can name the one or two worlds that can kill a given mutant instead of
# generating all of them (a bc2cpp run is ~2s and most of it is the same fixed startup).
# A name the check does not know is a hard error: a typo that selected nothing would let a
# mutant "pass" for the wrong reason.
def world_slug(what)
  what.gsub(/\W+/, '_')
end

BASE = 'base'.freeze
SWITCH = {
  'switch' => 'the kill switch (BC2CPP_FROZEN_TABLES=0)',
  'class_pools_switch' => 'BC2CPP_CLASS_POOLS=0 withdraws the table proofs as well',
  'open_world' => 'the open world proves nothing',
  'no_frozen_literal' => 'a world with no frozen literal'
}.freeze

VARIANTS = {
  'Array#[] redefined in Ruby' => { extra: "class Array\n  def [](i); \"s\"; end\nend\n", kept: %w[lit_idx neg_idx var_calc local_alias],
                                   proven: %w[ends hash_lit] },
  'Hash#[] redefined in Ruby' => { extra: "class Hash\n  def [](k); \"s\"; end\nend\n", kept: %w[hash_lit hash_sym hash_var],
                                  proven: %w[lit_idx ends] },
  'Array#first redefined in Ruby' => { extra: "class Array\n  def first; \"s\"; end\nend\n", kept: %w[ends empty_first],
                                      proven: %w[lit_idx hash_lit] },
  'Array#size redefined in Ruby' => { extra: "class Array\n  def size; \"s\"; end\nend\n", kept: %w[counts],
                                     proven: %w[lit_idx ends] },
  'Array#freeze redefined in Ruby (any Ruby freeze withdraws every table)' =>
    { extra: "class Array\n  def freeze; self; end\nend\n", kept: %w[lit_idx hash_lit ends counts] },
  'Hash#freeze redefined in Ruby' =>
    { extra: "class Hash\n  def freeze; self; end\nend\n", kept: %w[lit_idx hash_lit ends counts] },
  'Kernel#freeze redefined in Ruby' =>
    { extra: "module Kernel\n  def freeze; self; end\nend\n", kept: %w[lit_idx hash_lit ends] },
  'Object#freeze redefined in Ruby' =>
    { extra: "class Object\n  def freeze; self; end\nend\n", kept: %w[lit_idx hash_lit ends] },
  'a module prepended to Array (declines every Array name, Hash is untouched)' =>
    { extra: "module EcFirst\n  def first; \"s\"; end\nend\nclass Array\n  prepend EcFirst\nend\n", kept: %w[ends lit_idx], proven: %w[hash_lit] },
  'a user freeze on instances (freeze is not only Kernel#freeze)' =>
    { extra: "class EcFoo\n  def freeze; 1; end\nend\n", kept: %w[lit_idx hash_lit ends] },
  'a const_missing (a failed constant lookup can answer)' =>
    { extra: "class EcUse\n  def self.const_missing(n); 1; end\nend\n", kept: %w[lit_idx hash_lit ends] },
  'alias_method :[] on Array' => { extra: "class Array\n  alias_method :[], :first\nend\n", kept: %w[lit_idx hash_lit var_calc] },
  'define_method(:first) on Array' => { extra: "class Array\n  define_method(:first) { 1 }\nend\n", kept: %w[ends] },
  'a method installer with a computed name' => { extra: "class EcUse\n  def inst(n); self.class.send(:define_method, n) { 1 }; end\nend\n",
                                                 kept: %w[lit_idx hash_lit ends] },
  'a singleton method on an Array (an instance can differ)' =>
    { extra: "class EcUse\n  def maker; a = [1]; def a.[](i); \"s\"; end; a; end\nend\n", kept: %w[lit_idx hash_lit ends counts] },
  'extend on an object' => { extra: "module EcExt; end\nclass EcUse\n  def ext(o); o.extend(EcExt); end\nend\n",
                             kept: %w[lit_idx hash_lit ends] },
  'a native source registering [] on Array' =>
    { native: [['ec_native.cxx', "void ec_init(mrb_state* mrb) { mrb_define_method(mrb, mrb->array_class, \"[]\", ec_aref, MRB_ARGS_REQ(1)); }\n"]],
      kept: %w[lit_idx var_calc], proven: %w[ends hash_lit] },
  'a native source registering first on Array' =>
    { native: [['ec_native.cxx', "void ec_init(mrb_state* mrb) { mrb_define_method(mrb, mrb->array_class, \"first\", ec_first, MRB_ARGS_NONE()); }\n"]],
      kept: %w[ends], proven: %w[lit_idx] },
  'a native source registering freeze through a class variable' =>
    { native: [['ec_native.cxx', "void ec_init(mrb_state* mrb) { RClass* a = mrb->array_class; mrb_define_method(mrb, a, \"freeze\", ec_freeze, MRB_ARGS_NONE()); }\n"]],
      kept: %w[lit_idx ends] },
  'a foreign Ruby source defining Array#[]' =>
    { foreign: [['ec_foreign.rb', "class Array\n  def [](i); \"s\"; end\nend\n"]], kept: %w[lit_idx var_calc], proven: %w[ends] }
}.freeze

CONTROLS = {
  'Marshal and send in the world' => "class EcUse\n  def roundtrip(o); Marshal.load(Marshal.dump(o)); end\n  def go(n); send(n); end\nend\n",
  'instance_variable_set on another ivar' => "class EcUse\n  def poke2(v); instance_variable_set(:@other, v); end\nend\n",
  'another class defining [] and first' => "class EcThing\n  def [](i); \"s\"; end\n  def first; \"s\"; end\nend\n",
  'a method_missing' => "class EcUse\n  def method_missing(n, *a); 1; end\nend\n",
  'an Array subclass overriding []' => "class EcSub2 < Array\n  def [](i); \"s\"; end\nend\n"
}.freeze

ALL_WORLDS = ([BASE] + VARIANTS.keys.map { |what| world_slug(what) } +
               CONTROLS.keys.map { |what| "control_#{world_slug(what)}" } + SWITCH.keys).freeze

selected_worlds = (ENV['FT_WORLDS'].to_s.split(',').map(&:strip) - [''])
unless selected_worlds.empty?
  unknown = selected_worlds - ALL_WORLDS
  unless unknown.empty?
    warn "FT_WORLDS names no world here: #{unknown.join(', ')} (known: #{ALL_WORLDS.join(', ')})"
    exit 1
  end
end
# Unset means every world, which is what a plain run of this check does.
run_world = selected_worlds.empty? ? ->(_slug) { true } : ->(slug) { selected_worlds.include?(slug) }
# One file so a world a mutant cannot be killed by is never generated: the whole point is that
# the mutation check names a subset.
ALL_WORLDS.each { |slug| puts "  world #{slug}" if ENV['FT_WORLDS_LIST'] == '1' && run_world.call(slug) }

if ENV['MRBC'] && (run_world.call(BASE) || VARIANTS.any? { |w, _| run_world.call(world_slug(w)) } ||
                    CONTROLS.any? { |w, _| run_world.call("control_#{world_slug(w)}") } ||
                    SWITCH.keys.any? { |w| run_world.call(w) })
  puts "-- generated code (closed world#{selected_worlds.empty? ? '' : ": #{selected_worlds.join(', ')}"})"
  Dir.mktmpdir do |dir|
    if run_world.call(BASE)
      code, err = generate.call(FIXTURE, dir)
      POSITIVE.merge(ARG_SITE).merge(RETURN_SITE).each do |fn, why|
        next if fn == 'via_arg'

      check.call("EcUse##{fn}: #{why} loses the dynamic arm of its arithmetic", proven.call(code, fn))
    end
    check.call('EcUse#via_arg: the pooled argument is proven in arg_read', proven.call(code, 'arg_read'))
    %w[lit_idx neg_idx oob_default var_calc hash_lit hash_sym hash_var local_alias ivar_read arg_read].each do |fn|
      check.call("EcUse##{fn}: the table receiver is exactly an Array/Hash, so the index has no class test (INDEX_EXACT)",
                 indexed_exact.call(code, fn))
    end
    check.call('the numeric proof (not only the Fixnum proof) took the Float slot', numeric_proof.call(code, 'float_slot'))
    NEGATIVE.each do |fn, why|
      check.call("NEG EcUse##{fn}: #{why} keeps the dynamic arm", kept.call(code, fn))
    end
    check.call('the diagnostic lists the shapes and the constants that hold them',
               err.include?('FROZENTABLE FROZEN:Array[INT*3] (') && err.include?('NUMCONST EcTables::IDX (FROZEN:Array[INT*3])') &&
                 err.include?('FROZEN:Hash[INT*4]') && err.include?('on ('))
    check.call('a name bound in two scopes is listed per definition, each with its own shape (ADR 0423)',
               err.include?('NUMCONST EcTables::SHARED (FROZEN:Array[INT*2])') &&
                 err.include?('NUMCONST EcOther::SHARED (FROZEN:Array[STR])'))
    end

    VARIANTS.each do |what, spec|
      slug = world_slug(what)
      next unless run_world.call(slug)

      d = File.join(dir, slug)
      Dir.mkdir(d)
      vcode, = generate.call(FIXTURE + spec.fetch(:extra, ''), d, **spec.slice(:native, :foreign))
      wrong = spec.fetch(:kept).reject { |fn| kept.call(vcode, fn) } + spec.fetch(:proven, []).reject { |fn| proven.call(vcode, fn) }
      ok = wrong.empty?
      puts "    (wrong: #{wrong.join(', ')})" unless ok
      check.call("NEG #{what}: #{spec.fetch(:kept).join(', ')} keep the dynamic arm" \
                 "#{spec[:proven] ? "; #{spec[:proven].join(', ')} still prove" : ''}", ok)
    end

    CONTROLS.each do |what, extra|
      slug = "control_#{world_slug(what)}"
      next unless run_world.call(slug)

      d = File.join(dir, slug)
      Dir.mkdir(d)
      ccode, = generate.call(FIXTURE + extra, d)
      wrong = %w[lit_idx hash_lit ends counts].reject { |fn| proven.call(ccode, fn) }
      puts "    (not proven: #{wrong.join(', ')})" unless wrong.empty?
      check.call("CONTROL #{what}: the table reads keep their proof", wrong.empty? && indexed_exact.call(ccode, 'lit_idx'))
    end

    if run_world.call('switch')
      Dir.mktmpdir do |off_dir|
        off_code, off_err = generate.call(FIXTURE, off_dir, env: { 'BC2CPP_FROZEN_TABLES' => '0' })
        check.call('the kill switch (BC2CPP_FROZEN_TABLES=0): no shape and no table read proven by the numeric flow',
                   !off_err.include?('FROZENTABLE') && off_err.include?('off: disabled by BC2CPP_FROZEN_TABLES=0') &&
                     POSITIVE.keys.reject { |fn| %w[via_arg].include?(fn) }.none? do |fn|
                       numeric_proof.call(off_code, fn)
                     end)
      end
    end
    if run_world.call('class_pools_switch')
      Dir.mktmpdir do |pools_dir|
        pools_code, = generate.call(FIXTURE, pools_dir, env: { 'BC2CPP_CLASS_POOLS' => '0' })
        check.call('BC2CPP_CLASS_POOLS=0 withdraws the table proofs as well (they share the exact-class gates)',
                   %w[lit_idx hash_lit ends].none? { |fn| numeric_proof.call(pools_code, fn) })
      end
    end
    if run_world.call('open_world')
      Dir.mktmpdir do |open_dir|
        open_code, open_err = generate.call(FIXTURE, open_dir, closed: false)
        check.call('the open world proves nothing', !open_err.include?('FROZENTABLE') && !indexed_exact.call(open_code, 'lit_idx'))
      end
    end
    if run_world.call('no_frozen_literal')
      Dir.mktmpdir do |plain_dir|
        plain = FIXTURE.gsub('.freeze', '')
        on_code, = generate.call(plain, plain_dir)
        Dir.mktmpdir do |plain_off|
          off_code, = generate.call(plain, plain_off, env: { 'BC2CPP_FROZEN_TABLES' => '0' })
          check.call('a world with no frozen literal generates the same code with the proof on and off', on_code == off_code)
        end
      end
    end
  end
else
  puts '-- SKIP generated code: set MRBC'
end

# ---------------------------------------------------------------------------
READS = %w[lit_idx neg_idx oob_default var_calc var_calc_oob ends pick counts hash_lit hash_sym hash_absent float_slot big_sum nested empty_first
           local_alias ivar_read via_arg via_return mutable_idx shared_name list_name dup_idx concat_frozen late_freeze
           p_read oob_plain hash_absent_plain].freeze
INDEXED = [['var_idx', 0], ['var_idx', 2], ['var_idx', 3], ['var_idx', -1], ['var_idx', -4], ['hash_var', 8], ['hash_var', 3],
           ['hash_var', 99]].freeze
MUTATIONS = %w[m_push m_set m_alias m_pop m_shift m_unshift m_insert m_concat m_replace m_fill m_map m_sort m_reverse
               m_rotate m_delete_at m_delete m_delete_if m_compact m_slice m_hset m_hstore m_hdelete m_hmerge m_hdefault
               m_hreplace m_hshift m_hdelete_if].freeze

# The C++ scenario: the reads, every attempt to change a table, the reads again (a table that changed
# shows in the second pass), then the ivar a reflection write replaced.
driver = lambda do
  reads = lambda do |prefix|
    READS.map { |m| "  call(M, \"#{prefix}#{m}\", use, \"#{m}\");" } +
      INDEXED.map do |m, n|
        "  { mrb_value a = mrb_fixnum_value(#{n}); call(M, \"#{prefix}#{m}(#{n})\", use, \"#{m}\", 1, &a); }"
      end
  end
  <<~CPP
    static int scenario(mrb_state* M) {
      mrb_value use = mrb_obj_new(M, mrb_class_get(M, "EcUse"), 0, nullptr);
    #{reads.call('').join("\n")}
    #{MUTATIONS.map { |m| "  call(M, \"#{m}\", use, \"#{m}\");" }.join("\n")}
    #{reads.call('after ').join("\n")}
      { mrb_value drv = mrb_obj_new(M, mrb_class_get(M, "EcDrv"), 0, nullptr);
        call(M, "sub_table", drv, "sub_table", 1, &use);
        call(M, "sub_sub", drv, "sub_sub", 1, &use); }
      { mrb_value v = mrb_load_string(M, "[\\"s\\"]"); call(M, "poke", use, "poke", 1, &v); }
      call(M, "p_read after poke", use, "p_read");
      return 0;
    }
  CPP
end

builds = [] # [label, build dir, mrbc, flags, full?]
if ENV['MRBC'] && runtime.compiler? && !ENV['FT_GENERATED_ONLY']
  full = runtime.full || (ENV['BC2CPP_FULL_BUILD_DIR'] ? runtime.full_or_build : nil)
  builds << ['mrb_int 64, full-core', full, ENV['MRBC'], '', true] if full
  core = runtime.core
  builds << ['mrb_int 64, core only', core, ENV['MRBC'], '', false] if core
  if ENV['BC2CPP_MRUBY_FULL32'] && ENV['BC2CPP_MRBC32']
    builds << ['mrb_int 32 (MRB_INT32)', ENV['BC2CPP_MRUBY_FULL32'], ENV['BC2CPP_MRBC32'],
               '-DMRB_32BIT -DMRB_INT32 -no-pie -DMRB_USE_BIGINT', true]
  end
end
puts '-- SKIP run: set MRBC, BC2CPP_MRUBY_FULL (libmruby.a from the patched 3rd/mruby) and have g++' if builds.empty?

builds.each do |label, build, mrbc, flags, full|
  puts "-- fixture on real mruby (#{label}), interpreted and compiled"
  saved = ENV.values_at('MRBC', 'BC2CPP_CXXFLAGS')
  ENV['MRBC'] = mrbc
  ENV['BC2CPP_CXXFLAGS'] = flags
  begin
    Dir.mktmpdir do |dir|
      _code, err = generate.call(FIXTURE, dir)
      built, output = runtime.run(dir, err, OWNERS, driver.call, build: build, full: full)
      check.call('the fixture compiles and runs against real mruby', built)
      puts output.to_s.lines.last(20).join unless built
      next unless built

      sections = runtime.sections(output)
      values = ->(section) { sections.fetch(section, []).reject { |l| l.start_with?('  ') } }
      interpreted = values.call('interpreted')
      compiled = values.call('compiled')
      puts output if ENV['BC2CPP_CHECK_VERBOSE'] || interpreted != compiled
      check.call("every call answers what the interpreter answers (#{interpreted.size} lines), values and exceptions alike",
                 !interpreted.empty? && interpreted == compiled)
      check.call('the reads answer the stored values',
                 compiled.include?('lit_idx => 21') && compiled.include?('neg_idx => 31') && compiled.include?('oob_default => 8') &&
                   compiled.include?('hash_lit => 3') && compiled.include?('counts => 7') && compiled.include?('empty_first => 5'))
      check.call('a Float slot and slots past the 31-bit fixnum range answer as the interpreter does',
                 compiled.include?('float_slot => 3.5') && compiled.include?('big_sum => 3500000000'))
      check.call('a computed index reads a slot, or nil when it is out of range',
                 compiled.include?('var_idx(0) => 11') && compiled.include?('var_idx(3) => 1') && compiled.include?('var_idx(-4) => 1') &&
                   compiled.include?('hash_var(99) => 10'))
      check.call('every attempt to change a frozen table raises (FrozenError where the build has the method)',
                 compiled.grep(/\Am_\w+ => raised /).size == MUTATIONS.size &&
                   (!full || compiled.grep(/\Am_\w+ => raised FrozenError\z/).size == MUTATIONS.size))
      check.call('the tables read the same after every attempt',
                 %w[lit_idx neg_idx ends counts hash_lit hash_sym].all? do |fn|
                   compiled.find { |l| l.start_with?("#{fn} =>") }&.sub("#{fn} =>", '') ==
                     compiled.find { |l| l.start_with?("after #{fn} =>") }&.sub("after #{fn} =>", '')
                 end)
      check.call('the copy and the late freeze are the interpreter\'s (a mutable copy, then the TypeError of a String slot)',
                 compiled.include?('dup_idx => 11') && compiled.any? { |l| l.start_with?('late_freeze => raised') })
      check.call('an Array subclass argument reaches its own []',
                 compiled.include?('sub_table => 11') && compiled.any? { |l| l.start_with?('sub_sub => raised') })
      check.call('an ivar written through instance_variable_set is read as written',
                 compiled.include?('p_read => 11') && (compiled.any? { |l| l.start_with?('p_read after poke => raised') } ||
                   (compiled.any? { |l| l.start_with?('poke => raised') } && compiled.include?('p_read after poke => 11'))))
      # The indented lines of a compiled run count the by-name calls a method made.
      counts = output.lines.each_cons(2).filter_map do |line, following|
        following.strip.split('=').last.to_i if line.start_with?('lit_idx =>') && following.start_with?('  dispatches=')
      end
      check.call("a proven read makes no by-name dispatch in the compiled run (lit_idx made #{counts.last.inspect})",
                 counts.last&.zero?)
    end
  ensure
    saved[0] ? ENV['MRBC'] = saved[0] : ENV.delete('MRBC')
    saved[1] ? ENV['BC2CPP_CXXFLAGS'] = saved[1] : ENV.delete('BC2CPP_CXXFLAGS')
  end
end

if failures.empty?
  puts 'bc2cpp frozen tables check: PASS'
else
  warn "bc2cpp frozen tables check: #{failures.size} failure(s)"
  exit 1
end
