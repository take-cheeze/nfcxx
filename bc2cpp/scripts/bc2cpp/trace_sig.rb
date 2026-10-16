#!/usr/bin/env ruby
# frozen_string_literal: true

# Writes RBS candidates from BC2CPP_TRACE_TYPES dumps (tools/bc2cpp/param_trace.rb): for each method whose
# parameters and returns were observed with one class (or that class and nil) in every run, a declaration
# with the observed types. Candidates only: the output is not loaded by bc2cpp, carries no
# `%a{bc2cpp:hint}`, and is not a proof -- a single run shows what happened, not what can happen.
# A parameter or return that was never reached is `untyped`.
#
#   ruby scripts/bc2cpp/trace_sig.rb [--out candidates.rbs] dump.txt [...]
#
# Reads the rows scripts/bc2cpp/param_trace_report.rb documents (PARAM_SITE/PARAM_CLASS, RETURN_SITE/RETURN_CLASS).
# A method is skipped when its owner is not a plain class name or its name is not a plain Ruby identifier.

OWNER_RE = /\A[A-Z]\w*(?:::[A-Z]\w*)*\z/
NAME_RE = /\A[a-z_]\w*[?!]?\z/
RBS_CLASS = { 'NilClass' => 'nil', 'TrueClass' => 'bool', 'FalseClass' => 'bool' }.freeze

# The RBS type of the observed classes: the union of what was seen (true and false both give `bool`).
def rbs_type(classes)
  return 'untyped' if classes.empty?

  classes.keys.map { |c| RBS_CLASS.fetch(c, c) }.uniq.sort.join(' | ')
end

# Merges the dumps by what a site is (method, parameter or return, name), not by the per-binary site id, so runs
# of one build add up and runs of different builds are compared on the same key. A site whose class table
# overflowed has classes nobody recorded, so it has no complete observed type.
def read_dumps(paths)
  params = {}   # [method, kind, index, name] => { calls:, overflow:, classes: Hash }
  rets = {}     # method => { calls:, overflow:, classes: Hash }
  paths.each do |path|
    ids = {}    # this dump's [sym, id] => key
    rid = {}    # this dump's [sym, id] => method
    File.foreach(path) do |raw|
      f = raw.chomp.split("\t", -1)
      case f[0]
      when 'PARAM_SITE'
        key = [f[5], f[8], f[9].to_i, f[10]]
        ids[[f[1], f[2].to_i]] = key
        site = params[key] ||= { calls: 0, overflow: 0, classes: Hash.new(0) }
        site[:calls] += f[3].to_i
        site[:overflow] += f[4].to_i
      when 'PARAM_CLASS'
        ids.fetch([f[1], f[2].to_i], nil)&.then { |key| params[key][:classes][f[3]] += f[4].to_i }
      when 'RETURN_SITE'
        rid[[f[1], f[2].to_i]] = f[5]
        site = rets[f[5]] ||= { calls: 0, overflow: 0, classes: Hash.new(0) }
        site[:calls] += f[3].to_i
        site[:overflow] += f[4].to_i
      when 'RETURN_CLASS'
        rid.fetch([f[1], f[2].to_i], nil)&.then { |method| rets[method][:classes][f[3]] += f[4].to_i }
      end
    end
  end
  [params, rets]
end

def candidates(params, rets)
  by_method = Hash.new { |h, k| h[k] = { params: {}, ret: Hash.new(0), ret_calls: 0 } }
  params.each do |(method, kind, index, name), p|
    next unless kind == 'req' && p[:calls].positive? && p[:overflow].zero?

    by_method[method][:params][index] = [name, p[:classes]]
  end
  rets.each do |method, r|
    # Ruby discards the value `initialize` returns, so no caller reads it.
    next if method.end_with?('#initialize')
    next unless r[:calls].positive? && r[:overflow].zero?

    m = by_method[method]
    r[:classes].each { |c, n| m[:ret][c] += n }
    m[:ret_calls] += r[:calls]
  end
  by_method.filter_map do |key, m|
    owner, name = key.split('#', 2)
    next unless owner && name && OWNER_RE.match?(owner) && NAME_RE.match?(name)
    next if m[:params].empty? && m[:ret_calls].zero?

    args = m[:params].sort.map { |_, (_, classes)| rbs_type(classes) }
    next if args.any?(&:nil?)

    ret = m[:ret].empty? ? 'untyped' : rbs_type(m[:ret])
    next if ret.nil?

    { owner: owner, name: name, args: args, ret: ret, calls: m[:ret_calls] }
  end
end

def render(cands)
  out = +"# Trace candidates (scripts/bc2cpp/trace_sig.rb). Not loaded by bc2cpp; review before any hint.\n"
  cands.group_by { |c| c[:owner] }.sort.each do |owner, list|
    out << "class #{owner}\n"
    list.sort_by { |c| c[:name] }.each do |c|
      ret = c[:ret].include?(' | ') ? "(#{c[:ret]})" : c[:ret] # RBS needs parentheses for a union return
      out << "  def #{c[:name]}: (#{c[:args].join(', ')}) -> #{ret}\n"
    end
    out << "end\n"
  end
  out
end

return unless $PROGRAM_NAME == __FILE__

out_path = nil
args = ARGV.dup
if args.first == '--out'
  args.shift
  out_path = args.shift
end
abort 'usage: trace_sig.rb [--out FILE] dump.txt [...]' if args.empty?

params, rets = read_dumps(args)
text = render(candidates(params, rets))
if out_path
  File.write(out_path, text)
  puts "wrote #{out_path}"
else
  print text
end
