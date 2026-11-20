#!/usr/bin/env ruby
# frozen_string_literal: true

# FOREIGN_DEFINERS_PER_LIST: ForeignDefiners.scan keeps one entry per list of files, keyed and
# checked by the files' stat key as before, and defines_any? asks about several owners from one scan. Host only,
# well under a second:
#   - callers alternating between two file lists walk each list once, not once per switch;
#   - a rewritten file is walked again and its new definitions are seen; a deleted file drops out;
#   - every answer equals a fresh scan_files of the list;
#   - defines_any? answers what defines? answers for any of the owners, and with no owners scans nothing (a foreign
#     file that does not parse still raises only when asked);
#   - the closed world's nil check and the frozen-table refusal ask through defines_any?;
#   - PRECISE_REOPENERS: OutsideRubyOwners.scan names the owners of `Const.class_eval do`, a definition-free
#     `__send__(name) do` and an `each` over a literal name list instead of making them wild, and keeps every other
#     shape wild.
#
# Usage: ruby scripts/bc2cpp/foreign_definers_cache_check.rb

require 'set'
require 'tmpdir'
require_relative '../../tools/bc2cpp/foreign_definers'
require_relative '../../tools/bc2cpp/outside_ruby_owners'

failures = []
check = lambda do |what, condition|
  puts "  #{condition ? 'ok  ' : 'FAIL'} #{what}"
  failures << what unless condition
end

FD = ForeignDefiners

walks = 0
original = FD.method(:scan_files)
FD.singleton_class.send(:remove_method, :scan_files)
FD.define_singleton_method(:scan_files) do |files|
  walks += 1
  original.call(files)
end

same = ->(a, b) { a.names == b.names && a.wild == b.wild }

Dir.mktmpdir('foreign_definers_cache') do |dir|
  a = File.join(dir, 'a.rb')
  b = File.join(dir, 'b.rb')
  File.write(a, "class Foo\n  def bar; end\nend\n")
  File.write(b, "class NilClass\n  def extra; end\nend\nclass Baz\n  class_eval { }\nend\n")
  both = [a, b]
  one = [a]

  walks = 0
  answers = 4.times.flat_map { [FD.scan(both), FD.scan(one)] }
  check.call('alternating between two lists walks each list once', walks == 2)
  check.call('each answer equals a fresh walk of its list',
             answers.each_slice(2).all? { |x, y| same.call(x, original.call(both)) && same.call(y, original.call(one)) })
  check.call('the fixture: Foo#bar, NilClass#extra, Baz wild',
             answers[0].names['Foo'].include?('bar') && answers[0].names['NilClass'].include?('extra') &&
             answers[0].wild.include?('Baz') && !answers[1].names.key?('NilClass'))

  File.write(a, "class Foo\n  def barr; end\nend\n")
  walks = 0
  rewritten = FD.scan(both)
  check.call('a rewritten file is walked again and its new definition is seen',
             walks == 1 && rewritten.names['Foo'].include?('barr') && !rewritten.names['Foo'].include?('bar'))
  walks = 0
  check.call('the other list sees the rewrite too', FD.scan(one).names['Foo'].include?('barr') && walks == 1)

  File.delete(b)
  dropped = FD.scan(both)
  check.call('a deleted file drops out of the list', !dropped.names.key?('NilClass') && same.call(dropped, original.call([a])))

  File.write(b, "class NilClass\n  def extra; end\nend\n")
  owner_sets = [%w[NilClass Object], %w[Object], %w[Foo], %w[Baz Kernel], []]
  agree = owner_sets.product(%w[extra barr nope]).all? do |owners, name|
    FD.defines_any?(both, owners, name) == owners.any? { |owner| FD.defines?(both, owner, name) }
  end
  check.call('defines_any? answers defines? for any of the owners', agree)
  check.call('defines_any? finds NilClass#extra and not NilClass#nope',
             FD.defines_any?(both, %w[NilClass Object], 'extra') && !FD.defines_any?(both, %w[NilClass Object], 'nope'))

  broken = File.join(dir, 'broken.rb')
  File.write(broken, "class Foo\n  def (\n")
  walks = 0
  quiet = FD.defines_any?([broken], [], 'x') == false && walks.zero?
  raised = begin
    FD.defines_any?([broken], %w[Foo], 'x')
    false
  rescue RuntimeError => e
    e.message.include?('does not parse')
  end
  check.call('no owners scans nothing; an unparseable file raises when asked', quiet && raised)
end

FD.singleton_class.send(:remove_method, :scan_files)
FD.define_singleton_method(:scan_files, original)

tools = File.expand_path('../../tools/bc2cpp', __dir__)
world = File.read(File.join(tools, 'closed_world.rb'))[/def nil_foreign_definition_free\?.*?\n  end\n/m].to_s
frozen = File.read(File.join(tools, 'codegen_frozen_tables.rb'))
check.call('the closed world nil check and the frozen-table refusal ask through defines_any?',
           world.include?('ForeignDefiners.defines_any?(@ruby_paths, owners, name)') &&
           frozen.include?('ForeignDefiners.defines_any?(frozen_table_foreign_paths, owners, name)'))

# PRECISE_REOPENERS: each fixture is scanned alone; [label, source, expected wild, expected {name => owners}].
OWNER_CASES = [
  ['class_eval block: defs on the constant, a nested class still lexical',
   "class Outer\n  Numeric.class_eval do\n    def i; end\n    def self.k; end\n" \
   "    class Inner; def z; end; end\n  end\nend\n",
   [], { 'i' => %w[Numeric], 'k' => %w[Numeric.singleton], 'z' => %w[Outer::Inner] }],
  ['class_eval with an argument stays wild', "Numeric.class_eval(src)\n", %w[Numeric Numeric.singleton], {}],
  ['class_eval with a block argument stays wild', "Numeric.class_eval(&blk)\n", %w[Numeric Numeric.singleton], {}],
  ['instance_eval on a constant stays wild', "Numeric.instance_eval do\n  def j; end\nend\n",
   %w[Numeric Numeric.singleton], {}],
  ['a definition-free __send__(name) block defines nothing',
   "class Proc\n  def curry\n    __send__(type) do |*args|\n      args\n    end\n  end\nend\n", [],
   { 'curry' => %w[Proc] }],
  ['a __send__(name) block with a definition stays wild',
   "class Proc\n  def c\n    __send__(type) do\n      define_method(:x) {}\n    end\n  end\nend\n",
   %w[Proc Proc.singleton], {}],
  ['send with more than the name stays wild', "class Proc\n  def c; send(type, :x); end\nend\n",
   %w[Proc Proc.singleton], {}],
  ['send with a splat stays wild', "class Proc\n  def c; send(*args); end\nend\n", %w[Proc Proc.singleton], {}],
  ['a bare send(name) in a module may reach module_function',
   "module M\n  send(type)\n  def f; end\nend\n", [], { 'f' => %w[M M.singleton] }],
  ['each over a literal name list names what its definers spell',
   "class S\n  %i[a b].each do |v|\n    alias_method :\"s_\#{v}\", v if method_defined?(v)\n" \
   "    alias_method v, :\"o_\#{v}\"\n  end\nend\n",
   [], { 's_a' => %w[S], 's_b' => %w[S], 'a' => %w[S], 'b' => %w[S], 'o_a' => %w[S], 'o_b' => %w[S] }],
  ['each whose block rebinds the variable stays wild',
   "class S\n  %i[a].each do |v|\n    v = name\n    alias_method v, :x\n  end\nend\n", %w[S S.singleton], {}],
  ['each over a computed list stays wild', "class S\n  list.each do |v|\n    alias_method v, :x\n  end\nend\n",
   %w[S S.singleton], {}],
  ['each_with_index stays wild', "class S\n  %i[a].each_with_index do |v, i|\n    alias_method v, :x\n  end\nend\n",
   %w[S S.singleton], {}]
].freeze

Dir.mktmpdir('outside_ruby_owners') do |dir|
  OWNER_CASES.each_with_index do |(label, source, wild, names), index|
    path = File.join(dir, "case#{index}.rb")
    File.write(path, source)
    result = OutsideRubyOwners.scan([path])
    got = names.keys.to_h { |name| [name, result.names.fetch(name, Set.new).to_a.sort] }
    check.call(label, result.wild.to_a.sort == wild.sort && got == names && result.unknown.empty?)
  end
end

if failures.empty?
  puts 'bc2cpp foreign definers cache check: PASS'
else
  puts "bc2cpp foreign definers cache check: FAIL (#{failures.size})"
  exit 1
end
