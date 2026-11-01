#!/usr/bin/env ruby
# frozen_string_literal: true

# ENUM_STEP for Integer#times, #upto and #downto (tools/bc2cpp/codegen_enum_step.rb, docs/bc2cpp-enum-step.md): with the
# flag on, the saved body of each guarded loop under a Fiber is a Ruby driver that makes the block call itself, so a
# Fiber.yield in the block, or Enumerator#next over the loop, suspends through VM frames only. Flag at 0, the generated
# code is what it was: each loop's own saved bytecode.
#
#   generated code (needs a host mrbc)
#     - flag set: each of the three registers through bc2cpp_enum_step_save with its driver, and no longer saves its body;
#     - flag at 0: no driver text, and each keeps its own saved body.
#   behaviour (needs a full-core libmruby, see Bc2cppFixtureRuntime.full_or_build)
#     - the interpreted run (mruby's own loops) and the compiled run (the drivers, flag set) print the same over ordinary
#       iteration, empty and negative ranges, breaks, returns, raises, enumerators, a Fiber.yield in the block and a
#       blockless loop under a Fiber.
#
# Usage: MRBC=path/to/mrbc [BC2CPP_MRUBY_FULL=dir | BC2CPP_FULL_BUILD_DIR=dir] ruby scripts/bc2cpp/enum_step_integer_loops_check.rb

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
  class EnumStepIntegerProbe
    def first_of(n)
      n.times { |i| return i }
    end

    def first_upto(n)
      0.upto(n) { |i| return i }
    end

    def first_downto(n)
      n.downto(0) { |i| return i }
    end
  end
RUBY

# The drivers' registrations and the saved-body registrations, as the generated text spells them.
TIMES_SAVE = /bc2cpp_enum_step_save\(M, bc2cpp_owner_reg_Integer, false, "\\x74\\x69\\x6d\\x65\\x73", \d+, nullptr, nullptr, bc2cpp_integer_times_driver_src, "__bc2cpp_times_driver"\)/
UPTO_SAVE = /bc2cpp_enum_step_save\(M, bc2cpp_owner_reg_Integer, false, "\\x75\\x70\\x74\\x6f", \d+, nullptr, nullptr, bc2cpp_integer_upto_driver_src, "__bc2cpp_upto_driver"\)/
DOWNTO_SAVE = /bc2cpp_enum_step_save\(M, bc2cpp_owner_reg_Integer, false, "\\x64\\x6f\\x77\\x6e\\x74\\x6f", \d+, nullptr, nullptr, bc2cpp_integer_downto_driver_src, "__bc2cpp_downto_driver"\)/
PLAIN_TIMES = /bc2cpp_core_save_interpreted\(M, bc2cpp_owner_reg_Integer, false, "\\x74\\x69\\x6d\\x65\\x73", \d+\)/
PLAIN_UPTO = /bc2cpp_core_save_interpreted\(M, bc2cpp_owner_reg_Integer, false, "\\x75\\x70\\x74\\x6f", \d+\)/
PLAIN_DOWNTO = /bc2cpp_core_save_interpreted\(M, bc2cpp_owner_reg_Integer, false, "\\x64\\x6f\\x77\\x6e\\x74\\x6f", \d+\)/

def generate_with(flag, dir)
  saved = ENV['BC2CPP_ENUM_STEP']
  flag ? ENV['BC2CPP_ENUM_STEP'] = '1' : ENV['BC2CPP_ENUM_STEP'] = '0'
  Bc2cppFixtureRuntime.generate(PROBE, dir, core: true, only_owners: %w[Integer])
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

  puts "mode: #{$bc2cpp_compiled ? 'compiled' : 'interpreted'} drivers=#{Integer.private_instance_methods.include?(:__bc2cpp_times_driver)}"

  show('times') { 3.times.to_a }
  show('times zero') { 0.times.to_a }
  show('times negative') { (-2).times.to_a }
  show('times break') { 5.times { |i| break i * 10 if i == 2 } }
  show('times return') { 3.times { } }
  show('times raise') { 2.times { |i| raise TypeError, "t#{i}" } }
  show('times enumerator') { e = 2.times; [e.next, e.next, stop_of(e)] }
  show('times fiber') { f = Fiber.new { 2.times { |i| Fiber.yield i }; :done }; [f.resume, f.resume, f.resume] }
  show('upto') { 3.upto(6).to_a }
  show('upto empty') { 5.upto(2).to_a }
  show('upto break') { 1.upto(9) { |i| break i if i == 4 } }
  show('upto return') { 1.upto(2) { } }
  show('upto raise') { 1.upto(3) { |i| raise TypeError, "u#{i}" } }
  show('downto') { 3.downto(0).to_a }
  show('downto empty') { 0.downto(1).to_a }
  show('downto break') { 9.downto(0) { |i| break i if i == 7 } }
  show('downto return') { 2.downto(1) { } }
  show('downto fiber') { Fiber.new { 2.downto(0) { |i| Fiber.yield i }; :done }.then { |f| [f.resume, f.resume, f.resume, f.resume] } }
  show('blockless in fiber') { Fiber.new { 3.upto(4).to_a }.resume }
  puts 'end'
RUBY

# The expected lines, from Ruby's own semantics (MRI).
EXPECTED = {
  'times' => '[0, 1, 2]',
  'times zero' => '[]',
  'times negative' => '[]',
  'times break' => '20',
  'times return' => '3',
  'times raise' => 'raised TypeError: t0',
  'times enumerator' => '[0, 1, "StopIteration result=2"]',
  'times fiber' => '[0, 1, :done]',
  'upto' => '[3, 4, 5, 6]',
  'upto empty' => '[]',
  'upto break' => '4',
  'upto return' => '1',
  'upto raise' => 'raised TypeError: u1',
  'downto' => '[3, 2, 1, 0]',
  'downto empty' => '[]',
  'downto break' => '7',
  'downto return' => '2',
  'downto fiber' => '[2, 1, 0, :done]',
  'blockless in fiber' => '[3, 4]'
}.freeze

dir = Dir.mktmpdir('bc2cpp-enum-step-int')
at_exit { FileUtils.remove_entry(dir) }

puts '-- generated code'
on_dir = File.join(dir, 'on')
off_dir = File.join(dir, 'off')
FileUtils.mkdir_p([on_dir, off_dir])
on_code, on_err = generate_with(true, on_dir)
off_code, = generate_with(false, off_dir)
check.call('flag set: Integer#times registers through bc2cpp_enum_step_save with its driver', on_code.match?(TIMES_SAVE))
check.call('flag set: Integer#upto registers through bc2cpp_enum_step_save with its driver', on_code.match?(UPTO_SAVE))
check.call('flag set: Integer#downto registers through bc2cpp_enum_step_save with its driver', on_code.match?(DOWNTO_SAVE))
check.call('flag set: no loop saves its own body', !on_code.match?(PLAIN_TIMES) && !on_code.match?(PLAIN_UPTO) && !on_code.match?(PLAIN_DOWNTO))
check.call('flag at 0: no driver text is emitted', !off_code.include?('__bc2cpp_times_driver') && !off_code.include?('__bc2cpp_downto_driver'))
check.call('flag at 0: each loop keeps its own saved body', off_code.match?(PLAIN_TIMES) && off_code.match?(PLAIN_UPTO) && off_code.match?(PLAIN_DOWNTO))
check.call('flag set: the generated code has no #error', !on_code.include?('#error'))

build = Bc2cppFixtureRuntime.full_or_build
if build.nil?
  puts '  SKIP behavioural comparison: needs a full-core libmruby (BC2CPP_MRUBY_FULL, or rake, g++ and 3rd/mruby)'
else
  puts '-- fixtures on real mruby: interpreted and driver-based (compiled)'
  body = <<~CPP
    static int scenario(mrb_state* M) {
      std::fflush(stdout);
      // The registrations a gem's init makes, which save each loop's body (its driver, under ENUM_STEP) before the
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
  check.call('the compiled run registers the drivers on Integer', mode_line.call(compiled)&.end_with?('drivers=true'))
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
  puts 'bc2cpp enum step Integer loops check: PASS'
else
  puts "bc2cpp enum step Integer loops check: #{failures.size} failure(s)"
  exit 1
end
