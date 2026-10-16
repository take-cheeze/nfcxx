#!/usr/bin/env ruby
# frozen_string_literal: true

# Joins the BC2CPP_TRACE_PARAMS=1 dumps (tools/bc2cpp/param_trace.rb) with the static facts bc2cpp proved
# for each parameter (carried in every dump row) and, optionally, with BC2CPP_TRACE_ELSE=1 dumps
# (tools/bc2cpp/else_trace.rb), to answer three questions:
#
#   (a) which parameters were monomorphic at run time but have no static fact (annotation / speculation
#       candidates);
#   (b) which parameters have a static fact the run contradicts (a soundness bug in the analysis);
#   (c) which parameters feed the unresolved by-name sends of the else-arm trace (ELSE_SITE rows whose
#       origin is `parameter`), ranked by else-arm hits.
#
#   BC2CPP_TRACE_PARAMS=1 BC2CPP_TRACE_ELSE=1 (at bc2cpp time), then run the binary with
#   BC2CPP_TRACE_PARAMS_OUT=params.txt BC2CPP_TRACE_ELSE_OUT=else.txt
#   ruby scripts/bc2cpp/param_trace_report.rb [--top N] [--else else.txt ...] params.txt [...]
#
# Param dump rows (tab separated; a binary may append several, counts are summed):
#   PARAM_TRACE_SYMBOL sym fns N params N params_hit N entries N untraced_methods N inlined_blocks_not_traced 1
#   PARAM_FN    sym fnid entries method fn method|block
#   PARAM_SITE  sym id calls overflow method fn method|block kind index name static
#   PARAM_CLASS sym id class count
#   RETURN_SITE sym id calls overflow method fn method|block kind=return ordinal static(ret=...)
#   RETURN_CLASS sym id class count
# static: comma-separated `kind=value` facts (argtypes, classarg, entryfix, numeric, pool, annot) or
# `none:mono` (single definition, nothing proved) / `none:poly(N)` / `none:non_mandatory` / `none:block` /
# `none:keyword`.
#
# Inlined blocks (each/map/times loops compiled into their caller) are not traced.

require 'optparse'

options = { top: 20, else_files: [] }
OptionParser.new do |o|
  o.banner = 'usage: bc2cpp_param_trace_report.rb [--top N] [--else DUMP]... PARAM_DUMP...'
  o.on('--top N', Integer, 'rows per ranking (default 20)') { |n| options[:top] = n }
  o.on('--else FILE', 'ELSE_TRACE dump (repeatable)') { |f| options[:else_files] << f }
end.parse!
abort 'no param dump files given' if ARGV.empty?

# Runtime class names that each mask token / fact value allows.
TOKEN_CLASS = { 'INT' => 'Integer', 'FLT' => 'Float', 'ARR' => 'Array', 'HSH' => 'Hash', 'STR' => 'String',
                'NIL' => 'NilClass', 'RNG' => 'Range' }.freeze
SCALAR_CLASS = { 'fixnum' => 'Integer', 'symbol' => 'Symbol', 'bool' => nil }.freeze

# The set of classes a fact allows, or nil when it carries no usable restriction.
def allowed_classes(fact)
  kind, value = fact.split('=', 2)
  case kind
  when 'argtypes', 'annot' then (c = SCALAR_CLASS[value]) ? [c] : nil
  when 'entryfix' then ['Integer']
  when 'classarg' then [value]
  when 'numeric', 'pool'
    tokens = value.split('|')
    return nil if tokens.any? { |t| %w[OTHER CHECKED NONE].include?(t) }

    tokens.map { |t| TOKEN_CLASS[t] || t }
  end
end

params = {}  # [sym, fn, name] => {...}
rets = {}    # [sym, return id] => {...}
symbols = {}
fn_entries = Hash.new(0)
ids = {}     # [sym, id] => key

ARGV.each do |path|
  File.foreach(path) do |raw|
    f = raw.chomp.split("\t", -1)
    case f[0]
    when 'PARAM_TRACE_SYMBOL'
      symbols[f[1]] = { fns: f[3].to_i, params: f[5].to_i, untraced_methods: f[11].to_i }
    when 'PARAM_FN'
      fn_entries[[f[1], f[5]]] += f[3].to_i
    when 'PARAM_SITE'
      sym, id = f[1], f[2].to_i
      key = [sym, f[6], f[10]]
      ids[[sym, id]] = key
      p = params[key] ||= { calls: 0, overflow: 0, classes: Hash.new(0) }
      p[:calls] += f[3].to_i
      p[:overflow] += f[4].to_i
      p.merge!(method: f[5], fn: f[6], scope: f[7], kind: f[8], index: f[9].to_i, name: f[10], static: f[11])
    when 'PARAM_CLASS'
      key = ids[[f[1], f[2].to_i]] or next
      params[key][:classes][f[3]] += f[4].to_i
    when 'RETURN_SITE'
      # [sym, id] => { calls:, overflow:, classes:, static:, label: } for each traced `return` statement.
      rets[[f[1], f[2].to_i]] = { calls: f[3].to_i, overflow: f[4].to_i, classes: Hash.new(0),
                                  method: f[5], fn: f[6], static: f[11] }
    when 'RETURN_CLASS'
      rets[[f[1], f[2].to_i]] or next
      rets[[f[1], f[2].to_i]][:classes][f[3]] += f[4].to_i
    end
  end
end

# Else-arm hits per feeding parameter.
else_by_param = Hash.new { |h, k| h[k] = { hits: 0, may_hits: 0, sites: [] } }
else_total = 0
options[:else_files].each do |path|
  File.foreach(path) do |raw|
    f = raw.chomp.split("\t", -1)
    next unless f[0] == 'ELSE_SITE'

    else_total += f[3].to_i
    next unless %w[parameter join].include?(f[10])

    param = f[12]
    if param.nil? || param == '-'
      else_by_param[:unresolved][:hits] += f[3].to_i
      next
    end
    exact = !param.start_with?('~')
    param.delete_prefix('~').split('|').each do |name|
      e = else_by_param[[f[1], f[6], name]]
      e[exact ? :hits : :may_hits] += f[3].to_i
      e[:sites] << "#{f[7]} on #{f[11]} #{f[8]}#{exact ? '' : ' (join: may hold this parameter)'}"
    end
  end
end

def facts(p)
  p[:static].start_with?('none') ? [] : p[:static].split(',')
end

def label(p)
  name = p[:name].sub(/\Abc2cpp_kwarg_/, 'kw:')
  "#{p[:method]} #{p[:kind]}#{p[:index].positive? ? p[:index] : ''} #{name}"
end

def histogram(p)
  s = p[:classes].sort_by { |c, n| [-n, c] }.map { |c, n| "#{c} #{n}" }.join(', ')
  p[:overflow].positive? ? "#{s}, +#{p[:overflow]} calls in further classes" : s
end

hit = params.values.select { |p| p[:calls].positive? }
mono = hit.select { |p| p[:classes].size == 1 && p[:overflow].zero? }
mono_or_nil = hit.select do |p|
  p[:classes].size == 2 && p[:classes].key?('NilClass') && p[:overflow].zero?
end
proven = ->(p) { !facts(p).empty? }

contradictions = []
hit.each do |p|
  facts(p).each do |fact|
    allowed = allowed_classes(fact)
    next unless allowed

    # A static class name may be unqualified (`Rect` for RGSS::Rect): match on the trailing path too.
    bad = p[:classes].reject { |c, _| allowed.any? { |a| a == c || c.end_with?("::#{a}") } }
    contradictions << [p, fact, bad] unless bad.empty?
    break unless bad.empty?
  end
end

puts "symbols traced: #{symbols.keys.join(', ')}"
puts "parameters instrumented: #{params.size}  (methods and blocks with their own impl; inlined blocks are not traced)"
puts "function entries counted: #{fn_entries.values.sum}"
puts "parameters reached at run time: #{hit.size}  (never reached: #{params.size - hit.size})"
puts "  statically proven (any fact): #{hit.count(&proven)}"
puts "  monomorphic at run time: #{mono.size}  (proven #{mono.count(&proven)}, UNPROVEN #{mono.count { |p| !proven.call(p) }})"
puts "  one class plus nil: #{mono_or_nil.size}  (proven #{mono_or_nil.count(&proven)}, unproven #{mono_or_nil.count { |p| !proven.call(p) }})"
puts "  polymorphic (3+ classes or more than the table holds): #{hit.size - mono.size - mono_or_nil.size - hit.count { |p| p[:classes].size == 2 && !p[:classes].key?('NilClass') && p[:overflow].zero? }}  (two non-nil classes: #{hit.count { |p| p[:classes].size == 2 && !p[:classes].key?('NilClass') && p[:overflow].zero? }})"
by_scope = mono.reject(&proven).group_by { |p| p[:scope] == 'block' ? 'block' : p[:kind] }.transform_values(&:size)
puts "  unproven monomorphic by kind: #{by_scope.sort.map { |k, v| "#{k} #{v}" }.join(', ')}"
by_static = mono.reject(&proven).group_by { |p| p[:static] }.transform_values(&:size)
puts "  unproven monomorphic by reason: #{by_static.sort.map { |k, v| "#{k} #{v}" }.join(', ')}"
puts ''

puts "== (b) static fact contradicted by run time: #{contradictions.size} =="
contradictions.each do |p, fact, bad|
  puts "  CONTRADICTION #{label(p)} [#{p[:fn]}]  fact #{fact}  observed #{histogram(p)}  (outside the fact: #{bad.map(&:first).join(', ')})"
end
puts '  (none)' if contradictions.empty?
puts ''

puts "== (a) monomorphic at run time, no static fact (top #{options[:top]} by calls) =="
cands = mono.reject(&proven).sort_by { |p| [-p[:calls], p[:method], p[:index]] }
cands.first(options[:top]).each_with_index do |p, i|
  puts format('%3d. %10d  %-70s %s  [%s]', i + 1, p[:calls], label(p), p[:classes].keys.first, p[:static])
end
puts ''

returns = rets.values.select { |r| r[:calls].positive? }
ret_facts = returns.select { |r| r[:static].start_with?('ret=') && r[:static] != 'ret=none' }
ret_contradictions = returns.filter_map do |r|
  allowed = case r[:static]
            when 'ret=fixnum' then ['Integer']
            when 'ret=array' then ['Array']
            when /\Aret=class=(.+)\z/ then [Regexp.last_match(1)]
            end
  next unless allowed

  bad = r[:classes].reject { |c, _| allowed.any? { |a| a == c || c.end_with?("::#{a}") } }
  [r, bad] unless bad.empty?
end
puts "== (d) returns: #{rets.size} traced, #{returns.size} reached at run time, #{ret_facts.size} with a static return fact =="
ret_contradictions.each do |r, bad|
  puts "  CONTRADICTION #{r[:method]} [#{r[:fn]}] return #{r[:static]}  observed #{r[:classes].sort_by { |c, n| [-n, c] }.map { |c, n| "#{c} #{n}" }.join(', ')}  (outside the fact: #{bad.map(&:first).join(', ')})"
end
puts '  (none)' if ret_contradictions.empty?
puts ''

unless options[:else_files].empty?
  resolved = else_by_param.reject { |k, _| k == :unresolved }
  total = ->(e) { e[:hits] + e[:may_hits] }
  puts "== (c) parameters feeding unresolved by-name sends (else-arm hits #{else_total} total; " \
       "#{else_by_param[:unresolved][:hits]} reach no parameter) =="
  puts '   "exact" = the receiver register is a plain copy of the parameter; "may" = a control-flow join, some path'
  puts '   copies the parameter (a hit counts once per candidate parameter, so the column sum can exceed the total).'
  ranked = resolved.sort_by { |(key), e| [-total.call(e), key.to_s] }
  ranked.first(options[:top]).each_with_index do |(key, e), i|
    p = params[key]
    sym, fn, name = key
    if p
      state = proven.call(p) ? 'PROVEN' : 'unproven'
      puts format('%3d. %9d else hits (exact %d, may %d)  %s  [%s, static: %s]', i + 1, total.call(e), e[:hits], e[:may_hits], label(p), state, p[:static])
      puts "       runtime (#{p[:calls]} calls): #{histogram(p)}"
    else
      puts format('%3d. %9d else hits (exact %d, may %d)  %s %s (%s): parameter not traced (function not instrumented)', i + 1, total.call(e), e[:hits], e[:may_hits], fn, name, sym)
    end
    e[:sites].tally.sort_by { |_, n| -n }.first(4).each { |s, n| puts "       send #{s}#{n > 1 ? " x#{n}" : ''}" }
  end
  traced = resolved.select { |key, _| params[key] }
  unproven_hits = traced.sum { |key, e| proven.call(params[key]) ? 0 : total.call(e) }
  mono_unproven_hits = traced.sum { |key, e| (p = params[key]) && mono.include?(p) && !proven.call(p) ? total.call(e) : 0 }
  puts ''
  puts "feeding parameters: #{resolved.size} (traced #{traced.size}); hits through unproven ones: #{unproven_hits} " \
       "(monomorphic at run time: #{mono_unproven_hits})"
end
