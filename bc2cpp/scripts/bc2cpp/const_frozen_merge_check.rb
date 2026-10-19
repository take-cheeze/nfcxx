#!/usr/bin/env ruby
# frozen_string_literal: true

# REPORT_CONSTANT_OWNERS (tools/bc2cpp/type_facts.rb const_rows): a constant typed by a `.freeze` of a literal, by a
# Hash#merge, or by an Array sum whose freeze is stock. Each fixture is a whole program run through type_check.rb
# --files (the closed world of that program, no engine signatures); the constant rows of its facts are asserted. The
# positives show the proof; each negative is a Ruby definition, prepend or unresolved mixin on an owner of the method
# (or a receiver the proof cannot see), and must leave the row untyped. A Ruby `freeze` on an unrelated module (Gfx)
# must not refuse the Array and Hash proofs.
#
#   MRBC=path/to/host/mrbc ruby scripts/bc2cpp/const_frozen_merge_check.rb
#
# Needs MRBC (a host mrbc); without it the check prints SKIP and exits 0.

require 'json'
require 'tmpdir'
require 'open3'
require 'rbconfig'

ROOT = File.expand_path('../..', __dir__)
TYPE_CHECK = File.join(ROOT, 'scripts/bc2cpp/type_check.rb')

unless ENV['MRBC'] && File.executable?(ENV['MRBC'])
  puts 'SKIP const_frozen_merge_check: MRBC is not set to a host mrbc'
  exit 0
end

failures = []
check = lambda do |what, condition|
  puts "  #{condition ? 'ok  ' : 'FAIL'} #{what}"
  failures << what unless condition
end

# The constant rows of one program, keyed by name: [type, source].
rows_of = lambda do |source|
  Dir.mktmpdir do |dir|
    prog = File.join(dir, 'fixture.rb')
    keep = File.join(dir, 'keep')
    sig = File.join(dir, 'sig')
    Dir.mkdir(sig)
    File.write(prog, source)
    out, status = Open3.capture2e(RbConfig.ruby, TYPE_CHECK, '--files', prog, '--sig', sig, '--no-sends', '--keep',
                                  keep, '-q')
    raise "type_check failed (#{status.exitstatus}):\n#{out}" unless status.success?

    JSON.parse(File.read(File.join(keep, 'facts.json')))['constants'].to_h do |row|
      [row['name'], [row['type'], row['source'], row['reason']]]
    end
  end
end

# Every positive program defines the same constants; the negatives redefine only what they test.
BASE = <<~RUBY
  module Gfx
    def self.freeze
      nil
    end
  end
  FROZEN_ARR = [1, 2].freeze
  FROZEN_HASH = { a: 1 }.freeze
  LIT_MERGE = { a: 1 }.merge({ b: 2 })
  MERGE_BASE = { 11 => 1 }
  CONST_MERGE = MERGE_BASE.merge({ 12 => 2 })
  KANA = (%w[a b] + [:t, nil]).freeze
  SUM = (KANA + %w[c]).freeze
  def go
    [FROZEN_ARR, FROZEN_HASH, LIT_MERGE, CONST_MERGE, SUM]
  end
  go
RUBY

puts '== positives: stock owners, a foreign Ruby freeze'
rows = rows_of.call(BASE)
check.call('a frozen Array literal is Array', rows['FROZEN_ARR']&.first(2) == ['Array', 'inferred:constructed'])
check.call('a frozen Hash literal is Hash', rows['FROZEN_HASH']&.first(2) == ['Hash', 'inferred:constructed'])
check.call('a Hash literal merge is Hash', rows['LIT_MERGE']&.first(2) == ['Hash', 'inferred:hash-merge'])
check.call('a Hash merge of a constant Hash is Hash', rows['CONST_MERGE']&.first(2) == ['Hash', 'inferred:hash-merge'])
check.call('an Array sum that is frozen is Array', rows['SUM']&.first(2) == ['Array', 'inferred:array-sum'])
check.call('the sum over a frozen sum is Array', rows['KANA']&.first(2) == ['Array', 'inferred:array-sum'])

negatives = {
  'Array#freeze defined in Ruby' => [
    "class Array\n  def freeze\n    self\n  end\nend\n",
    %w[FROZEN_ARR KANA SUM]
  ],
  'Object#freeze defined in Ruby (Array and Hash inherit it)' => [
    "class Object\n  def freeze\n    self\n  end\nend\n",
    %w[FROZEN_ARR FROZEN_HASH KANA]
  ],
  'a module mixed into Hash defines freeze' => [
    "module Frz\n  def freeze\n    self\n  end\nend\nclass Hash\n  include Frz\nend\n",
    %w[FROZEN_HASH]
  ],
  'a module prepended to Array defines freeze' => [
    "module Frz\n  def freeze\n    self\n  end\nend\nclass Array\n  prepend Frz\nend\n",
    %w[FROZEN_ARR KANA SUM]
  ],
  'an unresolved mixin into Hash' => [
    "class Hash\n  include NoSuchMixinAnywhere\nend\n",
    %w[FROZEN_HASH LIT_MERGE CONST_MERGE]
  ],
  'a Hash prepend (merge and freeze)' => [
    "module MergeP\n  def merge(other)\n    {}\n  end\nend\nclass Hash\n  prepend MergeP\nend\n",
    %w[FROZEN_HASH LIT_MERGE CONST_MERGE]
  ],
  'Hash#merge redefined in Ruby' => [
    "class Hash\n  def merge(other)\n    1\n  end\nend\n",
    %w[LIT_MERGE CONST_MERGE]
  ],
  'a singleton merge on the constant receiver' => [
    "MERGE_BASE_S = { 11 => 1 }\ndef MERGE_BASE_S.merge(other)\n  {}\nend\nSINGLE_MERGE = MERGE_BASE_S.merge({ 12 => 2 })\n",
    %w[SINGLE_MERGE]
  ],
  'a non-literal merge receiver (a global nothing proves)' => [
    "X_MERGE = $unproven.merge({ b: 2 })\n",
    %w[X_MERGE]
  ]
}

negatives.each do |what, (extra, names)|
  puts "== negative: #{what}"
  program = BASE + extra
  # The Ruby definition is in the program itself, so each negative is its own closed world.
  rows = rows_of.call(program)
  names.each do |name|
    check.call("#{name} stays untyped (#{what})", rows[name] && rows[name][0].nil?)
  end
end

puts "#{failures.empty? ? 'PASS' : 'FAIL'} const_frozen_merge_check: #{failures.size} failure(s)"
exit(failures.empty? ? 0 : 1)
