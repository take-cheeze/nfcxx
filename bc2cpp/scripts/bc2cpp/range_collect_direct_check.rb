#!/usr/bin/env ruby
# encoding: UTF-8
# frozen_string_literal: true

# RANGE_COLLECT_DIRECT (tools/bc2cpp/codegen_collect_direct.rb): a literal-block `map`/`each` on an exact Range
# whose bounds are Integers at run time calls bc2cpp_range_collect / bc2cpp_range_each, a counted loop into the
# block's direct entry, instead of the compiled Enumerable#collect (Range#each, a `|*val|` block and two Arrays per
# element) or Range#each. Any other Range takes the compiled body behind the bound test.
#
#   generated code (needs a host mrbc)
#     - a Range map/each nested in an inlined loop body, and one over computed bounds, take the helper behind
#       bc2cpp_range_int_p, with the compiled core body as the else;
#     - the helper decodes the block before its loop and cuts the arena back after each store;
#     - BC2CPP_RANGE_COLLECT_DIRECT=0 keeps the compiled core calls;
#     - a program definition of a name Range#each calls (`exclude_end?`) withdraws the helpers;
#   behaviour (needs a full-core libmruby, see Bc2cppFixtureRuntime.full_or_build)
#     - interpreted and compiled runs print the same for inclusive, exclusive, empty, reversed and negative
#       Ranges, bounds at the Fixnum edge, Float, String, bigint and endless Ranges, break/next/return from the
#       block, an exception in the block, block arity (none, two parameters, a splat), outer locals read and
#       reassigned, a Range subclass, GC.stress and a Fiber.
#
# Usage: MRBC=path/to/mrbc [BC2CPP_MRUBY_FULL=dir | BC2CPP_FULL_BUILD_DIR=dir] ruby scripts/bc2cpp/range_collect_direct_check.rb

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

SRC = <<~'RUBY'
  class RcList < Range
    def tag; :sub; end
  end
  class RcMaps
    # The optcarrot APU::Noise shape: the Range map sits in an inlined Array#map body.
    def bits(n); [1, 2].map { |s| (0..n).map { |b| b[0] == b[s] ? b / 2 : b / 2 + 4 } }; end
    def nested_x(n); [3].map { |s| (0...n).map { |i| i * s } }; end
    def each_in(lo, hi); acc = []; [10, 20].each { |k| (lo..hi).each { |i| acc << k + i } }; acc; end
    def computed(r); [0].map { r.map { |i| i * 2 } }.first; end
    def each_r(r); acc = []; [0].each { r.each { |i| acc << i } }; acc; end
    def brk(r); [0].map { r.map { |i| break [:early, i] if i == 3; i } }.first; end
    def brk_each(r); [0].map { r.each { |i| break i * 100 if i == 2 } }.first; end
    def nxt(r); [0].map { r.map { |i| next :odd if i.odd?; i } }.first; end
    def ret(r); [0].each { r.each { |i| return [:ret, i] if i == 2 } }; :none; end
    def raises(r); [0].map { r.map { |i| raise ArgumentError, "at #{i}" if i == 2; i } }.first; end
    def arity0(r); n = 0; [0].each { r.each { n += 1 } }; n; end
    def arity2(r); [0].map { r.map { |a, b| [a, b] } }.first; end
    def splat(r); [0].map { r.map { |*a| a } }.first; end
    def outer(r)
      sum = 0
      last = nil
      [1].each { |k| r.each { |i| sum += i * k; last = i } }
      [sum, last]
    end
    def fresh(r); [0].map { r.map { |i| [i, i.to_s * 3] } }.first; end
  end
RUBY

OWNERS = %w[RcList RcMaps].freeze

# The method's body and the cfuncs its blocks became (`<name>_block_fallback_*`, `<name>_inline_*`).
def method_code(code, name)
  code.scan(/^(?:static )?mrb_value #{name}_(?:impl|block_fallback_\w+|inline_\w+)\(mrb_state\* M.*?(?=^(?:static )?mrb_value \w+\(mrb_state\* M|\z)/m).join
end

def generate_world(src, env = {})
  saved = env.keys.to_h { |k| [k, ENV.fetch(k, nil)] }
  env.each { |k, v| ENV[k] = v }
  Dir.mktmpdir { |dir| Bc2cppFixtureRuntime.generate(src, dir, core: true, only_owners: OWNERS) }
ensure
  saved&.each { |k, v| v.nil? ? ENV.delete(k) : ENV[k] = v }
end

baseline_dir = Dir.mktmpdir('bc2cpp-range-collect-direct')
at_exit { FileUtils.remove_entry(baseline_dir) }
puts '-- generated code'
code, baseline_err = Bc2cppFixtureRuntime.generate(SRC, baseline_dir, core: true, only_owners: OWNERS)
# A block with `break` or a method `return` keeps its heap RProc (the site's frame token lives in it).
BLK = '(?:bc2cpp_blk_stack_\d+\.value\(\)|mrb_obj_value\(bc2cpp_blk_proc_\d+\))'
COLLECT_ARM = /= bc2cpp_range_int_p\(M, (r\d+)\) \? bc2cpp_range_collect\(M, \1, #{BLK}\) : Enumerable_collect_impl\(M, \1, /
EACH_ARM = /= bc2cpp_range_int_p\(M, (r\d+)\) \? bc2cpp_range_each\(M, \1, #{BLK}\) : Range_each_impl\(M, \1, /
check.call('the Range helpers are emitted',
           code.include?('static mrb_value bc2cpp_range_collect(') && code.include?('static mrb_value bc2cpp_range_each('))
%w[bits nested_x computed brk nxt raises arity2 splat fresh].each do |fn|
  check.call("RcMaps##{fn}: Range map takes bc2cpp_range_collect behind the bound test",
             method_code(code, "RcMaps_#{fn}").match?(COLLECT_ARM))
end
%w[each_in each_r brk_each ret arity0 outer].each do |fn|
  check.call("RcMaps##{fn}: Range each takes bc2cpp_range_each behind the bound test",
             method_code(code, "RcMaps_#{fn}").match?(EACH_ARM))
end
check.call('no #error in the generated code', !code.include?('#error'))
helper = code[/static mrb_value bc2cpp_range_collect\(.*?^}/m].to_s
loop_body = helper[/for \(mrb_int i = a;.*\z/m].to_s
check.call('bc2cpp_range_collect decodes the block before its loop and cuts the arena back after each store',
           helper.index('bc2cpp_range_block_entry(blk, &env)').to_i < helper.index('for (mrb_int i = a;').to_i &&
             loop_body.include?('entry(M, env, false, 1, &v)') &&
             loop_body.index('mrb_ary_push(M, acc, r)').to_i < loop_body.index('mrb_gc_arena_restore(M, ai)').to_i)
off, = generate_world(SRC, 'BC2CPP_RANGE_COLLECT_DIRECT' => '0')
check.call('BC2CPP_RANGE_COLLECT_DIRECT=0: no Range helper', !off.include?('bc2cpp_range_int_p('))
redefined, = generate_world("#{SRC}class Range\n  def exclude_end?; false; end\nend\n")
check.call('a program Range#exclude_end? withdraws the Range helpers', !redefined.include?('bc2cpp_range_int_p('))

DRIVER = <<~'RUBY'
  show = lambda do |name, &blk|
    out = begin
      blk.call.inspect
    rescue Exception => e
      "#{e.class}: #{e.message}"
    end
    puts "#{name}: #{out}"
  end
  m = RcMaps.new
  big = 2**70
  max = 2**62 - 1
  imax = 2**63 - 1
  ranges = [1..4, 1...4, 0..0, 0...0, 3..1, -3..-1, -2...2, (max - 2)..max, (max - 2)...max, (imax - 2)..imax, (imax - 2)...imax, 1.0..3.0, 1..2.5,
            'a'..'c', 'a'...'c', big..(big + 2), RcList.new(1, 3), RcList.new(1, 3, true)]
  ranges.each do |r|
    label = "#{r.class} #{r.inspect}"
    show.call("computed #{label}") { m.computed(r) }
    show.call("each #{label}") { m.each_r(r) }
    show.call("outer #{label}") { m.outer(r) }
    show.call("arity0 #{label}") { m.arity0(r) }
  end
  show.call('bits') { m.bits(15) }
  show.call('nested exclusive') { m.nested_x(5) }
  show.call('each nested') { m.each_in(1, 3) }
  show.call('each nested empty') { m.each_in(3, 1) }
  show.call('endless break') { m.brk(1..) }
  show.call('endless each break') { m.brk_each(0..) }
  show.call('huge break') { m.brk(0..(2**61)) }
  show.call('break') { [m.brk(0..5), m.brk(0..2)] }
  show.call('break each') { [m.brk_each(0..5), m.brk_each(0..1)] }
  show.call('next') { m.nxt(0..5) }
  show.call('return') { [m.ret(0..5), m.ret(0..1)] }
  show.call('raise') { m.raises(0..5) }
  show.call('raise float') { m.raises(0.5..1.5) }
  show.call('arity2') { m.arity2(1..3) }
  show.call('splat') { m.splat(1..3) }
  show.call('gc stress') do
    GC.stress = true if GC.respond_to?(:stress=)
    out = m.fresh(1..200).last(2) + [m.fresh(1..300).map(&:last).join.size, m.bits(31).flatten.sum]
    GC.stress = false if GC.respond_to?(:stress=)
    out
  end
  f = Fiber.new do
    a = m.computed(1..3)
    Fiber.yield a
    m.each_r(4..6)
  end
  show.call('fiber') { [f.resume, f.resume] }
  puts 'end'
RUBY

if ENV['CC_GENERATED_ONLY'] == '1'
  puts '  SKIP behavioural comparison: CC_GENERATED_ONLY'
else
  build = Bc2cppFixtureRuntime.full_or_build
  if build.nil?
    puts '  SKIP behavioural comparison: needs a full-core libmruby (BC2CPP_MRUBY_FULL, or rake, g++ and 3rd/mruby)'
  else
    puts '-- fixtures on real mruby, interpreted and compiled'
    body = <<~CPP
      static int scenario(mrb_state* M) {
        std::fflush(stdout);
        const char* src = R"RCD(#{DRIVER})RCD";
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
    check.call("the driver prints #{interpreted&.size} lines in both runs",
               interpreted && interpreted.last == 'end' && compiled&.last == 'end')
    check.call('interpreted and compiled runs print the same', interpreted == compiled)
    if interpreted && compiled
      interpreted.zip(compiled).reject { |a, b| a == b }.first(10).each { |a, b| puts "    interpreted: #{a}\n    compiled:    #{b}" }
    end
    puts output.lines.last(30).join unless built && interpreted && compiled
  end
end

if failures.empty?
  puts 'bc2cpp range collect direct check: PASS'
else
  warn "bc2cpp range collect direct check: #{failures.size} failure(s)"
  exit 1
end
