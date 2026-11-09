#!/usr/bin/env ruby
# encoding: UTF-8
# frozen_string_literal: true

# HOT_INLINE (tools/bc2cpp/bc2cpp.rb): the per-element Array helpers are always inlined, except in a build
# optimized for size.
#
#   generated code (needs a host mrbc)
#     - bc2cpp_ary_entry, bc2cpp_ary_push, bc2cpp_ary_set and bc2cpp_getidx's inline front carry
#       BC2CPP_HOT_INLINE, which the prologue defines before any of them;
#     - the macro is always_inline under -O2 and empty under -Os (needs g++).
#   behaviour (needs a full-core libmruby, see Bc2cppFixtureRuntime.full_or_build)
#     - interpreted and compiled runs print the same.
#
# Usage: MRBC=path/to/mrbc [BC2CPP_MRUBY_FULL=dir | BC2CPP_FULL_BUILD_DIR=dir] ruby scripts/bc2cpp/hot_inline_check.rb

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

SRC = <<~'RUBY'
  class HiRow
    def initialize(n)
      @cells = []
      n.times { |i| @cells << i * 2 }
    end
    def get(i, xs); [@cells[i], xs[i]]; end
    def put(i, v); @cells[i] = v; self; end
    def push(v); @cells << v; self; end
    def cells; @cells; end
  end
RUBY

OWNERS = %w[HiRow].freeze
HELPERS = ['static inline mrb_value bc2cpp_ary_entry(', 'static inline void bc2cpp_ary_push(',
           'static inline void bc2cpp_ary_set(', 'static inline mrb_value bc2cpp_getidx('].freeze
MACRO = /^#if defined\(__GNUC__\) && !defined\(__OPTIMIZE_SIZE__\)\n#define BC2CPP_HOT_INLINE .*?^#endif\n/m

baseline_dir = Dir.mktmpdir('bc2cpp-hot-inline')
at_exit { FileUtils.remove_entry(baseline_dir) }
puts '-- generated code'
code, baseline_err = Bc2cppFixtureRuntime.generate(SRC, baseline_dir, core: true, only_owners: OWNERS)
macro = code[MACRO]
check.call('the prologue defines BC2CPP_HOT_INLINE', !macro.nil?)
HELPERS.each do |helper|
  at = code.index(helper)
  check.call("#{helper[/bc2cpp_\w+/]} is emitted with BC2CPP_HOT_INLINE, after the definition",
             at && code[0...at].end_with?('BC2CPP_HOT_INLINE ') && code.index(MACRO) < at)
end
check.call('no #error in the generated code', !code.include?('#error'))

if macro && system('g++', '--version', out: File::NULL, err: File::NULL)
  expand = lambda do |flag|
    out, status = Open3.capture2('g++', flag, '-E', '-P', '-x', 'c++', '-', stdin_data: "#{macro}BC2CPP_HOT_INLINE\n")
    status.success? ? out.strip : nil
  end
  check.call('the macro is always_inline under -O2', expand.call('-O2') == '__attribute__((always_inline))')
  check.call('the macro is empty under -Os', expand.call('-Os') == '')
else
  puts '  SKIP macro expansion: needs g++'
end

DRIVER = <<~'RUBY'
  r = HiRow.new(4)
  p r.get(2, [7, 8, 9])
  p r.get(-1, [1])
  p r.get(10, [])
  p r.put(1, :x).push('s').cells
  p r.put(-2, 5).cells
  p r.put(8, 1).cells
  begin
    r.cells.freeze
    r.push(1)
  rescue => e
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
        const char* src = R"HIC(#{DRIVER})HIC";
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
  puts 'bc2cpp hot inline check: PASS'
else
  warn "bc2cpp hot inline check: #{failures.size} failure(s)"
  exit 1
end
