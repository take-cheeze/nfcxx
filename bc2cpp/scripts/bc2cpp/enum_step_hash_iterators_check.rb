#!/usr/bin/env ruby
# frozen_string_literal: true

# ENUM_STEP for Hash#each, #each_key and #each_value (tools/bc2cpp/codegen_enum_step.rb, docs/bc2cpp-enum-step.md): with the
# flag on, the saved body of each under a Fiber is a Ruby driver that makes the block call itself, so a Fiber.yield in
# the block, or Enumerator#next over the iterator, suspends through VM frames only. Flag at 0, the generated code is what
# it was: each iterator's own saved bytecode. Hash#each_pair is an alias copy of each and keeps its own body.
#
#   generated code (needs a host mrbc)
#     - flag set: each of the three registers through bc2cpp_enum_step_save with its driver, and no longer saves its body;
#     - flag at 0: no driver text, and each keeps its own saved body.
#   behaviour (needs a full-core libmruby, see Bc2cppFixtureRuntime.full_or_build)
#     - the interpreted run (mruby's own iterators) and the compiled run (the drivers, flag set) print the same over
#       ordinary iteration, empty hashes, breaks, enumerators, a Fiber.yield in the block, a blockless iterator under a
#       Fiber, and each_pair. Results are compared as arrays of keys and values, since Hash#inspect differs between MRI
#       and mruby.
#
# Usage: MRBC=path/to/mrbc [BC2CPP_MRUBY_FULL=dir | BC2CPP_FULL_BUILD_DIR=dir] ruby scripts/bc2cpp/enum_step_hash_iterators_check.rb

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

PROBE = <<~'RUBY'
  class EnumStepHashProbe
    def first_of(h)
      h.each { |k, v| return k }
    end

    def first_key(h)
      h.each_key { |k| return k }
    end

    def first_value(h)
      h.each_value { |v| return v }
    end
  end
RUBY

# The drivers' registrations and the saved-body registrations, as the generated text spells them.
EACH_SAVE = /bc2cpp_enum_step_save\(M, bc2cpp_owner_reg_Hash, false, "\\x65\\x61\\x63\\x68", \d+, nullptr, nullptr, bc2cpp_hash_each_driver_src, "__bc2cpp_each_driver"\)/
EACH_KEY_SAVE = /bc2cpp_enum_step_save\(M, bc2cpp_owner_reg_Hash, false, "\\x65\\x61\\x63\\x68\\x5f\\x6b\\x65\\x79", \d+, nullptr, nullptr, bc2cpp_hash_each_key_driver_src, "__bc2cpp_each_key_driver"\)/
EACH_VALUE_SAVE = /bc2cpp_enum_step_save\(M, bc2cpp_owner_reg_Hash, false, "\\x65\\x61\\x63\\x68\\x5f\\x76\\x61\\x6c\\x75\\x65", \d+, nullptr, nullptr, bc2cpp_hash_each_value_driver_src, "__bc2cpp_each_value_driver"\)/
PLAIN_EACH = /bc2cpp_core_save_interpreted\(M, bc2cpp_owner_reg_Hash, false, "\\x65\\x61\\x63\\x68", \d+\)/
PLAIN_EACH_KEY = /bc2cpp_core_save_interpreted\(M, bc2cpp_owner_reg_Hash, false, "\\x65\\x61\\x63\\x68\\x5f\\x6b\\x65\\x79", \d+\)/
PLAIN_EACH_VALUE = /bc2cpp_core_save_interpreted\(M, bc2cpp_owner_reg_Hash, false, "\\x65\\x61\\x63\\x68\\x5f\\x76\\x61\\x6c\\x75\\x65", \d+\)/

def generate_with(flag, dir)
  saved = ENV['BC2CPP_ENUM_STEP']
  flag ? ENV['BC2CPP_ENUM_STEP'] = '1' : ENV['BC2CPP_ENUM_STEP'] = '0'
  Bc2cppFixtureRuntime.generate(PROBE, dir, core: true, only_owners: %w[Hash])
ensure
  saved ? ENV['BC2CPP_ENUM_STEP'] = saved : ENV.delete('BC2CPP_ENUM_STEP')
end

# Each scenario is one labelled line. The values are arrays of keys and values, so inspect output is the same in both VMs.
DRIVER = <<~'RUBY'
  def show(label)
    puts "#{label}: #{yield.inspect}"
  rescue StandardError => e
    puts "#{label}: raised #{e.class}: #{e.message}"
  end

  def stop_of(e)
    e.next
    :no_stop
  rescue StopIteration => s
    "StopIteration result=#{s.result.class}"
  end

  puts "mode: #{$bc2cpp_compiled ? 'compiled' : 'interpreted'} drivers=#{Hash.private_instance_methods.include?(:__bc2cpp_each_driver)}"

  h = { a: 1, b: 2 }
  show('each pairs') { acc = []; h.each { |k, v| acc << [k, v] }; acc }
  show('each enumerator') { h.each.to_a }
  show('each empty') { {}.each.to_a }
  show('each break') { { a: 1, b: 2, c: 3 }.each { |k, v| break k if v == 2 } }
  show('each returns self') { h.each { }.equal?(h) }
  show('each_key') { h.each_key.to_a }
  show('each_key block') { acc = []; h.each_key { |k| acc << k }; acc }
  show('each_value') { h.each_value.to_a }
  show('each_value block') { acc = []; h.each_value { |v| acc << v }; acc }
  show('each_pair') { acc = []; h.each_pair { |k, v| acc << v }; acc }
  show('raise in block') { h.each { |k, v| raise TypeError, "h#{k}" } }
  show('enumerator next') { e = h.each; [e.next, e.next, stop_of(e)] }
  show('fiber yield in block') do
    fiber = Fiber.new { h.each { |k, v| Fiber.yield k }; :done }
    [fiber.resume, fiber.resume, fiber.resume]
  end
  show('blockless in fiber') { Fiber.new { h.each_key.to_a }.resume }
  puts 'end'
RUBY

# The expected lines, from Ruby's own semantics (MRI), with keys and values as arrays.
EXPECTED = {
  'each pairs' => '[[:a, 1], [:b, 2]]',
  'each enumerator' => '[[:a, 1], [:b, 2]]',
  'each empty' => '[]',
  'each break' => ':b',
  'each returns self' => 'true',
  'each_key' => '[:a, :b]',
  'each_key block' => '[:a, :b]',
  'each_value' => '[1, 2]',
  'each_value block' => '[1, 2]',
  'each_pair' => '[1, 2]',
  'raise in block' => 'raised TypeError: ha',
  'enumerator next' => '[[:a, 1], [:b, 2], "StopIteration result=Hash"]',
  'fiber yield in block' => '[:a, :b, :done]',
  'blockless in fiber' => '[:a, :b]'
}.freeze

dir = Dir.mktmpdir('bc2cpp-enum-step-hash')
at_exit { FileUtils.remove_entry(dir) }

puts '-- generated code'
on_dir = File.join(dir, 'on')
off_dir = File.join(dir, 'off')
FileUtils.mkdir_p([on_dir, off_dir])
on_code, on_err = generate_with(true, on_dir)
off_code, = generate_with(false, off_dir)
check.call('flag set: Hash#each registers through bc2cpp_enum_step_save with its driver', on_code.match?(EACH_SAVE))
check.call('flag set: Hash#each_key registers through bc2cpp_enum_step_save with its driver', on_code.match?(EACH_KEY_SAVE))
check.call('flag set: Hash#each_value registers through bc2cpp_enum_step_save with its driver', on_code.match?(EACH_VALUE_SAVE))
check.call('flag set: no iterator saves its own body', !on_code.match?(PLAIN_EACH) && !on_code.match?(PLAIN_EACH_KEY) && !on_code.match?(PLAIN_EACH_VALUE))
check.call('flag at 0: no driver text is emitted', !off_code.include?('__bc2cpp_each_key_driver'))
check.call('flag at 0: each iterator keeps its own saved body', off_code.match?(PLAIN_EACH) && off_code.match?(PLAIN_EACH_KEY) && off_code.match?(PLAIN_EACH_VALUE))
check.call('flag set: the generated code has no #error', !on_code.include?('#error'))

build = Bc2cppFixtureRuntime.full_or_build
if build.nil?
  puts '  SKIP behavioural comparison: needs a full-core libmruby (BC2CPP_MRUBY_FULL, or rake, g++ and 3rd/mruby)'
else
  puts '-- fixtures on real mruby: interpreted and driver-based (compiled)'
  body = <<~CPP
    static int scenario(mrb_state* M) {
      std::fflush(stdout);
      // The registrations a gem's init makes, which save each iterator's body (its driver, under ENUM_STEP) before the
      // compiled entry replaces it. run() would register the entries plainly, leaving no saved body to fall back to.
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
  mode_line = ->(lines) { lines&.find { |line| line.start_with?('mode: ') } }
  same = ->(lines) { lines&.reject { |line| line.start_with?('mode: ') } }
  check.call('both runs reach the end', interpreted&.last == 'end' && compiled&.last == 'end')
  check.call('the interpreted run has no drivers', mode_line.call(interpreted)&.end_with?('drivers=false'))
  check.call('the compiled run registers the drivers on Hash', mode_line.call(compiled)&.end_with?('drivers=true'))
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
  puts 'bc2cpp enum step Hash iterators check: PASS'
else
  puts "bc2cpp enum step Hash iterators check: #{failures.size} failure(s)"
  exit 1
end
