#!/usr/bin/env ruby
# frozen_string_literal: true

require 'json'
require_relative '../../tools/bc2cpp/native_sigs'

iterations = Integer(ENV.fetch('ITERATIONS', '10'), 10)
abort 'ITERATIONS must be positive' unless iterations.positive?

# The old lookup supplies a reference without changing the production cache.
module UncachedNativeMarkers
  def own_table(node)
    text = node.comment&.string
    return nil unless text&.include?(NativeSigs::MARK_WORD)

    text[NativeSigs::MARK_LINE, 1]
  end
end
reference = NativeSigs.dup
reference.singleton_class.prepend(UncachedNativeMarkers)
parsed = NativeSigs.parse
tables = parsed.flat_map { |decl| NativeSigs.tables_in(decl) }.uniq
lines = File.readlines(NativeSigs::FILE)
expected = tables.map { |name| reference.source_text(parsed, lines, name) }
actual = tables.map { |name| NativeSigs.source_text(parsed, lines, name) }
raise 'cached markers changed rendered native tables' unless expected == actual

work = ->(reader) { iterations.times { tables.each { |name| reader.select_table(parsed, name) } } }
readers = { uncached: reference, cached: NativeSigs }
readers.each_value { |reader| work.call(reader) }
reports = readers.map do |name, reader|
  GC.start
  before = GC.stat
  started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
  work.call(reader)
  elapsed = Process.clock_gettime(Process::CLOCK_MONOTONIC) - started
  after = GC.stat
  { version: name, iterations: iterations, tables: tables.size, seconds: elapsed,
    allocated_objects: after[:total_allocated_objects] - before[:total_allocated_objects],
    gc_count: after[:count] - before[:count] }
end
puts JSON.pretty_generate(reports)
