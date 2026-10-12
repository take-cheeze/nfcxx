# frozen_string_literal: true

require 'json'
require 'set'
require_relative 'annotations'

# TYPE_CHECK (docs/adr/0412): the types bc2cpp's whole-program inference settled on, as data.
#
# bc2cpp.rb calls TypeFacts.collect at the point where every analysis has run (after the
# annotation/proof contradiction check) when BC2CPP_TYPE_FACTS=<path> is set, and writes the result as
# JSON. Nothing reads the file during a build and no generated code depends on it: it is the input of
# scripts/bc2cpp/type_check.rb, whose report front-end (type_check_report.rb) renders it.
#
# One row per method definition, ivar and constant, each with the type the analysis proved (or none), the
# SOURCE of that type (`inferred:*`, `annotation`, `signature`) and, when there is none, a REASON bucket:
#   methods  params[]  {pos, name, type, source, reason}; reasons: poly:N (the name has N definitions, so
#                      call-site facts do not apply), dynamic-name, never-called, packed-caller, and the
#                      receiver-proof `why` of the argument when the run loaded it (no_candidate:<rule>, dropped:<kinds>)
#            return    {type, source, reason}; reasons: the producers of the unresolved return sites
#                      (send_result:<name>, ivar:@x, param, literal:..., unanalyzable:<why>)
#   ivars    {type, element, source, reason}; reasons: the ADR 0382 poison buckets, plus `any` (two stores
#            disagree: inherent) and `opaque` (a store could not be traced), and the file:line of every
#            unresolved store
#   consts   {type, source}
# Declared types that disagree with an inferred one are `contradictions`; declared types that merely
# have nothing to compare against are listed with the other annotations.
module TypeFacts
  VERSION = 1

  Ctx = Struct.new(:ireps, :registry, :annotations, :class_annotations, :element_annotations, :arg_types,
                   :class_arg_types, :class_layout_raw, :class_poison_reason, :store_log, :poison_buckets,
                   :ivar_layout, :element_raw, :element_poison_reason, :hash_element_raw, :hash_poison_reason,
                   :container_constants, :gen, :contradictions, :dynamic_names, :call_sites, :root,
                   :signature_diagnostics, :signature_origins, keyword_init: true)

  INT_TYPES = { fixnum: 'Integer', symbol: 'Symbol', bool: 'bool', fixnum_nil: 'Integer?', array: 'Array' }.freeze
  # Writer opcode -> producer bucket for an unresolved return / store (see IvarPoisonCauses for the ivar side).
  CALL_OPS = %w[SEND SEND0 SENDB SSEND SSEND0 SSENDB SUPER].freeze
  PRODUCERS = {
    'GETIV' => 'ivar', 'GETIDX' => 'element', 'GETIDX0' => 'element', 'GETCONST' => 'constant', 'GETMCNST' => 'constant',
    'GETUPVAR' => 'upvar', 'GETGV' => 'global', 'GETCV' => 'class_variable', 'STRING' => 'literal:String',
    'STRCAT' => 'literal:String', 'ARRAY' => 'literal:Array', 'ARRAY2' => 'literal:Array', 'HASH' => 'literal:Hash',
    'RANGE_INC' => 'literal:Range', 'RANGE_EXC' => 'literal:Range', 'LAMBDA' => 'literal:Proc', 'BLOCK' => 'literal:Proc',
    'LOADSYM' => 'literal:Symbol', 'LOADSELF' => 'self', 'LOADNIL' => 'literal:nil', 'LOADT' => 'literal:bool',
    'LOADF' => 'literal:bool', 'LOADL' => 'literal:Numeric'
  }.freeze

  module_function

  def relative(ctx, path)
    return path.to_s unless ctx.root

    path.to_s.sub(%r{\A#{Regexp.escape(ctx.root.to_s)}/?}, '')
  end

  def scope_of(path)
    path.to_s.match?(%r{(\A|/)3rd/}) ? 'core' : 'engine'
  end

  # [line, col] of the `def` of +d+ (col from the source text; 1 when it cannot be found).
  def def_position(ctx, d, source_lines)
    irep = ctx.ireps[d.irep]
    enter = irep&.enter
    line = enter ? enter.lineno : irep&.instructions&.first&.lineno
    return [0, 1] unless line&.positive?

    [line, column_of(source_lines.call(irep.file), line, /\bdef\s+(?:self\.)?#{Regexp.escape(d.name.to_s)}\b/, 0)]
  end

  # 1-based column of the first match of +re+ (offset +shift+ into the match) on +line+ of +lines+, else 1.
  def column_of(lines, line, re, shift)
    text = lines && lines[line - 1]
    m = text && re.match(text)
    m ? m.begin(0) + shift + 1 : 1
  end

  def source_reader
    cache = {}
    lambda do |path|
      cache[path] ||= begin
        File.readlines(path, encoding: 'UTF-8')
      rescue SystemCallError
        nil
      end
    end
  end

  # The line of the `# bc2cpp:` comment above +irep+'s def, as Annotations.extract finds it, or nil.
  def annotation_line(irep, lines)
    enter = irep.enter
    return nil unless enter && lines

    idx = enter.lineno - 2
    idx -= 1 while idx >= 0 && lines[idx].strip.empty?
    idx >= 0 ? idx + 1 : nil
  end

  def collect(ctx)
    reader = source_reader
    gen = ctx.gen
    defs = ctx.registry.values.flatten.select(&:irep).uniq(&:irep)
    sites = ctx.call_sites
    methods = defs.filter_map { |d| method_row(ctx, gen, d, reader, sites) }
    ivars = ivar_rows(ctx, gen, reader)
    consts = const_rows(ctx)
    {
      'version' => VERSION,
      'methods' => methods.sort_by { |m| [m['file'], m['line'], m['owner'], m['name']] },
      'ivars' => ivars.sort_by { |i| [i['owner'], i['name']] },
      'constants' => consts.sort_by { |c| c['name'] },
      'annotations' => annotation_rows(ctx, defs, reader),
      'contradictions' => contradiction_rows(ctx, gen, defs, reader),
      'signature_diagnostics' => Array(ctx.signature_diagnostics),
      'summary' => nil
    }.tap { |facts| facts['summary'] = summarize(facts) }
  end

  # ------------------------------------------------------------------------------------------------ methods

  def method_row(ctx, gen, d, reader, sites)
    irep = ctx.ireps[d.irep] or return nil
    return nil unless irep.file

    line, col = def_position(ctx, d, reader)
    enter = irep.enter
    mand, opt, rest = enter ? enter.enter_fields.first(3).map(&:to_i) : [0, 0, 0]
    names = Array(irep.lv).first(mand + opt + (rest.positive? ? 1 : 0))
    defs_of_name = ctx.registry[d.name] || []
    mono = defs_of_name.size == 1
    params = (1..mand).map { |k| param_row(ctx, gen, d, irep, k, names[k - 1], mono, defs_of_name.size, sites) }
    {
      'owner' => d.owner, 'name' => d.name, 'file' => relative(ctx, irep.file), 'line' => line, 'col' => col,
      'scope' => scope_of(irep.file), 'req' => mand, 'opt' => opt, 'rest' => rest.positive?,
      'visibility' => d.visibility&.to_s, 'params' => params, 'return' => return_row(ctx, gen, d, irep, mono),
      'annotated' => !!(ctx.annotations[d.irep] || ctx.class_annotations[d.irep] || ctx.element_annotations[d.irep])
    }
  end

  def param_row(ctx, gen, d, irep, k, name, mono, ndefs, sites)
    row = { 'pos' => k, 'name' => name.to_s, 'type' => nil, 'source' => nil, 'reason' => nil }
    types = []
    # Declared first: a signature or comment annotation is the author's claim, shown as such.
    if (a = ctx.annotations[d.irep]) && (t = a.args[k - 1])
      types << [INT_TYPES.fetch(t, t.to_s), declared_source(ctx, d)]
    end
    if (c = ctx.class_annotations[d.irep]) && (t = c.args[k - 1])
      types << [t.to_s, declared_source(ctx, d)]
    end
    declared = types.dup
    inferred = inferred_param_types(ctx, gen, d, irep, k, mono)
    if declared.any?
      row['type'] = declared.map(&:first).uniq.join(' | ')
      row['source'] = declared.first.last
      row['inferred'] = inferred.map(&:first).uniq.join(' | ') unless inferred.empty?
    elsif inferred.any?
      row['type'] = inferred.map(&:first).uniq.join(' | ')
      row['source'] = inferred.first.last
    else
      row['reason'] = param_reason(ctx, gen, d, irep, k, mono, ndefs, sites)
    end
    row
  end

  def declared_source(ctx, d)
    (ctx.signature_origins && ctx.signature_origins[d.irep]) || 'annotation'
  end

  def inferred_param_types(ctx, gen, d, irep, k, mono)
    out = []
    label = d.irep
    name = d.name
    if mono
      t = (ctx.arg_types[name] || [])[k - 1]
      out << [INT_TYPES.fetch(t, nil), 'inferred:call-sites'] if t && INT_TYPES.key?(t)
      c = (ctx.class_arg_types[name] || [])[k - 1]
      out << [c.to_s, 'inferred:call-sites'] if c
    end
    out << ['Integer', 'inferred:entry-callsite'] if entry_fixnum?(gen, label, k)
    pools = gen.instance_variable_get(:@class_arg_pools) || {}
    if (mask = pools[[label, k]]) && mask.nonzero?
      names = mask_classes(gen, mask)
      out << [names.join(' | '), 'inferred:class-pool'] unless names.empty? || names.include?('OTHER')
    end
    numeric = gen.instance_variable_get(:@entry_arg_numeric) || {}
    if (mask = numeric[[label, k]]) && mask.nonzero? && out.empty?
      n = mask_classes_of_numeric(gen, mask)
      out << [n.join(' | '), 'inferred:numeric-flow'] unless n.empty? || n.include?('OTHER')
    end
    out.uniq
  rescue StandardError
    []
  end

  def mask_classes_of_numeric(gen, mask)
    gen.send(:numeric_mask_name, mask).to_s.split('|').reject { |n| n == 'NONE' }.map { |n| CORE_NAMES.fetch(n, n) }.uniq
  end

  def entry_fixnum?(gen, label, k)
    facts = gen.instance_variable_get(:@entry_arg_fixnum)
    facts ? facts.include?([label, k]) : false
  end

  CORE_NAMES = { 'INT' => 'Integer', 'FLT' => 'Float', 'ARR' => 'Array', 'HSH' => 'Hash', 'STR' => 'String',
                 'RNG' => 'Range', 'NIL' => 'nil' }.freeze

  def mask_classes(gen, mask)
    gen.send(:class_mask_name, mask).to_s.split('|').reject { |n| n == 'CHECKED' || n == 'NONE' }
       .map { |n| CORE_NAMES.fetch(n, n) }.uniq
  end

  def param_reason(ctx, gen, d, irep, k, mono, ndefs, sites)
    name = d.name
    return "poly:#{ndefs}" unless mono
    return 'dynamic-name' if ctx.dynamic_names&.include?(name)

    callers = sites ? CallSiteIndex.sites(sites, name) : []
    return 'never-called' if callers.empty?
    return 'packed-caller' if callers.any? { |_c, _i, _d, n| n.nil? }

    if gen.respond_to?(:rp_argument_why, true)
      pools = gen.instance_variable_get(:@class_arg_pools) || {}
      return gen.send(:rp_argument_why, [d.irep, k], pools[[d.irep, k]]).to_s
    end
    'opaque-callers'
  rescue StandardError
    'opaque-callers'
  end

  def return_row(ctx, gen, d, irep, mono)
    row = { 'type' => nil, 'source' => nil, 'reason' => nil }
    if (a = ctx.annotations[d.irep]) && a.ret
      row['type'] = INT_TYPES.fetch(a.ret, a.ret.to_s)
      row['source'] = declared_source(ctx, d)
    end
    if (e = ctx.element_annotations[d.irep])
      t = e.element ? "Array[#{e.element}]" : e.ret_class
      if t
        row['type'] = t
        row['source'] = declared_source(ctx, d)
      end
    end
    inferred = inferred_return(ctx, gen, d, irep, mono) || trivial_return(irep)
    if row['type']
      row['inferred'] = inferred if inferred
      return row
    end
    if inferred
      row['type'] = inferred
      row['source'] = 'inferred:return-analysis'
    else
      row['reason'] = return_reason(ctx, gen, d, irep)
    end
    row
  end

  # A body whose every exit is RETSELF / RETNIL / RETTRUE / RETFALSE (no value register to trace).
  def trivial_return(irep)
    ops = irep.instructions.map(&:op).grep(/\ARET|\ABREAK\z|\ARETURN/)
    return nil if ops.empty? || ops.any? { |o| %w[RETURN RETURN_BLK BREAK].include?(o) }

    kinds = ops.map { |o| { 'RETSELF' => 'self', 'RETNIL' => 'nil', 'RETTRUE' => 'bool', 'RETFALSE' => 'bool' }[o] }.uniq
    kinds.size == 1 ? kinds.first : nil
  end

  def inferred_return(ctx, gen, d, irep, mono)
    if mono
      return 'Integer' if gen.fixnum_return_names.include?(d.name)
      return 'Array' if gen.array_return_names.include?(d.name)
    end
    return nil unless gen.respond_to?(:return_class_def_mask)

    mask = gen.return_class_def_mask(d)
    return nil unless mask.is_a?(Integer) && mask.positive?

    names = mask_classes(gen, mask)
    return nil if names.empty? || names.include?('OTHER')

    nilable = names.delete('nil')
    return 'nil' if names.empty? && nilable
    return nil if names.empty?

    base = names.join(' | ')
    nilable ? "#{base}?" : base
  rescue StandardError
    nil
  end

  # Why no return class: the producers of the return sites the analysis could not name.
  def return_reason(ctx, gen, d, irep)
    cant = gen.respond_to?(:class_return_analyzable?, true) && !gen.send(:class_return_analyzable?, irep)
    if cant
      why = if (irep.catch_handlers || []).any? { |h| h.type == :ensure } then 'ensure'
            elsif gen.send(:subtree_has_nonlocal_exit?, irep) then 'nonlocal-exit'
            elsif irep.instructions.none? { |i| %w[RETURN RETURN_BLK].include?(i.op) } then 'implicit-return-op'
            else 'rescue'
            end
      return "unanalyzable:#{why}"
    end

    causes = Set.new
    irep.instructions.each_with_index do |insn, idx|
      case insn.op
      when 'RETURN'
        srcs = gen.respond_to?(:return_value_sources, true) ? gen.send(:return_value_sources, irep, idx, insn.reg) : nil
        if srcs.nil?
          causes << textual_producer(ctx, irep, idx, insn.reg)
          next
        end
        srcs.each do |s|
          if s == :nil then causes << 'literal:nil'
          else
            w = irep.instructions[s.first]
            causes << producer_of(ctx, w)
          end
        end
      when 'RETSELF' then causes << 'self'
      when 'RETTRUE', 'RETFALSE' then causes << 'literal:bool'
      when 'RETNIL' then causes << 'literal:nil'
      when 'RETURN_BLK', 'BREAK' then causes << 'block-return'
      end
    end
    causes.empty? ? 'unknown' : causes.to_a.sort.first(4).join('+')
  rescue StandardError => e
    "unanalyzable:#{e.class}"
  end

  # The nearest textual writer of the returned register (IrepScans#walk_writers), for a body the flow cannot read.
  def textual_producer(ctx, irep, idx, reg)
    enter = irep.enter
    mand = enter ? enter.enter_fields.first.to_i : 0
    found = irep.walk_writers(idx - 1, reg.to_s, skip_ops: ['BLOCK'], follow_moves: true,
                                                 exhausted: ->(last) { last == '0' ? 'self' : (last.to_i <= mand ? 'param' : 'unreadable') }) do |w, _i, _r|
      producer_of(ctx, w)
    end
    found.is_a?(String) ? found : 'unreadable'
  end

  def producer_of(ctx, w)
    return 'unreadable' unless w

    if CALL_OPS.include?(w.op)
      "send_result:#{w.sym}#{definer_kind(ctx, w.sym)}"
    elsif w.op == 'GETIV'
      "ivar:@#{w.ivar}"
    elsif w.op.start_with?('LOADI')
      'literal:Integer'
    else
      PRODUCERS[w.op] || "op:#{w.op}"
    end
  end

  # `(native)`, `(ruby)`, `(mixed)` or `(unregistered)`: who defines the called name, which says whether a
  # signature on the callee can help (ruby) or the result class has to come from the native model (native).
  def definer_kind(ctx, name)
    defs = ctx.registry[name.to_s] || []
    return '(unregistered)' if defs.empty?

    native = defs.count { |x| x.owner == '<native>' || !x.irep }
    return '(native)' if native == defs.size
    return '(ruby)' if native.zero?

    '(mixed)'
  end

  # ------------------------------------------------------------------------------------------------ ivars

  def ivar_rows(ctx, gen, reader)
    sites = Hash.new { |h, k| h[k] = [] }
    first_store = {}
    ctx.registry.each_value do |defs|
      defs.each do |d|
        irep = d.irep && ctx.ireps[d.irep]
        next unless irep&.file

        irep.each_with_op('SETIV') do |insn, _|
          first_store[[d.owner, insn.ivar.to_s]] ||= { 'file' => relative(ctx, irep.file), 'line' => insn.lineno,
            'col' => column_of(reader.call(irep.file), insn.lineno, /@#{Regexp.escape(insn.ivar.to_s)}\b/, 0), 'method' => d.name }
        end
      end
    end
    ctx.store_log.each do |(owner, _label, idx), (ivar, found, irep, _reg, _mand, mname)|
      insn = irep.instructions[idx]
      loc = { 'file' => relative(ctx, irep.file), 'line' => insn.lineno,
              'col' => column_of(reader.call(irep.file), insn.lineno, /@#{Regexp.escape(ivar.to_s)}\b/, 0), 'method' => mname }
      sites[[owner, ivar.to_s]] << loc.merge('resolved' => !found.nil?) unless found
    end
    bucket_of = {}
    ctx.poison_buckets.each { |bucket, names| names.each { |n| bucket_of[n] = bucket } }
    rows = []
    ctx.ivar_layout.each do |owner, ivars|
      ivars.each do |name, embed|
        row = { 'owner' => owner, 'name' => "@#{name}", 'type' => nil, 'element' => nil, 'source' => nil,
                'reason' => nil, 'embedded' => nil }
        loc = first_store[[owner, name.to_s]]
        row['file'], row['line'], row['col'] = loc ? [loc['file'], loc['line'], loc['col']] : [nil, 0, 1]
        row['scope'] = scope_of(loc && loc['file'])
        row['embedded'] = INT_TYPES[embed] if INT_TYPES.key?(embed)
        cls = (ctx.class_layout_raw[owner] || {})[name]
        if cls && cls != ClassLayout::UNKNOWN
          row['type'] = cls.to_s
          row['source'] = (ctx.signature_origins && ctx.signature_origins[[owner, "@#{name}"]]) || 'inferred:class-layout'
        elsif row['embedded']
          row['type'] = row['embedded']
          row['source'] = 'inferred:ivar-layout'
        end
        elem = (ctx.element_raw[owner] || {})[name]
        helem = (ctx.hash_element_raw[owner] || {})[name]
        row['element'] = "Array[#{elem}]" if elem && elem != ClassLayout::UNKNOWN && elem.is_a?(String)
        row['element'] = "Hash[#{helem}]" if helem && helem != ClassLayout::UNKNOWN && helem.is_a?(String) && row['element'].nil?
        if row['type'].nil?
          key = "#{owner}#@#{name}"
          pr = ctx.class_poison_reason.dig(owner, name.to_s) || ctx.class_poison_reason.dig(owner, name)
          bucket = bucket_of[key]
          row['reason'] = if cls == ClassLayout::UNKNOWN
                            [pr ? pr.to_s : 'unresolved', bucket].compact.join(':')
                          else
                            'nil-or-unassigned'
                          end
          row['stores'] = sites[[owner, name.to_s]].first(5) if cls == ClassLayout::UNKNOWN
        elsif row['element'].nil? && %w[Array Hash].include?(row['type'])
          epr = (ctx.element_poison_reason.dig(owner, name.to_s) if row['type'] == 'Array') ||
                (ctx.hash_poison_reason.dig(owner, name.to_s) if row['type'] == 'Hash')
          row['element_reason'] = epr ? epr.to_s : 'unresolved'
        end
        rows << row
      end
    end
    rows
  end

  # ------------------------------------------------------------------------------------------------ constants

  def const_rows(ctx)
    classes = ctx.container_constants || {}
    pools = ctx.gen.instance_variable_get(:@class_const_pools) || {}
    where = const_sites(ctx)
    names = (classes.keys + pools.keys).uniq
    names.map do |n|
      loc = where[n.to_s.split('::').last] || where[n.to_s]
      type = classes[n]&.to_s
      type ||= mask_classes(ctx.gen, pools[n]).join(' | ') if pools[n]
      { 'name' => n.to_s, 'type' => type, 'source' => classes[n] ? 'inferred:constructed' : 'inferred:class-pool',
        'file' => loc && loc[0], 'line' => loc ? loc[1] : 0, 'col' => 1 }
    end
  rescue StandardError
    []
  end

  def const_sites(ctx)
    found = {}
    ctx.ireps.each_value do |irep|
      next unless irep.file

      irep.each_with_op('SETCONST') do |insn, _|
        found[insn.const_name.to_s] ||= [relative(ctx, irep.file), insn.lineno]
      end
    end
    found
  end

  # ------------------------------------------------------------------------------------------------ annotations

  def annotation_rows(ctx, defs, reader)
    owners = ctx.registry.values.flatten.map(&:owner).to_set
    defs.filter_map do |d|
      irep = ctx.ireps[d.irep]
      lines = reader.call(irep.file)
      line = annotation_line(irep, lines)
      m = line && Annotations::COMMENT_RE.match(lines[line - 1])
      ann = ctx.annotations[d.irep]
      cann = ctx.class_annotations[d.irep]
      eann = ctx.element_annotations[d.irep]
      sig = ctx.signature_origins && ctx.signature_origins[d.irep]
      next unless m || sig

      tokens = m ? m[1].split(',', -1).map(&:strip) : []
      ret = m && m[2]
      enter = irep.enter
      mand = enter ? enter.enter_fields.first.to_i : 0
      known = ->(t) { t.empty? || Annotations::TYPES.key?(t) || owners.include?(t) || %w[Array Hash].include?(t) || container_known?(t, owners) }
      ignored = tokens.reject(&known)
      ignored << ret unless ret.nil? || known.call(ret.sub(/<.*>\z/, ''))
      { 'owner' => d.owner, 'name' => d.name, 'file' => relative(ctx, irep.file), 'line' => line || 0, 'col' => 1,
        'source' => declared_source(ctx, d), 'tokens' => tokens, 'return_token' => ret, 'ignored' => ignored,
        'arity_mismatch' => (tokens.size == mand || (tokens.empty? && mand.zero?) ? nil : "lists #{tokens.size} parameter(s), method takes #{mand}"),
        'args' => Array(ann&.args).map { |t| t && INT_TYPES.fetch(t, t.to_s) },
        'class_args' => Array(cann&.args),
        'return' => ann&.ret && INT_TYPES.fetch(ann.ret, ann.ret.to_s),
        'return_class' => eann&.ret_class, 'element' => eann&.element }
    end
  end

  def container_known?(token, owners)
    m = /\A(?:Array|Hash)<([A-Za-z_][\w:]*)>\z/.match(token)
    m ? owners.include?(m[1]) : false
  end

  # ------------------------------------------------------------------------------------------------ contradictions

  # A declared type the inference disproves: what AnnotationContradictions finds (fixnum/symbol, class argument) plus
  # a declared class RETURN against a COMPLETE inferred class set that lacks it.
  def contradiction_rows(ctx, gen, defs, reader)
    out = []
    by_irep = defs.to_h { |d| [d.irep, d] }
    seen = Set.new
    add = lambda do |d, slot, declared, inferred, line_irep|
      key = [d.irep, slot, declared]
      next unless seen.add?(key)

      irep = ctx.ireps[line_irep || d.irep]
      line = annotation_line(irep, reader.call(irep.file)) || 0
      where = slot == 'return' ? 'return type' : "parameter #{slot}"
      out << { 'owner' => d.owner, 'name' => d.name, 'slot' => slot.to_s, 'declared' => declared.to_s,
               'inferred' => inferred.to_s, 'file' => relative(ctx, irep.file), 'line' => line, 'col' => 1,
               'source' => declared_source(ctx, d),
               'message' => "#{d.owner}##{d.name} #{where}: declared #{declared}, inferred #{inferred}" }
    end
    Array(ctx.contradictions).each do |owner, name, pos, declared, got|
      d = (ctx.registry[name] || []).find { |x| x.owner == owner && x.irep } or next
      slot = pos == :return ? 'return' : (pos + 1).to_s
      add.call(d, slot, INT_TYPES.fetch(declared, declared), INT_TYPES.fetch(got, got), nil)
    end
    defs.each do |d|
      eann = ctx.element_annotations[d.irep]
      if eann&.ret_class
        set = complete_set([[inferred_return(ctx, gen, d, ctx.ireps[d.irep], (ctx.registry[d.name] || []).size == 1), nil]])
        add.call(d, 'return', eann.ret_class, set.join(' | '), nil) if set && !set.empty? && !set.include?(eann.ret_class) &&
                                                                         !inherits_any?(ctx, set, eann.ret_class)
      end
    end
    out
  end

  # Class names of an inferred list when it is a closed set of registry classes or Integer/Symbol, else nil.
  def complete_set(inferred)
    names = inferred.flat_map { |t, _| t.to_s.split('|').map { |x| x.strip.delete_suffix('?') } }.reject { |x| x.empty? || x == 'nil' }
    names.empty? ? nil : names.uniq
  end

  def inherits_any?(_ctx, _set, _declared)
    # Subclass relations are not carried here; a declared superclass is never reported (an absent fact, not a contradiction).
    false
  end

  # ------------------------------------------------------------------------------------------------ summary

  def summarize(facts)
    engine = ->(rows) { rows.select { |r| r['scope'] == 'engine' } }
    methods = engine.call(facts['methods'])
    params = methods.flat_map { |m| m['params'] }
    ivars = engine.call(facts['ivars'])
    {
      'methods' => methods.size,
      'methods_typed_return' => methods.count { |m| m['return']['type'] },
      'methods_all_params_typed' => methods.count { |m| m['params'].all? { |p| p['type'] } },
      'params' => params.size, 'params_typed' => params.count { |p| p['type'] },
      'ivars' => ivars.size, 'ivars_typed' => ivars.count { |i| i['type'] },
      'constants' => facts['constants'].size, 'constants_typed' => facts['constants'].count { |c| c['type'] },
      'annotations' => facts['annotations'].size, 'contradictions' => facts['contradictions'].size
    }
  end

  def write(path, facts)
    File.write(path, JSON.pretty_generate(facts))
  end
end
