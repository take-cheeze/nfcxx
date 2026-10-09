# frozen_string_literal: true

# Classifies the by-name dispatch left in bc2cpp's generated C++. Shared by
# scripts/bc2cpp_dynamic_site_census.rb (static counts, executed-count ranking)
# and site_profile.rb (the opt-in counter instrumentation), so both name a site
# and its reason identically. See docs/bc2cpp-dynamic-site-census.md.
module SiteCensus
  Scan = Struct.new(:lines, :names, :first_method, :sites, :helper_sends, keyword_init: true)

  FN_RE = /^(?:\[\[[^\]]*\]\]\s*)*(?:static |inline )+[\w:*&<>\s]+?\b(\w+)\(.*\{\s*$/
  # Non-static bodies (a gem's own `X_impl`, declared in its decls header).
  FN_EXTERN_RE = /^mrb_value (\w+)\(.*\{\s*$/
  SEND_RE = /bc2cpp_send\(M, [^,]+, (\d+), (\d+)/
  FAM_RE = %r{^\s*//\s*([A-Z][A-Z0-9_]+)\b}
  # Non-bc2cpp_send by-name calls; the lookbehind keeps `mrb_funcall_id` from matching as `mrb_funcall`.
  FUNCALL_RE = /(?<![\w.])(mrb_funcall_with_block|mrb_funcall_argv|mrb_funcall_id|mrb_funcall)\(/
  # The `#if` that opens the by-name copy of a closed helper (codegen_numeric_slow.rb); the copy ends at `#else`.
  NUMERIC_OPEN_FORM_GUARD = '#if defined(MRB_USE_COMPLEX) || defined(MRB_USE_RATIONAL)'

  module_function

  def fn_name(line)
    line[FN_RE, 1] || line[FN_EXTERN_RE, 1]
  end

  def sym_names(src)
    src[/bc2cpp_sym_names\[\d+\] = \{(.*?)\n\};/m, 1].to_s.scan(/^\s*"((?:[^"\\]|\\.)*)",/).flatten
  end

  # Shared helpers precede the first generated method body.
  def first_method_line(lines)
    lines.index { |l| l =~ /^(?:static )?mrb_value \w+_impl\(.*\{\s*$/ }
  end

  # A helper written twice (ADR 0360, 0361) keeps its by-name form for builds that link Complex or Rational, which
  # the closed-world targets do not: the lines of that copy (up to its `#else`) are not live there.
  def open_form_mask(lines, first_method)
    open_form = false
    depth = 0
    lines.each_with_index.map do |l, i|
      if open_form
        # The open copy has its own `#ifdef MRB_USE_BIGINT ... #else`; only the guard's own `#else` ends it.
        depth += 1 if l =~ /\A#if/
        depth -= 1 if l =~ /\A#endif/ && depth.positive?
        open_form = false if depth.zero? && l =~ /\A#else\s*\z/
      elsif i < first_method && l.start_with?(NUMERIC_OPEN_FORM_GUARD)
        open_form = true
        depth = 0
      end
      open_form
    end
  end

  # Hop limit of the text-mode copy walk (see receiver_origin).
  COPY_HOPS = 8

  # Index and right-hand side of the nearest assignment to `reg` in lines[floor...from] (a declaration included).
  def last_assignment(lines, from, floor, reg)
    (from - 1).downto(floor) do |j|
      m = lines[j].match(/^\s*(?:mrb_value )?#{reg} = (.*);\s*$/)
      return [j, m[1]] if m
    end
    nil
  end

  # The generated method header that opens the body holding `i`; nil outside any function.
  def function_start(lines, i)
    k = i
    k -= 1 while k.positive? && fn_name(lines[k]).nil?
    fn_name(lines[k]) ? k : nil
  end

  def parameter_names(header)
    header[/\((.*)\)\s*\{\s*$/, 1].to_s.split(',').filter_map { |p| p[/(\w+)\s*\z/, 1] }
  end

  # Text-mode baseline (no origin table): the origin is read from the right-hand side of the register's last
  # assignment, and a register copy is followed up to COPY_HOPS assignments in text order. The default census
  # uses origin_table (SiteOriginTable's reaching definitions) instead; this stays for before/after comparisons.
  def receiver_origin(lines, line, recv)
    # A receiver that is not a register is named directly: `self`, or a parameter of the method.
    unless recv =~ /\Ar\d+\z/
      fn = function_start(lines, line - 1)
      return origin_of(lines, line - 1, recv, fn, parameter_list(lines, fn), COPY_HOPS)
    end

    i = line - 2
    i -= 1 while i.positive? && line - i < 80 && !(lines[i] =~ %r{^(if \(|\{$|// [^ ]+ -- generated)} && lines[i - 1] !~ /\} else|else\s*$/)
    found = last_assignment(lines, i, [i - 60, 0].max, recv)
    return 'unknown' unless found
    return 'join' if join_between?(lines, found[0], line - 1, recv)

    fn = function_start(lines, found[0])
    origin_of(lines, found[0], found[1], fn, parameter_list(lines, fn), COPY_HOPS)
  end

  JOIN_LABEL_RE = /^\s*L\d+:/
  JOIN_BRANCH_RE = /^\s*(?:\}\s*)?(?:else\b|if \(|switch \(|goto )/

  # True when the matched assignment at `from` is not the only definition that can reach the send at `to`
  # (0-based): a jump label lies between them (another path joins there), or a branch does while the register
  # is assigned again between them (an arm's value is not the receiver's). Diagnostic only.
  def join_between?(lines, from, to, reg)
    between = lines[(from + 1)...to] || []
    return true if between.any? { |l| l =~ JOIN_LABEL_RE }

    between.any? { |l| l =~ JOIN_BRANCH_RE } && between.any? { |l| l =~ /(?:^|[\s;{(])#{reg} = / }
  end

  def parameter_list(lines, fn)
    fn ? parameter_names(lines[fn]) : []
  end

  # The `/*SR:*/` and `/*SO:*/` join tags are comments the text walk must not see (a trailing tag hides `;`).
  TAG_RE = %r{ /\*S[RO]:[^*]*\*/}
  # The SiteOriginTable tag on a by-name line: `/*SO:<label>:<index>:<reg>:<walk>*/` (see site_origin_table.rb).
  ORIGIN_TAG_RE = %r{/\*SO:(.+?):(\d+):(\d+):(\d+)\*/}

  def strip_tags(src)
    src.gsub(TAG_RE, '')
  end

  # [label, index, reg, walk] => [status, category, definition] from a BC2CPP_SITE_ORIGIN_TABLE file.
  def origin_table(path)
    File.foreach(path).each_with_object({}) do |row, table|
      label, index, reg, status, category, definition, walk = row.chomp.split("\t")
      table[[label, index.to_i, reg, walk]] = [status, category, definition]
    end
  end

  # The receiver origin from the exact walk (SiteOriginTable): [origin, status]. A site the table
  # cannot prove, or cannot find, is `unknown` with the reason as its status.
  def exact_origin(line, recv, origins)
    return ['self', 'exact'] if recv == 'self'
    return ['unknown', 'not_a_register'] unless recv =~ /\Ar\d+\z/

    m = line.match(ORIGIN_TAG_RE)
    return ['unknown', 'untagged'] unless m

    row = origins[[m[1], m[2].to_i, m[3], m[4]]]
    return ['unknown', 'no_table_row'] unless row

    status, category, _definition = row
    return ['unknown', status] unless status == 'exact'
    return ['unknown', 'reg_mismatch'] unless recv == "r#{m[3]}"

    [category, status]
  end

  # `at` is the index of the assignment whose right-hand side is `rhs`; `fn` and `params` describe its method.
  def origin_of(lines, at, rhs, fn, params, hops)
    case rhs
    when /mrb_iv_get/ then 'ivar_read'
    when /_ivars\*\)DATA_PTR/ then 'embedded_ivar'
    when /bc2cpp_getidx|bc2cpp_ary_entry|mrb_hash_get/ then 'indexed_result'
    when /bc2cpp_cconst|mrb_const_get|bc2cpp_const_try/ then 'constant'
    when /upvar/ then 'captured_upvar'
    when 'self' then 'self'
    when /\Ar\d+\z/ then follow_copy(lines, at, rhs, fn, params, hops)
    when /\A\w+\z/ then params.include?(rhs) ? 'parameter' : 'other'
    when /_impl\(/ then 'direct_call_result'
    when /bc2cpp_send|mrb_funcall|bc2cpp_slow|bc2cpp_eqq/ then 'dynamic_call_result'
    when /mrb_ary_new|mrb_hash_new|mrb_str_new|mrb_obj_new|mrb_float_value|mrb_fixnum_value|mrb_int_value|mrb_nil_value|mrb_bool_value|mrb_true_value|mrb_false_value/
      'literal_or_fresh'
    else 'other'
    end
  end

  # Out of hops (a long or cyclic copy chain) the copy is left unresolved, so `register_copy` stays a floor.
  def follow_copy(lines, at, reg, fn, params, hops)
    return 'register_copy' unless hops.positive?

    found = last_assignment(lines, at, fn || 0, reg)
    return 'unknown' unless found

    origin_of(lines, found[0], found[1], fn, params, hops - 1)
  end

  # Nearest preceding family comment (`// POLY_SMALL_N ...`) within the 25 lines before `i`.
  def marker_before(lines, i)
    lines[[i - 25, 0].max...i].reverse.each do |c|
      next if c.include?('POLY_DIAG')

      if c =~ FAM_RE
        return Regexp.last_match(1)
      elsif c =~ %r{^\s*// RGSS }
        return 'RGSS'
      end
    end
    'NONE'
  end

  # With +origins+ (origin_table), the receiver origin comes from the exact walk and the join tags are kept;
  # without it, the text walk runs over the untagged text.
  def scan(src, origins: nil)
    lines = (origins ? src : strip_tags(src)).lines
    names = sym_names(src)
    first_method = first_method_line(lines)
    raise 'bc2cpp_sym_names table not found' if names.empty?
    raise 'no generated method found' unless first_method

    sites = []
    helper_sends = Hash.new(0)
    cur = nil
    open_form = open_form_mask(lines, first_method)
    lines.each_with_index do |l, i|
      next if open_form[i]

      cur = fn_name(l) || cur
      next unless l =~ SEND_RE

      idx = Regexp.last_match(1).to_i
      argc = Regexp.last_match(2).to_i
      name = names[idx]
      if i < first_method
        helper_sends[[cur, name]] += 1
        next
      end
      sites << classify_send(lines, i, l, cur, name, argc, origins)
    end
    Scan.new(lines: lines, names: names, first_method: first_method, sites: sites, helper_sends: helper_sends)
  end

  def classify_send(lines, i, l, cur, name, argc, origins = nil)
    prev = lines[0...i].reverse.find { |x| x !~ /^\s*$/ }.to_s
    class_arm = prev =~ /(?:if|else if) \(.*(?:bc2cpp_owner_class_\d+\(M\) == mrb_obj_class|native_class ==)/ ? true : false
    else_arm = prev =~ /\belse\s*\{?\s*$/ || prev =~ /if \(!\w*(?:done|ok)\w*\)/ ? true : false
    ctx = lines[[i - 25, 0].max...i].reverse
    diag = ctx.first(10).find { |c| c.include?('POLY_DIAG') }
    marker = marker_before(lines, i)
    guard = ctx.first(8).reject { |c| c =~ %r{^\s*//} }.join
    shape = case guard
            when /bc2cpp_owner_class_\d+\(M\) == mrb_obj_class/ then 'owner_class_chain'
            when /native_class ==|rgss::native_\w+_class\(\)/ then 'rgss_native_class_guard'
            when /M->(?:array|hash|string|range)_class/ then 'core_exact_class_chain'
            when /mrb_integer_p|mrb_float_p|mrb_fixnum_p/ then 'numeric_tag_guard'
            when /mrb_obj_class\(M, \w+\) ==|->c == / then 'other_class_guard'
            else 'no_guard_nearby'
            end
    why = if diag
            "#{diag[/path=(\w+)/, 1]}/#{diag[/receiver=(\w+)/, 1]}/#{diag[/origin=([\w:.]+)/, 1] || '-'}"
          else
            'no_diag'
          end
    kept = l[/CLOSED_WORLD kept: (\w+)/, 1]
    recv = l[/bc2cpp_send\(M, (\w+)/, 1]
    origin, origin_status = origins ? exact_origin(l, recv, origins) : [receiver_origin(lines, i + 1, recv), 'text_walk']
    category = if kept then "closed_world_kept:#{kept}"
               elsif class_arm then 'known_class_arm_still_by_name'
               elsif shape == 'rgss_native_class_guard' then 'rgss_native_exact_class_else'
               elsif shape == 'core_exact_class_chain'
                 %w[ivar_read embedded_ivar].include?(origin) ? 'core_tag_chain_else:receiver_is_ivar' : 'core_tag_chain_else:receiver_other'
               elsif diag then "poly_diag:#{why.split('/').first(2).join('/')}"
               elsif shape == 'owner_class_chain' then 'owner_chain_default_else'
               else "other:#{shape}"
               end
    { line: i + 1, origin: origin, origin_status: origin_status, category: category, kept: kept, fn: cur, name: name, argc: argc, else_arm: else_arm, class_arm: class_arm, marker: marker, shape: shape, why: why,
      excluded: diag && diag[/excluded=(\S+)/, 1] }
  end

  # The by-name call that is not a bc2cpp_send: its method name (a literal or a
  # cached symbol index), best effort, and a reason category from the family marker.
  def classify_funcall(lines, names, i, kind, fn)
    rest = lines[i][/#{kind}\((.*)/, 1].to_s
    name = rest[/\A[^,]+,[^,]+,\s*"((?:[^"\\]|\\.)*)"/, 1] ||
           (idx = rest[/bc2cpp_sym\(M, (\d+)\)/, 1]) && names[idx.to_i] ||
           rest[/MRB_SYM(?:_[A-Z])?\((\w+)\)/, 1] || '?'
    marker = marker_before(lines, i)
    category = lines[[i - 8, 0].max..i].any? { |c| c.include?('BLOCK_FALLBACK') } ? 'block_fallback' : "funcall:#{marker}"
    { line: i + 1, kind: kind, name: name, fn: fn, category: category, marker: marker }
  end
end
