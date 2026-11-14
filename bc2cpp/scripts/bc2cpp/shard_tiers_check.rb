#!/usr/bin/env ruby
# frozen_string_literal: true

# BC2CPP_SHARD_COLD_OPT and BC2CPP_SHARD_HOT_OWNERS (tools/bc2cpp/shard_output.rb, docs/notes/bc2cpp-shard-tiers.md):
#
#   text (no tools)
#     - without BC2CPP_SHARD_COLD_OPT the split is the default one: no pragma, and a hot list is ignored;
#     - with it, every non-empty shard but the main file starts with `#pragma GCC optimize ("<level>")`, and the owners
#       named in BC2CPP_SHARD_HOT_OWNERS all land in the main file;
#     - a bad level is refused;
#   linkage (needs g++)
#     - the split program with a cold tier compiles warning-free at -O2 with -Werror, links, and prints what the
#       untiered split prints.
#
# Usage: ruby scripts/bc2cpp/shard_tiers_check.rb

require 'fileutils'
require 'open3'
require 'tmpdir'
require_relative '../../tools/bc2cpp/shard_output'

$checks = 0
$failures = []

def check(label, condition)
  $checks += 1
  if condition
    puts "  ok   #{label}"
  else
    $failures << label
    puts "  FAIL #{label}"
  end
end

# Owners A and B are hot in the list, C and D are cold. Each owner has a method and a call into the prelude's state.
PRELUDE = <<~'CPP'
  #include <stdio.h>
  static int counter = 0;
  static int bump(void) { return ++counter; }
CPP

def method_text(owner, name, body)
  "int #{name}(int x) { #{body} }\n"
end

def program_text
  units = [
    ['A', 'hot_a', 'return x * 3 + bump();'],
    ['B', 'hot_b', 'return x * 5 + bump();'],
    ['C', 'cold_c', 'return x - 7 + bump();'],
    ['D', 'cold_d', 'return (x ^ 11) + bump();']
  ]
  text = String.new(PRELUDE)
  units.each do |owner, name, body|
    text << ShardOutput.unit_mark(owner) << method_text(owner, name, body)
  end
  text << ShardOutput::HOOKS_MARK << "/* hooks */\n"
  text
end

def with_env(pairs)
  saved = pairs.keys.to_h { |k| [k, ENV.fetch(k, nil)] }
  pairs.each { |k, v| v.nil? ? ENV.delete(k) : ENV[k] = v }
  yield
ensure
  saved.each { |k, v| v.nil? ? ENV.delete(k) : ENV[k] = v }
end

BASE_ENV = { 'BC2CPP_SHARD_MIN_BYTES' => '1', 'BC2CPP_SHARD_COLD_OPT' => nil, 'BC2CPP_SHARD_HOT_OWNERS' => nil }.freeze

def split_with(env, shards: 3)
  with_env(BASE_ENV.merge(env)) { ShardOutput.split(program_text, 'chk', shards) }
end

puts '-- text'
Dir.mktmpdir('shard-tiers') do |dir|
  hot_file = File.join(dir, 'hot.txt')
  File.write(hot_file, "# profile hot owners\nA\nB\n")

  plain_main, plain_files = split_with({})
  check('without a tier there is no pragma', plain_files.none? { |t| t.include?('#pragma GCC optimize') })
  check('without a tier the hot list is ignored',
        with_env(BASE_ENV.merge('BC2CPP_SHARD_HOT_OWNERS' => hot_file)) { ShardOutput.hot_owners }.empty?)

  tier_main, tier_files = split_with({ 'BC2CPP_SHARD_COLD_OPT' => 'O1' })
  nonempty = tier_files.reject { |t| t.start_with?('// chk_gen_shard') && !t.include?('#define') }
  check('a tier puts the pragma at the top of every non-empty shard',
        nonempty.all? { |t| t.start_with?(%(#pragma GCC optimize ("O1")\n)) })
  check('the main file gets no pragma', !tier_main.include?('#pragma GCC optimize'))

  bad = begin
    split_with({ 'BC2CPP_SHARD_COLD_OPT' => 'fast' })
    false
  rescue ShardOutput::Error
    true
  end
  check('a bad tier level is refused', bad)

  hot_main, hot_files = split_with({ 'BC2CPP_SHARD_COLD_OPT' => 'O1', 'BC2CPP_SHARD_HOT_OWNERS' => hot_file })
  # The hot owners A and B are in the main file: their methods are defined there, and no shard defines them.
  check('hot owners are defined in the main file', hot_main.include?('int hot_a(') && hot_main.include?('int hot_b('))
  check('no shard defines a hot owner', hot_files.none? { |t| t.include?('int hot_a(') || t.include?('int hot_b(') })
  check('cold owners are in the shards', hot_files.any? { |t| t.include?('int cold_c(') } &&
                                         hot_files.any? { |t| t.include?('int cold_d(') })
  # The main file keeps the prelude's state and the hooks.
  check('the main file keeps the hooks', hot_main.include?('/* hooks */'))

  puts '-- linkage'
  cxx = ENV.fetch('CXX', 'g++')
  if system(cxx, '--version', out: File::NULL, err: File::NULL)
    out_dir = File.join(dir, 'split')
    FileUtils.mkdir_p(out_dir)
    tier_main_path = File.join(out_dir, 'chk_gen.cpp')
    File.write(tier_main_path, hot_main)
    hot_files.each_with_index { |t, i| File.write(File.join(out_dir, "chk_gen_shard#{i + 1}.cpp"), t) }
    driver = File.join(out_dir, 'driver.cpp')
    File.write(driver, <<~'CPP')
      #include <stdio.h>
      int hot_a(int); int hot_b(int); int cold_c(int); int cold_d(int);
      int main(void) {
        printf("%d %d %d %d\n", hot_a(2), hot_b(2), cold_c(2), cold_d(2));
        return 0;
      }
    CPP
    objs = []
    ok = true
    ([tier_main_path] + Dir[File.join(out_dir, 'chk_gen_shard*.cpp')].sort).each do |src|
      obj = src.sub(/\.cpp\z/, '.o')
      _o, err, st = Open3.capture3(cxx, '-std=c++17', '-O2', '-Wall', '-Werror', '-c', src, '-o', obj)
      ok &&= st.success?
      puts err unless st.success?
      objs << obj
    end
    bin = File.join(out_dir, 'prog')
    _o, err, st = Open3.capture3(cxx, '-std=c++17', '-O2', '-Wall', '-Werror', driver, *objs, '-o', bin)
    ok &&= st.success?
    puts err unless st.success?
    check('the tiered split compiles warning-free at -O2 and links', ok && st.success?)
    if ok && st.success?
      untiered = File.join(out_dir, 'plain')
      FileUtils.mkdir_p(untiered)
      File.write(File.join(untiered, 'chk_gen.cpp'), plain_main)
      plain_files.each_with_index { |t, i| File.write(File.join(untiered, "chk_gen_shard#{i + 1}.cpp"), t) }
      plain_objs = Dir[File.join(untiered, 'chk_gen*.cpp')].sort.map do |src|
        obj = src.sub(/\.cpp\z/, '.o')
        Open3.capture3(cxx, '-std=c++17', '-O2', '-c', src, '-o', obj)
        obj
      end
      pbin = File.join(untiered, 'prog')
      Open3.capture3(cxx, '-std=c++17', '-O2', driver, *plain_objs, '-o', pbin)
      tiered_out, = Open3.capture2(bin)
      plain_out, = Open3.capture2(pbin)
      check("the tiered program prints what the untiered one prints (#{tiered_out.strip})",
            tiered_out == plain_out && !tiered_out.strip.empty?)
    end
  else
    puts "  SKIP: no C++ compiler (#{cxx})"
  end
end

puts "shard_tiers_check: #{$checks - $failures.size} checks passed"
exit 1 unless $failures.empty?
