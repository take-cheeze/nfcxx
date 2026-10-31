#!/usr/bin/env ruby
# frozen_string_literal: true

require 'csv'
require 'fileutils'
require 'json'
require 'open3'
require 'tmpdir'

ROOT = File.expand_path('../..', __dir__)
Dir.mktmpdir('lookup-report') do |dir|
  source = File.join(dir, 'src')
  FileUtils.mkdir_p(source)
  File.write(File.join(source, 'fixture.c'), "int observed(void) { return 1; }\nint main(void) { return observed(); }\n")
  binary = File.join(dir, 'fixture')
  out, status = Open3.capture2e('cc', '-g', '-no-pie', File.join(source, 'fixture.c'), '-o', binary)
  abort out unless status.success?
  symbols, status = Open3.capture2e('nm', binary)
  abort symbols unless status.success?
  address = '0x' + symbols.lines.find { |line| line.end_with?(" observed\n") }.split.first
  logs = File.join(dir, 'logs')
  FileUtils.mkdir_p(logs)
  header = %w[owner_hex name_hex kind address core gems gameplay]
  rows = [
    ['A'.unpack1('H*'), 'observed'.unpack1('H*'), 'native-callable', address, 2, 1, 5],
    ['A'.unpack1('H*'), 'unused'.unpack1('H*'), 'native-callable', address, 0, 0, 0],
    ['B'.unpack1('H*'), 'new'.unpack1('H*'), 'undefined', '0x0', 0, 0, 0],
    ['<outside-final-table>'.unpack1('H*'), 'temporary'.unpack1('H*'), 'transient', '0x0', 0, 3, 0],
    ['<outside-final-table>'.unpack1('H*'), 'missing'.unpack1('H*'), 'missing', '0x0', 0, 0, 7]
  ]
  %w[first second].each do |name|
    path = File.join(logs, "#{name}.lookups.tsv")
    CSV.open(path, 'w', col_sep: "\t") { |csv| csv << header; rows.each { |row| csv << row } }
    File.write(path + '.stacks', "name_hex\tphase\tsamples\tframes\n#{'observed'.unpack1('H*')}\t2\t1\t#{address},\n")
    File.write(File.join(logs, "#{name}.vm.tsv"), "1\tC_entry\tstartup\n4\tSEND\tgame\n")
  end
  File.write(File.join(logs, 'baseline.vm.tsv'), "1\tC_entry\tstartup\n")
  report = File.join(dir, 'report')
  command = ['python3', File.join(ROOT, 'scripts/bc2cpp/method_lookup_report.py'), logs, binary, report]
  out, status = Open3.capture2e(*command)
  abort out unless status.success?
  summary = JSON.parse(File.read(File.join(report, 'summary.json')))
  abort 'incorrect installed/observed counts' unless summary.values_at('installed_entries', 'observed_entries', 'unobserved_entries') == [3, 1, 2]
  abort 'incorrect phase totals' unless summary['phase_lookups'] == { 'core' => 4, 'gems' => 2, 'gameplay' => 10 }
  abort 'incorrect VM baseline subtraction' unless summary['vm_starts_beyond_startup'] == { 'C_entry' => 0, 'SEND' => 8 }
  abort 'missing transient classification' unless summary['outside_installed_table'][0]['count'] == 6
  abort 'missing failed lookup classification' unless summary['misses'][0]['count'] == 14
  path = File.join(logs, 'second.lookups.tsv')
  File.write(path, CSV.generate(col_sep: "\t") { |csv| csv << header; rows.drop(1).each { |row| csv << row } })
  out, status = Open3.capture2e(*command)
  abort 'inconsistent tables accepted' if status.success? || !out.include?('inventory differs')
  puts 'method_lookup_report_check: phase counts, transient/missing classification, VM baseline and inventory validation passed'
end
