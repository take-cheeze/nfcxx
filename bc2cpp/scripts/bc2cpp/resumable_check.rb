#!/usr/bin/env ruby
# frozen_string_literal: true

# Check RESUMABLE_ROOTS (docs/adr/0273): a method that a `Fiber.new { root; :done }` block calls
# and that reaches Fiber.yield (directly, through tiny helpers, in `while` loops and inlined
# Integer#step/upto/downto loops) is compiled as a step function over a heap frame, and the
# fiber's bytecode driver calls it again after every Fiber.yield.
#
#   - generated code: which roots become step functions, the inlined helpers and flat loops,
#     and the reason every refused root stays interpreted (rescue around a yield, a yield in a
#     block that is not inlined, a yield with two arguments, a nested step loop);
#   - behaviour (needs a full-core libmruby, see Bc2cppFixtureRuntime.full_or_build): the
#     compiled roots yield and return what the interpreted ones do, round-tripping the yielded
#     and the resumed values, under GC pressure (also with an aggressive incremental GC), for a
#     dead fiber, and when called outside a Fiber or through a C frame.
#
# Usage: MRBC=path/to/mrbc ruby scripts/bc2cpp/resumable_check.rb

require 'tmpdir'
require_relative 'fixture_runtime'

failures = []
check = lambda do |what, condition|
  puts "  #{condition ? 'ok  ' : 'FAIL'} #{what}"
  failures << what unless condition
end

FIXTURE = <<~'RUBY'
# Every class is a Fiber.new root (`Fiber.new { run; :done }`) so `run` qualifies for the
# resumable transform; `go(v)` resumes the fiber.
class RcWhile
  def initialize; @n = 0; @f = Fiber.new { run; :done }; end
  def go(v = nil); @f.resume(v); end
  def run
    i = 0
    while i < 4
      Fiber.yield i
      i += 1
    end
    Fiber.yield
  end
end

class RcStep
  def initialize; @log = []; @f = Fiber.new { run; :done }; end
  def go(v = nil); @f.resume(v); end
  def run
    3.step(20, 8) { |i| Fiber.yield i }
    20.step(3, -8) { |i| Fiber.yield i }
    1.upto(3) { |i| Fiber.yield i * 10 }
    3.downto(1) { |i| Fiber.yield i * 100 }
    Fiber.yield 0.step(4, 2) { |i| i }
  end
end

class RcHelper
  def initialize; @hclk = 0; @target = 3; @ticks = 0; @f = Fiber.new { run; :done }; end
  def tick; @ticks += 1; end
  def go(v = nil); @f.resume(v); end
  def wait_frame; Fiber.yield true; end
  def wait_one; @hclk += 1; Fiber.yield if @target <= @hclk; end
  def wait_two; @hclk += 2; Fiber.yield if @target <= @hclk; end
  def wait_zero; Fiber.yield if @target <= @hclk; end
  def run
    wait_frame
    while @hclk < 12
      2.step(9, 4) do
        wait_two
        @target += 1
        tick
        wait_one
      end
      wait_zero
      @target += 2
    end
    wait_frame
  end
end

class RcLocals
  def initialize; @f = Fiber.new { run; :done }; end
  def go(v = nil); @f.resume(v); end
  def run
    s = "hello"
    a = [1, 2, 3]
    h = { k: "v" }
    got = Fiber.yield s
    a << got
    t = s + " world"
    got2 = Fiber.yield [a, h]
    Fiber.yield [s, t, a, h, got, got2]
    :finished
  end
end

class RcGc
  def initialize; @f = Fiber.new { run; :done }; end
  def go(v = nil); @f.resume(v); end
  def run
    keep = Array.new(20) { |i| "item#{i}" * 3 }
    text = "x" * 200
    0.step(2, 1) do |round|
      junk = []
      2000.times { |i| junk << "garbage#{i}" << [i] }
      GC.start
      Fiber.yield [round, keep.size, keep.last, text.size, junk.size]
      keep << "more#{round}"
    end
    Fiber.yield keep.map { |x| x.size }
  end
end

class RcGcInc
  def initialize; @f = Fiber.new { run; :done }; end
  def go(v = nil); @f.resume(v); end
  def run
    keep = []
    text = "seed"
    0.step(40, 1) do |round|
      keep << "kept#{round}" * 2
      text = text + "." if round % 8 == 0
      junk = nil
      junk = Array.new(300) { |i| "junk#{round}-#{i}" }
      Fiber.yield [round, keep.size, keep[round].size, text.size, junk.size] if round % 10 == 0
    end
    keep.map { |x| x.size }.sum
  end
end

class RcNested
  def initialize; @f = Fiber.new { run; :done }; end
  def go(v = nil); @f.resume(v); end
  def run
    n = 0
    j = 0
    while j < 2
      2.step(6, 2) do |i|
        n += i * j
        Fiber.yield [j, i, n]
        w = 0
        while w < 2
          Fiber.yield [:inner, w]
          w += 1
        end
      end
      Fiber.yield :row
      j += 1
    end
    k = 0
    while k < 2
      3.downto(2) { |q| Fiber.yield [k, q] }
      k += 1
    end
    n
  end
end

class RcReturn
  def initialize; @f = Fiber.new { run; :done }; end
  def go(v = nil); @f.resume(v); end
  def run
    1.step(50, 1) do |i|
      Fiber.yield i
      return i * 7 if i == 3
    end
    :unreachable
  end
end

class RcBreak
  def initialize; @f = Fiber.new { run; :done }; end
  def go(v = nil); @f.resume(v); end
  def run
    r = 1.step(9, 2) do |i|
      Fiber.yield i
      break i * 100 if i >= 5
    end
    Fiber.yield r
    r
  end
end

class RcValues
  def initialize; @f = Fiber.new { run; :done }; end
  def go(*v); @f.resume(*v); end
  def run
    a = Fiber.yield
    b = Fiber.yield a
    c = Fiber.yield [a, b]
    Fiber.yield [a, b, c]
  end
end

class RcNoYield
  def initialize; @f = Fiber.new { run; :done }; end
  def go(v = nil); @f.resume(v); end
  def run
    Fiber.yield 1 if @never
    [1, 2, 3].each { |x| x }
  end
end

class RcRaise
  def initialize; @f = Fiber.new { run; :done }; end
  def go(v = nil); @f.resume(v); end
  def run
    Fiber.yield :before
    raise ArgumentError, "boom"
  end
end

# -- refusals: these stay interpreted and must behave the same --
class RcRescue
  def initialize; @f = Fiber.new { run; :done }; end
  def go(v = nil); @f.resume(v); end
  def run
    begin
      Fiber.yield :in_begin
      raise "x"
    rescue => e
      Fiber.yield e.message
    end
    :end
  end
end

class RcBlock
  def initialize; @f = Fiber.new { run; :done }; end
  def go(v = nil); @f.resume(v); end
  def run
    [1, 2].each { |x| Fiber.yield x }
    :end
  end
end

class RcNestedStep
  def initialize; @f = Fiber.new { run; :done }; end
  def go(v = nil); @f.resume(v); end
  def run
    2.step(6, 2) do |i|
      1.upto(2) { |j| Fiber.yield [i, j] }
    end
    :end
  end
end

class RcTwoArgs
  def initialize; @f = Fiber.new { run; :done }; end
  def go(v = nil); @f.resume(v); end
  def run
    Fiber.yield 1, 2
    :end
  end
end

module RcSpace
  class Inner
    def initialize; @f = Fiber.new { run; :done }; end
    def go(v = nil); @f.resume(v); end
    def run
      Fiber.yield :in_namespace
      :end
    end
  end
end

class RcPlain
  def helper(x); x + 1; end
  def call_it; helper(1); end
end

class RcRoot
  def run
    Fiber.yield :from_root_context
  end
end
RUBY

DRIVER = <<~'RUBY'
def drive(name, obj, inputs)
  out = inputs.map do |v|
    begin
      r = v.nil? ? obj.go : obj.go(*v)
      r.inspect
    rescue => e
      "#{e.class}"
    end
  end
  puts "#{name}: #{out.join(' | ')}"
end
none = Array.new(12)
drive :while, RcWhile.new, none
drive :step, RcStep.new, Array.new(20)
h = RcHelper.new
drive :helper, h, Array.new(24)
puts "helper ticks: #{h.instance_variable_get(:@ticks)}"
drive :locals, RcLocals.new, [nil, ["got"], [:second], nil, nil]
drive :gc, RcGc.new, Array.new(6)
drive :gc_inc, RcGcInc.new, Array.new(7)
drive :nested, RcNested.new, Array.new(24)
drive :return, RcReturn.new, Array.new(6)
drive :break, RcBreak.new, Array.new(6)
drive :values, RcValues.new, [nil, [1], [2], [3], nil]
drive :values_multi, RcValues.new, [nil, [1, 2], [], [[9]], nil]
drive :noyield, RcNoYield.new, Array.new(3)
drive :raise, RcRaise.new, Array.new(4)
drive :rescue, RcRescue.new, Array.new(5)
drive :block, RcBlock.new, Array.new(5)
drive :nested_step, RcNestedStep.new, Array.new(10)
drive :namespaced, RcSpace::Inner.new, Array.new(4)
drive :twoargs, RcTwoArgs.new, Array.new(4)
# called outside a fiber and from a C frame
begin
  puts "root: #{RcRoot.new.run.inspect}"
rescue => e
  puts "root: #{e.class}: #{e.message}"
end
o = RcNoYield.new
puts "direct: #{o.run.inspect}"
puts "via send: #{o.send(:run).inspect}"
puts "via each: #{[o].map { |x| x.run }.inspect}"
begin
  [RcRoot.new].each { |x| x.run }
rescue => e
  puts "yield from a C frame: #{e.class}"
end
f = Fiber.new { [RcRoot.new].each { |x| x.run }; :done }
begin
  puts "yield through each: #{f.resume.inspect}"
rescue => e
  puts "yield through each: #{e.class}"
end
puts "end"
RUBY

COMPILED = %w[RcWhile RcStep RcHelper RcLocals RcGc RcGcInc RcNested RcReturn RcBreak RcValues RcNoYield RcRaise RcSpace::Inner].freeze
REFUSED = {
  'RcRescue' => 'has a rescue or ensure handler',
  'RcBlock' => 'Fiber.yield inside a block or loop that is not inlined into the step function',
  'RcNestedStep' => 'Fiber.yield inside a block or loop that is not inlined into the step function',
  'RcTwoArgs' => 'calls Fiber.yield with 2 arguments'
}.freeze
OWNERS = (COMPILED + REFUSED.keys + %w[RcPlain RcRoot]).freeze

def cpp_name(owner) = owner.gsub('::', '__')

def body_of(code, fn)
  code[/^static mrb_value #{cpp_name(fn)}_step\(mrb_state\* M.*?(?=^mrb_value #{cpp_name(fn)}_impl)/m].to_s
end

unless Bc2cppFixtureRuntime.mrbc && system(Bc2cppFixtureRuntime.mrbc, '--version', out: File::NULL, err: File::NULL)
  puts '  SKIP: no host mrbc (set MRBC); the generated-code and behavioural checks need it'
  exit 0
end

Dir.mktmpdir do |dir|
  code, err = Bc2cppFixtureRuntime.generate(FIXTURE, dir)
  entries = err.split('== compiled entry points ==', 2)[1].to_s.split("\n== ", 2)[0]
  COMPILED.each do |owner|
    body = body_of(code, "#{owner}_run")
    check.call("#{owner}#run is a step function", !body.empty? && !body.include?('#error') && entries.include?("(#{owner}#run,"))
  end
  REFUSED.each do |owner, reason|
    check.call("#{owner}#run stays interpreted, and says why (#{reason})",
               !entries.include?("(#{owner}#run,") && err.include?("bc2cpp: resumable: #{owner}#run stays interpreted: #{reason}"))
  end
  check.call('the yielding helpers stay interpreted (they are inlined, never entered)',
             %w[wait_frame wait_one wait_two wait_zero].none? { |name| entries.include?("(RcHelper##{name},") })
  check.call('a method reachable from the fiber that cannot yield is compiled and called directly',
             entries.include?('(RcHelper#tick,') && body_of(code, 'RcHelper_run').include?('RcHelper_tick_impl(M, self)'))
  check.call('the helper calls are inlined into the step function',
             body_of(code, 'RcHelper_run').scan('RESUMABLE_HELPER wait_one').size >= 1 &&
             body_of(code, 'RcHelper_run').scan('RESUMABLE_YIELD').size >= 4)
  step = body_of(code, 'RcStep_run')
  check.call('step loops are flat: counters in the frame, no C++ for', step.include?('F->slots[') && !step.include?('for (long long'))
  check.call('registers are references into the heap frame', step.include?('mrb_value& r0 = R[2];'))
  check.call('a yield saves its state, marks the frame for the GC and returns the frame',
             step.include?('F->state = 1;') && step.include?('mrb_write_barrier') && step.include?('return bc2cpp_frame_value;'))
  check.call('each yield point has a resume label the entry switch jumps to',
             step.scan(/Lbc2cpp_resume_(\d+):;/).flatten.sort == step.scan(/case (\d+): goto Lbc2cpp_resume_/).flatten.sort)
  check.call('the entry hands a VM-called invocation to the driver and steps from C otherwise',
             code.include?('bc2cpp_resumable_exec_ok(M)') && code.include?('bc2cpp_resumable_yield_from_c'))
  check.call('no compiled method calls a resumable one directly (only its own entry wrapper does)',
             COMPILED.all? { |owner| code.scan("#{cpp_name(owner)}_run_impl(M, ").size == 1 })
end

full = Bc2cppFixtureRuntime.full_or_build
if full.nil?
  puts '  SKIP behavioural comparison: needs a full-core libmruby (BC2CPP_MRUBY_FULL, or rake, g++ and 3rd/mruby)'
else
  Dir.mktmpdir do |dir|
    _code, err = Bc2cppFixtureRuntime.generate(FIXTURE, dir)
    body = <<~CPP
      static int scenario(mrb_state* M) {
        std::fflush(stdout);
        // Without the frame class and driver from bc2cpp_set_instance_tts, the first entry defines them
        // from inside a running method (in a class scope), where a bare `module` would nest.
        if (getenv("BC2CPP_LAZY_INIT")) mrb_const_remove(M, mrb_obj_value(M->object_class), mrb_intern_lit(M, "Bc2cppResumable"));
        // The stress run collects incrementally all the time, so frames are marked while suspended.
        const char* prelude = getenv("BC2CPP_GC_STRESS")
          ? "GC.interval_ratio = 100; GC.step_ratio = 200; GC.generational_mode = false\\n" : "";
        std::string src = std::string(prelude) + R"BCD(#{DRIVER})BCD";
        mrb_load_string(M, src.c_str());
        if (M->exc) { mrb_print_error(M); M->exc = nullptr; return 1; }
        return 0;
      }
    CPP
    body = "#include <string>\n#include <cstdlib>\n#{body}"
    built, results = Bc2cppFixtureRuntime.run(dir, err, OWNERS, body, build: full, full: true,
                                              envs: [{}, { 'BC2CPP_GC_STRESS' => '1' }, { 'BC2CPP_LAZY_INIT' => '1' }])
    check.call('the fixture builds', built)
    if built
      results.each_with_index do |(output, ok), i|
        label = ['default GC', 'incremental GC stress', 'lazy driver load'][i]
        check.call("#{label}: the process exits cleanly", ok)
        sections = Bc2cppFixtureRuntime.sections(output)
        interpreted = sections['interpreted']
        compiled = sections['compiled']
        check.call("#{label}: the driver prints #{interpreted&.size} lines in both runs",
                   interpreted && interpreted.last == 'end' && compiled&.last == 'end')
        check.call("#{label}: interpreted and compiled runs print the same", interpreted == compiled)
        if interpreted && compiled
          interpreted.zip(compiled).reject { |a, b| a == b }.first(8).each { |a, b| puts "    interpreted: #{a}\n    compiled:    #{b}" }
        end
        puts output.lines.last(20).join unless ok
      end
    end
  end
end

if failures.empty?
  puts 'bc2cpp resumable check: PASS'
else
  warn "bc2cpp resumable check: #{failures.size} failure(s)"
  exit 1
end
