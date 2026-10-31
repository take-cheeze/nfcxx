#!/usr/bin/env ruby
# frozen_string_literal: true

# ENUM_STEP for Range#each (tools/bc2cpp/codegen_enum_step.rb, docs/bc2cpp-enum-step.md): with BC2CPP_ENUM_STEP=1 the saved
# body of a compiled Range#each under a Fiber is a shared driver that calls a compiled step per element, so
# Enumerator#next over an Integer range suspends through VM frames only. The other cases (a String, Float or bignum bound,
# an inclusive end at MRB_INT_MAX) are stepped too, by scripts/bc2cpp/enum_step_range_generic_check.rb. Unset, the generated code is
# what it was: Range#each's own saved bytecode.
#
#   generated code (needs a host mrbc)
#     - flag set: Range#each registers through bc2cpp_enum_step_save with the Range step and open, and no longer saves
#       its own body; Array#each keeps its step (the per-owner form);
#     - flag unset: no step text, and Range#each keeps its own saved body.
#   behaviour (needs a full-core libmruby, see Bc2cppFixtureRuntime.full_or_build)
#     - the interpreted run (mruby's own Range#each, Fiber-based through mruby-enumerator) and the compiled run (the step
#       form, flag set) print the same over Integer ranges (ascending, exclusive, empty, reversed, endless, past
#       MRB_INT_MAX), a String and a Float range, StopIteration with its result, peek, rewind, feed, break, a raising block
#       under a Fiber and in the root, a blockless each under a Fiber, and a Range subclass.
#
# Usage: MRBC=path/to/mrbc [BC2CPP_MRUBY_FULL=dir | BC2CPP_FULL_BUILD_DIR=dir] ruby scripts/bc2cpp/enum_step_range_check.rb

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

# Both owners generate, so the generated-code checks also see Array#each keep its step under the per-owner form.
PROBE = <<~'RUBY'
  class EnumStepRangeProbe
    def first_of(r)
      r.each { |x| return x }
    end
  end
  class EnumStepArrayProbe
    def first_of(a)
      a.each { |x| return x }
    end
  end
RUBY

# The step's registration and the saved-body registration for Range#each, as the generated text spells them.
STEP_SAVE = /bc2cpp_enum_step_save\(M, bc2cpp_owner_reg_Range, false, "\\x65\\x61\\x63\\x68", \d+, bc2cpp_range_each_step, bc2cpp_range_each_open, bc2cpp_range_each_driver_src\)/
PLAIN_SAVE = /bc2cpp_core_save_interpreted\(M, bc2cpp_owner_reg_Range, false, "\\x65\\x61\\x63\\x68", \d+\)/
ARRAY_STEP_SAVE = /bc2cpp_enum_step_save\(M, bc2cpp_owner_reg_Array, false, "\\x65\\x61\\x63\\x68", \d+, bc2cpp_each_step, nullptr, bc2cpp_each_driver_src\)/

def generate_with(flag, dir)
  saved = ENV['BC2CPP_ENUM_STEP']
  flag ? ENV['BC2CPP_ENUM_STEP'] = '1' : ENV.delete('BC2CPP_ENUM_STEP')
  Bc2cppFixtureRuntime.generate(PROBE, dir, core: true, only_owners: %w[Array Range])
ensure
  saved ? ENV['BC2CPP_ENUM_STEP'] = saved : ENV.delete('BC2CPP_ENUM_STEP')
end

# Each scenario is one labelled line. The expected values are Ruby's own where MRI and mruby agree (see EXPECTED).
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

  puts "mode: #{$bc2cpp_compiled ? 'compiled' : 'interpreted'} step=#{Range.private_instance_methods.include?(:__bc2cpp_each_step)}"

  show('ordinary next') { e = (1..3).each; [e.next, e.next, e.next] }
  show('ordinary end') { e = (1..3).each; 3.times { e.next }; stop_of(e) }
  show('exclusive') { e = (1...3).each; [e.next, e.next, stop_of(e)] }
  show('empty exclusive') { stop_of((1...1).each) }
  show('reversed') { stop_of((3..1).each) }
  show('loop result') { eb = (1..2).each; loop { eb.next } }
  show('endless take') { e = (1..).each; [e.next, e.next, e.next] }
  show('endless past max') { e = (9223372036854775806..).each; [e.next, e.next, e.next] }
  show('inclusive at max') { e = (9223372036854775806..9223372036854775807).each; [e.next, e.next, stop_of(e)] }
  show('string range') { e = ('a'..'c').each; [e.next, e.next, e.next, stop_of(e)] }
  show('float end') { e = (1..2.5).each; [e.next, e.next, stop_of(e)] }
  show('peek') { e = (5..6).each; [e.peek, e.peek, e.next, e.peek, e.next, stop_of(e)] }
  show('rewind') do
    eh = (1..2).each
    first = eh.next
    eh.next
    eh.rewind
    [first, eh.next]
  end
  show('feed once') { ek = (1..2).each; ek.next; ek.feed(:x); ek.next }
  show('feed twice') { ek = (1..2).each; ek.feed(:y); ek.feed(:z) }
  show('break in root') { (1..5).each { |x| break x * 10 if x == 2 } }
  show('break in fiber') { Fiber.new { (1..5).each { |x| break x * 10 if x == 2 } }.resume }
  show('raise in fiber block') do
    fiber = Fiber.new do
      begin
        (1..3).each { |x| Fiber.yield x; raise ArgumentError, "boom #{x}" if x == 1 }
        :done
      rescue ArgumentError => ex
        "rescued #{ex.message}"
      end
    end
    [fiber.resume, fiber.resume]
  end
  show('raise in root block') { (1..2).each { |x| raise TypeError, "t#{x}" } }
  show('blockless each in fiber') { Fiber.new { (1..2).each }.resume.to_a }

  class EnumStepRangeSub < Range
    def end
      super + 1
    end
  end
  show('subclass end') { e = EnumStepRangeSub.new(1, 2).each; [e.next, e.next, e.next] }

  puts 'end'
RUBY

# The expected lines, from Ruby's own semantics, except where mruby's own body differs from MRI (both are mruby's own
# results; the step must match them, and the fallback keeps them):
#   - 'string range': a String range runs String#upto, which returns its receiver, so mruby's Range#each returns "a";
#     MRI returns the range;
#   - 'subclass end': mruby's body dispatches `end` (the override adds one) where MRI reads the bounds, so MRI yields 1, 2.
EXPECTED = {
  'ordinary next' => '[1, 2, 3]',
  'ordinary end' => '"StopIteration result=1..3"',
  'exclusive' => '[1, 2, "StopIteration result=1...3"]',
  'empty exclusive' => '"StopIteration result=1...1"',
  'reversed' => '"StopIteration result=3..1"',
  'loop result' => '1..2',
  'endless take' => '[1, 2, 3]',
  'endless past max' => '[9223372036854775806, 9223372036854775807, 9223372036854775808]',
  'inclusive at max' => '[9223372036854775806, 9223372036854775807, "StopIteration result=9223372036854775806..9223372036854775807"]',
  'string range' => '["a", "b", "c", "StopIteration result=\"a\""]',
  'float end' => '[1, 2, "StopIteration result=1..2.5"]',
  'peek' => '[5, 5, 5, 6, 6, "StopIteration result=5..6"]',
  'rewind' => '[1, 1]',
  'feed once' => '2',
  'feed twice' => 'raised TypeError: feed value already set',
  'break in root' => '20',
  'break in fiber' => '20',
  'raise in fiber block' => '[1, "rescued boom 1"]',
  'raise in root block' => 'raised TypeError: t1',
  'blockless each in fiber' => '[1, 2]',
  'subclass end' => '[1, 2, 3]'
}.freeze

dir = Dir.mktmpdir('bc2cpp-enum-step-range')
at_exit { FileUtils.remove_entry(dir) }

puts '-- generated code'
on_dir = File.join(dir, 'on')
off_dir = File.join(dir, 'off')
FileUtils.mkdir_p([on_dir, off_dir])
on_code, on_err = generate_with(true, on_dir)
off_code, = generate_with(false, off_dir)
check.call('flag set: Range#each registers through bc2cpp_enum_step_save with the Range step and open', on_code.match?(STEP_SAVE))
check.call('flag set: the Range step and open are emitted',
           on_code.include?('static mrb_value bc2cpp_range_each_step(') && on_code.include?('static mrb_value bc2cpp_range_each_open('))
check.call('flag set: Range#each no longer saves its own body', !on_code.match?(PLAIN_SAVE))
check.call('flag set: Array#each keeps its step under the per-owner form', on_code.match?(ARRAY_STEP_SAVE))
check.call('flag set: the generated code has no #error', !on_code.include?('#error'))
check.call('flag unset: no step text is emitted',
           !off_code.include?('bc2cpp_enum_step') && !off_code.include?('bc2cpp_range_each_step') && !off_code.include?('bc2cpp_each_step'))
check.call('flag unset: Range#each keeps its own saved body', off_code.match?(PLAIN_SAVE))

build = Bc2cppFixtureRuntime.full_or_build
if build.nil?
  puts '  SKIP behavioural comparison: needs a full-core libmruby (BC2CPP_MRUBY_FULL, or rake, g++ and 3rd/mruby)'
else
  puts '-- fixtures on real mruby: Fiber-based (interpreted) and step-based (compiled)'
  body = <<~CPP
    static int scenario(mrb_state* M) {
      std::fflush(stdout);
      // The registrations a gem's init makes, which save each owner's #each (the driver, under ENUM_STEP) before the
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
  # Owners are empty: the registrations are the body's (above), so run() registers nothing itself.
  built, output = Bc2cppFixtureRuntime.run(on_dir, on_err, [], body, build: build, full: true)
  check.call('the fixtures build and run', built)
  sections = Bc2cppFixtureRuntime.sections(output)
  interpreted = sections['interpreted']
  compiled = sections['compiled']
  mode_line = ->(lines) { lines&.find { |line| line.start_with?('mode: ') } }
  same = ->(lines) { lines&.reject { |line| line.start_with?('mode: ') } }
  check.call('both runs reach the end', interpreted&.last == 'end' && compiled&.last == 'end')
  check.call('the interpreted run is interpreted without the step', mode_line.call(interpreted)&.end_with?('step=false'))
  check.call('the compiled run registers the step on Range', mode_line.call(compiled)&.end_with?('step=true'))
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
  puts 'bc2cpp enum step range check: PASS'
else
  warn "bc2cpp enum step range check: #{failures.size} failure(s)"
  exit 1
end
