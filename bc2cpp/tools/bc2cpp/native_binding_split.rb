# frozen_string_literal: true

require 'json'
require 'set'
require_relative 'native_direct'

# Classification of the RGSS native bindings (ADR 0263): which
# mrb_define_method / mrb_define_class_method / mrb_define_module_function
# registrations bind a function that can run without the caller's frame, and
# so can be split into a frame-independent `rgss::<function>_direct` entry
# point plus a thin binding that unpacks mrb_get_args.
#
# The facts come from scripts/native_binding_facts.py (libclang); everything
# here is plain Ruby over that JSON and the C++ source text, so the
# classification, the report, the source rewrite and the compiler's table are
# reproducible and testable without a compiler. The rule is fail closed: a
# binding is `splittable` only when every check below passes in every
# configuration that compiles it, and anything unproven is refused with a
# reason.
module NativeBindingSplit
  CONFIGS = %w[host wio psp maix emscripten].freeze
  CONFIG_DEFINES = {
    'host' => [], 'wio' => %w[WIO_TERMINAL], 'psp' => %w[PSP_BUILD], 'maix' => %w[MAIX_BUILD],
    'emscripten' => %w[__EMSCRIPTEN__]
  }.freeze

  # mrb_get_args format letter -> [C parameter types, Ruby argument kind].
  FORMATS = {
    'o' => [%w[mrb_value], :value], 'i' => [%w[mrb_int], :int], 'b' => [%w[mrb_bool], :bool],
    'f' => [%w[mrb_float], :float], 'n' => [%w[mrb_sym], :sym], 'S' => [%w[mrb_value], :string],
    'A' => [%w[mrb_value], :array], 'H' => [%w[mrb_value], :hash], 'z' => [['const char *'], :cstr],
    's' => [['const char *', 'mrb_int'], :str]
  }.freeze
  TYPE_ALIASES = { 'V' => 'mrb_value' }.freeze

  STATUS_ORDER = %i[forwarded delegated split splittable frame_free refused].freeze

  Verdict = Struct.new(:status, :reasons, :format, :params, :kinds, :function, :export_extent, keyword_init: true)

  # A registration seen in one or more configurations.
  Binding = Struct.new(:file, :line, :api, :name, :class_expr, :owner, :cfunc, :target_kind, :configs, :verdict,
                       :reg, :guard, :functions, keyword_init: true) do
    def label
      "#{owner || "?#{class_expr}"}#{api == 'mrb_define_method' ? '#' : '.'}#{name}"
    end
  end

  # ----------------------------------------------------------------------------
  # Source text: byte offsets, preprocessor context.
  # ----------------------------------------------------------------------------
  class Source
    attr_reader :path, :bytes

    def initialize(path, bytes = nil)
      @path = path
      @bytes = bytes || File.binread(path)
      @bytes.force_encoding(Encoding::BINARY)
    end

    def slice(extent)
      @bytes.byteslice(extent[0], extent[1] - extent[0])
    end

    # [[offset, condition-or-:complex-or-:endif]] for each directive that
    # opens, splits or closes a conditional, comments and continuation lines
    # handled.
    def directives
      @directives ||= scan_directives
    end

    # The clauses (C expressions) that must all hold at `offset`, or nil when a
    # `#elif` or an unparseable directive makes that unprovable.
    def guard_at(offset)
      stack = []
      directives.each do |pos, kind, cond|
        break if pos > offset

        case kind
        when :if then stack.push([cond])
        when :elif then stack.push(stack.pop.to_a + [:complex]) unless stack.empty?
        when :else then stack.push(stack.pop.to_a.then { |e| e.include?(:complex) ? e : [:else, e] }) unless stack.empty?
        when :endif then stack.pop
        end
      end
      clauses = []
      stack.each do |entry|
        return nil if entry.include?(:complex)

        clauses << (entry.first == :else ? negate(entry.last.first) : entry.first)
      end
      clauses
    end

    # true when a conditional directive lies inside the byte range.
    def conditional_inside?(extent)
      directives.any? { |pos, _kind, _cond| pos > extent[0] && pos < extent[1] }
    end

    def line_of(offset)
      @bytes.byteslice(0, offset).count("\n") + 1
    end

    private

    def negate(cond)
      "!(#{cond})"
    end

    def scan_directives
      out = []
      in_comment = false
      offset = 0
      lines = @bytes.split("\n", -1)
      i = 0
      while i < lines.size
        start = offset
        raw = lines[i]
        offset += raw.bytesize + 1
        text = raw
        while text.end_with?("\\") && i + 1 < lines.size
          i += 1
          offset += lines[i].bytesize + 1
          text = text.chomp("\\") + ' ' + lines[i]
        end
        i += 1
        code = text.dup
        if in_comment
          if (idx = code.index('*/'))
            code = ' ' * (idx + 2) + code[(idx + 2)..]
            in_comment = false
          else
            next
          end
        end
        code = code.gsub(%r{/\*.*?\*/}, ' ').gsub(%r{//.*}, '')
        if (idx = code.index('/*'))
          in_comment = true
          code = code[0...idx]
        end
        next unless code =~ /\A\s*#\s*(if|ifdef|ifndef|elif|else|endif)\b(.*)\z/m

        kind, rest = Regexp.last_match(1), Regexp.last_match(2).gsub(/\s+/, ' ').strip
        case kind
        when 'if' then out << [start, :if, rest]
        when 'ifdef' then out << [start, :if, "defined(#{rest})"]
        when 'ifndef' then out << [start, :if, "!defined(#{rest})"]
        when 'elif' then out << [start, :elif, rest]
        when 'else' then out << [start, :else, nil]
        when 'endif' then out << [start, :endif, nil]
        end
      end
      out
    end
  end

  # Evaluate a guard made only of defined(X), !, &&, ||, parentheses and 0/1
  # against a configuration's defines. nil when the expression uses anything
  # else (fail closed: the presence of the binding is then not modelled).
  module GuardEval
    module_function

    def eval(clause, defines)
      tokens = clause.scan(/defined\s*\(\s*\w+\s*\)|defined\s+\w+|&&|\|\||!|\(|\)|\d+|\S+/)
      pos = 0
      parse = nil
      primary = lambda do
        tok = tokens[pos]
        pos += 1
        case tok
        when nil then raise ArgumentError
        when '!' then !primary.call
        when '(' then parse.call.tap { raise ArgumentError unless tokens[pos] == ')'; pos += 1 }
        when /\Adefined\s*\(?\s*(\w+)\s*\)?\z/ then defines.include?(Regexp.last_match(1))
        when /\A\d+\z/ then tok != '0'
        else raise ArgumentError
        end
      end
      and_expr = lambda do
        value = primary.call
        while tokens[pos] == '&&'
          pos += 1
          rhs = primary.call
          value &&= rhs
        end
        value
      end
      parse = lambda do
        value = and_expr.call
        while tokens[pos] == '||'
          pos += 1
          rhs = and_expr.call
          value ||= rhs
        end
        value
      end
      result = parse.call
      raise ArgumentError unless pos == tokens.size

      result
    rescue ArgumentError
      nil
    end

    # Guard (array of clauses) evaluated for a configuration; nil = not modelled.
    def holds?(clauses, config)
      return nil if clauses.nil?

      defines = CONFIG_DEFINES.fetch(config)
      values = clauses.map { |c| eval(c, defines) }
      return nil if values.any?(&:nil?)

      values.all?
    end

    def expression(clauses)
      clauses.map { |c| clauses.size > 1 ? "(#{c})" : c }.join(' && ')
    end
  end

  # ----------------------------------------------------------------------------
  # Facts.
  # ----------------------------------------------------------------------------
  Facts = Struct.new(:by_config, :root)

  module_function

  def load_facts(paths, root)
    by_config = paths.transform_values { |path| JSON.parse(File.read(path)) }
    Facts.new(by_config, root)
  end

  def normalize_type(type)
    t = type.to_s.strip
    TYPE_ALIASES.fetch(t, t)
  end

  # The direct entry function name a binding's split gets.
  def direct_name(function)
    function.sub(/_native_body\z/, '') + '_direct'
  end

  # -- classification of one registration, in one configuration ---------------

  # Statements of a wrapper that unpacks mrb_get_args and forwards, or a pure
  # forwarder: [callee, callee-ns] when the shape is exactly
  #   T a; ...; mrb_get_args(M, "..", &a, ...); return callee(M, self, a, ...);
  def wrapper_call(target, fmt_info)
    call = target['ret_call']
    return nil unless call

    params = target['params']
    m, slf = params[0][1], params[1][1]
    stmts = target['stmts']
    gets = target['gets']
    vars = fmt_info ? fmt_info[:vars] : []
    return nil unless call['args'] == [m, slf, *vars]

    kinds = stmts.map { |s| s['kind'] }
    expected = Array.new(stmts.size - 1 - (gets.empty? ? 0 : 1)) { 'DECL_STMT' }
    expected << 'CALL_EXPR' unless gets.empty?
    expected << 'RETURN_STMT'
    kinds == expected ? call : nil
  end

  # Reasons a body cannot be split, in the order they are reported; first is
  # the primary reason.
  def reason_code(reason)
    reason.sub(/ \(via .*\)\z/, '')
  end

  def parse_format(format, targets)
    return [nil, [['get_args_format', 'not a string literal']]] unless format

    if (bad = format[/[^oibfnSAHzs]/])
      return [nil, [["get_args_format:#{bad}", "format #{format.inspect}"]]]
    end

    letters = format.chars
    want = letters.sum { |l| FORMATS.fetch(l)[0].size }
    return [nil, [['get_args_targets', "#{targets.size} targets for #{want}"]]] if targets.size != want || targets.any?(&:nil?)

    types = []
    kinds = []
    vars = []
    idx = 0
    reasons = []
    letters.each do |l|
      ctypes, kind = FORMATS.fetch(l)
      kinds << kind
      ctypes.each do |ct|
        t = targets[idx]
        vars << t['var']
        types << ct
        reasons << ['param_type', "#{t['var']}: #{t['type']} for #{l}"] if normalize_type(t['type']) != ct
        idx += 1
      end
    end
    [{ letters: letters, vars: vars, types: types, kinds: kinds, format: format }, reasons]
  end

  # Classify one target as seen by one configuration.
  # `source` is the Source of the file, `functions` the file's function facts
  # (name => [defs]), `exports` its rgss-namespace functions.
  def classify_target(reg, source, functions, exports)
    t = reg['target']
    refuse = ->(*reasons) { Verdict.new(status: :refused, reasons: reasons) }
    return refuse.call(['target_not_a_function', "#{t['kind']} #{t['name']}"]) unless %w[function lambda].include?(t['kind'])
    return refuse.call(['no_definition', t['name'].to_s]) if t['body_extent'].nil?
    return refuse.call(['dynamic_name', 'registered name is not a string literal']) unless reg['name']

    params = t['params']
    unless params.size == 2 && params[0][0] =~ /\Amrb_state\s*\*\z/ && normalize_type(params[1][0]) == 'mrb_value'
      return refuse.call(['signature', params.map(&:first).join(', ')])
    end

    gets = t['gets']
    reasons = []
    own_get_args = t['reasons'].count('frame_api:mrb_get_args')
    (t['reasons'] - ['frame_api:mrb_get_args']).each do |r|
      reasons << [reason_code(r), r] unless r.start_with?('frame_api:mrb_get_args (via')
    end
    reasons << ['get_args_multiple', "#{gets.size} calls"] if gets.size > 1
    reasons << ['get_args_in_callee', 'reached through a called function'] if t['reasons'].any? { |r| r.start_with?('frame_api:mrb_get_args (via') }
    reasons << ['goto', 'goto/label in the body'] if t['goto']
    reasons << ['ifdef_in_body', 'conditional compilation inside the function'] if source.conditional_inside?(t['extent'] || t['lambda_extent'])
    body_text = source.slice(t['body_extent'])
    reasons << ['function_name_used', '__func__'] if body_text.match?(/__func__|__FUNCTION__|__PRETTY_FUNCTION__/)

    fmt_info = nil
    if gets.size == 1
      g = gets.first
      fmt_info, more = parse_format(g['format'], g['targets'])
      reasons.concat(more)
      reasons << ['get_args_not_leading', 'mrb_get_args is not a plain top-level statement'] unless g['top_level']
      if fmt_info && g['top_level']
        idx = t['stmts'].index { |s| s['kind'] == 'CALL_EXPR' && s['extent'][0] == g['extent'][0] }
        before = idx ? t['stmts'][0...idx] : []
        declared = []
        bad_stmt = before.any? do |s|
          next true unless s['kind'] == 'DECL_STMT'

          names = s['vars'].map { |v| v['name'] }
          declared.concat(names)
          !(names - fmt_info[:vars]).empty?
        end
        reasons << ['statement_before_get_args', 'something other than the argument declarations precedes mrb_get_args'] if bad_stmt || idx.nil?
        reasons << ['get_args_targets', 'argument variable not declared just before the call'] if !bad_stmt && idx && declared.sort != fmt_info[:vars].sort
      end
    elsif gets.empty? && own_get_args.positive?
      reasons << ['get_args_not_leading', 'mrb_get_args reached only through callees']
    end

    shape = wrapper_call(t, fmt_info)
    kinds = fmt_info ? fmt_info[:kinds] : []
    if shape && reasons.empty?
      callee = shape['callee']
      if shape['ns'] == 'rgss' && callee.end_with?('_direct')
        return Verdict.new(status: :forwarded, reasons: [], format: fmt_info&.fetch(:format), params: typed_params(fmt_info),
                           kinds: kinds, function: callee)
      elsif callee.end_with?('_native_body')
        return Verdict.new(status: :split, reasons: [], format: fmt_info&.fetch(:format), params: typed_params(fmt_info),
                           kinds: kinds, function: direct_name(callee))
      end
    end

    return refuse.call(*reasons) unless reasons.empty?

    template = t['template']
    if gets.empty?
      delegate = t['usr'] && exports.find { |e| e['ret_call'] && e['ret_call']['usr'] == t['usr'] && e['params'].size == 2 && e['stmts'] == 1 }
      if delegate
        return Verdict.new(status: :delegated, reasons: [], format: nil, params: [], kinds: [], function: delegate['name'],
                           export_extent: delegate['extent'])
      end

      return refuse.call(['template_instance', "#{t['name']} is a function template specialization"]) if template

      return Verdict.new(status: :frame_free, reasons: [], format: nil, params: [], kinds: [], function: nil)
    end

    return refuse.call(['template_instance', "#{t['name']} is a function template specialization"]) if template

    Verdict.new(status: :splittable, reasons: [], format: fmt_info[:format], params: typed_params(fmt_info), kinds: kinds,
                function: nil)
  end

  def typed_params(fmt_info)
    return [] unless fmt_info

    fmt_info[:vars].zip(fmt_info[:types])
  end

  # -- all registrations across configurations --------------------------------

  def registration_key(file, reg)
    [file, reg['line'], reg['name']]
  end

  # Returns [bindings, problems]; a binding's verdict is refused with
  # config_disagreement when its configurations do not classify alike.
  def classify_all(facts, sources)
    table = {}
    facts.by_config.each do |config, data|
      data['files'].each do |file, fdata|
        fdata['registrations'].each do |reg|
          key = registration_key(file, reg)
          (table[key] ||= {})[config] = [reg, fdata]
        end
      end
    end
    problems = []
    facts.by_config.each do |config, data|
      data['files'].each do |file, fdata|
        next if fdata['errors'].empty? || fdata['registrations'].empty?

        problems << "#{config} #{file}: #{fdata['errors'].first}"
      end
    end

    owners_by_file = {}
    bindings = table.map do |key, per_config|
      file = key[0]
      source = sources.fetch(file)
      first_reg = per_config.values.first[0]
      verdicts = per_config.transform_values do |(reg, fdata)|
        classify_target(reg, source, fdata['functions'], fdata['exports'])
      end
      verdict = merge_verdicts(verdicts)
      owners = (owners_by_file[file] ||= NativeDirect.class_variables(NativeDirect.strip_comments(source.bytes.dup.force_encoding('UTF-8'))))
      owner = owners[first_reg['class_expr']]
      owner = "#{owner}.singleton" if owner && first_reg['kind'] != 'method'
      target = first_reg['target']
      Binding.new(file: file, line: first_reg['line'], api: first_reg['api'], name: first_reg['name'],
                  class_expr: first_reg['class_expr'], owner: owner, cfunc: target['name'], target_kind: target['kind'],
                  configs: per_config.keys, verdict: verdict, reg: first_reg, functions: per_config.values.first[1]['functions'],
                  guard: source.guard_at(first_reg['extent'][0]))
    end
    [bindings.sort_by { |b| [b.file, b.line, b.name.to_s] }, problems]
  end

  def merge_verdicts(verdicts)
    first = verdicts.values.first
    return first if verdicts.size == 1

    same = verdicts.values.all? do |v|
      v.status == first.status && v.function == first.function && v.format == first.format && v.params == first.params
    end
    return first if same

    reasons = verdicts.map { |cfg, v| ['config_disagreement', "#{cfg}: #{v.status}#{v.reasons.empty? ? '' : " (#{v.reasons.first.first})"}"] }
    Verdict.new(status: :refused, reasons: reasons)
  end

  # A registration's own conditional compilation must predict, for every
  # configuration, whether the facts saw it. A mismatch is a bug in the guard
  # model (returned as a problem); a guard the model cannot evaluate only
  # keeps that binding from being rewritten.
  def apply_presence(bindings, facts)
    problems = []
    bindings.each do |b|
      facts.by_config.each_key do |config|
        predicted = GuardEval.holds?(b.guard, config)
        observed = b.configs.include?(config)
        if predicted.nil?
          if %i[splittable frame_free].include?(b.verdict.status)
            b.verdict = Verdict.new(status: :refused, reasons: [['guard_not_modelled', "guard #{b.guard.inspect}"]])
          end
          break
        elsif predicted != observed
          problems << "#{b.label} (#{File.basename(b.file)}:#{b.line}): guard says #{predicted} for #{config}, facts say #{observed}"
        end
      end
    end
    problems
  end

  # -- reporting ----------------------------------------------------------------

  def report_lines(bindings)
    lines = []
    lines << format('%-34s %-26s %-8s %-40s %s', 'binding', 'function', 'format', 'typed params', 'verdict')
    bindings.each do |b|
      v = b.verdict
      fn = b.cfunc || (b.target_kind == 'lambda' ? '<lambda>' : '?')
      typed = v.params.to_a.map { |name, type| "#{type} #{name}" }.join(', ')
      outcome = case v.status
                when :refused then "refused: #{v.reasons.map(&:first).uniq.join(', ')}"
                when :splittable then b.owner ? 'splittable' : 'splittable (not applied: class owner unresolved)'
                when :frame_free then b.owner ? 'frame-free (forwarder only)' : 'frame-free (not applied: class owner unresolved)'
                else "#{v.status} -> rgss::#{v.function}"
                end
      lines << format('%-34s %-26s %-8s %-40s %s', "#{b.label} (#{File.basename(b.file)}:#{b.line})", fn, v.format.to_s, typed, outcome)
    end
    lines
  end

  def summary(bindings)
    counts = Hash.new(0)
    bindings.each { |b| counts[b.verdict.status] += 1 }
    refusals = Hash.new(0)
    any = Hash.new(0)
    bindings.select { |b| b.verdict.status == :refused }.each do |b|
      refusals[b.verdict.reasons.first.first] += 1
      b.verdict.reasons.map(&:first).uniq.each { |r| any[r] += 1 }
    end
    [counts, refusals, any]
  end
end
