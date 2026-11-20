#!/usr/bin/env ruby
# frozen_string_literal: true

# Guarded cleanliness answers may be reused only at the empty probe stack and
# with exactly the same unconditional answers. These checks exercise the real
# probe implementation with small synthetic method compilers, without mrbc.
require 'set'
require_relative '../../tools/bc2cpp/codegen_emit'

def probe_fixture(handlers)
  counts = Hash.new(0)
  generator = CodeGen.allocate
  generator.instance_variable_set(:@clean_cache, {})
  generator.instance_variable_set(:@probing, Set.new)
  generator.instance_variable_set(:@guard_cycles, 0)
  generator.define_singleton_method(:resumable_method?) { |_| false }
  generator.define_singleton_method(:entry_specialize_enabled?) { false }
  generator.define_singleton_method(:compile_method) do |label|
    counts[label] += 1
    handlers.fetch(label).call(self)
  end
  [generator, counts]
end

guarded = lambda do |generator|
  generator.instance_variable_set(:@guard_cycles, generator.instance_variable_get(:@guard_cycles) + 1)
  { code: 'clean' }
end
saved = ENV['BC2CPP_PROBE_ROOT_CACHE']
begin
  ENV.delete('BC2CPP_PROBE_ROOT_CACHE')
  generator, counts = probe_fixture(root: guarded)
  3.times { raise 'lost root result' unless generator.compiles_clean?(:root) }
  raise 'recompiled the same guarded root' unless counts[:root] == 1
  raise 'a reused guarded answer did not propagate its guard' unless generator.instance_variable_get(:@guard_cycles) == 3
  raise 'a guarded answer leaked into the unconditional cache' unless generator.instance_variable_get(:@clean_cache).empty?

  # Equal-size changes, deletion and clearing must all invalidate root answers.
  facts = generator.instance_variable_get(:@clean_cache)
  [-> { facts[:known] = false }, -> { facts[:known] = true }, -> { facts.delete(:known) },
   -> { facts[:another] = true }, -> { facts.clear }].each_with_index do |change, index|
    change.call
    2.times { generator.compiles_clean?(:root) }
    raise 'reused an answer after facts changed' unless counts[:root] == index + 2
  end
  generator.forget_root_probe_answers
  generator.compiles_clean?(:root)
  raise 'retained an explicitly forgotten answer' unless counts[:root] == 7

  handlers = {
    root: lambda do |gen|
      guarded.call(gen)
      { code: gen.instance_variable_get(:@probing).include?(:middle) ? '#error nested context' : 'clean' }
    end,
    middle: ->(gen) { { code: gen.compiles_clean?(:root) ? 'clean' : '#error nested root' } }
  }
  generator, counts = probe_fixture(handlers)
  raise 'outer root should compile' unless generator.compiles_clean?(:root)
  raise 'used the empty-stack answer in a nested probe' if generator.compiles_clean?(:middle)
  raise 'did not actually compile in the nested context' unless counts[:root] == 2

  generator, counts = probe_fixture(root: lambda do |gen|
    guarded.call(gen)
    gen.instance_variable_get(:@clean_cache)[:discovered] = true
    { code: 'clean' }
  end)
  3.times { generator.compiles_clean?(:root) }
  raise 'retained the result of a probe that changed facts' unless counts[:root] == 2

  generator, counts = probe_fixture(root: ->(_) { { code: 'clean' } })
  3.times { generator.compiles_clean?(:root) }
  raise 'lost unconditional memoization' unless counts[:root] == 1

  generator, counts = probe_fixture(root: guarded)
  generator.compiles_clean?(:root)
  generator.instance_variable_set(:@probing, Set.new(0...CodeGen::PROBE_DEPTH_LIMIT))
  raise 'reused a root answer past the depth limit' if generator.compiles_clean?(:root)
  raise 'compiled past the depth limit' unless counts[:root] == 1

  ENV['BC2CPP_PROBE_ROOT_CACHE'] = '0'
  generator, counts = probe_fixture(root: guarded)
  3.times { generator.compiles_clean?(:root) }
  raise 'ignored the cache-off control' unless counts[:root] == 3
ensure
  saved.nil? ? ENV.delete('BC2CPP_PROBE_ROOT_CACHE') : ENV['BC2CPP_PROBE_ROOT_CACHE'] = saved
end

puts 'probe root cache: contexts, fact changes, guards and invalidation PASS'
