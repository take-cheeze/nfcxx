#!/usr/bin/env ruby
# frozen_string_literal: true

# RECORD_HASH_PROOF (docs/adr/0285): per-key value classes of a record-like Hash in an ivar.
#
# 1. Analysis fixtures: each accepted shape (literal-key reads and writes, readers, delete, branch
#    refinement, captured locals, call-site pooled keys, handlers) and each refusal the ADR lists
#    (non-literal key write, merge!, default proc, send, dup/clone, Marshal round trip, Hash subclass,
#    compare_by_identity, attr_writer, instance_variable_*, escapes) is compiled and analysed.
# 2. Generated code: an Array key gets the inlined loop with no dynamic fallback, a key holding one
#    class of fresh objects gets an exact-class direct call; every refusal keeps its guard/fallback.
# 3. With BC2CPP_MRUBY_FULL and g++: the fixtures run against real mruby, interpreted and compiled,
#    and must answer alike.
#
# Usage: MRBC=path/to/mrbc [BC2CPP_MRUBY_CORE=dir BC2CPP_MRUBY_FULL=dir] ruby scripts/bc2cpp/record_hash_check.rb

require 'set'
require 'tmpdir'
require_relative '../../tools/bc2cpp/bc2cpp'
require_relative '../../tools/bc2cpp/compiled_gems'
require_relative '../../tools/bc2cpp/nomethod_reviewed_probe'
require_relative 'fixture_runtime'

ROOT = File.expand_path('../..', __dir__)
failures = []
check = lambda do |what, condition|
  puts "  #{condition ? 'ok  ' : 'FAIL'} #{what}"
  failures << what unless condition
end

WIO_GEMS = NomethodReviewedProbe.wio_gems(ROOT)
OUTSIDE_NATIVE, OUTSIDE_RUBY = bc2cpp_closed_world_outside_srcs('wio', WIO_GEMS, ROOT)
OUTSIDE_TOKENS = outside_world_tokens(OUTSIDE_NATIVE + OUTSIDE_RUBY)

# Compiles +source+ under the wio closed world, runs RecordHash.analyze, yields (result, registry, gen)
# and always clears the process-wide table.
def analysed(source, name = 'rh')
  Dir.mktmpdir do |dir|
    path = File.join(dir, "#{name}.rb")
    File.write(path, source)
    ireps, root_label = compile_ireps(path, "bc2cpp_#{name}", dir)
    registry, superclass_of, _containers, included, prepended, unknown, _s, class_decls, walked, _b, _c, modules =
      build_registry(ireps, root_label)
    UniqueClassNames.table = UniqueClassNames.analyze(ireps, root_label, [], [])
    ConstructClassNames.table = ConstructClassNames.analyze(ireps, root_label, UniqueClassNames.table.values)
    world = ClosedWorld.new(ireps: ireps, registry: registry, class_decls: class_decls, walked: walked,
                            native_paths: OUTSIDE_NATIVE, ruby_paths: OUTSIDE_RUBY, module_names: modules)
    result = RecordHash.analyze(ireps, registry, native_paths: OUTSIDE_NATIVE, foreign_paths: OUTSIDE_RUBY,
                                                 closed_world: world, outside_tokens: OUTSIDE_TOKENS)
    RecordHash.table = result.table
    RecordHash.readers = result.readers
    gen = CodeGen.new(ireps, registry, {}, {}, {}, {}, superclass_of, {}, {}, {}, {}, Set.new, nil, nil, nil,
                      included, prepended, unknown, closed_world: world)
    warn "  (refused: #{result.refused.inspect} global: #{result.global_refusal.inspect})" if ENV["BC2CPP_CHECK_VERBOSE"]
    yield(result, registry, gen)
  ensure
    RecordHash.table = nil
    RecordHash.readers = nil
    RecordHash.pool = nil
  end
end

def key_classes(result, slot, key, tier = :strict)
  result.slots[slot]&.keys&.dig(key, tier)&.to_a&.map(&:to_s)&.sort
end

# ---------------------------------------------------------------------------
puts '-- accepted shapes'
analysed(<<~'RUBY') do |result, _registry, _gen|
  class RhBasic
    def initialize
      @rh_a = { name: :idle, foes: [1, 2], count: 0, cfg: {}, tag: 'x', maybe: nil }
      nil
    end
    def rh_bump; @rh_a[:count] = @rh_a[:count] + 1; end
    def rh_set; @rh_a[:maybe] = [3]; end
    def rh_phase; @rh_a[:name]; end
    def rh_or; @rh_a[:foes] ||= []; end
    def rh_add; @rh_a[:count] += 1; end
  end
RUBY
  check.call('a literal-key record is accepted', result.slots.key?('rh_a'))
  check.call('an Array literal key with only that literal is a strict non-nil Array',
             key_classes(result, 'rh_a', 'foes') == %w[Array])
  check.call('a Symbol literal key joins to Symbol', key_classes(result, 'rh_a', 'name') == %w[Symbol])
  check.call('a nil literal later stored with an Array is Array|nil', key_classes(result, 'rh_a', 'maybe') == %w[Array NilClass])
  check.call('an Integer key whose store is arithmetic stays unclassified (unknown)',
             key_classes(result, 'rh_a', 'count').include?('unknown'))
  check.call('the empty Hash literal value is Hash', key_classes(result, 'rh_a', 'cfg') == %w[Hash])
end

analysed(<<~'RUBY') do |result, _registry, _gen|
  class RhTwo
    def initialize(flag)
      @rh_b = flag ? { keep: [1], only_a: [2] } : { keep: [3] }
      nil
    end
    def rh_get; @rh_b[:only_a]; end
  end
RUBY
  check.call('two literals are accepted', result.slots.key?('rh_b') && result.slots['rh_b'].literals == 2)
  check.call('a key one literal omits reads nil as well', key_classes(result, 'rh_b', 'only_a') == %w[Array NilClass])
  check.call('a key both literals carry stays non-nil', key_classes(result, 'rh_b', 'keep') == %w[Array])
end

analysed(<<~'RUBY') do |result, _registry, _gen|
  class RhEmpty
    def initialize(flag)
      @rh_h = flag ? {} : { keep: [1] }
      nil
    end
    def rh_get; @rh_h[:keep]; end
  end
RUBY
  check.call('an empty literal makes every key of the other literal nilable', key_classes(result, 'rh_h', 'keep') == %w[Array NilClass])
end

analysed(<<~'RUBY') do |result, _registry, _gen|
  class RhDel
    def initialize; @rh_c = { a: [1], b: [2] }; nil; end
    def rh_drop; @rh_c.delete(:a); end
  end
RUBY
  check.call('delete with a literal key is accepted and makes the key nilable',
             key_classes(result, 'rh_c', 'a') == %w[Array NilClass] && key_classes(result, 'rh_c', 'b') == %w[Array])
end

analysed(<<~'RUBY') do |result, registry, _gen|
  class RhReader
    attr_reader :rh_d
    def initialize; @rh_d = { k: [1] }; nil; end
  end
  class RhUser
    def go(o); o.rh_d[:k]; end
  end
RUBY
  check.call('an attr_reader whose call sites only index literally is accepted', result.slots.key?('rh_d'))
  check.call('the reader name is recorded so its call sites read the slot', result.readers.include?('rh_d'))
  check.call('the reader has a bytecode-free definition only', registry['rh_d'].all? { |d| d.kind == :ivar_accessor })
end

analysed(<<~'RUBY') do |result, _registry, _gen|
  class RhLocal
    def initialize; @rh_e = { k: [1], j: [2] }; nil; end
    def rh_alias
      ui = @rh_e
      [1].each { |i| ui[:k] = [i] }
      ui[:j]
    end
    def rh_guard; @rh_e && @rh_e[:k]; end
    def rh_branch
      h = @rh_e
      return nil unless h
      h[:j]
    end
  end
RUBY
  check.call('a local alias captured by a block, a && guard and a branch on the alias are accepted',
             result.slots.key?('rh_e'))
  check.call('the captured-block store joins its Array literal into the key', key_classes(result, 'rh_e', 'k') == %w[Array])
end

analysed(<<~'RUBY') do |result, _registry, _gen|
  class RhPool
    def initialize; @rh_f = { a: 1, b: 2 }; nil; end
    def rh_go; rh_draw(:a); rh_draw(:b); rh_put(scroll_key: :a); rh_put; end
    def rh_draw(key); @rh_f[key] = 3; end
    def rh_put(scroll_key: nil); @rh_f[scroll_key] = 4 if scroll_key; end
  end
RUBY
  check.call('positional and keyword call-site Symbols pool into the key set', result.slots.key?('rh_f'))
  check.call('the pooled keys receive the stored classes', key_classes(result, 'rh_f', 'a') == %w[Integer] &&
                                                              key_classes(result, 'rh_f', 'b') == %w[Integer])
end

analysed(<<~'RUBY') do |result, _registry, _gen|
  class RhRescue
    def initialize; @rh_g = { k: [1] }; nil; end
    def rh_safe
      @rh_g[:k]
    rescue ArgumentError
      @rh_g[:k] = [2]
    end
  end
RUBY
  check.call('a method with a rescue handler is analysed through its handler edges', result.slots.key?('rh_g'))
end

# ---------------------------------------------------------------------------
puts '-- refusals'
REFUSED = [
  ['a non-literal key write', "class RhN1\n  def initialize; @rh_x = { a: 1 }; nil; end\n  def put(k); @rh_x[k] = 1; end\n  def run(z); put(z); end\nend\n", /non-literal key write/],
  ['merge!', "class RhN2\n  def initialize; @rh_x = { a: 1 }; nil; end\n  def m(o); @rh_x.merge!(o); end\nend\n", /operand of SEND/],
  ['a Hash with a default proc', "class RhN3\n  def initialize; @rh_x = { a: 1 }; nil; end\n  def m; @rh_x = Hash.new { |h, k| h[k] = [] }; nil; end\nend\n", /store from SENDB/],
  ['a store from an argument', "class RhN4\n  def initialize(h); @rh_x = h; nil; end\n  def m; @rh_x = { a: 1 }; nil; end\nend\n", /store from an argument/],
  ['a send on the Hash', "class RhN5\n  def initialize; @rh_x = { a: 1 }; nil; end\n  def m; @rh_x.send(:store, :b, 2); end\nend\n", /operand of SEND/],
  ['dup', "class RhN6\n  def initialize; @rh_x = { a: 1 }; nil; end\n  def m; @rh_x.dup; end\nend\n", /operand of SEND0/],
  ['clone', "class RhN7\n  def initialize; @rh_x = { a: 1 }; nil; end\n  def m; @rh_x.clone; end\nend\n", /operand of SEND0/],
  ['a Marshal round trip', "class RhN8\n  def initialize; @rh_x = { a: 1 }; nil; end\n  def m; Marshal.load(Marshal.dump(@rh_x)); end\nend\n", /operand of SEND/],
  ['a Hash subclass', "class RhSub < Hash; end\nclass RhN9\n  def initialize; @rh_x = RhSub.new; nil; end\n  def m; @rh_x = { a: 1 }; nil; end\nend\n", /store from SEND/],
  ['compare_by_identity', "class RhN10\n  def initialize; @rh_x = { a: 1 }; @rh_x.compare_by_identity; nil; end\nend\n", /operand of SEND0/],
  ['an attr_writer', "class RhN11\n  attr_writer :rh_x\n  def initialize; @rh_x = { a: 1 }; nil; end\nend\n", /attr_writer/],
  ['an attr_accessor', "class RhN12\n  attr_accessor :rh_x\n  def initialize; @rh_x = { a: 1 }; nil; end\nend\n", /attr_writer/],
  ['returning the Hash', "class RhN13\n  def initialize; @rh_x = { a: 1 }; nil; end\n  def m; @rh_x; end\nend\n", /operand of RETURN/],
  ['passing the Hash on', "class RhN14\n  def initialize; @rh_x = { a: 1 }; nil; end\n  def m; take(@rh_x); end\n  def take(h); h; end\nend\n", /operand of SSEND/],
  ['storing the Hash in another ivar', "class RhN15\n  def initialize; @rh_x = { a: 1 }; @rh_y = @rh_x; nil; end\nend\n", /stored to @rh_y/],
  ['a local alias passed on', "class RhN16\n  def initialize; @rh_x = { a: 1 }; nil; end\n  def m; h = @rh_x; take(h); end\n  def take(h); h; end\nend\n", /operand of SSEND/],
  ['a captured alias passed on', "class RhN17\n  def initialize; @rh_x = { a: 1 }; nil; end\n  def m; h = @rh_x; [1].each { |i| take(h) }; end\n  def take(h); h; end\nend\n", /operand of SSEND/],
  ['instance_variable_get of the name', "class RhN18\n  def initialize; @rh_x = { a: 1 }; nil; end\n  def m; instance_variable_get(:@rh_x); end\nend\n", /reflection instance_variable_get/],
  ['instance_variable_set of the name', "class RhN19\n  def initialize; @rh_x = { a: 1 }; nil; end\n  def m(v); instance_variable_set(:@rh_x, v); end\nend\n", /reflection instance_variable_set/],
  ['a non-Symbol key', "class RhN20\n  def initialize; @rh_x = { 'a' => 1 }; nil; end\n  def m; @rh_x[:a]; end\nend\n", /non-literal key in a Hash literal/],
  ['a double splat in the literal', "class RhN21\n  def initialize(o); @rh_x = { a: 1, **o }; nil; end\n  def m; @rh_x = { a: 1 }; nil; end\nend\n", /store from HASHCAT/],
  ['each on the Hash', "class RhN22\n  def initialize; @rh_x = { a: 1 }; nil; end\n  def m; @rh_x.each { |k, v| v }; end\nend\n", /operand of SENDB/],
  ['fetch on the Hash', "class RhN23\n  def initialize; @rh_x = { a: 1 }; nil; end\n  def m; @rh_x.fetch(:a); end\nend\n", /operand of SEND/],
  ['a Symbol key that cannot be pooled (unresolved caller)', "class RhN24\n  def initialize; @rh_x = { a: 1 }; nil; end\n  def rh_put(k); @rh_x[k] = 1; end\n  def m(s); send(:rh_put, s); end\nend\n", /non-literal key write/],
  ['a positional key whose method is also named as a Symbol', "class RhN25\n  def initialize; @rh_x = { a: 1 }; nil; end\n  def rh_put2(k); @rh_x[k] = 1; end\n  def m; rh_put2(:a); method(:rh_put2); end\nend\n", /non-literal key write/],
  ['delete with a computed key', "class RhN26\n  def initialize; @rh_x = { a: 1 }; nil; end\n  def m(k); @rh_x.delete(k); end\nend\n", /non-literal delete/],
  ['delete with a block', "class RhN27\n  def initialize; @rh_x = { a: 1 }; nil; end\n  def m; @rh_x.delete(:a) { 1 }; end\nend\n", /operand of SENDB/],
  ['the reader named as a Symbol', "class RhN28\n  attr_reader :rh_x\n  def initialize; @rh_x = { a: 1 }; nil; end\n  def m(o); o.send(:rh_x); end\nend\n", /reader named as a Symbol/]
].freeze
REFUSED.each do |what, source, reason|
  analysed(source) do |result, _registry, _gen|
    check.call("#{what} refuses the slot (#{reason.source})",
               !result.slots.key?('rh_x') && result.refused['rh_x'].to_s.match?(reason))
  end
end
analysed("class RhG\n  def initialize; @rh_x = { a: [1] }; nil; end\n  def m(n); instance_variable_get(n); end\nend\n") do |result, _r, _g|
  check.call('a computed instance_variable_get refuses every slot', result.global_refusal && result.slots.empty?)
end

# ---------------------------------------------------------------------------
puts '-- generated code'
CODE = <<~'RUBY'
  class RhEngine
    def initialize; @lvl = 1; end
    def rh_go(n); @lvl += n; end
  end
  class RhOther
    def rh_go(n); -n; end
  end
  class RhHost
    def initialize
      @rh_ui = { foes: [1, 2, 3], engine: RhEngine.new, mixed: RhEngine.new, list: [1], cfg: { a: 1 }, tag: 'ab' }
      nil
    end
    def rh_natives; [@rh_ui[:foes].size, @rh_ui[:cfg].key?(:a), @rh_ui[:cfg].key?(:b), @rh_ui[:tag].size, @rh_ui[:foes].first]; end
    def rh_sum; t = 0; @rh_ui[:foes].each { |x| t += x }; t; end
    def rh_engine_go(n); @rh_ui[:engine].rh_go(n); end
    def rh_mixed_go(n); @rh_ui[:mixed].rh_go(n); end
    def rh_swap(o); @rh_ui[:mixed] = o; nil; end
    def rh_list_sum; t = 0; @rh_ui[:list].each { |x| t += x }; t; end
    def rh_list_set(v); @rh_ui[:list] = v; nil; end
  end
  class RhDelHost
    def initialize
      @rh_dd = { foes: [1, 2], engine: RhEngine.new }
      nil
    end
    def rh_dsum; t = 0; @rh_dd[:foes].each { |x| t += x }; t; end
    def rh_dgo(n); @rh_dd[:engine].rh_go(n); end
    def rh_ddrop; @rh_dd.delete(:foes); nil; end
  end
RUBY
analysed(CODE) do |result, registry, gen|
  dispatch = ->(code) { code.gsub(%r{//[^\n]*}, '').match?(/mrb_funcall|bc2cpp_send|bc2cpp_nomethod/) }
  code_of = ->(owner, meth) { gen.compile_method(registry.fetch(meth).find { |d| d.owner == owner }.irep).fetch(:code) }
  check.call('the host record is accepted', result.slots.key?('rh_ui'))
  sum = code_of.call('RhHost', 'rh_sum')
  check.call('an Array key that only holds Array literals is inlined with no dynamic fallback',
             sum.include?('Array receiver for inlined #each') && !sum.include?('mrb_funcall_with_block'))
  go = code_of.call('RhHost', 'rh_engine_go')
  exact_go = ->(code) { code.match?(/(?:CLOSED_WORLD_EXACT_CLASS|EXACT_TYPED) :rh_go -> RhEngine#rh_go/) }
  check.call('a key holding only fresh RhEngine.new is an exact-class direct call',
             exact_go.call(go) && !dispatch.call(go))
  mixed = code_of.call('RhHost', 'rh_mixed_go')
  check.call('a key another method stores an unknown value into keeps its dispatch',
             !mixed.match?(/(?:CLOSED_WORLD_EXACT_CLASS|EXACT_TYPED) :rh_go/) && dispatch.call(mixed))
  check.call('a deletable Array key is not inlined (it may read nil)',
             !code_of.call('RhDelHost', 'rh_dsum').include?('Array receiver for inlined #each'))
  check.call('a key next to a deleted one keeps its exact class',
             exact_go.call(code_of.call('RhDelHost', 'rh_dgo')))
  list = code_of.call('RhHost', 'rh_list_sum')
  check.call('an Array key with an unclassified store keeps the fallback loop',
             !list.include?('Array receiver for inlined #each') || list.include?('mrb_funcall_with_block'))
end
LEAK = <<~'RUBY'
  class RhEngine
    def initialize; @lvl = 1; end
    def rh_go(n); @lvl += n; end
  end
  class RhOther
    def rh_go(n); -n; end
  end
  class RhLeak
    def initialize; @rh_ui = { engine: RhEngine.new }; nil; end
    def rh_leak; @rh_ui; end
    def rh_engine_go(n); @rh_ui[:engine].rh_go(n); end
  end
RUBY
analysed(LEAK) do |result, registry, gen|
  leak = gen.compile_method(registry.fetch('rh_engine_go').find { |d| d.owner == 'RhLeak' }.irep).fetch(:code)
  check.call('an escaping slot is refused', !result.slots.key?('rh_ui'))
  check.call('an escaping slot keeps the guarded dispatch', !leak.include?('CLOSED_WORLD_EXACT_CLASS'))
end

# ---------------------------------------------------------------------------
puts '-- fixtures on real mruby, interpreted and compiled'
runtime = Bc2cppFixtureRuntime
full = runtime.full
if full.nil? || !runtime.compiler?
  puts '  SKIP run: set BC2CPP_MRUBY_FULL (libmruby.a with the full-core gems, from the patched 3rd/mruby) and have g++'
else
  Dir.mktmpdir do |dir|
    owners = %w[RhEngine RhOther RhHost RhDelHost]
    _code, err = runtime.generate(CODE, dir, closed: true, only_owners: owners)
    body = <<~CPP
      static int scenario(mrb_state* M) {
        mrb_value host = mrb_obj_new(M, mrb_class_get(M, "RhHost"), 0, nullptr);
        call(M, "sum", host, "rh_sum");
        call(M, "natives on literal keys", host, "rh_natives");
        mrb_value three = mrb_fixnum_value(3);
        call(M, "engine go", host, "rh_engine_go", 1, &three);
        call(M, "engine go again", host, "rh_engine_go", 1, &three);
        call(M, "mixed go", host, "rh_mixed_go", 1, &three);
        mrb_value other = mrb_obj_new(M, mrb_class_get(M, "RhOther"), 0, nullptr);
        call(M, "swap in another class", host, "rh_swap", 1, &other);
        call(M, "mixed go after swap", host, "rh_mixed_go", 1, &three);
        mrb_value nothing = mrb_nil_value();
        call(M, "swap in nil", host, "rh_swap", 1, &nothing);
        call(M, "mixed go on nil", host, "rh_mixed_go", 1, &three);
        call(M, "list sum", host, "rh_list_sum");
        mrb_value replacement = mrb_ary_new(M);
        mrb_ary_push(M, replacement, mrb_fixnum_value(10));
        mrb_ary_push(M, replacement, mrb_fixnum_value(20));
        call(M, "replace list", host, "rh_list_set", 1, &replacement);
        call(M, "list sum after replace", host, "rh_list_sum");
        mrb_value not_a_list = mrb_fixnum_value(5);
        call(M, "replace list with an Integer", host, "rh_list_set", 1, &not_a_list);
        call(M, "list sum on an Integer", host, "rh_list_sum");
        mrb_value del = mrb_obj_new(M, mrb_class_get(M, "RhDelHost"), 0, nullptr);
        call(M, "delete host sum", del, "rh_dsum");
        call(M, "delete host go", del, "rh_dgo", 1, &three);
        call(M, "delete the key", del, "rh_ddrop");
        call(M, "sum after delete", del, "rh_dsum");
        call(M, "go after delete", del, "rh_dgo", 1, &three);
        return 0;
      }
    CPP
    built, output = runtime.run(dir, err, owners, body, build: full, full: true)
    check.call('the fixture compiles and runs against real mruby', built)
    puts output unless built
    if built
      sections = runtime.sections(output)
      values = ->(name) { sections.fetch(name, []).reject { |l| l.start_with?('  ') } }
      check.call('every call answers what the interpreter answers, including after the record is reassigned',
                 !values.call('interpreted').empty? && values.call('interpreted') == values.call('compiled'))
      puts output if ENV['BC2CPP_CHECK_VERBOSE'] || values.call('interpreted') != values.call('compiled')
      dispatches = sections.fetch('compiled', []).each_cons(2).to_h { |a, b| [a, b[/dispatches=(\d+)/, 1]&.to_i] }
      engine = dispatches.find { |line, _| line.start_with?('engine go =>') }&.last
      check.call('the exact-class engine call makes no dynamic dispatch', engine == 0)
    end
  end
end

if failures.empty?
  puts 'bc2cpp record hash check: PASS'
else
  warn "bc2cpp record hash check: #{failures.size} failure(s)"
  exit 1
end
