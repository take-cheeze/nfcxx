#!/usr/bin/env ruby
# frozen_string_literal: true

# ENUM_STEP for String#upto (tools/bc2cpp/codegen_enum_step.rb, docs/bc2cpp-enum-step.md): with the flag on, the saved
# body of a guarded String#upto under a Fiber is a Ruby driver (STRING_UPTO_DRIVER) that makes the block call itself,
# so a Fiber.yield in the block, or Enumerator#next over the upto, suspends through VM frames only. Flag at 0, the
# generated code is what it was: String#upto's own saved bytecode.
#
#   generated code (needs a host mrbc)
#     - flag set: String#upto registers through bc2cpp_enum_step_save with the driver, and no longer saves its own body;
#     - flag at 0: no driver text, and String#upto keeps its own saved body.
#   behaviour (needs a full-core libmruby, see Bc2cppFixtureRuntime.full_or_build)
#     - the interpreted run (mruby's own String#upto, Fiber-based) and the compiled run (the driver, flag set) print the
#       same over the digit, single-character and succ branches, exclusive ends, breaks, raises, a TypeError, an
#       enumerator, a Fiber.yield in the block and a blockless upto under a Fiber.
#
# Usage: MRBC=path/to/mrbc [BC2CPP_MRUBY_FULL=dir | BC2CPP_FULL_BUILD_DIR=dir] ruby scripts/bc2cpp/enum_step_string_upto_check.rb

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
  class EnumStepUptoProbe
    def first_of(s)
      s.upto("c") { |x| return x }
    end
  end
RUBY

# The driver's registration and the saved-body registration for String#upto, as the generated text spells them.
STEP_SAVE = /bc2cpp_enum_step_save\(M, bc2cpp_owner_reg_String, false, "\\x75\\x70\\x74\\x6f", \d+, nullptr, nullptr, bc2cpp_upto_driver_src, "__bc2cpp_upto_driver"\)/
PLAIN_SAVE = /bc2cpp_core_save_interpreted\(M, bc2cpp_owner_reg_String, false, "\\x75\\x70\\x74\\x6f", \d+\)/

def generate_with(flag, dir)
  saved = ENV['BC2CPP_ENUM_STEP']
  flag ? ENV['BC2CPP_ENUM_STEP'] = '1' : ENV['BC2CPP_ENUM_STEP'] = '0'
  Bc2cppFixtureRuntime.generate(PROBE, dir, core: true, only_owners: %w[String])
ensure
  saved ? ENV['BC2CPP_ENUM_STEP'] = saved : ENV.delete('BC2CPP_ENUM_STEP')
end

# Each scenario is one labelled line. The expected values are Ruby's own (MRI and mruby agree on every one).
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
    "StopIteration result=#{s.result.inspect}"
  end

  puts "mode: #{$bc2cpp_compiled ? 'compiled' : 'interpreted'} driver=#{String.private_instance_methods.include?(:__bc2cpp_upto_driver)}"

  show('digits') { "7".upto("11").to_a }
  show('zero padded') { "07".upto("11").to_a }
  show('digits exclusive') { "1".upto("3", true).to_a }
  show('no digits to run') { "25".upto("5").to_a }
  show('single char') { "a".upto("e").to_a }
  show('single char exclusive') { "a".upto("e", true).to_a }
  show('succ loop') { "az".upto("bc").to_a }
  show('succ loop exclusive') { "az".upto("bc", true).to_a }
  show('break in block') { "a".upto("z") { |x| break x if x == "c" } }
  show('return value') { "a".upto("c") { } }
  show('raise in block') { "a".upto("c") { |x| raise TypeError, "t#{x}" } }
  show('type error') { "a".upto(1) { } }
  show('enumerator') do
    e = "a".upto("c")
    [e.next, e.next, e.next, stop_of(e)]
  end
  show('fiber yield in block') do
    fiber = Fiber.new { "a".upto("c") { |x| Fiber.yield x }; :done }
    [fiber.resume, fiber.resume, fiber.resume, fiber.resume]
  end
  show('blockless in fiber') { Fiber.new { "a".upto("b").to_a }.resume }
  puts 'end'
RUBY

# The expected lines, from Ruby's own semantics (MRI).
EXPECTED = {
  'digits' => '["7", "8", "9", "10", "11"]',
  'zero padded' => '["07", "08", "09", "10", "11"]',
  'digits exclusive' => '["1", "2"]',
  'no digits to run' => '[]',
  'single char' => '["a", "b", "c", "d", "e"]',
  'single char exclusive' => '["a", "b", "c", "d"]',
  'succ loop' => '["az", "ba", "bb", "bc"]',
  'succ loop exclusive' => '["az", "ba", "bb"]',
  'break in block' => '"c"',
  'return value' => '"a"',
  'raise in block' => 'raised TypeError: ta',
  'type error' => 'raised TypeError: no implicit conversion of Integer into String',
  'enumerator' => '["a", "b", "c", "StopIteration result=\"a\""]',
  'fiber yield in block' => '["a", "b", "c", :done]',
  'blockless in fiber' => '["a", "b"]'
}.freeze

dir = Dir.mktmpdir('bc2cpp-enum-step-upto')
at_exit { FileUtils.remove_entry(dir) }

puts '-- generated code'
on_dir = File.join(dir, 'on')
off_dir = File.join(dir, 'off')
FileUtils.mkdir_p([on_dir, off_dir])
on_code, on_err = generate_with(true, on_dir)
off_code, = generate_with(false, off_dir)
check.call('flag set: String#upto registers through bc2cpp_enum_step_save with the driver', on_code.match?(STEP_SAVE))
check.call('flag set: the driver source is emitted', on_code.include?('def __bc2cpp_upto_driver('))
check.call('flag set: String#upto no longer saves its own body', !on_code.match?(PLAIN_SAVE))
check.call('flag at 0: no driver text is emitted', !off_code.include?('__bc2cpp_upto_driver'))
check.call('flag at 0: String#upto keeps its own saved body', off_code.match?(PLAIN_SAVE))
check.call('flag set: the generated code has no #error', !on_code.include?('#error'))

build = Bc2cppFixtureRuntime.full_or_build
if build.nil?
  puts '  SKIP behavioural comparison: needs a full-core libmruby (BC2CPP_MRUBY_FULL, or rake, g++ and 3rd/mruby)'
else
  puts '-- fixtures on real mruby: Fiber-based (interpreted) and driver-based (compiled)'
  body = <<~CPP
    static int scenario(mrb_state* M) {
      std::fflush(stdout);
      // The registrations a gem's init makes, which save String#upto's body (the driver, under ENUM_STEP) before the
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
  check.call('the interpreted run has no driver', mode_line.call(interpreted)&.end_with?('driver=false'))
  check.call('the compiled run registers the driver on String', mode_line.call(compiled)&.end_with?('driver=true'))
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
  puts 'bc2cpp enum step String#upto check: PASS'
else
  puts "bc2cpp enum step String#upto check: #{failures.size} failure(s)"
  exit 1
end
