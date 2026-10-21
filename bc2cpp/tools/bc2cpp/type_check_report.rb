# frozen_string_literal: true

require 'json'
require 'set'
require_relative 'receiver_proof_report_columns'
require_relative 'type_check_rbs'

# TYPE_CHECK (docs/adr/0412): turns the facts bc2cpp wrote (type_facts.rb) and, optionally, the receiver-proof rows
# (BC2CPP_RECEIVER_PROOF_REPORT, ADR 0331) into the three outputs of scripts/bc2cpp/type_check.rb:
#
#   text         a stable summary plus `file:line:col: severity: message [CODE]` diagnostics (what `tsc` and `ruby -c`
#                print, so an editor's problem matcher reads them);
#   json         every row, every diagnostic and the ranked suggestions;
#   tsv          one row per method parameter / return / ivar / constant, for a spreadsheet or `sort | uniq -c`.
#
# Diagnostic codes (the number never changes meaning):
#   TC1001 error    a declared type (signature or `# bc2cpp:` annotation) disagrees with the inferred one
#   TC1002 error    a signature file the loader could not use (unsupported syntax, parse error)
#   TC1003 warning  a signature names a method / ivar the program does not define
#   TC1004 warning  an annotation token bc2cpp ignores, or an annotation whose parameter count is not the method's
#   TC1007 error    an inferred IR may-set is disjoint from a nominal RBS return/ivar contract
#   TC1008 warning  an inferred IR may-set partly overlaps the contract
#   TC1016 error    an RBS `class C < S` whose S is not the program's superclass of C (ADR 0453)
#   TC2004 info     (--all) an IR query is unknown, with its refusal reason
#   TC2001 info     (--all) a parameter has no type, with the reason bucket
#   TC2002 info     (--all) a return has no type, with the reason bucket
#   TC2003 info     (--all) an ivar has no type, with the reason bucket
#   TC3001 info     a signature on this declaration would remove N by-name sends (ranked)
# Only errors make the exit status non-zero.
module TypeCheckReport
  Diagnostic = Struct.new(:file, :line, :col, :severity, :code, :message, keyword_init: true) do
    def to_s
      "#{file}:#{line}:#{col}: #{severity}: #{message} [#{code}]"
    end

    def to_h
      { 'file' => file, 'line' => line, 'col' => col, 'severity' => severity, 'code' => code, 'message' => message }
    end
  end

  # Signature-addressable sources of the receiver-proof report: the rest (merge, literal, upvar, self, other, element)
  # have no declaration a signature could attach to.
  ADDRESSABLE = %w[argument ivar call const].freeze

  module_function

  def load_rows(path)
    return [] unless path && File.exist?(path)

    cols = ReceiverProofReport::COLUMNS
    File.readlines(path, chomp: true).reject(&:empty?).map { |l| cols.zip(l.split("\t", -1)).to_h }
  end

  def reason_bucket(reason)
    return '(none)' if reason.nil? || reason.empty?

    head = reason.split(':', 2).first
    head
  end

  # ---------------------------------------------------------------------------------------------- suggestions

  # Ranked declarations whose signature would remove by-name sends. A row is one send with a by-name line; its
  # `before` is the by-name lines of the site, `floor_after` the lines left when the receiver is forced to every class
  # that answers the name (so zero means a signature naming ANY answering class removes it), `after` the lines left
  # with the source's own class set. Without --what-if both are `-` and only the as-compiled count is known.
  def suggestions(facts, rows, scope: 'engine')
    methods = facts['methods'].select { |m| scope == 'all' || m['scope'] == scope }
    by_def = methods.group_by { |m| [m['owner'], m['name']] }
    by_name = methods.group_by { |m| m['name'] }
    ivar_at = facts['ivars'].to_h { |i| [[i['owner'], i['name']], i] }
    const_at = facts['constants'].to_h { |c| [c['name'], c] }
    groups = Hash.new { |h, k| h[k] = { sites: [], lines: 0, floor: 0, hyp: 0, known_floor: false, known_hyp: false } }
    rows.each do |r|
      next unless ADDRESSABLE.include?(r['source'])
      next if r['existing'] != '-' # the flow already proves the receiver

      before = r['before'].to_i
      next unless before.positive?

      target = suggestion_target(r, by_def, by_name, ivar_at, const_at)
      next unless target

      g = groups[target[:key]]
      g[:target] ||= target
      g[:sites] << r['where']
      g[:lines] += before
      g[:answerers] = [g[:answerers], r['answerers']].compact.reject { |a| a == '-' }.first
      if r['floor_after'] =~ /\A\d+\z/
        g[:known_floor] = true
        g[:floor] += [before - r['floor_after'].to_i, 0].max
      end
      if r['after'] =~ /\A\d+\z/ && r['hyp'] != '-'
        g[:known_hyp] = true
        g[:hyp] += [before - r['after'].to_i, 0].max
      end
    end
    groups.map do |key, g|
      t = g[:target]
      { 'target' => key, 'kind' => t[:kind], 'file' => t[:file], 'line' => t[:line], 'col' => t[:col],
        'sites' => g[:sites].size, 'by_name_lines' => g[:lines],
        'removable_at_floor' => g[:known_floor] ? g[:floor] : nil, 'removable_with_own_set' => g[:known_hyp] ? g[:hyp] : nil,
        'answerers' => g[:answerers], 'where' => g[:sites].uniq.first(5), 'sample' => t[:sample] }
    end.sort_by { |s| [-s['by_name_lines'], -s['sites'], s['target']] }
  end

  def suggestion_target(r, by_def, by_name, ivar_at, const_at)
    owner, meth = r['owner'].to_s.split('#', 2)
    case r['source']
    when 'argument'
      m = by_def[[owner, meth]]&.first or return nil
      k = r['detail'].to_s[/\Aarg(\d+)\z/, 1]&.to_i or return nil
      return nil if r['why'].to_s == 'no_candidate:block_param'

      p = m['params'][k - 1] or return nil
      return nil if p['type'] # already typed (declared or inferred elsewhere): the site is not blocked on this parameter

      { kind: 'param', key: "#{owner}##{meth} parameter #{k} (#{p['name']})", file: m['file'], line: m['line'], col: m['col'],
        sample: "#{owner}##{meth}(#{p['name']})" }
    when 'ivar'
      iv = "@#{r['detail'].to_s.delete_prefix('@')}"
      i = ivar_at[[owner, iv]] or return nil
      return nil if i['type']

      { kind: 'ivar', key: "#{owner}##{iv}", file: i['file'], line: i['line'], col: i['col'], sample: "#{owner}##{iv}" }
    when 'call'
      defs = by_name[r['detail']] or return nil
      return nil if defs.all? { |m| m['return']['type'] }

      first = defs.first
      { kind: 'return', key: "return of ##{r['detail']} (#{defs.size} definition#{'s' if defs.size > 1})",
        file: first['file'], line: first['line'], col: first['col'], sample: "##{r['detail']}" }
    when 'const'
      c = const_at[r['detail']] or return nil
      return nil if c['type']

      { kind: 'const', key: "constant #{r['detail']}", file: c['file'], line: c['line'], col: c['col'], sample: r['detail'] }
    end
  end

  # ---------------------------------------------------------------------------------------------- diagnostics

  def diagnostics(facts, suggestions, all: false, top: 20, scope: 'engine')
    out = []
    facts['contradictions'].each do |c|
      out << Diagnostic.new(file: c['file'], line: c['line'], col: c['col'], severity: 'error', code: 'TC1001',
                            message: "#{c['message']} (#{c['source']})")
    end
    facts['annotations'].each do |a|
      next unless a['file'] && a['line'].to_i.positive?

      a['ignored'].each do |tok|
        out << Diagnostic.new(file: a['file'], line: a['line'], col: a['col'], severity: 'error', code: 'TC1004',
                              message: "#{a['owner']}##{a['name']}: annotation token `#{tok}` is ignored (not a type bc2cpp reads, " \
                                       'or not a class the program defines)')
      end
      next unless a['arity_mismatch']

      out << Diagnostic.new(file: a['file'], line: a['line'], col: a['col'], severity: 'error', code: 'TC1004',
                            message: "#{a['owner']}##{a['name']}: annotation #{a['arity_mismatch']}")
    end
    Array(facts['nilable_index']).each do |n|
      out << Diagnostic.new(file: n['file'], line: n['line'], col: n['col'], severity: 'warning', code: 'TC1005',
                            message: "#{n['owner']}##{n['method']}: index `#{n['name']}` on a receiver that may be nil; " \
                                     'check it for nil first (ADR 0439)')
    end
    Array(facts['signature_diagnostics']).each do |d|
      out << Diagnostic.new(file: d['file'], line: d['line'], col: d['col'], severity: d['severity'], code: d['code'],
                            message: d['message'])
    end
    fc = filtered_collections(facts, scope)
    fc[:feedback].each do |row|
      if all && row['status'] == 'unknown'
        out << Diagnostic.new(file: row['file'], line: row['line'], col: row['col'], severity: 'info', code: 'TC2004',
                              message: "#{row['owner']}##{row['method']} #{row['kind']} #{row['detail']}: IR type unknown (#{row['reason']})")
      end
      next unless %w[mismatch possible_mismatch].include?(row['status'])
      possible = row['status'] == 'possible_mismatch'


      out << Diagnostic.new(file: row['file'], line: row['line'], col: row['col'], severity: possible ? 'warning' : 'error', code: possible ? 'TC1008' : 'TC1007',
                            message: "#{row['owner']}##{row['method']} #{row['kind'] == 'return' ? 'return' : row['detail']}: inferred #{row['type']} " \
                                     "#{possible ? 'may exceed' : 'falls outside'} RBS contract #{row['expected']}")
    end
    suggestions.first(top).each_with_index do |s, rank|
      next unless s['file']

      est = s['removable_at_floor'] ? "; up to #{s['removable_at_floor']} removable by a signature naming any answering class" : ''
      out << Diagnostic.new(file: s['file'], line: s['line'], col: s['col'], severity: 'info', code: 'TC3001',
                            message: "suggestion ##{rank + 1}: a signature for #{s['target']} would act on #{s['by_name_lines']} by-name send line(s) at " \
                                     "#{s['sites']} site(s)#{est}")
    end
    if all
      fc[:methods].each do |m|
        m['params'].each do |p|
          next if p['type']

          out << Diagnostic.new(file: m['file'], line: m['line'], col: m['col'], severity: 'info', code: 'TC2001',
                                message: "#{m['owner']}##{m['name']} parameter #{p['pos']} (#{p['name']}) has no type: #{p['reason']}")
        end
        next if m['return']['type']

        out << Diagnostic.new(file: m['file'], line: m['line'], col: m['col'], severity: 'info', code: 'TC2002',
                              message: "#{m['owner']}##{m['name']} return has no type: #{m['return']['reason']}")
      end
      fc[:ivars].each do |i|
        next if i['type']

        out << Diagnostic.new(file: i['file'] || '-', line: i['line'], col: i['col'], severity: 'info', code: 'TC2003',
                              message: "#{i['owner']}##{i['name']} has no type: #{i['reason']}")
      end
    end
    out.sort_by { |d| [d.severity == 'error' ? 0 : d.severity == 'warning' ? 1 : 2, d.file.to_s, d.line, d.col, d.code, d.message] }
  end

  # ---------------------------------------------------------------------------------------------- summary

  def tally(values)
    values.tally.sort_by { |k, v| [-v, k.to_s] }
  end

  def summary(facts, scope: 'engine')
    methods = facts['methods'].select { |m| scope == 'all' || m['scope'] == scope }
    ivars = facts['ivars'].select { |i| scope == 'all' || i['scope'] == scope }
    consts = facts['constants'].select { |c| scope == 'all' || c['scope'] == scope }
    params = methods.flat_map { |m| m['params'] }
    {
      'ir_feedback' => tally(Array(facts['ir_feedback']).select { |row| scope == 'all' || row['scope'] == scope }.map { |row| row['status'] }),
      'methods' => methods.size,
      'methods_with_params' => methods.count { |m| !m['params'].empty? },
      'params' => params.size, 'params_typed' => params.count { |p| p['type'] },
      'params_declared' => params.count { |p| p['type'] && %w[annotation signature].include?(p['source']) },
      'returns' => methods.size, 'returns_typed' => methods.count { |m| m['return']['type'] },
      'returns_declared' => methods.count { |m| m['return']['type'] && %w[annotation signature].include?(m['return']['source']) },
      'methods_fully_typed' => methods.count { |m| m['return']['type'] && m['params'].all? { |p| p['type'] } },
      'ivars' => ivars.size, 'ivars_typed' => ivars.count { |i| i['type'] },
      'ivars_with_element' => ivars.count { |i| i['element'] },
      'constants' => consts.size, 'constants_typed' => consts.count { |c| c['type'] },
      'annotations' => facts['annotations'].size, 'contradictions' => facts['contradictions'].size,
      'param_reasons' => tally(params.reject { |p| p['type'] }.map { |p| reason_bucket(p['reason']) }),
      'param_reasons_detail' => tally(params.reject { |p| p['type'] }.map { |p| p['reason'].to_s.sub(/\Adropped:.*/, 'dropped') }),
      'return_reasons' => tally(methods.reject { |m| m['return']['type'] }
                                       .flat_map { |m| m['return']['reason'].to_s.split('+').map { |r| reason_bucket(r) } }),
      'ivar_reasons' => tally(ivars.reject { |i| i['type'] }.map { |i| i['reason'].to_s }),
      'param_sources' => tally(params.select { |p| p['type'] }.map { |p| p['source'].to_s }),
      'return_sources' => tally(methods.select { |m| m['return']['type'] }.map { |m| m['return']['source'].to_s }),
      'ivar_sources' => tally(ivars.select { |i| i['type'] }.map { |i| i['source'].to_s })
    }
  end

  # 1 when a declared type contradicts the inference or a signature cannot be used; warnings and info never fail.
  def exit_status(diags)
    diags.any? { |d| d.severity == 'error' } ? 1 : 0
  end

  def pct(n, d)
    d.zero? ? '0.0%' : format('%.1f%%', 100.0 * n / d)
  end

  # ---------------------------------------------------------------------------------------------- renderers

  def text(facts, suggestions, diags, summary, top: 20, scope: 'engine', sends: true)
    s = summary
    out = +''
    diags.each { |d| out << d.to_s << "\n" }
    out << "\n" unless diags.empty?
    out << "bc2cpp type check (scope: #{scope})\n"
    out << format("  methods                 %6d  (%d with parameters)\n", s['methods'], s['methods_with_params'])
    out << format("  parameters typed        %6d of %6d  %s  (declared %d)\n", s['params_typed'], s['params'], pct(s['params_typed'], s['params']), s['params_declared'])
    out << format("  returns typed           %6d of %6d  %s  (declared %d)\n", s['returns_typed'], s['returns'], pct(s['returns_typed'], s['returns']), s['returns_declared'])
    out << format("  methods fully typed     %6d of %6d  %s\n", s['methods_fully_typed'], s['methods'], pct(s['methods_fully_typed'], s['methods']))
    out << format("  ivars typed             %6d of %6d  %s  (%d with an element class)\n", s['ivars_typed'], s['ivars'], pct(s['ivars_typed'], s['ivars']), s['ivars_with_element'])
    out << format("  constants typed         %6d of %6d\n", s['constants_typed'], s['constants'])
    out << format("  annotations / signatures %5d   contradictions %d\n", s['annotations'], s['contradictions'])
    unless Array(s['ir_feedback']).empty?
      out << "  IR feedback              #{s['ir_feedback'].map { |status, count| "#{status}=#{count}" }.join(' ')}\n"
    end
    out << "\n"
    section = lambda do |title, pairs, limit|
      out << "-- #{title} --\n"
      pairs.first(limit).each { |k, v| out << format("%6d  %s\n", v, k) }
      out << "       (none)\n" if pairs.empty?
      out << "\n"
    end
    section.call('typed parameters by source', s['param_sources'], 10)
    section.call('untyped parameters by reason', s['param_reasons'], 12)
    section.call('untyped parameters by detailed reason', s['param_reasons_detail'], 12)
    section.call('untyped returns by producer of the unresolved return sites', s['return_reasons'], 12)
    section.call('typed returns by source', s['return_sources'], 10)
    section.call('untyped ivars by reason (stage:ADR 0382 bucket)', s['ivar_reasons'], 14)
    feedback = Array(facts['ir_feedback']).select { |row| scope == 'all' || row['scope'] == scope }
    unless feedback.empty?
      section.call('IR queries left unknown by reason', tally(feedback.select { |row| row['status'] == 'unknown' }.map { |row| row['reason'] }), 12)
      out << "-- inferred RBS return suggestions (top #{top}) --\n"
      TypeCheckRbs.inferred_return_suggestions(facts, scope: scope).first(top).each do |row|
        out << "  #{row['owner']}##{row['method']} -> #{row['type']}\n"
      end
      out << "\n"
    end

    out << "-- signatures that would remove the most by-name sends (top #{top}) --\n"
    if suggestions.empty?
      out << (sends ? "       (none)\n" : "       (not collected: run without --no-sends)\n")
    else
      suggestions.first(top).each_with_index do |g, i|
        est = g['removable_at_floor'] ? "  removable<=#{g['removable_at_floor']}" : ''
        loc = g['file'] ? "  #{g['file']}:#{g['line']}" : ''
        out << format("%3d. %5d lines %4d sites%s  %s%s\n", i + 1, g['by_name_lines'], g['sites'], est, g['target'], loc)
      end
    end
    out
  end

  def tsv(facts, scope: 'engine')
    rows = [%w[kind owner name slot type source reason file line col].join("\t")]
    facts['methods'].each do |m|
      next unless scope == 'all' || m['scope'] == scope

      m['params'].each do |p|
        rows << ['param', m['owner'], m['name'], p['name'], p['type'], p['source'], p['reason'], m['file'], m['line'], m['col']].join("\t")
      end
      r = m['return']
      rows << ['return', m['owner'], m['name'], 'return', r['type'], r['source'], r['reason'], m['file'], m['line'], m['col']].join("\t")
    end
    facts['ivars'].each do |i|
      next unless scope == 'all' || i['scope'] == scope

      type = [i['type'], i['element']].compact.join(' ')
      rows << ['ivar', i['owner'], i['name'], '', type, i['source'], i['reason'], i['file'], i['line'], i['col']].join("\t")
    end
    facts['constants'].each do |c|
      next unless scope == 'all' || c['scope'] == scope

      rows << ['const', '', c['name'], '', c['type'], c['source'], '', c['file'], c['line'], c['col']].join("\t")
    end
    rows.join("\n") << "\n"
  end

  def filtered_collections(facts, scope)
    @filtered_collections ||= {}
    @filtered_collections[[facts.object_id, scope]] ||= {
      methods: facts['methods'].select { |m| scope == 'all' || m['scope'] == scope },
      ivars: facts['ivars'].select { |i| scope == 'all' || i['scope'] == scope },
      constants: facts['constants'].select { |c| scope == 'all' || c['scope'] == scope },
      feedback: Array(facts['ir_feedback']).select { |row| scope == 'all' || row['scope'] == scope }
    }
  end

  def json(facts, suggestions, diags, summary, scope: 'engine')
    fc = filtered_collections(facts, scope)
    JSON.pretty_generate({ 'version' => facts['version'], 'scope' => scope, 'summary' => summary, 'diagnostics' => diags.map(&:to_h),
                           'suggestions' => suggestions, 'methods' => fc[:methods], 'ivars' => fc[:ivars],
                           'constants' => facts['constants'], 'annotations' => facts['annotations'],
                           'native_direct_forms' => Array(facts['native_direct_forms']),
                           'rbs_suggestions' => TypeCheckRbs.inferred_return_suggestions(facts, scope: scope),
                           'ir_feedback' => fc[:feedback] }) << "\n"
  end
end
