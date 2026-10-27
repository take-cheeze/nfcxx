#!/usr/bin/env ruby
# encoding: UTF-8
# frozen_string_literal: true

# INTEGER_BIT_AREF (tools/bc2cpp/codegen_integer_bit_aref.rb): `n[i]` on a Fixnum reads the bit inline when the
# program's only Integer#[] is `(self >> i) & 1`, instead of bc2cpp_getidx_slow's POLY chain into the compiled body.
#
#   generated code (needs a host mrbc)
#     - bc2cpp_getidx carries the arm after its Array test;
#     - a receiver NumericFlow proves Integer gets the arm at the site, ahead of the generic tests;
#     - a different Integer#[] body, a program Integer#>>, a module prepended into Integer and
#       BC2CPP_INTEGER_BIT_AREF=0 each keep the generic path;
#   behaviour (needs a full-core libmruby, see Bc2cppFixtureRuntime.full_or_build)
#     - interpreted and compiled runs print the same for positive and negative Fixnums, indices 0, past the
#       sign bit, negative, bignum and Float, and Array, Hash, String and program receivers.
#
# Usage: MRBC=path/to/mrbc [BC2CPP_MRUBY_FULL=dir | BC2CPP_FULL_BUILD_DIR=dir] ruby scripts/bc2cpp/integer_bit_aref_check.rb

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

SHIM = <<~'RUBY'
  # optcarrot's shim (tools/optcarrot_probe/shim_integer_aref.rb): the full-core build has no Integer#[].
  class Integer
    def [](i)
      (self >> i) & 1
    end
  end
RUBY

PROGRAM = <<~'RUBY'
  class IbBox
    def [](i); i * 10; end
  end
  class IbBits
    def bit(x, i); x[i]; end
    def each_bit(xs, i); xs.map { |x| x[i] }; end
    def low_bits(n)
      out = []
      i = 0
      while i < n
        out << i[0] + i[1] * 2
        i += 1
      end
      out
    end
  end
RUBY

SRC = SHIM + PROGRAM
OWNERS = %w[Integer IbBox IbBits].freeze

def method_code(code, name)
  code[/^mrb_value #{name}_impl\(mrb_state\* M.*?(?=^(?:static )?mrb_value \w+\(mrb_state\* M|\z)/m].to_s
end

def generate_world(src, env = {})
  saved = env.keys.to_h { |k| [k, ENV.fetch(k, nil)] }
  env.each { |k, v| ENV[k] = v }
  Dir.mktmpdir { |dir| Bc2cppFixtureRuntime.generate(src, dir, core: true, only_owners: OWNERS) }
ensure
  saved&.each { |k, v| v.nil? ? ENV.delete(k) : ENV[k] = v }
end

def helper_arm?(code)
  helper = code[/static inline mrb_value bc2cpp_getidx\(.*?^}/m].to_s
  helper.include?('INTEGER_BIT_AREF') && helper.index('mrb_array_p(recv)') < helper.index('mrb_fixnum_p(recv)')
end

baseline_dir = Dir.mktmpdir('bc2cpp-integer-bit-aref')
at_exit { FileUtils.remove_entry(baseline_dir) }
puts '-- generated code'
code, baseline_err = Bc2cppFixtureRuntime.generate(SRC, baseline_dir, core: true, only_owners: OWNERS)
check.call('no #error in the generated code', !code.include?('#error'))
check.call('bc2cpp_getidx reads a Fixnum bit after its Array test', helper_arm?(code))
low = method_code(code, 'IbBits_low_bits')
check.call('a proven-Integer receiver reads the bit at the site',
           low.include?('INTEGER_BIT_AREF') && low.include?('(receiver proven Integer)'))
check.call('an unproven receiver keeps the shared helper',
           method_code(code, 'IbBits_bit').include?('bc2cpp_getidx(M, ') &&
             !method_code(code, 'IbBits_bit').include?('INTEGER_BIT_AREF'))

refusals = {
  'a different Integer#[] body' => [SHIM.sub('& 1', '& 3') + PROGRAM, {}],
  'a program Integer#>>' => [SHIM + "class Integer\n  def >>(n); 0; end\nend\n" + PROGRAM, {}],
  'a module prepended into Integer' => [SHIM + "module IbPre; def [](i); 7; end; end\n" \
                                                "class Integer; prepend IbPre; end\n" + PROGRAM, {}],
  'BC2CPP_INTEGER_BIT_AREF=0' => [SRC, { 'BC2CPP_INTEGER_BIT_AREF' => '0' }]
}
refusals.each do |label, (src, env)|
  world, = generate_world(src, env)
  check.call("#{label}: no INTEGER_BIT_AREF arm", !world.include?('INTEGER_BIT_AREF') && !world.include?('#error'))
end

DRIVER = <<~'RUBY'
  show = lambda do |name, &blk|
    out = begin
      blk.call.inspect
    rescue Exception => e
      "#{e.class}: #{e.message}"
    end
    puts "#{name}: #{out}"
  end
  b = IbBits.new
  ints = [0, 1, 5, -1, -6, 0x3fff_ffff, -0x4000_0000, 2**40 + 5, -(2**40)]
  [0, 1, 2, 29, 30, 31, 32, 61, 62, 63, 64, 100, 2**40].each do |i|
    show.call("bits #{i}") { ints.map { |x| b.bit(x, i) } }
  end
  show.call('negative index') { ints.map { |x| b.bit(x, -1) } + ints.map { |x| b.bit(x, -3) } }
  show.call('bignum index') { b.bit(5, 2**70) }
  show.call('float index') { b.bit(6, 1.0) }
  show.call('non-integer index') { b.bit(6, 'x') }
  show.call('other receivers') { b.each_bit([[7, 8], { 1 => :h }, 'ab', IbBox.new], 1) }
  show.call('low bits') { b.low_bits(9) }
  # A bignum receiver (2**70) is left out: the compiled shim's own `>>` on a bignum fails before and after this arm,
  # which the arm never takes (its test needs a Fixnum receiver).
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
        const char* src = R"IBF(#{DRIVER})IBF";
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
  puts 'bc2cpp integer bit aref check: PASS'
else
  warn "bc2cpp integer bit aref check: #{failures.size} failure(s)"
  exit 1
end
