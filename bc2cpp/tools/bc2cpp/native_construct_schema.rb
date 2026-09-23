# frozen_string_literal: true

# NATIVE_CONSTRUCT_SCHEMA_AUDIT (audit only, never read by codegen).

# ---------------------------------------------------------------------------
# NATIVE_CONSTRUCT_SCHEMA_AUDIT: derive each NATIVE_CONSTRUCT_TARGETS row's
# (arity, arg_type) from the native `mrb_get_args` format string and compare it
# with the hand-written row. A row narrower than the format (Tone's "|ffff"
# vs arity 4) is conservative and passes; a wider row or a type disagreement
# is reported as MISMATCH. Audit-only: never consulted by codegen.
#
# Every failure mode (lambda init, Ruby-defined initialize, missing or
# unrecognized format, non-uniform types) resolves to :unresolved, so MISMATCH
# always means a real disagreement read off the source.
# ---------------------------------------------------------------------------
module NativeConstructSchema
  # mrb_get_args format characters -> NATIVE_CONSTRUCT_TARGETS arg_type tokens.
  # `i` is int-coerced; pass-through arguments are :object. `*` and `&` add no
  # position. Anything else makes the derivation :unresolved.
  FORMAT_TYPES = {
    'i' => :int, 'f' => :float,
    'o' => :object, 'n' => :object, 's' => :object, 'S' => :object,
    'c' => :object, 'b' => :object, 'z' => :object, 'p' => :object,
    'C' => :object, 'a' => :object, 'A' => :object, 'Z' => :object,
  }.freeze

  # `"|o"` -> ([0, 1], :object); `"ii"` -> ([2, 2], :int); `"i|ii"` -> ([1, 3],
  # :int). Non-uniform types and unknown characters are nil: a single-arg_type
  # row cannot express them.
  def self.derive(format)
    return nil unless format =~ /\A[|oifnscbzpCaAZ*!&]*\z/

    pre, post = format.split('|', 2)
    req = post.nil? ? pre : pre + post
    min = pre.delete('*&').length
    max = post.nil? ? min : min + post.delete('*&').length
    types = req.delete('*&').chars.map { |c| FORMAT_TYPES[c] }
    return nil if types.any?(&:nil?) || types.uniq.size > 1

    [[min, max], types.first || :object]
  end

  # The brace-matched body of C++ function `fn`, or nil. Literals and comments
  # are skipped so a `}` in them does not end the match. First definition wins;
  # a wrong body can only produce a MISMATCH, never a miscompile.
  def self.fn_body(src, fn)
    idx = 0
    loop do
      i = src.index(fn, idx)
      return nil unless i

      rest = src[i..]
      m = rest.match(/\A#{Regexp.escape(fn)}\s*\([^)]*\)\s*\{/)
      if m
        depth = 0
        j = i + m[0].length - 1
        start = j
        in_str = nil
        in_line = false
        in_block = false
        prev = nil
        src[start..].each_char.with_index do |ch, k|
          nxt = src[start + k + 1]
          if in_line
            in_line = false if ch == "\n"
          elsif in_block
            in_block = false if prev == '*' && ch == '/'
          elsif in_str
            in_str = nil if ch == in_str && prev != '\\'
          elsif ch == '"' || ch == "'"
            in_str = ch
          elsif ch == '/' && nxt == '/'
            in_line = true
          elsif ch == '/' && nxt == '*'
            in_block = true
          elsif ch == '{'
            depth += 1
          elsif ch == '}'
            depth -= 1
            return src[start..(start + k)] if depth.zero?
          end
          prev = ch
        end
        return nil
      end
      idx = i + 1
    end
  end

  # Scrape [init_fn, format] for native class `klass`: the class variable from
  # mrb_define_class_under, the init from mrb_define_method(..., "initialize",
  # FN), the format from FN's first mrb_get_args. nil means :unresolved.
  def self.scrape(native_paths, klass)
    Array(native_paths).each do |path|
      src = begin
        File.read(path, encoding: 'UTF-8')
      rescue StandardError
        next
      end
      cm = src.match(/(\w+)\s*=\s*mrb_define_class_under\s*\(\s*\w+\s*,\s*\w+\s*,\s*"#{Regexp.escape(klass)}"/)
      next unless cm

      im = src.match(/mrb_define_method\s*\(\s*\w+\s*,\s*#{Regexp.escape(cm[1])}\s*,\s*"initialize"\s*,\s*(\w+)/)
      next unless im

      body = fn_body(src, im[1])
      next unless body

      fm = body.match(/mrb_get_args\s*\(\s*\w+\s*,\s*"([^"]*)"/)
      next unless fm

      return [im[1], fm[1]]
    end
    nil
  end

  # :ok (arities within the derived range, types agree), :mismatch (with
  # details) or :unresolved.
  def self.audit(native_paths, klass, row)
    scraped = scrape(native_paths, klass)
    return [:unresolved, 'no (init_fn, format) scraped'] unless scraped

    fn, fmt = scraped
    derived = derive(fmt)
    return [:unresolved, "#{fn} format #{fmt.inspect} underivable"] unless derived

    (range, type) = derived
    arities = Array(row[:arity])
    unless arities.all? { |a| a.between?(range[0], range[1]) }
      return [:mismatch, "#{fn} format #{fmt.inspect} admits #{range[0]}..#{range[1]}, row pins #{arities.inspect}"]
    end
    unless row[:arg_type] == type
      return [:mismatch, "#{fn} format #{fmt.inspect} is #{type.inspect}, row says #{row[:arg_type].inspect}"]
    end

    [:ok, "#{fn} #{fmt.inspect}"]
  end
end
