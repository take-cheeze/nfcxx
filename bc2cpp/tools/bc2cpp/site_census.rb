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

  # Where the receiver register was last assigned before the guard chain. Heuristic: a
  # register copy hides the real origin, so "register_copy" is a floor on what is unknown.
  def receiver_origin(lines, line, recv)
    i = line - 2
    i -= 1 while i.positive? && line - i < 80 && !(lines[i] =~ %r{^(if \(|\{$|// [^ ]+ -- generated)} && lines[i - 1] !~ /\} else|else\s*$/)
    (1..60).each do |k|
      x = lines[i - k] or break
      next unless x =~ /^\s*#{recv} = (.*);\s*$/

      return case Regexp.last_match(1)
             when /mrb_iv_get/ then 'ivar_read'
             when /_ivars\*\)DATA_PTR/ then 'embedded_ivar'
             when /bc2cpp_getidx|bc2cpp_ary_entry|mrb_hash_get/ then 'indexed_result'
             when /bc2cpp_cconst|mrb_const_get|bc2cpp_const_try/ then 'constant'
             when /upvar/ then 'captured_upvar'
             when /\A(?:r\d+|self)\z/ then 'register_copy'
             when /_impl\(/ then 'direct_call_result'
             when /bc2cpp_send|mrb_funcall|bc2cpp_slow|bc2cpp_eqq/ then 'dynamic_call_result'
             when /mrb_ary_new|mrb_hash_new|mrb_str_new|mrb_obj_new|mrb_float_value|mrb_fixnum_value|mrb_int_value/ then 'literal_or_fresh'
             else 'other'
             end
    end
    'unknown'
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

  def scan(src)
    lines = src.lines
    names = sym_names(src)
    first_method = first_method_line(lines)
    raise 'bc2cpp_sym_names table not found' if names.empty?
    raise 'no generated method found' unless first_method

    sites = []
    helper_sends = Hash.new(0)
    cur = nil
    lines.each_with_index do |l, i|
      cur = fn_name(l) || cur
      next unless l =~ SEND_RE

      idx = Regexp.last_match(1).to_i
      argc = Regexp.last_match(2).to_i
      name = names[idx]
      if i < first_method
        helper_sends[[cur, name]] += 1
        next
      end
      sites << classify_send(lines, i, l, cur, name, argc)
    end
    Scan.new(lines: lines, names: names, first_method: first_method, sites: sites, helper_sends: helper_sends)
  end

  def classify_send(lines, i, l, cur, name, argc)
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
    origin = receiver_origin(lines, i + 1, l[/bc2cpp_send\(M, (\w+)/, 1])
    category = if kept then "closed_world_kept:#{kept}"
               elsif class_arm then 'known_class_arm_still_by_name'
               elsif shape == 'rgss_native_class_guard' then 'rgss_native_exact_class_else'
               elsif shape == 'core_exact_class_chain'
                 %w[ivar_read embedded_ivar].include?(origin) ? 'core_tag_chain_else:receiver_is_ivar' : 'core_tag_chain_else:receiver_other'
               elsif diag then "poly_diag:#{why.split('/').first(2).join('/')}"
               elsif shape == 'owner_class_chain' then 'owner_chain_default_else'
               else "other:#{shape}"
               end
    { line: i + 1, origin: origin, category: category, kept: kept, fn: cur, name: name, argc: argc, else_arm: else_arm, class_arm: class_arm, marker: marker, shape: shape, why: why,
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
