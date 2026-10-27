#!/usr/bin/env ruby
# frozen_string_literal: true

# BC2CPP_SHARDS (tools/bc2cpp/shard_output.rb, docs/bc2cpp-shards.md): the generated code split into translation
# units that compile in parallel.
#
#   text (no tools)
#     - a run whose code is under the shard threshold prints its main file unchanged and comment-only shards;
#     - a split one moves the prelude into the gem's namespace, makes its stateful `static` items `inline` and leaves
#       a stateless helper `static`, keeps #include and the declarations of method-section functions global, and
#       drops `static` only from the method-section functions another shard names;
#   linkage (needs g++)
#     - the split synthetic program links, and its prelude state, function-local statics and constant tables have
#       one instance that both shards share;
#   generated code (needs a host mrbc and a full-core libmruby)
#     - bc2cpp.rb with BC2CPP_SHARDS=2 writes a non-empty shard, and the two translation units, linked, run the
#       fixture as the interpreter does.
#
# Usage: [MRBC=path/to/mrbc] [BC2CPP_MRUBY_FULL=dir | BC2CPP_FULL_BUILD_DIR=dir] ruby scripts/bc2cpp/shard_output_check.rb

require 'fileutils'
require 'open3'
require 'tmpdir'
require_relative 'check_support'
require_relative 'cxx'
require_relative '../../tools/bc2cpp/shard_output'

suite = FixtureCheck.new('shard_output_check')

PRELUDE = <<~'CPP'
  #include <stdio.h>
  static int counter = 0;
  static inline int bump() {
    static int calls = 0;
    ++calls;
    return ++counter * 100 + calls;
  }
  #ifdef SHARD_CHECK_NEVER
  #include <never_included.h>
  static int never_defined = 0;
  #endif
  struct Pair { int a; int b; };
  static int twice(int x) { return 2 * x; }
  static const int TABLE[] = { 1, 2, 3 };
  int ext_value(void) { return TABLE[2] * 2 + 1; }
  int A_one_impl(int);
  [[maybe_unused]] static int A_one(int);
  int B_one_impl(int);
  [[maybe_unused]] static int B_one(int);
  static int (*const registry[])(int) = { A_one, B_one };
CPP

UNIT_A = <<~'CPP'
  static int A_local(int x) { return x + 1; }
  int A_one_impl(int x) { return bump() + B_helper(A_local(x)); }
  static int A_one(int x) { return A_one_impl(x); }
  const int* A_table() { return TABLE; }
CPP

UNIT_B = <<~'CPP'
  static int B_helper(int x) { return twice(x); }
  int B_one_impl(int x) { return bump() + x; }
  static int B_one(int x) { return B_one_impl(x); }
  const int* B_table() { return TABLE + ext_value() - 7; }
CPP

HOOKS = <<~'CPP'
  int run_all() { return registry[0](1) + registry[1](2); }
CPP

# UNIT_A calls UNIT_B's helper, which the one-text output declares first.
def marked
  PRELUDE + ShardOutput.unit_mark('B') + UNIT_B + ShardOutput.unit_mark('A') + UNIT_A + ShardOutput::HOOKS_MARK + HOOKS
end

puts '-- text'
small, small_shards = ShardOutput.split(marked, 'chk', 3)
suite.check('under the threshold the main file is the unmarked text',
            small == PRELUDE + UNIT_B + UNIT_A + HOOKS)
suite.check('under the threshold every other shard is a comment only',
            small_shards.size == 2 && small_shards.all? { |t| t.lines.all? { |l| l.start_with?('//') } })

ENV['BC2CPP_SHARD_MIN_BYTES'] = '1'
main, shards = ShardOutput.split(marked, 'chk', 3)
suite.check('two owners fill two shards of three; the third is a comment only',
            shards.size == 2 && shards[0].include?('#define BC2CPP_SHARD_PRELUDE_ONLY') &&
            shards[1].lines.all? { |l| l.start_with?('//') })
suite.check('shard 1 includes the main file', shards[0].include?(%(#include "chk_gen.cpp")))
suite.check('prelude state and helpers are inline in the gem namespace',
            main.include?("namespace bc2cpp_shard_chk {\ninline int counter = 0;\ninline int bump() {") &&
            main.include?('inline const int TABLE[]') && main.include?('inline int (*const registry[])(int)'))
suite.check('function-local statics are left alone', main.include?('  static int calls = 0;'))
suite.check('a stateless prelude helper stays static (each shard its own copy)',
            main.include?("\n[[maybe_unused]] static int twice(int x)"))
suite.check('#include stays at global scope',
            main.match?(%r{^\} // namespace bc2cpp_shard_chk\n#include <stdio.h>|\A[^\n]*\n[^\n]*\n#include <stdio.h>}) &&
            main.include?("#ifdef SHARD_CHECK_NEVER\n#include <never_included.h>\n#endif\n"))
suite.check('method declarations stay global and lose static',
            main.match?(/^\} \/\/ namespace bc2cpp_shard_chk\n(?:.*\n)*?int A_one_impl\(int\);\n\[\[maybe_unused\]\] int A_one\(int\);/))
all = main + shards.join
suite.check('a helper another shard calls loses static and is declared for it',
            all.include?("\nint B_helper(int x) {") && main.include?("int B_helper(int x);\n"))
suite.check("an external prelude function is the main file's alone, declared for the shards",
            main.include?("#ifndef BC2CPP_SHARD_PRELUDE_ONLY\nint ext_value(void) {") &&
            main.include?("#else\nint ext_value(void);\n#endif\n"))
suite.check('a helper only its own shard calls keeps static', all.include?('static int A_local(int x)'))
suite.check('shard 0 and the hooks sit inside BC2CPP_SHARD_PRELUDE_ONLY',
            main.match?(/#ifndef BC2CPP_SHARD_PRELUDE_ONLY\n(?:.*\n)*int run_all\(\)(?:.*\n)*#endif/))

puts '-- linkage'
if Bc2cppCxx.executable?(Bc2cppCxx.compiler.first)
  Dir.mktmpdir('bc2cpp-shard-output') do |dir|
    File.write(File.join(dir, 'chk_gen.cpp'), main)
    shards.each_with_index { |text, i| File.write(ShardOutput.shard_path(dir, 'chk', i + 1), text) }
    File.write(File.join(dir, 'main.cpp'), <<~'CPP')
      #include <cstdio>
      int run_all();
      const int* A_table();
      const int* B_table();
      int ext_value(void);
      int main() {
        int first = run_all();
        int second = run_all();
        std::printf("%d %d %d %d\n", first, second, A_table() == B_table(), ext_value());
        return 0;
      }
    CPP
    binary = File.join(dir, 'chk')
    sources = [File.join(dir, 'chk_gen.cpp'), *shards.each_index.map { |i| ShardOutput.shard_path(dir, 'chk', i + 1) },
               File.join(dir, 'main.cpp')]
    out, err, status = Bc2cppCxx.capture3('-std=c++17', '-O2', '-Wall', '-Werror', "-I#{dir}", *sources, '-o', binary)
    suite.check('the split program compiles warning-free and links', status.success?)
    puts err.lines.first(20).join unless status.success?
    if status.success?
      out, = Open3.capture2(binary)
      # A_one: bump() is the first call (101) + B_helper(2) = 105; B_one: bump() second (202) + 2 = 204. Shared
      # counter and call count carry on into the second round: 305 + 404.
      suite.check("prelude state and statics are one instance across shards (#{out.strip})",
                  out == "309 713 1 7\n")
    end
  end
else
  puts '  SKIP: no C++ compiler'
end

puts '-- generated code'
mrbc = ENV['MRBC'] || ENV.fetch('PATH', '').split(File::PATH_SEPARATOR).map { |d| File.join(d, 'mrbc') }.find { |p| File.executable?(p) }
if mrbc.nil?
  puts '  SKIP: no host mrbc (set MRBC)'
  suite.finish!
  exit
end
require_relative 'fixture_runtime'
ENV['BC2CPP_SIG_DIRS'] = ''
SOURCE = <<~'RUBY'
  class ShardLeft
    def initialize(n); @n = n; end
    def total(right); [1, 2, 3].map { |x| x * @n }.sum + right.scaled(@n); end
    def name; "left#{@n}"; end
  end
  class ShardRight
    def initialize(k); @k = k; end
    def scaled(n); (0...n).inject(@k) { |acc, i| acc + i }; end
    def describe(left); "#{left.name}/#{left.total(self)}"; end
  end
RUBY
OWNERS = %w[ShardLeft ShardRight].freeze
DRIVER = <<~'RUBY'
  l = ShardLeft.new(4)
  r = ShardRight.new(10)
  puts l.total(r)
  puts r.describe(l)
  puts ShardRight.new(-3).describe(ShardLeft.new(0))
  puts 'end'
RUBY
Dir.mktmpdir('bc2cpp-shard-generated') do |dir|
  ENV['BC2CPP_SHARDS'] = '2'
  code, err = Bc2cppFixtureRuntime.generate(SOURCE, dir, core: true, only_owners: OWNERS)
  ENV.delete('BC2CPP_SHARDS')
  shard = ShardOutput.shard_path(dir, 'fixture', 1)
  shard_text = File.exist?(shard) ? File.read(shard) : ''
  suite.check('BC2CPP_SHARDS=2 writes a shard holding compiled methods',
              shard_text.include?('#include "fixture_gen.cpp"') && shard_text.match?(/^mrb_value \w+_impl\(/))
  suite.check('the main file opens the gem namespace', code.include?('namespace bc2cpp_shard_fixture {'))
  build = Bc2cppFixtureRuntime.full_or_build
  if build.nil?
    puts '  SKIP behavioural comparison: needs a full-core libmruby (BC2CPP_MRUBY_FULL, or rake, g++ and 3rd/mruby)'
  else
    body = <<~CPP
      static int scenario(mrb_state* M) {
        std::fflush(stdout);
        mrb_load_string(M, R"SHD(#{DRIVER})SHD");
        std::fflush(stdout);
        if (M->exc) { mrb_print_error(M); M->exc = nullptr; return 1; }
        return 0;
      }
    CPP
    built, output = Bc2cppFixtureRuntime.run(dir, err, OWNERS, body, build: build, full: true, extra_srcs: [shard])
    suite.check('the main file and the shard compile and link', built)
    sections = Bc2cppFixtureRuntime.sections(output.to_s)
    suite.check('the sharded build runs the fixture as the interpreter does',
                sections['interpreted']&.last == 'end' && sections['interpreted'] == sections['compiled'])
    puts output.to_s.lines.last(20).join unless built && sections['interpreted'] == sections['compiled']
  end
end

suite.finish!
