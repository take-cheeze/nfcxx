# frozen_string_literal: true

require_relative 'native_binding_split'

# The source rewrite behind scripts/native_binding_split.rb (ADR 0263).
#
# For a binding
#
#   mrb_value f(mrb_state* M, mrb_value self) {
#     T a; U b;
#     mrb_get_args(M, "..", &a, &b);
#     BODY
#   }
#
# the body moves into `f_native_body(M, self, a, b)` and `f` keeps the
# declarations and the mrb_get_args call, then forwards. The body text is
# never copied, so the binding and the direct path run one body. A lambda
# binding is lifted to a static function ahead of the function that registers
# it. `rgss::f_direct` (a forwarder in the generated block of the file,
# declared in include/rgss_native_direct.hxx) is what compiled code calls; a
# frame-independent binding that reads no arguments only gets that forwarder.
module NativeBindingSplit
  BLOCK_BEGIN = '// BEGIN native-binding-split (ADR 0263, generated)'
  BLOCK_END = '// END native-binding-split'
  HEADER_PATH = 'include/rgss_native_direct.hxx'
  TABLE_PATH = 'tools/bc2cpp/native_direct_table.rb'
  PROBE_PATH = 'mruby-rgss/test/native_direct_probe.inc'

  Edit = Struct.new(:start, :finish, :text)
  Unit = Struct.new(:file, :kind, :cfunc, :body_name, :direct_name, :callee, :params, :splittable, :reg, :guard,
                    :bindings, :edits, keyword_init: true)

  module_function

  OWNER_NAME_TAGS = { '=' => '_set', '?' => '_p', '!' => '_bang', '[]' => 'aref', '[]=' => 'aset', '==' => 'eq',
                      '<=>' => 'cmp', '+' => 'add', '-' => 'sub', '*' => 'mul', '<<' => 'lshift' }.freeze

  def owner_tag(owner)
    owner.to_s.split('::').last.to_s.sub(/\.singleton\z/, '_s').downcase
  end

  def name_tag(name)
    return OWNER_NAME_TAGS.fetch(name) if OWNER_NAME_TAGS.key?(name)

    base = name.sub(/\A_+/, '')
    base = base.sub(/=\z/, '_set').sub(/\?\z/, '_p').sub(/!\z/, '_bang')
    base.gsub(/[^A-Za-z0-9_]/, '_')
  end

  # Byte offset where the comment block directly above `offset`'s line starts.
  def comment_block_start(bytes, offset)
    line_start = bytes.rindex("\n", offset - 1).then { |i| i ? i + 1 : 0 }
    pos = line_start
    loop do
      break if pos.zero?

      prev_start = bytes.rindex("\n", pos - 2).then { |i| i ? i + 1 : 0 }
      prev = bytes.byteslice(prev_start, pos - prev_start)
      break unless prev.match?(%r{\A\s*//})

      pos = prev_start
    end
    pos
  end

  # Statement end: the `;` after a call's extent.
  def semicolon_after(bytes, offset)
    idx = offset
    idx += 1 while bytes.getbyte(idx) && [32, 9, 10, 13].include?(bytes.getbyte(idx))
    bytes.getbyte(idx) == 59 ? idx : nil
  end

  def split_params(text)
    parts = []
    depth = 0
    cur = +''
    text.each_char do |ch|
      depth += 1 if '(<['.include?(ch)
      depth -= 1 if ')>]'.include?(ch)
      if ch == ',' && depth.zero?
        parts << cur.strip
        cur = +''
      else
        cur << ch
      end
    end
    parts << cur.strip unless cur.strip.empty?
    parts
  end

  def param_list(vars_types)
    vars_types.map { |name, type| "#{type} #{name}" }.join(', ')
  end

  # -- units -------------------------------------------------------------------

  def unit_key(binding)
    t = binding.reg['target']
    t['kind'] == 'lambda' ? [binding.file, :lambda, t['lambda_extent']] : [binding.file, :named, t['usr'] || t['name']]
  end

  # The bindings to rewrite: splittable or frame-free, owner resolved, and a
  # source shape the rewrite understands. Returns [units, rejected] where
  # rejected is [binding, reason].
  def plan_units(bindings, sources, existing_names)
    groups = bindings.select { |b| %i[splittable frame_free].include?(b.verdict.status) && b.owner }
                     .group_by { |b| unit_key(b) }
    units = []
    rejected = []
    taken = existing_names.dup
    groups.each_value do |members|
      first = members.first
      t = first.reg['target']
      source = sources.fetch(first.file)
      splittable = first.verdict.status == :splittable
      unit = Unit.new(file: first.file, kind: t['kind'] == 'lambda' ? :lambda : :named, cfunc: t['name'], reg: first.reg,
                      splittable: splittable, bindings: members, edits: [], params: first.verdict.params)
      if unit.kind == :lambda
        tag = "#{owner_tag(first.owner)}_#{name_tag(first.name)}"
        unit.body_name = "#{tag}_native_body"
        unit.direct_name = "#{tag}_direct"
      else
        unit.body_name = "#{t['name']}_native_body"
        unit.direct_name = "#{t['name']}_direct"
      end
      clash = [unit.direct_name, (unit.body_name if unit.kind == :lambda || splittable)].compact.find { |n| taken.include?(n) }
      if clash
        members.each { |b| rejected << [b, "name #{clash} is already taken"] }
        next
      end
      taken << unit.direct_name
      taken << unit.body_name if unit.kind == :lambda || splittable
      begin
        build_unit(unit, source, first)
      rescue ArgumentError => e
        members.each { |b| rejected << [b, e.message] }
        next
      end
      units << unit
    end
    [units, rejected]
  end

  def guard_of(source, offset)
    guard = source.guard_at(offset)
    raise ArgumentError, 'guard around the definition cannot be modelled (#elif)' if guard.nil?

    guard
  end

  def build_unit(unit, source, binding)
    t = unit.reg['target']
    bytes = source.bytes
    if unit.kind == :named
      unit.guard = guard_of(source, t['extent'][0])
      unit.callee = unit.splittable ? unit.body_name : t['name']
      build_named_edits(unit, source, t) if unit.splittable
    else
      unit.guard = guard_of(source, unit.reg['extent'][0])
      unit.callee = unit.body_name
      build_lambda_edits(unit, source, t, bytes)
    end
  end

  def wrapper_param_names(t)
    m = t['params'][0][1]
    s = t['params'][1][1]
    [m.empty? ? 'M' : m, s.empty? ? 'self' : s]
  end

  def split_pieces(unit, source, t)
    g = t['gets'].first
    semi = semicolon_after(source.bytes, g['extent'][1]) or raise ArgumentError, 'mrb_get_args statement does not end in a semicolon'
    body_open = t['body_extent'][0]
    body_close = t['body_extent'][1]
    raise ArgumentError, 'function body does not start with a brace' unless source.bytes.getbyte(body_open) == 123

    prelude = source.bytes.byteslice(body_open + 1, semi + 1 - (body_open + 1))
    rest = source.bytes.byteslice(semi + 1, body_close - (semi + 1))
    [prelude, rest]
  end

  def build_named_edits(unit, source, t)
    prelude, rest = split_pieces(unit, source, t)
    ext = t['extent']
    header = source.bytes.byteslice(ext[0], t['body_extent'][0] - ext[0])
    match = header.match(/\A(?<pre>.*?)\b#{Regexp.escape(t['name'])}\s*\((?<params>.*)\)\s*\z/m)
    raise ArgumentError, "cannot parse the declarator of #{t['name']}" unless match

    m, s = wrapper_param_names(t)
    parts = split_params(match[:params])
    raise ArgumentError, 'unexpected parameter list' unless parts.size == 2

    wrapper_params = [parts[0], t['params'][1][1].empty? ? "#{parts[1]} #{s}" : parts[1]]
    wrapper_params[0] = "#{parts[0]} #{m}" if t['params'][0][1].empty?
    extra = param_list(unit.params)
    body_fn = "#{match[:pre]}#{unit.body_name}(#{parts.join(', ')}, #{extra}) {#{rest}"
    args = ([m, s] + unit.params.map(&:first)).join(', ')
    wrapper = "#{match[:pre]}#{t['name']}(#{wrapper_params.join(', ')}) {#{prelude}\n  return #{unit.body_name}(#{args});\n}"
    unit.edits << Edit.new(ext[0], ext[1], "#{body_fn}\n\n#{wrapper}")
  end

  def build_lambda_edits(unit, source, t, bytes)
    enclosing = unit.reg['enclosing'] or raise ArgumentError, 'registration is not inside a function'
    insert_at = comment_block_start(bytes, enclosing['extent'][0])
    # A lift must precede the forwarder block that calls it.
    range = block_range(source)
    insert_at = range[0] if range && insert_at >= range[0]
    lam = t['lambda_extent']
    body_open, body_close = t['body_extent']
    raise ArgumentError, 'lambda body does not start with a brace' unless bytes.getbyte(body_open) == 123

    m, s = wrapper_param_names(t)
    relative = relative_guard(source, enclosing['extent'][0], unit.reg['extent'][0])
    if unit.splittable
      prelude, rest = split_pieces(unit, source, t)
      lifted = "static mrb_value #{unit.body_name}(mrb_state* #{m}, mrb_value #{s}, #{param_list(unit.params)}) {#{rest}"
      header = bytes.byteslice(lam[0], body_open - lam[0])
      args = ([m, s] + unit.params.map(&:first)).join(', ')
      replacement = "#{header}{#{prelude}\n  return #{unit.body_name}(#{args});\n}"
    else
      lifted = "static mrb_value #{unit.body_name}(mrb_state* #{m}, mrb_value #{s}) #{bytes.byteslice(body_open, body_close - body_open)}"
      replacement = unit.body_name
    end
    lifted = wrap_guard(relative, lifted)
    unit.edits << Edit.new(insert_at, insert_at, "#{lifted}\n\n")
    unit.edits << Edit.new(lam[0], lam[1], replacement)
  end

  # The clauses that hold at the registration but not at the start of the
  # function containing it.
  def relative_guard(source, function_start, offset)
    outer = guard_of(source, function_start)
    inner = guard_of(source, offset)
    raise ArgumentError, 'conditional structure around the registration differs unexpectedly' unless inner.first(outer.size) == outer

    inner[outer.size..]
  end

  def wrap_guard(clauses, text)
    return text if clauses.empty?

    "#if #{GuardEval.expression(clauses)}\n#{text}\n#endif"
  end

  def apply_edits(bytes, edits)
    out = bytes.dup
    edits.sort_by { |e| [-e.start, -e.finish] }.each do |e|
      out = out.byteslice(0, e.start) + e.text.b + out.byteslice(e.finish, out.bytesize - e.finish)
    end
    out.force_encoding(Encoding::BINARY)
  end

  # -- generated block, header, table --------------------------------------------

  Forwarder = Struct.new(:direct_name, :callee, :params, :guard, :file)

  def block_range(source)
    first = source.bytes.index(BLOCK_BEGIN)
    last = source.bytes.index(BLOCK_END)
    first && last ? [first, last + BLOCK_END.size] : nil
  end

  # The forwarder a binding needs in the generated block, or nil. Split
  # bindings and frame-free named functions get one; a delegation is kept only
  # while its export lives in the block (a hand-written one stays where it is).
  def forwarder_for(binding, source)
    v = binding.verdict
    t = binding.reg['target']
    case v.status
    when :split then callee, params, direct = t['ret_call']['callee'], v.params, v.function
    when :frame_free
      return nil unless t['kind'] == 'function'

      callee, params, direct = t['name'], [], direct_name(t['name'])
    when :delegated
      range = block_range(source)
      return nil unless range && v.export_extent && v.export_extent[0].between?(range[0], range[1]) && t['kind'] == 'function'

      callee, params, direct = t['name'], [], direct_name(t['name'])
    else return nil
    end
    defs = binding.functions[callee]
    raise ArgumentError, "#{callee} is not defined exactly once in #{binding.file}" unless defs && defs.size == 1

    Forwarder.new(direct, callee, params, guard_of(source, defs.first['extent'][0]), binding.file)
  end

  def forwarder_from_unit(unit)
    Forwarder.new(unit.direct_name, unit.callee, unit.params, unit.guard, unit.file)
  end

  def forwarders_for(bindings, sources)
    found = {}
    bindings.each do |b|
      next unless b.owner

      f = forwarder_for(b, sources.fetch(b.file))
      next unless f

      old = found[f.direct_name]
      raise ArgumentError, "#{f.direct_name} forwards to both #{old.callee} and #{f.callee}" if old && old.callee != f.callee

      found[f.direct_name] ||= f
    end
    found.values.sort_by(&:direct_name)
  end

  # A body that moved into its own function must name the same declarations it
  # did before (unqualified lookup inside another scope can pick a different
  # overload or hide a name): compare the digests of what each refers to.
  def moved_body_problems(moved, facts)
    problems = []
    facts.by_config.each do |config, data|
      moved.each do |body_name, (file, refs)|
        defs = data['files'].dig(file, 'functions', body_name)
        next unless defs

        problems << "#{config}: #{body_name} refers to different declarations than the body it was split from" unless defs.first['refs'] == refs
      end
    end
    problems
  end

  # Does each forwarder's guard predict, in every configuration, whether its
  # callee is compiled there, and is the entry point defined (really or as the
  # raising stub) in each of them?
  def link_problems(forwarders, facts)
    problems = []
    facts.by_config.each do |config, data|
      forwarders.each do |f|
        fdata = data['files'][f.file] or next
        defined = fdata['exports'].any? { |e| e['name'] == f.direct_name }
        problems << "#{config}: rgss::#{f.direct_name} is not defined" unless defined
        expected = GuardEval.holds?(f.guard, config)
        actual = fdata['functions'].key?(f.callee)
        export = fdata['exports'].find { |e| e['name'] == f.direct_name }
        if actual && export && export['ret_call'] && export['ret_call']['usr'] != fdata['functions'][f.callee].first['usr']
          problems << "#{config}: rgss::#{f.direct_name} calls a different function than #{f.callee}"
        end
        if expected.nil?
          problems << "#{config}: guard of #{f.callee} is not modelled: #{f.guard.inspect}"
        elsif expected != actual
          problems << "#{config}: #{f.callee} is #{actual ? '' : 'not '}compiled but its guard says #{expected}"
        end
      end
    end
    problems
  end

  def render_block(forwarders)
    lines = [BLOCK_BEGIN, 'namespace rgss {', '',
             '[[maybe_unused]] static mrb_value native_split_compiled_out(mrb_state* M, mrb_value self) {',
             '  mrb_raisef(M, mrb_exc_get_id(M, MRB_ERROR_SYM(NotImplementedError)),',
             '             "%C is not compiled into this build (ADR 0263)", mrb_obj_class(M, self));',
             '  return self;', '}', '']
    forwarders.each do |f|
      sig = ->(named) { (['mrb_state* M', 'mrb_value self'] + f.params.each_with_index.map { |(n, t), _| named ? "#{t} #{n}" : t.to_s }).join(', ') }
      call = ['M', 'self'] + f.params.map(&:first)
      real = ["mrb_value #{f.direct_name}(#{sig.call(true)}) {", "  return #{f.callee}(#{call.join(', ')});", '}']
      if f.guard.nil? || f.guard.empty?
        lines.concat(real)
      else
        lines << "#if #{GuardEval.expression(f.guard)}"
        lines.concat(real)
        lines << '#else'
        lines << "mrb_value #{f.direct_name}(#{sig.call(false)}) {"
        lines << '  return native_split_compiled_out(M, self);'
        lines << '}'
        lines << '#endif'
      end
      lines << ''
    end
    lines << '}  // namespace rgss'
    lines << BLOCK_END
    lines.join("\n") + "\n"
  end

  def render_header(forwarders)
    lines = ['// Generated by scripts/native_binding_split.rb (ADR 0263).',
             '// Frame-independent entry points of the RGSS native bindings.',
             '#pragma once', '', '#include <mruby.h>', '', 'namespace rgss {', '']
    forwarders.each do |f|
      params = (['mrb_state* M', 'mrb_value self'] + f.params.map { |n, t| "#{t} #{n}" }).join(', ')
      lines << "mrb_value #{f.direct_name}(#{params});"
    end
    lines << ''
    lines << '}  // namespace rgss'
    lines.join("\n") + "\n"
  end

  # One thunk per entry point for the mrbtest build: it turns Ruby values into
  # the typed arguments the way the binding's mrb_get_args format does and
  # calls the entry point, so a test can run binding and direct side by side.
  def render_probe(forwarders)
    lines = ['// Generated by scripts/native_binding_split.rb (ADR 0263); do not edit.',
             '// {entry point, Ruby argument count, thunk} per rgss::*_direct function.']
    forwarders.each do |f|
      args = []
      argc = 0
      params = f.params.map(&:last)
      i = 0
      while i < params.size
        type = normalize_type(params[i])
        if type == 'const char *' && normalize_type(params[i + 1].to_s) == 'mrb_int'
          args << "probe_str_ptr(M, a[#{argc}]), probe_str_len(M, a[#{argc}])"
          i += 2
        else
          args << case type
                  when 'mrb_int' then "mrb_as_int(M, a[#{argc}])"
                  when 'mrb_bool' then "mrb_test(a[#{argc}])"
                  when 'mrb_float' then "mrb_as_float(M, a[#{argc}])"
                  when 'mrb_sym' then "mrb_obj_to_sym(M, a[#{argc}])"
                  when 'mrb_value' then "a[#{argc}]"
                  when 'const char *' then "mrb_string_value_cstr(M, &a[#{argc}])"
                  else raise ArgumentError, "no probe conversion for #{type}"
                  end
          i += 1
        end
        argc += 1
      end
      call = (%w[M self] + args).join(', ')
      lines << "{\"#{f.direct_name}\", #{argc},"
      lines << " [](mrb_state* M, mrb_value self, mrb_value* a) -> mrb_value {"
      lines << '   (void)a;'
      lines << "   return rgss::#{f.direct_name}(#{call});"
      lines << ' }},'
    end
    lines.join("\n") + "\n"
  end

  # name => owner => [function, kinds] for every binding that has an entry
  # point once the plan is applied (`planned` maps a not-yet-applied binding to
  # the direct name it will get). A (name, owner) two registrations disagree on
  # gets no entry.
  def table_entries(bindings, planned = {})
    entries = Hash.new { |h, k| h[k] = {} }
    conflicts = []
    dropped = Set.new
    bindings.each do |b|
      next unless b.owner

      v = b.verdict
      function = planned[b] || (%i[forwarded delegated split].include?(v.status) ? v.function : nil)
      next unless function

      key = [b.name, b.owner]
      next if dropped.include?(key)

      value = [function, v.kinds.to_a]
      existing = entries[b.name][b.owner]
      if existing && existing != value
        conflicts << "#{b.label}: #{existing.first} vs #{function}"
        entries[b.name].delete(b.owner)
        dropped << key
      else
        entries[b.name][b.owner] = value
      end
    end
    entries.delete_if { |_, owners| owners.empty? }
    entries.default_proc = nil
    [entries, conflicts]
  end

  def render_table(entries)
    lines = ['# frozen_string_literal: true', '',
             '# Generated by scripts/native_binding_split.rb (ADR 0263); do not edit.',
             '# name => RGSS class => [entry point in include/rgss_construct.hxx, argument kinds].',
             'module NativeDirect', '  GENERATED = {']
    body = entries.sort.map do |name, owners|
      pairs = owners.map { |owner, (fn, kinds)| "#{owner.inspect} => [#{fn.inspect}, [#{kinds.map { |k| ":#{k}" }.join(', ')}]]" }
      "    #{name.inspect} => {\n#{pairs.map { |p| "      #{p}" }.join(",\n")}\n    }"
    end
    lines << body.join(",\n")
    lines << '  }.freeze'
    lines << 'end'
    lines.join("\n") + "\n"
  end
end
