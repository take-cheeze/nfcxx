# frozen_string_literal: true

# Single-class send profile: joins the receiver-trace dumps (BC2CPP_TRACE_RECV_OUT) with the
# site list of the instrumented build, and writes the by-name sites that saw one receiver class.
#
#   ruby scripts/bc2cpp/send_profile.rb --build BUILD_DIR [--min-hits N] [--out FILE] DUMP [...]
#
# The site list is the `bc2cpp_recv_meta_<unit>` array of each generated unit (BUILD_DIR/closed/mrbgems/**/*_gen.cpp),
# in site-id order, one row per by-name send or block call. A site's ordinal is its position among the sites of the
# same unit, method and name, in that order. The ordinal is the key a later guard pass reads; it does not depend on
# the C++ line, which moves with every codegen change.
#
# Output (TSV): unit, method, name, ordinal, kind, class, hits. Sites with no hit are not listed.

require 'optparse'

options = { min_hits: 1, out: nil, build: nil }
OptionParser.new do |o|
  o.banner = 'usage: send_profile.rb --build BUILD_DIR [--min-hits N] [--out FILE] DUMP [...]'
  o.on('--build DIR', 'instrumented build directory') { |v| options[:build] = v }
  o.on('--min-hits N', Integer, 'fewest hits a site needs to be listed (default 1)') { |v| options[:min_hits] = v }
  o.on('--out FILE', 'write the profile here (default: stdout)') { |v| options[:out] = v }
end.parse!
abort 'no --build given' unless options[:build]
abort 'no dump files given' if ARGV.empty?

# unit -> [{ method:, name:, kind: }] in site-id order.
sites = {}
Dir.glob(File.join(options[:build], 'closed/mrbgems/**/*_gen.cpp')).sort.each do |path|
  text = File.read(path)
  text.scan(/static const char\* const bc2cpp_recv_meta_(\w+)\[\d+\] = \{\n(.*?)\n\};/m) do |unit, body|
    rows = body.scan(/"((?:[^"\\]|\\.)*)"/).map do |(raw)|
      method, _fn, name, _line, kind, _recv = raw.gsub('\\011', "\t").split("\t", -1)
      { method: method, name: name, kind: kind }
    end
    sites[unit] = rows
  end
end
abort "no bc2cpp_recv_meta arrays under #{options[:build]}" if sites.empty?

# ordinal per (unit, method, name), counted in site-id order.
ordinal_of = {}
sites.each do |unit, rows|
  counts = Hash.new(0)
  rows.each_with_index do |row, id|
    key = [row[:method], row[:name]]
    ordinal_of[[unit, id]] = counts[key]
    counts[key] += 1
  end
end

# hits and receiver classes per (unit, site id), summed over the dumps.
hits = Hash.new(0)
classes = Hash.new { |h, k| h[k] = Hash.new(0) }
ARGV.each do |path|
  File.foreach(path) do |raw|
    f = raw.chomp.split("\t", -1)
    case f[0]
    when 'RECV_SITE' then hits[[f[1], f[2].to_i]] += f[3].to_i
    when 'RECV_CLASS' then classes[[f[1], f[2].to_i]][f[3]] += f[6].to_i
    end
  end
end

rows = []
hits.each do |(unit, id), total|
  next if total < options[:min_hits]

  seen = classes[[unit, id]]
  next unless seen.size == 1
  row = sites[unit] && sites[unit][id]
  next unless row

  rows << [unit, row[:method], row[:name], ordinal_of[[unit, id]], row[:kind], seen.keys.first, total]
end

text = (["unit\tmethod\tname\tordinal\tkind\tclass\thits"] + rows.sort.map { |r| r.join("\t") }).join("\n") + "\n"
if options[:out]
  File.write(options[:out], text)
  warn "send_profile: #{rows.size} single-class site(s) of #{hits.size} reached, #{sites.values.sum(&:size)} instrumented"
else
  print text
end
