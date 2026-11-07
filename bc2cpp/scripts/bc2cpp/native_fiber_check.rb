#!/usr/bin/env ruby
# encoding: UTF-8
# frozen_string_literal: true

# NATIVE_FIBER (docs/bc2cpp-cxx-fiber.md, "Removing mruby-fiber"): Fiber programs compiled by bc2cpp run on an mruby that
# has no mruby-fiber, with the C++ Fiber (tools/bc2cpp/runtime/bc2cpp_fiber*.hxx) as the whole Fiber. The scenario
# program is a compiled probe class (every Fiber body in it is compiled), driven by a few lines of interpreted Ruby that
# only call `resume` and `alive?` on the C++ Fibers.
#
#   generated code (needs a host mrbc)
#     - the no-fiber libmruby really has no mruby-fiber, and the program compiles;
#   behaviour (needs a full-core libmruby and the no-fiber one, see Bc2cppFixtureRuntime.nofiber_or_build)
#     - the program's output on the no-fiber build equals the interpreted run on the full-core build (which has
#       mruby-fiber), scenario by scenario, except the KNOWN_GAPS: scenarios whose Fiber body is not a step yet. A gap that
#       starts passing fails the check, so the table only shrinks.
#
# Usage: MRBC=path/to/mrbc [BC2CPP_MRUBY_FULL=dir] [BC2CPP_MRUBY_NOFIBER=dir | BC2CPP_NOFIBER_BUILD_DIR=dir] \
#        ruby scripts/bc2cpp/native_fiber_check.rb

require 'open3'
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

# Scenarios that need a gem the no-fiber build leaves out (StringIO needs mruby-enumerator).
NEEDS_ENUMERATOR = /StringIO/
# The iterator scenarios and the helpers that give the expected output of the ones mruby's interpreter cannot (a
# Fiber.yield in the native sort's comparison), as resumable_variants_check.rb defines them.
fixture = File.read(File.join(__dir__, 'resumable_variants_check.rb'))
eval(fixture[/^# array\.c's sort.*?^\]\.freeze$/m], TOPLEVEL_BINDING, 'resumable_variants scenarios')
scenarios = SCENARIOS.reject { |label, fiber, plain| "#{label} #{fiber} #{plain}".match?(NEEDS_ENUMERATOR) }

# Scenarios beyond the iterator list: [label, method of NativeFiberProbe that builds the fiber or runs the scenario,
# driver line]. Their bodies are compiled like the others.
EXTRAS = [
  ['nonlocal return', 'drain(NativeFiberProbe.new.nonlocal_fiber)'],
  ['custom nested each', 'drain(NativeFiberProbe.new.custom_each_fiber)'],
  ['nested ensure', 'NativeFiberProbe.new.nested_ensure'],
  ['catch throw after yield', 'drain(NativeFiberProbe.new.catch_throw_fiber)'],
  ['nested fibers and resume values', 'NativeFiberProbe.new.nested_fibers'],
  ['escaping closure', 'NativeFiberProbe.new.escaping_closure'],
  ['fiber transfer', 'NativeFiberProbe.new.transfer_scenario'],
  ['enumerator lazy nested', 'NativeFiberProbe.new.lazy_scenario'],
  ['range sum plain', '(1..3).sum'],
  ['range sum in fiber', 'drain(NativeFiberProbe.new.range_sum_fiber)'],
  ['current fiber', 'NativeFiberProbe.new.current_scenario'],
  ['wide registers', 'drain(NativeFiberProbe.new.wide_fiber)'],
  ['block parameters at the first resume', 'NativeFiberProbe.new.first_resume_scenario'],
  ['dead fiber', 'NativeFiberProbe.new.dead_fiber_scenario']
].freeze

WIDE = (0...250).map { |i| "      local#{i} = #{i}\n" }.join

PROBE = <<~RUBY
  class NativeFiberSource
    include Enumerable
    def each(start = 1, *rest, stop: 3, &block)
      while start <= stop
        block.call(start)
        start += 1
      end
      self
    end
  end

  class NativeFiberProbe
#{scenarios.each_with_index.map { |(_, fiber, _), i| "    def fiber_#{i}\n      Fiber.new { #{fiber} }\n    end\n" }.join("\n")}
    def native_nonlocal_result
      [1, 2].each do |value|
        Fiber.yield value
        return :returned if value == 2
      end
    end

    def nonlocal_fiber
      Fiber.new { native_nonlocal_result }
    end

    def custom_each_fiber
      Fiber.new { NativeFiberSource.new.map { |x| Fiber.yield x; x * 3 } }
    end

    def nested_ensure
      events = []
      f = Fiber.new do
        begin
          NativeFiberSource.new.each do |x|
            begin
              Fiber.yield x
              raise ArgumentError, 'after resume' if x == 2
            ensure
              events << x
            end
          end
        rescue ArgumentError => e
          events << e.message
        ensure
          events << :outer
        end
        :done
      end
      result = []
      while f.alive?
        result << f.resume
      end
      [result, events]
    end

    def catch_throw_fiber
      Fiber.new { catch(:tag) { |tag| Fiber.yield tag; throw tag, :caught } }
    end

    def nested_fibers
      outer = Fiber.new do |a|
        inner = Fiber.new { |b| Fiber.yield [a, b]; :inner_done }
        first = inner.resume(2)
        resumed = Fiber.yield(first)
        [resumed, inner.resume]
      end
      [outer.resume(1), outer.resume(3, 4)]
    end

    def escaping_closure
      f = Fiber.new do
        x = 1
        capture = proc { x += 1 }
        Fiber.yield capture
        capture.call
      end
      capture = f.resume
      GC.start
      [capture.call, f.resume, capture.call]
    end

    def transfer_scenario
      main = Fiber.current
      f = Fiber.new { resumed = main.transfer(:yielded); [:done, resumed] }
      [f.transfer, f.transfer(:resumed)]
    end

    def lazy_scenario
      e = NativeFiberSource.new.lazy.map { |x| x * 2 }.select { |x| x > 2 }.to_enum
      [e.next, e.next]
    end

    def range_sum_fiber
      Fiber.new { (1..3).sum }
    end

    def current_scenario
      f = Fiber.new { Fiber.yield Fiber.current; :done }
      first = f.resume
      [first.equal?(f), f.resume, f.alive?]
    end

    def native_wide_registers
#{WIDE}      Fiber.yield [#{(0...250).map { |i| "local#{i}" }.join(', ')}]
      [local0, local249]
    end

    def wide_fiber
      Fiber.new { native_wide_registers }
    end

    def first_resume_scenario
      f = Fiber.new { |a, b| c = Fiber.yield [a, b]; [c, a, b] }
      [f.resume(1, 2), f.resume(:c)]
    end

    def dead_fiber_scenario
      f = Fiber.new { :only }
      first = f.resume
      begin
        f.resume
      rescue FiberError => e
        [first, f.alive?, e.class]
      end
    end
  end
RUBY

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
      GC.start
    end
    out
  end
RUBY
driver_lines = scenarios.each_with_index.flat_map do |(label, _, plain), i|
  ["show('fiber #{label}') { drain(NativeFiberProbe.new.fiber_#{i}) }", "show('plain #{label}') { #{plain} }"]
end
driver_lines += EXTRAS.map { |label, call| "show('#{label}') { #{call} }" }
DRIVER_FULL = "#{DRIVER}#{driver_lines.join("\n")}\nputs 'end'\n"

# Scenarios whose Fiber body cannot be a step yet: label => why. The output of the no-fiber build differs from the
# interpreted run for these, and only these.
KNOWN_GAPS = {
  'nested ensure' => 'rescue/ensure around a yield is not a step yet',
  'fiber transfer' => 'Fiber#transfer is not implemented',
  'enumerator lazy nested' => 'Enumerator and Enumerator::Lazy need mruby-enumerator, which needs mruby-fiber',
  'custom nested each' => 'the user each takes keyword arguments, which a suspendable method cannot'
}.freeze

OWNERS = %w[NativeFiberSource NativeFiberProbe Array Enumerable Hash Integer Float Range String].freeze

full = Bc2cppFixtureRuntime.full_or_build
nofiber = Bc2cppFixtureRuntime.nofiber_or_build
dir = Dir.mktmpdir('bc2cpp-native-fiber')
at_exit { FileUtils.remove_entry(dir) }

puts '-- generated code'
# BC2CPP_GUARD_FIBER_FREE=0 keeps every guard, so each listed method takes its variant in this probe (the probe is not
# the whole program).
saved_guard = ENV['BC2CPP_GUARD_FIBER_FREE']
ENV['BC2CPP_GUARD_FIBER_FREE'] = '0'
code, err = begin
  # The core mrblib of the gems the no-fiber build has: not mruby-enumerator nor mruby-stringio, which need mruby-fiber.
  core_gems = BC2CPP_CANONICAL_CORE_GEMS - Bc2cppFixtureRuntime::NOFIBER_GEMS - %w[mruby-stringio]
  Bc2cppFixtureRuntime.generate(PROBE, dir, core: true, core_gems: core_gems, only_owners: OWNERS)
ensure
  saved_guard ? ENV['BC2CPP_GUARD_FIBER_FREE'] = saved_guard : ENV.delete('BC2CPP_GUARD_FIBER_FREE')
end
check.call('the program compiles and registers a Fiber body step', code.include?('FIBER_BODY_STEP') || code.include?('bc2cpp_fiber_new_'))
check.call('no generated code loads bytecode or Ruby source for a Fiber', !code.match?(/mrb_load_(?:irep|string)\(/))

if nofiber.nil? || full.nil? || ENV['CC_GENERATED_ONLY'] == '1'
  puts '  SKIP behavioural comparison: needs a full-core libmruby and a no-fiber one (BC2CPP_MRUBY_FULL, BC2CPP_MRUBY_NOFIBER, or rake, g++ and 3rd/mruby)'
else
  symbols, status = Open3.capture2e('nm', '-g', '--defined-only', File.join(nofiber, 'lib/libmruby.a'))
  check.call('the no-fiber libmruby has no mruby-fiber', status.success? && !symbols.match?(/\bmrb_fiber_\w+|\bfiber_(?:resume|yield|alive)\w*\b/i))

  puts '-- the program on mruby without mruby-fiber, against interpreted mruby with it'
  body = <<~CPP
    static int scenario(mrb_state* M) {
      std::fflush(stdout);
      const char* src = R"RBC(#{DRIVER_FULL})RBC";
      mrb_load_string(M, src);
      std::fflush(stdout);
      if (M->exc) { mrb_print_error(M); M->exc = nullptr; return 1; }
      return 0;
    }
  CPP
  reference_built, reference_output = Bc2cppFixtureRuntime.run(dir, err, OWNERS, body, build: full, full: true)
  check.call('the program builds and runs on the full-core mruby (the reference)', reference_built)
  native_built, native_output = Bc2cppFixtureRuntime.run(dir, err, OWNERS, body, build: nofiber, full: true)
  check.call('the program builds and links against the no-fiber mruby', native_built)
  expected = Bc2cppFixtureRuntime.sections(reference_output)['interpreted']
  # A scenario with its own expected "fiber" line (the native sort) replaces the interpreter's FiberError.
  scenarios.each_with_index { |(_, _, _, line), i| expected[2 * i] = line.call if expected && line }
  actual = Bc2cppFixtureRuntime.sections(native_output)['compiled']
  check.call('both runs reach the end', expected&.last == 'end' && actual&.last == 'end')
  if expected && actual
    label_of = ->(line) { line.split(': ', 2).first }
    gap_label = lambda do |line|
      label = label_of.call(line)
      KNOWN_GAPS.key?(label) ? label : KNOWN_GAPS.keys.find { |gap| label == "fiber #{gap}" }
    end
    actual_by_label = actual.group_by(&label_of)
    differing = expected.reject { |line| actual.include?(line) }
    unexpected = differing.reject { |line| gap_label.call(line) }
    unexpected.first(12).each { |line| puts "    interpreted: #{line}\n    native:      #{actual_by_label[label_of.call(line)]&.first}" }
    check.call("the output equals interpreted mruby over #{expected.size} lines except the known gaps", unexpected.empty?)
    puts "    known gaps: #{differing.size - unexpected.size} lines (#{KNOWN_GAPS.keys.join(', ')})"
    stale = KNOWN_GAPS.keys.select { |gap| expected.none? { |line| label_of.call(line) == gap && !actual.include?(line) } }
    check.call("every known gap still differs (#{stale.join(', ')} pass now: remove them)", stale.empty?)
  end
  puts native_output.lines.last(20).join unless native_built && actual
end

if failures.empty?
  puts 'bc2cpp native Fiber check: PASS'
else
  warn "bc2cpp native Fiber check: #{failures.size} failure(s)"
  exit 1
end
