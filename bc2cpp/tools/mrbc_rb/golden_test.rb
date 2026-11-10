# frozen_string_literal: true

# Compares MrbcRb.compile with the fork's `mrbc -g`, byte for byte, on the snippets below.
#   MRBC=<path to the fork's mrbc> bundle exec ruby bc2cpp/tools/mrbc_rb/golden_test.rb
# Without MRBC (or when it does not run), the test exits 0 with a SKIP line, since the oracle is not part of CI.

require 'tmpdir'
require 'open3'
require_relative 'mrbc_rb'

SNIPPETS = [
  'x = nil',
  'x = true',
  'x = false',
  'x = self',
  'x = 100',
  'x = -3',
  'x = 1',
  "x = 1\ny = x",
  "x = 2\nx",
  "x = 1\nx = 2",
  '1',
  'nil',
  "x = 1\ny = 2\nz = x",
  "x = 7\ny = 8",
  "x = -1",
  "x = 255\ny = 256",
  "x = -255\ny = -256",
  "x = 40000\ny = -40000",
  "x = 2147483647\ny = -2147483648",
  "x = 1\n\ny = x\n\nx",
  # sends (milestone 2)
  'p',
  'p 1',
  "x = 1\np x",
  "x = 1\np(x, 2)",
  'foo(1, 2)',
  "x = 1\nx.foo",
  "x = 1\nx.foo(2)",
  "p\np",
  "x = 1\np x\np x",
  "x = nil\nself.foo(x)",
  # ADDI and SUBI on a literal
  "x = 1\nx + 2",
  "x = 1\nx - 3",
  "x = 1\nx = x + 1",
  "x = 1\nx + 255",
  "x = 1\ny = 2\nx + y",
  "x = 1\nx * 2",
  "x = 1\nx / 2",
  "x = 1\ny = 2\nx - y",
  "x = 1\ny = 2\nx < y",
  "x = 1\ny = 2\nx == y",
  "x = 1\nx >= 3",
  # if (milestone 3)
  "x = 1\nif x\n  p 1\nend\n2",
  "x = 1\nif x\n  2\nend\np 3",
  "x = 1\nif x\n  2\nelse\n  3\nend\np 4",
  "x = 1\nif x > 2\n  p 1\nelse\n  p 2\nend",
  "x = 1\nif x\n  2\n  3\nelse\n  4\nend",
  "if self\n  1\nend",
  "x = 1\nif x\n  2\nelse\n  3\nend",
  "x = 1\nif x\n  p 1\nend",
  "x = 1\nif x\nend",
  "x = 1\nif x\nelse\n  3\nend\nx",
  "x = 1\nif x\n  2\n  3\nelse\n  4\nend",
  "x = 1\nif x\n  p 2\nelse\n  3\n  p 4\nend\nx",
  "x = 1\nif x\n  p 2\n  p 3\nelse\n  p 4\nend",
  # string and array literals, unless (milestone 4)
  'x = "ab"',
  "x = \"ab\"\nx",
  "x = \"ab\"\ny = \"ab\"\np x, y",
  'x = [1, 2]',
  'x = []',
  "x = 1\nx = [x, 2]",
  "x = [1]\nx.size",
  "x = 1\np x, \"s\"",
  "x = 1\nunless x\n  2\nelse\n  3\nend",
  "x = 1\nunless x\n  2\nend",
  "x = 1\nunless x\n  2\nend\np 3",
  "unless self\n  1\nend",
  # literals: symbols, string interpolation, hash literals (milestone 9)
  'x = :foo',
  "x = :foo\nx",
  ':foo',
  'p :foo',
  "x = :foo\ny = :foo\np x, y",
  "x = :foo\n3",
  ":foo\n3",
  "x = :foo\ny = :bar\nx = :foo",
  'x = :+',
  'x = :"a b"',
  'x = "a#{1}b"',
  "x = 1\ny = \"a\#{x}b\"",
  "x = 1\n\"\#{x}\"",
  "x = 1\n\"a\#{x}\"",
  "x = 1\n\"\#{x}b\"",
  "x = 1\n\"a\#{x}b\#{x}c\"",
  "x = 1\n\"\#{x}\#{x}\"",
  "x = 1\n\"a\#{x}\#{x}\"",
  "x = 1\nx = \"a\#{x}\"\n3",
  "x = 1\np \"a\#{x}b\"",
  "x = 1\np x, \"a\#{x}\"",
  'p "a#{nil}b#{"s"}c#{:foo}"',
  "x = 1\n\"a\#{x}\"\n3",
  ":a\np :b",
  "x = 1\nx + {a: 1}",
  "x = 1\nx.foo(\"a\#{x}\")",
  "x = {#{(1..16).map { |i| "#{i} => #{i}" }.join(', ')}}",
  'x = {}',
  'x = {a: 1}',
  "x = 1\nx = {a: 1, \"k\" => x}",
  'p({a: 1})',
  'p 1, {2 => 3, 4 => 5}',
  '{a: 1}',
  "x = {a: 1}\n3",
  "x = :a\nx = {x => :b}",
  "x = 1\np x, {a: x}",
  "x = {a: 1}\nx.size",
  "{}\n3",
  'x = {a: 1, b: 2, c: 3}'
].freeze

oracle = ENV.fetch('MRBC', nil)
unless oracle && File.executable?(oracle)
  puts 'SKIP: set MRBC to the fork mrbc to run the golden comparison'
  exit 0
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
exit(failures.zero? ? 0 : 1)
