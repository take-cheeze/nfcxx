#!/usr/bin/env ruby
# frozen_string_literal: true

# Check BC2CPP_BLOCK_SEND_REPORT (docs/adr/0325, tools/bc2cpp/block_send_report.rb): the report is a measurement, so
# the generated C++ must be byte-identical with it on, and its rows must say what the compiler did with each block
# send of a fixture (a proven receiver, an unproven one, a name with no compiled callee, `&:sym`, a receiver the
# call facts bound to one user class).
#
# Usage: MRBC=path/to/mrbc ruby scripts/bc2cpp/block_send_report_check.rb

require 'open3'
require 'rbconfig'
require 'shellwords'
require 'tmpdir'
require_relative '../../tools/bc2cpp/compiled_gems'
require_relative '../../tools/bc2cpp/nomethod_reviewed'
require_relative '../../tools/bc2cpp/nomethod_reviewed_probe'
require_relative '../../tools/bc2cpp/block_send_report_columns'

ROOT = File.expand_path('../..', __dir__)

unless ENV['MRBC']
  puts '-- SKIP: set MRBC'
  exit 0
end

failures = []
check = lambda do |what, condition|
  puts "  #{condition ? 'ok  ' : 'FAIL'} #{what}"
  failures << what unless condition
end

SOURCE = <<~RUBY
  class BsBox
    def bump; self; end
    def each_thing; yield 1; end
  end

  class BsFx
    def proven; s = 0; { 1 => 2, 3 => 4 }.select { |_k, v| s += v }; s; end
    def unproven(a); s = 0; a.each { |x| s += x }; s; end
    def mapped(a); a.map { |x| x + 1 }; end
    def looped; i = 0; loop { i += 1; break if i > 2 }; i; end
    def newarr(n); Array.new(n) { |i| i }; end
    def newhash; Hash.new { |h, k| h[k] = k }; end
    def symblk(a, pr); a.select(&pr); end
    def broke(a); a.each { |x| return x if x > 1 }; nil; end
    def factbox(b); b.bump; b.each_thing { |x| x }; end
  end
RUBY

# The closed wio world with the compiled core Ruby, as bc2cpp_block_arm_reach_check builds it: the block arms only
# exist for core bodies this link emits.
generate = lambda do |source, dir, extra_env = {}|
  path = File.join(dir, 'bs_fixture.rb')
  File.write(path, source)
  env = { 'MRBC' => ENV.fetch('MRBC'), 'OUT_SYMBOL' => 'bs_fixture', 'OUT_DIR' => dir, 'SKIP_UNSUPPORTED' => '1',
          'NATIVE_SRCS' => Shellwords.join(core_native_srcs("#{ROOT}/3rd/mruby") + external_gem_native_srcs(ROOT)),
          'FOREIGN_RUBY_SRCS' => Shellwords.join(foreign_mrblib_srcs(ROOT)),
          'ONLY_OWNERS' => (BC2CPP_CORE_OWNERS + %w[BsFx BsBox]).join(','),
          'BC2CPP_CLOSED_WORLD' => '1', 'BC2CPP_BUILD_NAME' => 'wio',
          'BC2CPP_BUILD_GEMS' => Shellwords.join(NomethodReviewedProbe.wio_gems(ROOT).map { |n, d| "#{n}=#{d}" }),
          NomethodReviewed::ALLOW_ENV => 'allow' }.merge(extra_env)
  out, err, status = Open3.capture3(env, RbConfig.ruby, File.join(ROOT, 'tools/bc2cpp/bc2cpp.rb'), '--annotated',
                                    *core_compiled_mrblib_srcs(ROOT), path)
  abort "bc2cpp.rb failed:\n#{err[-3000..] || err}" unless status.success?

  out
end

rows = lambda do |report|
  File.readlines(report, chomp: true).reject(&:empty?).map { |l| BlockSendReport::COLUMNS.zip(l.split("\t", -1)).to_h }
end
by_owner = ->(all, name) { all.select { |r| r['owner'] == "BsFx##{name}" } }

Dir.mktmpdir do |dir|
  plain = File.join(dir, 'plain')
  withr = File.join(dir, 'report')
  Dir.mkdir(plain)
  Dir.mkdir(withr)
  report = File.join(dir, 'bs.tsv')
  code_off = generate.call(SOURCE, plain)
  code_on = generate.call(SOURCE, withr, 'BC2CPP_BLOCK_SEND_REPORT' => report)

  puts '== generated code'
  check.call('the report changes no generated code', code_on == code_off)
  all = rows.call(report)
  check.call('the report has a row per block send of the fixture (8)', all.count { |r| r['gem'] == 'other' } == 8)

  r = by_owner.call(all, 'proven').first
  check.call('proven: the literal receiver is a Hash literal and the dynamic send is gone or guarded for the Fiber case',
             r && r['existing'] == 'Hash' && %w[removed proven_guarded].include?(r['shape']))
  r = by_owner.call(all, 'unproven').first
  check.call('unproven: class-test arms with a dynamic else, receiver an incoming argument',
             r && r['shape'] == 'exact_arms' && r['existing'] == 'unproven' && r['byname'] == '1' &&
             r['producer'] == 'incoming_arg' && r['arms'].split(',').size == 3)
  r = by_owner.call(all, 'mapped').first
  check.call('mapped: the same shape for map', r && r['shape'] == 'exact_arms' && r['name'] == 'map')
  r = by_owner.call(all, 'looped').first
  check.call('loop: no compiled callee, the reason is named', r && r['shape'] == 'dynamic' && r['arms'].empty? && !r['why'].empty?)
  r = by_owner.call(all, 'newhash').first
  check.call('Hash.new with a block: no compiled callee, receiver produced by a constant',
             r && r['shape'] == 'dynamic' && r['name'] == 'new' && r['producer'].start_with?('const'))
  check.call('Array.new with a block is an inlined loop (ADR 0391), so it has no block-send row',
             by_owner.call(all, 'newarr').empty? && code_on.include?('ARRAY_NEW_BLOCK'))
  r = all.find { |row| row['gem'] == 'other' && row['kind'] == 'explicit' }
  check.call('&expr is an explicit block send', r && r['kind'] == 'explicit' && r['shape'] == 'explicit')
  r = by_owner.call(all, 'broke').first
  check.call('a block that returns has no direct entry', r && r['entry'] == '0' && r['ret'] == '1')
  r = by_owner.call(all, 'factbox').first
  check.call('facts: after b.bump the receiver is bounded to one user class the build would accept',
             r && r['facts'] == 'bump' && r['fact_kind'] == 'user' && r['fact_set'] == 'BsBox' && r['fact_usable'] == '1')
  unless failures.empty?
    all.select { |row| row['gem'] == 'other' }.each { |row| warn row.values_at('owner', 'kind', 'name', 'shape', 'existing', 'producer', 'entry', 'ret').join(' | ') }
  end
end

if failures.empty?
  puts 'ok'
else
  warn "FAILED: #{failures.size}"
  exit 1
end
