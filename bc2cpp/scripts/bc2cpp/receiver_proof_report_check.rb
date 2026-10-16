#!/usr/bin/env ruby
# frozen_string_literal: true

# Check BC2CPP_RECEIVER_PROOF_REPORT (docs/adr/0331, tools/bc2cpp/receiver_proof_report.rb): the report is a
# measurement, so the generated C++ must be byte-identical with it on, and its rows must name where the receiver of
# each by-name send of a fixture comes from and what forcing a class set on it does: a merge (`a || []`) freed by
# Array, a nilable one that is not (nil is a core class's problem), a name nothing bounds, a receiver already proven.
#
# Usage: MRBC=path/to/mrbc ruby scripts/bc2cpp/receiver_proof_report_check.rb

require 'open3'
require 'rbconfig'
require 'shellwords'
require 'tmpdir'
require_relative '../../tools/bc2cpp/compiled_gems'
require_relative '../../tools/bc2cpp/nomethod_reviewed'
require_relative '../../tools/bc2cpp/nomethod_reviewed_probe'
require_relative '../../tools/bc2cpp/receiver_proof_report_columns'

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

SOURCE = +<<~RUBY
  class RpBox
    def bump; self; end
    def size; 7; end
  end

  class RpFx
    def merged(a); r = a || []; r.empty?; end
    def element(h); h[1].empty?; end
    def argument(a); a.empty?; end
    def proven; [1, 2].empty?; end
    def stored(v); @store = v; end
    def fromivar; @store.empty?; end
    def makes; @made; end
    def fromcall; makes.empty?; end
    def box(b); b.bump; b.size; end
    def many(a); a.rp_floor_answer; end
    # A block parameter is the CALLEE's yield, not this method's argument: `|c|` must be named a block parameter,
    # never an admission rule of `each_block` (which numeric_irep_owner would otherwise hand us, since a nested rep
    # is attributed to its enclosing definition).
    def each_block; @rows.each { |c| c.empty? }; end
  end
RUBY

41.times do |i|
  SOURCE << "class RpAnswer#{i}; def rp_floor_answer; 7; end; end\n"
end

# The closed wio world with the compiled core Ruby (as bc2cpp_block_send_report_check builds it), SKIP_UNSUPPORTED=1
# because the report only runs in the shipped pass, BC2CPP_RECEIVER_PROOF_ANY=1 because the fixture is not an engine gem.
generate = lambda do |source, dir, extra_env = {}|
  path = File.join(dir, 'rp_fixture.rb')
  File.write(path, source)
  env = { 'MRBC' => ENV.fetch('MRBC'), 'OUT_SYMBOL' => 'rp_fixture', 'OUT_DIR' => dir, 'SKIP_UNSUPPORTED' => '1',
          'NATIVE_SRCS' => Shellwords.join(core_native_srcs("#{ROOT}/3rd/mruby") + external_gem_native_srcs(ROOT)),
          'FOREIGN_RUBY_SRCS' => Shellwords.join(foreign_mrblib_srcs(ROOT)),
          'ONLY_OWNERS' => (BC2CPP_CORE_OWNERS + %w[RpFx RpBox]).join(','),
          'BC2CPP_CLOSED_WORLD' => '1', 'BC2CPP_BUILD_NAME' => 'wio',
          'BC2CPP_BUILD_GEMS' => Shellwords.join(NomethodReviewedProbe.wio_gems(ROOT).map { |n, d| "#{n}=#{d}" }),
          NomethodReviewed::ALLOW_ENV => 'allow' }.merge(extra_env)
  out, err, status = Open3.capture3(env, RbConfig.ruby, File.join(ROOT, 'tools/bc2cpp/bc2cpp.rb'), '--annotated',
                                    *core_compiled_mrblib_srcs(ROOT), path)
  abort "bc2cpp.rb failed:\n#{err[-3000..] || err}" unless status.success?

  out
end

Dir.mktmpdir do |dir|
  plain = File.join(dir, 'plain')
  withr = File.join(dir, 'report')
  Dir.mkdir(plain)
  Dir.mkdir(withr)
  report = File.join(dir, 'rp.tsv')
  code_off = generate.call(SOURCE, plain)
  code_on = generate.call(SOURCE, withr, 'BC2CPP_RECEIVER_PROOF_REPORT' => report, 'BC2CPP_RECEIVER_PROOF_ANY' => '1')

  puts '== generated code'
  check.call('the report changes no generated code', code_on == code_off)
  rows = File.readlines(report, chomp: true).reject(&:empty?).map { |l| ReceiverProofReport::COLUMNS.zip(l.split("\t", -1)).to_h }
  fixture = rows.select { |r| r['owner'].start_with?('RpFx#') }
  of = ->(name) { fixture.select { |r| r['owner'] == "RpFx##{name}" } }

  puts '== rows'
  r = of.call('merged').first
  check.call('merged: `a || []` is a merge whose other arm is an argument, hypothesis Array',
             r && r['source'] == 'merge' && r['detail'] == 'Array|argument' && r['hyp'] == 'Array' && r['hyp_complete'] == '0')
  check.call('merged: forced to Array the by-name line goes away (a merge holds no nil)',
             r && r['before'].to_i.positive? && r['after'] == '0' && r['after_nil'] == '0')
  r = of.call('element').first
  check.call('element: the receiver is a GETIDX result, no hypothesis', r && r['source'] == 'element' && r['hyp'] == '-')
  r = of.call('argument').first
  # The `why` names the admission rule the method fails, not just `no_candidate`: `argument` is named as a token by a
  # scanned outside source, so rule 3 (outside_token) refuses it before its call site is ever read.
  check.call('argument: an incoming parameter whose method fails admission rule 3 (a name an outside source spells)',
             r && r['source'] == 'argument' && r['why'] == 'no_candidate:outside_token')
  r = of.call('box').first
  # `box` is called from nowhere in the world, so rule 8 (no call site to pool) is what refuses it -- a different
  # proof from rule 3, which is why the rule is named.
  check.call('argument: a parameter no call site reaches names rule 8 (no call site)',
             r && r['source'] == 'argument' && r['why'] == 'no_candidate:nosites')
  check.call('argument: the answering classes include Array and the kinds of their definitions are named',
             r && r['answerers'].include?('Array') && !r['kinds'].empty?)
  # A `|c|` block parameter must not inherit the enclosing method's admission rule: the two are different proofs,
  # and misnaming it would send the next reader after rule 8 for a yield the callee decides.
  r = of.call('each_block').first
  check.call('argument: a block parameter is named a block parameter, not a rule of the enclosing method',
             r && r['source'] == 'argument' && r['why'] == 'no_candidate:block_param')
  r = of.call('many').first
  check.call('floor: includes every answering class when more than 40 answer the name',
             r && r['answerers'].split('|').sort == 41.times.map { |i| "RpAnswer#{i}" }.sort)
  r = of.call('fromivar').first
  check.call('fromivar: an ivar whose pool the argument store drops', r && r['source'] == 'ivar' && r['why'].start_with?('dropped:argument'))
  r = of.call('fromcall').first
  check.call('fromcall: a self call to an ivar accessor, resolved per class it is a selfcall',
             r && r['source'] == 'call' && r['detail'] == 'makes' && r['percls'] == 'selfcall')
  check.call('proven: a literal receiver has no row that needs a proof', of.call('proven').none? { |row| row['source'] != 'literal' && row['existing'] == '-' })
  check.call('every unproven row has the columns of the layout', fixture.all? { |row| row['where'].to_s.include?(':') })
  summary, status = Open3.capture2e(RbConfig.ruby, File.join(ROOT, 'scripts/bc2cpp/receiver_proof_report.rb'), report)
  check.call('the aggregator reads the rows and counts the unproven sites',
             status.success? && summary.match?(/unproven \d+/) && summary.include?('merge'))
  unless failures.empty?
    fixture.each { |row| warn row.values_at('owner', 'name', 'source', 'detail', 'existing', 'hyp', 'why', 'before', 'after', 'after_nil', 'percls').join(' | ') }
  end
end

if failures.empty?
  puts 'ok'
else
  warn "FAILED: #{failures.size}"
  exit 1
end
