#!/usr/bin/env ruby
# frozen_string_literal: true

# ENUM_STEP by default for the guarded core methods without a hand-written form (tools/bc2cpp/codegen_enum_step.rb,
# EnumStep.default_form, docs/bc2cpp-enum-step.md): each such method's saved body under a Fiber is a driver generated from
# the def it was compiled from (EnumDriverGen), so a Fiber.yield in the block, or Enumerator#next over the method, suspends
# through VM frames only. Flag at 0, the generated code is what it was: each method's own saved bytecode.
#
#   generated code (needs a host mrbc)
#     - flag set: Enumerable#each_slice, Array#collect! and Integer#step register through bc2cpp_enum_step_save with their
#       generated drivers; Hash#< (no &block) keeps its saved bytecode, as the generator refuses it;
#     - flag at 0: no driver text is emitted, and each method keeps its own saved body.
#   behaviour (needs a full-core libmruby, see Bc2cppFixtureRuntime.full_or_build)
#     - the interpreted run (mruby's own methods) and the compiled run (the generated drivers, flag set) print the same over
#       ordinary calls, enumerators, breaks, raises, Enumerator#next and a Fiber.yield in the block, for Enumerable, Array,
#       Hash, String and Integer/Float methods. The expected lines are Ruby's own (MRI); results are arrays, since Hash#inspect
#       differs between MRI and mruby.
#
# Usage: MRBC=path/to/mrbc [BC2CPP_MRUBY_FULL=dir | BC2CPP_FULL_BUILD_DIR=dir] ruby scripts/bc2cpp/enum_step_default_drivers_check.rb

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

OWNERS = %w[Enumerable Array Hash String Integer Float Range Enumerator].freeze

# The generated-code registrations: a generated driver's saved name and its driver source, as the text spells them.
EACH_SLICE_SAVE = /bc2cpp_enum_step_save\(M, bc2cpp_owner_reg_Enumerable, false, "[^"]*", \d+, nullptr, nullptr, bc2cpp_enumerable_each_slice_driver_src, "__bc2cpp_each_slice_driver"\)/
COLLECT_B_SAVE = /bc2cpp_enum_step_save\(M, bc2cpp_owner_reg_Array, false, "[^"]*", \d+, nullptr, nullptr, bc2cpp_array_collect_b_driver_src, "__bc2cpp_collect_b_driver"\)/
INTEGER_STEP_SAVE = /bc2cpp_enum_step_save\(M, bc2cpp_owner_reg_Integer, false, "[^"]*", \d+, nullptr, nullptr, bc2cpp_integer_step_driver_src, "__bc2cpp_step_driver"\)/
# Hash#transform_values reads block_given?, which the generator rewrites as a test of its &block parameter.
TRANSFORM_SAVE = /bc2cpp_enum_step_save\(M, bc2cpp_owner_reg_Hash, false, "[^"]*", \d+, nullptr, nullptr, bc2cpp_hash_transform_values_driver_src, "__bc2cpp_transform_values_driver"\)/
# Hash#< has no &block, so the generator refuses it and it keeps its saved bytecode (\x3c is "<").
HASH_LT_PLAIN = /bc2cpp_core_save_interpreted\(M, bc2cpp_owner_reg_Hash, false, "\\x3c", \d+\)/
PLAIN_EACH_SLICE = /bc2cpp_core_save_interpreted\(M, bc2cpp_owner_reg_Enumerable, false, "\\x65\\x61\\x63\\x68\\x5f\\x73\\x6c\\x69\\x63\\x65", \d+\)/

PROBE = <<~'RUBY'
  class EnumStepDefaultProbe
    def first_slice(e)
      e.each_slice(2) { |s| return s }
    end
  end
RUBY

def generate_with(flag, dir)
  saved = ENV['BC2CPP_ENUM_STEP']
  flag ? ENV['BC2CPP_ENUM_STEP'] = '1' : ENV['BC2CPP_ENUM_STEP'] = '0'
  Bc2cppFixtureRuntime.generate(PROBE, dir, core: true, only_owners: OWNERS)
ensure
  saved ? ENV['BC2CPP_ENUM_STEP'] = saved : ENV.delete('BC2CPP_ENUM_STEP')
end

# Each scenario is one labelled line.
DRIVER = <<~'RUBY'
puts "mode: #{$bc2cpp_compiled ? 'compiled' : 'interpreted'} drivers=#{Enumerable.private_instance_methods.include?(:__bc2cpp_each_slice_driver)}"

  def show(label)
    puts "#{label}: #{yield.inspect}"
  rescue StandardError => e
    puts "#{label}: raised #{e.class}: #{e.message}"
  end

  def stop_of(e)
    e.next
    :no_stop
  rescue StopIteration => s
    "StopIteration result=#{s.result.inspect}"
  end

  show('each_slice') { acc = []; [1, 2, 3, 4, 5].each_slice(2) { |s| acc << s }; acc }
  show('each_slice enumerator') { [1, 2, 3, 4, 5].each_slice(2).to_a }
  show('each_slice break') { (1..9).each_slice(3) { |s| break s if s.first == 4 } }
  show('each_slice raise') { [1, 2].each_slice(1) { |s| raise TypeError, "s#{s[0]}" } }
  show('each_slice fiber') { f = Fiber.new { [1, 2, 3, 4].each_slice(2) { |s| Fiber.yield s.sum }; :done }; [f.resume, f.resume, f.resume] }
  show('each_cons') { (1..4).each_cons(2).to_a }
  show('each_with_index') { acc = []; %w[a b].each_with_index { |x, i| acc << [x, i] }; acc }
  show('each_with_index next') { e = [5, 6].each_with_index; [e.next, e.next] }
  show('inject block') { [1, 2, 3].inject { |a, b| a + b } }
  show('inject symbol') { [1, 2, 3].inject(:+) }
  show('group_by') { (1..6).group_by(&:odd?).to_a }
  show('find_all') { (1..6).find_all { |x| x.even? } }
  show('filter_map') { (1..6).filter_map { |x| x * 2 if x.odd? } }
  show('flat_map') { [1, 2].flat_map { |x| [x, x] } }
  show('partition') { (1..6).partition(&:even?) }
  show('sort_by') { %w[bb a ccc].sort_by(&:size) }
  show('min_by') { %w[bb a ccc].min_by(&:size) }
  show('each_index') { acc = []; %w[a b].each_index { |i| acc << i }; acc }
  show('reverse_each') { [1, 2, 3].reverse_each.to_a }
  show('combination') { [1, 2, 3].combination(2).to_a }
  show('array find') { [1, 2, 3].find { |x| x > 1 } }
  show('select!') { a = [1, 2, 3]; a.select! { |x| x.odd? }; a }
  show('select! nil') { a = [1, 3]; a.select! { |x| x.odd? }.inspect }
  show('delete_if') { a = [1, 2, 3, 4]; a.delete_if(&:even?); a }
  show('collect!') { a = [1, 2]; a.collect! { |x| x * 10 }; a }
  show('hash select') { { a: 1, b: 2 }.select { |k, v| v > 1 }.to_a }
  show('hash delete_if') { h = { a: 1, b: 2 }; h.delete_if { |k, v| v == 1 }; h.to_a }
  show('hash reject') { { a: 1, b: 2 }.reject { |k, v| v > 1 }.to_a }
  show('each_line') { "a\nb\n".each_line.to_a }
  show('each_line block') { acc = []; "x\ny".each_line { |l| acc << l }; acc }
  show('integer step') { acc = []; 1.step(7, 3) { |i| acc << i }; acc }
  show('integer step enumerator') { 1.step(7, 3).to_a }
  show('float step') { 1.0.step(2.0, 0.5).to_a }
  show('step break') { 1.step(9, 2) { |i| break i if i > 4 } }
  show('fiber yield in step') { f = Fiber.new { 1.step(5, 2) { |i| Fiber.yield i }; :done }; [f.resume, f.resume, f.resume, f.resume] }
  show("transform_values") { { a: 1, b: 2 }.transform_values { |v| v * 10 }.to_a }
  show("transform_values enumerator") { { a: 1 }.transform_values.to_a }
  show("transform_values fiber") { f = Fiber.new { { a: 1, b: 2 }.transform_values { |v| Fiber.yield v; v }; :done }; [f.resume, f.resume, f.resume] }
  show("transform_values! ") { h = { a: 1, b: 2 }; h.transform_values! { |v| v + 1 }; h.to_a }
  show("transform_values! enumerator") { { a: 1 }.transform_values!.to_a }
  puts 'end'
RUBY

# The expected lines, from Ruby's own semantics (MRI), with keys and values as arrays.
EXPECTED = {
  "each_slice" => '[[1, 2], [3, 4], [5]]',
  "each_slice enumerator" => '[[1, 2], [3, 4], [5]]',
  "each_slice break" => '[4, 5, 6]',
  "each_slice raise" => 'raised TypeError: s1',
  "each_slice fiber" => '[3, 7, :done]',
  "each_cons" => '[[1, 2], [2, 3], [3, 4]]',
  "each_with_index" => '[["a", 0], ["b", 1]]',
  "each_with_index next" => '[[5, 0], [6, 1]]',
  "inject block" => '6',
  "inject symbol" => '6',
  "group_by" => '[[true, [1, 3, 5]], [false, [2, 4, 6]]]',
  "find_all" => '[2, 4, 6]',
  "filter_map" => '[2, 6, 10]',
  "flat_map" => '[1, 1, 2, 2]',
  "partition" => '[[2, 4, 6], [1, 3, 5]]',
  "sort_by" => '["a", "bb", "ccc"]',
  "min_by" => '"a"',
  "each_index" => '[0, 1]',
  "reverse_each" => '[3, 2, 1]',
  "combination" => '[[1, 2], [1, 3], [2, 3]]',
  "array find" => '2',
  "select!" => '[1, 3]',
  "select! nil" => '"nil"',
  "delete_if" => '[1, 3]',
  "collect!" => '[10, 20]',
  "hash select" => '[[:b, 2]]',
  "hash delete_if" => '[[:b, 2]]',
  "hash reject" => '[[:a, 1]]',
  "each_line" => '["a\n", "b\n"]',
  "each_line block" => '["x\n", "y"]',
  "integer step" => '[1, 4, 7]',
  "integer step enumerator" => '[1, 4, 7]',
  "float step" => '[1.0, 1.5, 2.0]',
  "step break" => '5',
  "fiber yield in step" => '[1, 3, 5, :done]',
  "transform_values" => '[[:a, 10], [:b, 20]]',
  "transform_values enumerator" => '[1]',
  "transform_values fiber" => '[1, 2, :done]',
  "transform_values! " => '[[:a, 2], [:b, 3]]',
  "transform_values! enumerator" => '[1]'
}.freeze

dir = Dir.mktmpdir('bc2cpp-enum-step-default')
at_exit { FileUtils.remove_entry(dir) }

puts '-- generated code'
on_dir = File.join(dir, 'on')
off_dir = File.join(dir, 'off')
FileUtils.mkdir_p([on_dir, off_dir])
on_code, on_err = generate_with(true, on_dir)
off_code, = generate_with(false, off_dir)
check.call('flag set: Enumerable#each_slice registers through bc2cpp_enum_step_save with its generated driver', on_code.match?(EACH_SLICE_SAVE))
check.call('flag set: Array#collect! registers through bc2cpp_enum_step_save with its generated driver', on_code.match?(COLLECT_B_SAVE))
check.call('flag set: Integer#step registers through bc2cpp_enum_step_save with its generated driver', on_code.match?(INTEGER_STEP_SAVE))
check.call('flag set: Enumerable#each_slice no longer saves its own body', !on_code.match?(PLAIN_EACH_SLICE))
check.call('flag set: Hash#< (refused by the generator) keeps its saved bytecode', on_code.match?(HASH_LT_PLAIN))
check.call('flag set: Hash#transform_values, which reads block_given?, registers with its generated driver', on_code.match?(TRANSFORM_SAVE))
check.call('flag set: the generated code has no #error', !on_code.include?('#error'))
check.call('flag at 0: no generated driver text is emitted', !off_code.include?('__bc2cpp_each_slice_driver') && !off_code.include?('__bc2cpp_collect_b_driver'))
check.call('flag at 0: Enumerable#each_slice keeps its own saved body', off_code.match?(PLAIN_EACH_SLICE))

build = Bc2cppFixtureRuntime.full_or_build
if build.nil?
  puts '  SKIP behavioural comparison: needs a full-core libmruby (BC2CPP_MRUBY_FULL, or rake, g++ and 3rd/mruby)'
else
  puts '-- fixtures on real mruby: interpreted and generated drivers (compiled)'
  body = <<~CPP
    static int scenario(mrb_state* M) {
      std::fflush(stdout);
      // The registrations a gem's init makes, which save each method's body (its generated driver, under ENUM_STEP) before
      // the compiled entry replaces it. run() would register the entries plainly, leaving no saved body to fall back to.
      mrb_gv_set(M, mrb_intern_lit(M, "$bc2cpp_compiled"), mrb_bool_value(compiled));
      if (compiled) bc2cpp_register_owner_methods(M);
      const char* src = R"ENUMSTEP(#{DRIVER})ENUMSTEP";
      mrb_load_string(M, src);
      std::fflush(stdout);
      if (M->exc) { mrb_print_error(M); M->exc = nullptr; return 1; }
      return 0;
    }
  CPP
  built, output = Bc2cppFixtureRuntime.run(on_dir, on_err, [], body, build: build, full: true)
  check.call('the fixtures build and run', built)
  sections = Bc2cppFixtureRuntime.sections(output)
  interpreted = sections['interpreted']
  compiled = sections['compiled']
  same = ->(lines) { lines&.reject { |line| line.start_with?('mode: ') } }
  check.call('both runs reach the end', interpreted&.last == 'end' && compiled&.last == 'end')
  check.call('the interpreted run has no generated drivers', interpreted&.find { |l| l.start_with?('mode: ') }&.end_with?('drivers=false'))
  check.call('the compiled run registers the generated drivers on Enumerable',
             compiled&.find { |l| l.start_with?('mode: ') }&.end_with?('drivers=true'))
  check.call('interpreted and compiled runs print the same',
             !interpreted.nil? && !compiled.nil? && same.call(interpreted) == same.call(compiled))
  if interpreted && compiled
    same.call(interpreted).zip(same.call(compiled)).reject { |a, b| a == b }.first(10)
                          .each { |a, b| puts "    interpreted: #{a}\n    compiled:    #{b}" }
    values = interpreted.filter_map { |line| line.split(': ', 2) if line.include?(': ') }.to_h
    EXPECTED.each do |label, expected|
      ok = values[label] == expected
      puts "    #{label}: expected #{expected}, got #{values[label]}" unless ok
      check.call("#{label} (Ruby's own result): #{expected}", ok)
    end
  end
  puts output.lines.last(30).join unless built && interpreted && compiled
end

if failures.empty?
  puts 'bc2cpp enum step default drivers check: PASS'
else
  puts "bc2cpp enum step default drivers check: #{failures.size} failure(s)"
  exit 1
end
