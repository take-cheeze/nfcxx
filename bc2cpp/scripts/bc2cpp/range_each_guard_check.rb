#!/usr/bin/env ruby
# encoding: UTF-8
# frozen_string_literal: true

# RANGE_EACH_GUARD (tools/bc2cpp/codegen_loop_inline.rb emit_range_each_inline): an inlined `(a..b).each { }` proves
# its receiver a Range but not its bounds Integers. A String, Float or bigint bound used to hit a tripwire
# (`TypeError: non-Integer Range#each left to interpreter`); the counter loop now runs only for Integer bounds and
# every other Range takes the ordinary send.
#
#   generated code (needs a host mrbc)
#     - every fixture `each` gets the guarded loop, the send label behind it, and no tripwire (one in a rescue
#       try body, which has no place for the send, keeps the send alone);
#   behaviour (needs a full-core libmruby, see Bc2cppFixtureRuntime.full_or_build)
#     - interpreted and compiled runs print the same over String, Float, bigint and Integer bounds, including the
#       Fixnum and mrb_int edges (RANGE_EACH_INT_MAX: an inclusive end at MRB_INT_MAX is the interpreter's).
#
# Usage: MRBC=path/to/mrbc [BC2CPP_MRUBY_FULL=dir | BC2CPP_FULL_BUILD_DIR=dir] ruby scripts/bc2cpp/range_each_guard_check.rb

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
  class RegBox
    def lit_str; r = []; ('a'...'c').each { |x| r << x }; r; end
    def lit_flt; r = []; (1..3.5).each { |x| r << x }; r; end
    def lit_big; r = []; (0x1_0000_0000_0000_0000..0x1_0000_0000_0000_0002).each { |x| r << x }; r; end
    def var(a, b); r = []; (a..b).each { |x| r << x }; r; end
    def xvar(a, b); r = []; (a...b).each { |x| r << x }; r; end
    def cnt(a, b); n = 0; (a..b).each { |x| n += 1 }; [n, b - a]; end
    def ret(a, b); (a..b).each { |x| return x if x == b }; :none; end
    def brk(a, b); (a..b).each { |x| break x if x == b }; end
    def resc(a, b)
      r = []
      begin
        (a..b).each { |x| r << x }
      rescue TypeError => e
        r << e.message
      end
      r
    end
  end
  class RegUse
    IMAX = 0x7fff_ffff_ffff_ffff
    IMIN = -IMAX - 1
    FMAX = 0x3fff_ffff_ffff_ffff
    CALLS = [[:lit_str], [:lit_flt], [:lit_big], [:var, 1, 3], [:var, 'x', 'z'], [:var, 1, 2.5], [:xvar, 1, 4],
             [:xvar, 1.0, 3], [:var, 0x1_0000_0000_0000_0000, 0x1_0000_0000_0000_0001], [:ret, 'a', 'c'], [:ret, 1, 3],
             [:brk, 'a', 'b'], [:brk, 2, 4], [:resc, 'a', 'b'], [:resc, 1, 2], [:resc, 1.0, 2],
             # The mrb_int and Fixnum edges: mrblib's `lim = last + 1` is a bigint at MRB_INT_MAX.
             [:var, IMAX - 2, IMAX], [:cnt, IMAX - 600, IMAX], [:xvar, IMAX - 2, IMAX], [:brk, IMAX - 2, IMAX],
             [:ret, IMAX - 1, IMAX], [:var, FMAX - 1, FMAX + 1], [:xvar, FMAX - 1, FMAX + 1], [:var, IMIN, IMIN + 2],
             [:xvar, IMIN, IMIN + 2]].freeze
    def run
      CALLS.map do |m, *args|
        begin
          RegBox.new.send(m, *args).inspect
        rescue StandardError => e
          "#{e.class}: #{e.message}"
        end
      end
    end
  end
RUBY

OWNERS = %w[RegBox RegUse].freeze
METHODS = %w[lit_str lit_flt lit_big var xvar cnt ret brk].freeze

def method_code(code, name)
  code[/^mrb_value #{name}_impl\(mrb_state\* M.*?(?=^(?:static )?mrb_value \w+\(mrb_state\* M|\z)/m].to_s
end

dir = Dir.mktmpdir('bc2cpp-range-each-guard')
at_exit { FileUtils.remove_entry(dir) }
puts '-- generated code'
code, err = Bc2cppFixtureRuntime.generate(SRC, dir, core: true, only_owners: OWNERS)
check.call('no #error in the generated code', !code.include?('#error'))
check.call('no non-Integer Range#each tripwire is left', !code.include?('non-Integer Range#each'))
METHODS.each do |name|
  body = method_code(code, "RegBox_#{name}")
  guard = body[/goto (Lbc2cpp_range_send_\d+);/, 1]
  check.call("RegBox##{name}: the counter loop runs behind the Integer-bounds guard, the send behind it",
             body.include?('RANGE_EACH_GUARD :each') && guard && body.include?("#{guard}:;") &&
               body.match?(/Lbc2cpp_range_after_\d+:;/))
  check.call("RegBox##{name}: an inclusive end at MRB_INT_MAX takes the send (RANGE_EACH_INT_MAX)",
             guard && body.match?(/== MRB_INT_MAX\) goto #{guard};/))
end

DRIVER = <<~'RUBY'
  RegUse.new.run.each_with_index { |line, i| puts "#{RegUse::CALLS[i].inspect}: #{line}" }
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
        const char* src = R"REG(#{DRIVER})REG";
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
    check.call('a String-bounded Range iterates as the interpreter does',
               interpreted.to_a.include?('[:var, "x", "z"]: ["x", "y", "z"]'))
    check.call('interpreted and compiled runs print the same', interpreted == compiled)
    if interpreted && compiled
      interpreted.zip(compiled).reject { |a, b| a == b }.first(10).each { |a, b| puts "    interpreted: #{a}\n    compiled:    #{b}" }
    end
    puts output.lines.last(30).join unless built && interpreted && compiled
  end
end

if failures.empty?
  puts 'bc2cpp range each guard check: PASS'
else
  warn "bc2cpp range each guard check: #{failures.size} failure(s)"
  exit 1
end
