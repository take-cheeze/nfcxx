#!/usr/bin/env ruby
# frozen_string_literal: true

# RESUMABLE_DUAL (tools/bc2cpp/codegen_method.rb): the direct-yield core iterators on the list take their resumable
# variant beside the fast body. Inside a Fiber the guard runs the variant, so a Fiber.yield in the block suspends through
# VM frames; outside one the fast body runs. This fixture runs each listed method both ways, and the methods that are
# not on the list (the ones that stay on their drivers) both ways too.
#
#   generated code (needs a host mrbc)
#     - the probe reaches every listed method from a Fiber body, so each one is guarded and gets its variant;
#   behaviour (needs a full-core libmruby, see Bc2cppFixtureRuntime.full_or_build)
#     - each method is run inside a Fiber (the block yields, and the fiber is drained) and plainly (the block returns);
#       the interpreted run and the compiled run print the same line for every scenario.
#
# Usage: MRBC=path/to/mrbc [BC2CPP_MRUBY_FULL=dir | BC2CPP_FULL_BUILD_DIR=dir] ruby scripts/bc2cpp/resumable_variants_check.rb

require 'tmpdir'
require_relative 'fixture_runtime'

# The fixture is its own closed world: the repository signatures name classes it does not define.
ENV['BC2CPP_SIG_DIRS'] = ''

failures = []
check = lambda do |what, condition|
  puts "  #{condition ? 'ok  ' : 'FAIL'} #{what}"
  failures << what unless condition
end

unless Bc2cppFixtureRuntime.mrbc && system(Bc2cppFixtureRuntime.mrbc, '--version', out: File::NULL, err: File::NULL)
  puts '  SKIP: no host mrbc (set MRBC); the generated-code and behavioural checks need it'
  exit 0
end

# [label, fiber expression, plain expression]. The fiber expression yields every block argument; the plain one only returns it.
SCENARIOS = [
  ['Array#each', '[1, 2].each { |x| Fiber.yield x }', '[1, 2].each { |x| x }'],
  ['Array#delete_if', '[1, 2, 3].delete_if { |x| Fiber.yield x; x == 2 }', '[1, 2, 3].delete_if { |x| x == 2 }'],
  ['Array#each_index', '[1, 2].each_index { |x| Fiber.yield x }', '[1, 2].each_index { |x| x }'],
  ['Array#fetch', '[1, 2].fetch(0) { |i| Fiber.yield i; 7 }', '[1, 2].fetch(0) { |i| 7 }'],
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
  ['Enumerable#sort', '(1..2).sort { |a, b| Fiber.yield a; 0 }', '(1..2).sort { |a, b| 0 }'],
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
  ['StringIO#each', 'require "stringio"; StringIO.new("a\\nb").each { |l| Fiber.yield l }', 'require "stringio"; StringIO.new("a\\nb").each { |l| l }']
].freeze

EXPECTED_LABELS = %w[
  Array#collect! Array#delete_if Array#each Array#each_index
  Array#reject! Array#select! Enumerable#sort Hash#delete
  Hash#each Integer#downto Integer#times Integer#upto
  Range#each String#each_char StringIO#each
].freeze

# The closed-world probe: every listed method is called from a Fiber body, so each is guarded and gets its variant.
PROBE = <<~RUBY
  class ProbeAll
    def run
      Fiber.new do
        r = []
#{SCENARIOS.map { |_, fiber, _| "        r << (#{fiber})" }.join("\n")}
        r
      end
    end
  end
  ProbeAll.new.run.resume
RUBY

# Each scenario runs as a line of output: "fiber LABEL: [..]" (drained fiber) and "plain LABEL: ..." (the same call, no fiber).
DRIVER = <<~'RUBY'
  def show(label)
    puts "#{label}: #{yield.inspect}"
  rescue StandardError => e
    puts "#{label}: raised #{e.class}: #{e.message}"
  end

  def drain(f)
    out = []
    while f.alive?
      out << f.resume
    end
    out
  end
RUBY
DRIVER_BODY = SCENARIOS.map do |label, fiber, plain|
  "show('fiber #{label}') { drain(Fiber.new { #{fiber} }) }\nshow('plain #{label}') { #{plain} }"
end.join("\n")
DRIVER_FULL = DRIVER + DRIVER_BODY + "\nputs 'end'\n"

OWNERS = %w[Array Enumerable Hash Integer Float Range String StringIO].freeze

baseline_dir = Dir.mktmpdir('bc2cpp-resumable-variants')
at_exit { FileUtils.remove_entry(baseline_dir) }
puts '-- generated code'
# BC2CPP_GUARD_FIBER_FREE=0 keeps every guard, so each listed method takes its variant in this probe (the probe is not
# the whole program: a method no probe Fiber reaches would otherwise lose its guard).
saved_guard = ENV['BC2CPP_GUARD_FIBER_FREE']
ENV['BC2CPP_GUARD_FIBER_FREE'] = '0'
code, baseline_err = begin
  Bc2cppFixtureRuntime.generate(PROBE, baseline_dir, core: true, only_owners: OWNERS)
ensure
  saved_guard ? ENV['BC2CPP_GUARD_FIBER_FREE'] = saved_guard : ENV.delete('BC2CPP_GUARD_FIBER_FREE')
end
File.write(ENV['BC2CPP_VARIANTS_DUMP'], code) if ENV['BC2CPP_VARIANTS_DUMP']
variants = code.scan(/^(?:\[\[maybe_unused\]\] )?static mrb_value ([\w$]+)_rsm_impl\(/).flatten.uniq
# The default list (RESUMABLE_DUAL in tools/bc2cpp/codegen_method.rb): exactly these take a variant.
EXPECTED = EXPECTED_LABELS
expected_names = EXPECTED.map { |label| label.sub('#', '_').gsub('!', '$21').gsub('?', '$3f') }
check.call("exactly the default list gets a variant (#{variants.size} of #{SCENARIOS.size} scenarios)", (expected_names - variants).empty? && (variants - expected_names).empty?)
check.call('no #error in the generated code', !code.include?('#error'))

if ENV['CC_GENERATED_ONLY'] == '1'
  puts '  SKIP behavioural comparison: CC_GENERATED_ONLY'
else
  build = Bc2cppFixtureRuntime.full_or_build
  if build.nil?
    puts '  SKIP behavioural comparison: needs a full-core libmruby (BC2CPP_MRUBY_FULL, or rake, g++ and 3rd/mruby)'
  else
    puts '-- fixtures on real mruby, interpreted and compiled'
    body = <<~CPP
      static int scenario(mrb_state* M) {
        std::fflush(stdout);
        const char* src = R"RAC(#{DRIVER_FULL})RAC";
        mrb_load_string(M, src);
        std::fflush(stdout);
        if (M->exc) { mrb_print_error(M); M->exc = nullptr; return 1; }
        return 0;
      }
    CPP
    built, output = Bc2cppFixtureRuntime.run(baseline_dir, baseline_err, OWNERS, body, build: build, full: true)
    check.call('the fixtures build and run', built)
    sections = Bc2cppFixtureRuntime.sections(output)
    interpreted = sections['interpreted']
    compiled = sections['compiled']
    check.call('both runs reach the end', interpreted&.last == 'end' && compiled&.last == 'end')
    if interpreted && compiled
      mismatched = interpreted.zip(compiled).reject { |a, b| a == b }
      mismatched.first(12).each { |a, b| puts "    interpreted: #{a}\n    compiled:    #{b}" }
      check.call("interpreted and compiled runs print the same over #{SCENARIOS.size * 2} scenarios", mismatched.empty?)
    end
    puts output.lines.last(30).join unless built && interpreted && compiled
  end
end

if failures.empty?
  puts 'bc2cpp resumable variants check: PASS'
else
  warn "bc2cpp resumable variants check: #{failures.size} failure(s)"
  exit 1
end
