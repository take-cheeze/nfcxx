#!/usr/bin/env ruby
# frozen_string_literal: true

# ENUM_STEP (tools/bc2cpp/codegen_enum_step.rb, docs/bc2cpp-enum-step.md): with BC2CPP_ENUM_STEP=1 the saved body of a
# compiled Array#each under a Fiber is a shared driver that calls a compiled step per element, so Enumerator#next over
# an Array suspends through VM frames only. Unset, the generated code is what it was: Array#each's own saved bytecode.
#
#   generated code (needs a host mrbc)
#     - flag set: Array#each registers through bc2cpp_enum_step_save and no longer saves its own body;
#     - flag unset: no step text, and Array#each keeps its own saved body.
#   behaviour (needs a full-core libmruby, see Bc2cppFixtureRuntime.full_or_build)
#     - the interpreted run (mruby's own Array#each, Fiber-based through mruby-enumerator) and the compiled run (the
#       step form, flag set) print the same over ordinary iteration, appends and deletes during iteration, StopIteration
#       with its result, peek, rewind, feed, a raising block, a blockless each under a Fiber, and a subclass of Array.
#
# Usage: MRBC=path/to/mrbc [BC2CPP_MRUBY_FULL=dir | BC2CPP_FULL_BUILD_DIR=dir] ruby scripts/bc2cpp/enum_step_array_check.rb

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
  class EnumStepProbe
    def first_of(a)
      a.each { |x| return x }
    end
  end
RUBY

# The step's registration and the saved-body registration for Array#each, as the generated text spells them.
STEP_SAVE = /bc2cpp_enum_step_save\(M, bc2cpp_owner_reg_Array, false, "\\x65\\x61\\x63\\x68", \d+, bc2cpp_each_step, nullptr, bc2cpp_each_driver_src\)/
PLAIN_SAVE = /bc2cpp_core_save_interpreted\(M, bc2cpp_owner_reg_Array, false, "\\x65\\x61\\x63\\x68", \d+\)/

def generate_with(flag, dir)
  saved = ENV['BC2CPP_ENUM_STEP']
  flag ? ENV['BC2CPP_ENUM_STEP'] = '1' : ENV['BC2CPP_ENUM_STEP'] = '0'
  Bc2cppFixtureRuntime.generate(PROBE, dir, core: true, only_owners: %w[Array])
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

  puts "mode: #{$bc2cpp_compiled ? 'compiled' : 'interpreted'} step=#{Array.private_instance_methods.include?(:__bc2cpp_each_step)}"

  a = [1, 2, 3]
  e = a.each
  show('ordinary next') { [e.next, e.next, e.next] }
  show('ordinary end') { stop_of(e) }

  b = [7, 8]
  eb = b.each
  show('loop result') { loop { eb.next } }

  c = [1, 2]
  ec = c.each
  show('append during') do
    got = [ec.next]
    c << 3
    got << ec.next << ec.next
    got << stop_of(ec)
  end

  d = [1, 2, 3, 4]
  ed = d.each
  show('delete middle during') do
    got = [ed.next]
    d.delete_at(1)
    got << ed.next << ed.next
    got << stop_of(ed)
  end

  f = [1, 2, 3]
  ef = f.each
  show('delete last during') do
    got = [ef.next]
    f.pop
    got << ef.next
    got << stop_of(ef)
  end

  g = [5, 6]
  eg = g.each
  show('peek') { [eg.peek, eg.peek, eg.next, eg.peek, eg.next, stop_of(eg)] }

  h = [1, 2]
  eh = h.each
  show('rewind') do
    first = eh.next
    eh.next
    eh.rewind
    [first, eh.next]
  end

  k = [1, 2]
  ek = k.each
  show('feed once') { ek.next; ek.feed(:x); ek.next }
  show('feed twice') { ek.feed(:y); ek.feed(:z) }

  show('raise in fiber block') do
    fiber = Fiber.new do
      begin
        [1, 2, 3].each { |x| Fiber.yield x; raise ArgumentError, "boom #{x}" if x == 1 }
        :done
      rescue ArgumentError => ex
        "rescued #{ex.message}"
      end
    end
    [fiber.resume, fiber.resume]
  end
  show('raise in root block') { [1, 2].each { |x| raise TypeError, "t#{x}" } }

  show('blockless each in fiber') { Fiber.new { [1, 2].each }.resume.to_a }

  class EnumStepSub < Array
    def [](i)
      super(i) * 10
    end
  end
  show('subclass next') { s = EnumStepSub.new([1, 2]).each; [s.next, s.next, stop_of(s)] }

  class EnumStepShort < Array
    def length
      1
    end
  end
  show('subclass length') { s = EnumStepShort.new([4, 5]).each; [s.next, stop_of(s)] }

  puts 'end'
RUBY

# The expected lines of the interpreted run, from Ruby's own semantics.
EXPECTED = {
  'ordinary next' => '[1, 2, 3]',
  'ordinary end' => '"StopIteration result=[1, 2, 3]"',
  'loop result' => '[7, 8]',
  'append during' => '[1, 2, 3, "StopIteration result=[1, 2, 3]"]',
  'delete middle during' => '[1, 3, 4, "StopIteration result=[1, 3, 4]"]',
  'delete last during' => '[1, 2, "StopIteration result=[1, 2]"]',
  'peek' => '[5, 5, 5, 6, 6, "StopIteration result=[5, 6]"]',
  'rewind' => '[1, 1]',
  'feed once' => '2',
  'feed twice' => 'raised TypeError: feed value already set',
  'raise in fiber block' => '[1, "rescued boom 1"]',
  'raise in root block' => 'raised TypeError: t1',
  'blockless each in fiber' => '[1, 2]',
  'subclass next' => '[10, 20, "StopIteration result=[1, 2]"]',
  'subclass length' => '[4, "StopIteration result=[4, 5]"]'
}.freeze

dir = Dir.mktmpdir('bc2cpp-enum-step')
at_exit { FileUtils.remove_entry(dir) }

puts '-- generated code'
on_dir = File.join(dir, 'on')
off_dir = File.join(dir, 'off')
FileUtils.mkdir_p([on_dir, off_dir])
on_code, on_err = generate_with(true, on_dir)
off_code, = generate_with(false, off_dir)
check.call('flag set: Array#each registers through bc2cpp_enum_step_save', on_code.match?(STEP_SAVE))
check.call('flag set: the step function is emitted', on_code.include?('static mrb_value bc2cpp_each_step('))
check.call('flag set: Array#each no longer saves its own body', !on_code.match?(PLAIN_SAVE))
check.call('flag unset: no step text is emitted', !off_code.include?('bc2cpp_each_step') && !off_code.include?('bc2cpp_enum_step'))
check.call('flag unset: Array#each keeps its own saved body', off_code.match?(PLAIN_SAVE))
check.call('flag set: the generated code has no #error', !on_code.include?('#error'))

build = Bc2cppFixtureRuntime.full_or_build
if build.nil?
  puts '  SKIP behavioural comparison: needs a full-core libmruby (BC2CPP_MRUBY_FULL, or rake, g++ and 3rd/mruby)'
else
  puts '-- fixtures on real mruby: Fiber-based (interpreted) and step-based (compiled)'
  body = <<~CPP
    static int scenario(mrb_state* M) {
      std::fflush(stdout);
      // The registrations a gem's init makes, which save Array#each's body (the driver, under ENUM_STEP) before the
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
  check.call('the compiled run registers the step on Array', mode_line.call(compiled)&.end_with?('step=true'))
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
  puts 'bc2cpp enum step array check: PASS'
else
  warn "bc2cpp enum step array check: #{failures.size} failure(s)"
  exit 1
end
