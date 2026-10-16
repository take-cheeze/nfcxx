#!/usr/bin/env ruby
# frozen_string_literal: true

# RBS_RECORD_TYPES (docs/adr/0454): an RBS record type on an ivar is checked at every write and feeds the
# RECORD_HASH_PROOF table and a guarded receiver hint.
#
# 1. Loader: record fields, optional keys, nilable records, `untyped`, an unsupported field type (TC1009).
# 2. Checker on compiled fixtures: accepted writers (literals, `h[:k] = v`, `update({...})`, `merge!({...})`,
#    `store`, delete of an optional key, call-site pooled keys, an attr_reader) and one located TC1009 error per
#    refused shape (computed key, non-literal update, wrong value class, undeclared key, omitted required key,
#    delete of a required key, clear, replace, escape, outside spelling, reflection).
# 3. Generated code: a literal-key read of a verified key is a guarded TYPED call; without the declaration (or
#    with a refused one) the send keeps its by-name dispatch.
#
# Usage: MRBC=path/to/mrbc ruby scripts/bc2cpp/rbs_record_types_check.rb   (prints SKIP without MRBC)

require 'set'
require 'tmpdir'

unless ENV['MRBC'] && File.executable?(ENV['MRBC'])
  puts 'bc2cpp rbs record types check: SKIP (set MRBC to a host mrbc)'
  exit 0
end

require_relative '../../tools/bc2cpp/bc2cpp'
require_relative '../../tools/bc2cpp/compiled_gems'
require_relative '../../tools/bc2cpp/nomethod_reviewed_probe'

ROOT = File.expand_path('../..', __dir__)
failures = []
check = lambda do |what, condition|
  puts "  #{condition ? 'ok  ' : 'FAIL'} #{what}"
  failures << what unless condition
end

WIO_GEMS = NomethodReviewedProbe.wio_gems(ROOT)
OUTSIDE_NATIVE, OUTSIDE_RUBY = bc2cpp_closed_world_outside_srcs('wio', WIO_GEMS, ROOT)
OUTSIDE_TOKENS = outside_world_tokens(OUTSIDE_NATIVE + OUTSIDE_RUBY)
OUTSIDE_IVARS = outside_ivar_names(OUTSIDE_NATIVE + OUTSIDE_RUBY)

def load_sig(dir, rbs)
  path = File.join(dir, 'rt.rbs')
  File.write(path, rbs)
  RbsRecordTypes.load([path], display_root: dir)
end

# Compiles +source+, checks +rbs+ against it and yields (result, registry, gen); the process-wide tables are
# always cleared. +foreign+ is extra outside Ruby text (an outside spelling).
def checked(source, rbs, foreign: nil)
  Dir.mktmpdir do |dir|
    path = File.join(dir, 'rt.rb')
    File.write(path, source)
    ruby_paths = OUTSIDE_RUBY
    outside = OUTSIDE_IVARS
    if foreign
      extra = File.join(dir, 'outside.rb')
      File.write(extra, foreign)
      ruby_paths += [extra]
      outside = outside_ivar_names(OUTSIDE_NATIVE + ruby_paths)
    end
    ireps, root_label = compile_ireps(path, 'bc2cpp_rt', dir)
    registry, superclass_of, containers, included, prepended, unknown, _s, class_decls, walked, _b, _c, modules =
      build_registry(ireps, root_label)
    UniqueClassNames.table = UniqueClassNames.analyze(ireps, root_label, [], [])
    ConstructClassNames.table = ConstructClassNames.analyze(ireps, root_label, UniqueClassNames.table.values)
    world = ClosedWorld.new(ireps: ireps, registry: registry, class_decls: class_decls, walked: walked,
                            native_paths: OUTSIDE_NATIVE, ruby_paths: ruby_paths, module_names: modules)
    rh = RecordHash.analyze(ireps, registry, native_paths: OUTSIDE_NATIVE, foreign_paths: ruby_paths,
                                             closed_world: world, outside_tokens: OUTSIDE_TOKENS)
    RecordHash.table = rh.table
    RecordHash.readers = rh.readers
    result = nil
    if rbs
      result = RbsRecordTypes.check(load_sig(dir, rbs), ireps, registry,
                                    closed_world: world, native_paths: OUTSIDE_NATIVE, foreign_paths: ruby_paths,
                                    outside_ivars: outside, superclass_of: superclass_of,
                                    container_constants: containers, display_root: dir)
      RbsRecordTypes.install(result)
    end
    gen = CodeGen.new(ireps, registry, {}, {}, {}, {}, superclass_of, {}, {}, {}, {}, Set.new, nil, nil, nil,
                      included, prepended, unknown, closed_world: world)
    result&.diagnostics&.each { |d| warn "    #{d.file}:#{d.line}: #{d.message}" } if ENV['BC2CPP_CHECK_VERBOSE']
    yield(result, registry, gen)
  ensure
    RecordHash.table = nil
    RecordHash.readers = nil
    RecordHash.pool = nil
    RbsRecordTypes.hints = nil
  end
end

def errors(result)
  result.diagnostics.select { |d| d.severity == 'error' }
end

# ---------------------------------------------------------------------------
puts '-- loader'
Dir.mktmpdir do |dir|
  loaded = load_sig(dir, <<~RBS)
    class RtA
      @rt: { a: Integer, ?b: String?, c: untyped, d: bool | Symbol }
      @rt_n: { a: Integer }?
      attr_reader rt_r: { x: RtA }
      @plain: Integer
      def make: () -> { a: Integer }
    end
  RBS
  rt = loaded.decls.find { |d| d.ivar == 'rt' }
  check.call('an ivar record type is loaded with its fields', rt && rt.fields.keys.sort == %w[a b c d])
  check.call('a `?key:` field is optional', rt && rt.fields['b'].optional && !rt.fields['a'].optional)
  check.call('a nilable field allows NilClass', rt && rt.fields['b'].classes == Set['String', 'NilClass'])
  check.call('an untyped field is unchecked', rt && rt.fields['c'].classes.nil?)
  check.call('a union field lists every class',
             rt && rt.fields['d'].classes == Set['TrueClass', 'FalseClass', 'Symbol'])
  check.call('`{ ... }?` is a nilable record', loaded.decls.find { |d| d.ivar == 'rt_n' }&.nilable)
  check.call('an attr_reader record names its ivar', loaded.decls.any? { |d| d.ivar == 'rt_r' })
  check.call('a non-record ivar is left to RbsSignatures', loaded.decls.none? { |d| d.ivar == 'plain' })
  check.call('a record return type is a TC1005 note',
             loaded.diagnostics.any? { |d| d.code == 'TC1005' && d.message.include?('record return type') })
  bad = load_sig(dir, "class RtA\n  @rt: { a: Array[Integer] | Foo[Bar] }\nend\n")
  check.call('a field type that cannot be checked is a TC1009 error',
             bad.decls.empty? && bad.diagnostics.any? { |d| d.code == 'TC1009' && d.line == 2 })
end

# ---------------------------------------------------------------------------
puts '-- accepted writers'
GOOD = <<~'RUBY'
  class RtEngine
    def initialize; @lvl = 1; end
    def rt_go(n); @lvl += n; end
  end
  class RtOther
    def rt_go(n); -n; end
  end
  class RtHost
    attr_reader :rt
    def initialize
      @rt = {}
      nil
    end
    def rt_start
      @rt.update({ engine: RtEngine.new, count: 0, names: [] })
      nil
    end
    def rt_more
      @rt.merge!({ count: 1 })
      @rt[:win] = RtEngine.new
      @rt.store(:label, 'x')
      rt_put(:count)
      rt_kw(scroll: :count)
      nil
    end
    def rt_put(k); @rt[k] = 2; nil; end
    def rt_kw(scroll: nil); @rt[scroll] = 3 if scroll; nil; end
    def rt_drop; @rt.delete(:win); nil; end
    def rt_has; @rt.key?(:win); end
    def rt_engine_go(n); @rt[:engine].rt_go(n); end
    def rt_alias_go(n); ui = @rt; ui && ui[:engine].rt_go(n); end
  end
  class RtUser
    def rt_peek(host); host.rt[:engine].rt_go(1); end
  end
RUBY
GOOD_RBS = <<~RBS
  class RtHost
    @rt: { ?engine: RtEngine, ?count: Integer, ?names: Array[untyped], ?win: RtEngine, ?label: String }
  end
RBS
checked(GOOD, GOOD_RBS) do |result, registry, gen|
  check.call('a record written by literal, update, merge!, []=, store, pooled keys and an optional delete is verified',
             errors(result).empty? && result.verified.key?('rt'))
  check.call('a single-class field is a hint', result.hints['rt'] && result.hints['rt']['engine'] == 'RtEngine')
  check.call('the attr_reader joins the RECORD_HASH readers', result.readers.include?('rt'))
  check.call('the verified name joins the RECORD_HASH table', RecordHash.table.key?('rt'))
  code_of = ->(owner, meth) { gen.compile_method(registry.fetch(meth).find { |d| d.owner == owner }.irep).fetch(:code) }
  go = code_of.call('RtHost', 'rt_engine_go')
  check.call('a literal-key read of a hinted key is a guarded TYPED call',
             go.match?(/TYPED[A-Z_]* :rt_go -> RtEngine#rt_go/))
  peek = code_of.call('RtUser', 'rt_peek')
  check.call('a read through the attr_reader is hinted too', peek.match?(/TYPED[A-Z_]* :rt_go -> RtEngine#rt_go/))
end
checked(GOOD, nil) do |_result, registry, gen|
  go = gen.compile_method(registry.fetch('rt_engine_go').find { |d| d.owner == 'RtHost' }.irep).fetch(:code)
  check.call('without the declaration the read is not hinted', !go.match?(/TYPED[A-Z_]* :rt_go -> RtEngine/))
end

checked(<<~'RUBY', "class RtFull\n  @rf: { k: RtFull, n: Integer? }\nend\n") do |result, _registry, _gen|
  class RtFull
    def initialize; @rf = { k: RtFull.new(1), n: nil }; nil; end
    def rf_set; @rf[:n] = 4; nil; end
  end
RUBY
  check.call('a literal carrying every required key, and a nilable field, are verified', errors(result).empty?)
end

# ---------------------------------------------------------------------------
puts '-- refused writers (one located TC1009 error each)'
HEAD = "class RtX\n  def initialize; @rx = { a: 1 }; nil; end\n"
RBS_X = "class RtX\n  @rx: { a: Integer, ?b: Integer }\nend\n"
REFUSED = [
  ['a computed key', "#{HEAD}  def m(k); @rx[k] = 1; nil; end\n  def n(z); m(z); end\nend\n", 3,
   /non-literal key write/],
  ['a non-literal update', "#{HEAD}  def m(o); @rx.update(o); nil; end\nend\n", 3, /non-literal update/],
  ['a computed key inside an update literal',
   "#{HEAD}  def m(k); @rx.update({ k => 1 }); nil; end\n  def n(z); m(z); end\nend\n", 3, /computed key in update/],
  ['a wrong value class', "#{HEAD}  def m; @rx[:a] = 'str'; nil; end\nend\n", 3,
   /value of :a is String, declared Integer/],
  ['a wrong value class in an update literal', "#{HEAD}  def m; @rx.update({ b: :sym }); nil; end\nend\n", 3,
   /value of :b is Symbol/],
  ['an untraceable value', "#{HEAD}  def m(v); @rx[:a] = v; nil; end\nend\n", 3, /cannot be traced/],
  ['an undeclared key', "#{HEAD}  def m; @rx[:zz] = 1; nil; end\nend\n", 3, /key :zz is not declared/],
  ['an undeclared key in the stored literal', "class RtX\n  def initialize; @rx = { a: 1, q: 2 }; nil; end\nend\n", 2,
   /key :q is not declared/],
  ['a literal without a required key', "class RtX\n  def initialize; @rx = {}; nil; end\nend\n", 2,
   /omits required key\(s\) :a/],
  ['delete of a required key', "#{HEAD}  def m; @rx.delete(:a); nil; end\nend\n", 3, /delete of required key/],
  ['clear', "#{HEAD}  def m; @rx.clear; nil; end\nend\n", 3, /operand of SEND/],
  ['replace', "#{HEAD}  def m; @rx.replace({ a: 2 }); nil; end\nend\n", 3, /operand of SEND/],
  ['an escape', "#{HEAD}  def m; take(@rx); nil; end\n  def take(h); h; end\nend\n", 3, /operand of SSEND/],
  ['a nil store into a non-nilable record', "#{HEAD}  def m; @rx = nil; end\nend\n", 3, /nil is stored/],
  ['an attr_writer (reported at the declaration)',
   "class RtX\n  attr_writer :rx\n  def initialize; @rx = { a: 1 }; nil; end\nend\n", 2,
   /declaration refused: attr_writer/, 'rt.rbs']
].freeze
REFUSED.each do |what, source, line, reason, file = 'rt.rb'|
  checked(source, RBS_X) do |result, _registry, _gen|
    located = errors(result).any? do |d|
      d.code == 'TC1009' && d.file == file && d.line == line && d.message.match?(reason)
    end
    check.call("#{what} is a TC1009 error at its line (#{reason.source})", located && !result.verified.key?('rx'))
    check.call("#{what} installs no hint", result.hints.empty?)
  end
end

checked("#{HEAD}end\n", RBS_X, foreign: "class RtX\n  def peek; @rx; end\nend\n") do |result, _registry, _gen|
  check.call('an ivar spelled by an outside source refuses the declaration (TC1009 at the .rbs)',
             errors(result).any? { |d| d.file == 'rt.rbs' && d.message.match?(/spelled by a foreign Ruby source/) } &&
             result.verified.empty?)
end
checked("#{HEAD}  def m(n); instance_variable_get(n); end\nend\n", RBS_X) do |result, _registry, _gen|
  check.call('computed reflection refuses every declaration',
             errors(result).any? { |d| d.message.match?(/reflection/) } && result.verified.empty?)
end
BAD_HINT = "#{HEAD}  def m; @rx[:a] = 'bad'; nil; end\n  def go; @rx[:a].succ; end\nend\n"
checked(BAD_HINT, RBS_X) do |result, registry, gen|
  go = gen.compile_method(registry.fetch('go').find { |d| d.owner == 'RtX' }.irep).fetch(:code)
  check.call('a refused declaration gives no hint to the generated code',
             !result.verified.key?('rx') && !go.match?(/TYPED[A-Z_]* :succ -> Integer/))
end

if failures.empty?
  puts 'bc2cpp rbs record types check: PASS'
else
  warn "bc2cpp rbs record types check: #{failures.size} failure(s)"
  exit 1
end
