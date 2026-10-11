#!/usr/bin/env ruby
# frozen_string_literal: true

# ADR 0337: report named setter inputs without changing code or claiming completeness.
require 'json'
require_relative 'fixture_runtime'

unless ENV['MRBC']
  puts '-- SKIP: set MRBC'
  exit 0
end
failures = []
check = lambda do |name, ok|
  puts "  #{ok ? 'ok  ' : 'FAIL'} #{name}"
  failures << name unless ok
end
source = <<~RUBY
  class NsBox
    def tag; 7; end
  end
  class NsRunner
    def known(window); window.contents = NsBox.new; end
    def unknown(sprite, value); sprite.bitmap = value; end
    def nil_value(sprite); sprite.bitmap = nil; end
    def dynamic(receiver, name, value); receiver.public_send(name, value); end
    def capture(receiver); receiver.method(:contents=); end
  end
RUBY
Dir.mktmpdir do |dir|
  saved = ENV['BC2CPP_NATIVE_SETTER_REPORT']
  begin
    ENV.delete('BC2CPP_NATIVE_SETTER_REPORT')
    plain, = Bc2cppFixtureRuntime.generate(source, dir, only_owners: %w[NsBox NsRunner])
    path = File.join(dir, 'setters.json')
    ENV['BC2CPP_NATIVE_SETTER_REPORT'] = path
    reported, = Bc2cppFixtureRuntime.generate(source, dir, only_owners: %w[NsBox NsRunner])
    check.call('setter report changes no generated code', plain == reported)
    report = JSON.parse(File.read(path))
    check.call('versioned diagnostic schema', report['schema_version'] == 1 && report['diagnostic_only'])
    check.call('computed names are a completeness blocker', report['computed_names_present'])
    check.call('native setter families never gain a pool', report['contracts'].values.all? { |contract| contract['native_family_pooling'] == false && contract['caller_completeness'] == 'not_proven' })
    sites = report.fetch('sites')
    known = sites.find { |row| row['owner'] == 'NsRunner#known' }
    unknown = sites.find { |row| row['owner'] == 'NsRunner#unknown' }
    nil_value = sites.find { |row| row['owner'] == 'NsRunner#nil_value' }
    check.call('known supplied class is reported independently of receiver', known && known['input'] == 'NsBox' && known['blockers'].include?('receiver_unresolved'))
    check.call('unknown input remains unknown', unknown && unknown['blockers'].include?('input_unresolved'))
    check.call('nil is a supplied value, not a missing input', nil_value && nil_value['input'] == 'NIL' && !nil_value['blockers'].include?('input_unresolved'))
    check.call('method capture is a mention, not a named setter call', report['mentions'].any? { |row| row['setter'] == 'contents=' && row['opcode'] == 'LOADSYM' } && report['contracts']['contents=']['named_calls'] == 1)
    closed_sites = report['sites']
    bitmap_flag = ENV['BC2CPP_NATIVE_BITMAP_IVAR_SCOPE']
    begin
      ENV['BC2CPP_NATIVE_BITMAP_IVAR_SCOPE'] = '0'
      Bc2cppFixtureRuntime.generate(source, dir, only_owners: %w[NsBox NsRunner])
      disabled = JSON.parse(File.read(path))
      check.call('withdrawn source audit makes no input contract claim', !disabled['contracts']['bitmap=']['native_scope_audited'] && disabled['contracts']['bitmap=']['input_behavior'] == 'not_audited')
    ensure
      ENV['BC2CPP_NATIVE_BITMAP_IVAR_SCOPE'] = bitmap_flag
    end
    Bc2cppFixtureRuntime.generate(source, dir, only_owners: %w[NsBox NsRunner], closed: false)
    open_report = JSON.parse(File.read(path))
    check.call('open-world report claims no caller proof', !open_report['closed_world'] && open_report['contracts'].values.all? { |contract| contract['caller_completeness'] == 'not_proven' })
    check.call('open-world report still enumerates named calls', open_report['sites'].size == closed_sites.size)
  ensure
    ENV['BC2CPP_NATIVE_SETTER_REPORT'] = saved
  end
end
abort "FAILED: #{failures.join(', ')}" unless failures.empty?
puts 'bc2cpp native setter report check: PASS'
