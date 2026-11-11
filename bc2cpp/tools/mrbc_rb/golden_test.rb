# frozen_string_literal: true

# Compares MrbcRb.compile with the fork's `mrbc -g`, byte for byte, on the snippets below.
#   MRBC=<path to the fork's mrbc> bundle exec ruby bc2cpp/tools/mrbc_rb/golden_test.rb
# Without MRBC (or when it does not run) the emitter is checked against the snapshot of the oracle's output instead
# (snapshot.txt, see snapshot.rb: every snippet, group, bc2cpp/ file and, with a world checkout, every gem set), so
# no mrbc is needed; an input not in the snapshot fails.

require 'tmpdir'
require 'open3'
require_relative 'mrbc_rb'
require_relative 'golden_data'
require_relative 'snapshot'

oracle = ENV.fetch('MRBC', nil)
unless oracle && File.executable?(oracle)
  puts 'no MRBC: comparing with the snapshot of the oracle (snapshot.txt)'
  exit MrbcRb::Snapshot.verify
end

failures = 0
SNIPPETS.each do |src|
  Dir.mktmpdir('mrbc_rb') do |dir|
    rb = File.join(dir, 't.rb')
    mrb = File.join(dir, 't.mrb')
    File.binwrite(rb, src + "\n")
    _out, err, status = Open3.capture3(oracle, '-g', '-o', mrb, 't.rb', chdir: dir)
    unless status.success?
      puts "SKIP: the oracle failed on #{src.inspect}: #{err.strip}"
      next
    end
    expected = File.binread(mrb)
    begin
      actual = MrbcRb.compile(src + "\n", 't.rb')
    rescue MrbcRb::Unsupported => e
      puts "UNSUPPORTED #{src.inspect}: #{e.message}"
      failures += 1
      next
    end
    if actual == expected
      puts "ok   #{src.inspect}"
    else
      failures += 1
      puts "FAIL #{src.inspect}: #{actual.bytesize} bytes, expected #{expected.bytesize}"
      puts "  got      #{actual.unpack1('H*')}"
      puts "  expected #{expected.unpack1('H*')}"
    end
  end
end

puts failures.zero? ? "all #{SNIPPETS.size} snippets match" : "#{failures} snippet(s) differ"

# `--no-optimize`: every 3rd snippet again, against `mrbc -g --no-optimize` (the emitter with no_optimize: no peephole, every
# operator a plain send). A snippet the emitter leaves Unsupported there is counted, not failed; a wrong binary is.
noopt_same = noopt_unsupported = noopt_skipped = 0
SNIPPETS.each_with_index do |src, i|
  next unless (i % 3).zero?

  Dir.mktmpdir('mrbc_rb') do |dir|
    rb = File.join(dir, 't.rb')
    mrb = File.join(dir, 't.mrb')
    File.binwrite(rb, src + "\n")
    _out, _err, status = Open3.capture3(oracle, '-g', '--no-optimize', '-o', mrb, 't.rb', chdir: dir)
    unless status.success?
      noopt_skipped += 1
      next
    end
    begin
      actual = MrbcRb.with_options(no_optimize: true) { MrbcRb.compile(src + "\n", 't.rb') }
    rescue MrbcRb::Unsupported, MrbcRb::Error
      noopt_unsupported += 1
      next
    end
    if actual == File.binread(mrb)
      noopt_same += 1
    else
      failures += 1
      puts "FAIL --no-optimize #{src.inspect}"
    end
  end
end
puts "--no-optimize: #{noopt_same} snippets identical, #{noopt_unsupported} unsupported, #{noopt_skipped} rejected by the oracle"

# Multi-file programs (MrbcRb.compile_files): the files of one command line `mrbc -g a.rb b.rb c.rb`, compiled as one program.
# Each group below must match the oracle (a group the emitter leaves Unsupported is a failure here: they are all covered).

multi_failures = 0
MULTI_FILE_GROUPS.each_with_index do |group, gi|
  Dir.mktmpdir('mrbc_rb_multi') do |dir|
    paths = group.each_with_index.map do |src, i|
      File.join(dir, "g#{gi}_#{i}.rb").tap { |path| File.binwrite(path, src) }
    end
    mrb = File.join(dir, 'o.mrb')
    _o, err, status = Open3.capture3(oracle, '-g', '-o', mrb, *paths)
    unless status.success?
      puts "SKIP: the oracle failed on group #{gi}: #{err.strip}"
      next
    end
    begin
      got = MrbcRb.compile_files(group.zip(paths))
    rescue MrbcRb::Unsupported => e
      puts "UNSUPPORTED multi-file group #{gi} #{group.inspect}: #{e.message}"
      multi_failures += 1
      next
    end
    next if got == File.binread(mrb)

    puts "FAIL multi-file group #{gi} #{group.inspect}"
    multi_failures += 1
  end
end

# Files named twice on one command line (`mrbc -g a.rb b.rb a.rb`): the second a.rb reuses the first one's index in the filename table,
# and a node built at line 0 of the next file takes that file's index minus one (init_var_header). [sources, order of the files].
MULTI_FILE_REPEATS = [
  [["a = 1\nputs a\n"], [0, 0]],
  [["a = 1\n", "b = 2\n"], [0, 1, 0]],
  [["a = 1\n", "b = 2\n"], [0, 1, 1]],
  [["a = 1\n", "b = 2\n", "c = 3\n"], [0, 1, 2, 1, 0]],
  [["a = 1\n", "b = 2\n"], [1, 0, 1, 0]],
  [["def m; end\n", "m\n"], [0, 1, 0, 1]],
  [["a = 1\na += 1\n", "b = 2\nputs b\n", "c = 3\n\na += 1\n"], [1, 0, 1]],
  [["a = 1\nputs a\n", "b = 2\nputs b\n"], [0, 1, 0]],
  [["a = 1\n# c\n", "b = 2\n"], [0, 1, 0]]
].freeze
MULTI_FILE_REPEATS.each_with_index do |(sources, order), ri|
  Dir.mktmpdir('mrbc_rb_repeat') do |dir|
    paths = sources.each_with_index.map { |src, i| File.join(dir, "r#{ri}_#{i}.rb").tap { |path| File.binwrite(path, src) } }
    mrb = File.join(dir, 'o.mrb')
    _o, err, status = Open3.capture3(oracle, '-g', '-o', mrb, *order.map { |i| paths[i] })
    unless status.success?
      puts "SKIP: the oracle failed on repeat #{ri}: #{err.strip}"
      next
    end
    begin
      got = MrbcRb.compile_files(order.map { |i| [sources[i], paths[i]] })
    rescue MrbcRb::Unsupported => e
      puts "UNSUPPORTED repeated-file group #{ri}: #{e.message}"
      multi_failures += 1
      next
    end
    next if got == File.binread(mrb)

    puts "FAIL repeated-file group #{ri} #{sources.inspect} #{order.inspect}"
    multi_failures += 1
  end
end
puts multi_failures.zero? ? "all #{MULTI_FILE_GROUPS.size} multi-file groups match" : "#{multi_failures} multi-file group(s) differ"
failures += multi_failures

# Real multi-file inputs: the mrblib files of the gems next to the oracle (the order the build compiles them: sorted), each set
# whole and then each pair of neighbours. Unsupported is counted, not failed; a wrong binary is.
mruby_dir = File.expand_path('../..', oracle)
world_root = File.expand_path('../..', mruby_dir)
sets = { 'core mrblib' => Dir["#{mruby_dir}/mrblib/*.rb"].sort.reject { |p| p.end_with?('/10error.rb') } }
(Dir["#{mruby_dir}/mrbgems/*"] + Dir["#{world_root}/3rd/*"] + Dir["#{world_root}/mruby-*"]).sort.each do |gem_dir|
  sets[File.basename(gem_dir)] = Dir["#{gem_dir}/mrblib/**/*.rb"].sort
end
sets.reject! { |_, files| files.size < 2 }
multi_total = multi_same = multi_unsupported = 0
sets.each do |name, files|
  ([files] + files.each_cons(2).to_a).each do |paths|
    multi_total += 1
    Dir.mktmpdir('mrbc_rb_multi') do |dir|
      mrb = File.join(dir, 'o.mrb')
      _o, _e, status = Open3.capture3(oracle, '-g', '-o', mrb, *paths)
      unless status.success?
        multi_total -= 1
        next
      end
      begin
        got = MrbcRb.compile_files(paths.map { |path| [File.binread(path), path] })
      rescue MrbcRb::Unsupported, MrbcRb::Error
        multi_unsupported += 1
        next
      end
      if got == File.binread(mrb)
        multi_same += 1
      else
        puts "  DIFF #{name}: #{paths.map { |p| File.basename(p) }.join(' ')}"
        failures += 1
      end
    end
  end
end
puts "multi-file corpus: #{multi_same} of #{multi_total} file sets identical (#{sets.size} gems, #{multi_unsupported} unsupported)"

# The corpus: every Ruby file under bc2cpp/ that the emitter covers must match the oracle. A file it does not cover is
# counted, not failed (Unsupported is the honest answer; a wrong binary is not).
corpus = Dir.glob('bc2cpp/**/*.rb').sort
covered = 0
corpus_failures = []
corpus.each do |path|
  src = File.binread(path)
  begin
    got = MrbcRb.compile(src, path)
  rescue MrbcRb::Unsupported, MrbcRb::Error
    next
  end
  covered += 1
  Dir.mktmpdir('mrbc_rb_corpus') do |dir|
    out = File.join(dir, 'c.mrb')
    _o, _e, st = Open3.capture3(oracle, '-g', '-o', out, path)
    corpus_failures << path unless st.success? && File.binread(out) == got
  end
end
puts "corpus: #{covered} of #{corpus.size} files covered, #{corpus_failures.size} differ from the oracle"
corpus_failures.each { |path| puts "  DIFF #{path}" }
failures += corpus_failures.size
puts failures.zero? ? 'all checks pass' : "#{failures} problem(s)"
exit(failures.zero? ? 0 : 1)
