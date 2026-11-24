# frozen_string_literal: true

require 'digest'
require 'set'
require_relative 'cold_compact'

# COLD_COMPACT_CALLS: in a method on the cold list (ColdCompact.cold?), a guarded statement -- an `if (...) {...}`
# chain (a send's owner-guard arms, a nil-receiver arm) or a `{...}` block (a keyword send, a union-class dispatch) --
# whose text recurs at enough cold sites to pay (pays?) moves into one file-scope noinline helper, and each site becomes
# one call of it. It runs last, on each method's finished text, so the helper holds exactly what the site held: the
# same calls of the same compiled bodies, by-name fallbacks, raises and roots. A method not listed keeps its text.
# BC2CPP_COLD_COMPACT_CALLS=0 (or BC2CPP_COLD_COMPACT=0) turns it off.
#
# Soundness (method_scope, refusal): the helper sees file scope instead of the method's, so each name the text reads
# must mean the same there: an `mrb_value` scalar of the method (passed by value), a local the text declares itself,
# `M`, a member, a macro or type, or a called name the method does not declare. One register at most is written, and
# it is returned; every other parameter is `const`, so a write through a reference or pointer fails to compile. No
# label, jump, `return`, loop or explicit `static`, so control leaves only at the end or by an exception, and no
# method whose handler reads registers after one (a partial write inside the helper would be lost). Dedup by body is
# sound because the text decides all the state a site has: the caches its macros declare are keyed by their arguments.
module ColdCompactCalls
  PREFIX = 'bc2cpp_ccall_'
  KEYWORDS = %w[if else true false nullptr sizeof].to_set.freeze
  CONTROL = %w[goto return break continue switch case default for while do static volatile try catch throw
               asm __asm__ __LINE__ __COUNTER__ __func__ setjmp longjmp].to_set.freeze
  DECL_TYPES = %w[mrb_value mrb_int mrb_float mrb_sym mrb_bool bool int unsigned size_t uint32_t int32_t uint8_t
                  int8_t uint16_t int16_t uint64_t int64_t uintptr_t intptr_t double float auto char long].to_set.freeze
  # Symbol macros whose argument is a symbol's spelling, not a name.
  SYM_MACRO = /\bMRB_(?:SYM|IVSYM|GVSYM|CVSYM|OPSYM|QSYM)(?:_[QBE])?\(\s*\w*\s*\)/
  IDENT = /(?<![\w$])[A-Za-z_][\w$]*/
  # What follows the name in a declaration.
  DECL_AFTER = /\s*(?:=(?!=)|;|\[|\{|,|\)|:(?!:))/
  MIN_SITES = 2
  # Between a type and the name it declares: blanks, at most one `&` (never `&&`) or a run of `*`.
  TYPE_GAP = /(?:[ \t]+|[ \t]*(?:\*+|&(?!&))[ \t]*)/
  # File-scope names a statement may read besides calls, macros and types.
  GLOBALS = %w[stderr stdout static_cast reinterpret_cast const_cast].to_set.freeze
  NOT_TYPES = %w[return else goto case do throw new delete sizeof].to_set.freeze

  module_function

  def enabled?
    ColdCompact.enabled? && ENV['BC2CPP_COLD_COMPACT_CALLS'] != '0'
  end

  def stats
    @stats ||= Hash.new(0)
  end

  # Rewrites the cold methods of `compiled` (entries with :owner, :name, :code) in place and returns the helpers'
  # definitions, to print ahead of the methods.
  def apply(compiled)
    return '' unless enabled?

    cold = compiled.select { |m| m[:code] && ColdCompact.cold?("#{m[:owner]}##{m[:name]}") }
    plans = cold.to_h { |m| [m, candidates(m[:code])] }
    sizes = plans.values.flatten.to_h { |c| [c[:name], c[:bytes]] }
    counts = Hash.new(0)
    plans.each_value { |cands| cands.each { |c| counts[c[:name]] += 1 } }
    # A helper pays when its sites save more than it costs. A statement inside a chosen one is no site of its own,
    # so the counts become the statements outside every chosen one until the choice settles.
    chosen = {}
    6.times do
      keep = counts.select { |name, n| pays?(sizes.fetch(name), n) }.keys.to_set
      chosen = plans.transform_values { |cands| choose(cands, keep) }
      now = Hash.new(0)
      plans.each do |m, cands|
        cands.each { |c| now[c[:name]] += 1 unless chosen[m].any? { |t| !t.equal?(c) && inside?(c, t) } }
      end
      break if now == counts

      counts = now
    end
    helpers = {}
    chosen.each do |m, cs|
      next if cs.empty?

      code = m[:code].dup
      cs.sort_by { |c| -c[:start] }.each do |c|
        code[c[:start]...c[:stop]] = c[:call]
        helpers[c[:name]] ||= c[:source]
        stats[:outlined] += 1
      end
      m[:code] = code
    end
    stats[:helpers] = helpers.size
    helpers.keys.sort.map { |k| helpers.fetch(k) }.join
  end

  # Rough Thumb-2 bytes: a call with its argument moves, a test and branch, a move; a site's call; a helper's frame.
  CALL_BYTES = 8
  SITE_BYTES = 8
  FRAME_BYTES = 8
  CHEAP = %w[mrb_nil_p mrb_test mrb_fixnum_p mrb_integer_p mrb_bool_value mrb_fixnum_value mrb_nil_value mrb_true_value
             mrb_false_value mrb_undef_p mrb_likely mrb_unlikely mrb_fixnum mrb_integer mrb_symbol_value DATA_PTR
             mrb_obj_ptr mrb_array_p mrb_hash_p mrb_string_p mrb_type mrb_immediate_p mrb_float_p mrb_symbol_p
             mrb_true_p mrb_false_p mrb_obj_value mrb_int_value mrb_cptr].to_set.freeze

  def estimate(plain)
    calls = plain.scan(/(?<![\w$.>])([A-Za-z_]\w*)\s*\(/).flatten.reject { |n| KEYWORDS.include?(n) || n == 'if' }
    (calls.count { |n| !CHEAP.include?(n) } * CALL_BYTES) + (calls.count { |n| CHEAP.include?(n) } * 2) +
      (plain.scan(/\bif\b/).size * 4) + (plain.scan(/(?<![=!<>])=(?!=)/).size * 2)
  end

  def pays?(bytes, sites)
    sites >= MIN_SITES && sites * (bytes - SITE_BYTES) > bytes + FRAME_BYTES
  end

  def inside?(inner, outer)
    inner[:start] >= outer[:start] && inner[:stop] <= outer[:stop]
  end

  # The outermost candidates whose helper is in `keep`; inside one that is not, its inner ones.
  def choose(cands, keep)
    taken = []
    cands.sort_by { |c| [c[:start], -c[:stop]] }.each do |c|
      next if taken.any? { |t| inside?(c, t) }

      taken << c if keep.include?(c[:name])
    end
    taken
  end

  def summary
    refused = stats.reject { |k, _| %i[outlined helpers].include?(k) }.sort_by { |k, n| [-n, k.to_s] }
                   .first(12).map { |k, n| "#{k} #{n}" }
    "== cold compact calls (COLD_COMPACT_CALLS): #{stats[:outlined]} sites into #{stats[:helpers]} helpers; " \
      "refused: #{refused.empty? ? 'none' : refused.join(', ')} =="
  end

  # Every statement in `code` that may move, as {start, stop, name, call, source, bytes}.
  def candidates(code)
    scope = method_scope(code)
    return [] unless scope

    out = []
    pos = 0
    while (m = /^([ \t]*)(?:if \(|\{)/.match(code, pos))
      start = m.begin(0)
      pos = m.end(0)
      stop = m[0].end_with?('(') ? chain_end(code, m.end(0) - 1) : balanced_end(code, m.end(0) - 1, '{', '}')
      next stats[:shape] += 1 unless stop

      # The statement must end its line.
      eol = code.index("\n", stop)
      next stats[:shape] += 1 unless eol && code[stop...eol].strip.empty?

      cand = outline(code[start...eol], m[1], scope)
      next unless cand

      out << cand.merge(start: start, stop: eol)
    end
    out
  end

  # The end (exclusive) of the `if (...) {...} [else if (...) {...}]* [else {...}]` chain whose `(` is at `at`.
  def chain_end(code, at)
    loop do
      close = balanced_end(code, at, '(', ')')
      return nil unless close

      brace = skip_space(code, close)
      return nil unless code[brace] == '{'

      stop = balanced_end(code, brace, '{', '}')
      return nil unless stop

      nxt = skip_space(code, stop)
      return stop unless code[nxt, 4] == 'else' && code[nxt + 4] !~ /[\w$]/

      nxt = skip_space(code, nxt + 4)
      if code[nxt, 2] == 'if' && code[nxt + 2] !~ /[\w$]/
        at = skip_space(code, nxt + 2)
        return nil unless code[at] == '('
      elsif code[nxt] == '{'
        stop = balanced_end(code, nxt, '{', '}')
        return stop
      else
        return nil
      end
    end
  end

  def skip_space(code, i)
    i += 1 while i < code.size && code[i].match?(/\s/)
    i
  end

  # The index just past the bracket closing the one at `at`, skipping string, character and comment text.
  def balanced_end(code, at, open, close)
    depth = 0
    i = at
    while i < code.size
      c = code[i]
      if c == '"' || c == "'"
        i = literal_end(code, i)
        return nil unless i

        next
      elsif c == '/' && code[i + 1] == '*'
        j = code.index('*/', i + 2)
        return nil unless j

        i = j + 2
        next
      elsif c == '/' && code[i + 1] == '/'
        j = code.index("\n", i)
        return nil unless j

        i = j
        next
      elsif c == open
        depth += 1
      elsif c == close
        depth -= 1
        return i + 1 if depth.zero?
      end
      i += 1
    end
    nil
  end

  def literal_end(code, i)
    q = code[i]
    j = i + 1
    while j < code.size
      ch = code[j]
      return j + 1 if ch == q
      return nil if ch == "\n"

      j += ch == '\\' ? 2 : 1
    end
    nil
  end

  # What the method's text declares: {values: the `mrb_value` scalars, other: every name declared any other way},
  # or nil for a method whose locals could change under a call (setjmp, volatile).
  def method_scope(code)
    return refuse_method(:method_volatile) if code.match?(/\b(?:volatile|setjmp|_setjmp|MRB_TRY)\b/)
    # A handler that goes on to read registers (a rescue, a block's break) would see a partial write the helper
    # never made; the method-return and proc-exit handlers only return their own value.
    return refuse_method(:method_handler) if code.scan(/\bcatch\s*\(([^)]*)\)/).flatten.any? { |c|
      !c.match?(/\A\s*bc2cpp_(?:method_return|proc_exit)\s*&\s*\w+\s*\z/)
    }

    plain = strip_literals(code)
    values = Set.new
    other = Set.new
    plain.scan(/(?<![\w$])mrb_value[ \t]+([A-Za-z_]\w*)(?=\s*(?:=(?!=)|;|,|\)))/) { |(n)| values << n }
    plain.scan(
      /(?:(?<![\w$])([A-Za-z_][\w$]*)|[*&>])#{TYPE_GAP.source}([A-Za-z_]\w*)(?=#{DECL_AFTER.source})/
    ) do |type, n|
      next if type == 'mrb_value' || NOT_TYPES.include?(type) || type&.match?(/\A[A-Z][A-Z0-9_]+\z/)

      other << n
    end
    # `Type name(args)`: an object built in place, or a function this text defines (printed after the helpers).
    plain.scan(/(?<![\w$])([A-Za-z_][\w$:]*)#{TYPE_GAP.source}([A-Za-z_]\w*)\s*\(/) do |type, n|
      other << n unless NOT_TYPES.include?(type) || type.match?(/\A[A-Z][A-Z0-9_]+\z/)
    end
    # `mrb_value *p` / `mrb_value& r` / `mrb_value a[2]` are not scalars.
    plain.scan(/(?<![\w$])mrb_value\s*[*&]\s*([A-Za-z_]\w*)|(?<![\w$])mrb_value[ \t]+([A-Za-z_]\w*)\s*\[/) do |a, b|
      other << (a || b)
    end
    { values: values - other, other: other }
  end

  def refuse_method(reason)
    stats[reason] += 1
    nil
  end

  # Comments removed, string and character literal contents blanked (lengths kept).
  def strip_literals(text)
    text.gsub(TOKEN_TEXT) { |s| s.start_with?('/') ? ' ' * s.size : s[0] + (' ' * (s.size - 2)) + s[-1] }
  end

  # A string or character literal, or a comment: scanned together, so a `//` inside a string is no comment.
  TOKEN_TEXT = %r{"(?:[^"\\\n]|\\.)*"|'(?:[^'\\\n]|\\.)*'|/\*.*?\*/|//[^\n]*}m

  def strip_comments(text)
    text.gsub(/(?:[ \t]*(?:#{TOKEN_TEXT.source}))/m) { |s| s.lstrip.start_with?('/') ? '' : s }
  end

  # The helper for the statement `text` (indented `indent`), or nil when it stays inline.
  def outline(text, indent, scope)
    body = strip_comments(text)
    # An `#if` on an MRB_ configuration macro means the same at file scope; its lines are no names to check.
    plain = strip_literals(body).gsub(/^[ \t]*#[^\n]*/) { |l| ' ' * l.size }
    refusal = refusal(body, plain, scope)
    if refusal
      stats[refusal] += 1
      return nil
    end

    declared = declared_names(plain)
    vars = []
    plain.scan(IDENT) do |id|
      vars << id if scope[:values].include?(id) && !declared.key?(id) && !member_at?(plain, Regexp.last_match.begin(0))
    end
    vars.uniq!
    dest = (assigned(plain) & vars).first
    params = vars.each_with_index.to_h { |v, i| [v, "a#{i}"] }
    renamed = rename(body, plain, params)
    lines = renamed.lines.map(&:rstrip).reject(&:empty?)
    lines = lines.map { |l| l.start_with?(indent) ? "  #{l[indent.size..]}" : "  #{l.lstrip}" }
    inner = lines.join("\n")
    sig = vars.map { |v| v == dest ? "mrb_value #{params[v]}" : "const mrb_value #{params[v]}" }
    key = "#{sig.join(',')}|#{inner}"
    name = "#{PREFIX}#{Digest::SHA256.hexdigest(key)[0, 16]}"
    ret = dest ? 'mrb_value' : 'void'
    source = "static __attribute__((noinline, cold)) #{ret} #{name}(#{(['mrb_state* M'] + sig).join(', ')}) {\n" \
             "#{inner}\n#{dest ? "  return #{params[dest]};\n" : ''}}\n\n"
    args = (['M'] + vars).join(', ')
    call = dest ? "#{indent}#{dest} = #{name}(#{args});" : "#{indent}#{name}(#{args});"
    { name: name, call: call, source: source, bytes: estimate(plain) }
  end

  def member_at?(plain, at)
    before = plain[0...at].rstrip
    before.end_with?('->') || (before.end_with?('.') && !before.end_with?('..')) || before.end_with?('::')
  end

  # Why `body` (its literal-blanked form `plain`) must stay inline, or nil.
  def refusal(body, plain, scope)
    lines = body.lines.map(&:rstrip)
    return :directive if lines.any? { |l| l.lstrip.start_with?('#') && !l.match?(ColdCompact::DIRECTIVE) }
    return :braces unless ColdCompact.balanced?(lines)
    return :label if plain.match?(/(?:^|[;{}])\s*[A-Za-z_]\w*\s*:(?!:)/) &&
                     plain.lines.any? { |l| l.match?(/^\s*[A-Za-z_]\w*\s*:(?!:)/) }
    return :lambda if plain.match?(/\[\s*[&=]?\s*\]\s*[({]|\[\s*[&=]\s*[,\]]/)
    return :compound_write if plain.match?(/\+\+|--|(?:[-+*\/%&|^]|<<|>>)=(?!=)/)

    declared = declared_names(plain)
    return :shadow unless declared.all? { |n, at| plain.index(/(?<![\w$])#{n}(?![\w$])/) == at }

    called = Set.new
    plain.scan(IDENT) do |id|
      at = Regexp.last_match.begin(0)
      rest = plain[(at + id.size)..]
      next if member_at?(plain, at)
      return :"control #{id}" if CONTROL.include?(id)
      next if KEYWORDS.include?(id) || id == 'M'

      if rest.match?(/\A\s*\(/)
        return :"local call #{id}" if scope[:other].include?(id) || scope[:values].include?(id)

        called << id
        next
      end
      next if scope[:values].include?(id) || declared.key?(id)
      return :"local #{id}" if scope[:other].include?(id)
      next if DECL_TYPES.include?(id) || id == 'struct' || id == 'const'
      next if id.match?(/\A[A-Z][A-Z0-9_]+\z/) # macro and enum constants (MRB_TT_*, BC2CPP_COLD_ARM)
      next if rest.match?(/\A\s*\*+\s*\)/) || plain[0...at].match?(/(?<![\w$])struct\s+\z/) # a type
      next if GLOBALS.include?(id) || rest.match?(/\A::/) # a namespace qualifier is never a local
      next if symbol_spelling?(plain, at)

      return :"name #{id}"
    end
    return :address if plain.match?(/(?<![&\w)\]])&\s*[A-Za-z_]\w*\b(?!\s*(?:\(|->|\.))/) &&
                       plain.scan(/(?<![&\w)\]])&\s*([A-Za-z_]\w*)\b(?!\s*\()/).flatten.any? { |n|
                         scope[:values].include?(n)
                       }

    written = assigned(plain)
    return :write unless written
    regs = written.reject { |n| declared.key?(n) }
    return :write unless regs.all? { |n| n.match?(/\Ar\d+\z/) && scope[:values].include?(n) }
    return :dest if regs.uniq.size > 1
    # bc2cpp_fixnum_* write their third argument through a reference: it must be the returned register.
    return :out_param unless ColdCompact.out_params(plain).all? { |arg| regs.include?(arg) || declared.key?(arg) }

    nil
  end

  # The locals `plain` declares, each with the position of its name in the declaration.
  DECLARATION = /(?<![\w$])(?:#{DECL_TYPES.to_a.join('|')}|struct\s+\w+)\s*[*&]*\s*([A-Za-z_]\w*)(?=\s*(?:=(?!=)|;|\[))/
  def declared_names(plain)
    out = {}
    plain.scan(DECLARATION) { |(n)| out[n] ||= Regexp.last_match.begin(1) }
    out
  end

  def symbol_spelling?(plain, at)
    plain.to_enum(:scan, SYM_MACRO).any? { Regexp.last_match.begin(0) < at && at < Regexp.last_match.end(0) }
  end

  # The names `plain` assigns with `=`, or nil when a left-hand side is not a plain name.
  def assigned(plain)
    plain.to_enum(:scan, /(?<![=!<>])=(?!=)/).map do
      lhs = Regexp.last_match.pre_match.rstrip
      name = lhs[/(?<![\w$.>])([A-Za-z_]\w*)\z/, 1]
      if name.nil?
        # A member store (`...->x = v`, `p.x = v`) writes no local.
        next :member if lhs.match?(/(?:->|\.)\s*[A-Za-z_]\w*\z/) || lhs.end_with?(']')
        return nil
      end

      name
    end.reject { |n| n == :member }
  end

  # `body` with each renamed variable replaced; positions come from `plain`, which has the same layout.
  def rename(body, plain, params)
    out = +''
    last = 0
    plain.scan(IDENT) do |id|
      at = Regexp.last_match.begin(0)
      next unless params.key?(id) && !member_at?(plain, at)

      out << body[last...at] << params.fetch(id)
      last = at + id.size
    end
    out << body[last..]
  end
end
