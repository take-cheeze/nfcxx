#!/usr/bin/env ruby
# frozen_string_literal: true

# KWARG_NO_HASH (codegen_kwarg_no_hash.rb): a compiled method with keyword parameters and no `**rest` does not build
# the keyword Hash mrbc rebuilds after KEYEND for a bare `super`, unless something can read it.
#
#   - placement: each POSITIVE method's body has the KWARG_NO_HASH note and no mrb_hash_new_capa; each REFUSED method
#     (a bare super, a bare super in a block, a `**rest`) keeps its Hash;
#   - kill switch: BC2CPP_KWARG_NO_HASH=0 places nothing and builds the Hash in every POSITIVE method;
#   - parity: every row, keywords given, omitted, unknown or missing, prints the same interpreted and compiled
#     (skipped without a full-core libmruby).
#
# Usage: MRBC=path/to/mrbc [BC2CPP_MRUBY_FULL=dir | BC2CPP_FULL_BUILD_DIR=dir] ruby scripts/bc2cpp/kwarg_no_hash_check.rb

require_relative 'fixture_runtime'

suite = Bc2cppStepCheck.new('kwarg_no_hash_check')

SRC = <<~RUBY
  class KwBase
    def kw_up(a, k: 1, j: 2)
      [a, k, j]
    end

    def kw_up_block(a, k: 1, j: 2)
      [a, k, j]
    end
  end

  class KwFix < KwBase
    def kw_sum(a, k: 1, j: 2)
      a + k + j
    end

    def kw_req(a, k:, j: 5)
      a * k + j
    end

    def kw_fwd(a, k: true)
      kw_sum(a, k: k ? 10 : 20)
    end

    def kw_rescue(a, k: 3)
      raise ArgumentError, 'neg' if a.negative?

      a + k
    rescue ArgumentError => e
      [e.message, k]
    end

    def kw_block(k: 2)
      [1, 2, 3].map { |x| x * k }
    end

    def kw_explicit_super(a, k: 1, j: 2)
      kw_sum(a, k: k, j: j)
    end

    def kw_up(a, k: 7, j: 8)
      super
    end

    def kw_up_block(a, k: 7, j: 8)
      [0].map { super }
    end

    def kw_up_block_bare(a, k: 7, j: 8)
      [0].map { |_| kw_up(a, k: k) }
    end

    def kw_rest(a, k: 1, **opts)
      [a, k, opts.size]
    end
  end
RUBY
# kw_up and kw_up_block forward k and j with a bare super, from the method and from a block.
POSITIVE = %w[kw_sum kw_req kw_fwd kw_rescue kw_block kw_explicit_super kw_up_block_bare].freeze
# KwFix's refusals and the reason BC2CPP_KWARG_NO_HASH_REPORT gives; kw_up_block stays interpreted. kw_rest's
# `**opts` is read, and its shape is refused before any body compiles; it is in the parity rows only.
REFUSED = { 'kw_up' => 'read', 'kw_up_block' => 'captured' }.freeze
OWNERS = %w[KwBase KwFix].freeze
DRIVER = Bc2cppStepCheck::SHOW + <<~'RUBY'
  f = KwFix.new
  show('sum') { [f.kw_sum(1), f.kw_sum(1, k: 10), f.kw_sum(1, j: 100, k: 10)] }
  show('sum unknown') { f.kw_sum(1, z: 1) }
  show('req') { [f.kw_req(2, k: 3), f.kw_req(2, j: 0, k: 4)] }
  show('req missing') { f.kw_req(2) }
  show('fwd') { [f.kw_fwd(1), f.kw_fwd(1, k: false), f.kw_fwd(1, k: nil)] }
  show('rescue') { [f.kw_rescue(1), f.kw_rescue(-1, k: 9)] }
  show('block') { [f.kw_block, f.kw_block(k: 5)] }
  show('explicit super') { [f.kw_explicit_super(1), f.kw_explicit_super(1, j: 3)] }
  show('bare super') { [f.kw_up(1), f.kw_up(1, k: 2), f.kw_up(1, j: 3, k: 4)] }
  show('super in block') { f.kw_up_block(1, k: 2) }
  show('call in block') { f.kw_up_block_bare(1, k: 2) }
  show('rest') { [f.kw_rest(1), f.kw_rest(1, k: 2, z: 3, y: 4)] }
  puts 'end'
RUBY

# Every function generated for KwFix#name's body (the `_impl` and its `_unguarded`/rescue parts).
bodies = lambda do |code, name|
  code.scan(/^(?:static )?(?:inline )?mrb_value KwFix_#{name}_impl\w*\(mrb_state\* M[^;{]*\{\n.*?^\}\n/m).join
end
saved = ENV.fetch('BC2CPP_KWARG_NO_HASH', nil)
ENV['BC2CPP_KWARG_NO_HASH'] = '0'
off = suite.generate(SRC, OWNERS)
saved.nil? ? ENV.delete('BC2CPP_KWARG_NO_HASH') : ENV['BC2CPP_KWARG_NO_HASH'] = saved
suite.check('BC2CPP_KWARG_NO_HASH=0: nothing is placed', !off.include?('KWARG_NO_HASH'))
(POSITIVE - %w[kw_block kw_up_block_bare]).each do |name|
  suite.check("BC2CPP_KWARG_NO_HASH=0: #{name} builds its keyword Hash", bodies.call(off, name).include?('mrb_hash_new_capa('))
end

ENV['BC2CPP_KWARG_NO_HASH_REPORT'] = '1'
code = suite.generate(SRC, OWNERS)
ENV.delete('BC2CPP_KWARG_NO_HASH_REPORT')
report = suite.instance_variable_get(:@err).to_s
fix_at = SRC.lines.index { |l| l.start_with?('class KwFix') }
line_of = ->(name) { SRC.lines.each_index.find { |i| i > fix_at && SRC.lines[i].include?("def #{name}(") }.to_i + 1 }
POSITIVE.each do |name|
  body = bodies.call(code, name)
  suite.check("#{name}: compiled, with no keyword Hash",
              body.include?('KWARG_NO_HASH: the keyword Hash') && !body.include?('mrb_hash_new_capa('))
  suite.check("#{name}: reported as no Hash", report.match?(/fixture\.rb:#{line_of.call(name)} \(irep \d+\): no Hash/))
end
REFUSED.each do |name, reason|
  suite.check("#{name}: kept (#{reason})", report.match?(/fixture\.rb:#{line_of.call(name)} \(irep \d+\): kept \(#{reason}\)/))
  suite.check("#{name}: no KWARG_NO_HASH note", !bodies.call(code, name).include?('KWARG_NO_HASH'))
end
suite.check('kw_up keeps building the Hash its bare super forwards', bodies.call(code, 'kw_up').include?('mrb_hash_new_capa('))
suite.check('KwBase#kw_up, which no super reaches through a Hash, builds none',
            !code.scan(/^mrb_value KwBase_kw_up_impl\w*\(mrb_state\* M[^;{]*\{\n.*?^\}\n/m).join.include?('mrb_hash_new_capa('))

EXPECTED = [
  'sum: [4, 13, 111]', 'req: [11, 8]', 'fwd: [13, 23, 23]', 'rescue: [4, ["neg", 9]]', 'block: [[2, 4, 6], [5, 10, 15]]',
  'bare super: [[1, 7, 8], [1, 2, 8], [1, 4, 3]]', 'super in block: [[1, 2, 8]]', 'call in block: [[1, 2, 8]]'
].freeze
suite.behaviour(DRIVER) do |_interpreted, compiled|
  EXPECTED.each { |line| suite.check("compiled prints #{line}", compiled.to_a.include?(line)) }
  suite.check('an unknown and a missing keyword raise ArgumentError',
              compiled.to_a.count { |line| line.match?(/\A(sum unknown|req missing): raised ArgumentError/) } == 2)
end
suite.finish
