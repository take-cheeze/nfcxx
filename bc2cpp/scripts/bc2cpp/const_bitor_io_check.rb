#!/usr/bin/env ruby
# frozen_string_literal: true

# Constant typing for bit operators, an out-of-margin Integer and a bool from `==` (docs/bc2cpp-type-check.md).
# Each fixture is compiled by the host mrbc. The exact-value proof (IntegerConstants) and the bignum-capable class proof
# (IntegerConstants.class_admitted) are checked in process; the rows are checked end to end through type_check.rb --files,
# which is the analysis a build runs. Needs MRBC (a host mrbc); without it the check prints SKIP and exits 0.
#
#   MRBC=path/to/host/mrbc ruby scripts/bc2cpp/const_bitor_io_check.rb

require 'json'
require 'open3'
require 'set'
require 'tmpdir'
require_relative '../../tools/bc2cpp/bc2cpp'

unless ENV['MRBC'] && File.executable?(ENV['MRBC'])
  puts 'SKIP const_bitor_io_check: MRBC is not set to a host mrbc'
  exit 0
end

ROOT = File.expand_path('../..', __dir__)
TYPE_CHECK = File.join(ROOT, 'scripts/bc2cpp/type_check.rb')

failures = []
check = lambda do |what, condition|
  puts "  #{condition ? 'ok  ' : 'FAIL'} #{what}"
  failures << what unless condition
end

row_for = lambda do |rows, bare|
  rows.find { |r| r['name'] == bare || r['name'].end_with?("::#{bare}") }
end

typed_rows = lambda do |source|
  Dir.mktmpdir do |dir|
    rb = File.join(dir, 'fixture.rb')
    out = File.join(dir, 'facts.json')
    File.write(rb, source)
    _stdout, stderr, status = Open3.capture3({ 'MRBC' => ENV['MRBC'] }, RbConfig.ruby, TYPE_CHECK,
                                             '--files', rb, '--no-sends', '--format', 'json', '--out', out, '-q')
    unless File.exist?(out)
      warn stderr
      raise "type_check.rb wrote no JSON (exit #{status.exitstatus})"
    end

    JSON.parse(File.read(out))['constants']
  end
end

# The exact-value and class proofs over one program, in process.
analysis = lambda do |source|
  Dir.mktmpdir do |dir|
    rb = File.join(dir, 'fixture.rb')
    File.write(rb, source)
    ireps, root = compile_ireps([rb], 'const_bitor_io', dir)
    registry, _superclass_of, _containers, included, prepended, unknown, _structs, _decls, _walked, _ivars, sites = build_registry(ireps, root)
    safe = IntegerConstantRanges.integer_ops_safe?(registry, included, prepended, unknown)
    # The IR class proof (ADR 0501 stage 4), with the gates the build passes (bc2cpp.rb).
    freeze_safe = DeclaredConstants.stock_method?('freeze', 'Integer', registry, included, prepended, unknown)
    ir = BytecodeIR::ConstantFacts.analyze(ireps, sites: sites, poisoned: Set.new, operators_safe: safe,
                                                  freeze_safe: freeze_safe, freeze_classes: Set.new)
    {
      safe: safe,
      exact: IntegerConstants.analyze(ireps, [], [], operators_safe: safe),
      values: IntegerConstants.analyze_values(ireps, IntegerConstants.analyze(ireps, [], [], operators_safe: safe)),
      classes: IntegerConstants.class_admitted(ireps, [], [], operators_safe: safe),
      ir_classes: ir.integer_class_names
    }
  end
end

positive = <<~RUBY
  module CbBits
    CB_A = 1
    CB_B = 2
    CB_RW = CB_A | CB_B
    CB_AND = 6 & 3
    CB_XOR = 6 ^ 3
    CB_NEG = -6 & 3
  end
  module CbBig
    CB_BIG = 1073741824
    CB_BIG_LESS = CB_BIG - 1
    CB_BIG_OR = CB_BIG | 1
    CB_LIT_OR = 1073741824 | 1
  end
  module CbMixed
    CB_BIG_SAFE = 1073741823 | 0
  end
  module CbUtf
    CB_UTF_OK = ('あ'.length == 1)
  end
RUBY

puts '== positive: exact bit-or, and/xor, negatives in and'
pos = analysis.call(positive)
check.call('the operators are the core ones (no Ruby definition on Integer)', pos[:safe])
check.call('CB_RW (= 1 | 2) is admitted by the exact-value proof', pos[:exact].include?('CB_RW'))
check.call('CB_RW has the exact value 3', pos[:values]['CB_RW'] == 3)
check.call('CB_AND (= 6 & 3) has the exact value 2', pos[:values]['CB_AND'] == 2)
check.call('CB_XOR (= 6 ^ 3) has the exact value 5', pos[:values]['CB_XOR'] == 5)
check.call('CB_NEG (= -6 & 3) has the exact value 2 (two complement, as Ruby)', pos[:values]['CB_NEG'] == 2)
check.call('CB_BIG (0x40000000) has no exact value (outside the Fixnum margin)', pos[:values]['CB_BIG'].nil?)
check.call('CB_BIG_LESS (= CB_BIG - 1) is refused by the exact proof: its operand has no exact value',
           !pos[:exact].include?('CB_BIG_LESS'))
check.call('CB_BIG_LESS (= CB_BIG - 1, value 0x3fffffff) is admitted by the bignum-capable class proof',
           pos[:classes].include?('CB_BIG_LESS'))
check.call('CB_BIG_OR (= CB_BIG | 1, outside the margin) has no exact value', !pos[:exact].include?('CB_BIG_OR'))
check.call('CB_BIG_OR (a constant operand) is admitted by the bignum-capable class proof', pos[:classes].include?('CB_BIG_OR'))
# mrbc folds `1073741824 | 1` to one LOADI32, so the literal-only rule never sees the expression: it is a plain
# out-of-margin literal, which the existing literal proofs already type (see docs/bc2cpp-type-check.md).
check.call('CB_LIT_OR is folded to one out-of-margin literal: no exact value', pos[:values]['CB_LIT_OR'].nil?)
check.call('the IR class proof admits every name the old class proof admits (positive)', (pos[:classes] - pos[:ir_classes].to_a).empty?)

# Literal-only arithmetic outside the Fixnum margin: the old class proof refuses it (integer_constants.rb, class_admitted:
# no exact value), so the names built on it are refused too. The IR class proof keeps them: an Integer operator on Integer
# operands is an Integer under the operator gate, whatever the size. The type check is the only reader (report only).
puts '== literal-only bignum arithmetic: IR class proof keeps what the old proof refuses'
arith = <<~RUBY
  module CbArith
    CB_ADD = 4611686018427387904 + 1
    CB_SUB = 9999999999 - 1
    CB_CHAIN = CB_ADD + 1
    CB_LOOK = CB_ADD
  end
RUBY
ar = analysis.call(arith)
only_ir = (ar[:ir_classes] - ar[:classes].to_a).to_a.sort
check.call('the IR class proof admits CB_ADD, CB_SUB, CB_CHAIN and CB_LOOK, and the old one refuses them',
           only_ir == %w[CB_ADD CB_CHAIN CB_LOOK CB_SUB])
check.call('the old class proof admits no name the IR refuses (arith)', (ar[:classes] - ar[:ir_classes].to_a).empty?)
ar_rows = typed_rows.call(arith)
add_row = row_for.call(ar_rows, 'CB_ADD')
check.call('CB_ADD is typed Integer by the class proof (inferred:integer-class)',
           add_row && add_row['type'] == 'Integer' && add_row['source'] == 'inferred:integer-class')

puts '== positive, end to end: rows'
rows = typed_rows.call(positive)
rw = row_for.call(rows, 'CB_RW')
check.call('CB_RW is typed Integer (inferred:integer-constant)',
           rw && rw['type'] == 'Integer' && rw['source'] == 'inferred:integer-constant')
big_less = row_for.call(rows, 'CB_BIG_LESS')
check.call('CB_BIG_LESS is typed Integer by the class proof (inferred:integer-class)',
           big_less && big_less['type'] == 'Integer' && big_less['source'] == 'inferred:integer-class')
big_or = row_for.call(rows, 'CB_BIG_OR')
check.call('CB_BIG_OR (= CB_BIG | 1) is typed Integer by inferred:integer-class',
           big_or && big_or['type'] == 'Integer' && big_or['source'] == 'inferred:integer-class')
utf = row_for.call(rows, 'CB_UTF_OK')
check.call('CB_UTF_OK (= (\'あ\'.length == 1)) is typed bool (inferred:bool-compare)',
           utf && utf['type'] == 'bool' && utf['source'] == 'inferred:bool-compare')

redefined_or = <<~RUBY
  class Integer
    def |(other)
      self
    end
  end
  module CbBits
    CB_A = 1
    CB_B = 2
    CB_RW = CB_A | CB_B
  end
RUBY

puts '== negative: a program redefining Integer#| is refused'
red = analysis.call(redefined_or)
check.call('integer_ops_safe? is false (a Ruby def of | on Integer)', !red[:safe])
check.call('CB_RW is not admitted by either proof', !red[:exact].include?('CB_RW') && !red[:classes].include?('CB_RW'))
rw = row_for.call(typed_rows.call(redefined_or), 'CB_RW')
check.call('CB_RW stays untyped', rw && rw['type'].nil?)

non_literal = <<~RUBY
  module CbBits
    CB_A = 1
    CB_NL = CB_A | Integer.sqrt(9)
  end
RUBY

puts '== negative: a non-literal operand'
nl = analysis.call(non_literal)
check.call('CB_NL (a method-call operand) is not admitted by the exact proof', !nl[:exact].include?('CB_NL'))
rows = typed_rows.call(non_literal)
nl_row = row_for.call(rows, 'CB_NL')
check.call('CB_NL stays untyped', nl_row && nl_row['type'].nil?)

redefined_length = <<~RUBY
  class String
    def length
      0
    end
  end
  module CbUtf
    CB_UTF_OK = ('あ'.length == 1)
  end
RUBY

puts '== negative: a program redefining String#length'
rows = typed_rows.call(redefined_length)
utf = row_for.call(rows, 'CB_UTF_OK')
check.call('CB_UTF_OK stays untyped (String#length is not stock)', utf && utf['type'] != 'bool')

non_literal_eq = <<~RUBY
  module CbUtf
    CB_UTF_NL = ('あ'.length == Integer.sqrt(4))
  end
RUBY

puts '== negative: a non-literal argument to =='
rows = typed_rows.call(non_literal_eq)
utf_nl = row_for.call(rows, 'CB_UTF_NL')
check.call('CB_UTF_NL (non-literal argument) stays untyped', utf_nl && utf_nl['type'].nil?)

puts
if failures.empty?
  puts 'const_bitor_io_check: all checks passed'
else
  puts "const_bitor_io_check: #{failures.size} check(s) failed"
  exit 1
end
