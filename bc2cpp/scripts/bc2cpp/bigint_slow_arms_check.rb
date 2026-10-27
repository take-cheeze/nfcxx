#!/usr/bin/env ruby
# encoding: UTF-8
# frozen_string_literal: true

# NUMERIC_SLOW_PATH's bigint arms (tools/bc2cpp/codegen_numeric_slow.rb) sit under `#ifdef MRB_USE_BIGINT`, a define
# the real build passes from mruby-bigint's gem flags. The fixture binary takes the defines of the libmruby it links
# (Bc2cppFixtureRuntime.library_defines); compiled without them, a bigint receiver of a NUMERIC_SLOW_CLOSED operator
# reached the helper's proven-dead fallback ("Integer#>> was proven undefined but dispatched").
#
#   generated code (needs a host mrbc)
#     - the closed `>>` helper keeps its bigint arm under MRB_USE_BIGINT;
#   behaviour (needs a full-core libmruby, see Bc2cppFixtureRuntime.full_or_build)
#     - the fixture is compiled with the library's -DMRB_USE_BIGINT when libmruby.a has mruby-bigint;
#     - interpreted and compiled runs print the same for optcarrot's Integer#[] shim and the slow-path operators
#       over bigint, fixnum, Float and mixed operands.
#
# Usage: MRBC=path/to/mrbc [BC2CPP_MRUBY_FULL=dir | BC2CPP_FULL_BUILD_DIR=dir] ruby scripts/bc2cpp/bigint_slow_arms_check.rb

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
  # optcarrot's shim (tools/optcarrot_probe/shim_integer_aref.rb): the full-core build has no Integer#[].
  class Integer
    def [](i)
      (self >> i) & 1
    end
  end
  class BsOps
    def bit(x, i); x[i]; end
    def shr(x, n); x >> n; end
    def shl(x, n); x << n; end
    def div(x, y); x / y; end
    def mul(x, y); x * y; end
    def mod(x, y); x % y; end
    def add(x, y); x + y; end
    def sub(x, y); x - y; end
    def xor(x, y); x ^ y; end
    def band(x, y); x & y; end
    def bor(x, y); x | y; end
    def neg(x); -x; end
    def rnd(x); x.round; end
  end
RUBY

OWNERS = %w[Integer BsOps].freeze

dir = Dir.mktmpdir('bc2cpp-bigint-slow')
at_exit { FileUtils.remove_entry(dir) }
puts '-- generated code'
code, err = Bc2cppFixtureRuntime.generate(SRC, dir, core: true, only_owners: OWNERS)
rshift = code[/^static mrb_value bc2cpp_slow_rshift\w*\(mrb_state\* M.*?^\}/m].to_s
check.call('the closed >> helper keeps its bigint arm under MRB_USE_BIGINT',
           rshift.include?('#ifdef MRB_USE_BIGINT') && rshift.include?('mrb_bint_rshift('))
check.call('no #error in the generated code', !code.include?('#error'))

DRIVER = <<~'RUBY'
  show = lambda do |name, &blk|
    out = begin
      blk.call.inspect
    rescue Exception => e
      "#{e.class}: #{e.message}"
    end
    puts "#{name}: #{out}"
  end
  o = BsOps.new
  big = 2**70
  vals = [big, -big, big + 1, 2**62, 5, -3, 1.5]
  show.call('bit') { vals.reject { |v| v.is_a?(Float) }.map { |v| [o.bit(v, 0), o.bit(v, 70), o.bit(v, 3)] } }
  vals.each do |x|
    show.call("shr #{x}") { [o.shr(x, 1), o.shr(x, 70), o.shr(x, -2)] }
    show.call("shl #{x}") { [o.shl(x, 1), o.shl(x, -3)] }
    vals.each do |y|
      show.call("#{x} #{y}") do
        [o.div(x, y), o.mul(x, y), o.mod(x, y), o.add(x, y), o.sub(x, y)]
      end
      next if x.is_a?(Float) || y.is_a?(Float)

      show.call("bits #{x} #{y}") { [o.xor(x, y), o.band(x, y), o.bor(x, y)] }
    end
    show.call("unary #{x}") { [o.neg(x), o.rnd(x)] }
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
    bigint_lib = IO.popen(['nm', '-g', "#{build}/lib/libmruby.a"], err: File::NULL, &:read).include?(' T mrb_bint_rshift')
    check.call('the fixture takes the library\'s -DMRB_USE_BIGINT',
               bigint_lib == Bc2cppFixtureRuntime.library_defines(build).include?('-DMRB_USE_BIGINT'))
    body = <<~CPP
      static int scenario(mrb_state* M) {
        std::fflush(stdout);
        const char* src = R"BSA(#{DRIVER})BSA";
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
  puts 'bc2cpp bigint slow arms check: PASS'
else
  warn "bc2cpp bigint slow arms check: #{failures.size} failure(s)"
  exit 1
end
