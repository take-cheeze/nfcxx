# frozen_string_literal: true

require 'json'
require 'set'
require_relative 'bytecode_ir_ops'
require_relative 'annotations'
require_relative 'annotation_contradictions'
require_relative 'ir_type_feedback'
require_relative 'ir_ivar_types'

# TYPE_CHECK: the types bc2cpp's whole-program inference settled on, as data.
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
#   ivars    {type, element, source, reason}; reasons: the poison buckets, plus `any` (two stores
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
                   :signature_diagnostics, :signature_origins, :signature_locs, :signature_ivars, :constant_sites,
                   :modules, :superclass_of, :integer_constants, :signature_arg_types, :signature_contracts,
                   :ir_return_facts, :included_modules, :prepended_modules, :unknown_mixins,
                   :element_site_classes, :hash_element_site_classes, :integer_constant_ranges,
                   :integer_class_constants, keyword_init: true)

  INT_TYPES = { fixnum: 'Integer', symbol: 'Symbol', bool: 'bool', fixnum_nil: 'Integer?', array: 'Array' }.freeze
  # Writer opcode -> producer bucket for an unresolved return / store (see IvarPoisonCauses for the ivar side).
  PRODUCERS = {
    'GETIV' => 'ivar', 'GETIDX' => 'element', 'GETIDX0' => 'element', 'GETCONST' => 'constant', 'GETMCNST' => 'constant',
    'GETUPVAR' => 'upvar', 'GETGV' => 'global', 'GETCV' => 'class_variable', 'STRING' => 'literal:String',
    'STRCAT' => 'literal:String', 'ARRAY' => 'literal:Array', 'ARRAY2' => 'literal:Array', 'HASH' => 'literal:Hash',
    'RANGE_INC' => 'literal:Range', 'RANGE_EXC' => 'literal:Range', 'LAMBDA' => 'literal:Proc', 'BLOCK' => 'literal:Proc',
    'LOADSYM' => 'literal:Symbol', 'LOADSELF' => 'self', 'LOADNIL' => 'literal:nil', 'LOADTRUE' => 'literal:bool',
    'LOADFALSE' => 'literal:bool', 'LOADL' => 'literal:Numeric'
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

  # [file, line, col] of the declaration of the hints of +d+: its signature when that is where they came from, else the
  # `# bc2cpp:` comment above the def.
  def declared_location(ctx, d, reader)
    if (l = ctx.signature_locs && ctx.signature_locs[d.irep])
      return [l.file, l.line, l.col]
    end
    irep = ctx.ireps[d.irep]
    [relative(ctx, irep.file), annotation_line(irep, reader.call(irep.file)) || 0, 1]
  end

  def collect(ctx)
    reader = source_reader
    gen = ctx.gen
    defs = ctx.registry.values.flatten.select(&:irep).uniq(&:irep)
    raw_sites = ctx.call_sites
    unknown_sites = raw_sites && (raw_sites[CallSiteIndex::UNKNOWN_TARGET] || [])
    sites = raw_sites && Hash.new { |h, k| h[k] = (raw_sites[k] || []) + unknown_sites }
    feedback = IrTypeFeedback.collect(ctx)
    ctx.ir_return_facts = feedback[:returns]
    methods = defs.filter_map { |d| method_row(ctx, gen, d, reader, sites) }
    ivars = ivar_rows(ctx, gen, reader)
    consts = const_rows(ctx)
    {
      'version' => VERSION,
      'methods' => methods.sort_by { |m| [m['file'], m['line'], m['owner'], m['name']] },
      'ivars' => ivars.sort_by { |i| [i['owner'], i['name']] },
      'constants' => consts.sort_by { |c| c['name'] },
      'classes' => class_rows(ctx),
      'annotations' => annotation_rows(ctx, defs, reader),
      'contradictions' => contradiction_rows(ctx, gen, defs, reader),
      'signature_diagnostics' => Array(ctx.signature_diagnostics),
      'ir_feedback' => feedback[:rows],
      'native_direct_forms' => gen.respond_to?(:bytecode_ir_native_expression_inventory) ? gen.bytecode_ir_native_expression_inventory : [],
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
    key, kdict = enter ? enter.enter_fields[4, 2].map(&:to_i) : [0, 0]
    names = Array(irep.lv).first(mand + opt + (rest.positive? ? 1 : 0))
    defs_of_name = ctx.registry[d.name] || []
    mono = defs_of_name.size == 1
    params = (1..mand).map { |k| param_row(ctx, gen, d, irep, k, names[k - 1], mono, defs_of_name.size, sites) }
    optional_params = (1..opt).map do |position|
      register = (mand + position).to_s
      types = ctx.signature_contracts&.ir_optional_types&.dig(d.irep, register)
      inferred = (types || !gen.respond_to?(:bytecode_ir_optional_argument_classes)) ? nil : gen.bytecode_ir_optional_argument_classes(d, mand + position)
      { 'pos' => mand + position, 'name' => names[mand + position - 1].to_s,
        'type' => (types || inferred) && BytecodeIR::Types.type_name(types || inferred),
        'source' => types ? 'signature' : inferred ? 'inferred:receiver-call-sites' : nil }
    end
    optional_keywords = irep.instructions.filter_map { |insn| insn.sym.to_s if insn.op == 'KEY_P' }.to_set
    keyword_params = irep.instructions.filter_map { |insn| insn.sym.to_s if insn.op == 'KARG' }.uniq.map do |name|
      types = ctx.signature_contracts&.ir_keyword_types&.dig(d.irep, name)
      { 'name' => name, 'required' => !optional_keywords.include?(name),
        'type' => types && BytecodeIR::Types.type_name(types), 'source' => types ? 'signature' : nil }
    end
    {
      'owner' => d.owner, 'name' => d.name, 'file' => relative(ctx, irep.file), 'line' => line, 'col' => col,
      'scope' => scope_of(irep.file), 'req' => mand, 'opt' => opt, 'rest' => rest.positive?, 'key' => key,
      'kdict' => kdict.positive?,
      'visibility' => d.visibility&.to_s, 'params' => params, 'optional_params' => optional_params, 'keyword_params' => keyword_params, 'return' => return_row(ctx, gen, d, irep, mono),
      'annotated' => !!(ctx.annotations[d.irep] || ctx.class_annotations[d.irep] || ctx.element_annotations[d.irep] ||
                       ctx.signature_arg_types&.[](d.irep)&.any? || ctx.signature_contracts&.ir_optional_types&.[](d.irep)&.any? ||
                       ctx.signature_contracts&.ir_keyword_types&.[](d.irep)&.any?)
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
    signature_types = ctx.signature_arg_types&.dig(d.irep, k.to_s)
    if types.empty? && signature_types
      types << [BytecodeIR::Types.type_name(signature_types), 'signature']
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
    numeric = gen.instance_variable_get(:@entry_arg_numeric) || {}
    poly = gen.respond_to?(:poly_arg_pool_key?) && gen.poly_arg_pool_key?([label, k])
    if !poly && (mask = pools[[label, k]]) && mask.nonzero?
      names = mask_classes(gen, mask)
      out << [names.join(' | '), 'inferred:class-pool'] unless names.empty? || names.include?('OTHER')
    end
    if (mask = numeric[[label, k]]) && mask.nonzero? && out.empty?
      n = mask_classes_of_numeric(gen, mask)
      out << [n.join(' | '), 'inferred:numeric-flow'] unless n.empty? || n.include?('OTHER')
    end
    if out.empty? && gen.respond_to?(:bytecode_ir_argument_classes)
      classes = gen.bytecode_ir_argument_classes(d, k)
      out << [BytecodeIR::Types.type_name(classes), 'inferred:receiver-call-sites'] if classes
    end
    if out.empty? && gen.respond_to?(:bytecode_ir_call_graph_argument_classes)
      classes = gen.bytecode_ir_call_graph_argument_classes(d, k)
      out << [BytecodeIR::Types.type_name(classes), 'inferred:call-graph'] if classes
    end
    out.uniq
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

    callers = sites ? sites[name] : []
    return 'never-called' if callers.empty?
    return 'packed-caller' if callers.any? { |_c, _i, _d, n| n.nil? }

    if gen.respond_to?(:rp_argument_why, true)
      pools = gen.instance_variable_get(:@class_arg_pools) || {}
      mask = pools[[d.irep, k]]
      return gen.send(:rp_argument_why, [d.irep, k], mask).to_s
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
    if !row['type'] && (signature = ctx.signature_contracts&.ir_return_types&.[](d.irep))
      row['type'] = BytecodeIR::Types.type_name(signature)
      row['source'] = 'signature'
    end
    inferred = inferred_return(ctx, gen, d, irep, mono) || trivial_return(irep)
    if row['type']
      row['inferred'] = inferred if inferred
      return row
    end
    ir_fact = ctx.ir_return_facts&.[](d.irep)
    prior_classes = inferred && simple_value_classes(inferred)
    if ir_fact && !ir_fact.declared? && Array(irep.reps).empty? && !BytecodeIR.for(irep).handlers? && prior_classes && ir_fact.classes.proper_subset?(prior_classes)
      row['type'] = BytecodeIR::Types.type_name(ir_fact.classes)
      row['source'] = 'inferred:bytecode-ir'
    elsif inferred
      row['type'] = inferred
      row['source'] = 'inferred:return-analysis'
    elsif ir_fact
      row['type'] = BytecodeIR::Types.type_name(ir_fact.classes)
      row['source'] = ir_fact.declared? ? 'derived:contracts' : 'inferred:bytecode-ir'
      row['contracts'] = ir_fact.contracts if ir_fact.declared?
    else
      row['reason'] = return_reason(ctx, gen, d, irep)
    end
    row
  end

  def simple_value_classes(text)
    return nil unless text.match?(/\A(?:[A-Z]\w*(?:::\w+)*|nil|bool)(?: \| (?:[A-Z]\w*(?:::\w+)*|nil|bool))*\z/)

    text.split(' | ').flat_map { |name| name == 'bool' ? [:TrueClass, :FalseClass] : [name == 'nil' ? :NilClass : name.to_sym] }.to_set
  end

  # A body whose every exit is RETSELF / RETNIL / RETTRUE / RETFALSE (no value register to trace).
  def trivial_return(irep)
    # The IR's exits minus STOP: it ends the program, not the body, and the grep this replaces never matched it.
    ops = BytecodeIR.for(irep).exits.map(&:op).reject { |o| o == 'STOP' }
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
            elsif BytecodeIR.for(irep).exits.none? { |ex| %w[RETURN RETURN_BLK].include?(ex.op) } then 'implicit-return-op'
            else 'rescue'
            end
      return "unanalyzable:#{why}"
    end

    causes = Set.new
    # Only frame exits name a cause, so the exit list visits the same instructions in the same order.
    BytecodeIR.for(irep).exits.each do |ex|
      idx = ex.index
      insn = irep.instructions[idx]
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

    if BytecodeIR::Ops::CALL.include?(w.op)
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
        if row['type'].nil? && (seed = ctx.signature_ivars && ctx.signature_ivars[[owner, "@#{name}"]]) &&
           %i[class array hash].include?(seed.type.kind)
          row['type'] = seed.type.kind == :class ? seed.type.cls : seed.type.kind.to_s.capitalize
          row['source'] = 'signature'
        end
        if row['type'].nil? && (seed = ctx.signature_contracts&.ir_ivar_types&.[]([owner, name.to_s]))
          row['type'] = BytecodeIR::Types.type_name(seed)
          row['source'] = 'signature'
        end
        if row['type'].nil? && (classes = IrIvarTypes.classes(gen, owner, name))
          row['type'] = BytecodeIR::Types.type_name(classes)
          row['source'] = 'inferred:ivar-class-pool'
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
    (ctx.signature_contracts&.ir_ivar_types || {}).each do |(owner, name), types|
      next if rows.any? { |row| row['owner'] == owner && row['name'] == "@#{name}" }

      signature = ctx.signature_ivars[[owner, "@#{name}"]]
      rows << { 'owner' => owner, 'name' => "@#{name}", 'type' => BytecodeIR::Types.type_name(types),
                'element' => nil, 'source' => 'signature', 'reason' => nil, 'embedded' => nil,
                'file' => signature.loc.file, 'line' => signature.loc.line, 'col' => signature.loc.col,
                'scope' => scope_of(signature.loc.file) }
    end
    rows
  end

  # ------------------------------------------------------------------------------------------------ classes

  # Every class / module the program defines: kind and the resolved superclass (nil when it is Object or unresolved).
  def class_rows(ctx)
    owners = ctx.registry.values.flatten.map { |d| d.owner.delete_suffix('.singleton') }.reject { |o| o.start_with?('<') }.uniq
    owners |= Array(ctx.superclass_of&.keys)
    owners |= Array(ctx.modules).to_a
    modules = ctx.modules || Set.new
    owners.sort.map do |o|
      sup = ctx.superclass_of && ctx.superclass_of[o]
      { 'name' => o, 'kind' => modules.include?(o) ? 'module' : 'class', 'superclass' => sup.is_a?(String) ? sup : nil }
    end
  end

  # ------------------------------------------------------------------------------------------------ constants

  # ARRAY_SUM: `+` on Array and `freeze` answer what the proof assumes only while no Ruby definition of either can
  # replace it (CodeGen#declared_array_plus_safe?: no program `+` on Array or a subclass, no prepend). `freeze` is
  # scoped to the Array owners (stock_proof), not to every program `freeze`, so Graphics.freeze does not refuse it.
  def array_sum_safe?(ctx)
    ctx.gen.declared_array_plus_safe? && stock_proof(ctx, 'freeze', 'Array')
  end

  # The owner-scoped proof of a stock +name+ on Array or Hash (DeclaredConstants.stock_method?) over the program's
  # class graph. Report-level only: CodeGen keeps its own predicates.
  def stock_proof(ctx, name, klass)
    DeclaredConstants.stock_method?(name, klass, ctx.registry, ctx.included_modules || {},
                                    ctx.prepended_modules || {}, ctx.unknown_mixins || [])
  end

  # FREEZE_SELF: `R.freeze` answers its receiver (Object#freeze), so `(literal).freeze` has the literal's class while
  # freeze is stock on it (stock_proof). Only a literal receiver is proven here; a send, sum or ivar keeps its own
  # producer. Returns the class, or nil.
  FREEZE_SELF_LITERALS = { 'literal:Integer' => 'Integer', 'literal:String' => 'String', 'literal:Array' => 'Array',
                           'literal:Hash' => 'Hash' }.freeze

  def freeze_self_type(ctx, irep, idx, reg)
    found = irep.walk_writers(idx - 1, reg.to_s, follow_moves: true) do |insn, j, cur|
      insn.op == 'SEND0' && insn.sym == 'freeze' ? [j, cur] : false
    end
    return nil unless found.is_a?(Array)

    j, cur = found
    klass = FREEZE_SELF_LITERALS[textual_producer(ctx, irep, j, cur)]
    klass && stock_proof(ctx, 'freeze', klass) ? klass : nil
  end

  # IO_OPEN_SAFE: the constant IO is the one native class (ClosedWorld#native_class_unshadowed?), and `open` on IO's
  # singleton is mruby-io's io.rb definition. Its singleton comes before every other definer of IO.open, so the gate
  # refuses any definer that could replace it: a Ruby `open` on IO.singleton (registry), a prepend or unknown mixin on
  # it, or a non-core native `open`. `new` on IO must be stock (class_new_is_stock?), since io.rb's open is `self.new`.
  def io_open_safe?(ctx)
    world = ctx.gen.instance_variable_get(:@closed_world)
    return false unless world && world.native_class_unshadowed?('IO')

    native = ctx.gen.instance_variable_get(:@native_name_sources) || {}
    included = ctx.included_modules || {}
    prepended = ctx.prepended_modules || {}
    unknown = ctx.unknown_mixins || []
    return false if Array(native.fetch('open', [])).any? { |path| !path.match?(ClosedWorld::NATIVE_CORE) }
    return false if (ctx.registry['open'] || []).any? { |d| d.owner == 'IO.singleton' }
    return false if Array(prepended['IO.singleton']).any? || unknown.include?('IO.singleton')

    class_new_is_stock?(ctx.registry, world, native, included, prepended, unknown)
  end

  # The merge proof reads a Hash receiver's `merge`, which a singleton method on that very object could replace. The
  # closed world's exact-instance check (no singleton makers in the program) is the proof that none can exist.
  def singleton_free?(ctx)
    world = ctx.gen.instance_variable_get(:@closed_world)
    !world.nil? && world.exact_instances_singleton_free?
  end

  # Non-core native files that name `length` and were read as NOT defining it on String: StringIO#length (an alias on
  # StringIO), MatchData#length, and two JS property reads. Any other non-core definer refuses the String#length proof.
  STRING_LENGTH_NOT_STRING_NATIVES = %w[
    3rd/mruby-stringio/src/stringio.c
    3rd/mruby-onig-regexp/src/mruby_onig_regexp.c
    mruby-mvjs/src/mvwebgl.cxx
    mruby-mvjs/src/mvcanvas.cxx
  ].freeze

  # The String#length proof of BOOL_COMPARE: stock on String (owner-scoped) and every non-core native `length` definer is
  # one read as not String's (STRING_LENGTH_NOT_STRING_NATIVES).
  def string_length_safe?(ctx)
    native = ctx.gen.instance_variable_get(:@native_name_sources) || {}
    DeclaredConstants.stock_method?('length', 'String', ctx.registry, ctx.included_modules || {},
                                    ctx.prepended_modules || {}, ctx.unknown_mixins || []) &&
      Array(native.fetch('length', [])).none? do |path|
        !path.match?(ClosedWorld::NATIVE_CORE) && STRING_LENGTH_NOT_STRING_NATIVES.none? { |known| path.end_with?(known) }
      end
  end

  def const_rows(ctx)
    classes = ctx.container_constants || {}
    pools = ctx.gen.instance_variable_get(:@class_const_pools) || {}
    ints = ctx.integer_constants || Set.new
    # NUMERIC_CONSTANT_RANGES: a bare name whose every definition has a Fixnum interval is an Integer. Consulted only
    # after the other producers, so no row that already has a type changes.
    ranges = ctx.integer_constant_ranges || {}
    # CLASS_INTEGER_PROOF (bignum-capable Integer), then the bool and IO proofs below. Each is consulted only after the
    # producers above, so a row that already has a type does not change.
    int_classes = ctx.integer_class_constants || Set.new
    string_length_safe = string_length_safe?(ctx)
    io_open_safe = io_open_safe?(ctx)
    integer_ops_safe = IntegerConstantRanges.integer_ops_safe?(ctx.registry, ctx.included_modules || {},
                                                              ctx.prepended_modules || {}, ctx.unknown_mixins || [])
    sums =DeclaredConstants.array_sum_names(ctx.ireps, Array(ctx.constant_sites), ctx.registry, classes,
                                             array_sum_safe?(ctx), range_safe: ctx.gen.range_to_a_safe?)
    merges = DeclaredConstants.hash_merge_names(ctx.ireps, Array(ctx.constant_sites), ctx.registry, classes,
                                                merge_safe: stock_proof(ctx, 'merge', 'Hash'),
                                                singleton_free: singleton_free?(ctx))
    # A value that is `.freeze`d keeps the class of its receiver only while freeze is stock on that class. The literal's
    # container class (literal_container_class) and the class pools walk past the freeze without checking it, so a
    # name with a frozen site that could hold an Array or Hash whose freeze is not proven is untyped by either.
    freeze_refused = Set.new
    Array(ctx.constant_sites).each do |site|
      name = site[:name].to_s
      irep = ctx.ireps[site[:irep]]
      next unless irep && DeclaredConstants.frozen_at?(irep, site[:idx], site[:reg])

      held = if classes[name] then [classes[name]]
             elsif pools[name] then mask_classes(ctx.gen, pools[name])
             else []
             end
      unproven = held.any? { |klass| %w[Array Hash].include?(klass) && !stock_proof(ctx, 'freeze', klass) }
      freeze_refused << name if unproven
    end
    # FREEZE_SELF needs every assignment of the name to be the same frozen literal class: the row takes one site's
    # type, so a name with a site of another class (or any unproven site) keeps no type from this fact.
    freeze_self = {}
    Array(ctx.constant_sites).group_by { |s| s[:name].to_s }.each do |name, group|
      kinds = group.map { |s| (irep = ctx.ireps[s[:irep]]) && freeze_self_type(ctx, irep, s[:idx], s[:reg]) }
      freeze_self[name] = kinds.first if kinds.first && kinds.uniq.size == 1
    end
    seen = {}
    Array(ctx.constant_sites).each do |site|
      name = site[:name].to_s
      irep = ctx.ireps[site[:irep]]
      next unless irep

      bare = name.split('::').last
      row = seen[name] ||= { 'name' => name, 'owner' => site[:owner], 'type' => nil, 'source' => nil, 'reason' => nil,
                             'file' => relative(ctx, irep.file), 'line' => irep.instructions[site[:idx]].lineno, 'col' => 1,
                             'scope' => scope_of(irep.file) }
      next if row['type']

      if classes[name] && !freeze_refused.include?(name)
        row['type'] = classes[name].to_s
        row['source'] = 'inferred:constructed'
      elsif pools[name] && !freeze_refused.include?(name) && !mask_classes(ctx.gen, pools[name]).include?('OTHER')
        row['type'] = mask_classes(ctx.gen, pools[name]).join(' | ')
        row['source'] = 'inferred:class-pool'
      elsif ints.include?(bare)
        row['type'] = 'Integer'
        row['source'] = 'inferred:integer-constant'
      elsif sums[name]
        row['type'] = 'Array'
        row['source'] = 'inferred:array-sum'
      elsif merges[name]
        row['type'] = 'Hash'
        row['source'] = 'inferred:hash-merge'
      else
        producer = textual_producer(ctx, irep, site[:idx], site[:reg])
        if producer.start_with?('literal:') && !%w[literal:nil literal:Numeric].include?(producer)
          row['type'] = producer.delete_prefix('literal:')
          row['source'] = 'inferred:literal'
        elsif producer == 'literal:Numeric'
          row['type'] = 'Numeric'
          row['source'] = 'inferred:literal'
        elsif freeze_self[name]
          row['type'] = freeze_self[name]
          row['source'] = 'inferred:freeze-self'
        elsif ranges.key?(bare)
          row['type'] = 'Integer'
          row['source'] = 'inferred:integer-range'
        elsif int_classes.include?(bare)
          row['type'] = 'Integer'
          row['source'] = 'inferred:integer-class'
        elsif DeclaredConstants.io_open_site?(irep, site[:idx], site[:reg], io_open_safe: io_open_safe)
          row['type'] = 'IO'
          row['source'] = 'inferred:io-open'
        elsif DeclaredConstants.bool_compare_site?(irep, site[:idx], site[:reg], string_length_safe: string_length_safe,
                                                                               integer_ops_safe: integer_ops_safe)
          row['type'] = 'bool'
          row['source'] = 'inferred:bool-compare'
        else
          row['reason'] = producer
        end
      end
    end
    seen.values
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

      file, aline, acol = declared_location(ctx, d, reader)
      tokens = m ? m[1].split(',', -1).map(&:strip) : []
      ret = m && m[2]
      enter = irep.enter
      mand = enter ? enter.enter_fields.first.to_i : 0
      known = ->(t) { t.empty? || Annotations::TYPES.key?(t) || owners.include?(t) || %w[Array Hash String].include?(t) || container_known?(t, owners) }
      ignored = tokens.reject(&known)
      ignored << ret unless ret.nil? || known.call(ret.sub(/<.*>\z/, ''))
      { 'owner' => d.owner, 'name' => d.name, 'file' => file, 'line' => aline, 'col' => acol,
        'source' => declared_source(ctx, d), 'tokens' => tokens, 'return_token' => ret, 'ignored' => ignored,
        'arity_mismatch' => (m.nil? || tokens.size <= mand ? nil : "lists #{tokens.size} parameter(s), method takes #{mand}"),
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
    seen = Set.new
    add = lambda do |d, slot, declared, inferred, line_irep|
      key = [d.irep, slot, declared]
      next unless seen.add?(key)

      file, line, col = declared_location(ctx, d, reader)
      where = slot == 'return' ? 'return type' : "parameter #{slot}"
      out << { 'owner' => d.owner, 'name' => d.name, 'slot' => slot.to_s, 'declared' => declared.to_s,
               'inferred' => inferred.to_s, 'file' => file, 'line' => line, 'col' => col,
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
    ivar_contradictions(ctx, out)
    out
  end

  # A declared ivar class (or Integer / Symbol) against what the analysis proved for the same ivar. The rule is
  # AnnotationContradictions.ivar_conflicts, which the build also enforces; ELEMENT_SIGNATURE_CHECK adds a declared
  # `Array[C]` / `Hash[K, C]` against the classes traced element sites wrote (ivar_element_conflicts).
  def ivar_contradictions(ctx, out)
    rows = AnnotationContradictions.ivar_conflicts(ctx.signature_ivars, ctx.class_layout_raw, ctx.ivar_layout,
                                                   ClassLayout::UNKNOWN)
    rows += AnnotationContradictions.ivar_element_conflicts(ctx.signature_ivars, ctx.element_site_classes || {},
                                                            ctx.hash_element_site_classes || {})
    rows.each do |sig, want, got|
      out << { 'owner' => sig.owner, 'name' => sig.name, 'slot' => 'ivar', 'declared' => want, 'inferred' => got,
               'file' => sig.loc.file, 'line' => sig.loc.line, 'col' => sig.loc.col, 'source' => 'signature',
               'message' => "#{sig.owner}#{sig.name} ivar: declared #{want}, inferred #{got}" }
    end
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

  # Adds the nilable-index rows (TC1005) to a facts file already written by `write`. Rows are collected after
  # the methods compile, so they are appended here rather than in `collect`.
  def append_nilable_index(path, sites, root)
    facts = JSON.parse(File.read(path))
    facts['nilable_index'] = sites.filter_map do |s|
      next unless s[:owner] && s[:method]

      { 'owner' => s[:owner], 'method' => s[:method], 'name' => s[:name], 'file' => relative(Struct.new(:root).new(root), s[:file]),
        'line' => s[:line], 'col' => 1 }
    end
    File.write(path, JSON.generate(facts))
  end

  def write(path, facts)
    File.write(path, JSON.generate(facts))
  end
end
