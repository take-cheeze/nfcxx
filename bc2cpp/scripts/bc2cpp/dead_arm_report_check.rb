#!/usr/bin/env ruby
# frozen_string_literal: true

# Check BC2CPP_DEAD_ARM_REPORT (docs/adr/0330, tools/bc2cpp/dead_arm_report.rb): the report is a measurement, so the
# generated C++ must be byte-identical with it on, and its rows must classify the arms of a fixture: the else of a
# class chain, a nil path, a guarded site, a method nothing calls, and the other must-raise shapes.
#
# Usage: MRBC=path/to/mrbc ruby scripts/bc2cpp/dead_arm_report_check.rb

require 'open3'
require 'rbconfig'
require 'shellwords'
require 'tmpdir'
require_relative '../../tools/bc2cpp/compiled_gems'
require_relative '../../tools/bc2cpp/nomethod_reviewed'
require_relative '../../tools/bc2cpp/nomethod_reviewed_probe'
require_relative '../../tools/bc2cpp/dead_arm_report_columns'

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
  class DaBox
    def ping; 1; end
  end

  class DaBox2
    def ping; 2; end
  end

  class DaFx
    def initialize; @box = nil; end
    def open; @box = DaBox.new; end
    def chain(x); x.ping; end
    def nilpath; @box.ping; end
    def laterset; @box.zzz_dispose if @box; @box = DaBox.new; @box.ping; end
    def allmiss; DaBox.new.zzz_none; end
    def rescued; @box.ping; rescue NoMethodError; 0; end
    def uncalled(x); x.ping; end
    def missing_const; Zzz_NoSuchConstant; end
    def guarded_const; Zzz_GuardedConstant; rescue NameError; 0; end
    def arity_bad; one_arg(1, 2); end
    def one_arg(a); a; end
  end

  f = DaFx.new
  f.open
  f.chain(DaBox.new)
  f.nilpath
  f.rescued
  f.laterset
  f.allmiss
  f.missing_const
  f.guarded_const
  f.arity_bad
RUBY

generate = lambda do |dir, extra_env = {}|
  path = File.join(dir, 'da_fixture.rb')
  File.write(path, SOURCE)
  env = { 'MRBC' => ENV.fetch('MRBC'), 'OUT_SYMBOL' => 'da_fixture', 'OUT_DIR' => dir, 'SKIP_UNSUPPORTED' => '1',
          'NATIVE_SRCS' => Shellwords.join(core_native_srcs("#{ROOT}/3rd/mruby") + external_gem_native_srcs(ROOT)),
          'FOREIGN_RUBY_SRCS' => Shellwords.join(foreign_mrblib_srcs(ROOT)),
          'ONLY_OWNERS' => (BC2CPP_CORE_OWNERS + %w[DaFx DaBox DaBox2]).join(','),
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
  report = File.join(dir, 'da.tsv')
  code_off = generate.call(plain)
  code_on = generate.call(withr, 'BC2CPP_DEAD_ARM_REPORT' => report)

  puts "== generated code"
  check.call('the report changes no generated code', code_on == code_off)
  all = File.readlines(report, chomp: true).reject(&:empty?).map { |l| DeadArmReport::COLUMNS.zip(l.split("\t", -1)).to_h }
  mine = all.select { |r| r['gem'] == 'other' }
  by = ->(kind, method) { mine.select { |r| r['kind'] == kind && r['method'] == "DaFx##{method}" } }

  puts '== rows'
  r = by.call('nomethod', 'chain').first
  check.call('chain: the else of the class chain, live, unguarded', r && r['shape'] == 'chain' && r['live'] == 'live' && r['guard'] == '-')
  r = by.call('nil_receiver', 'nilpath').first
  check.call('nilpath: the nil path of a nil-or-DaBox ivar, with its origin and nil source',
             r && r['shape'] == 'nil' && r['live'] == 'live' && r['guard'] == '-' && r['origin'].start_with?('@box [init:nil'))
  r = by.call('partial_miss', 'laterset').first
  check.call('laterset: a test of the receiver ivar precedes the call, so the guard is a hint', r && r['guard'] == 'hint')
  r = by.call('partial_miss', 'allmiss').first
  check.call('allmiss: an exact receiver whose class lacks the name is a partial_miss with shape all',
             r && r['shape'] == 'all' && r['live'] == 'live' && r['guard'] == '-')
  check.call('allmiss: the send keeps its dynamic dispatch, so no arm row exists for it', by.call('nomethod', 'allmiss').empty?)
  r = by.call('nil_receiver', 'rescued').first
  check.call('rescued: inside a rescue range', r && r['guard'] == 'rescue')
  r = (by.call('nomethod', 'uncalled') + by.call('nil_receiver', 'uncalled')).first
  check.call('uncalled: no live caller by name, so dead', r && r['live'] == 'dead')
  r = mine.find { |row| row['kind'] == 'const_unresolved' && row['name'] == 'Zzz_NoSuchConstant' }
  check.call('an undefined constant is listed, unguarded', r && r['guard'] == '-' && r['live'] == 'live')
  r = mine.find { |row| row['kind'] == 'const_unresolved' && row['name'] == 'Zzz_GuardedConstant' }
  check.call('an undefined constant under rescue NameError is listed as guarded', r && r['guard'] == 'rescue')
  r = by.call('arity_all', 'arity_bad').first
  check.call('a call every definition rejects is listed (argc=2 against one_arg(a))', r && r['name'] == 'one_arg' && r['shape'] == 'argc=2')
  unless failures.empty?
    mine.each { |row| warn row.values_at('kind', 'method', 'name', 'shape', 'live', 'guard', 'origin').join(' | ') }
  end
end

if failures.empty?
  puts 'ok'
else
  warn "FAILED: #{failures.size}"
  exit 1
end
