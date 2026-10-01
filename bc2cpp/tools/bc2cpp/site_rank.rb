# frozen_string_literal: true

require 'optparse'
require_relative 'site_profile'

# Ranks the by-name dispatch sites of a SITE_PROFILE build (ADR 0298) by how
# often the workloads executed them. Inputs: the <symbol>.sites.tsv files bc2cpp
# wrote and the <symbol>.<pid>.hits files the instrumented binaries dumped.
module SiteRank
  Table = Struct.new(:sites, :digest)
  Site = Struct.new(:symbol, :id, :kind, :line, :fn, :name, :category, :marker, :hits, keyword_init: true)

  # Reason category prefix -> the proof that would turn the site into a direct call.
  # A category names why codegen kept the site, not whether the proof can be had.
  LEVERS = {
    'closed_world_kept' => 'review the kept reason; the closed-world proof already ran (ADR 0210)',
    'known_class_arm_still_by_name' => 'direct arm for the proven class (ADR 0297 unlisted-class arms)',
    'rgss_native_exact_class_else' => 'native exact-class direct call (ADR 0274 audited natives)',
    'core_tag_chain_else:receiver_is_ivar' => 'typed ivar class fact or class pool (ADR 0296)',
    'core_tag_chain_else:receiver_other' => 'receiver class proof (return-class table, ADR 0289) or core-method direct arm',
    'poly_diag:dynamic_single_registered_definition/receiver_class_unresolved' =>
      'one bytecode definer: prove the receiver class (ivar class set, class pool ADR 0296, return-class table) for a direct call',
    'poly_diag:dynamic_no_registered_definition/receiver_class_unresolved' =>
      'no bytecode definer (native or core): exact receiver class plus an audited native direct arm (ADR 0274)',
    'poly_diag:dynamic_single_registered_definition/implicit_self_unresolved' =>
      'implicit self, one definer: prove the self class (owner chain) for a direct call',
    'poly_diag:dynamic_no_registered_definition/implicit_self_unresolved' =>
      'implicit self, no bytecode definer: direct native call on the self class',
    'poly_diag:dynamic_single_registered_definition/traced_class_no_direct_target' =>
      'class known, lookup gives no direct target: unlisted-class arm for it (ADR 0297)',
    'poly_diag:dynamic_no_registered_definition/traced_class_no_direct_target' =>
      'class known, no bytecode definer: native-direct arm for that class (ADR 0274)',
    'poly_diag:chain/runtime_class' => 'inherent: the receiver class is chosen at run time',
    'poly_diag:dynamic_no_complete_candidate_set' => 'candidate set not provably complete: close the world for the name',
    'owner_chain_default_else' => 'prove the receiver is one of the owner classes (class pools, ADR 0296)',
    'other:no_guard_nearby' => 'unguarded send: prove the receiver class (literal, exact-class arm or class pool)',
    'other:numeric_tag_guard' => 'numeric operand proof for the other operand (ADR 0292 slow path)',
    'shared_helper' => 'none per site: specialise the helper at its callers',
    'block_fallback' => 'BLOCK_CORE_DIRECT / yield-free block proof (ADR 0283)',
    'funcall' => 'convert to a direct call or bc2cpp_send arm; no guard chain exists here'
  }.freeze

  module_function

  COMPUTED_SEND = 'computed-name send: prove the finite name set of the argument (ADR 0279) and expand it to direct calls'

  def lever(category, name = nil)
    return COMPUTED_SEND if name == 'send' && category.include?('implicit_self')

    key = LEVERS.keys.select { |k| category == k || category.start_with?("#{k}/", "#{k}:") }.max_by(&:size)
    key ? LEVERS[key] : 'none matched: classify the category'
  end

  def load_sites(dir)
    files = Dir[File.join(dir, '*.sites.tsv')].sort
    raise "no *.sites.tsv under #{dir}" if files.empty?

    files.to_h do |f|
      symbol = File.basename(f, '.sites.tsv')
      rows = File.readlines(f, chomp: true)
      cols = rows.shift.split("\t", -1)
      raise "#{f}: unexpected columns #{cols.inspect}" unless cols == SiteProfile::SITE_COLUMNS

      parsed = rows.map { |r| cols.zip(r.split("\t", -1)).to_h }
      sites = parsed.map do |h|
        Site.new(symbol: symbol, id: h['id'].to_i, kind: h['kind'], line: h['line'].to_i, fn: h['fn'], name: h['name'],
                 category: h['category'], marker: h['marker'], hits: Hash.new(0))
      end
      [symbol, Table.new(sites, SiteProfile.digest(parsed.map { |h| h.transform_keys(&:to_sym) }))]
    end
  end

  # Adds every <symbol>.<pid>.hits under dir to the sites' per-workload counts.
  def add_hits(by_symbol, workload, dir)
    files = Dir[File.join(dir, '*.hits')].sort
    raise "no *.hits under #{dir} (workload #{workload}): was the binary built from a BC2CPP_SITE_PROFILE output?" if files.empty?

    files.each do |f|
      symbol = File.basename(f)[/\A(.+)\.\d+\.hits\z/, 1] or raise "#{f}: not <symbol>.<pid>.hits"
      table = by_symbol.fetch(symbol) { raise "#{f}: no #{symbol}.sites.tsv for these hits" }
      sites = table.sites
      lines = File.readlines(f, chomp: true)
      stamp = lines.shift.to_s[/\A# sites (\h+)\z/, 1]
      raise "#{f}: hits are from a different build than #{symbol}.sites.tsv (stale build directory?)" unless stamp == table.digest

      lines.each do |l|
        id, count = l.split("\t").map(&:to_i)
        site = sites[id] or raise "#{f}: site id #{id} out of range (#{sites.size} sites): hits and sites are from different builds"
        site.hits[workload] += count
      end
    end
  end

  def pct(part, whole)
    whole.zero? ? '0.0' : format('%.1f', 100.0 * part / whole)
  end

  def report(by_symbol, workloads, top, io: $stdout)
    sites = by_symbol.values.flat_map(&:sites)
    totals = ->(w) { sites.sum { |s| s.hits[w] } }
    all = ->(s) { workloads.sum { |w| s.hits[w] } }
    grand = sites.sum(&all)
    io.puts "-- workloads (executed by-name dispatch; counts are calls reaching the site, not guard hits) --"
    workloads.each do |w|
      ran = sites.count { |s| s.hits[w].positive? }
      io.puts format('%-14<w>s %14<h>d hits over %<r>d of %<n>d instrumented sites', w: w, h: totals.(w), r: ran, n: sites.size)
    end
    io.puts
    ranked = sites.select { |s| all.(s).positive? }.sort_by { |s| [-all.(s), s.symbol, s.line] }
    io.puts "-- TOP #{top} dynamic sites by executed hits (all workloads) --"
    io.puts format('%4s %13s %6s %6s  %-*s %-10s %-24s %-34s %s', '#', 'hits', 'share', 'cum', workloads.size * 14 - 1,
                   workloads.join(' '), 'symbol', 'method', 'category', 'site (fn @ generated line)')
    cum = 0
    ranked.first(top).each_with_index do |s, i|
      cum += all.(s)
      per = workloads.map { |w| format('%13d', s.hits[w]) }.join(' ')
      io.puts format('%4d %13d %5s%% %5s%%  %s %-10s %-24s %-34s %s @ %d', i + 1, all.(s), pct(all.(s), grand), pct(cum, grand), per,
                     s.symbol, "#{s.kind == 'bc2cpp_send' ? '' : "#{s.kind}:"}#{s.name}", s.category, s.fn, s.line)
      io.puts format('%s lever: %s', ' ' * 6, lever(s.category, s.name))
    end
    io.puts
    io.puts '-- executed hits by reason category --'
    by_cat = sites.group_by(&:category).transform_values { |v| [v.sum(&all), v.count { |s| all.(s).positive? }, v.size] }
    by_cat.sort_by { |c, (h, _)| [-h, c] }.each do |c, (h, ran, n)|
      io.puts format('%13d %5s%%  %4d/%-5d sites run  %-44s lever: %s', h, pct(h, grand), ran, n, c, lever(c))
    end
    io.puts
    io.puts '-- executed hits by method name (top 20) --'
    sites.group_by(&:name).transform_values { |v| v.sum(&all) }.sort_by { |n, h| [-h, n.to_s] }.first(20).each do |n, h|
      io.puts format('%13d %5s%%  %s', h, pct(h, grand), n)
    end
    ranked
  end

  def write_tsv(path, ranked, workloads)
    File.open(path, 'w') do |f|
      f.puts (%w[rank symbol kind name fn line category lever] + workloads).join("\t")
      ranked.each_with_index do |s, i|
        f.puts ([i + 1, s.symbol, s.kind, s.name, s.fn, s.line, s.category, lever(s.category, s.name)] + workloads.map { |w| s.hits[w] }).join("\t")
      end
    end
  end

  def main(argv)
    workloads = {}
    top = 30
    tsv = nil
    parser = OptionParser.new do |o|
      o.on('--workload NAME=DIR') do |v|
        name, dir = v.split('=', 2)
        abort '--workload wants NAME=HITS_DIR' unless dir
        workloads[name] = dir
      end
      o.on('--top N', Integer) { |v| top = v }
      o.on('--tsv FILE') { |v| tsv = v }
    end
    rest = parser.parse(argv)
    abort 'usage: --rank SITES_DIR --workload NAME=HITS_DIR [--workload ...] [--top N] [--tsv FILE]' if rest.size != 1 || workloads.empty?

    by_symbol = load_sites(rest.first)
    workloads.each { |w, d| add_hits(by_symbol, w, d) }
    ranked = report(by_symbol, workloads.keys, top)
    write_tsv(tsv, ranked, workloads.keys) if tsv
  rescue RuntimeError => e
    abort "bc2cpp_dynamic_site_census: #{e.message}"
  end
end
