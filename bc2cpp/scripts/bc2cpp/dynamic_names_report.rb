#!/usr/bin/env ruby
# frozen_string_literal: true

# DYNAMIC_NAMES_REPORT: why each registered entry of the closed build (compiled engine methods, attr accessors,
# RGSS natives) stays in the method table. The closed-list proof (tools/bc2cpp/static_dispatch_registrations.rb) keeps an entry whose name some lookup may reach; this prints, per entry, the first source that made
# its name dynamic, and a summary of the sources that keep the most entries.
#
# Usage: MRBC=path/to/mrbc BC2CPP_STATIC_DISPATCH_LISTS=<scripts/bc2cpp/static_dispatch_lists.bash output> \
#        ruby scripts/bc2cpp/dynamic_names_report.rb [--entries] [--entries-out PATH]

require 'set'
require 'optparse'

options = { entries: false, entries_out: nil }
parser = OptionParser.new do |opts|
  opts.banner = "Usage: #{$PROGRAM_NAME} [--entries] [--entries-out PATH]"
  opts.on('--entries', 'Print entry rows instead of the summary') { options[:entries] = true }
  opts.on('--entries-out PATH', 'Also write entry rows from this analysis to PATH') { |path| options[:entries_out] = path }
end
parser.parse!
abort "unexpected arguments: #{ARGV.join(' ')}" unless ARGV.empty?

require_relative '../../tools/bc2cpp/static_dispatch_registrations'

sdr = StaticDispatchRegistrations
root = File.expand_path('../..', __dir__)
sdr.why = {}
# The report is of the state the build is in, so it reads the lists the build was given.
lists = StaticDispatchLists.current(required: true)
analysis = sdr.analyze(root, ENV.fetch('MRBC', 'mrbc'), lists: lists, lists_path: ENV.fetch(StaticDispatchLists::PATH_ENV),
                                                         closed_only: true)
why = sdr.why
eligible = sdr.eligible(analysis).to_set { |m| [m[:owner], m[:name]] }
re = sdr.owner_re(true)
kept = analysis[:registered].select { |m| m[:owner].match?(re) && !eligible.include?([m[:owner], m[:name]]) }
                            .uniq { |m| [m[:owner], m[:name]] }

reason = lambda do |name|
  next why[name] if why[name]

  base = name[0..-2]
  if name.end_with?('=', '?', '!') && (analysis[:suffix_bases] || analysis[:dynamic]).include?(base)
    "its base `#{base}`: #{why[base] || 'dynamic'} (SUFFIX_BASES)"
  elsif !name.match?(sdr::IDENT)
    'not an identifier (operator names are always dynamic)'
  elsif (f = analysis[:fragments].find { |s| s != name && (name.start_with?(s) || name.end_with?(s)) })
    "a string fragment #{f.inspect} may build it (FRAGMENT_USES)"
  else
    'dynamic'
  end
end

rows = kept.map { |m| [m[:owner], m[:name], reason.call(m[:name])] }.sort
if options[:entries_out]
  File.write(options[:entries_out], rows.map { |row| row.join("\t") + "\n" }.join)
end
if options[:entries]
  rows.each { |row| puts row.join("\t") }
else
  # A source's kind: the reason without the name that varies per site.
  kind = ->(r) { r.sub(/ in .*\z/, ' in ...').sub(/\Asent by .*, which/, 'sent by ..., which').sub(/`[^`]*`/, '`...`') }
  puts "kept entries: #{rows.size} (eligible: #{eligible.size})"
  puts "\nby kind of source:"
  rows.group_by { |_, _, r| kind.call(r) }.sort_by { |_, v| -v.size }.each { |k, v| puts format('%6d  %s', v.size, k) }
  puts "\ntop sources:"
  rows.group_by { |_, _, r| r }.sort_by { |_, v| -v.size }.first(40).each do |r, v|
    puts format('%6d  %s  (%s)', v.size, r, v.first(4).map { |o, n, _| "#{o}##{n}" }.join(', '))
  end
end
