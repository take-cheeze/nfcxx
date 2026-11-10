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
  # call receivers that are calls, constants (milestone 5)
  "x = 1\nx.foo.bar",
  "x = 1\nx.foo.bar(2)",
  "X = 1",
  "X = 1\nX",
  "x = X",
  "x = 1\nx = X",
  "X = 1\nY = X\nY",
  # frozen string literals (milestone 5)
  "# frozen_string_literal: true\nrequire 'set'",
  "# frozen_string_literal: true\nx = \"ab\"\nx",
  "# frozen_string_literal: false\nx = \"ab\"",
  # || and && (milestone 5)
  "x = 1\ny = x || 2",
  "x = 1\nx || 2",
  "x = 1\ny = x && 2",
  "x = 1\nx && 2\np 3",
  "x = 1\nx || 2\np 3",
  "x = 1\ny = x || 2\ny",
  # global variables (milestone 5)
  "$g = 1",
  "$g = 1\n$g",
  "x = $g",
  "x = 1\np $g",
  # attribute assignment (milestone 5)
  "$stdout.sync = true",
  "x = 1\nx.sync = true",
  "x = 1\nx.foo = 2\nx",
  # class and module with an empty body (step 1: CLASS/MODULE, no child ireps)
  'class Foo; end',
  'module Foo; end',
  "class Foo\nend",
  "class Foo; ; end",
  "x = 1\nclass Foo; end",
  "class Foo; end\nx = 1",
  "class Foo; end\nclass Bar; end",
  "module Foo; end\nmodule Bar; end",
  "class Foo; end\nmodule Foo; end",
  "module Foo; end\nx = 1\nx",
  # class and module bodies with statements (step 2: child ireps, EXEC)
  'class Foo; 1; end',
  'class Foo; self; end',
  'class Foo; nil; end',
  'class Foo; x = 1; end',
  "class Foo; x = 1; x; end",
  "class Foo\n  1\nend",
  "class Foo\n  x = 1\n  2\nend",
  "class Foo; x = 1\n  x + 2\nend",
  'class Foo; p 1; end',
  'class Foo; 1; 2; end',
  "class Foo; 1; end\nx = 1",
  "class Foo; 1; end\np 2",
  "class Foo; x = 1; end\nx = 2",
  "class Foo; 1; end\nclass Bar; 2; end",
  "class Foo; end\nclass Bar; 1; end",
  'module Foo; 1; end',
  "module Foo; x = 1; x; end",
  "x = 1\nclass Foo; x; end",
  "class Foo; class Bar; 1; end; end",
  "class Foo; x = 1; end\nclass Bar; x = 2; end",
  "class Foo; y = 1; x = y; end",
  "class Foo; x = [1]; end",
  "x = 1\nclass Foo; x = 2; end\nx",
  "class Foo\n  x = 1\n  if x\n    2\n  end\nend",
  "class Foo\n  x = 1\n  if x\n    2\n  else\n    3\n  end\n  x\nend",
  # method definitions (milestone 6)
  "def foo\n  1\nend",
  "def foo\nend",
  "def foo\n  1\nend\nfoo",
  "x = 1\ndef foo\n  2\nend",
  "def foo(a)\n  a\nend",
  "def foo(a, b)\n  b\nend",
  "def foo\n  1\nend\nx = 2",
  "def foo(a)\n  c = a\n  c\nend",
  "x = 1\nx[2]",
  "x = 1\nx[]",
  "module Foo\n  def bar\n    1\n  end\nend",
  "# frozen_string_literal: true\ndef foo\n  'a'\nend",
  # index assignment and superclasses (milestone 7)
  "x = 1\nx[2] = 3",
  "x = 1\nx[2] = 3\nx",
  "x = 1\nx[2] = 3\n3",
  # instance variables and parentheses (milestone 8)
  "x = @a",
  "class Foo\n  @a = 1\n  x = @a\nend",
  "@a = 1\n@a",
  "x = 1\n(x)",
  "x = 1\ny = (x)\ny",
  "x = 1\np (x)",
  "x = 1\n(x) || 2",
  "class Foo < Bar; end",
  "class Foo < Bar\n  1\nend",
  "class Foo < Bar; end\nclass Baz; end",
  # def parameters: optional, rest, block, return, required keywords (milestone 9)
  "def f(a, b = 1)\n  b\nend",
  "def f(a, b = 1, c = 2)\n  c\nend",
  "def f(a = 1)\nend",
  "def f(a = p(1), b = [1])\n  a\nend",
  "def f(a, b = a + 1)\n  b\nend",
  "def f(a = 1)\n  x = 2\n  x\nend",
  "def f(a = 1)\n  a\n  p a\nend",
  "def f(*r)\n  r\nend",
  "def f(a, *r)\n  r\nend",
  "def f(a, *r, c)\n  c\nend",
  "def f(*)\n  1\nend",
  "def f(a, b = 1, *r, c)\n  r\nend",
  "def f(&blk)\n  blk\nend",
  "def f(a, &blk)\n  a\nend",
  "def f(&blk)\n  x = blk\n  x\nend",
  "def f(a, b = a + 1, *r, &blk)\n  x = 1\n  r\nend",
  "def f(a, b = 1)\n  return b\nend",
  "def f(x)\n  return x\nend",
  "def f(x)\n  return\nend",
  "def f(x)\n  return 1\n  2\nend",
  "def f(x)\n  if x\n    return 1\n  end\n  2\nend",
  "def f(x)\n  return x + 1\nend",
  "def f(x)\n  return p(x)\nend",
  "def f(x)\n  if x\n    return 1\n  else\n    return 2\n  end\nend",
  "def f(x)\n  unless x\n    return\n  end\n  x\nend",
  "def f(a, k:)\n  k\nend",
  "def f(k:, j:)\n  j\nend",
  "def f(a, k:, &blk)\n  blk\nend",
  "def f(a, b = 1, *r, k:, &blk)\n  y = 1\n  k\nend",
  "def f(a,\n      b = 1,\n      &blk)\n  b\nend",
  "def f(a = p(1),\n      b = p(2))\n  b\nend",
  "def f(a, b = \"s\")\n  b\nend",
  "def f(x)\n  return x if x\n  1\nend",
  "def f(*r, &b)\n  b\nend",
  "def f(a, b = 1)\n  x = a + b\n  return x\nend",
  "class Foo\n  def bar(a, b = 1, *r, &blk)\n    return a\n  end\nend"
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
