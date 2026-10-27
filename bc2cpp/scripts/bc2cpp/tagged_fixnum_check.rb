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
#     - & | ^ are word operations in the default world, and a world that reopens Integer#& keeps its send.
#   behaviour (needs a full-core libmruby, see Bc2cppFixtureRuntime.full_or_build)
#     - interpreted and compiled runs print the same at the fixnum edges (FIXNUM_MAX/MIN +- 1, the heap Integers
#       up to 2**63, bigints, overflow to bigint and back), for Floats, mixed and non-numeric operands, in the default
#       world and one that reopens Integer#+, #< and #&, with the tagged form on and forced off.
#
# Usage: MRBC=path/to/mrbc [BC2CPP_MRUBY_FULL=dir | BC2CPP_FULL_BUILD_DIR=dir] ruby scripts/bc2cpp/tagged_fixnum_check.rb

require 'open3'
require 'tmpdir'
require_relative 'fixture_runtime'
require_relative '../../tools/bc2cpp/tagged_fixnum'

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
    probe = lambda do |expected, flags, compiler|
      src = File.join(dir, 'probe.cpp')
      File.write(src, <<~CPP)
        #include <mruby.h>
        #include <mruby/numeric.h>
        #{TaggedFixnum::PRELUDE}
        static_assert(BC2CPP_TAGGED_FIXNUM == #{expected}, "BC2CPP_TAGGED_FIXNUM");
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
    report = lambda do |name, expected, flags, compiler = ENV.fetch('CXX', 'g++')|
      out, status = probe.call(expected, flags, compiler)
      check.call("#{name}: BC2CPP_TAGGED_FIXNUM is #{expected} and the prelude compiles", status.success?)
      puts out.lines.first(10).join unless status.success?
    end
    # MRB_32BIT on a 64-bit host is the fixtures' 32-bit mrb_int build (BC2CPP_MRUBY_FULL32): the word stays 64 bits.
    { 'word boxing, 64-bit mrb_int' => [1, []], 'word boxing, 64-bit word with MRB_INT32' => [0, %w[-DMRB_INT32]],
      'MRB_32BIT MRB_INT32 on a 64-bit word' => [0, %w[-DMRB_32BIT -DMRB_INT32]],
      'NaN boxing' => [0, %w[-DMRB_NAN_BOXING]], 'no boxing' => [0, %w[-DMRB_NO_BOXING]],
      'forced off' => [0, %w[-DBC2CPP_TAGGED_FIXNUM=0]] }.each { |name, (expected, flags)| report.call(name, expected, flags) }
    # The 32-bit targets (Emscripten, PSP, Wio): a 32-bit word with MRB_INT32. g++ -m32 needs multilib headers;
    # clang's i386 target reads the host's glibc headers, which lack only the empty gnu/stubs-32.h.
    stubs = File.join(dir, 'stubs')
    FileUtils.mkdir_p(File.join(stubs, 'gnu'))
    File.write(File.join(stubs, 'gnu/stubs-32.h'), '')
    host_include = Dir['/usr/include/*-linux-gnu'].first
    m32 = [[ENV.fetch('CXX', 'g++'), %w[-m32]],
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
    def initialize; @c = 0; end
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
RUBY

OWNERS = %w[TfOps].freeze

def code_of(code, name)
  code.scan(/^(?:static )?mrb_value #{name}_impl\w*\(mrb_state\* M.*?(?=^(?:static )?mrb_value \w+\(mrb_state\* M|\z)/m).join
end

dirs = { 'default' => Dir.mktmpdir('bc2cpp-tf'), 'reopened' => Dir.mktmpdir('bc2cpp-tf-reopen') }
at_exit { dirs.each_value { |dir| FileUtils.remove_entry(dir) } }
puts '-- generated code'
code, err = Bc2cppFixtureRuntime.generate(SRC, dirs['default'], core: true, only_owners: OWNERS)
reopen_code, reopen_err = Bc2cppFixtureRuntime.generate(SRC + REOPEN, dirs['reopened'], core: true,
                                                                                         only_owners: OWNERS + ['Integer'])
check.call('the prelude is in the generated code', code.include?(TaggedFixnum::PRELUDE))
pair = ->(text) { text.match(/if \(mrb_likely\(BC2CPP_FIXNUM_PAIR_P\((r\d+), (r\d+)\)\)\) \{/) }
{ 'add' => %w[add mrb_num_add], 'sub' => %w[sub mrb_num_sub], 'mul' => %w[mul mrb_num_mul] }.each do |name, (op, slow)|
  body = code_of(code, "TfOps_#{name}")
  m = pair.call(body)
  check.call("#{name}: one pair test, the word helper, its mrb_num_* overflow, the Float arms and the fallback",
             m && body.include?("if (mrb_unlikely(bc2cpp_fixnum_#{op}(#{m[1]}, #{m[2]}, #{m[1]}))) " \
                                "{ #{m[1]} = #{slow}(M, #{m[1]}, #{m[2]}); }") &&
               body.include?("mrb_float_p(#{m[1]}) && mrb_float_p(#{m[2]})"))
end
{ 'addi' => 'add', 'subi' => 'sub' }.each do |name, op|
  check.call("#{name}: the literal is a boxed constant to the word helper",
             code_of(code, "TfOps_#{name}").match?(/bc2cpp_fixnum_#{op}\((r\d+), mrb_fixnum_value\(1\), \1\)/))
end
{ 'lt' => '<', 'le' => '<=', 'gt' => '>', 'ge' => '>=' }.each do |name, sym|
  body = code_of(code, "TfOps_#{name}")
  m = pair.call(body)
  word = m && body.index("mrb_bool_value(BC2CPP_FIXNUM_WORD(#{m[1]}) #{sym} BC2CPP_FIXNUM_WORD(#{m[2]}))")
  check.call("#{name}: the Fixnum pair compares the words ahead of the Integer pair",
             word && body.index('mrb_integer_p(') && m.begin(0) < word && word < body.index('mrb_integer_p('))
end
eq = code_of(code, 'TfOps_eq')
eq_word = eq.index('BC2CPP_FIXNUM_WORD(')
check.call('==: the word arm (not hinted) is ahead of the Integer pair and mrb_obj_eq',
           eq.match?(/if \(BC2CPP_FIXNUM_PAIR_P\(r\d+, r\d+\)\) \{/) && eq_word && eq.index('mrb_integer_p(') &&
             eq_word < eq.index('mrb_integer_p(') && eq_word < eq.index('mrb_obj_eq(M'))
ne = code_of(code, 'TfOps_ne')
check.call('!=: the word arm is ahead of the Integer pair and !mrb_equal',
           (i = ne.index('BC2CPP_FIXNUM_WORD(')) && i < ne.index('mrb_integer_p(') && i < ne.index('!mrb_equal(M'))
{ 'band' => 'AND', 'bor' => 'OR', 'bxor' => 'XOR' }.each do |name, op|
  check.call("#{name}: a word operation behind the pair test",
             code_of(code, "TfOps_#{name}").match?(/BC2CPP_FIXNUM_PAIR_P\(r\d+, r\d+\).*BC2CPP_FIXNUM_#{op}\(r\d+, r\d+\)/m))
end
check.call('a reopened Integer#& keeps its send', !code_of(reopen_code, 'TfOps_band').include?('BC2CPP_FIXNUM_AND'))
check.call('a reopened Integer#+ leaves OP_ADD its word arm, as the VM does',
           code_of(reopen_code, 'TfOps_add').include?('bc2cpp_fixnum_add('))
methods = code.sub(TaggedFixnum::PRELUDE, '')
check.call('the unbox/rebox tier is gone from the generated methods',
           !methods.match?(/mrb_int_(?:add|sub|mul)_overflow\(mrb_fixnum\(/) && !methods.include?('bc2cpp_z'))
# A register address would keep a resumable step function's registers in its frame (RESUMABLE_REGISTER_ADDRESS).
check.call('the word helpers take no register address',
           !methods.match?(/bc2cpp_fixnum_(?:add|sub|mul)\([^;]*&\s*r\d/))
check.call('no #error in the generated code', !code.include?('#error') && !reopen_code.include?('#error'))

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
  ops = %i[add sub mul lt le gt ge eq ne band bor bxor]
  bigs = [2**70, -(2**70)]
  ops.each do |op|
    vals.each_with_index do |a, i|
      # The interpreter answers `2**70 == 0` true (mruby's bigint ==); the compiled mrb_equal does not.
      show.call("#{op} #{i}") do
        vals.map do |b|
          zero = b.is_a?(Numeric) && b.to_f == 0.0
          %i[eq ne].include?(op) && bigs.include?(a) && zero ? :skip : t.__send__(op, a, b)
        end
      end
    end
    show.call("#{op} hook") { $tf_hook }
  end
  vals.each_with_index do |a, i|
    show.call("addi/subi #{i}") { [t.addi(a), t.subi(a), t.subi(t.addi(a)), t.addi(t.subi(a))] }
  end
  show.call('back to fixnum') { [t.sub(t.add(fmax, 1), 1), t.add(t.sub(fmin, 1), 1), t.sub(t.mul(fmax, 2), fmax)] }
  show.call('step') { [t.step(1), t.step(1), t.step(fmax), t.step(fmin), t.step(-fmax)] }
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
      { 'default' => [err, OWNERS], 'reopened' => [reopen_err, OWNERS + ['Integer']] }.each do |world, (diag, owners)|
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
