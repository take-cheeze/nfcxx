#!/usr/bin/env ruby
# encoding: UTF-8
# frozen_string_literal: true

# ROTATE_SMALL_SHIFT: the NATIVE_CORE_DIRECT `rotate!` mirror (bc2cpp_ary_rotate_bang, tools/bc2cpp/native_core_direct.rb)
# moves a shift whose short side fits BC2CPP_ROTATE_SMALL_MAX through a stack buffer and memmove instead of the triple
# reversal, which stays for longer shifts.
#
#   generated code (needs a host mrbc)
#     - the mirror keeps mrb_ary_modify ahead of both buffered branches, the reversal after them;
#   behaviour (needs a full-core libmruby, see Bc2cppFixtureRuntime.full_or_build)
#     - interpreted and compiled runs print the same for every shift of embedded and heap arrays (short side inside
#       and past the bound, both directions, n beyond len), empty, frozen, shared and dup'd receivers, non-Integer and
#       bigint counts, and under GC.stress.
#
# Usage: MRBC=path/to/mrbc [BC2CPP_MRUBY_FULL=dir | BC2CPP_FULL_BUILD_DIR=dir] ruby scripts/bc2cpp/rotate_small_shift_check.rb

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
  class RsBuf
    attr_reader :bg
    def initialize
      @bg = [0] * 16
    end
    def rotate_by(a, k); a.rotate!(k); end
    def rotate_one(a); a.rotate!; end
    def tile(lut, k)
      @bg.rotate!(8)
      @bg[k, 8] = lut
    end
  end
RUBY

OWNERS = %w[RsBuf].freeze

dir = Dir.mktmpdir('bc2cpp-rotate-small-shift')
at_exit { FileUtils.remove_entry(dir) }
puts '-- generated code'
code, err = Bc2cppFixtureRuntime.generate(SRC, dir, core: true, only_owners: OWNERS)
check.call('no #error in the generated code', !code.include?('#error'))
helper = code[/static inline mrb_value bc2cpp_ary_rotate_bang\(.*?\n\}\n/m].to_s
check.call('the rotate! site calls the mirror', code.include?('bc2cpp_ary_rotate_bang(M, r'))
modify = helper.index('mrb_ary_modify(M, a);')
small = helper.index('if (idx <= BC2CPP_ROTATE_SMALL_MAX)')
rest = helper.index('if (rest <= BC2CPP_ROTATE_SMALL_MAX)')
rev = helper.index('bc2cpp_ary_rev(p, 0, len);')
check.call('mrb_ary_modify runs before either buffered branch, the triple reversal after them',
           modify && small && rest && rev && modify < small && small < rest && rest < rev)
check.call('the bound is 16 values', code.include?('#define BC2CPP_ROTATE_SMALL_MAX 16'))

DRIVER = <<~'RUBY'
  show = lambda do |name, &blk|
    out = begin
      blk.call.inspect
    rescue Exception => e
      "#{e.class}: #{e.message}"
    end
    puts "#{name}: #{out}"
  end
  b = RsBuf.new
  # Lengths around the embedded capacity and the bound; counts of every short-side size, both signs, past len.
  [1, 2, 3, 5, 16, 17, 33, 40, 64].each do |len|
    ks = ((-len - 3)..(len + 3)).to_a + [len * 5 + 2, -len * 7 - 1, 1 << 40, -(1 << 40)]
    show.call("len #{len}") do
      ks.map do |k|
        a = (0...len).map { |i| "v#{i}" }
        r = b.rotate_by(a, k)
        [k, r.equal?(a), a.join(',')]
      end
    end
  end
  show.call('one') { [b.rotate_one((1..3).to_a), b.rotate_one((1..40).to_a).first(3)] }
  show.call('empty') { [b.rotate_by([], 0), b.rotate_by([], 3), b.rotate_by([], -2), b.rotate_one([])] }
  show.call('zero') { a = (1..20).to_a; [b.rotate_by(a, 0).equal?(a), a] }
  show.call('bignum') { b.rotate_by((1..5).to_a, 1 << 64) }
  show.call('float') { b.rotate_by([1, 2, 3], 1.0) }
  show.call('nil') { b.rotate_by([1, 2, 3], nil) }
  show.call('frozen') { b.rotate_by([1, 2].freeze, 1) }
  show.call('frozen zero') { b.rotate_by([1, 2].freeze, 0) }
  show.call('frozen empty') { b.rotate_by([].freeze, 1) }
  show.call('shared slice') { a = (1..60).to_a; s = a[2, 40]; b.rotate_by(s, 3); [s.first(4), s.last(4), a.first(6), a.size] }
  show.call('shared slice long') { a = (1..60).to_a; s = a[2, 40]; b.rotate_by(s, -38); [s.first(4), a.first(6)] }
  show.call('dup') { a = (1..40).to_a; d = a.dup; b.rotate_by(d, 5); [d.first(6), a.first(6)] }
  show.call('dup back') { a = (1..40).to_a; d = a.dup; b.rotate_by(a, -2); [a.first(3), d.first(3)] }
  show.call('tile') { lut = (1..8).to_a; 6.times { |k| b.tile(lut.map { |x| x * (k + 1) }, k) }; b.bg }
  show.call('gc') do
    GC.stress = true if GC.respond_to?(:stress=)
    out = [3, 18, 40].map do |len|
      a = (0...len).map { |i| "s#{i}" }
      [1, 7, -7, len - 2, 20].each { |k| b.rotate_by(a, k); a << "n#{k}"; a.shift }
      a.join(',')
    end
    GC.stress = false if GC.respond_to?(:stress=)
    out
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
        const char* src = R"RSS(#{DRIVER})RSS";
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
  puts 'bc2cpp rotate small shift check: PASS'
else
  warn "bc2cpp rotate small shift check: #{failures.size} failure(s)"
  exit 1
end
