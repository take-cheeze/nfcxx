#!/usr/bin/env ruby
# frozen_string_literal: true

# RESUMABLE_DUAL (codegen_method.rb): the direct-yield core iterators on the list take a resumable variant beside the fast body. Each
# runs inside a Fiber (the block yields) and plainly; interpreted and compiled runs print the same. native_fiber_check evals the table.
#
# Usage: MRBC=path/to/mrbc [BC2CPP_MRUBY_FULL=dir | BC2CPP_FULL_BUILD_DIR=dir] ruby scripts/bc2cpp/resumable_variants_check.rb

require_relative 'fixture_runtime'

suite = Bc2cppStepCheck.new('bc2cpp resumable variants check')

# array.c's sort (insertion sort up to 16 elements, heap sort above), transcribed so the comparison block sees the
# calls mruby's native sort makes. The interpreted run cannot give the expected output of a Fiber.yield in a
# comparison: the native sort is a C frame, and mruby-fiber raises FiberError there.
def reference_sort(ary)
  a = ary.dup
  n = a.size
  gt = ->(x, y) { yield(x, y) > 0 }
  if n <= 16
    (1...n).each do |i|
      key = a[i]
      j = i - 1
      while j >= 0 && gt.call(a[j], key)
        a[j + 1] = a[j]
        j -= 1
      end
      a[j + 1] = key
    end
  else
    heapify = lambda do |index, size|
      loop do
        max = index
        l = (2 * index) + 1
        r = l + 1
        max = l if l < size && gt.call(a[l], a[max])
        max = r if r < size && gt.call(a[r], a[max])
        break if max == index

        a[max], a[index] = a[index], a[max]
        index = max
      end
    end
    (n / 2 - 1).downto(0) { |i| heapify.call(i, n) }
    (n - 1).downto(1) do |i|
      a[0], a[i] = a[i], a[0]
      heapify.call(0, i)
    end
  end
  a
end

# The yields of a drained fiber whose comparison block yields its +arg+ argument, then the sorted result.
def reference_sort_line(label, ary, arg)
  log = []
  sorted = reference_sort(ary) do |x, y|
    log << (arg.zero? ? x : y)
    arg.zero? ? x <=> y : y <=> x
  end
  "fiber #{label}: #{(log + [sorted]).inspect}"
end

# [label, fiber expression, plain expression, optional expected "fiber" line (see reference_sort)]. The fiber expression yields every block argument; the plain one only returns it.
SCENARIOS = [
  ['Array#each', '[1, 2].each { |x| Fiber.yield x }', '[1, 2].each { |x| x }'],
  ['Array#delete_if', '[1, 2, 3].delete_if { |x| Fiber.yield x; x == 2 }', '[1, 2, 3].delete_if { |x| x == 2 }'],
  ['Array#each_index', '[1, 2].each_index { |x| Fiber.yield x }', '[1, 2].each_index { |x| x }'],
  ['Array#fetch', '[1, 2].fetch(0) { |i| Fiber.yield i; 7 }', '[1, 2].fetch(0) { |i| 7 }'],
  ['Array#fetch', '[1, 2].fetch(9) { |i| Fiber.yield i; 7 }', '[1, 2].fetch(9) { |i| 7 }'],
  ['Array#fetch', '[1, 2].fetch(9, 8)', '[1, 2].fetch(9, 8)'],
  ['Array#fetch', '[1, 2].fetch(-1)', '[1, 2].fetch(-1)'],
  ['Array#fetch', '[1, 2].fetch(9)', '[1, 2].fetch(9)'],
  ['Array#fetch', '[1, 2].fetch(9, 8) { |i| Fiber.yield i; 7 }', '[1, 2].fetch(9, 8) { |i| 7 }'],
  ['Hash#fetch', '{ a: 1 }.fetch(:a)', '{ a: 1 }.fetch(:a)'],
  ['Hash#fetch', '{ a: 1 }.fetch(:zz, 8)', '{ a: 1 }.fetch(:zz, 8)'],
  ['Hash#fetch', '{ a: 1 }.fetch(:zz)', '{ a: 1 }.fetch(:zz)'],
  ['Hash#fetch', '{ a: 1 }.fetch(:zz, 8) { |k| Fiber.yield k; 7 }', '{ a: 1 }.fetch(:zz, 8) { |k| 7 }'],
  ['String#upto', %q{'07'.upto('10', true) { |c| Fiber.yield c }}, %q{'07'.upto('10', true) { |c| c }}],
  ['String#upto', %q{'az'.upto('bc', false) { |c| Fiber.yield c }}, %q{'az'.upto('bc', false) { |c| c }}],
  ['Array#fetch', '[1].fetch(9) { |i| Fiber.yield i; break :stopped }', '[1].fetch(9) { |i| break :stopped }'],
  ['Array#fetch', '[1].fetch(9) { |i| Fiber.yield i; raise TypeError, "fetch" }', '[1].fetch(9) { |i| raise TypeError, "fetch" }'],
  ['Hash#fetch', '{}.fetch(:zz) { |k| Fiber.yield k; break :stopped }', '{}.fetch(:zz) { |k| break :stopped }'],
  ['Hash#fetch', '{}.fetch(:zz) { |k| Fiber.yield k; raise TypeError, "fetch" }', '{}.fetch(:zz) { |k| raise TypeError, "fetch" }'],
  ['Array#sort', '[3, 1, 2].sort { |a, b| Fiber.yield a; a <=> b }', '[3, 1, 2].sort { |a, b| a <=> b }',
   -> { reference_sort_line('Array#sort', [3, 1, 2], 0) }],
  ['Array#sort', '(1..20).to_a.reverse.sort { |a, b| Fiber.yield a; a <=> b }', '(1..20).to_a.reverse.sort { |a, b| a <=> b }',
   -> { reference_sort_line('Array#sort', (1..20).to_a.reverse, 0) }],
  ['Array#sort', '[3, 1, 2].sort! { |a, b| Fiber.yield b; b <=> a }', '[3, 1, 2].sort! { |a, b| b <=> a }',
   -> { reference_sort_line('Array#sort', [3, 1, 2], 1) }],
  ['Array#sort', '[2, 1].sort { |a, b| nil }', '[2, 1].sort { |a, b| nil }'],
  ['Array#find', '[1, 2].find { |x| Fiber.yield x; x == 2 }', '[1, 2].find { |x| x == 2 }'],
  ['Array#sort_by', '[2, 1].sort_by { |x| Fiber.yield x; x }', '[2, 1].sort_by { |x| x }'],
  ['Array#to_h', '[[1, 2], [3, 4]].to_h { |x| Fiber.yield x; [x[0], x[1]] }', '[[1, 2], [3, 4]].to_h { |x| [x[0], x[1]] }'],
  ['Array#uniq', '[1, 1, 2].uniq { |x| Fiber.yield x; x }', '[1, 1, 2].uniq { |x| x }'],
  ['Enumerable#collect', '(1..2).collect { |x| Fiber.yield x; x }', '(1..2).collect { |x| x }'],
  ['Enumerable#count', '(1..2).count { |x| Fiber.yield x; true }', '(1..2).count { |x| true }'],
  ['Enumerable#each_with_object', '(1..2).each_with_object([]) { |x, a| Fiber.yield x; a << x }', '(1..2).each_with_object([]) { |x, a| a << x }'],
  ['Enumerable#filter_map', '(1..2).filter_map { |x| Fiber.yield x; x }', '(1..2).filter_map { |x| x }'],
  ['Enumerable#find_all', '(1..2).find_all { |x| Fiber.yield x; true }', '(1..2).find_all { |x| true }'],
  ['Enumerable#flat_map', '(1..2).flat_map { |x| Fiber.yield x; [x] }', '(1..2).flat_map { |x| [x] }'],
  ['Enumerable#inject', '(1..2).inject(0) { |a, x| Fiber.yield x; a + x }', '(1..2).inject(0) { |a, x| a + x }'],
  ['Enumerable#max', '(1..2).max { |a, b| Fiber.yield a; 0 }', '(1..2).max { |a, b| 0 }'],
  ['Enumerable#min', '(1..2).min { |a, b| Fiber.yield a; 0 }', '(1..2).min { |a, b| 0 }'],
  ['Enumerable#reject', '(1..2).reject { |x| Fiber.yield x; false }', '(1..2).reject { |x| false }'],
  ['Enumerable#sort', '(1..2).sort { |a, b| Fiber.yield a; 0 }', '(1..2).sort { |a, b| 0 }',
   -> { "fiber Enumerable#sort: #{[1, [1, 2]].inspect}" }],
  ['Enumerable#sort_by', '(1..2).sort_by { |x| Fiber.yield x; x }', '(1..2).sort_by { |x| x }'],
  ['Enumerable#sum', '(1..2).sum { |x| Fiber.yield x; x }', '(1..2).sum { |x| x }'],
  ['Enumerable#to_h', '(1..2).to_h { |x| Fiber.yield x; [x, x] }', '(1..2).to_h { |x| [x, x] }'],
  ['Enumerable#uniq', '(1..2).uniq { |x| Fiber.yield x; x }', '(1..2).uniq { |x| x }'],
  ['Float#step', '1.0.step(2.0, 0.5) { |x| Fiber.yield x }', '1.0.step(2.0, 0.5) { |x| x }'],
  ['Hash#delete', 'h = { a: 1 }; h.delete(:zz) { |k| Fiber.yield k; 0 }', 'h = { a: 1 }; h.delete(:zz) { |k| 0 }'],
  ['Hash#delete_if', 'h = { a: 1, b: 2 }; h.delete_if { |k, v| Fiber.yield k; false }', 'h = { a: 1, b: 2 }; h.delete_if { |k, v| false }'],
  ['Hash#fetch', '{ a: 1 }.fetch(:zz) { |k| Fiber.yield k; 0 }', '{ a: 1 }.fetch(:zz) { |k| 0 }'],
  ['Hash#reject', '{ a: 1, b: 2 }.reject { |k, v| Fiber.yield k; false }', '{ a: 1, b: 2 }.reject { |k, v| false }'],
  ['Hash#select', '{ a: 1, b: 2 }.select { |k, v| Fiber.yield k; true }', '{ a: 1, b: 2 }.select { |k, v| true }'],
  ['Integer#downto', '2.downto(1) { |x| Fiber.yield x }', '2.downto(1) { |x| x }'],
  ['Integer#step', '1.step(3, 1) { |x| Fiber.yield x }', '1.step(3, 1) { |x| x }'],
  ['Integer#times', '2.times { |x| Fiber.yield x }', '2.times { |x| x }'],
  ['Integer#upto', '1.upto(2) { |x| Fiber.yield x }', '1.upto(2) { |x| x }'],
  ['String#each_char', %q{'ab'.each_char { |c| Fiber.yield c }}, %q{'ab'.each_char { |c| c }}],
  ['String#each_line', %q{"a\nb".each_line { |c| Fiber.yield c }}, %q{"a\nb".each_line { |c| c }}],
  ['String#upto', %q{'a'.upto('b') { |c| Fiber.yield c }}, %q{'a'.upto('b') { |c| c }}],
  ['Array#collect!', '[1, 2].collect! { |x| Fiber.yield x; x * 10 }', '[1, 2].collect! { |x| x * 10 }'],
  ['Array#reject!', '[1, 2, 3].reject! { |x| Fiber.yield x; x == 2 }', '[1, 2, 3].reject! { |x| x == 2 }'],
  ['Array#select!', '[1, 2, 3].select! { |x| Fiber.yield x; x != 2 }', '[1, 2, 3].select! { |x| x != 2 }'],
  ['Array#uniq!', '[1, 1, 2].uniq! { |x| Fiber.yield x; x }', '[1, 1, 2].uniq! { |x| x }'],
  ['Enumerable#all?', '(1..2).all? { |x| Fiber.yield x; true }', '(1..2).all? { |x| true }'],
  ['Enumerable#any?', '(1..2).any? { |x| Fiber.yield x; false }', '(1..2).any? { |x| false }'],
  ['Enumerable#detect', '(1..2).detect { |x| Fiber.yield x; x == 2 }', '(1..2).detect { |x| x == 2 }'],
  ['Enumerable#each_with_index', '(1..2).each_with_index { |x, i| Fiber.yield x }', '(1..2).each_with_index { |x, i| x }'],
  ['Enumerable#find_index', '(1..2).find_index { |x| Fiber.yield x; x == 2 }', '(1..2).find_index { |x| x == 2 }'],
  ['Enumerable#none?', '(1..2).none? { |x| Fiber.yield x; false }', '(1..2).none? { |x| false }'],
  ['Hash#each', 'h = { a: 1, b: 2 }; h.each { |k, v| Fiber.yield k }', 'h = { a: 1, b: 2 }; h.each { |k, v| k }'],
  ['Hash#each_key', '{ a: 1, b: 2 }.each_key { |k| Fiber.yield k }', '{ a: 1, b: 2 }.each_key { |k| k }'],
  ['Hash#each_value', '{ a: 1, b: 2 }.each_value { |v| Fiber.yield v }', '{ a: 1, b: 2 }.each_value { |v| v }'],
  ['Hash#merge!', 'h = { a: 1 }; h.merge!({ a: 2 }) { |k, o, n| Fiber.yield k; n }', 'h = { a: 1 }; h.merge!({ a: 2 }) { |k, o, n| n }'],
  ['Hash#reject!', 'h = { a: 1, b: 2 }; h.reject! { |k, v| Fiber.yield k; false }', 'h = { a: 1, b: 2 }; h.reject! { |k, v| false }'],
  ['Hash#select!', 'h = { a: 1, b: 2 }; h.select! { |k, v| Fiber.yield k; true }', 'h = { a: 1, b: 2 }; h.select! { |k, v| true }'],
  ['Range#each', '(1..2).each { |x| Fiber.yield x }', '(1..2).each { |x| x }'],
  ['Range#each', %q{('a'..'c').each { |x| Fiber.yield x }}, %q{('a'..'c').each { |x| x }}],
  ['Enumerable#each_slice', '(1..3).each_slice(2) { |a| Fiber.yield a }', '(1..3).each_slice(2) { |a| a }'],
  ['Enumerable#each_cons', '(1..3).each_cons(2) { |a| Fiber.yield a }', '(1..3).each_cons(2) { |a| a }'],
  ['Enumerable#group_by', '(1..3).group_by { |x| Fiber.yield x; x % 2 }', '(1..3).group_by { |x| x % 2 }'],
  ['Enumerable#partition', '(1..3).partition { |x| Fiber.yield x; x > 1 }', '(1..3).partition { |x| x > 1 }'],
  ['Enumerable#min_by', '(1..3).min_by { |x| Fiber.yield x; -x }', '(1..3).min_by { |x| -x }'],
  ['Enumerable#max_by', '(1..3).max_by { |x| Fiber.yield x; -x }', '(1..3).max_by { |x| -x }'],
  ['Enumerable#take_while', '(1..3).take_while { |x| Fiber.yield x; x < 3 }', '(1..3).take_while { |x| x < 3 }'],
  ['Enumerable#drop_while', '(1..3).drop_while { |x| Fiber.yield x; x < 2 }', '(1..3).drop_while { |x| x < 2 }'],
  ['Kernel#loop', 'n = 0; loop { Fiber.yield n; n += 1; break if n > 1 }', 'n = 0; loop { n += 1; break if n > 1 }'],
  ['Kernel#loop', 'n = 0; loop { Fiber.yield n; n += 1; raise StopIteration if n > 1 }', 'n = 0; loop { n += 1; raise StopIteration if n > 1 }'],
  ['Hash#fetch_values', '{ a: 1 }.fetch_values(:z) { |k| Fiber.yield k; 0 }', '{ a: 1 }.fetch_values(:z) { |k| 0 }'],
  # A block run from a C iterator cannot suspend: the error matches mruby-fiber's.
  ['Array#index', '[1, 2].index { |x| Fiber.yield x; x == 2 }', '[1, 2].index { |x| x == 2 }'],
  # An Enumerator driven inside a Fiber body: its own fiber nests in the body's.
  ['Enumerator#next', 'e = [1, 2].each; Fiber.yield e.next; e.next', 'e = [1, 2].each; e.next; e.next'],
  ['StringIO#each', 'require "stringio"; StringIO.new("a\\nb").each { |l| Fiber.yield l }', 'require "stringio"; StringIO.new("a\\nb").each { |l| l }']
].freeze

EXPECTED_LABELS = %w[
  Array#collect! Array#delete_if Array#each Array#each_index Array#fetch Array#find
  Array#reject! Array#select! Array#sort Enumerable#sort Hash#delete Hash#fetch
  Hash#each Integer#downto Integer#times Integer#upto
  String#each_char String#upto StringIO#each
  Range#max Range#min Enumerable#all? Enumerable#any? Enumerable#detect Enumerable#find_index Enumerable#none? Array#sort_by Array#to_h Array#uniq Array#uniq! Enumerable#collect Enumerable#count Enumerable#each_with_object Enumerable#filter_map Enumerable#find_all Enumerable#flat_map Enumerable#inject Enumerable#max Enumerable#min Enumerable#reject Enumerable#sort_by Enumerable#sum Enumerable#to_h Enumerable#uniq Enumerable#each_with_index Hash#delete_if Hash#reject Hash#select Hash#each_key Hash#each_value Hash#merge! Hash#reject! Hash#select! Range#each
  Enumerable#each_slice Enumerable#each_cons Enumerable#group_by Enumerable#partition Enumerable#min_by Enumerable#max_by Enumerable#take_while Enumerable#drop_while
  Kernel#loop Hash#fetch_values
].freeze

# One method per scenario builds the fiber whose body is the scenario, so every fiber body is compiled (a Fiber made by the
# driver's own, interpreted, source would run on mruby-fiber).
PROBE = <<~RUBY
  class VariantProbe
#{SCENARIOS.each_with_index.map { |(_, fiber, _), i| "    def fiber_#{i}\n      Fiber.new { #{fiber} }\n    end\n" }.join("\n")}
  end
RUBY

# Each scenario prints "fiber LABEL: [..]" (drained fiber) and "plain LABEL: ..." (the same call, no fiber).
DRIVER_BODY = SCENARIOS.each_with_index.map do |(label, _, plain), i|
  "show('fiber #{label}') { drain(VariantProbe.new.fiber_#{i}) }\nshow('plain #{label}') { #{plain} }"
end.join("\n")
DRIVER = "#{Bc2cppStepCheck::SHOW}#{Bc2cppStepCheck::DRAIN}#{DRIVER_BODY}\nputs 'end'\n"

OWNERS = %w[Array Enumerable Enumerator Hash Integer Float Kernel Range String StringIO VariantProbe].freeze
# BC2CPP_GUARD_FIBER_FREE=0 (guards: true) keeps every guard, so each listed method takes its variant in this probe, which is
# not the whole program: a method no probe Fiber reaches would otherwise lose its guard.
code = suite.generate(PROBE, OWNERS, guards: true)
variants = code.scan(/^(?:\[\[maybe_unused\]\] )?static mrb_value ([\w$]+)_rsm_impl\(/).flatten.uniq
# The default list (RESUMABLE_DUAL in codegen_method.rb): exactly these take a variant.
expected_names = EXPECTED_LABELS.map { |label| label.sub('#', '_').gsub('!', '$21').gsub('?', '$3f') }
puts "    missing variants: #{(expected_names - variants).sort.join(' ')}" unless (expected_names - variants).empty?
puts "    unexpected variants: #{(variants - expected_names).sort.join(' ')}" unless (variants - expected_names).empty?
suite.check("exactly the default list gets a variant (#{variants.size} of #{SCENARIOS.size} scenarios)",
            (expected_names - variants).empty? && (variants - expected_names).empty?)
%w[array_fetch hash_fetch string_upto].each do |method|
  suite.check("#{method} needs no per-method driver", !code.include?("bc2cpp_#{method}_driver_src"))
end

suite.behaviour(DRIVER, same: false, diff: false) do |interpreted, compiled|
  next unless interpreted && compiled

  # A scenario with an expected line is held to it, not to the interpreted run.
  SCENARIOS.each_with_index { |(_, _, _, expected), idx| interpreted[idx * 2] = expected.call if expected }
  differing = interpreted.zip(compiled).reject { |a, b| a == b }
  differing.first(12).each { |a, b| puts "    interpreted: #{a}\n    compiled:    #{b}" }
  suite.check("interpreted and compiled runs print the same over #{SCENARIOS.size * 2} scenarios", differing.empty?)
end
suite.finish
