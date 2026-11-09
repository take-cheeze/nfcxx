#!/usr/bin/env ruby
# frozen_string_literal: true

# Aggregate BC2CPP_NATIVE_ARMS_REPORT: how many by-name sites a
# per-class native arm could remove, lever by lever, and which native entries would be missing.
#
#   BC2CPP_NATIVE_ARMS_REPORT=arms.tsv MRBC=<host mrbc> ruby scripts/bc2cpp/coverage_report.rb > /dev/null
#   ruby scripts/bc2cpp/native_arms_report.rb arms.tsv [owner-regexp]
#
# Levers: (a) a def or alias inside `class << <Const>` installs on a class object,
# (b) native and outside definers are resolved per class, (c) the listed classes are checked against the proven set S.
# A lever only counts when S is bounded; an unproven receiver is not touched by any of them.

path = ARGV.fetch(0) { abort 'usage: bc2cpp_native_arms_report.rb arms.tsv [owner-regexp]' }
scope = Regexp.new(ARGV[1] || '.')
COLUMNS = %w[irep idx gem fn name argc op byname else kept src set kinds cells gates levers family].freeze
rows = File.readlines(path, chomp: true).reject(&:empty?).map { |l| COLUMNS.zip(l.split("\t", -1)).to_h }
engine = %w[mruby-rpg2k mruby-lcf mruby-rgss]
rows.select! { |r| engine.include?(r['gem']) && r['fn'].match?(scope) }

# Names whose every installer (alias_method, alias, define_method, ...) sits inside a `class << Const` body.
class_object_only = {}
installs_path = "#{path}.installs"
if File.exist?(installs_path)
  File.readlines(installs_path, chomp: true).each do |line|
    name, sites = line.split("\t", 2)
    scoped = sites.to_s.split(';').map do |site|
      file, lineno = site.split(/:(?=\d+\z)/)
      next false unless file && File.exist?(file)

      src = File.readlines(file, chomp: true)
      i = lineno.to_i - 1
      indent = src[i][/\A */].size
      j = i - 1
      j -= 1 while j >= 0 && (src[j].strip.empty? || src[j][/\A */].size >= indent)
      j >= 0 && src[j].match?(/\Aclass\s*<<\s*[A-Z]\w*/) || (j >= 0 && src[j].strip.match?(/\Aclass\s*<<\s*[A-Z]\w*/))
    end
    class_object_only[name] = !scoped.empty? && scoped.all?
  end
end

def table(title, pairs, limit = nil)
  puts "-- #{title} --"
  pairs = pairs.sort_by { |k, n| [-n, k.to_s] }
  (limit ? pairs.first(limit) : pairs).each { |k, n| puts format('%6d  %s', n, Array(k).join(' | ')) }
  puts
end

SEND_CELLS = %w[native_direct_guarded native_core_direct_guarded native_noentry inherited_native_noentry foreign_ruby ruby_not_direct unknown_lookup method_missing unbounded].freeze
cells_of = ->(r) { r['cells'] == '-' ? [] : r['cells'].split('|').map { |c| c.split('=', 2) } }
cell_ok = lambda do |r|
  cells_of.(r).all? { |_k, c| !SEND_CELLS.include?(c) && c != 'classobj' }
end
bad_cells = ->(r) { cells_of.(r).reject { |_k, c| %w[error ruby_direct native_direct native_core_direct].include?(c) || c.start_with?('accessor:') } }

puts "#{rows.size} by-name sites in the engine gems (owners #{scope.source})"
table('else arm', rows.map { |r| r['else'] }.tally)
table('receiver set source x else', rows.map { |r| [r['src'], r['else'] == 'nomethod' ? 'nomethod (by-name ARM, no else to remove)' : (r['kept'] == '-' ? 'no chain/else kept' : 'kept else')] }.tally)

kept = rows.select { |r| r['kept'] != '-' || r['else'] == 'send' }
bare = rows.select { |r| r['kept'] == '-' && r['else'] == 'send' }
puts "dispatching else arms (kept marker or bare send): #{kept.size}; of which bare sends with no marker: #{bare.size}"
bounded = ->(r) { %w[proven facts].include?(r['src']) && r['set'] != '-' }
puts "  receiver set bounded (proven or CALL_FACTS, any members): #{kept.count(&bounded)}; unbounded: #{kept.count { |r| !bounded.(r) }}"
puts

table('bounded dispatching sites by set source x member kinds x shape',
      kept.select(&bounded).map { |r| [r['src'], r['kinds'], r['kept'] == '-' ? 'bare send' : 'kept else'] }.tally)

puts '== lever model over the bounded dispatching sites'
cand = kept.select(&bounded)
hard = lambda do |r|
  g = r['gates'].split(',')
  l = r['levers'].split(',')
  out = []
  out << 'opaque' if l.any? { |x| x.start_with?('opaque:') } || g.include?('opaque_definer') || g.include?('opaque_subclass')
  out << 'method_missing' if g.include?('method_missing_receiver')
  out << 'classobj_member' if cells_of.(r).any? { |_k, c| c == 'classobj' }
  out
end
# Gates left after the levers in +set+ (a, b, c); a bounded site is removable when none is left, no hard blocker
# holds and every cell of S is direct (an error, a Ruby body, an audited native entry or an ivar accessor).
remaining = lambda do |r, set|
  left = r['gates'].split(',') - %w[singleton_definer]
  left += %w[unbounded_name] if r['levers'].split(',').include?('unbounded_name') && !left.include?('dynamic_install')
  left -= %w[dynamic_install unknown_definer unbounded_name] if set.include?(:a) && class_object_only[r['name']]
  left -= %w[core_or_native] if set.include?(:b) && cell_ok.(r) && !r['levers'].split(',').include?('perclass_blocked')
  left -= %w[unlisted_class] if set.include?(:c) && !r['levers'].split(',').include?('unlisted_scoped')
  left
end
removable = ->(r, set) { hard.(r).empty? && remaining.(r, set).empty? && cell_ok.(r) }
combos = {
  'today (no lever)' => [],
  '(a) singleton-scoped definers only' => [:a],
  '(b) per-class native only' => [:b],
  '(c) cell check against S only' => [:c],
  '(a)+(b)' => %i[a b],
  '(b)+(c)' => %i[b c],
  '(a)+(c)' => %i[a c],
  '(a)+(b)+(c)' => %i[a b c]
}
['kept else', 'bare send'].each do |shape|
  group = cand.select { |r| (r['kept'] == '-' ? 'bare send' : 'kept else') == shape }
  puts "shape: #{shape} (#{group.size} bounded sites; hard blockers: #{group.count { |r| !hard.(r).empty? }})"
  combos.each do |label, set|
    ok = group.select { |r| removable.(r, set) }
    puts format('  %-38s %4d sites removed (%d by-name lines)', label, ok.size, ok.sum { |r| r['byname'].to_i })
  end
  puts
end

all_levers = cand.select { |r| removable.(r, %i[a b c]) }
puts "== realistic yield: bounded, no hard blocker, every gate lifted, every cell direct: #{all_levers.size} sites"
table('by shape', all_levers.map { |r| r['kept'] == '-' ? 'bare send (needs a new chain)' : 'kept else' }.tally)
table('by name x set', all_levers.map { |r| [r['name'], r['set']] }.tally, 25)

blocked_cells = cand.select { |r| hard.(r).empty? && !cell_ok.(r) }
puts "== gated by a cell that is a send (native with no frame-independent entry, or a Ruby body not direct-callable): #{blocked_cells.size}"
need = Hash.new { |h, k| h[k] = [] }
blocked_cells.each { |r| bad_cells.(r).each { |k, c| need["#{k}##{r['name']}/#{r['argc']} (#{c})"] << r } }
table('missing cells (class#name/arity) -> sites it gates, all bounded dispatching sites', need.transform_values(&:size), 40)
need_kept = Hash.new(0)
blocked_cells.select { |r| r['kept'] != '-' }.each { |r| bad_cells.(r).each { |k, c| need_kept["#{k}##{r['name']}/#{r['argc']} (#{c})"] += 1 } }
table('missing cells over the KEPT-ELSE sites only', need_kept, 40)

puts '== hard blockers over bounded dispatching sites'
table('blocker', cand.flat_map { |r| hard.(r) }.tally)
table('gates over bounded dispatching sites (a site counts once per gate)', cand.flat_map { |r| r['gates'].split(',') }.tally)
table('names of bounded dispatching sites', cand.map { |r| [r['name'], r['kept']] }.tally, 30)
puts "names installed only inside class << Const: #{class_object_only.select { |_k, v| v }.keys.sort.join(' ')}"
puts "names installed elsewhere too: #{class_object_only.reject { |_k, v| v }.keys.sort.first(40).join(' ')}"
