#!/usr/bin/env ruby
# frozen_string_literal: true

# SEND_COUNTER report: turns the per-process counts a trace_host_counted run wrote (send_counter.cxx, via
# `SEND_COUNT_DIR=DIR host_sweep.bash BUILD`) into per-call-site tables.
#
#   ruby send_counter_report.rb --binary BUILD/trace-host/trace_host_counted [--out OUT] [--top N] COUNT_DIR
#
# A return address is resolved with addr2line (-i, so a helper inlined into a compiled method is attributed to the
# method). The site of a call is the first frame that is not one of bc2cpp's call helpers (bc2cpp_funcall_argv,
# bc2cpp_owner_call, ...): the compiled Ruby method, the mruby core function or the gem function that made it.
# A call whose first frame is vm_frames.cxx itself is the frames-only runtime calling its own entry (mrb_funcall_send
# into mrb_funcall_with_method), counted once already at the outer function; those are listed as `internal`.
#
# Kinds: by-name sends (funcall, funcall_id, funcall_argv, funcall_with_block, funcall_send: the method is looked
# up by name); found-method frame pushes (funcall_with_method, funcall_send_with_method: the method was found by the
# caller, no lookup); lookups (vm_find_method: OP_SEND and by-name sends, through the method cache; method_search,
# method_search_plain: a search of the tables; method_memo, respond_to, obj_respond_to); yields.
#
# Writes OUT/summary.tsv (group, kind, calls, processes), OUT/callers.tsv (kind, category, site, calls),
# OUT/sites.tsv (kind, site, generated file:line, calls, the line's text), OUT/names.tsv (kind, name, calls) and
# OUT/report.txt (the same, ranked); with BC2CPP_SENDCNT_DETAIL=1 in the run, OUT/collisions.tsv: lookups that found
# another (class, name) pair in their method-cache slot, which is how two hot call sites evict each other. Groups: each scenario, `maps` (every map-N), `all`.
require 'optparse'
require 'open3'
require 'fileutils'

BY_NAME = %w[funcall funcall_id funcall_argv funcall_with_block funcall_send].freeze
FOUND = %w[funcall_with_method funcall_send_with_method].freeze
LOOKUP = %w[method_search method_search_plain vm_find_method method_memo respond_to obj_respond_to].freeze
YIELD = %w[yield yield_argv yield_with_class].freeze
# Helpers whose caller is the site: bc2cpp's generated call helpers, and the core functions that only look a method up.
HELPER = /\A(?:\w+::)*(?:bc2cpp_(?:funcall\w*|ssend|send\w*|owner_call\w*|find_method\w*|proc_call\w*|dyn_\w+|
          nil_receiver|nomethod\w*|respond_to\w*|call_block\w*|yield\w*|direct_\w+|left_out|native_singleton)|
          mrb_func_basic_p|mrb_method_memo)(?:\(|\z)/x
WRAPPED = /\A(?:mrb_funcall\w*|mrb_yield\w*|funcall_with_block_m|__wrap_\w+|mrb_method_search_vm|mrb_method_memo|
            mrb_obj_respond_to|mrb_respond_to|mrb_vm_find_method|mrb_method_search)(?:\(|\z)/x

options = { top: 40 }
OptionParser.new do |o|
  o.banner = 'usage: send_counter_report.rb --binary BIN [--out OUT] [--top N] COUNT_DIR'
  o.on('--binary BIN') { |v| options[:binary] = v }
  o.on('--out OUT') { |v| options[:out] = v }
  o.on('--top N', Integer) { |v| options[:top] = v }
end.parse!
dir = ARGV.shift or abort 'send_counter_report: COUNT_DIR is required'
bin = options[:binary] or abort 'send_counter_report: --binary is required'
out = options[:out] || File.join(dir, 'report')
FileUtils.mkdir_p(out)

# [group, kind, name, count, [pc...]]
rows = []
procs = Hash.new(0)
Dir[File.join(dir, '*.tsv')].sort.each do |path|
  base = File.basename(path, '.tsv')
  group = base.start_with?('map-') ? 'maps' : base
  procs[group] += 1
  File.foreach(path) do |line|
    kind, name, count, pcs = line.chomp.split("\t", 4)
    next unless pcs

    rows << [group, kind, name, count.to_i, pcs.split(',').map { |h| h.to_i(16) }]
  end
end
abort "send_counter_report: no counts in #{dir}" if rows.empty?

# addr2line over every distinct return address (minus one: the call instruction, not the one after it).
addrs = rows.flat_map { |r| r[4] }.reject(&:zero?).uniq
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

def category(file)
  case file
  when %r{/mruby-(core|rpg2k|rgss|lcf)-compiled/.*_gen} then "generated:#{Regexp.last_match(1)}"
  when %r{/3rd/mruby/src/([^/]+)} then "core:#{Regexp.last_match(1)}"
  when %r{/3rd/mruby/mrbgems/([^/]+)} then "gem:#{Regexp.last_match(1)}"
  when %r{/3rd/(mruby-[^/]+)} then "gem:#{Regexp.last_match(1)}"
  when %r{mruby-rgss/} then 'rgss-native'
  when %r{/runtime/|bc2cpp_fiber|vm_frames} then 'bc2cpp-runtime'
  when /trace_host/ then 'host'
  else 'other'
  end
end

def short(path)
  path.sub(%r{\A.*?/(closed/mrbgems/|3rd/mruby/|3rd/|mruby-rgss/|bc2cpp/)}, '\1')
end

# The outermost function of each address's inline chain, and the source line it made the call from.
site_of = lambda do |pcs|
  pcs.each_with_index do |pc, i|
    chain = frames[pc] || []
    next if chain.empty?

    func, file = chain.last
    next if i.zero? && func.match?(WRAPPED) && file.include?('vm_frames')
    next if func.match?(HELPER)

    return [func, file]
  end
  ['?', '?:0']
end

internal = Hash.new(0)
agg = Hash.new(0)        # [group, kind] => calls
callers = Hash.new(0)    # [kind, category, site] => calls
sites = Hash.new(0)      # [kind, site, file:line] => calls
names = Hash.new(0)      # [kind, name] => calls
name_site = Hash.new(0)  # [kind, name, site] => calls
evict = Hash.new(0)      # [kind, name, site, slot, occupant, same-class?] => lookups (detail mode)
rows.each do |group, kind, name, count, pcs|
  first = (frames[pcs[0]] || []).first
  if first && first[0].match?(WRAPPED) && first[1].include?('vm_frames')
    internal[kind] += count
    next
  end
  detail = nil
  if name.include?('|c=')
    base_name, cls, slot, occ, = name.split('|')
    klass = cls.delete_prefix('c=')
    occ_name, occ_klass = occ.delete_prefix('occ=').split('@')
    detail = [slot.delete_prefix('slot='), occ_name, occ_klass == klass ? 'same-class' : 'other-class']
    name = base_name
  end
  func, file = site_of.call(pcs)
  cat = category(file)
  agg[[group, kind]] += count
  agg[['all', kind]] += count
  callers[[kind, cat, func]] += count
  sites[[kind, func, short(file)]] += count
  names[[kind, name]] += count unless name.empty?
  evict[[kind, name, func, *detail]] += count if detail
  name_site[[kind, name, func]] += count unless name.empty?
end

File.open(File.join(out, 'summary.tsv'), 'w') do |f|
  f.puts "group\tkind\tcalls\tprocesses"
  agg.sort_by { |(g, k), _| [g, k] }.each { |(g, k), n| f.puts "#{g}\t#{k}\t#{n}\t#{g == 'all' ? procs.values.sum : procs[g]}" }
end
File.open(File.join(out, 'callers.tsv'), 'w') do |f|
  f.puts "kind\tcategory\tsite\tcalls"
  callers.sort_by { |(k, c, s), n| [k, -n, c, s] }.each { |(k, c, s), n| f.puts "#{k}\t#{c}\t#{s}\t#{n}" }
end

# The generated line a site call is on, for the sites that matter.
text_cache = {}
line_text = lambda do |where|
  path, line = where.split(/:(?=\d+\z)/)
  return '' unless line

  full = Dir.glob("#{File.dirname(bin)}/../closed/#{path.sub(%r{\Aclosed/}, '')}").first || path
  text_cache[full] ||= File.file?(full) ? File.readlines(full, chomp: true) : []
  text_cache[full][line.to_i - 1].to_s.strip[0, 220]
end
File.open(File.join(out, 'sites.tsv'), 'w') do |f|
  f.puts "kind\tsite\twhere\tcalls\ttext"
  sites.sort_by { |(k, s, w), n| [k, -n, s, w] }.each { |(k, s, w), n| f.puts "#{k}\t#{s}\t#{w}\t#{n}\t#{n >= 1000 ? line_text.call(w) : ''}" }
end
File.open(File.join(out, 'names.tsv'), 'w') do |f|
  f.puts "kind\tname\tcalls"
  names.sort_by { |(k, nm), n| [k, -n, nm] }.each { |(k, nm), n| f.puts "#{k}\t#{nm}\t#{n}" }
end

unless evict.empty?
  File.open(File.join(out, 'collisions.tsv'), 'w') do |f|
    f.puts "kind\tname\tsite\tcache_slot\toccupant\toccupant_class\tlookups"
    evict.sort_by { |_, n| -n }.each { |(k, nm, site, slot, occ, same), n| f.puts "#{k}\t#{nm}\t#{site}\t#{slot}\t#{occ}\t#{same}\t#{n}" }
  end
end

total = lambda { |kinds| kinds.sum { |k| agg[['all', k]] } }
File.open(File.join(out, 'report.txt'), 'w') do |r|
  r.puts "processes: #{procs.values.sum} (#{procs.map { |g, n| "#{g}=#{n}" }.join(' ')})"
  r.puts "by-name sends: #{total.call(BY_NAME)}  found-method frame pushes: #{total.call(FOUND)}  " \
         "lookups: #{total.call(LOOKUP)}  yields: #{total.call(YIELD)}"
  r.puts "internal (vm_frames.cxx into itself, excluded): #{internal.map { |k, n| "#{k}=#{n}" }.join(' ')}" unless internal.empty?
  (BY_NAME + FOUND + LOOKUP + YIELD).each do |kind|
    n = agg[['all', kind]]
    next if n.zero?

    r.puts "\n== #{kind}: #{n}"
    r.puts '  by site:'
    sites.select { |(k, _, _), _| k == kind }.sort_by { |_, c| -c }.first(options[:top]).each do |(_, s, w), c|
      r.puts format('    %10d  %-60s %s', c, s[0, 60], w)
    end
    next unless BY_NAME.include?(kind) || kind == 'method_search'

    r.puts '  by name:'
    names.select { |(k, _), _| k == kind }.sort_by { |_, c| -c }.first(15).each { |(_, nm), c| r.puts format('    %10d  %s', c, nm) }
  end
end
puts File.read(File.join(out, 'report.txt'))
