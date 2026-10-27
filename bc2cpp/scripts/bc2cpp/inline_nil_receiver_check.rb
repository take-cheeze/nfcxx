#!/usr/bin/env ruby
# encoding: UTF-8
# frozen_string_literal: true

# INLINE_NIL_RECEIVER (tools/bc2cpp/codegen_loop_inline.rb inline_receiver_guard): an inlined block loop over an
# ivar the class hint names Array or Hash is entered with no class guard, but an ivar no path has assigned yet is nil.
# Its tripwire raised `TypeError: bc2cpp: expected Array receiver for inlined #each` where the interpreter raises
# `NoMethodError: undefined method 'each' for NilClass`; nil now takes the send's own NoMethodError first.
#
#   generated code (needs a host mrbc)
#     - `@h.each`, `@h.each_with_index`, `@h.map`, `@h.select`, `@h.inject(0)`, `@g.each`, `@g.each_value` and
#       `@g.each_key` test nil (bc2cpp_nil_receiver) ahead of the tripwire;
#   behaviour (needs a full-core libmruby, see Bc2cppFixtureRuntime.full_or_build)
#     - interpreted and compiled runs print the same with the ivars assigned and with them left nil.
#
# Usage: MRBC=path/to/mrbc [BC2CPP_MRUBY_FULL=dir | BC2CPP_FULL_BUILD_DIR=dir] ruby scripts/bc2cpp/inline_nil_receiver_check.rb

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
  class InrBox
    def initialize(fill)
      @h = [] if fill
      @g = { 1 => 2 } if fill
    end
    def push(x); @h << x; end
    def each_sum; r = 0; @h.each { |v| r += v }; r; end
    def ewi; r = []; @h.each_with_index { |v, i| r << [v, i] }; r; end
    def map1; @h.map { |v| v + 1 }; end
    def sel; @h.select { |v| v > 1 }; end
    def fold; @h.inject(0) { |s, v| s + v }; end
    def heach; r = 0; @g.each { |_k, v| r += v }; r; end
    def hval; r = 0; @g.each_value { |v| r += v }; r; end
    def hkey; r = []; @g.each_key { |k| r << k }; r; end
  end
  class InrUse
    METHODS = %i[each_sum ewi map1 sel fold heach hval hkey].freeze
    def run(fill)
      b = InrBox.new(fill)
      b.push(2) if fill
      METHODS.map do |m|
        begin
          b.send(m).inspect
        rescue StandardError => e
          "#{e.class}: #{e.message}"
        end
      end
    end
  end
RUBY

OWNERS = %w[InrBox InrUse].freeze
CASES = { 'InrBox_each_sum' => 'each', 'InrBox_ewi' => 'each_with_index', 'InrBox_map1' => 'map',
          'InrBox_sel' => 'select', 'InrBox_fold' => 'inject', 'InrBox_heach' => 'each', 'InrBox_hval' => 'each_value',
          'InrBox_hkey' => 'each_key' }.freeze

def method_code(code, name)
  code[/^mrb_value #{name}_impl\(mrb_state\* M.*?(?=^(?:static )?mrb_value \w+\(mrb_state\* M|\z)/m].to_s
end

dir = Dir.mktmpdir('bc2cpp-inline-nil')
at_exit { FileUtils.remove_entry(dir) }
puts '-- generated code'
code, err = Bc2cppFixtureRuntime.generate(SRC, dir, core: true, only_owners: OWNERS)
check.call('no #error in the generated code', !code.include?('#error'))
CASES.each do |fn, name|
  tripwires = method_code(code, fn).lines.grep(/receiver for inlined/)
  nil_arm = %r{if \(mrb_nil_p\((\w+)\)\) bc2cpp_nil_receiver\(M, \1, \d+\); /\* CLOSED_WORLD nil-receiver: #{name} \*/ mrb_raise}
  check.call("#{fn}: each inline loop tests nil ahead of its tripwire",
             !tripwires.empty? && tripwires.all? { |line| line.match?(nil_arm) })
end

DRIVER = <<~'RUBY'
  u = InrUse.new
  [true, false].each { |fill| u.run(fill).each_with_index { |line, i| puts "#{fill} #{InrUse::METHODS[i]}: #{line}" } }
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
        const char* src = R"INR(#{DRIVER})INR";
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
    check.call('a nil ivar raises the NoMethodError the interpreter raises',
               interpreted.to_a.any? { |l| l.include?("NoMethodError: undefined method 'each' for NilClass") })
    check.call('interpreted and compiled runs print the same', interpreted == compiled)
    if interpreted && compiled
      interpreted.zip(compiled).reject { |a, b| a == b }.first(10).each { |a, b| puts "    interpreted: #{a}\n    compiled:    #{b}" }
    end
    puts output.lines.last(30).join unless built && interpreted && compiled
  end
end

if failures.empty?
  puts 'bc2cpp inline nil receiver check: PASS'
else
  warn "bc2cpp inline nil receiver check: #{failures.size} failure(s)"
  exit 1
end
