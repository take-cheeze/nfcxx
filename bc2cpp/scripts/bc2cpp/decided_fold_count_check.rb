#!/usr/bin/env ruby
# frozen_string_literal: true

# Checks scripts/bc2cpp/decided_fold_count.rb on synthetic generated trees, so it runs without mrbc or a closed world.
#
#   ruby scripts/bc2cpp/decided_fold_count_check.rb

require 'tmpdir'
require 'fileutils'
require_relative 'decided_fold_count'

failures = []
check = lambda do |name, ok|
  puts "  #{ok ? 'ok  ' : 'FAIL'} #{name}"
  failures << name unless ok
end

# A folds-on tree: one taken JMPIF (a goto), one not-taken JMPNOT and one not-taken JMPNIL, with the tests they leave.
ON_SOURCE = <<~CXX
  if (mrb_test(r1)) goto L1; // not a fold: the test stays
  goto L2; // DECIDED_BRANCH JMPIF R2: taken
  // DECIDED_BRANCH JMPNOT R3: not taken
  // DECIDED_BRANCH JMPNIL R4: not taken
  if (mrb_test(r5)) goto L3;
CXX

# The same code with the folds off: each fold's test is back, and the untouched test is the same.
OFF_SOURCE = <<~CXX
  if (mrb_test(r1)) goto L1;
  if (mrb_test(r2)) goto L2;
  if (!mrb_test(r3)) goto L9;
  if (mrb_nil_p(r4)) goto L10;
  if (mrb_test(r5)) goto L3;
CXX

Dir.mktmpdir do |root|
  on_dir = File.join(root, 'on')
  off_dir = File.join(root, 'off')
  FileUtils.mkdir_p(on_dir)
  FileUtils.mkdir_p(off_dir)
  File.write(File.join(on_dir, 'rpg2k_gen.cpp'), ON_SOURCE)
  File.write(File.join(off_dir, 'rpg2k_gen.cpp'), OFF_SOURCE)

  puts '== counting one tree'
  on = DecidedFoldCount.count(on_dir)
  check.call('three markers, one per fold', on[:folds].values.sum == 3)
  check.call('the taken JMPIF is counted as taken', on[:folds][%w[JMPIF taken]] == 1)
  check.call('the not-taken JMPNOT is counted', on[:folds][%w[JMPNOT not\ taken]] == 1)
  check.call('the not-taken JMPNIL is counted', on[:folds][%w[JMPNIL not\ taken]] == 1)
  check.call('mrb_test calls: the commented-out test line counts too', on[:calls][:mrb_test] == 2)

  puts '== comparing folds on with folds off'
  off = DecidedFoldCount.count(off_dir)
  check.call('the drops agree with the folds', DecidedFoldCount.compare(on, off))

  puts '== a drop that does not match the folds'
  # The folds-off tree has five mrb_test calls that the folds-on tree lacks, beyond the folds' two: the drop is seven, not two.
  off_bad = { folds: off[:folds], calls: { mrb_test: off[:calls][:mrb_test] + 5, mrb_nil_p: off[:calls][:mrb_nil_p] } }
  check.call('an extra removed test is reported as a disagreement', !DecidedFoldCount.compare(on, off_bad))
end

puts failures.empty? ? 'decided_fold_count_check: all checks passed' : "decided_fold_count_check: #{failures.size} failed"
exit(failures.empty? ? 0 : 1)
