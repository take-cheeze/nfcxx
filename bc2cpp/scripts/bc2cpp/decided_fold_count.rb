#!/usr/bin/env ruby
# frozen_string_literal: true

# Counts the decided-branch folds (ADR 0532) in a closed-world generated tree, and checks them against the tests the
# build removes. The generated C++ carries a `DECIDED_BRANCH` marker per fold only when bc2cpp runs with --annotated: the
# default output strips `//` comments (CompactOutput, ADR 0463), so run the generator with --annotated to count markers.
#
#   ruby scripts/bc2cpp/decided_fold_count.rb GEN_DIR
#   ruby scripts/bc2cpp/decided_fold_count.rb GEN_DIR_FOLDS_ON GEN_DIR_FOLDS_OFF
#
# With one directory: the markers by kind (taken or not taken, and the jump op) and the number of mrb_test( and mrb_nil_p(
# calls. With two: also the drop in each call count, and whether it equals the folds that remove that call. A fold replaces
# one test: an mrb_test-based jump (JMPIF, JMPNOT) loses one mrb_test( call, a JMPNIL loses one mrb_nil_p( call. The
# check exits non-zero when the drops disagree with the folds.

require 'pathname'

module DecidedFoldCount
  MARKER = /DECIDED_BRANCH (JMPIF|JMPNOT|JMPNIL) R\d+: (taken|not taken)/
  TEST_CALLS = { mrb_test: /\bmrb_test\(/, mrb_nil_p: /\bmrb_nil_p\(/ }.freeze
  NIL_OPS = %w[JMPNIL].freeze

  module_function

  # The generated C++ files under +dir+ (a *_gen.cpp is what the build compiles; other C++ files are scanned too).
  def sources(dir)
    Pathname.new(dir).glob('**/*.{cxx,cpp,cc,h,hpp}').sort
  end

  # { folds: {[op, outcome] => count}, calls: { mrb_test: n, mrb_nil_p: n } } for every file under +dir+.
  def count(dir)
    folds = Hash.new(0)
    calls = TEST_CALLS.keys.to_h { |name| [name, 0] }
    sources(dir).each do |path|
      text = path.binread.force_encoding('UTF-8').scrub
      text.scan(MARKER) { |op, outcome| folds[[op, outcome]] += 1 }
      TEST_CALLS.each { |name, pattern| calls[name] += text.scan(pattern).size }
    end
    { folds: folds, calls: calls }
  end

  # The calls each kind of fold removes: a JMPNIL fold removes an mrb_nil_p( call, every other fold an mrb_test( call.
  def expected_drops(folds)
    expected = TEST_CALLS.keys.to_h { |name| [name, 0] }
    folds.each do |(op, _outcome), n|
      expected[NIL_OPS.include?(op) ? :mrb_nil_p : :mrb_test] += n
    end
    expected
  end

  def report(counted)
    total = counted[:folds].values.sum
    puts "decided-branch markers: #{total}"
    counted[:folds].sort.each { |(op, outcome), n| puts "  #{op} #{outcome}: #{n}" }
    counted[:calls].each { |name, n| puts "#{name}( calls: #{n}" }
  end

  # The drops of two counted trees, and whether each equals the folds of the decided tree.
  def compare(on, off)
    drops = on[:calls].keys.to_h { |name| [name, off[:calls][name] - on[:calls][name]] }
    expected = expected_drops(on[:folds])
    agree = drops == expected
    puts "drop in mrb_test( calls: #{drops[:mrb_test]} (folds removing one: #{expected[:mrb_test]})"
    puts "drop in mrb_nil_p( calls: #{drops[:mrb_nil_p]} (folds removing one: #{expected[:mrb_nil_p]})"
    puts(agree ? 'agree: every fold removes exactly the test it replaces' : 'DISAGREE: the drops do not match the folds')
    agree
  end
end

if $PROGRAM_NAME == __FILE__
  case ARGV.size
  when 1
    DecidedFoldCount.report(DecidedFoldCount.count(ARGV[0]))
  when 2
    on = DecidedFoldCount.count(ARGV[0])
    off = DecidedFoldCount.count(ARGV[1])
    DecidedFoldCount.report(on)
    exit(DecidedFoldCount.compare(on, off) ? 0 : 1)
  else
    abort 'usage: decided_fold_count.rb GEN_DIR [GEN_DIR_FOLDS_OFF]'
  end
end
