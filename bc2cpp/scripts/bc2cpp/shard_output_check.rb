#!/usr/bin/env ruby
# frozen_string_literal: true

# BC2CPP_SHARDS (tools/bc2cpp/shard_output.rb, docs/bc2cpp-shards.md): the generated code split into translation
# units that compile in parallel.
#
#   text (no tools)
#     - a run whose code is under the shard threshold prints its main file unchanged and comment-only shards;
#     - a split one moves the prelude into the gem's namespace, makes its `static` items `inline` (a stateless
#       helper stays `static` under BC2CPP_SHARED_HELPERS=0, unless marked BC2CPP_SHARD_ONE_BODY), keeps #include and the
#       declarations of method-section functions global, and drops `static` only from the method-section functions
#       another shard names;
#   linkage (needs g++)
#     - the split synthetic program links, and its prelude state, function-local statics and constant tables have
#       one instance that both shards share;
#   generated code (needs a host mrbc and a full-core libmruby)
#     - bc2cpp.rb with BC2CPP_SHARDS=2 writes a non-empty shard, and the two translation units, linked, run the
#       fixture as the interpreter does, with no gem-namespace function defined in both (SHARED_HELPERS).
#   IMPLICIT_STATE (tools/bc2cpp/implicit_state.rb)
#     - a synthetic text loses the state parameter of its called-only functions and keeps it on an address-taken
#       entry, an overloaded name and an extern "C" init (which stores it); compiled, it runs, a second state aborts
#       under BC2CPP_IMPLICIT_STATE_CHECK, and without -DBC2CPP_IMPLICIT_STATE it does not compile;
#     - the colocated generated fixture with BC2CPP_IMPLICIT_STATE=1 compiles, links and runs as the interpreter does.
#
# Usage: [MRBC=path/to/mrbc] [BC2CPP_MRUBY_FULL=dir | BC2CPP_FULL_BUILD_DIR=dir] ruby scripts/bc2cpp/shard_output_check.rb

require_relative '../../tools/mrbc_rb/mrbc_default.rb'
require 'fileutils'
require 'open3'
require 'tmpdir'
require_relative 'check_support'
require_relative 'cxx'
require_relative '../../tools/bc2cpp/shard_output'
require_relative '../../tools/bc2cpp/implicit_state'

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
  template <int N> static inline int times(int x) { return N * x; }
  template <class F>
  static int apply(F f) { return f(); }
  static int wrapped(int a,
                     int b) { return a + b; }
  static int wrapped_state(int a,
                           int b) {
    static int seen = 0;
    return seen += a + b;
  }
  #define BC2CPP_SHARD_ONE_BODY
  static int thrice(int x) { return 3 * x; }
  BC2CPP_SHARD_ONE_BODY static int one_body(int x) { return thrice(x); }
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
lexical = <<~'CPP'
  static int lexical() {
    const char* raw = R"TAG(
  } // a raw-string line that would close the function
  )TAG";
    /* a multiline comment
  }
    */
    const char* quoted = "} /*";
    if (true) { }
    return 2 / 1;
  }
CPP
lexical_lines = lexical.lines.map(&:freeze)
scan = ShardOutput.scan_lines(lexical_lines)
suite.check('plain-line scanning retains braces inside carried raw strings and comments',
            scan.map { |line| line[:depth] } == [0] + [1] * 10 &&
            scan.each_index.select { |i| scan[i][:item_start] } == [0] &&
            scan.each_index.select { |i| scan[i][:item_end] } == [10])
suite.check('literal and division lines do not change the enclosing item boundaries',
            ShardOutput.top_level_items(lexical_lines).map { |item| item.values_at(:name, :first, :last) } ==
              [['lexical', 0, 10]])

delimiters = <<~'CPP'
  static int delimiter_guards() {
    /* 雪 *x /y
       not a close * / }
    */
    const char* raw = R"TAG(雪 )NO" /* //
      )TAGx"
    )TAG";
    const char* empty_tag = R"(雪 /* } )";
    const char* quoted = "雪 \" // /*";
    int café = 4;
    int n = 1'000;
    return n / 2; // }
  }
CPP
delimiter_lines = delimiters.lines.map(&:freeze)
delimiter_scan = ShardOutput.scan_lines(delimiter_lines)
suite.check('partial delimiters, UTF-8 and empty raw tags preserve the enclosing depth',
            delimiter_scan.map { |line| line[:depth] } == [0] + [1] * (delimiter_lines.size - 1))
suite.check('comment and raw-string false endings do not split the function',
            ShardOutput.top_level_items(delimiter_lines).map { |item| item.values_at(:name, :first, :last) } ==
              [['delimiter_guards', 0, delimiter_lines.size - 1]])
suite.check('the blanked code text keeps one line per input line (item indices address it)',
            ShardOutput.code_text(PRELUDE.lines).lines.size == PRELUDE.lines.size &&
              ShardOutput.code_text(delimiter_lines).lines.size == delimiter_lines.size)
suite.check('division stays code while a trailing line comment hides its brace',
            delimiter_scan[-2][:code].strip == 'return n / 2;')
suite.check('non-ASCII identifiers retain their original characters',
            delimiter_scan.any? { |line| line[:code].include?('int café = 4;') })
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
suite.check('SHARED_HELPERS: a stateless prelude helper is inline under -Os (one body per gem), a template stays static',
            main.include?("\n[[maybe_unused]] BC2CPP_SHARED_FN int twice(int x)") &&
              main.include?("\ntemplate <int N> static inline int times(int x)") &&
              main.include?("\ntemplate <class F>\nstatic int apply(F f)") &&
              main.include?("#ifdef __OPTIMIZE_SIZE__\n#define BC2CPP_SHARED_FN inline\n"))
suite.check('a head wrapped over lines is read as its function: stateless shared, stateful inline',
            main.include?("\n[[maybe_unused]] BC2CPP_SHARED_FN int wrapped(int a,\n") &&
              main.include?("\ninline int wrapped_state(int a,\n"))
saved_helpers = ENV.fetch('BC2CPP_SHARED_HELPERS', nil)
ENV['BC2CPP_SHARED_HELPERS'] = '0'
helpers_off, = ShardOutput.split(marked, 'chk', 3)
saved_helpers.nil? ? ENV.delete('BC2CPP_SHARED_HELPERS') : ENV['BC2CPP_SHARED_HELPERS'] = saved_helpers
suite.check('BC2CPP_SHARED_HELPERS=0: a stateless prelude helper stays static (each shard its own copy)',
            helpers_off.include?("\n[[maybe_unused]] static int twice(int x)") &&
              !helpers_off.include?('BC2CPP_SHARED_FN'))
suite.check('a BC2CPP_SHARD_ONE_BODY helper and what it calls are inline (one body for every shard)',
            main.include?("\nBC2CPP_SHARD_ONE_BODY inline int one_body(int x)") && main.include?("\ninline int thrice(int x)"))
suite.check('#include stays at global scope',
            main.delete_prefix(ShardOutput::SHARED_HELPER_MACROS)
                .match?(%r{^\} // namespace bc2cpp_shard_chk\n#include <stdio.h>|\A[^\n]*\n[^\n]*\n#include <stdio.h>}) &&
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

puts '-- oversized owners'
single_b = "static int method_counter = 0;\nstatic const int method_table[] = { 1, 2, 3 };\n" +
           UNIT_B.sub('return twice(x);', 'return twice(x) + method_counter;')
                 .sub('return TABLE + ext_value() - 7;', 'return method_table + ext_value() - 7;')
single_a = UNIT_A.sub('return bump()', '++method_counter; return bump()')
                .sub('return TABLE;', 'return method_table;')
single_owner = PRELUDE + ShardOutput.unit_mark('One') + single_b +
               ShardOutput.unit_mark('One') + single_a + ShardOutput::HOOKS_MARK + HOOKS
saved_split_owners = ENV.delete('BC2CPP_SHARD_SPLIT_OWNERS')
grouped_main, grouped_shards = ShardOutput.split(single_owner, 'chk', 3)
suite.check('without the opt-in an oversized owner stays in one unchanged translation unit',
            grouped_main == PRELUDE + single_b + single_a + HOOKS &&
            grouped_shards.all? { |text| text.lines.all? { |line| line.start_with?('//') } })
ENV['BC2CPP_SHARD_SPLIT_OWNERS'] = '1'
single_main, single_shards = ShardOutput.split(single_owner, 'chk', 3)
suite.check('one large owner can fill multiple shards',
            single_shards[0].include?('#define BC2CPP_SHARD_PRELUDE_ONLY') &&
            single_shards[1].lines.all? { |line| line.start_with?('//') })
suite.check('same-owner static references receive cross-shard declarations',
            single_main.include?("int B_helper(int x);\n") &&
            (single_main + single_shards.join).include?("\nint B_helper(int x) {"))
suite.check('same-owner mutable method state receives one external declaration',
            single_main.include?("extern int method_counter;\n"))
suite.check('same-owner constant method state receives external linkage',
            single_main.include?("extern const int method_table[];\n") &&
            (single_main + single_shards.join).include?('extern const int method_table[] ='))
units = 12.times.map { |i| { owner: 'Large', code: 'x' * 100, index: i } } +
        [{ owner: 'Small', code: 'y' * 100, index: 12 }]
groups = ShardOutput.assign(units, 4)
suite.check('oversized owner units balance across the requested shards',
            groups.all? { |g| g.any? { |u| u[:owner] == 'Large' } } &&
            groups.map { |g| g.sum { |u| u[:code].bytesize } }.max == 400)
suite.check('placement retains every method exactly once and in source order within each shard',
            groups.flatten.map { |u| u[:index] }.sort == (0..12).to_a &&
            groups.all? { |g| g.map { |u| u[:index] } == g.map { |u| u[:index] }.sort })
suite.check('placement is deterministic', groups == ShardOutput.assign(units, 4))
balanced = %w[A A B B].each_with_index.map { |owner, i| { owner: owner, code: 'x' * 50, index: i } }
suite.check('owners fitting the byte budget remain together',
            ShardOutput.assign(balanced, 2).map { |g| g.map { |u| u[:owner] } } == [%w[A A], %w[B B]])
hot_groups = ShardOutput.assign(units, 4, Set.new(['Large']))
suite.check('an explicitly hot oversized owner stays entirely in the main file',
            hot_groups[0].count { |u| u[:owner] == 'Large' } == 12 &&
            hot_groups.drop(1).flatten.none? { |u| u[:owner] == 'Large' })
tier_main, _tier_files, unit_tiers = ShardOutput.split_with_tiers(single_owner, 'chk', 3, 'O1')
suite.check('each split unit reports the tier of the shard containing its body',
            unit_tiers == ['B', 'A'].map { |owner| tier_main.include?("int #{owner}_one_impl(int x) {") ? 'default' : 'O1' } &&
            unit_tiers.sort == %w[O1 default])
saved_split_owners.nil? ? ENV.delete('BC2CPP_SHARD_SPLIT_OWNERS') : ENV['BC2CPP_SHARD_SPLIT_OWNERS'] = saved_split_owners

puts '-- linkage'
if Bc2cppCxx.executable?(Bc2cppCxx.compiler.first)
  { 'two owners' => [main, shards, "309 713 1 7\n"],
    'one oversized owner' => [single_main, single_shards, "310 715 1 7\n"] }.each do |description, split|
    main_text, shard_texts, expected = split
    Dir.mktmpdir('bc2cpp-shard-output') do |dir|
      File.write(File.join(dir, 'chk_gen.cpp'), main_text)
      shard_texts.each_with_index { |text, i| File.write(ShardOutput.shard_path(dir, 'chk', i + 1), text) }
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
      sources = [File.join(dir, 'chk_gen.cpp'), *shard_texts.each_index.map { |i| ShardOutput.shard_path(dir, 'chk', i + 1) },
                 File.join(dir, 'main.cpp')]
      # -Os makes the stateless helpers inline (SHARED_HELPERS).
      %w[-O2 -Os].each do |opt|
        out, err, status = Bc2cppCxx.capture3('-std=c++17', opt, '-Wall', '-Werror', "-I#{dir}", *sources, '-o', binary)
        suite.check("#{description} #{opt}: the split program compiles warning-free and links", status.success?)
        puts err.lines.first(20).join unless status.success?
        next unless status.success?

        out, = Open3.capture2(binary)
        # A_one: bump() is the first call (101) + B_helper(2) = 105; B_one: bump() second (202) + 2 = 204. Shared
        # counter and call count carry on into the second round: 305 + 404.
        suite.check("#{description} #{opt}: prelude state and statics are one instance across shards (#{out.strip})",
                    out == expected)
      end
    end
  end
else
  puts '  SKIP: no C++ compiler'
end

# The shard tier flags (docs/notes/bc2cpp-shard-tiers.md): a GCC optimize pragma on the shards other than the main
# file, and the hot owners kept in the main file. The flags are --shard-cold-opt= and --shard-hot-owners=.
TIER_PRELUDE = <<~'CPP'
  #include <stdio.h>
  static int tier_counter = 0;
  static int tier_bump(void) { return ++tier_counter; }
CPP

def tier_program_text
  text = String.new(TIER_PRELUDE)
  [['A', 'hot_a', 'return x * 3 + tier_bump();'], ['B', 'hot_b', 'return x * 5 + tier_bump();'],
   ['C', 'cold_c', 'return x - 7 + tier_bump();'], ['D', 'cold_d', 'return (x ^ 11) + tier_bump();']].each do |owner, name, body|
    text << ShardOutput.unit_mark(owner) << "int #{name}(int x) { #{body} }\n"
  end
  text << ShardOutput::HOOKS_MARK << "/* hooks */\n"
end

# BC2CPP_SHARD_MIN_BYTES (the existing knob) lowers the threshold so the small fixture splits.
def tier_split(tier, hot, shards = 3)
  tier_with_env('BC2CPP_SHARD_MIN_BYTES' => '1') { ShardOutput.split(tier_program_text, 'chk', shards, tier, hot) }
end

def tier_with_env(pairs)
  saved = pairs.keys.to_h { |k| [k, ENV.fetch(k, nil)] }
  pairs.each { |k, v| v.nil? ? ENV.delete(k) : ENV[k] = v }
  yield
ensure
  saved&.each { |k, v| v.nil? ? ENV.delete(k) : ENV[k] = v }
end

puts '-- tiers'
Dir.mktmpdir('bc2cpp-shard-tiers') do |dir|
  hot_file = File.join(dir, 'hot.txt')
  File.write(hot_file, "# profile hot owners\nA\nB\n")
  hot_set = Set.new(%w[A B])

  plain_main, plain_files = tier_split(nil, nil)
  suite.check('without a tier there is no pragma', plain_files.none? { |t| t.include?('#pragma GCC optimize') })
  ignored_main, ignored_files = tier_split(nil, hot_set)
  suite.check('without a tier the hot owners are ignored',
              ignored_main == plain_main && ignored_files == plain_files)

  argv = ['x.rb', '--shard-cold-opt=O1', "--shard-hot-owners=#{hot_file}", 'y.rb']
  flags = ShardOutput.take_argv!(argv)
  suite.check('the flags come out of argv and the sources stay',
              argv == ['x.rb', 'y.rb'] && flags[:tier] == 'O1' && flags[:hot] == hot_set)
  suite.check('no flags give no tier and no hot owners',
              ShardOutput.take_argv!(['x.rb']) == { tier: nil, hot: Set.new })

  refused = lambda do |args|
    ShardOutput.take_argv!(args)
    false
  rescue ShardOutput::Error
    true
  end
  suite.check('a hot-owners flag without a cold level is refused', refused.call(["--shard-hot-owners=#{hot_file}"]))
  suite.check('a bad cold level is refused', refused.call(['--shard-cold-opt=fast']))

  tier_main, tier_files = tier_split('O1', nil)
  nonempty = tier_files.select { |t| t.include?('#define BC2CPP_SHARD_PRELUDE_ONLY') }
  guarded = "#if defined(__GNUC__) && !defined(__clang__)\n#pragma GCC optimize (\"O1\")\n#endif\n"
  suite.check('a tier puts the GCC-only pragma at the top of every non-empty shard',
              !nonempty.empty? && nonempty.all? { |t| t.start_with?(guarded) })
  suite.check('the main file gets no pragma', !tier_main.include?('#pragma GCC optimize'))

  hot_main, hot_files = tier_split('O1', hot_set)
  suite.check('hot owners are defined in the main file',
              hot_main.include?('int hot_a(') && hot_main.include?('int hot_b('))
  suite.check('no shard defines a hot owner',
              hot_files.none? { |t| t.include?('int hot_a(') || t.include?('int hot_b(') })
  suite.check('cold owners are in the shards',
              hot_files.any? { |t| t.include?('int cold_c(') } && hot_files.any? { |t| t.include?('int cold_d(') })
  suite.check('the main file keeps the hooks', hot_main.include?('/* hooks */'))

  # The per-method report's tiers (bc2cpp.rb COMPILED_METHOD_REPORT): hot owners stay "default", cold units take the level.
  owners = ShardOutput.sections(tier_program_text)[1].map { |u| u[:owner] }
  tiered = tier_with_env('BC2CPP_SHARD_MIN_BYTES' => '1') do
    ShardOutput.split_with_tiers(tier_program_text, 'chk', 3, 'O1', hot_set)[2]
  end
  suite.check('each unit reports one tier per print position',
              tiered.size == owners.size && owners.size.positive?)
  suite.check('hot owners report default and cold units report the cold level',
              owners.zip(tiered).all? { |owner, tier| tier == (hot_set.include?(owner) ? 'default' : 'O1') } &&
              tiered.include?('O1'))
  untiered = tier_with_env('BC2CPP_SHARD_MIN_BYTES' => '1') do
    ShardOutput.split_with_tiers(tier_program_text, 'chk', 3, nil, nil)[2]
  end
  suite.check('without a tier every unit reports default', untiered.all? { |tier| tier == 'default' })

  if Bc2cppCxx.executable?(Bc2cppCxx.compiler.first)
    tiered = File.join(dir, 'tiered')
    untiered = File.join(dir, 'untiered')
    [[tiered, hot_main, hot_files], [untiered, plain_main, plain_files]].each do |d, main_text, files|
      FileUtils.mkdir_p(d)
      File.write(File.join(d, 'chk_gen.cpp'), main_text)
      files.each_with_index { |t, i| File.write(ShardOutput.shard_path(d, 'chk', i + 1), t) }
      File.write(File.join(d, 'driver.cpp'), <<~'CPP')
        #include <cstdio>
        int hot_a(int); int hot_b(int); int cold_c(int); int cold_d(int);
        int main() {
          int a = hot_a(2); int b = hot_b(2); int c = cold_c(2); int d = cold_d(2);
          std::printf("%d %d %d %d\n", a, b, c, d);
          return 0;
        }
      CPP
    end
    run_split = lambda do |d, files|
      sources = [File.join(d, 'chk_gen.cpp'), *files.each_index.map { |i| ShardOutput.shard_path(d, 'chk', i + 1) },
                 File.join(d, 'driver.cpp')]
      bin = File.join(d, 'prog')
      _out, err, status = Bc2cppCxx.capture3('-std=c++17', '-O2', '-Wall', '-Werror', *sources, '-o', bin)
      puts err.lines.first(20).join unless status.success?
      status.success? ? bin : nil
    end
    tiered_bin = run_split.call(tiered, hot_files)
    untiered_bin = run_split.call(untiered, plain_files)
    suite.check('the tiered split compiles warning-free at -O2 and links', !tiered_bin.nil?)
    if tiered_bin && untiered_bin
      tiered_out, = Open3.capture2(tiered_bin)
      untiered_out, = Open3.capture2(untiered_bin)
      suite.check("the tiered program prints what the untiered one prints (#{tiered_out.strip})",
                  tiered_out == untiered_out && !tiered_out.strip.empty?)
    end
  else
    puts '  SKIP: no C++ compiler'
  end
end

# SHARD_COLOCATE (tools/bc2cpp/shard_colocate.rb): a single-site `_impl` is copied, static, beside its caller.
puts '-- colocate'
COLO_PRELUDE = <<~'CPP'
  #include <stdio.h>
  typedef long mrb_value;
  struct mrb_gc { int arena_idx; };
  struct mrb_state { mrb_gc gc; };
  struct bc2cpp_res { mrb_state* M; int idx; mrb_value v; };
  static mrb_value bc2cpp_cfunc_result(bc2cpp_res r) { return r.v; }
  mrb_value A_top_impl(mrb_state* M, mrb_value self);
  mrb_value A_other_impl(mrb_state* M, mrb_value self);
  mrb_value B_mid_impl(mrb_state* M, mrb_value self);
  mrb_value C_leaf_impl(mrb_state* M, mrb_value self, mrb_value x);
  mrb_value D_two_impl(mrb_state* M, mrb_value self);
  mrb_value E_state_impl(mrb_state* M, mrb_value self);
  mrb_value F_live_impl(mrb_state* M, mrb_value self);
  mrb_value G_rec_impl(mrb_state* M, mrb_value self);
  mrb_value H_ping_impl(mrb_state* M, mrb_value self);
  mrb_value H_pong_impl(mrb_state* M, mrb_value self);
  mrb_value K_kept_impl(mrb_state* M, mrb_value self);
  mrb_value L_ctx_impl(mrb_state* M, mrb_value self);
  mrb_value N_guard_impl(mrb_state* M, mrb_value self);
  mrb_value P_one_impl(mrb_state* M, mrb_value self);
CPP
COLO_A = <<~'CPP'
  mrb_value A_top_impl(mrb_state* M, mrb_value self) {
    return B_mid_impl(M, self) + D_two_impl(M, self) + E_state_impl(M, self) + F_live_impl(M, self) +
           G_rec_impl(M, self) + K_kept_impl(M, self);
  }
  mrb_value A_other_impl(mrb_state* M, mrb_value self) {
    return D_two_impl(M, self) + (self > 0 ? H_ping_impl(M, self - 1) : 0) + L_ctx_impl(M, self) +
           N_guard_impl(M, self) + P_one_impl(M, self);
  }
CPP
COLO_B = <<~'CPP'
  static const int b_spec = 7;
  mrb_value B_mid_impl(mrb_state* M, mrb_value self) {
    /* C_leaf_impl( in a comment is no call */
    return C_leaf_impl(M, self, b_spec);
  }
  static mrb_value B_mid(mrb_state* M, mrb_value self) {
    return bc2cpp_cfunc_result({M, M->gc.arena_idx, B_mid_impl(M, self)});
  }
  mrb_value F_live_impl(mrb_state* M, mrb_value self) { return self * 3; }
  static mrb_value F_live(mrb_state* M, mrb_value self) {
    return bc2cpp_cfunc_result({M, M->gc.arena_idx, F_live_impl(M, self)});
  }
CPP
COLO_C = <<~'CPP'
  mrb_value C_leaf_impl(mrb_state* M, mrb_value self, mrb_value x) {
    return self + x;
  }
  mrb_value D_two_impl(mrb_state* M, mrb_value self) {
    return self * 10;
  }
  mrb_value E_state_impl(mrb_state* M, mrb_value self) {
    static int calls = 0;
    return ++calls * 1000;
  }
  mrb_value G_rec_impl(mrb_state* M, mrb_value self) {
    return self > 3 ? self : G_rec_impl(M, self + 1);
  }
  mrb_value H_ping_impl(mrb_state* M, mrb_value self) { return self > 0 ? H_pong_impl(M, self - 1) : 100; }
  mrb_value H_pong_impl(mrb_state* M, mrb_value self) { return self > 0 ? H_ping_impl(M, self - 1) : 200; }
  mrb_value K_kept_impl(mrb_state* M, mrb_value self) { return 5; }
  struct L$ctx { long v; };
  mrb_value L_ctx_impl(mrb_state* M, mrb_value self) { L$ctx c{3}; return self + c.v; }
  static inline mrb_value N_guard_impl_unguarded(mrb_state* M, mrb_value self) { return self + 11; }
  mrb_value N_guard_impl(mrb_state* M, mrb_value self) { return N_guard_impl_unguarded(M, self) * 2; }
  static inline mrb_value P_help(mrb_state* M, mrb_value self) { return self ^ 6; }
  mrb_value P_one_impl(mrb_state* M, mrb_value self) { return P_help(M, self) + P_help(M, self + 1); }
CPP
COLO_HOOKS = <<~'CPP'
  int run_all() {
    mrb_value (*const rows[])(mrb_state*, mrb_value) = { F_live };
    mrb_state m{};
    return (int)(A_top_impl(&m, 1) + A_other_impl(&m, 3) + rows[0](&m, 1));
  }
CPP

def colo_text
  COLO_PRELUDE + ShardOutput.unit_mark('A') + COLO_A + ShardOutput.unit_mark('B') + COLO_B +
    ShardOutput.unit_mark('C') + COLO_C + ShardOutput::HOOKS_MARK + COLO_HOOKS
end

def colo_split(mode, keep = nil)
  saved_keep = ShardColocate.keep
  ShardColocate.keep = keep
  tier_with_env('BC2CPP_SHARD_MIN_BYTES' => '1', 'BC2CPP_SHARD_COLOCATE' => mode) { ShardOutput.split(colo_text, 'colo', 3) }
ensure
  ShardColocate.keep = saved_keep
end

colo_main, colo_shards = colo_split(nil, ['K_kept_impl'])
colo_all = colo_main + colo_shards.join
a_shard = [colo_main, *colo_shards].find { |t| t.include?('mrb_value A_top_impl(mrb_state* M, mrb_value self) {') }
suite.check('a single-site callee and the one its body calls are copied, static, into the caller\'s shard',
            a_shard.include?("\nBC2CPP_COLO_ATTR static mrb_value bc2cpp_colo_B_mid_impl(mrb_state* M, mrb_value self) {") &&
              a_shard.include?("\nBC2CPP_COLO_ATTR static mrb_value bc2cpp_colo_C_leaf_impl(mrb_state* M, mrb_value self, mrb_value x) {"))
suite.check('the copies are declared ahead of their root caller, which calls the first',
            a_shard.index('BC2CPP_COLO_ATTR static mrb_value bc2cpp_colo_C_leaf_impl(mrb_state* M, mrb_value self, mrb_value x);') <
              a_shard.index('mrb_value A_top_impl(mrb_state* M, mrb_value self) {') &&
              a_shard.include?('return bc2cpp_colo_B_mid_impl(M, self) + D_two_impl(M, self)'))
suite.check('the copy of a chain member calls the next copy; the originals stay as they were',
            a_shard.include?('return bc2cpp_colo_C_leaf_impl(M, self, b_spec);') &&
              colo_all.include?("mrb_value B_mid_impl(mrb_state* M, mrb_value self) {\n  /* C_leaf_impl( in a comment is no call */\n  return C_leaf_impl(M, self, b_spec);"))
refused = { 'two call sites' => 'D_two_impl', 'a mutable function-local static' => 'E_state_impl',
            'a registered wrapper' => 'F_live_impl', 'recursion' => 'G_rec_impl', 'a cycle' => 'H_ping_impl',
            'an entry-header name' => 'K_kept_impl', 'a type its unit defines' => 'L_ctx_impl',
            'an inline helper it does not take along' => 'P_one_impl' }
refused.each do |why, name|
  suite.check("#{why} keeps #{name} uncopied", !colo_all.include?("bc2cpp_colo_#{name}"))
end
a_other = [colo_main, *colo_shards].find { |t| t.include?('mrb_value A_other_impl(mrb_state* M, mrb_value self) {') }
suite.check('a guard wrapper\'s static inline body is copied along with it',
            a_other.include?("\nBC2CPP_COLO_ATTR static mrb_value bc2cpp_colo_N_guard_impl_unguarded(mrb_state* M, mrb_value self) {") &&
              a_other.include?('return bc2cpp_colo_N_guard_impl_unguarded(M, self) * 2;') &&
              colo_all.include?("\nstatic inline mrb_value N_guard_impl_unguarded(mrb_state* M, mrb_value self) {"))
aff_units = [{ owner: 'R', code: 'r' * 100, colo_owners: { 'S' => 80 } }, { owner: 'S', code: 's' * 100 },
             { owner: 'T', code: 't' * 100 }, { owner: 'U', code: 'u' * 100 }].each_with_index.map { |u, i| u.merge(index: i) }
aff = ShardOutput.assign(aff_units, 2)
suite.check('an owner whose copies another owner holds shares that owner\'s shard when both fit',
            aff.any? { |g| g.map { |u| u[:owner] }.sort == %w[R S] })
big = aff_units.map { |u| u[:owner] == 'S' ? u.merge(code: 's' * 400) : u }
suite.check('affinity never makes a chunk larger than one shard\'s share',
            ShardOutput.assign(big, 2).none? { |g| g.map { |u| u[:owner] }.sort == %w[R S] })
off_main, off_shards = colo_split('0')
suite.check('BC2CPP_SHARD_COLOCATE=0 copies nothing', !(off_main + off_shards.join).include?('bc2cpp_colo_'))
all_main, all_shards = colo_split('all', ['K_kept_impl'])
suite.check('BC2CPP_SHARD_COLOCATE=all copies a callee whose wrapper is registered, too',
            (all_main + all_shards.join).include?('BC2CPP_COLO_ATTR static mrb_value bc2cpp_colo_F_live_impl('))
one_main, = tier_with_env('BC2CPP_SHARD_COLOCATE' => nil, 'BC2CPP_SHARD_MIN_BYTES' => nil) { ShardOutput.split(colo_text, 'colo', 3) }
suite.check('under the shard threshold the one translation unit holds the copies after every unit',
            one_main.index('BC2CPP_COLO_ATTR static mrb_value bc2cpp_colo_B_mid_impl(mrb_state* M, mrb_value self) {') >
              one_main.index('mrb_value K_kept_impl('))
if Bc2cppCxx.executable?(Bc2cppCxx.compiler.first)
  outputs = { 'colocated' => [colo_main, colo_shards], 'all' => [all_main, all_shards], 'off' => [off_main, off_shards],
              'one unit' => [one_main, []] }.map do |label, (main_text, shard_texts)|
    Dir.mktmpdir('bc2cpp-shard-colocate') do |dir|
      File.write(File.join(dir, 'colo_gen.cpp'), main_text)
      shard_texts.each_with_index { |text, i| File.write(ShardOutput.shard_path(dir, 'colo', i + 1), text) }
      File.write(File.join(dir, 'main.cpp'), "#include <cstdio>\nint run_all();\nint main() { std::printf(\"%d %d\\n\", run_all(), run_all()); }\n")
      sources = [File.join(dir, 'colo_gen.cpp'), *shard_texts.each_index.map { |i| ShardOutput.shard_path(dir, 'colo', i + 1) },
                 File.join(dir, 'main.cpp')]
      _out, err, status = Bc2cppCxx.capture3('-std=c++17', '-O2', '-Wall', '-Werror', '-Wno-unused-function', *sources,
                                             '-o', File.join(dir, 'colo'))
      puts err.lines.first(20).join unless status.success?
      suite.check("colocate #{label}: the program compiles warning-free and links", status.success?)
      status.success? ? Open3.capture2(File.join(dir, 'colo')).first : nil
    end
  end
  suite.check("the colocated programs print what the uncolocated one prints (#{outputs[2].to_s.strip})",
              !outputs[2].to_s.strip.empty? && outputs.uniq.size == 1)
else
  puts '  SKIP: no C++ compiler'
end

puts '-- implicit state'
IMPLICIT_TEXT = <<~'CPP'
  #include <stdio.h>
  typedef struct mrb_state { int calls; } mrb_state;
  typedef struct { long w; } mrb_value;
  namespace chk {
  static mrb_value helper(mrb_state* M, mrb_value v, int k) { M->calls++; v.w += k; return v; }
  static mrb_value over(mrb_value v) { return v; }
  static mrb_value over(mrb_state* M, mrb_value v) { M->calls += 10; return over(v); }
  } // namespace chk
  using namespace chk;
  mrb_value A_impl(mrb_state* M, mrb_value self);
  mrb_value A_impl(mrb_state* M, mrb_value self) { return over(M, helper(M, self, 2)); }
  static mrb_value entry(mrb_state* M, mrb_value self) { return A_impl(M, self); }
  typedef mrb_value (*fn_t)(mrb_state*, mrb_value);
  static const fn_t table[] = { entry };
  extern "C" void chk_gem_init(mrb_state* M) { (void)M; }
  int run(mrb_state* M) { mrb_value v = { 40 }; return (int)table[0](M, v).w + M->calls; }
CPP
implicit = ImplicitState.rewrite([IMPLICIT_TEXT]).first
suite.check('IMPLICIT_STATE: called-only functions lose the state parameter and read it in their body',
            implicit.include?('static mrb_value helper(mrb_value v, int k) { BC2CPP_IMPLICIT_M M->calls++;') &&
              implicit.include?("mrb_value A_impl(mrb_value self);\n") &&
              implicit.include?('mrb_value A_impl(mrb_value self) { BC2CPP_IMPLICIT_M return over(M, helper(M, self, 2)); }'))
suite.check('IMPLICIT_STATE: an address-taken entry and an overloaded name keep it, checked; an extern "C" init stores it',
            implicit.include?('static mrb_value entry(mrb_state* M, mrb_value self) { BC2CPP_STATE_CHECK(M); return') &&
              implicit.include?('static mrb_value over(mrb_state* M, mrb_value v) { BC2CPP_STATE_CHECK(M);') &&
              implicit.include?('extern "C" void chk_gem_init(mrb_state* M) { bc2cpp_implicit_state = M; (void)M; }'))
suite.check('IMPLICIT_STATE: one forwarder per converted function (helper, A_impl, run), in its namespace',
            implicit.scan(/^#define (BC2CPP_IMPLICIT_FWD_\w+)/).uniq.size == 3 &&
              implicit.index('decltype(auto) helper(mrb_state* bc2cpp_m, mrb_value bc2cpp_a0, int bc2cpp_a1)') <
                implicit.index('} // namespace chk'))
if Bc2cppCxx.executable?(Bc2cppCxx.compiler.first)
  Dir.mktmpdir('bc2cpp-implicit-state') do |dir|
    File.write(File.join(dir, 'chk.cpp'), implicit + <<~'CPP')
      #include <stdlib.h>
      int main(int argc, char**) {
        mrb_state s = { 0 }, other = { 0 };
        chk_gem_init(&s);
        printf("%d\n", run(&s));
        fflush(stdout);
        if (argc > 1) run(&other);
        return 0;
      }
    CPP
    binary = File.join(dir, 'chk')
    flags = ['-std=c++17', '-O2', '-Wall', '-Werror', File.join(dir, 'chk.cpp'), '-o', binary]
    _, err, status = Bc2cppCxx.capture3('-DBC2CPP_IMPLICIT_STATE=1', '-DBC2CPP_IMPLICIT_STATE_CHECK=1', *flags)
    suite.check('IMPLICIT_STATE: the rewritten text compiles warning-free', status.success?)
    puts err.lines.first(20).join unless status.success?
    if status.success?
      out, = Open3.capture2(binary)
      suite.check("IMPLICIT_STATE: it runs through the global (#{out.strip})", out == "53\n")
      _, st = Open3.capture2e(binary, 'second', rlimit_core: 0)
      suite.check('IMPLICIT_STATE: a second mrb_state aborts under BC2CPP_IMPLICIT_STATE_CHECK', !st.success?)
    end
    _, _, plain = Bc2cppCxx.capture3(*flags)
    suite.check('IMPLICIT_STATE: without -DBC2CPP_IMPLICIT_STATE the text does not compile', !plain.success?)
  end
else
  puts '  SKIP: no C++ compiler'
end

puts '-- generated code'
mrbc = MrbcRbDefault.from_env || ENV.fetch('PATH', '').split(File::PATH_SEPARATOR).map { |d| File.join(d, 'mrbc') }.find { |p| File.executable?(p) } || MrbcRbDefault.command
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
    # -Os: the size-optimized build is the one SHARED_HELPERS gives one body per gem. -fno-inline keeps every
    # called helper out of line, so a per-shard copy cannot hide inside its callers.
    saved_flags = ENV.fetch('BC2CPP_CXXFLAGS', nil)
    ENV['BC2CPP_CXXFLAGS'] = "#{saved_flags} -Os -fno-inline"
    built, output = Bc2cppFixtureRuntime.run(dir, err, OWNERS, body, build: build, full: true, extra_srcs: [shard])
    saved_flags.nil? ? ENV.delete('BC2CPP_CXXFLAGS') : ENV['BC2CPP_CXXFLAGS'] = saved_flags
    suite.check('the main file and the shard compile and link', built)
    nm = ENV.fetch('NM', 'nm')
    # -p: symbol-table order, so the two listings pair line for line.
    syms, nm_status = Open3.capture2(nm, '-p', File.join(dir, 'fixture')) if built
    names, = Open3.capture2(nm, '-p', '-C', File.join(dir, 'fixture')) if nm_status&.success?
    if nm_status&.success?
      # The link keeps every local symbol: a mangled name listed twice is a body each shard compiled. GCC's own
      # clones (`.isra.0`, `.constprop.0`) are local to the unit that made them whatever the original's linkage, and
      # a function template's instances stay per unit (stateless_helpers).
      copies = syms.lines.zip(names.lines).map { |l, d| [*l.split(' ', 3), d.to_s.split(' ', 3)[2].to_s] }
                   .select { |_, kind, name, plain| kind == 't' && name.include?('bc2cpp_shard_fixture') && !plain[/\A[^(]*/].include?('<') }
                   .map { |_, _, name, _| name.strip }.grep_v(/\.(?:isra|constprop|part|cold)\b/).tally.select { |_, n| n > 1 }
      suite.check("SHARED_HELPERS: no gem-namespace function has a copy per shard (#{copies.keys.first(3).join('; ')})",
                  copies.empty?)
    else
      puts "  SKIP helper copy count: no #{nm}"
    end
    sections = Bc2cppFixtureRuntime.sections(output.to_s)
    suite.check('the sharded build runs the fixture as the interpreter does',
                sections['interpreted']&.last == 'end' && sections['interpreted'] == sections['compiled'])
    puts output.to_s.lines.last(20).join unless built && sections['interpreted'] == sections['compiled']
  end
end

# SHARD_COLOCATE on generated code: a chain of single-site methods across owners. The fixture registers every
# method, so BC2CPP_SHARD_COLOCATE=all reaches the copies a closed build makes of statically dispatched ones.
COLO_SOURCE = <<~'RUBY'
  class ColoTop
    def initialize(n); @n = n; end
    def run(mid); mid.step(@n, [1, 2, 3]) + 1; end
  end
  class ColoMid
    def initialize(leaf); @leaf = leaf; end
    def step(n, list); @leaf.scale(list.sum, n) * 2; end
  end
  class ColoLeaf
    def initialize(k); @k = k; end
    def scale(x, n); n > 2 ? x * n + @k : (x - @k).abs; end
  end
RUBY
COLO_OWNERS = %w[ColoTop ColoMid ColoLeaf].freeze
COLO_DRIVER = <<~'RUBY'
  leaf = ColoLeaf.new(5)
  puts ColoTop.new(4).run(ColoMid.new(leaf))
  puts ColoTop.new(1).run(ColoMid.new(leaf))
  puts ColoTop.new(-2).run(ColoMid.new(ColoLeaf.new(-1)))
  puts 'end'
RUBY
Dir.mktmpdir('bc2cpp-shard-colocate-generated') do |dir|
  saved = %w[BC2CPP_SHARDS BC2CPP_SHARD_MIN_BYTES BC2CPP_SHARD_COLOCATE].to_h { |k| [k, ENV.fetch(k, nil)] }
  ENV.update('BC2CPP_SHARDS' => '3', 'BC2CPP_SHARD_MIN_BYTES' => '1', 'BC2CPP_SHARD_COLOCATE' => 'all')
  code, err = Bc2cppFixtureRuntime.generate(COLO_SOURCE, dir, core: true, only_owners: COLO_OWNERS)
  saved.each { |k, v| v.nil? ? ENV.delete(k) : ENV[k] = v }
  shards = [1, 2].map { |k| ShardOutput.shard_path(dir, 'fixture', k) }
  text = code + shards.map { |p| File.exist?(p) ? File.read(p) : '' }.join
  suite.check('SHARD_COLOCATE copies the generated single-site callees, static, beside their callers',
              text.match?(/^BC2CPP_COLO_ATTR static mrb_value bc2cpp_colo_ColoMid_step_impl\(/) &&
                text.match?(/^BC2CPP_COLO_ATTR static mrb_value bc2cpp_colo_ColoLeaf_scale_impl\(/))
  build = Bc2cppFixtureRuntime.full_or_build
  if build.nil?
    puts '  SKIP colocate behavioural comparison: needs a full-core libmruby'
  else
    body = <<~CPP
      static int scenario(mrb_state* M) {
        std::fflush(stdout);
        mrb_load_string(M, R"SHD(#{COLO_DRIVER})SHD");
        std::fflush(stdout);
        if (M->exc) { mrb_print_error(M); M->exc = nullptr; return 1; }
        return 0;
      }
    CPP
    built, output = Bc2cppFixtureRuntime.run(dir, err, COLO_OWNERS, body, build: build, full: true, extra_srcs: shards)
    suite.check('the colocated shards compile and link', built)
    sections = Bc2cppFixtureRuntime.sections(output.to_s)
    suite.check('the colocated build runs the fixture as the interpreter does',
                sections['interpreted']&.last == 'end' && sections['interpreted'] == sections['compiled'])
    puts output.to_s.lines.last(20).join unless built && sections['interpreted'] == sections['compiled']
  end
end

# IMPLICIT_STATE on the colocated generated code: the generation drops the state parameter, and the program built with
# BC2CPP_IMPLICIT_STATE (its check on) runs as the interpreter does.
Dir.mktmpdir('bc2cpp-implicit-state-generated') do |dir|
  keys = %w[BC2CPP_SHARDS BC2CPP_SHARD_MIN_BYTES BC2CPP_SHARD_COLOCATE BC2CPP_IMPLICIT_STATE BC2CPP_CXXFLAGS]
  saved = keys.to_h { |k| [k, ENV.fetch(k, nil)] }
  ENV.update('BC2CPP_SHARDS' => '3', 'BC2CPP_SHARD_MIN_BYTES' => '1', 'BC2CPP_SHARD_COLOCATE' => 'all',
             'BC2CPP_IMPLICIT_STATE' => '1')
  code, err = Bc2cppFixtureRuntime.generate(COLO_SOURCE, dir, core: true, only_owners: COLO_OWNERS)
  ENV.delete('BC2CPP_IMPLICIT_STATE')
  shards = [1, 2].map { |k| ShardOutput.shard_path(dir, 'fixture', k) }
  text = code + shards.map { |p| File.exist?(p) ? File.read(p) : '' }.join
  suite.check('IMPLICIT_STATE: the generated methods and their colocated copies lose the state parameter',
              text.match?(/^mrb_value ColoMid_step_impl\(mrb_value self\b.*\{ BC2CPP_IMPLICIT_M/) &&
                text.match?(/^BC2CPP_COLO_ATTR static mrb_value bc2cpp_colo_ColoLeaf_scale_impl\(mrb_value self\b/) &&
                text.match?(/^static void bc2cpp_gem_init\(mrb_state\* M\) \{ bc2cpp_implicit_state = M;|bc2cpp_gem_init\(mrb_state\* M\) \{ bc2cpp_implicit_state = M;/))
  build = Bc2cppFixtureRuntime.full_or_build
  if build.nil?
    puts '  SKIP implicit-state behavioural comparison: needs a full-core libmruby'
  else
    ENV['BC2CPP_CXXFLAGS'] = "#{saved['BC2CPP_CXXFLAGS']} -DBC2CPP_IMPLICIT_STATE=1 -DBC2CPP_IMPLICIT_STATE_CHECK=1"
    body = <<~CPP
      static int scenario(mrb_state* M) {
        std::fflush(stdout);
        mrb_load_string(M, R"SHD(#{COLO_DRIVER})SHD");
        std::fflush(stdout);
        if (M->exc) { mrb_print_error(M); M->exc = nullptr; return 1; }
        return 0;
      }
    CPP
    built, output = Bc2cppFixtureRuntime.run(dir, err, COLO_OWNERS, body, build: build, full: true, extra_srcs: shards)
    suite.check('IMPLICIT_STATE: the generated shards compile and link', built)
    sections = Bc2cppFixtureRuntime.sections(output.to_s)
    suite.check('IMPLICIT_STATE: the generated program runs the fixture as the interpreter does',
                sections['interpreted']&.last == 'end' && sections['interpreted'] == sections['compiled'])
    puts output.to_s.lines.last(20).join unless built && sections['interpreted'] == sections['compiled']
  end
  saved.each { |k, v| v.nil? ? ENV.delete(k) : ENV[k] = v }
end

# SHARD_COLOCATE_GUARDS on generated code: a declared program-class parameter that its one program site proves is left
# out of the copy, and kept in the original that outside callers reach. An Integer guard stays. The name is unique:
# one the outside world also uses (`step`) has no site list, so nothing is proven.
GUARD_SOURCE = <<~'RUBY'
  class GuardLeaf
    def initialize(k); @k = k; end
    def scale(n); n * 3 + @k; end
  end
  class GuardMid
    def guard_advance(leaf, n); leaf.scale(n) * 2; end
  end
  class GuardTop
    def run(k); GuardMid.new.guard_advance(GuardLeaf.new(k), k + 1) + 1; end
  end
RUBY
GUARD_SIG = <<~'RBS'
  class GuardMid
    def guard_advance: (GuardLeaf leaf, Integer n) -> untyped
  end
RBS
GUARD_OWNERS = %w[GuardLeaf GuardMid GuardTop].freeze
GUARD_DRIVER = <<~'RUBY'
  puts GuardTop.new.run(4)
  puts GuardTop.new.run(-7)
  puts 'end'
RUBY
copy_body = lambda do |text, name|
  start = text.index(/^BC2CPP_COLO_ATTR static mrb_value bc2cpp_colo_#{name}\(.*\{$/)
  start ? text[start...text.index(/^\}$/, start)] : ''
end
guard_texts = { nil => nil, '0' => nil }.keys.to_h do |mode|
  Dir.mktmpdir('bc2cpp-shard-colocate-guards') do |dir|
    sig = File.join(dir, 'sig')
    FileUtils.mkdir_p(sig)
    File.write(File.join(sig, 'guard.rbs'), GUARD_SIG)
    saved = %w[BC2CPP_SHARDS BC2CPP_SHARD_MIN_BYTES BC2CPP_SHARD_COLOCATE BC2CPP_SHARD_COLOCATE_GUARDS BC2CPP_SIG_DIRS]
            .to_h { |k| [k, ENV.fetch(k, nil)] }
    ENV.update('BC2CPP_SHARDS' => '3', 'BC2CPP_SHARD_MIN_BYTES' => '1', 'BC2CPP_SHARD_COLOCATE' => 'all', 'BC2CPP_SIG_DIRS' => sig)
    mode ? ENV['BC2CPP_SHARD_COLOCATE_GUARDS'] = mode : ENV.delete('BC2CPP_SHARD_COLOCATE_GUARDS')
    code, err = Bc2cppFixtureRuntime.generate(GUARD_SOURCE, dir, core: true, only_owners: GUARD_OWNERS)
    saved.each { |k, v| v.nil? ? ENV.delete(k) : ENV[k] = v }
    shards = [1, 2].map { |k| ShardOutput.shard_path(dir, 'fixture', k) }
    text = code + shards.map { |p| File.exist?(p) ? File.read(p) : '' }.join
    if mode.nil?
      build = Bc2cppFixtureRuntime.full_or_build
      if build.nil?
        puts '  SKIP guard behavioural comparison: needs a full-core libmruby'
      else
        body = <<~CPP
          static int scenario(mrb_state* M) {
            std::fflush(stdout);
            mrb_load_string(M, R"SHD(#{GUARD_DRIVER})SHD");
            std::fflush(stdout);
            if (M->exc) { mrb_print_error(M); M->exc = nullptr; return 1; }
            return 0;
          }
        CPP
        built, output = Bc2cppFixtureRuntime.run(dir, err, GUARD_OWNERS, body, build: build, full: true, extra_srcs: shards)
        sections = Bc2cppFixtureRuntime.sections(output.to_s)
        suite.check('the build without the site-proven guard runs the fixture as the interpreter does',
                    built && sections['interpreted']&.last == 'end' && sections['interpreted'] == sections['compiled'])
        puts output.to_s.lines.last(20).join unless built && sections['interpreted'] == sections['compiled']
      end
    end
    [mode, text]
  end
end
on = guard_texts[nil]
guarded_copy = copy_body.call(on, 'GuardMid_guard_advance_impl')
suite.check('the copy of a guard wrapper leaves out the program-class guard its one site proves',
            !guarded_copy.empty? && !guarded_copy.include?('DECLARED_PARAM_GUARD GuardMid#guard_advance arg 1 '))
suite.check('the copy keeps the Integer guard (the flow\'s Integer bit is not the fixnum test)',
            guarded_copy.include?('DECLARED_PARAM_GUARD GuardMid#guard_advance arg 2 '))
suite.check('the original keeps both guards for its outside callers',
            on.match?(/^mrb_value GuardMid_guard_advance_impl\(.*\{\n.*DECLARED_PARAM_GUARD GuardMid#guard_advance arg 1 /))
suite.check('BC2CPP_SHARD_COLOCATE_GUARDS=0 keeps the guard in the copy',
            copy_body.call(guard_texts['0'], 'GuardMid_guard_advance_impl').include?('DECLARED_PARAM_GUARD GuardMid#guard_advance arg 1 '))

suite.finish!
