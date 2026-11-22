#!/usr/bin/env ruby
# frozen_string_literal: true

# ALLOC_COUNTER report: turns the counts trace_host_alloc runs wrote (alloc_counter.cxx) into per-site tables.
#
#   ruby alloc_counter_report.rb --binary BUILD/trace-host/trace_host_alloc [--out OUT] [--top N] COUNT_DIR
#
# The site of an allocation is the first frame outside mruby's own sources (src/, mrbgems/, the wrapper): a compiled
# Ruby method's generated line, an RGSS native, or the bc2cpp runtime. `via` is the mruby function that frame called
# (mrb_ary_new_from_values, mrb_str_new, ...). A return address is resolved with addr2line -i, so a helper inlined
# into a compiled method is attributed to the method.
#
# Writes OUT/sites.tsv (group, kind, site, where, via, type, objects, malloc_bytes, line text) and OUT/report.txt
# (ranked by objects and by bytes, per group). Groups: each COUNT_DIR/NAME.tsv; map-* files fold into `maps`.
require 'optparse'
require 'fileutils'

options = { top: 40 }
OptionParser.new do |o|
  o.banner = 'usage: alloc_counter_report.rb --binary BIN [--out OUT] [--top N] COUNT_DIR'
  o.on('--binary BIN') { |v| options[:binary] = v }
  o.on('--out OUT') { |v| options[:out] = v }
  o.on('--top N', Integer) { |v| options[:top] = v }
end.parse!
dir = ARGV.shift or abort 'alloc_counter_report: COUNT_DIR is required'
bin = options[:binary] or abort 'alloc_counter_report: --binary is required'
out = options[:out] || File.join(dir, 'report')
FileUtils.mkdir_p(out)

# mruby's enum mrb_vtype (include/mruby/value.h order).
TT = %w[false true symbol undef free float integer cptr object class module sclass hash cdata exception iclass proc
        array string range env fiber struct istruct break complex rational bigint backtrace set].freeze

rows = []
Dir[File.join(dir, '*.tsv')].sort.each do |path|
  base = File.basename(path, '.tsv')
  group = base.start_with?('map-') ? 'maps' : base
  File.foreach(path) do |line|
    kind, tt, cls, count, bytes, pcs = line.chomp.split("\t", 6)
    next unless pcs

    rows << [group, kind, tt.to_i, cls, count.to_i, bytes.to_i, pcs.split(',').map { |h| h.to_i(16) }]
  end
end
abort "alloc_counter_report: no counts in #{dir}" if rows.empty?

addrs = rows.flat_map { |r| r[6] }.reject(&:zero?).uniq
frames = {}
IO.popen(['addr2line', '-a', '-i', '-f', '-C', '-e', bin], 'r+') do |io|
  writer = Thread.new do
    addrs.each { |a| io.puts format('0x%x', a - 1) }
    io.close_write
  end
  current = nil
  pending = nil
  io.each_line do |line|
    line = line.chomp
    if line.start_with?('0x')
      current = line.hex + 1
      frames[current] = []
    elsif pending.nil?
      pending = line
    else
      frames[current] << [pending, line.sub(/ \(discriminator \d+\)\z/, '')]
      pending = nil
    end
  end
  writer.join
end

MRUBY_OWN = %r{/3rd/mruby/(?:src|mrbgems|include)/|alloc_counter|/libc|/usr/}
def short(path)
  path.sub(%r{\A.*?/(closed/mrbgems/|3rd/mruby/|3rd/|mruby-rgss/|mruby-rpg2k/|mruby-lcf/|bc2cpp/)}, '\1')
end

# bc2cpp's call and rescue glue between two compiled methods; the caller is the compiled frame past it.
GLUE = /\A(?:\w+::)*(?:bc2cpp_(?:protect|call_found|native_slot\w*|funcall\w*|owner_call\w*|rescue\w*|ensure\w*)|
       mrb_funcall\w*|mrb_call_direct|mrb_protect\w*)(?:\(|\z)|_rescue_try\(/x
FUNC = /\A(?:\w+::)*([^(]+)/
def fname(func) = func[FUNC, 1] || func

site_of = lambda do |pcs|
  via = '?'
  site = nil
  pcs.each do |pc|
    chain = frames[pc] || []
    next if chain.empty?

    func, file = chain.last
    if site
      next if func.match?(GLUE) || file.match?(MRUBY_OWN) || fname(func) == fname(site[0])

      return site + [fname(func)]
    end
    if file.match?(MRUBY_OWN) || file.start_with?('??')
      via = fname(func)
      next
    end
    site = [func, short(file), via]
  end
  site ? site + ['?'] : ['(mruby)', '?', via, '?']
end

text_cache = {}
line_text = lambda do |where|
  path, line = where.split(/:(?=\d+\z)/)
  return '' unless line

  full = Dir.glob("#{File.dirname(bin)}/../closed/#{path.sub(%r{\Aclosed/}, '')}").first || path
  text_cache[full] ||= File.file?(full) ? File.readlines(full, chomp: true) : []
  text_cache[full][line.to_i - 1].to_s.strip[0, 200]
end

sites = Hash.new { |h, k| h[k] = [0, 0] }   # [group, site, where, via, type, caller] => [objects, bytes]
methods = Hash.new { |h, k| h[k] = [0, 0] } # [group, site function, caller] => [objects, bytes]
totals = Hash.new { |h, k| h[k] = [0, 0] }
rows.each do |group, kind, tt, cls, count, bytes, pcs|
  func, where, via, caller = site_of.call(pcs)
  type = kind == 'obj' ? "#{TT[tt] || tt}:#{cls}" : 'malloc'
  objs = kind == 'obj' ? count : 0
  [group, 'all'].each do |g|
    [sites[[g, func, where, via, type, caller]], methods[[g, fname(func), caller]], totals[g]].each do |v|
      v[0] += objs
      v[1] += bytes
    end
  end
end

File.open(File.join(out, 'sites.tsv'), 'w') do |f|
  f.puts "group\tsite\twhere\tvia\ttype\tcaller\tobjects\tmalloc_bytes\ttext"
  sites.sort_by { |(g, *), (o, b)| [g, -o, -b] }.each do |(g, s, w, v, t, c), (o, b)|
    f.puts [g, s, w, v, t, c, o, b, o >= 500 || b >= 50_000 ? line_text.call(w) : ''].join("\t")
  end
end

File.open(File.join(out, 'report.txt'), 'w') do |r|
  totals.keys.sort.each do |g|
    objs, bytes = totals[g]
    r.puts "== #{g}: #{objs} objects, #{bytes} malloc bytes"
    mine = methods.select { |(gg, *), _| gg == g }
    r.puts '  by method (objects, malloc bytes, method <- caller):'
    mine.sort_by { |_, (o, b)| [-o, -b] }.first(options[:top]).each do |(_, m, c), (o, b)|
      r.puts format('    %8d %10d  %s <- %s', o, b, m[0, 70], c[0, 60])
    end
    r.puts '  by malloc bytes:'
    mine.sort_by { |_, (_, b)| -b }.first(options[:top] / 2).each do |(_, m, c), (o, b)|
      r.puts format('    %8d %10d  %s <- %s', o, b, m[0, 70], c[0, 60])
    end
    r.puts '  by site (objects, type, via, generated line):'
    sites.select { |(gg, *), _| gg == g }.sort_by { |_, (o, _)| -o }.first(options[:top]).each do |(_, s, w, v, t), (o, _)|
      r.puts format('    %8d  %-22s %-50s %-24s %s', o, t[0, 22], fname(s)[0, 50], v[0, 24], w)
    end
  end
end
puts File.read(File.join(out, 'report.txt'))
