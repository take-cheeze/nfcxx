#!/usr/bin/env ruby
# encoding: UTF-8
# frozen_string_literal: true

# CALL_FROM_C (tools/bc2cpp/codegen_resumable.rb bc2cpp_resumable_resume_from_c): a resumable method entered from C, not
# as a frame of a C++ Fiber, runs the frames its steps CALL to their end. The entry is reached that way when the
# caller is interpreted code in a Fiber (mruby-fiber) or the VM: core iterators take their resumable variant
# whenever M->c is not the root context.
#
#   behaviour (needs a host mrbc and a full-core libmruby)
#     - inside an interpreted Fiber, compiled Array#sort with a block that does not yield, and a compiled Enumerable method
#       whose body calls each with a block, give the interpreted results (before the fix a CALL suspension was taken for
#       a Fiber.yield and raised FiberError);
#     - a Fiber.yield in such a block is a FiberError (a yield through compiled code needs a compiled Fiber body).
#
# Usage: MRBC=path/to/mrbc [BC2CPP_MRUBY_FULL=dir | BC2CPP_FULL_BUILD_DIR=dir] ruby scripts/bc2cpp/call_from_c_check.rb

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
  puts '  SKIP: no host mrbc (set MRBC); the behavioural check needs it'
  exit 0
end

# The probe makes the core iterators it names take their variant (a Fiber body calls them); the driver runs them from an
# interpreted Fiber, where the variant is entered from C.
PROBE = <<~RUBY
  class CallFromCProbe
    def run
      Fiber.new do
        r = []
        r << [3, 1, 2].sort { |a, b| Fiber.yield a; a <=> b }
        r << (1..3).collect { |x| Fiber.yield x; x }
        r << [3, 1, 2].sort! { |a, b| a <=> b }
        r
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
  show('sort in fiber') { Fiber.new { [3, 1, 2].sort { |a, b| a <=> b } }.resume }
  show('sort in fiber, large') { Fiber.new { (1..20).to_a.reverse.sort { |a, b| a <=> b } }.resume }
  show('sort! in fiber') { Fiber.new { [3, 1, 2].sort! { |b, a| a <=> b } }.resume }
  show('collect in fiber') { Fiber.new { (1..3).collect { |x| x * 2 } }.resume }
  show('inject in fiber') { Fiber.new { (1..4).inject(0) { |a, x| a + x } }.resume }
  show('flat_map in fiber') { Fiber.new { (1..2).flat_map { |x| [x, x] } }.resume }
  show('sort yield in fiber') { Fiber.new { [2, 1].sort { |a, b| Fiber.yield a; a <=> b } }.resume }
  show('collect yield in fiber') { Fiber.new { (1..2).collect { |x| Fiber.yield x; x } }.resume }
  puts 'end'
RUBY

OWNERS = %w[Array Enumerable Range Hash Integer String StringIO CallFromCProbe].freeze
baseline_dir = Dir.mktmpdir('bc2cpp-call-from-c')
at_exit { FileUtils.remove_entry(baseline_dir) }
saved_guard = ENV['BC2CPP_GUARD_FIBER_FREE']
ENV['BC2CPP_GUARD_FIBER_FREE'] = '0'
code, baseline_err = begin
  Bc2cppFixtureRuntime.generate(PROBE, baseline_dir, core: true, only_owners: OWNERS)
ensure
  saved_guard ? ENV['BC2CPP_GUARD_FIBER_FREE'] = saved_guard : ENV.delete('BC2CPP_GUARD_FIBER_FREE')
end
check.call('no #error in the generated code', !code.include?('#error'))
check.call('Array#sort has a resumable variant', code.include?('Array_sort_rsm_impl'))

if ENV['CC_GENERATED_ONLY'] == '1'
  puts '  SKIP behavioural comparison: CC_GENERATED_ONLY'
else
  build = Bc2cppFixtureRuntime.full_or_build
  if build.nil?
    puts '  SKIP behavioural comparison: needs a full-core libmruby (BC2CPP_MRUBY_FULL, or rake, g++ and 3rd/mruby)'
  else
    puts '-- interpreted Fibers calling compiled iterators'
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
    built, output = Bc2cppFixtureRuntime.run(baseline_dir, baseline_err, OWNERS, body, build: build, full: true)
    check.call('the fixtures build and run', built)
    sections = Bc2cppFixtureRuntime.sections(output)
    interpreted = sections['interpreted']
    compiled = sections['compiled']
    check.call('both runs reach the end', interpreted&.last == 'end' && compiled&.last == 'end')
    if interpreted && compiled
      interpreted.zip(compiled).reject { |a, b| a == b }.first(10).each { |a, b| puts "    interpreted: #{a}\n    compiled:    #{b}" }
    end
    # The last two lines yield inside an interpreted Fiber: a yield through compiled code needs a compiled Fiber body, so
    # they are FiberErrors here (the interpreted run suspends them in its VM frames).
    plain = 6
    check.call('the non-yielding blocks print what the interpreted runs print', interpreted&.first(plain) == compiled&.first(plain))
    check.call('a Fiber.yield across the compiled iterator is a FiberError', compiled&.values_at(plain, plain + 1)&.all? { |l| l.include?('FiberError') })
    puts output.lines.last(30).join unless built && interpreted && compiled
  end
end

if failures.empty?
  puts 'bc2cpp call from c check: PASS'
else
  warn "bc2cpp call from c check: #{failures.size} failure(s)"
  exit 1
end
