#!/usr/bin/env ruby
# encoding: UTF-8
# frozen_string_literal: true

# TAGGED_FIXNUM (tools/bc2cpp/tagged_fixnum.rb): the Fixnum arms of + - * & | ^ and the compares work on the boxed
# word when the boxing makes that exact, and keep the unbox/rebox form otherwise.
#
#   preprocessor (needs g++)
#     - the prelude turns the tagged form on for word boxing with a 64-bit mrb_int and for a 32-bit word with
#       MRB_INT32 (when g++ -m32 or clang++'s i386 target compiles), and off for a 64-bit word with MRB_INT32
#       (MRB_32BIT or not), NaN boxing and no boxing; both halves compile.
#   generated code (needs a host mrbc)
#     - + - * and ADDI/SUBI test the pair with one mask and call the word-level helper, whose overflow runs
#       mrb_num_*; the Float arms and the by-name fallback stay;
#     - < <= > >= == != have a Fixnum-pair arm on the words ahead of the Integer pair (whose tag test also takes a
#       heap Integer), and `==` keeps that arm ahead of mrb_obj_eq;
#     - & | ^ are word operations in the default world, and a world that reopens Integer#& keeps its send;
#     - CMP_NUM_OUTLINE and INT_BOX_OUTLINE (int_box_outline.rb): the compares past the Fixnum pair call one shared
#       helper, Integer#/ of a pair, an Array size and a block's register addresses take their helpers, and the
#       switches set to 0 give the inline forms back.
#   behaviour (needs a full-core libmruby, see Bc2cppFixtureRuntime.full_or_build)
#     - interpreted and compiled runs print the same at the fixnum edges (FIXNUM_MAX/MIN +- 1, the heap Integers
#       up to 2**63, bigints, overflow to bigint and back), for Floats, mixed and non-numeric operands, in the default
#       world and one that reopens Integer#+, #< and #&, with the tagged form on and forced off, and with the outline
#       switches off.
#   cold compact (tools/bc2cpp/cold_compact.rb)
#     - with the fixture's methods on the cold list, each operator site is one call of a noinline helper whose body is
#       the inline text; BC2CPP_COLD_COMPACT=0 gives the default output; both worlds print what the interpreter prints.
#
# Usage: MRBC=path/to/mrbc [BC2CPP_MRUBY_FULL=dir | BC2CPP_FULL_BUILD_DIR=dir] ruby scripts/bc2cpp/tagged_fixnum_check.rb

require 'open3'
require 'tmpdir'
require_relative 'fixture_runtime'
require_relative 'host_cxx'
require_relative '../../tools/bc2cpp/tagged_fixnum'
require_relative '../../tools/bc2cpp/cold_compact'
require_relative '../../tools/bc2cpp/cmp_num_outline'
require_relative '../../tools/bc2cpp/int_box_outline'

# The fixture is its own closed world: the repository signatures name classes it does not define.
ENV['BC2CPP_SIG_DIRS'] = ''

failures = []
check = lambda do |what, condition|
  puts "  #{condition ? 'ok  ' : 'FAIL'} #{what}"
  failures << what unless condition
end

ROOT = Bc2cppFixtureRuntime::ROOT

puts '-- preprocessor'
if Bc2cppFixtureRuntime.compiler?
  Dir.mktmpdir('bc2cpp-tagged-pp') do |dir|
    probe = lambda do |expected, flags, compiler, fits = expected|
      src = File.join(dir, 'probe.cpp')
      File.write(src, <<~CPP)
        #include <mruby.h>
        #include <mruby/numeric.h>
        #{TaggedFixnum::PRELUDE}
        #{CmpNumOutline::RUNTIME}
        #{IntBoxOutline::RUNTIME}
        static_assert(BC2CPP_TAGGED_FIXNUM == #{expected}, "BC2CPP_TAGGED_FIXNUM");
        static_assert(bc2cpp_upvar_ptr_fits == #{fits} && bc2cpp_size_fits == #{fits}, "INT_BOX_OUTLINE fits");
        bool probe(mrb_value a, mrb_value b, mrb_value& z) {
          return BC2CPP_FIXNUM_PAIR_P(a, b) && !bc2cpp_fixnum_add(a, b, z) && !bc2cpp_fixnum_sub(a, b, z) &&
                 !bc2cpp_fixnum_mul(a, b, z) && BC2CPP_FIXNUM_WORD(a) < BC2CPP_FIXNUM_WORD(b) &&
                 mrb_fixnum_p(BC2CPP_FIXNUM_XOR(BC2CPP_FIXNUM_AND(a, b), BC2CPP_FIXNUM_OR(a, b)));
        }
      CPP
      # MRB_PRESYM_SCANNING: the source tree has no generated presym/id.h, and symbols play no part here.
      Open3.capture2e(compiler, '-std=c++17', '-fsyntax-only', '-DMRB_PRESYM_SCANNING', *flags,
                      "-I#{ROOT}/3rd/mruby/include", src)
    end
    # The outline's fits flags hold exactly where mrb_int is as wide as the word, the tagged condition less NaN boxing.
    report = lambda do |name, expected, flags, compiler = HostCxx.pick('g++'), fits = expected|
      out, status = probe.call(expected, flags, compiler, fits)
      check.call("#{name}: BC2CPP_TAGGED_FIXNUM is #{expected}, the outline fits are #{fits} and the prelude compiles",
                 status.success?)
      puts out.lines.first(10).join unless status.success?
    end
    # MRB_32BIT on a 64-bit host is the fixtures' 32-bit mrb_int build (BC2CPP_MRUBY_FULL32): the word stays 64 bits.
    { 'word boxing, 64-bit mrb_int' => [1, []], 'word boxing, 64-bit word with MRB_INT32' => [0, %w[-DMRB_INT32]],
      'MRB_32BIT MRB_INT32 on a 64-bit word' => [0, %w[-DMRB_32BIT -DMRB_INT32]],
      'NaN boxing' => [0, %w[-DMRB_NAN_BOXING], 0], 'no boxing' => [0, %w[-DMRB_NO_BOXING], 1],
      'forced off' => [0, %w[-DBC2CPP_TAGGED_FIXNUM=0], 1] }.each do |name, (expected, flags, fits)|
      report.call(name, expected, flags, HostCxx.pick('g++'), fits.nil? ? expected : fits)
    end
    # The 32-bit targets (Emscripten, PSP, Wio): a 32-bit word with MRB_INT32. g++ -m32 needs multilib headers;
    # clang's i386 target reads the host's glibc headers, which lack only the empty gnu/stubs-32.h.
    stubs = File.join(dir, 'stubs')
    FileUtils.mkdir_p(File.join(stubs, 'gnu'))
    File.write(File.join(stubs, 'gnu/stubs-32.h'), '')
    host_include = Dir['/usr/include/*-linux-gnu'].first
    # nfcxx is not a candidate: it has no 32-bit target for hosted code (--target is freestanding --emit-c only) and would take
    # -m32 as an ISA option and compile a 64-bit word, so a CXX that is nfcxx gives way to g++ here.
    m32_cxx = HostCxx.nfcxx?(ENV.fetch('CXX', '')) || ENV.fetch('CXX', '').empty? ? 'g++' : ENV.fetch('CXX')
    m32 = [[m32_cxx, %w[-m32]],
           ['clang++', ['--target=i386-linux-gnu', '-isystem', stubs, *(host_include ? ['-isystem', host_include] : [])]]]
          .find do |compiler, flags|
            Open3.capture2e(compiler, *flags, '-fsyntax-only', '-x', 'c++', '-', stdin_data: "#include <stdio.h>\n")
                 .last.success?
          rescue SystemCallError
            false
          end
    if m32
      report.call("32-bit word, MRB_INT32 (#{m32[0]} #{m32[1].first})", 1, [*m32[1], '-DMRB_INT32'], m32[0])
    else
      puts '  SKIP 32-bit word: neither g++ -m32 nor clang++ --target=i386-linux-gnu compiles here'
    end
  end
else
  puts '  SKIP: no g++'
end

unless Bc2cppFixtureRuntime.mrbc && system(Bc2cppFixtureRuntime.mrbc, '--version', out: File::NULL, err: File::NULL)
  puts '  SKIP: no host mrbc (set MRBC); the generated-code and behavioural checks need it'
  exit(failures.empty? ? 0 : 1)
end

SRC = <<~'RUBY'
  class TfOps
    def initialize; @c = 0; @k = 0; end
    def add(a, b); a + b; end
    def sub(a, b); a - b; end
    def mul(a, b); a * b; end
    def addi(a); a + 1; end
    def subi(a); a - 1; end
    def lt(a, b); a < b; end
    def le(a, b); a <= b; end
    def gt(a, b); a > b; end
    def ge(a, b); a >= b; end
    def eq(a, b); a == b; end
    def ne(a, b); a != b; end
    def band(a, b); a & b; end
    def bor(a, b); a | b; end
    def bxor(a, b); a ^ b; end
    def step(n); @c += n; @c < 3; end
    def dv(a, b); a / b; end
    def sz(a); a.size; end
    def each2; yield 1; yield 2; end
    def cap(n); s = 0; each2 { |x| s += x * n }; s; end
    # LITERAL_EQ_IDENTITY (codegen_literal_eq.rb): == against a literal; @k only ever holds an Integer.
    def eq_sym(a); a == :tag; end
    def eq_nil(a); a == nil; end
    def eq_true(a); a == true; end
    def eq_false(a); a == false; end
    def sym_eq(a); :tag == a; end
    def eq_one(a); a == 1; end
    def kinc; @k += 1; end
    def eq_k1; @k == 1; end
  end
RUBY

# Each reopened method answers the default one's value for an Integer operand and counts its calls, so a compiled
# arm that skipped a send the interpreter makes (or made one it does not) shows in $tf_hook.
REOPEN = <<~'RUBY'
  $tf_hook = 0
  class Integer
    def +(o); $tf_hook += 1; o.is_a?(Integer) ? self - (0 - o) : :hooked; end
    def <(o); $tf_hook += 1; o.is_a?(Numeric) ? (self <=> o) == -1 : :hooked; end
    def &(o); $tf_hook += 1; o.is_a?(Integer) ? (self | o) - (self ^ o) : :hooked; end
  end
  # A program `==` that answers true for a literal it is not: x == :tag must send it.
  class TfAny
    def ==(o); o == :tag || o.nil?; end
  end
RUBY

OWNERS = %w[TfOps].freeze

def code_of(code, name)
  code.scan(/^(?:static )?mrb_value #{name}_impl\w*\(mrb_state\* M.*?(?=^(?:static )?mrb_value \w+\(mrb_state\* M|\z)/m).join
end

dirs = { 'default' => Dir.mktmpdir('bc2cpp-tf'), 'reopened' => Dir.mktmpdir('bc2cpp-tf-reopen'),
         'cold' => Dir.mktmpdir('bc2cpp-tf-cold'), 'cold reopened' => Dir.mktmpdir('bc2cpp-tf-cold-reopen'),
         'cold off' => Dir.mktmpdir('bc2cpp-tf-cold-off') }
at_exit { dirs.each_value { |dir| FileUtils.remove_entry(dir) } }
puts '-- generated code'
code, err = Bc2cppFixtureRuntime.generate(SRC, dirs['default'], core: true, only_owners: OWNERS)
OUTLINE_SWITCHES = %w[BC2CPP_CMP_NUM_OUTLINE BC2CPP_UPVAR_PTR_FIXNUM BC2CPP_SIZE_FIXNUM BC2CPP_INT_PAIR_OUTLINE
                      BC2CPP_LITERAL_EQ_IDENTITY BC2CPP_COLD_COMPACT_TAIL].freeze
with_switches = lambda do |value, &blk|
  saved = OUTLINE_SWITCHES.to_h { |k| [k, ENV.fetch(k, nil)] }
  OUTLINE_SWITCHES.each { |k| ENV[k] = value }
  blk.call
ensure
  saved.each { |k, v| ENV[k] = v }
end
dirs['inline'] = Dir.mktmpdir('bc2cpp-tf-inline')
inline_code, inline_err = with_switches.call('0') do
  Bc2cppFixtureRuntime.generate(SRC, dirs['inline'], core: true, only_owners: OWNERS)
end
reopen_code, reopen_err = Bc2cppFixtureRuntime.generate(SRC + REOPEN, dirs['reopened'], core: true,
                                                                                         only_owners: OWNERS + ['Integer'])
# COLD_COMPACT: every TfOps method on the cold list.
cold_list = File.join(dirs['cold'], 'cold_methods.txt')
File.write(cold_list, "# fixture\n#{SRC.scan(/def (\w+)/).flatten.map { |name| "TfOps##{name}" }.join("\n")}\n")
cold_gen = lambda do |src, dir, owners, env = {}|
  saved = ENV.to_h.slice(ColdCompact::LIST_KEY, *env.keys)
  ENV[ColdCompact::LIST_KEY] = cold_list
  env.each { |k, v| ENV[k] = v }
  Bc2cppFixtureRuntime.generate(src, dir, core: true, only_owners: owners)
ensure
  [ColdCompact::LIST_KEY, *env.keys].each { |k| saved.key?(k) ? ENV[k] = saved[k] : ENV.delete(k) }
end
cold_code, cold_err = cold_gen.call(SRC, dirs['cold'], OWNERS)
cold_reopen_code, cold_reopen_err = cold_gen.call(SRC + REOPEN, dirs['cold reopened'], OWNERS + ['Integer'])
cold_off_code, = cold_gen.call(SRC, dirs['cold off'], OWNERS, 'BC2CPP_COLD_COMPACT' => '0')
dirs['tail off'] = Dir.mktmpdir('bc2cpp-tf-tail-off')
tail_off_code, = cold_gen.call(SRC, dirs['tail off'], OWNERS, 'BC2CPP_COLD_COMPACT_TAIL' => '0', ColdCompact::LIST_KEY => '/nonexistent')
check.call('the prelude is in the generated code', code.include?(TaggedFixnum::PRELUDE))
pair = ->(text) { text.match(/if \(mrb_likely\(BC2CPP_FIXNUM_PAIR_P\((r\d+), (r\d+)\)\)\) \{/) }
{ 'add' => %w[add mrb_num_add], 'sub' => %w[sub mrb_num_sub], 'mul' => %w[mul mrb_num_mul] }.each do |name, (op, slow)|
  body = code_of(inline_code, "TfOps_#{name}")
  m = pair.call(body)
  check.call("#{name}: one pair test, the word helper, its mrb_num_* overflow, the shared Float helper and the fallback",
             m && body.include?("if (mrb_unlikely(bc2cpp_fixnum_#{op}(#{m[1]}, #{m[2]}, #{m[1]}))) " \
                                "{ #{m[1]} = #{slow}(M, #{m[1]}, #{m[2]}); }") &&
               body.include?("bc2cpp_num_#{name}_float(M, #{m[1]}, #{m[2]})") &&
               inline_code.include?("mrb_value bc2cpp_num_#{name}_float(mrb_state* M, mrb_value d, mrb_value s)"))
end
# COLD_COMPACT_TAIL (cold_compact.rb): the Fixnum tier stays inline, and one helper call holds the arms after it.
tail_site = lambda do |body, test, op, rhs|
  body.match(/if \(mrb_likely\(#{test}\) && !mrb_unlikely\(bc2cpp_fixnum_#{op}\((r\d+), #{rhs}, \1\)\)\) \{\n  \} else \{\n(?:  \/\/[^\n]*\n)*  \1 = (bc2cpp_compact_\h{16})\(M, \1(?:, r\d+)?\);\n  \}/)
end
{ 'add' => %w[add mrb_num_add], 'sub' => %w[sub mrb_num_sub], 'mul' => %w[mul mrb_num_mul],
  'addi' => %w[add mrb_num_add], 'subi' => %w[sub mrb_num_sub] }.each do |name, (op, slow)|
  body = code_of(code, "TfOps_#{name}")
  imm = name.end_with?('i')
  m = tail_site.call(body, imm ? 'mrb_fixnum_p\\(r\\d+\\)' : 'BC2CPP_FIXNUM_PAIR_P\\(r\\d+, r\\d+\\)', op,
                     imm ? 'mrb_fixnum_value\\(1\\)' : 'r\\d+')
  helper = m && code[/^static __attribute__\(\(noinline, cold\)\) mrb_value #{m[2]}\(.*?^\}$/m]
  check.call("#{name}: the Fixnum tier is inline and one helper holds the Integer, Float and fallback arms (COLD_COMPACT_TAIL)",
             m && helper && helper.include?("= #{slow}(M, a0, ") && !helper.include?('bc2cpp_fixnum_') &&
               !body.include?(slow) && (imm || helper.include?("bc2cpp_num_#{name}_float(M, a0, a1)")))
end
dv = code_of(code, 'TfOps_dv')
dv_call = dv.match(/= bc2cpp_div_int_pair\(M, (r\d+), (r\d+)\);\n  \} else \{\n(?:  \/\/[^\n]*\n)*  \1 = (bc2cpp_compact_\h{16})\(M, \1, \2\);/)
dv_helper = dv_call && code[/^static __attribute__\(\(noinline, cold\)\) mrb_value #{dv_call[3]}\(.*?^\}$/m]
check.call('/: the Integer pair stays inline and one helper holds the Float and fallback arms (COLD_COMPACT_TAIL)',
           dv_helper&.include?('bc2cpp_num_div_float(M, a0, a1)') && !dv.include?('bc2cpp_num_div_float'))
{ 'addi' => 'add', 'subi' => 'sub' }.each do |name, op|
  check.call("#{name}: the literal is a boxed constant to the word helper",
             code_of(code, "TfOps_#{name}").match?(/bc2cpp_fixnum_#{op}\((r\d+), mrb_fixnum_value\(1\), \1\)/))
end
{ 'lt' => '<', 'le' => '<=', 'gt' => '>', 'ge' => '>=' }.each do |name, sym|
  body = code_of(code, "TfOps_#{name}")
  m = pair.call(body)
  word = m && body.index("mrb_bool_value(BC2CPP_FIXNUM_WORD(#{m[1]}) #{sym} BC2CPP_FIXNUM_WORD(#{m[2]}))")
  helper = m && body.index("bc2cpp_cmp_num_#{name}(M, #{m[1]}, #{m[2]})")
  check.call("#{name}: the Fixnum pair compares the words, then the shared helper, with no inline Integer read",
             word && helper && m.begin(0) < word && word < helper && !body.include?('mrb_integer(') &&
               code.include?("mrb_value bc2cpp_cmp_num_#{name}(mrb_state* M, mrb_value d, mrb_value s)"))
  off = code_of(inline_code, "TfOps_#{name}")
  m = pair.call(off)
  word = m && off.index("mrb_bool_value(BC2CPP_FIXNUM_WORD(#{m[1]}) #{sym} BC2CPP_FIXNUM_WORD(#{m[2]}))")
  check.call("#{name}: switched off, the Integer pair is inline behind the word arm",
             word && off.index('mrb_integer_p(') && word < off.index('mrb_integer_p(') && !off.include?('bc2cpp_cmp_num_'))
end
eq = code_of(code, 'TfOps_eq')
eq_word = eq.index('BC2CPP_FIXNUM_WORD(')
check.call('==: the word arm (not hinted) is ahead of the shared helper, whose Integer pair is ahead of mrb_obj_eq',
           eq.match?(/if \(BC2CPP_FIXNUM_PAIR_P\(r\d+, r\d+\)\) \{/) && eq_word && eq.index('bc2cpp_cmp_num_eq(M,') &&
             eq_word < eq.index('bc2cpp_cmp_num_eq(M,') && !eq.include?('mrb_integer(') &&
             code.match?(/bc2cpp_cmp_num_eq\(mrb_state\* M, mrb_value d, mrb_value s\) \{\n\s*if \(mrb_integer_p\(d\) && mrb_integer_p\(s\)\)[^\n]*\n\s*if \(mrb_obj_eq\(M, d, s\)\)/))
eq = code_of(inline_code, 'TfOps_eq')
eq_word = eq.index('BC2CPP_FIXNUM_WORD(')
check.call('==: switched off, the word arm is ahead of the Integer pair and mrb_obj_eq',
           eq_word && eq.index('mrb_integer_p(') && eq_word < eq.index('mrb_integer_p(') && eq_word < eq.index('mrb_obj_eq(M'))
ne = code_of(code, 'TfOps_ne')
check.call('!=: the word arm is ahead of the shared == helper, negated, and !mrb_equal',
           (i = ne.index('BC2CPP_FIXNUM_WORD(')) && ne.index('bc2cpp_cmp_num_eq(M,') && i < ne.index('bc2cpp_cmp_num_eq(M,') &&
             ne.include?('mrb_bool_value(mrb_false_p(bc2cpp_nt))') && i < ne.index('!mrb_equal(M'))
ne = code_of(inline_code, 'TfOps_ne')
check.call('!=: switched off, the word arm is ahead of the Integer pair and !mrb_equal',
           (i = ne.index('BC2CPP_FIXNUM_WORD(')) && i < ne.index('mrb_integer_p(') && i < ne.index('!mrb_equal(M'))
check.call('/: an Integer pair takes the shared helper; switched off, three reads',
           code_of(code, 'TfOps_dv').match?(/= bc2cpp_div_int_pair\(M, (r\d+), r\d+\);/) &&
             code_of(inline_code, 'TfOps_dv').match?(/= mrb_div_int_value\(M, mrb_integer\((r\d+)\), mrb_integer\(r\d+\)\);/))
check.call('size: the Array length is boxed by bc2cpp_size_value; switched off, mrb_int_value',
           code_of(code, 'TfOps_sz').include?('bc2cpp_size_value(M, ARY_LEN(') &&
             code_of(inline_code, 'TfOps_sz').include?('mrb_int_value(M, ARY_LEN('))
check.call('block env: register addresses are written and read by the UPVAR_PTR_FIXNUM pair',
           code_of(code, 'TfOps_cap').match?(/bc2cpp_upvar_ptr_value\(M, &r\d+\)/) &&
             code.match?(/mrb_value\* bc2cpp_upvar_\w+ = bc2cpp_upvar_ptr\(/) &&
             !code.match?(/= reinterpret_cast<mrb_value\*>\(static_cast<uintptr_t>\(mrb_integer\(/))
check.call('block env: switched off, mrb_int_value and mrb_integer',
           code_of(inline_code, 'TfOps_cap').include?('mrb_int_value(M, static_cast<mrb_int>(reinterpret_cast<uintptr_t>(&r') &&
             inline_code.match?(/= reinterpret_cast<mrb_value\*>\(static_cast<uintptr_t>\(mrb_integer\(/) &&
             !inline_code.include?('bc2cpp_upvar_ptr') && !inline_code.include?('bc2cpp_cmp_num_'))
{ 'band' => 'AND', 'bor' => 'OR', 'bxor' => 'XOR' }.each do |name, op|
  check.call("#{name}: a word operation behind the pair test",
             code_of(code, "TfOps_#{name}").match?(/BC2CPP_FIXNUM_PAIR_P\(r\d+, r\d+\).*BC2CPP_FIXNUM_#{op}\(r\d+, r\d+\)/m))
end
check.call('a reopened Integer#& keeps its send', !code_of(reopen_code, 'TfOps_band').include?('BC2CPP_FIXNUM_AND'))
identity = ->(text, name) { code_of(text, "TfOps_#{name}").match?(/BC2CPP_SAME_WORD\(r\d+, r\d+\)/) }
%w[eq_sym eq_nil eq_true eq_false sym_eq eq_k1].each do |name|
  body = code_of(code, "TfOps_#{name}")
  check.call("#{name}: == against the literal is the word identity, no mrb_equal (LITERAL_EQ_IDENTITY)",
             identity.call(code, name) && !body.include?('mrb_equal(') && !body.include?('bc2cpp_cmp_num_eq('))
  check.call("#{name}: BC2CPP_LITERAL_EQ_IDENTITY=0 keeps the full compare", !identity.call(inline_code, name))
end
eq_one = code_of(code, 'TfOps_eq_one')
check.call('eq_one: an operand that may be a Float (1 == 1.0) is the word test, else the Float compare',
           eq_one.match?(/= mrb_fixnum_p\((r\d+)\) \? mrb_bool_value\(BC2CPP_SAME_WORD\(\1, r\d+\)\) : bc2cpp_eq_lit_num\(\1, r\d+\);/) &&
             !eq_one.include?('mrb_equal(') && !eq_one.include?('bc2cpp_cmp_num_eq('))
check.call('eq_one: BC2CPP_LITERAL_EQ_IDENTITY=0 keeps the numeric compare',
           code_of(inline_code, 'TfOps_eq_one').include?('mrb_equal(') && !code_of(inline_code, 'TfOps_eq_one').include?('bc2cpp_eq_lit_num('))
check.call('a program == (TfAny) keeps every literal compare a send',
           %w[eq_sym eq_nil eq_true eq_false eq_k1 eq_one].none? { |name| identity.call(reopen_code, name) })
check.call('a reopened Integer#+ leaves OP_ADD its word arm, as the VM does',
           code_of(reopen_code, 'TfOps_add').include?('bc2cpp_fixnum_add('))
methods = code.sub(TaggedFixnum::PRELUDE, '')
check.call('the unbox/rebox tier is gone from the generated methods',
           !methods.match?(/mrb_int_(?:add|sub|mul)_overflow\(mrb_fixnum\(/) && !methods.include?('bc2cpp_z'))
# A register address would keep a resumable step function's registers in its frame (RESUMABLE_REGISTER_ADDRESS).
check.call('the word helpers take no register address',
           !methods.match?(/bc2cpp_fixnum_(?:add|sub|mul)\([^;]*&\s*r\d/))
check.call('no #error in the generated code', !code.include?('#error') && !reopen_code.include?('#error'))
helper_call = /^  (r\d+) = (bc2cpp_compact_\h{16})\(M, \1(?:, r\d+)?\);$/
%w[add sub mul addi subi lt le gt ge eq].each do |name|
  body = code_of(cold_code, "TfOps_#{name}")
  m = body.match(helper_call)
  helper = m && cold_code[/^static __attribute__\(\(noinline, cold\)\) mrb_value #{m[2]}\(.*?^\}$/m]
  check.call("cold #{name}: the operator site is one helper call, and the helper holds the inline arms",
             m && helper && !body.include?('BC2CPP_FIXNUM_PAIR_P') && !body.include?('mrb_fixnum_p(') &&
               helper.match?(/BC2CPP_FIXNUM_PAIR_P\(a\d, a\d\)|mrb_fixnum_p\(a0\)/))
end
check.call('cold: a method off the list keeps the inline arms',
           code_of(cold_code, 'Integer_').empty? || !code_of(cold_code, 'Integer_').include?('bc2cpp_compact_'))
check.call('cold: BC2CPP_COLD_COMPACT=0 generates the default code less its arithmetic tails', cold_off_code == tail_off_code)
check.call('cold: no #error in the generated code', !cold_code.include?('#error') && !cold_reopen_code.include?('#error'))

DRIVER = <<~'RUBY'
  show = lambda do |name, &blk|
    out = begin
      blk.call.inspect
    rescue Exception => e
      "#{e.class}"
    end
    puts "#{name}: #{out}"
  end
  t = TfOps.new
  fmax = 0x3fff_ffff_ffff_ffff
  fmin = -0x4000_0000_0000_0000
  nan = 0.0 / 0.0
  vals = [0, 1, -1, 2, -2, 100, fmax, fmax - 1, fmax + 1, fmin, fmin + 1, fmin - 1, 0x7fff_ffff_ffff_ffff,
          -0x8000_0000_0000_0000, 0x8000_0000_0000_0000, 2**70, -(2**70), 1.5, -0.0, nan, nil, :tag]
  vals += [1.0, true, false, 'tag']
  vals << TfAny.new if Object.const_defined?(:TfAny)
  ops = %i[add sub mul lt le gt ge eq ne band bor bxor dv]
  ops.each do |op|
    vals.each_with_index do |a, i|
      show.call("#{op} #{i}") { vals.map { |b| t.__send__(op, a, b) } }
    end
    show.call("#{op} hook") { $tf_hook }
  end
  vals.each_with_index do |a, i|
    show.call("addi/subi #{i}") { [t.addi(a), t.subi(a), t.subi(t.addi(a)), t.addi(t.subi(a))] }
  end
  vals.each_with_index do |a, i|
    show.call("literal == #{i}") { %i[eq_sym eq_nil eq_true eq_false sym_eq eq_one].map { |op| t.__send__(op, a) } }
  end
  show.call('eq_k1') { r = [t.eq_k1]; t.kinc; r << t.eq_k1; t.kinc; r << t.eq_k1 }
  show.call('back to fixnum') { [t.sub(t.add(fmax, 1), 1), t.add(t.sub(fmin, 1), 1), t.sub(t.mul(fmax, 2), fmax)] }
  show.call('step') { [t.step(1), t.step(1), t.step(fmax), t.step(fmin), t.step(-fmax)] }
  show.call('size') { [t.sz([1, 2, 3]), t.sz([]), t.sz('abcd'), t.sz({ a: 1 }), t.sz(nil)] }
  show.call('cap') { [t.cap(3), t.cap(fmax), t.cap(-1), t.cap(1.5)] }
  show.call('hook') { $tf_hook }
  puts 'end'
RUBY

if ENV['CC_GENERATED_ONLY'] == '1'
  puts '  SKIP behavioural comparison: CC_GENERATED_ONLY'
else
  build = Bc2cppFixtureRuntime.full_or_build
  if build.nil?
    puts '  SKIP behavioural comparison: needs a full-core libmruby (BC2CPP_MRUBY_FULL, or rake, g++ and 3rd/mruby)'
  else
    cxxflags = ENV.fetch('BC2CPP_CXXFLAGS', '')
    { 'tagged' => [1, cxxflags], 'forced off' => [0, "#{cxxflags} -DBC2CPP_TAGGED_FIXNUM=0"] }.each do |form, (on, flags)|
      ENV['BC2CPP_CXXFLAGS'] = flags
      { 'default' => [err, OWNERS], 'reopened' => [reopen_err, OWNERS + ['Integer']],
        'inline' => [inline_err, OWNERS],
        'cold' => [cold_err, OWNERS], 'cold reopened' => [cold_reopen_err, OWNERS + ['Integer']] }.each do |world, (diag, owners)|
        body = <<~CPP
          static int scenario(mrb_state* M) {
            std::printf("tagged=%d\\n", BC2CPP_TAGGED_FIXNUM);
            std::fflush(stdout);
            const char* src = R"TF(#{DRIVER})TF";
            mrb_load_string(M, src);
            std::fflush(stdout);
            if (M->exc) { mrb_print_error(M); M->exc = nullptr; return 1; }
            return 0;
          }
        CPP
        what = "#{world} world, #{form}"
        puts "-- #{what} on real mruby, interpreted and compiled"
        built, output = Bc2cppFixtureRuntime.run(dirs[world], diag, owners, body, build: build, full: true)
        check.call("#{what}: the fixtures build and run", built)
        sections = Bc2cppFixtureRuntime.sections(output)
        interpreted = sections['interpreted']
        compiled = sections['compiled']
        check.call("#{what}: BC2CPP_TAGGED_FIXNUM is #{on}", compiled&.first == "tagged=#{on}")
        check.call("#{what}: the driver prints #{interpreted&.size} lines in both runs",
                   interpreted && interpreted.last == 'end' && compiled&.last == 'end')
        check.call("#{what}: interpreted and compiled runs print the same", interpreted == compiled)
        if interpreted && compiled
          interpreted.zip(compiled).reject { |a, b| a == b }.first(10).each { |a, b| puts "    interpreted: #{a}\n    compiled:    #{b}" }
        end
        puts output.lines.last(30).join unless built && interpreted && compiled
      end
    end
    ENV['BC2CPP_CXXFLAGS'] = cxxflags
  end
end

if failures.empty?
  puts 'bc2cpp tagged fixnum check: PASS'
else
  warn "bc2cpp tagged fixnum check: #{failures.size} failure(s)"
  exit 1
end
