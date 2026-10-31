#!/usr/bin/env ruby
# frozen_string_literal: true

# ENUM_STEP for every case of Range#each (tools/bc2cpp/codegen_enum_step.rb, docs/bc2cpp-enum-step.md, "Range generic").
# With BC2CPP_ENUM_STEP=1 the step form covers the generic path (the receiver's succ and <=>, called from C), the String
# and bignum cases and the endless String case, so the driver keeps no fallback to mruby's body. The closed build then
# drops that body from its mrblib (bc2cpp_stub_top_mrblib). A user succ or <=> that calls Fiber.yield raises FiberError
# under the step (fiber_check_cfunc: a C frame is on the fiber's stack); the body let the Fiber.yield through, so those
# two scenarios are compared with their own expected lines, not with the body's.
#
#   generated code (needs a host mrbc)
#     - flag set: the Range step calls succ and <=> from C, the driver has no body fallback, and the core manifest lists
#       Range#each (its body may leave the binary);
#     - flag unset: the manifest does not list Range#each, and Range#each keeps its own saved body;
#     - the top-level mrblib copy of range.rb, with only Range#each emptied, compiles and keeps the other defs.
#   behaviour (needs a full-core libmruby, see Bc2cppFixtureRuntime.full_or_build)
#     - the interpreted run (mruby's body, Fiber-based through mruby-enumerator) and the compiled run (the step, flag set)
#       print the same over the scenarios, including the calls a user succ, <=> and exclude_end? see, in order;
#     - the compiled driver calls no body (no __bc2cpp_each_plain);
#     - a user succ or <=> that calls Fiber.yield raises FiberError in the compiled run.
#
# Usage: MRBC=path/to/mrbc [BC2CPP_MRUBY_FULL=dir | BC2CPP_FULL_BUILD_DIR=dir] [BC2CPP_TOOL=path/to/bc2cpp.rb] \
#          ruby scripts/bc2cpp/enum_step_range_generic_check.rb

require 'set'
require 'tmpdir'
require_relative 'fixture_runtime'
require_relative '../../tools/bc2cpp/mrblib_stubs'

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

# Both owners generate, as in enum_step_range_check.rb, so the Array form is checked alongside.
PROBE = <<~'RUBY'
  class EnumStepGenericProbe
    def first_of(r)
      r.each { |x| return x }
    end
  end
  class EnumStepArrayGenericProbe
    def first_of(a)
      a.each { |x| return x }
    end
  end

# Calls to succ, <=> and exclude_end? are logged while $enum_log is an Array (the dispatch-order scenarios).
class EnumStepGenericV
  attr_reader :n

  def initialize(n)
    @n = n
  end

  def succ
    $enum_log << [:succ, @n] if $enum_log
    EnumStepGenericV.new(@n + 1)
  end

  def <=>(other)
    $enum_log << [:cmp, @n] if $enum_log
    other.is_a?(EnumStepGenericV) ? @n <=> other.n : nil
  end

  def inspect
    "v#{@n}"
  end
end

class EnumStepGenericBad < EnumStepGenericV
  def succ
    raise RangeError, 'no succ'
  end
end

class EnumStepGenericYieldSucc < EnumStepGenericV
  def succ
    Fiber.yield [:inside_succ, @n]
    EnumStepGenericYieldSucc.new(@n + 1)
  end
end

class EnumStepGenericYieldCmp < EnumStepGenericV
  def succ
    EnumStepGenericYieldCmp.new(@n + 1)
  end

  def <=>(other)
    Fiber.yield [:inside_cmp, @n] if other.is_a?(EnumStepGenericV) && @n == 2
    super
  end
end

class EnumStepGenericLogged < Range
  def exclude_end?
    $enum_log << :excl if $enum_log
    super ? true : false
  end
end

RUBY

PLAIN_SAVE = /bc2cpp_core_save_interpreted\(M, bc2cpp_owner_reg_Range, false, "\\x65\\x61\\x63\\x68", \d+\)/
STEP_SAVE = /bc2cpp_enum_step_save\(M, bc2cpp_owner_reg_Range, false, "\\x65\\x61\\x63\\x68", \d+, bc2cpp_range_each_step, bc2cpp_range_each_open, bc2cpp_range_each_driver_src\)/

def generate_with(flag, dir)
  saved = ENV['BC2CPP_ENUM_STEP']
  saved_log = ENV['BC2CPP_STUB_LOG']
  flag ? ENV['BC2CPP_ENUM_STEP'] = '1' : ENV['BC2CPP_ENUM_STEP'] = '0'
  # The stub rule logs one line per compiled body it keeps, with the reason (MrblibStubs.stub_keep_log).
  ENV['BC2CPP_STUB_LOG'] = File.join(dir, 'stub.log')
  Bc2cppFixtureRuntime.generate(PROBE, dir, core: true, only_owners: %w[Array Range])
ensure
  saved ? ENV['BC2CPP_ENUM_STEP'] = saved : ENV.delete('BC2CPP_ENUM_STEP')
  saved_log ? ENV['BC2CPP_STUB_LOG'] = saved_log : ENV.delete('BC2CPP_STUB_LOG')
end

# The [reason, key] pairs the stub rule kept (one tab-separated line each).
def kept_reasons(dir)
  path = File.join(dir, 'stub.log')
  return [] unless File.exist?(path)

  File.readlines(path, chomp: true).map { |line| line.split("\t", 2) }
end

# Each scenario is one labelled line. The expected values are the body's own, which the interpreted run prints.
DRIVER = <<~'RUBY'
  def show(label)
    puts "#{label}: #{yield.inspect}"
  rescue StandardError, ScriptError => e
    puts "#{label}: raised #{e.class}: #{e.message}"
  end

  def stop_of(e)
    e.next
    :no_stop
  rescue StopIteration => s
    "StopIteration result=#{s.result.inspect}"
  end

  puts "mode: #{$bc2cpp_compiled ? 'compiled' : 'interpreted'} plain=#{Range.private_instance_methods.include?(:__bc2cpp_each_plain)} step=#{Range.private_instance_methods.include?(:__bc2cpp_each_step)}"

  show('string excl') { e = ('a'...'e').each; [e.next, e.next, e.next, e.next, stop_of(e)] }
  show('string incl') { e = ('a'..'c').each; [e.next, e.next, e.next, stop_of(e)] }
  show('endless string') { e = ('a'..).each; [e.next, e.next, e.next] }
  show('float range') { e = (1.0..3.0).each; e.next }
  show('beginless') { e = (..3).each; e.next }
  show('version exclusive') { e = (EnumStepGenericV.new(1)...EnumStepGenericV.new(3)).each; [e.next.n, e.next.n, stop_of(e)] }
  show('version inclusive') { e = (EnumStepGenericV.new(1)..EnumStepGenericV.new(2)).each; [e.next.n, e.next.n, stop_of(e)] }
  show('version reversed') { stop_of((EnumStepGenericV.new(3)..EnumStepGenericV.new(1)).each) }
  show('version equal exclusive') { stop_of((EnumStepGenericV.new(2)...EnumStepGenericV.new(2)).each) }
  show('version endless') { e = (EnumStepGenericV.new(1)..).each; [e.next.n, e.next.n] }
  show('bignum range') { e = (9223372036854775806..9223372036854775808).each; [e.next, e.next, e.next, stop_of(e)] }
  show('bignum begin') { e = (18446744073709551616..18446744073709551618).each; [e.next, e.next, e.next, stop_of(e)] }
  show('inclusive at max') { e = (9223372036854775806..9223372036854775807).each; [e.next, e.next, stop_of(e)] }
  show('endless past max') { e = (9223372036854775806..).each; [e.next, e.next, e.next] }
  show('peek rewind feed') do
    e = (EnumStepGenericV.new(1)..EnumStepGenericV.new(2)).each
    [e.peek.n, e.next.n, e.rewind.class, e.next.n]
  end
  show('feed generic') { e = (EnumStepGenericV.new(1)..EnumStepGenericV.new(2)).each; e.next; e.feed(:x); [e.next.n, stop_of(e)] }
  show('raise in generic fiber block') do
    fiber = Fiber.new do
      begin
        (EnumStepGenericV.new(1)..EnumStepGenericV.new(3)).each { |x| Fiber.yield x.n; raise ArgumentError, "boom #{x.n}" if x.n == 1 }
        :done
      rescue ArgumentError => ex
        "rescued #{ex.message}"
      end
    end
    [fiber.resume, fiber.resume]
  end
  show('raise in root generic block') { (EnumStepGenericV.new(1)..EnumStepGenericV.new(2)).each { |x| raise TypeError, "t#{x.n}" } }
  show('break in generic fiber') { Fiber.new { (EnumStepGenericV.new(1)..EnumStepGenericV.new(3)).each { |x| break x.n * 10 if x.n == 2 } }.resume }
  show('succ raises') { e = (EnumStepGenericBad.new(1)..EnumStepGenericBad.new(3)).each; [e.next.n, e.next.n] }
  show('root generic block') { acc = []; (EnumStepGenericV.new(1)..EnumStepGenericV.new(3)).each { |x| acc << x.n }; acc }
  show('endless generic') { acc = []; (EnumStepGenericV.new(1)..).each { |x| acc << x.n; break if acc.size == 2 }; acc }
  show('dispatch log exclusive') do
    $enum_log = []
    (EnumStepGenericV.new(1)...EnumStepGenericV.new(3)).each { |x| $enum_log << [:yield, x.n] }
    $enum_log.tap { $enum_log = nil }
  end
  show('dispatch log inclusive') do
    $enum_log = []
    (EnumStepGenericV.new(1)..EnumStepGenericV.new(2)).each { |x| $enum_log << [:yield, x.n] }
    $enum_log.tap { $enum_log = nil }
  end
  show('dispatch log subclass generic') do
    $enum_log = []
    EnumStepGenericLogged.new(EnumStepGenericV.new(1), EnumStepGenericV.new(2), true).each { |x| $enum_log << [:yield, x.n] }
    $enum_log.tap { $enum_log = nil }
  end
  show('dispatch log subclass integer') do
    $enum_log = []
    EnumStepGenericLogged.new(1, 2, false).each { |x| $enum_log << [:yield, x] }
    $enum_log.tap { $enum_log = nil }
  end
  show('dispatch log float end') do
    $enum_log = []
    EnumStepGenericLogged.new(1, 2.5, false).each { |x| $enum_log << [:yield, x] }
    $enum_log.tap { $enum_log = nil }
  end
  show('succ yields') { e = (EnumStepGenericYieldSucc.new(1)..EnumStepGenericYieldSucc.new(3)).each; [e.next.n, e.next] }
  show('cmp yields') do
    f = Fiber.new { (EnumStepGenericYieldCmp.new(1)..EnumStepGenericYieldCmp.new(3)).each { |x| Fiber.yield x.n } }
    [f.resume, f.resume]
  end
  # Last: String#upto is undefined for the rest of the run, so a String range takes the generic (succ and size) loop.
  show('string without upto') do
    String.send(:undef_method, :upto)
    e = ('a'...'d').each
    [e.next, e.next, e.next, stop_of(e)]
  end
  puts 'end'
RUBY

# Ruby's own result for each scenario, as the interpreted run prints it (the body's; MRI agrees where both define it).
EXPECTED = {
  'string excl' => '["a", "b", "c", "d", "StopIteration result=\"a\""]',
  'string incl' => '["a", "b", "c", "StopIteration result=\"a\""]',
  'endless string' => '["a", "b", "c"]',
  'float range' => 'raised TypeError: can\'t iterate',
  'beginless' => 'raised TypeError: can\'t iterate',
  'version exclusive' => '[1, 2, "StopIteration result=v1...v3"]',
  'version inclusive' => '[1, 2, "StopIteration result=v1..v2"]',
  'version reversed' => '"StopIteration result=v3..v1"',
  'version equal exclusive' => '"StopIteration result=v2...v2"',
  'version endless' => 'raised NoMethodError: undefined method \'>\' for NilClass',
  'bignum range' => '[9223372036854775806, 9223372036854775807, 9223372036854775808, "StopIteration result=9223372036854775806..9223372036854775808"]',
  'bignum begin' => '[18446744073709551616, 18446744073709551617, 18446744073709551618, "StopIteration result=18446744073709551616..18446744073709551618"]',
  'inclusive at max' => '[9223372036854775806, 9223372036854775807, "StopIteration result=9223372036854775806..9223372036854775807"]',
  'endless past max' => '[9223372036854775806, 9223372036854775807, 9223372036854775808]',
  'peek rewind feed' => '[1, 1, Enumerator, 1]',
  'feed generic' => '[2, "StopIteration result=v1..v2"]',
  'raise in generic fiber block' => '[1, "rescued boom 1"]',
  'raise in root generic block' => 'raised TypeError: t1',
  'break in generic fiber' => '20',
  'succ raises' => 'raised RangeError: no succ',
  'root generic block' => '[1, 2, 3]',
  'endless generic' => 'raised NoMethodError: undefined method \'>\' for NilClass',
  'dispatch log exclusive' => '[[:cmp, 1], [:cmp, 1], [:cmp, 1], [:yield, 1], [:succ, 1], [:cmp, 2], [:yield, 2], [:succ, 2], [:cmp, 3]]',
  'dispatch log inclusive' => '[[:cmp, 1], [:cmp, 1], [:cmp, 1], [:yield, 1], [:succ, 1], [:cmp, 2], [:cmp, 2], [:yield, 2]]',
  'dispatch log subclass generic' => '[[:cmp, 1], [:cmp, 1], [:cmp, 1], [:yield, 1], [:succ, 1], [:cmp, 2], :excl]',
  'dispatch log subclass integer' => '[:excl, [:yield, 1], [:yield, 2]]',
  'dispatch log float end' => '[[:yield, 1], [:yield, 2], :excl]',
  'string without upto' => '["a", "b", "c", "StopIteration result=\"a\"...\"d\""]'
}.freeze

# A user succ or <=> that suspends the fiber. The body (interpreted) lets the Fiber.yield through; the step cannot (a C
# frame is on the stack), so the compiled run must raise FiberError, and the interpreted run keeps the body's value.
SUSPENDING = {
  'succ yields' => { interpreted: '[1, [:inside_succ, 1]]',
                     compiled: 'raised FiberError: can\'t cross C function boundary' },
  'cmp yields' => { interpreted: '[1, [:inside_cmp, 2]]',
                    compiled: 'raised FiberError: can\'t cross C function boundary' }
}.freeze

dir = Dir.mktmpdir('bc2cpp-enum-step-range-generic')
at_exit { FileUtils.remove_entry(dir) }

puts '-- generated code'
on_dir = File.join(dir, 'on')
off_dir = File.join(dir, 'off')
FileUtils.mkdir_p([on_dir, off_dir])
on_code, on_err = generate_with(true, on_dir)
off_code, = generate_with(false, off_dir)
on_kept = kept_reasons(on_dir)
off_kept = kept_reasons(off_dir)
check.call('flag set: Range#each registers through bc2cpp_enum_step_save with the Range step and open', on_code.match?(STEP_SAVE))
check.call('flag set: the Range step calls succ and <=> from C (mrb_funcall)',
           on_code.include?('mrb_funcall(M, cur, "succ", 0)') && on_code.include?('mrb_funcall(M, cur, "<=>", 1, last)'))
check.call('flag set: the driver keeps no fallback to the body (no __bc2cpp_each_plain)', !on_code.include?('__bc2cpp_each_plain'))
check.call('flag set: the stub rule no longer keeps Range#each as guarded (only the copy by name is left)',
           !on_kept.include?(['guarded', 'Range#each']) && on_kept.include?(['copy by name', 'Range#each']))
check.call('flag set: the generated code has no #error', !on_code.include?('#error'))
check.call('flag unset: the stub rule keeps Range#each as guarded (the body stays)', off_kept.include?(['guarded', 'Range#each']))
check.call('flag unset: Range#each keeps its own saved body', off_code.match?(PLAIN_SAVE))

# The top-level mrblib copy the closed build compiles under the flag (bc2cpp_stub_top_mrblib): range.rb with only
# Range#each emptied. Its other defs must survive, and the copy must compile with the host mrbc.
range_rb = File.join(Bc2cppFixtureRuntime::ROOT, '3rd/mruby/mrblib/range.rb')
if File.exist?(range_rb)
  stubbed, stubbed_keys = MrblibStubs.rewrite(File.binread(range_rb), Set['Range#each'])
  check.call('the stubbed range.rb empties Range#each (raise ScriptError) and keeps the other bodies',
             stubbed_keys.to_a == ['Range#each'] && stubbed.include?('raise ScriptError') &&
             !stubbed.include?('block.call(val)') && stubbed.include?('def hash') && stubbed.include?('def to_a'))
  Dir.mktmpdir('bc2cpp-stubbed-range') do |tmp|
    copy = File.join(tmp, 'range.rb')
    File.binwrite(copy, stubbed)
    check.call('the stubbed range.rb compiles with the host mrbc',
               system(Bc2cppFixtureRuntime.mrbc, '-o', File.join(tmp, 'range.mrb'), copy, out: File::NULL, err: File::NULL))
  end
else
  puts "  SKIP the stubbed range.rb checks: #{range_rb} is missing (git submodule update --init 3rd/mruby)"
end

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
  same = ->(lines) { lines&.reject { |line| line.start_with?('mode: ') || SUSPENDING.key?(line.split(': ', 2).first) } }
  check.call('both runs reach the end', interpreted&.last == 'end' && compiled&.last == 'end')
  check.call('the interpreted run is interpreted without the step or a body alias',
             mode_line.call(interpreted)&.end_with?('step=false') && mode_line.call(interpreted)&.include?('plain=false'))
  check.call('the compiled run registers the step on Range', mode_line.call(compiled)&.end_with?('step=true'))
  check.call('the compiled run keeps no body alias (the step covers every case)', mode_line.call(compiled)&.include?('plain=false'))
  check.call('interpreted and compiled runs print the same (suspending succ and <=> excepted)',
             !interpreted.nil? && !compiled.nil? && same.call(interpreted) == same.call(compiled))
  if interpreted && compiled
    same.call(interpreted).zip(same.call(compiled)).reject { |a, b| a == b }.first(10)
                          .each { |a, b| puts "    interpreted: #{a}\n    compiled:    #{b}" }
    values = interpreted.filter_map { |line| line.split(': ', 2) if line.include?(': ') }.to_h
    compiled_values = compiled.filter_map { |line| line.split(': ', 2) if line.include?(': ') }.to_h
    EXPECTED.each do |label, expected|
      ok = values[label] == expected
      puts "    #{label}: expected #{expected}, got #{values[label]}" unless ok
      check.call("#{label} (Ruby's own result): #{expected}", ok)
    end
    SUSPENDING.each do |label, want|
      check.call("#{label}: the body lets the Fiber.yield through (interpreted): #{want[:interpreted]}",
                 values[label] == want[:interpreted])
      ok = compiled_values[label] == want[:compiled]
      puts "    #{label}: expected #{want[:compiled]}, got #{compiled_values[label]}" unless ok
      check.call("#{label}: the step raises FiberError, not a hang or a silent value (#{want[:compiled]})", ok)
    end
  end
  puts output.lines.last(30).join unless built && interpreted && compiled
end

if failures.empty?
  puts 'bc2cpp enum step range generic check: PASS'
else
  warn "bc2cpp enum step range generic check: #{failures.size} failure(s)"
  exit 1
end
