#!/usr/bin/env ruby
# frozen_string_literal: true

# Check RubyParseCache (tools/bc2cpp/ruby_parse_cache.rb): the per-process parse memo of the foreign Ruby
# name scans. A hit must return the tree of exactly the bytes asked for, the tree must be the one an uncached
# Prism.parse gives (for the real foreign mrblib files and for random byte strings in both encodings), the
# consumers must return what they return without the cache, and a parse must happen once per text. Run by
# the `ruby-checks` job; the real-file half skips without 3rd/mruby.

require 'tmpdir'
require 'fileutils'
require 'set'
require_relative '../../tools/bc2cpp/ruby_parse_cache'
require_relative '../../tools/bc2cpp/foreign_definers'
require_relative '../../tools/bc2cpp/native_names'
require_relative '../../tools/bc2cpp/closed_world'

failures = []
check = lambda do |what, condition|
  puts "  #{condition ? 'ok  ' : 'FAIL'} #{what}"
  failures << what unless condition
end

ROOT = File.expand_path('../..', __dir__)

# Every node, array and string of the tree in a stable order, so two parses compare by structure.
def signature(result)
  rows = []
  stack = [result.value]
  until stack.empty?
    node = stack.shift
    next unless node.is_a?(Prism::Node)

    loc = node.location
    rows << [node.class.name, loc.start_offset, loc.end_offset,
             node.respond_to?(:unescaped) ? node.unescaped : nil,
             node.respond_to?(:unescaped) ? node.unescaped.encoding.name : nil,
             node.respond_to?(:name) ? node.name : nil]
    stack.concat(node.compact_child_nodes)
  end
  [rows, result.errors.map { |e| [e.message, e.location.start_offset] }, result.warnings.size,
   result.value.inspect.gsub(/0x\h+/, '')]
end

puts '-- Symbol dispatch in foreign method-name visitors'
source = <<~'RUBY_SOURCE'
  class ForeignSymbols
    def known; end
    attr :plain
    attr_reader :read
    attr_writer :write
    attr_accessor :both
    alias_method :renamed, :known
    define_method("dynamic") { 1 }
    alias copied known
  end
RUBY_SOURCE
tree = Prism.parse(source).value
names = ForeignDefNames.new
tree.accept(names)
check.call('all installer spellings still collect String method names',
           names.names == %w[known plain plain= read read= write write= both both= renamed dynamic copied].to_set)
owners = HiddenRubyOwnerScan.new
tree.accept(owners)
check.call('owner scans retain String names and setter spellings',
           owners.owners['known'] == Set['ForeignSymbols'] &&
           owners.unowned == %w[plain read write write= both both= renamed known dynamic copied].to_set && !owners.global)
%w[send __send__ public_send].each do |send_name|
  [':define_method', '"define_method"'].each do |literal|
    walker = HiddenRubyOwnerScan.new
    Prism.parse("#{send_name}(#{literal}, :hidden) { 1 }").value.accept(walker)
    check.call("#{send_name} recognizes reflective definer #{literal}", walker.global)
  end
end
forwarder = HiddenRubyOwnerScan.new
Prism.parse('def include(*mods); Object.include(*mods); end; include KnownMixin').value.accept(forwarder)
check.call('mixin forwarding still recognizes the Symbol definition name',
           !forwarder.global && forwarder.mixins == Set['KnownMixin'])
computed = HiddenRubyOwnerScan.new
Prism.parse('class KnownOwner; define_method(computed_name) { 1 }; end').value.accept(computed)
check.call('computed instance definers stay scoped to their owner', !computed.global && computed.wild == Set['KnownOwner'])
singleton = HiddenRubyOwnerScan.new
Prism.parse('class KnownOwner; define_singleton_method(computed_name) { 1 }; end').value.accept(singleton)
check.call('computed singleton definers still refuse globally', singleton.global)

puts '-- the same tree from every read of a file'
foreign = Dir["#{ROOT}/3rd/mruby/mrblib/**/*.rb"] + Dir["#{ROOT}/3rd/mruby/mrbgems/*/mrblib/**/*.rb"] +
          Dir["#{ROOT}/3rd/mruby-marshal/mrblib/**/*.rb"] + Dir["#{ROOT}/3rd/mruby-onig-regexp/mrblib/**/*.rb"] +
          Dir["#{ROOT}/3rd/mruby-stringio/mrblib/**/*.rb"]
if foreign.empty?
  puts '  skip real foreign mrblib (3rd/mruby not checked out)'
else
  same = foreign.sort.all? do |path|
    expected = signature(Prism.parse_file(path))
    signature(Prism.parse(File.binread(path), filepath: path)) == expected &&
      signature(Prism.parse(File.read(path, encoding: 'UTF-8'), filepath: path)) == expected
  end
  check.call("#{foreign.size} foreign files: parse_file, binary and UTF-8 reads give one tree", same)
end

puts '-- random texts parse the same in either encoding'
rng = Random.new(20_261_012)
pieces = ['def ', 'x', ' = ', '1', ':sym', '"s#{x}"', "'q'", ' ', "\n", '; ', 'alias ', 'class ', 'end', '# c', "\xFF".b,
          "\xC3".b, '(', ')', '[', ']', ' do |a| ', 'x.y', '__END__', '&.', '=>', "é".b, '%w[a b]', '<<~E', "E\n"]
fuzz_same = (1..300).all? do
  body = Array.new(rng.rand(1..30)) { pieces[rng.rand(pieces.size)].b }.join.b
  text = body.dup.force_encoding('UTF-8')
  signature(Prism.parse(text)) == signature(Prism.parse(text.b))
end
check.call('300 random texts (invalid UTF-8 included): UTF-8 and binary parse to one tree', fuzz_same)

puts '-- the cache returns what it was asked for'
calls = 0
Prism.singleton_class.prepend(Module.new do
  define_method(:parse) do |*args, **opts|
    calls += 1
    super(*args, **opts)
  end
end)

Dir.mktmpdir do |tmp|
  one = File.join(tmp, 'one.rb')
  two = File.join(tmp, 'two.rb')
  File.write(one, "class A\n  def f; end\nend\n")
  File.write(two, "class B\n  alias g f\nend\n")
  RubyParseCache.clear

  calls = 0
  first = RubyParseCache.parse_file(one)
  check.call('the first read parses once', calls == 1)
  check.call('a second read of the same bytes is the same tree and parses nothing',
             RubyParseCache.parse_file(one).equal?(first) && calls == 1)
  check.call('the same bytes as UTF-8 text also hit', RubyParseCache.parse(File.read(one, encoding: 'UTF-8'), one).equal?(first) && calls == 1)

  File.write(one, "class A\n  def g; end\nend\n")
  rewritten = RubyParseCache.parse_file(one)
  check.call('a rewritten file is parsed again', calls == 2)
  reference = signature(Prism.parse(File.binread(one), filepath: one)) # uncached, so counted: reset below
  check.call('the rewritten tree is the tree of the new bytes', signature(rewritten) == reference)
  calls = 2
  check.call('a read of the same bytes hits (no parse)', RubyParseCache.parse_file(one).equal?(rewritten) && calls == 2)

  other = RubyParseCache.parse_file(two)
  check.call('another path is a separate entry', calls == 3 && !other.equal?(rewritten))
  check.call('the other path keeps its own tree', RubyParseCache.parse_file(two).equal?(other) && calls == 3)

  check.call('a parse that gives errors keeps them', RubyParseCache.parse("def (\n", 'broken.rb').errors.any?)
end

puts '-- sharing leaves the caller and the tree usable'
Dir.mktmpdir do |tmp|
  path = File.join(tmp, 'shared.rb')
  File.write(path, "def f(a)\n  a.to_s\nend\n")
  RubyParseCache.clear
  src = File.read(path, encoding: 'UTF-8')
  tree = RubyParseCache.parse(src, path)
  check.call('the caller source text is not frozen by sharing', !src.frozen?)
  check.call('a shared tree still answers Node#location', tree.value.location.start_offset.zero?)
  check.call('the second reader gets the same tree, which it can walk',
             RubyParseCache.parse_file(path).equal?(tree) && tree.value.statements.body.size == 1)
end

puts '-- consumers return what they return without the cache'
if foreign.empty?
  puts '  skip consumer comparison (no real foreign files)'
else
  # The uncached reference: the same walk over a fresh parse per file.
  collector = ForeignDefiners::Collector.new
  foreign.sort.each { |path| collector.visit(Prism.parse_file(path).value) }
  RubyParseCache.clear
  cached = ForeignDefiners.scan_files(foreign.sort)
  check.call('ForeignDefiners.scan_files names match an uncached walk',
             cached.names.transform_values(&:to_a) == collector.names.transform_values(&:to_a) && cached.wild == collector.wild)
  check.call('foreign_method_names over the files matches the per-file calls',
             foreign_method_names(foreign.sort) == foreign.sort.each_with_object(Set.new) { |p, s| s.merge(foreign_method_names([p])) })
end

puts '-- one parse per text in a scan'
if foreign.empty?
  puts '  skip parse count (no real foreign files)'
else
  # Measure parser reuse without a disk-cached scan bypassing the parser entirely.
  ScanCache.bypass do
    RubyParseCache.clear
    calls = 0
    foreign.sort.each { |path| 3.times { foreign_method_names([path]) } }
    check.call("#{foreign.size} files scanned three times each parse #{foreign.size} times", calls == foreign.size)
    calls = 0
    ForeignDefiners.scan(foreign.sort)
    check.call('ForeignDefiners.scan of the same files parses nothing more', calls.zero?)
  end
end

puts '-- closed-world queries share each file scan across method names'
Dir.mktmpdir do |tmp|
  one = File.join(tmp, 'one.rb')
  two = File.join(tmp, 'two.rb')
  File.write(one, "class A; def first; end; attr_accessor :shared; end\n")
  File.write(two, "class B; def second; end; alias shared second; end\n")
  paths = [two, one, two]
  expected = %w[first second shared shared= absent].to_h do |name|
    [name, paths.select { |path| foreign_method_names([path]).include?(name) }]
  end
  world_class = Class.new(ClosedWorld) do
    attr_reader :scans

    def initialize(paths)
      @ruby_paths = paths
      @scans = []
    end

    def foreign_method_names(paths)
      @scans.concat(paths)
      super
    end
  end
  world = world_class.new(paths)
  expected.each do |name, defining|
    check.call("definer paths for #{name} retain order and duplicates",
               world.outside_ruby_definer_paths(name) == defining)
    check.call("return paths for #{name} agree with definer paths",
               world.outside_ruby_paths_defining(name) == defining)
  end
  check.call('both query families scan each distinct path once', world.scans == [two, one])
  File.write(one, "class A; def replacement; end; end\n")
  fresh_world = world_class.new(paths)
  check.call('a new world scans current file contents', fresh_world.outside_ruby_definer_paths('replacement') == [one])
  check.call('a new world does not retain old definitions', fresh_world.outside_ruby_definer_paths('first').empty?)
end

if failures.empty?
  puts 'ruby_parse_cache_check: all checks passed'
else
  puts "ruby_parse_cache_check: #{failures.size} failed"
  exit 1
end
