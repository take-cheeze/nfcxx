#!/usr/bin/env ruby
# encoding: UTF-8
# frozen_string_literal: true

# UNSIGNED_INDEX (tools/bc2cpp/codegen_emit.rb#emit_ary_entry_helper): the inline Array element read and write test
# 0 <= n < len as one unsigned compare, and the inline `x[i]` fronts test the fixnum tag only.
#
#   generated code (needs a host mrbc)
#     - bc2cpp_ary_entry reads the embed flag once and has no signed `n < 0` adjustment ahead of the bound test;
#     - bc2cpp_ary_set's fast path is the unsigned in-range store, a negative index takes mrb_ary_set;
#     - bc2cpp_getidx's front and a static-Array GETIDX arm test mrb_fixnum_p, not mrb_integer_p.
#   behaviour (needs a full-core libmruby, see Bc2cppFixtureRuntime.full_or_build)
#     - reads at every index class (in range, from the end, exactly -len, past either end, the fixnum extremes, a
#       heap Integer and a Float key) on embedded, heap, shared and empty Arrays, and writes in range, from the end,
#       past the end, before the start and on a frozen Array, print the same interpreted and compiled.
#
# Usage: MRBC=path/to/mrbc [BC2CPP_MRUBY_FULL=dir | BC2CPP_FULL_BUILD_DIR=dir] ruby scripts/bc2cpp/unsigned_index_check.rb

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
  class UiRow
    def initialize(n)
      @cells = []
      n.times { |i| @cells << i * 3 }
    end
    # @cells is only ever an Array: the static-Array GETIDX arm.
    def cell(i); @cells[i]; end
    # xs is whatever the caller passes: bc2cpp_getidx.
    def at(xs, i); xs[i]; end
    def put(i, v); @cells[i] = v; self; end
    def put_into(xs, i, v); xs[i] = v; xs; end
    def cells; @cells; end
  end
RUBY

OWNERS = %w[UiRow].freeze

def helper(code, name)
  code[/static inline \w+ #{name}\(.*?^}/m].to_s
end

def method_code(code, name)
  code[/^mrb_value #{name}_impl\(mrb_state\* M[^\n]*\{\n.*?^}/m].to_s
end

dir = Dir.mktmpdir('bc2cpp-unsigned-index')
at_exit { FileUtils.remove_entry(dir) }
puts '-- generated code'
code, err = Bc2cppFixtureRuntime.generate(SRC, dir, core: true, only_owners: OWNERS)
check.call('no #error in the generated code', !code.include?('#error'))
entry = helper(code, 'bc2cpp_ary_entry')
check.call('bc2cpp_ary_entry tests the bound as one unsigned compare',
           entry.include?('(mrb_uint)n < len)) return p[n];'))
check.call('bc2cpp_ary_entry reads the embed flag once and has no signed adjustment',
           entry.scan('ARY_EMBED_P(a)').size == 1 && !entry.include?('n += len') && !entry.include?('ARY_LEN('))
check.call('bc2cpp_ary_entry counts a negative index from the end in unsigned arithmetic',
           entry.include?('mrb_uint from_end = (mrb_uint)n + len;') &&
             entry.include?('return from_end < len ? p[from_end] : mrb_nil_value();'))
set = helper(code, 'bc2cpp_ary_set')
check.call('bc2cpp_ary_set stores in range only, everything else calls mrb_ary_set',
           set.include?('(mrb_uint)n < (mrb_uint)ARY_LEN(a)') && !set.include?('n + len') &&
             set.include?('mrb_ary_set(M, ary, n, val);'))
front = helper(code, 'bc2cpp_getidx')
check.call("bc2cpp_getidx's front tests the fixnum tag",
           front.include?('mrb_fixnum_p(key)') && front.include?('bc2cpp_ary_entry(M, recv, mrb_fixnum(key))') &&
             !front.include?('mrb_integer_p(key)'))
check.call("the outlined bc2cpp_getidx_slow keeps the Integer arm for a heap Integer key",
           code[/static mrb_value bc2cpp_getidx_slow\(.*?^}/m].to_s.include?('mrb_integer_p(key)'))
cell = method_code(code, 'UiRow_cell')
check.call('a static-Array GETIDX arm tests the fixnum tag',
           cell.match?(/mrb_fixnum_p\(r\d+\)\) \{\n\s*r\d+ = bc2cpp_ary_entry\(M, r\d+, mrb_fixnum\(r\d+\)\);/) &&
             !cell.include?('mrb_integer_p('))

DRIVER = <<~'RUBY'
  big = 2**64
  fmax = 2**62 - 1
  fmin = -2**62
  keys = [0, 1, 2, -1, -2, -3, -4, 3, 4, 7, 100, fmax, fmin, fmin + 1, big, -big, 1.0, -1.5]
  row = UiRow.new(6)
  small = UiRow.new(2)
  arrays = { 'empty' => [], 'one' => [:a], 'three' => [1, 2, 3], 'heap' => (0...10).to_a,
             'shared' => (0...20).to_a[5, 12], 'tail' => (0...20).to_a.drop(15) }
  def read
    yield
  rescue RangeError => e
    e.class
  end
  keys.each do |k|
    p [k, read { row.cell(k) }, read { small.cell(k) }]
    arrays.each { |name, xs| p [name, k, read { row.at(xs, k) }] }
  end
  [[1, :x], [-1, :y], [-6, :z], [8, :w]].each { |i, v| p row.put(i, v).cells }
  p row.put_into([1, 2, 3], -3, :q)
  p row.put_into((0...6).to_a, 2, :r)
  p row.put_into((0...20).to_a[2, 6], 1, :s)
  [-20, fmin, big].each do |i|
    begin
      row.put(i, 0)
    rescue IndexError, RangeError => e
      p [i, e.class]
    end
  end
  begin
    row.cells.freeze
    row.put(0, 1)
  rescue FrozenError => e
    p e.class
  end
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
        const char* src = R"UIC(#{DRIVER})UIC";
        mrb_load_string(M, src);
        std::fflush(stdout);
        if (M->exc) { mrb_print_error(M); M->exc = nullptr; return 1; }
        return 0;
      }
    CPP
    built, output = Bc2cppFixtureRuntime.run(dir, err, OWNERS, body, build: build, full: true)
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
  puts 'bc2cpp unsigned index check: PASS'
else
  warn "bc2cpp unsigned index check: #{failures.size} failure(s)"
  exit 1
end
