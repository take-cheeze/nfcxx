#!/usr/bin/env ruby
# encoding: UTF-8
# frozen_string_literal: true

# NATIVE_FIBER (docs/bc2cpp-cxx-fiber.md): compiled Fiber programs on an mruby with no mruby-fiber must print what the interpreted
# run prints on the full-core build, scenario by scenario, except KNOWN_GAPS (a gap that starts passing fails, so the table only
# shrinks). The scenario program is a compiled probe class driven by interpreted Ruby that only calls `resume` and `alive?`.
#
# Usage: MRBC=path/to/mrbc [BC2CPP_MRUBY_FULL=dir] [BC2CPP_MRUBY_NOFIBER=dir | BC2CPP_NOFIBER_BUILD_DIR=dir] \
#        ruby scripts/bc2cpp/native_fiber_check.rb

require 'open3'
require_relative 'fixture_runtime'

suite = Bc2cppStepCheck.new('bc2cpp native Fiber check')

# Scenarios of a gem the probe does not compile (StringIO is in the no-fiber build, but not among the probe's owners).
STRINGIO = /StringIO/
# The iterator scenarios, and the expected output of the ones mruby's interpreter cannot give (a Fiber.yield in the native
# sort's comparison), as resumable_variants_check.rb defines them.
fixture = File.read(File.join(__dir__, 'resumable_variants_check.rb'))
eval(fixture[/^# array\.c's sort.*?^\]\.freeze$/m], TOPLEVEL_BINDING, 'resumable_variants scenarios')
scenarios = SCENARIOS.reject { |label, fiber, plain| "#{label} #{fiber} #{plain}".match?(STRINGIO) }

# Scenarios beyond the iterator list: [label, method of NativeFiberProbe that builds the fiber or runs the scenario,
# driver line]. Their bodies are compiled like the others.
EXTRAS = [
  ['nonlocal return', 'drain(NativeFiberProbe.new.nonlocal_fiber)'],
  ['custom nested each', 'drain(NativeFiberProbe.new.custom_each_fiber)'],
  ['nested fibers and resume values', 'NativeFiberProbe.new.nested_fibers'],
  ['fiber transfer', 'NativeFiberProbe.new.transfer_scenario'],
  ['enumerator lazy nested', 'NativeFiberProbe.new.lazy_scenario'],
  ['range sum plain', '(1..3).sum'],
  ['range sum in fiber', 'drain(NativeFiberProbe.new.range_sum_fiber)'],
  ['current fiber', 'NativeFiberProbe.new.current_scenario'],
  ['block parameters at the first resume', 'NativeFiberProbe.new.first_resume_scenario'],
  ['dead fiber', 'NativeFiberProbe.new.dead_fiber_scenario'],
  ['root fiber at the root', 'NativeFiberProbe.new.root_at_root'],
  ['root fiber inside a fiber', 'NativeFiberProbe.new.root_in_fiber'],
  ['root fiber transfer chain', 'NativeFiberProbe.new.root_chain'],
  ['root fiber errors', 'NativeFiberProbe.new.root_errors'],
  ['fiber raise', 'NativeFiberProbe.new.raise_scenario'],
  ['tap then yield_self', 'drain(NativeFiberProbe.new.tap_fiber)'],
  ['fiber from a proc variable', 'drain(NativeFiberProbe.new.proc_variable_fiber)'],
  ['fiber through send', 'drain(NativeFiberProbe.new.send_fiber)'],
  ['fiber through public_send', 'drain(NativeFiberProbe.new.public_send_fiber)'],
  ['enumerator generator next', 'drain(NativeFiberProbe.new.generator_fiber)'],
  ['enumerator produce next', 'drain(NativeFiberProbe.new.produce_fiber)'],
  ['yielder chain next', 'drain(NativeFiberProbe.new.yielder_fiber)'],
  ['chunk next', 'drain(NativeFiberProbe.new.chunk_fiber)'],
  ['lambda call', 'drain(NativeFiberProbe.new.lambda_fiber)']
].freeze

# Scenarios mruby-fiber cannot run (it has no Fiber#raise): the expected line is what CRuby prints for the same program.
OWN_EXPECTED = {
  'fiber raise' => 'fiber raise: [:waiting, :rescued, :done, "x", false, ["boom", :ens]]'
}.freeze

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

    def nested_fibers
      outer = Fiber.new do |a|
        inner = Fiber.new { |b| Fiber.yield [a, b]; :inner_done }
        first = inner.resume(2)
        resumed = Fiber.yield(first)
        [resumed, inner.resume]
      end
      [outer.resume(1), outer.resume(3, 4)]
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

    def first_resume_scenario
      f = Fiber.new { |a, b| c = Fiber.yield [a, b]; [c, a, b] }
      [f.resume(1, 2), f.resume(:c)]
    end

    def root_at_root
      main = Fiber.current
      [main.class, main.alive?, main.equal?(Fiber.current), main.inspect.start_with?('#<Fiber'), main.transfer(1, 2)]
    end

    def root_in_fiber
      main = Fiber.current
      f = Fiber.new { [main.equal?(Fiber.current), Fiber.current.equal?(main), main.alive?, Fiber.yield(:y)] }
      [f.resume, f.resume(:r), main.equal?(Fiber.current), f.alive?]
    end

    def root_chain
      main = Fiber.current
      f = Fiber.new { a = main.transfer(:one); b = main.transfer(a); [:end, b] }
      [f.transfer, f.transfer(:two), f.transfer(:three), f.alive?, main.alive?]
    end

    def root_errors
      main = Fiber.current
      out = []
      begin
        main.resume
      rescue FiberError => e
        out << e.message
      end
      f = Fiber.new do
        begin
          main.resume
        rescue FiberError => e
          Fiber.yield e.message
        end
        :end
      end
      out << f.resume
      out << f.resume
      out << f.alive?
      out
    end

    def raise_scenario
      events = []
      f = Fiber.new do
        begin
          Fiber.yield :waiting
        rescue ArgumentError => e
          events << e.message
          Fiber.yield :rescued
        ensure
          events << :ens
        end
        :done
      end
      a = f.resume
      b = f.raise(ArgumentError, 'boom')
      c = f.resume
      g = Fiber.new { Fiber.yield 1 }
      g.resume
      err = begin
        g.raise(IOError, 'x')
      rescue IOError => e
        e.message
      end
      [a, b, c, err, g.alive?, events]
    end

    # Kernel#tap/then/yield_self (mruby-object-ext, joined to the world below) run their block as a step.
    def tap_fiber
      Fiber.new do
        [1.tap { Fiber.yield :in_tap }, 2.then { |x| Fiber.yield [:in_then, x]; x + 1 },
         3.yield_self { |x| Fiber.yield [:in_ys, x]; x * 2 }]
      end
    end

    # A Fiber made from a proc variable, or through send/public_send, is a C++ Fiber too.
    def proc_variable_fiber
      body = proc { Fiber.yield 1; 2 }
      Fiber.new(&body)
    end

    def send_fiber
      Fiber.send(:new) { Fiber.yield 1; 2 }
    end

    def public_send_fiber
      Fiber.public_send(:new) { Fiber.yield 1; 2 }
    end

    # Enumerator.new generators, Enumerator.produce and Enumerable#chunk driven by next, inside a Fiber.
    def generator_fiber
      Fiber.new do
        e = Enumerator.new { |y| y << 1; y << 2 }
        [e.next, Fiber.yield(:mid), e.next, (e.next rescue :stop)]
      end
    end

    def produce_fiber
      Fiber.new do
        e = Enumerator.produce(1) { |x| x * 2 }
        Fiber.yield e.next
        [e.next, e.next, e.peek]
      end
    end

    def yielder_fiber
      Fiber.new do
        e = Enumerator.new { |y| y << :a << :b; y.yield :c, :d }
        [e.next, Fiber.yield(:mid), e.next, e.next]
      end
    end

    def chunk_fiber
      Fiber.new do
        e = [1, 2, 4].chunk { |x| x.even? }
        Fiber.yield e.next
        e.next
      end
    end

    # lambda { }.call suspends like a block call when the arity fits; a miss raises as Proc#call does.
    def lambda_fiber
      Fiber.new do
        a = lambda { Fiber.yield :in_lambda; 7 }.call
        b = lambda { |x, y| Fiber.yield [x, y]; x + y }.call(1, 2)
        c = begin
          lambda { |x| Fiber.yield x; x }.call
        rescue ArgumentError => e
          e.message
        end
        [a, b, c]
      end
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

driver_lines = scenarios.each_with_index.flat_map do |(label, _, plain), i|
  ["show('fiber #{label}') { drain(NativeFiberProbe.new.fiber_#{i}) }", "show('plain #{label}') { #{plain} }"]
end
driver_lines += EXTRAS.map { |label, call| "show('#{label}') { #{call} }" }
DRIVER = "#{Bc2cppStepCheck::SHOW}#{Bc2cppStepCheck::DRAIN}#{driver_lines.join("\n")}\nputs 'end'\n"

# Scenarios whose Fiber body cannot be a step yet: label => why. The no-fiber output differs from the interpreted run for these,
# and only these. None is left: the table stays so a new gap is recorded, not hidden.
KNOWN_GAPS = {}.freeze
OWNERS = %w[NativeFiberSource NativeFiberProbe Array Enumerable Hash Integer Float Range String].freeze

full = Bc2cppFixtureRuntime.full_or_build
nofiber = Bc2cppFixtureRuntime.nofiber_or_build
# The core mrblib of the gems the no-fiber build has (mruby-enumerator's next_values is compiled onto the C++ Fiber); mruby-stringio
# stays out. mruby-enum-lazy is not a gem bc2cpp compiles, so its mrblib joins as mruby's own Ruby (a program definition would
# withdraw the kind_of block arms of every name it defines).
core_gems = BC2CPP_CANONICAL_CORE_GEMS - Bc2cppFixtureRuntime::NOFIBER_GEMS - %w[mruby-stringio]
lazy_path = '3rd/mruby/mrbgems/mruby-enum-lazy/mrblib/lazy.rb'
# mruby-object-ext (Kernel#tap/then/yield_self) joins the same way: the closed build has no such gem.
object_path = '3rd/mruby/mrbgems/mruby-object-ext/mrblib/object.rb'
extras = [lazy_path, object_path].map { |path| [path, File.read(File.join(Bc2cppFixtureRuntime::ROOT, path))] }
code = suite.generate(PROBE, OWNERS + %w[Enumerator Kernel], guards: true, core_gems: core_gems, extra: extras)
suite.check('the program compiles and registers a Fiber body step', code.include?('FIBER_BODY_STEP') || code.include?('bc2cpp_fiber_new_'))
suite.check('no generated code loads bytecode or Ruby source for a Fiber', !code.match?(/mrb_load_(?:irep|string)\(/))

if nofiber.nil? || full.nil? || ENV['CC_GENERATED_ONLY'] == '1'
  puts '  SKIP behavioural comparison: needs a full-core libmruby and a no-fiber one (BC2CPP_MRUBY_FULL, BC2CPP_MRUBY_NOFIBER, or rake, g++ and 3rd/mruby)'
else
  symbols, status = Open3.capture2e('nm', '-g', '--defined-only', File.join(nofiber, 'lib/libmruby.a'))
  suite.check('the no-fiber libmruby has no mruby-fiber', status.success? && !symbols.match?(/\bmrb_fiber_\w+|\bfiber_(?:resume|yield|alive)\w*\b/i))
  puts '-- the program on mruby without mruby-fiber, against interpreted mruby with it'
  body = <<~CPP
    static int scenario(mrb_state* M) {
      std::fflush(stdout);
      const char* src = R"RBC(#{DRIVER})RBC";
      mrb_load_string(M, src);
      std::fflush(stdout);
      if (M->exc) { mrb_print_error(M); M->exc = nullptr; return 1; }
      return 0;
    }
  CPP
  reference_built, reference_output = Bc2cppFixtureRuntime.run(suite.dir, suite.err, OWNERS, body, build: full, full: true)
  suite.check('the program builds and runs on the full-core mruby (the reference)', reference_built)
  native_built, native_output = Bc2cppFixtureRuntime.run(suite.dir, suite.err, OWNERS, body, build: nofiber, full: true)
  suite.check('the program builds and links against the no-fiber mruby', native_built)
  expected = Bc2cppFixtureRuntime.sections(reference_output)['interpreted']
  # A scenario with its own expected "fiber" line (the native sort) replaces the interpreter's FiberError.
  scenarios.each_with_index { |(_, _, _, line), i| expected[2 * i] = line.call if expected && line }
  expected&.map! { |line| OWN_EXPECTED.fetch(line.split(': ', 2).first, line) }
  actual = Bc2cppFixtureRuntime.sections(native_output)['compiled']
  suite.check('both runs reach the end', expected&.last == 'end' && actual&.last == 'end')
  if expected && actual
    label_of = ->(line) { line.split(': ', 2).first }
    gap_label = ->(line) { KNOWN_GAPS.key?(label_of.(line)) || KNOWN_GAPS.keys.any? { |gap| label_of.(line) == "fiber #{gap}" } }
    actual_by_label = actual.group_by(&label_of)
    differing = expected.reject { |line| actual.include?(line) }
    unexpected = differing.reject { |line| gap_label.(line) }
    unexpected.first(12).each { |line| puts "    interpreted: #{line}\n    native:      #{actual_by_label[label_of.(line)]&.first}" }
    suite.check("the output equals interpreted mruby over #{expected.size} lines except the known gaps", unexpected.empty?)
    puts "    known gaps: #{differing.size - unexpected.size} lines (#{KNOWN_GAPS.keys.join(', ')})"
    stale = KNOWN_GAPS.keys.select { |gap| expected.none? { |line| label_of.(line) == gap && !actual.include?(line) } }
    suite.check("every known gap still differs (#{stale.join(', ')} pass now: remove them)", stale.empty?)
  end
  puts native_output.lines.last(20).join unless native_built && actual
end
suite.finish
