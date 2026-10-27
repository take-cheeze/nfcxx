#!/usr/bin/env ruby
# encoding: UTF-8
# frozen_string_literal: true

# INTEGER_PAIR_EQ (tools/bc2cpp/codegen_insn.rb compile_cmp) and NEQ_INTEGER_PAIR
# (tools/bc2cpp/codegen_native_send.rb integer_eq_native?): `==` and `!=` on two Integers compare
# their values inline instead of calling mrb_obj_eq / mrb_equal (whose unequal-Integer path sends
# `==` through mrb_funcall), and MOD_POW2_CONSTANT (tools/bc2cpp/codegen_send.rb FIXNUM_BINARY :%):
# `x % 2**k` with a constant divisor is a low-bit mask.
#
#   generated code (needs a host mrbc)
#     - `a == b` tests the Integer pair before the mrb_obj_eq identity call;
#     - `a != b` has an Integer-pair arm ahead of `!mrb_equal`;
#     - a world that reopens Integer#== keeps `!=` on mrb_equal alone;
#     - `%` carries the power-of-two arm ahead of the general floor modulo.
#   behaviour (needs a full-core libmruby, see Bc2cppFixtureRuntime.full_or_build)
#     - interpreted and compiled runs print the same for Integer, bigint, Float (NaN), mixed,
#       String, Symbol, nil and a user `==`, in both worlds, and for `%` by constant and variable divisors.
#
# Usage: MRBC=path/to/mrbc [BC2CPP_MRUBY_FULL=dir | BC2CPP_FULL_BUILD_DIR=dir] ruby scripts/bc2cpp/integer_fast_arms_check.rb

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
  class IpcBox
    def initialize(v); @v = v; end
    attr_reader :v
    def ==(other); other.is_a?(IpcBox) && other.v == @v; end
  end
  class IpcCmp
    def initialize; @hclk = 0; end
    def eq(a, b); a == b; end
    def ne(a, b); a != b; end
    def ivar_ne; @hclk += 1; @hclk != 3; end
    def mod_eq(x); x % 4 == 0; end
    def mod8(x); x % 8; end
    def mod1(x); x % 1; end
    def modv(x, y); x % y; end
  end
RUBY

REOPEN = <<~'RUBY'
  class Integer
    def ==(other); other.equal?(:any) || super; end
  end
RUBY

OWNERS = %w[IpcBox IpcCmp].freeze

def code_of(code, name)
  code.scan(/^(?:static )?mrb_value #{name}_impl\w*\(mrb_state\* M.*?(?=^(?:static )?mrb_value \w+\(mrb_state\* M|\z)/m).join
end

dirs = { 'default' => Dir.mktmpdir('bc2cpp-ipc'), 'reopened' => Dir.mktmpdir('bc2cpp-ipc-reopen') }
at_exit { dirs.each_value { |dir| FileUtils.remove_entry(dir) } }
puts '-- generated code'
code, err = Bc2cppFixtureRuntime.generate(SRC, dirs['default'], core: true, only_owners: OWNERS)
reopen_code, reopen_err = Bc2cppFixtureRuntime.generate(SRC + REOPEN, dirs['reopened'], core: true,
                                                                                           only_owners: OWNERS + ['Integer'])
eq = code_of(code, 'IpcCmp_eq')
ne = code_of(code, 'IpcCmp_ne')
pair = /if \(mrb_integer_p\(r\d+\) && mrb_integer_p\(r\d+\)\) \{\s*r\d+ = mrb_bool_value\(mrb_integer\(r\d+\) (==|!=) mrb_integer\(r\d+\)\);/
check.call('== tests the Integer pair before the mrb_obj_eq call',
           (i = eq =~ pair) && $1 == '==' && eq.index('mrb_obj_eq(M') && i < eq.index('mrb_obj_eq(M'))
check.call('!= has an Integer-pair arm ahead of !mrb_equal',
           (j = ne =~ pair) && $1 == '!=' && ne.index('!mrb_equal(M') && j < ne.index('!mrb_equal(M'))
check.call('an ivar != literal takes the same arm', code_of(code, 'IpcCmp_ivar_ne').match?(pair))
reopen_ne = code_of(reopen_code, 'IpcCmp_ne')
check.call('a reopened Integer#== keeps != on mrb_equal alone',
           reopen_ne.include?('!mrb_equal(M') && !reopen_ne.match?(pair))
mod8 = code_of(code, 'IpcCmp_mod8')
check.call('% carries the power-of-two arm ahead of the general floor modulo',
           (k = mod8.index('__builtin_constant_p(bc2cpp_mod_right)')) && mod8.index('bc2cpp_mod_left % bc2cpp_mod_right') &&
             k < mod8.index('bc2cpp_mod_left % bc2cpp_mod_right'))
check.call('no #error in the generated code', !code.include?('#error') && !reopen_code.include?('#error'))

DRIVER = <<~'RUBY'
  show = lambda do |name, &blk|
    out = begin
      blk.call.inspect
    rescue Exception => e
      "#{e.class}: #{e.message}"
    end
    puts "#{name}: #{out}"
  end
  c = IpcCmp.new
  big = 0x4000_0000_0000_0000
  nan = 0.0 / 0.0
  pairs = [[1, 1], [1, 2], [-3, -3], [-3, 3], [0, -0], [0x7fff_ffff, 0x7fff_ffff], [0x7fff_ffff, -0x8000_0000],
           [big, big], [big, big + 1], [big * 4, big * 4], [1, 1.0], [1.0, 1], [2, 2.5], [nan, nan], [1.5, 1.5],
           ['a', 'a'], ['a', 'b'], [:s, :s], [:s, :t], [nil, nil], [nil, false], [1, nil], [1, :any],
           [IpcBox.new(1), IpcBox.new(1)], [IpcBox.new(1), IpcBox.new(2)], [1, IpcBox.new(1)]]
  pairs.reject! { |pair| pair.any? { |v| v.is_a?(Integer) && v.abs > 0x7fff_ffff } } if IPC_FIXNUM_ONLY
  pairs.each_with_index { |(a, b), i| show.call("pair #{i}") { [c.eq(a, b), c.ne(a, b)] } }
  show.call('ivar_ne') { (1..5).map { c.ivar_ne } }
ints = [-0x4000_0000_0000_0001, -0x8000_0000, -9, -8, -7, -1, 0, 1, 7, 8, 9, 0x7fff_ffff, 0x4000_0000_0000_0000]
ints.reject! { |v| v.abs > 0x7fff_ffff } if IPC_FIXNUM_ONLY
show.call('mod8') { ints.map { |x| c.mod8(x) } + [c.mod8(-2.5), c.mod8(9.5)] }
show.call('mod1') { ints.map { |x| c.mod1(x) } }
show.call('modv') { [8, -8, 3, -3, 1, -1, 2.5].map { |y| ints.map { |x| c.modv(x, y) } } }
show.call('modv zero') { c.modv(5, 0) }
show.call('mod_eq') { [-8, -5, 0, 3, 4, 2.0, 4.0].map { |x| c.mod_eq(x) } }
  puts 'end'
RUBY

if ENV['CC_GENERATED_ONLY'] == '1'
  puts '  SKIP behavioural comparison: CC_GENERATED_ONLY'
else
  build = Bc2cppFixtureRuntime.full_or_build
  if build.nil?
    puts '  SKIP behavioural comparison: needs a full-core libmruby (BC2CPP_MRUBY_FULL, or rake, g++ and 3rd/mruby)'
  else
    # The reopened world keeps to fixnums: there `!mrb_equal` on two bigints reaches the compiled
    # Integer#== through mrb_funcall, a super path outside what this check covers.
    { 'default' => [err, OWNERS, false], 'reopened' => [reopen_err, OWNERS + ['Integer'], true] }
      .each do |world, (diag, owners, fixnum_only)|
      body = <<~CPP
        static int scenario(mrb_state* M) {
          std::fflush(stdout);
          const char* src = R"IPC(IPC_FIXNUM_ONLY = #{fixnum_only}\n#{DRIVER})IPC";
          mrb_load_string(M, src);
          std::fflush(stdout);
          if (M->exc) { mrb_print_error(M); M->exc = nullptr; return 1; }
          return 0;
        }
      CPP
      puts "-- #{world} world on real mruby, interpreted and compiled"
      built, output = Bc2cppFixtureRuntime.run(dirs[world], diag, owners, body, build: build, full: true)
      check.call("#{world}: the fixtures build and run", built)
      sections = Bc2cppFixtureRuntime.sections(output)
      interpreted = sections['interpreted']
      compiled = sections['compiled']
      check.call("#{world}: the driver prints #{interpreted&.size} lines in both runs",
                 interpreted && interpreted.last == 'end' && compiled&.last == 'end')
      check.call("#{world}: interpreted and compiled runs print the same", interpreted == compiled)
      if interpreted && compiled
        interpreted.zip(compiled).reject { |a, b| a == b }.first(10).each { |a, b| puts "    interpreted: #{a}\n    compiled:    #{b}" }
      end
      puts output.lines.last(30).join unless built && interpreted && compiled
    end
  end
end

if failures.empty?
  puts 'bc2cpp integer fast arms check: PASS'
else
  warn "bc2cpp integer fast arms check: #{failures.size} failure(s)"
  exit 1
end
