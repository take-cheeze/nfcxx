#!/usr/bin/env ruby
# frozen_string_literal: true

# FOREIGN_DEFINERS_PER_LIST (docs/adr/0471): ForeignDefiners.scan keeps one entry per list of files, keyed and
# checked by the files' stat key as before, and defines_any? asks about several owners from one scan. Host only,
# well under a second:
#   - callers alternating between two file lists walk each list once, not once per switch;
#   - a rewritten file is walked again and its new definitions are seen; a deleted file drops out;
#   - every answer equals a fresh scan_files of the list;
#   - defines_any? answers what defines? answers for any of the owners, and with no owners scans nothing (a foreign
#     file that does not parse still raises only when asked);
#   - the closed world's nil check and the frozen-table refusal ask through defines_any?.
#
# Usage: ruby scripts/bc2cpp/foreign_definers_cache_check.rb

require 'set'
require 'tmpdir'
require_relative '../../tools/bc2cpp/foreign_definers'

failures = []
check = lambda do |what, condition|
  puts "  #{condition ? 'ok  ' : 'FAIL'} #{what}"
  failures << what unless condition
end

FD = ForeignDefiners

walks = 0
original = FD.method(:scan_files)
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

FD.define_singleton_method(:scan_files, original)

tools = File.expand_path('../../tools/bc2cpp', __dir__)
world = File.read(File.join(tools, 'closed_world.rb'))[/def nil_foreign_definition_free\?.*?\n  end\n/m].to_s
frozen = File.read(File.join(tools, 'codegen_frozen_tables.rb'))
check.call('the closed world nil check and the frozen-table refusal ask through defines_any?',
           world.include?('ForeignDefiners.defines_any?(@ruby_paths, owners, name)') &&
           frozen.include?('ForeignDefiners.defines_any?(frozen_table_foreign_paths, owners, name)'))

if failures.empty?
  puts 'bc2cpp foreign definers cache check: PASS'
else
  puts "bc2cpp foreign definers cache check: FAIL (#{failures.size})"
  exit 1
end
