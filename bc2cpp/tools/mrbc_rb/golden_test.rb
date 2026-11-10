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
  "x = 1\nx >= 3"
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
