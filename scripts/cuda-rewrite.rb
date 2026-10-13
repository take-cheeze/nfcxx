# CUDA launch rewrite for nfcxx: turns the kernel launch syntax of a .cu file into a call of
# __nfcxx_cuda_launch (lib/cuda/nfcxx_cuda.h), so the EDG front end sees only C++.
#   name<<<grid, block[, shmem[, stream]]>>>(args)  ->  __nfcxx_cuda_launch(name, grid, block, shmem, stream, args)
# Usage: scripts/mrb scripts/cuda-rewrite.rb FILE.cu > FILE.cpp
#
# A small scanner, not a parser: string, character and raw string literals and comments are copied as they are, so
# `<<<` inside them is not a launch. Newlines inside a launch are kept (as the same number after the call), so line
# numbers after it do not move. The output starts with `#line 1 "FILE.cu"`, so diagnostics name the original file.
# Forms not handled exit 3 with `refused: ...` on stderr: a template kernel name (`k<float><<<...>>>`), a launch
# without a kernel name, and a configuration with fewer than 2 or more than 4 items.
# No regexp: scripts run on mruby, which has none in core.

# The character before position i, skipping whitespace; "" at the start.
def text_before(text, i)
  j = i - 1
  j -= 1 while j >= 0 && white?(text[j])
  j < 0 ? "" : text[j]
end

def white?(c)
  c == " " || c == "\t" || c == "\n" || c == "\r"
end

def ident_char?(c)
  return false if c.nil?
  o = c.ord
  (o >= 48 && o <= 57) || (o >= 65 && o <= 90) || (o >= 97 && o <= 122) || o == 95
end

def refuse(msg)
  $stderr.puts "refused: #{msg}"
  exit(3)
end

# If a literal or comment starts at s[i], returns the index just past it; otherwise nil.
def skip_literal(s, i)
  n = s.length
  c = s[i]
  if c == "/" && s[i + 1] == "/"
    j = s.index("\n", i)
    return j.nil? ? n : j
  end
  if c == "/" && s[i + 1] == "*"
    j = s.index("*/", i + 2)
    refuse("unterminated comment") if j.nil?
    return j + 2
  end
  if c == "R" && s[i + 1] == "\"" && !(i > 0 && ident_char?(s[i - 1]))
    paren = s.index("(", i + 2)
    refuse("raw string delimiter") if paren.nil?
    delim = s[(i + 2)...paren]
    close = s.index(")" + delim + "\"", paren + 1)
    refuse("unterminated raw string") if close.nil?
    return close + delim.length + 2
  end
  # A quote after a digit is a digit separator (1'000), not a character literal.
  return nil if c == "'" && i > 0 && s[i - 1].ord >= 48 && s[i - 1].ord <= 57
  if c == "\"" || c == "'"
    j = i + 1
    while j < n
      if s[j] == "\\"
        j += 2
      elsif s[j] == c
        return j + 1
      else
        j += 1
      end
    end
    refuse("unterminated literal")
  end
  nil
end

# Index of the bracket that closes the one at s[open] (which is `(`), skipping literals; nil if none.
def matching_paren(s, open)
  depth = 0
  i = open
  while i < s.length
    e = skip_literal(s, i)
    if e
      i = e
      next
    end
    c = s[i]
    if c == "(" || c == "[" || c == "{"
      depth += 1
    elsif c == ")" || c == "]" || c == "}"
      depth -= 1
      return i if depth == 0
    end
    i += 1
  end
  nil
end

# Splits the launch configuration text at its top-level commas.
def split_config(s, from, to)
  items = []
  depth = 0
  start = from
  i = from
  while i < to
    e = skip_literal(s, i)
    if e
      i = e
      next
    end
    c = s[i]
    if c == "(" || c == "[" || c == "{"
      depth += 1
    elsif c == ")" || c == "]" || c == "}"
      depth -= 1
    elsif c == "," && depth == 0
      items << s[start...i].strip
      start = i + 1
    end
    i += 1
  end
  items << s[start...to].strip
  items
end

# Template kernel launches: `k<T...><<<...>>>(args)` is a call of a generated C-linkage wrapper (see
# template_sites), so the host registration and the device image name the same entry.
$expanded = ""   # the source with local quoted includes expanded, for the template definitions
$sites = {}      # wrapper name => { name:, targs:, decl:, call: }

def split_top(s)
  parts = []
  depth = 0
  start = 0
  i = 0
  while i < s.length
    e = skip_literal(s, i)
    if e
      i = e
      next
    end
    c = s[i]
    if c == "(" || c == "[" || c == "{" || c == "<"
      depth += 1
    elsif c == ")" || c == "]" || c == "}" || c == ">"
      depth -= 1
    elsif c == "," && depth == 0
      parts << s[start...i].strip
      start = i + 1
    end
    i += 1
  end
  parts << s[start...s.length].strip
  parts.reject { |x| x.empty? }
end

def sanitize(s)
  out = ""
  s.each_char do |c|
    out << (ident_char?(c) ? c : "_")
  end
  out.gsub("__", "_")
end

def wrapper_name(name, targs)
  "__nfcxx_k_#{sanitize(name)}_#{sanitize(targs)}"
end

# Index of the first character c at or after from, outside comments and literals; nil if none.
def index_code(s, c, from)
  i = from
  while i < s.length
    e = skip_literal(s, i)
    if e
      i = e
      next
    end
    return i if s[i] == c
    i += 1
  end
  nil
end

# The template header of the first __global__ template named `name` in the source: its parameter names, and its
# parameter list text.
def kernel_template(name)
  # the host pass searches the host-resolved unit (its pieces are balanced); the device pass has resolved already
  src = $kernel_text || $expanded
  # memoized per unit: many launches name the same kernel
  $kernel_memo = {} unless $kernel_memo_for.equal?(src)
  $kernel_memo_for = src
  return $kernel_memo[name] if $kernel_memo.key?(name)
  $kernel_memo[name] = kernel_template_uncached(name, src)
end

def kernel_template_uncached(name, src)
  $kernel_pieces = nil unless $kernel_pieces_for.equal?(src)
  unless $kernel_pieces
    $kernel_pieces = top_pieces(src)
    $kernel_pieces_for = src
  end
  $kernel_pieces.each do |st, en, kind, body|
    next unless kind == :code && body
    t = src[st...en]
    toks = tokens_of(t)
    next unless toks.first == "template" && toks.include?("__global__")
    q = remove_words(t, DEVICE_QUALIFIERS)
    next unless function_name(q) == name
    lt = index_code(q, "<", 0)
    depth = 0
    k = lt
    while k < q.length
      depth += 1 if q[k] == "<"
      depth -= 1 if q[k] == ">"
      break if depth == 0
      k += 1
    end
    parts = split_top(q[(lt + 1)...k])
    names = parts.map { |part| tokens_of(part.split("=")[0]).last }.compact
    pack = parts.index { |part| part.include?("...") }
    open = index_code(q, "(", k)
    close = matching_paren(q, open)
    refuse("unterminated parameter list for #{name}") if close.nil?
    return { names: names, params: q[(open + 1)...close], pack: pack }
  end
  nil
end

# Replaces the template parameter names in the parameter list by the explicit arguments.
# With pack (the index of a parameter pack in names), the pack takes args[pack, size] where size is what the other
# parameters leave: `Ns...` in the text is the pack's values joined; a bare pack name is refused.
def substitute(text, names, args, pack = nil)
  map = {}
  if pack.nil?
    names.each_with_index { |n, idx| map[n] = args[idx] }
  else
    size = args.length - (names.length - 1)
    names.each_with_index do |n, idx|
      if idx < pack
        map[n] = [args[idx]]
      elsif idx == pack
        map[n] = args[pack, size]
      else
        map[n] = [args[idx - 1 + size]]
      end
    end
  end
  out = ""
  i = 0
  while i < text.length
    e = skip_literal(text, i)
    if e
      out << text[i...e]
      i = e
      next
    end
    if ident_char?(text[i]) && !(text[i] >= "0" && text[i] <= "9")
      j = i
      j += 1 while j < text.length && ident_char?(text[j])
      w = text[i...j]
      if pack && names[pack] == w && map.key?(w)
        k = j
        k += 1 while k < text.length && white?(text[k])
        refuse("parameter pack #{w} used without ...") unless text[k, 3] == "..."
        out << map[w].join(", ")
        i = k + 3
        next
      end
      v = map[w]
      out << (v.is_a?(Array) ? v[0].to_s : (v || w))
      i = j
    else
      out << text[i]
      i += 1
    end
  end
  out
end

# The wrapper of a template launch: its declaration (the instance's parameters with the arguments substituted) and
# the names the call passes. Registers it in $sites.
def template_site(name, targs)
  kt = kernel_template(name)
  refuse("template kernel #{name}: no __global__ template of that name in the source") if kt.nil?
  args = split_top(targs)
  # A parameter pack takes the arguments the other parameters leave (at least none); without one, every parameter.
  if kt[:pack] ? args.length < kt[:names].length - 1 : args.length != kt[:names].length
    refuse("template kernel #{name}<#{targs}>: explicit arguments must give every template parameter")
  end
  decl = substitute(kt[:params], kt[:names], args, kt[:pack])
  call = split_top(decl).map do |part|
    n = tokens_of(part.split("=")[0]).last
    refuse("template kernel #{name}: unnamed parameter #{part}") if n.nil?
    n
  end
  w = wrapper_name(name, targs)
  $sites[w] = { name: name, targs: targs, decl: decl, call: call } unless $sites.key?(w)
  w
end

# The template launches of a source: [name, targs] for each `<<<` that follows a template argument list.
# The nearest `template <...>` header before position i (the function or class the launch is in): if the template
# arguments of a launch name one of its parameters, that parameter's name; else nil. A launch like that needs an
# instance that only the instantiation fixes, and the wrapper is a concrete function (see template_site).
def dependent_on_template(text, i, targs)
  cand = template_bodies(text).select { |tb| tb[:open] < i && i < tb[:close] }
  return nil if cand.empty?
  t = cand.max_by { |x| x[:open] }[:tmpl]
  names = split_top(text[(t[:lt] + 1)...t[:close]]).map { |pr| tokens_of(pr.split("=")[0]).last }.compact
  used = tokens_of(targs)
  names.find { |nm| used.include?(nm) }
end

# Index of the `>` closing the `<` at s[open] (nesting counted), or nil.
def matching_angle(s, open)
  depth = 0
  k = open
  while k < s.length
    e = skip_literal(s, k)
    if e
      k = e
      next
    end
    depth += 1 if s[k] == "<"
    if s[k] == ">"
      depth -= 1
      return k if depth == 0
    end
    k += 1
  end
  nil
end

# The directives of a text: start index => end index (a launch in a #define is not a launch in code).
def directive_ends(text)
  out = {}
  top_pieces(text).each { |st, en, kind, _b| out[st] = en if kind == :pp }
  out
end

def template_launches(text)
  found = []
  i = 0
  dirs = directive_ends(text)
  while i < text.length
    if dirs.key?(i)
      i = dirs[i]
      next
    end
    e = skip_literal(text, i)
    if e
      i = e
      next
    end
    if text[i, 3] == "<<<" && text_before(text, i) == ">"
      # the `>` closing the template arguments: the nearest one before `<<<` (a line break may come between)
      gt = i - 1
      gt -= 1 while gt >= 0 && white?(text[gt])
      j = gt
      depth = 0
      while j >= 0
        depth += 1 if text[j] == ">"
        depth -= 1 if text[j] == "<"
        break if depth == 0
        j -= 1
      end
      k = j - 1
      k -= 1 while k >= 0 && white?(text[k])
      e2 = k + 1
      k -= 1 while k >= 0 && ident_char?(text[k])
      name = text[(k + 1)...e2]
      found << [name, text[(j + 1)...gt].strip, i] unless name.empty?
    end
    i += 1
  end
  found
end

# Index of the `}` closing the `{` at s[open], skipping literals; nil if unbalanced.
def matching_brace(s, open)
  depth = 0
  i = open
  while i < s.length
    e = skip_literal(s, i)
    if e
      i = e
      next
    end
    depth += 1 if s[i] == "{"
    if s[i] == "}"
      depth -= 1
      return i if depth == 0
    end
    i += 1
  end
  nil
end

# The bodies of the function templates of the text, in one pass: each `{` whose header (the text since the last `;`
# or brace of its level) starts with `template <...>`, with the body's open and close braces, the header's
# `template` position and its angle brackets. Braces of the text are balanced once the conditionals are resolved.
def template_bodies(text)
  return $template_bodies if $template_bodies_for.equal?(text)
  out = []
  stack = [{ hs: 0 }]
  i = 0
  while i < text.length
    e = skip_literal(text, i)
    if e
      i = e
      next
    end
    c = text[i]
    if c == "{"
      # the header's last `template <`: a comment, a preprocessor line or a declaration may come before it
      tmpl = nil
      k = stack.last[:hs]
      while k < i
        e2 = skip_literal(text, k)
        if e2
          k = e2
          next
        end
        if word_at?(text, k, "template")
          lt = index_code(text, "<", k + 8)
          if lt && lt < i && text[k + 8...lt].strip.empty?
            close = matching_angle(text, lt)
            tmpl = { st: k, lt: lt, close: close } if close && close < i
          end
        end
        k += 1
      end
      stack << { hs: i + 1, open: i, tmpl: tmpl }
    elsif c == "}"
      frame = stack.size > 1 ? stack.pop : stack.last
      out << { open: frame[:open], close: i, tmpl: frame[:tmpl] } if frame[:tmpl]
      stack.last[:hs] = i + 1
    elsif c == ";"
      stack.last[:hs] = i + 1
    end
    i += 1
  end
  $template_bodies_for = text
  $template_bodies = out
  out
end

# The function template that holds position pos: the innermost template body containing pos, as its parameter
# names, declaration texts, the header's position and the function's name. nil when no template encloses pos.
def enclosing_template(text, pos)
  cand = template_bodies(text).select { |tb| tb[:open] < pos && pos < tb[:close] }
  return nil if cand.empty?
  tb = cand.max_by { |x| x[:open] }
  t = tb[:tmpl]
  params = split_top(text[(t[:lt] + 1)...t[:close]])
  # One parameter pack is allowed (`int... Ns`): its index is recorded; its values come from the explicit calls.
  packs = params.each_index.select { |k| params[k].include?("...") }
  refuse("template with #{packs.length} parameter packs (at line #{text[0...pos].count("\n") + 1}): one is supported") if packs.length > 1
  decls = params.map { |pr| pr.split("=")[0].strip }
  names = decls.map { |pr| tokens_of(pr).last }
  header = text[(t[:close] + 1)...tb[:open]]
  { st: t[:st], names: names, decls: decls, fname: function_name(header), qual: member_qualifier(header), open: tb[:open],
    pack: packs.first }
end

# The value of a local compile-time constant `T name = VALUE;` (for example `constexpr bool fallback = true;`) that
# precedes pos in the body of the enclosing template, starting at open: the nearest such declaration before pos, as
# its text, or nil. A call inside an if-branch follows the declaration of its own branch, so the nearest one is the
# one in scope for it.
def local_constant(text, open, pos, name)
  seg = text[open...pos]
  found = nil
  i = 0
  while (k = seg.index(name, i))
    e = k + name.length
    i = e
    next if (k > 0 && ident_char?(seg[k - 1])) || (e < seg.length && ident_char?(seg[e]))
    b = k - 1
    b -= 1 while b >= 0 && white?(seg[b])
    next unless b >= 0 && ident_char?(seg[b])
    a = e
    a += 1 while a < seg.length && white?(seg[a])
    next unless seg[a] == "=" && seg[a + 1] != "="
    semi = seg.index(";", a)
    next if semi.nil?
    found = seg[(a + 1)...semi].strip
  end
  found
end

# `Q<args>::member` in a header of a member defined out of its class template: { name: Q, args: [...] }, else nil.
def member_qualifier(header)
  cc = header.index("::")
  return nil if cc.nil?
  before = header[0...cc].rstrip
  return nil unless before.end_with?(">")
  open = before.length - 1
  depth = 0
  while open >= 0
    depth += 1 if before[open] == ">"
    depth -= 1 if before[open] == "<"
    break if depth == 0
    open -= 1
  end
  return nil if open < 0
  name_start = open
  name_start -= 1 while name_start > 0 && ident_char?(before[name_start - 1])
  name = before[name_start...open]
  return nil if name.empty?
  { name: name, args: split_top(before[(open + 1)...(before.length - 1)]) }
end

# The explicit instantiations `template class|struct Q<args>;` of a class template in the text, as their argument
# lists, mapped onto the member template's names: one instance (a list in the member's own parameter order) each.
def member_instances(outer, text)
  q = outer[:qual]
  out = []
  i = 0
  while i < text.length
    e = skip_literal(text, i)
    if e
      i = e
      next
    end
    if word_at?(text, i, "template")
      k = i + 8
      k += 1 while k < text.length && white?(text[k])
      if word_at?(text, k, "class") || word_at?(text, k, "struct")
        k += (text[k, 5] == "class" ? 5 : 6)
        k += 1 while k < text.length && white?(text[k])
        if word_at?(text, k, q[:name])
          k += q[:name].length
          k += 1 while k < text.length && white?(text[k])
          if text[k] == "<"
            close = matching_angle(text, k)
            out << split_top(text[(k + 1)...close]) if close
          end
        end
      end
    end
    i += 1
  end
  out.map do |args|
    refuse("member template #{outer[:fname]}: the class instance #{q[:name]}<#{args.join(', ')}> does not give all its arguments") unless args.length == q[:args].length
    outer[:names].map do |nm|
      k = q[:args].index(nm)
      refuse("member template #{outer[:fname]}: its parameter #{nm} is not a parameter of #{q[:name]}") if k.nil?
      args[k]
    end
  end.uniq
end

# The explicit template-argument lists of the calls of template function `name` in the text: [targs, position].
# The text is indexed once (every `name<...>(` in it), so the lookups of many launches do not rescan it.
def call_sites(text, name)
  unless $call_index_for.equal?(text)
    index = Hash.new { |h, k| h[k] = [] }
    # Directives are not code: a #define's body names its parameters (DECL_MMQ_CASE(type)), which are not calls.
    pp = top_pieces(text).select { |pc| pc[2] == :pp }.map { |pc| [pc[0], pc[1]] }
    i = 0
    while i < text.length
      e = skip_literal(text, i)
      if e
        i = e
        next
      end
      if pp.any? { |a, b| a <= i && i < b }
        i = pp.find { |a, b| a <= i && i < b }[1]
        next
      end
      if ident_char?(text[i]) && !(i > 0 && ident_char?(text[i - 1])) && !(text[i] >= "0" && text[i] <= "9")
        j = i
        j += 1 while j < text.length && ident_char?(text[j])
        id = text[i...j]
        k = j
        k += 1 while k < text.length && white?(text[k])
        if text[k] == "<"
          close = matching_angle(text, k)
          if close
            m = close + 1
            m += 1 while m < text.length && white?(text[m])
            index[id] << [text[(k + 1)...close].strip, i] if text[m] == "("
          end
        end
        i = j
        next
      end
      i += 1
    end
    $call_index_for = text
    $call_index = index
  end
  $call_index.key?(name) ? $call_index[name] : []
end

# The concrete argument lists that instantiate template function `name`: each explicit call of it, with the
# arguments that name an enclosing template's parameters replaced by that template's own instances (transitively).
# A call through a cycle of templates is refused with the chain.
# The unqualified calls `name(args)` of a template function (no explicit <...>): [args, position] pairs. A declaration
# (its name follows a type keyword, or its parameter list is followed by a body) is not a call.
DECL_WORDS = %w[void static inline int float double bool size_t unsigned long char short template __device__ __host__
                __global__ __forceinline__ constexpr auto]
def plain_call_sites(text, name)
  out = []
  pp = top_pieces(text).select { |pc| pc[2] == :pp }.map { |pc| [pc[0], pc[1]] }
  i = 0
  while i < text.length
    e = skip_literal(text, i)
    if e
      i = e
      next
    end
    if pp.any? { |a, b| a <= i && i < b }
      i = pp.find { |a, b| a <= i && i < b }[1]
      next
    end
    # A qualified call (`cg::reduce(...)`) or a member call (`x.reduce(...)`) names another function.
    qualified = (i >= 2 && text[i - 2, 2] == "::") || (i >= 1 && text[i - 1] == ".") || (i >= 2 && text[i - 2, 2] == "->")
    if text[i, name.length] == name && !qualified && !(i > 0 && ident_char?(text[i - 1])) && !ident_char?(text[i + name.length] || " ")
      k = i + name.length
      k += 1 while k < text.length && white?(text[k])
      if text[k] == "("
        close = matching_paren(text, k)
        if close
          after = close + 1
          after += 1 while after < text.length && white?(text[after])
          b = i - 1
          b -= 1 while b >= 0 && white?(text[b])
          e2 = b
          b -= 1 while b >= 0 && ident_char?(text[b])
          prev = text[(b + 1)..e2]
          is_decl = DECL_WORDS.include?(prev) || text[after] == "{"
          out << [split_top(text[(k + 1)...close]), i] unless is_decl
        end
      end
    end
    i += 1
  end
  out
end

# The type of a call argument in the caller: a cast `(T *) x` gives T *, anything else the declared type of x.
def caller_arg_type(text, pos, arg, name)
  a = arg.strip
  if a.start_with?("(")
    close = matching_paren(a, 0)
    if close && close + 1 < a.length && ident_char?(a[close + 1..-1].strip[0].to_s)
      return type_tokens(a[1...close])
    end
  end
  argument_type(text, pos, a, name)
end

# The template parameters of a template function (its names) and its parameter parts, from its definition.
def template_head_of(text, name)
  template_bodies(text).each do |tb|
    t = tb[:tmpl]
    header = text[(t[:close] + 1)...tb[:open]]
    next unless function_name(header) == name
    lp = header.index("(")
    next if lp.nil?
    rp = matching_paren(header, lp)
    parts = split_top(header[(lp + 1)...rp])
    names = split_top(text[(t[:lt] + 1)...t[:close]]).map { |pr| tokens_of(pr.split("=")[0].strip).last }
    return { names: names, parts: parts, pos: tb[:open] }
  end
  nil
end

# The explicit template arguments of a call without them, deduced from the types of its arguments: one per template
# parameter, in order. Refuses an ambiguous deduction and a parameter no argument gives.
def deduce_call_targs(text, name, pos, args)
  head = template_head_of(text, name)
  return nil if head.nil?
  found = {}
  head[:parts].each_with_index do |part, idx|
    break if idx >= args.length
    ptoks = type_tokens(part)
    ptoks.pop if ptoks.last && !ptoks.last.start_with?("*") && !ptoks.last.start_with?("&") && ptoks.length > 1
    head[:names].each do |p|
      next unless ptoks.include?(p)
      at = caller_arg_type(text, pos, args[idx], name)
      t = match_type(ptoks, at, p)
      refuse("call of #{name}: #{p} cannot be deduced from the argument #{args[idx]} of type #{at.join(' ')} (at line #{text[0...pos].count("\n") + 1})") if t.nil?
      refuse("call of #{name}: #{p} is deduced as #{found[p]} and as #{t} (ambiguous, at line #{text[0...pos].count("\n") + 1})") if found[p] && found[p] != t
      found[p] = t
    end
  end
  head[:names].map do |p|
    found[p] || refuse("call of #{name} (at line #{text[0...pos].count("\n") + 1}): no argument gives #{p}, so it cannot be deduced")
  end
end

def template_instances(name, text, stack)
  refuse("dependent launch: #{(stack + [name]).join(' -> ')} instantiates itself through its template arguments") if stack.include?(name)
  out = []
  sites = call_sites(text, name).map { |targs, pos| [split_top(targs), pos] }
  # Calls without explicit template arguments: their arguments' types give the instance (softmax's soft_max_f32_cuda).
  plain_call_sites(text, name).each do |cargs, pos|
    deduced = deduce_call_targs(text, name, pos, cargs)
    sites << [deduced, pos] if deduced
  end
  sites.each do |args, pos|
    outer = enclosing_template(text, pos)
    # A bare local constant of the enclosing body (fallback in mmq's mul_mat_q_case) is its literal value.
    if outer
      args = args.map do |a|
        v = a.strip
        if v.length > 0 && v.chars.all? { |c| ident_char?(c) } && !outer[:names].include?(v)
          local_constant(text, outer[:open], pos, v) || a
        else
          a
        end
      end
    end
    if outer && args.any? { |a| tokens_of(a).any? { |tk| outer[:names].include?(tk) } }
      template_instances(outer[:fname], text, stack + [name]).each do |inst|
        # A pack expands to several arguments: the list is split again after the substitution.
        out << split_top(args.map { |a| substitute(a, outer[:names], inst, outer[:pack]) }.join(", "))
      end
    else
      out << args
    end
  end
  out.uniq
end

# Line (1-based) and column (0-based) of position pos in s. The newline positions of s are indexed once.
def line_col(s, pos)
  unless $newlines_for.equal?(s)
    nl = []
    i = 0
    while (k = s.index("\n", i))
      nl << k
      i = k + 1
    end
    $newlines = nl
    $newlines_for = s
  end
  lo = 0
  hi = $newlines.length
  while lo < hi
    mid = (lo + hi) / 2
    if $newlines[mid] < pos
      lo = mid + 1
    else
      hi = mid
    end
  end
  line_start = lo == 0 ? 0 : $newlines[lo - 1] + 1
  [lo + 1, pos - line_start]
end

def line_start(s, line)
  i = 0
  (line - 1).times { i = s.index("\n", i) + 1 }
  i
end

# The launches whose template arguments depend on an enclosing template parameter, keyed by [line, column] of their
# `<<<` (in the text they are given; the rewrite maps them, see rewrite). The text is the host-resolved unit, where the
# conditionals of the host pass are resolved and each function is one top-level piece.
# `<<<`: the enclosing template, its concrete instances, and the dispatch struct that carries each instance's wrapper
# address (see dependent_decls). The instances come from the explicit calls of the enclosing template in the unit.
def dependent_launches(text)
  out = {}
  template_launches(text).each_with_index do |(nm, ta, pos), idx|
    next if ta.empty?
    dep = dependent_on_template(text, pos, ta)
    next if dep.nil?
    outer = enclosing_template(text, pos)
    refuse("template launch of #{nm}<#{ta}> depends on the template parameter #{dep}, which is not a parameter of a top-level " \
           "template function (at line #{text[0...pos].count("\n") + 1})") if outer.nil?
    insts = outer[:qual] ? member_instances(outer, text) : template_instances(outer[:fname], text, [])
    refuse("template launch of #{nm}<#{ta}> depends on the template parameter #{dep} of #{outer[:fname]}: the unit has no " \
           "explicit call of it with all its template arguments, so its instances are not known") if insts.empty?
    insts.each do |inst|
      # Without a pack, one argument per template parameter; with one, the other parameters' count is the minimum.
      ok = outer[:pack] ? inst.length >= outer[:names].length - 1 : inst.length == outer[:names].length
      refuse("template launch of #{nm}<#{ta}>: a call of #{outer[:fname]} does not give all its template arguments " \
             "explicitly") unless ok
    end
    outer[:line] = line_col(text, outer[:st])[0]
    out[line_col(text, pos)] = { name: nm, targs: ta, outer: outer, insts: insts, dname: "__nfcxx_disp_#{sanitize(nm)}_#{idx}" }
  end
  out
end

# The declarations of the dependent launches' dispatch, at the top-level piece of their enclosing template: each
# instance's wrapper (see template_site), the primary dispatch template, and one specialization per instance.
def dependent_decls(dl, orig)
  lines = []
  dl.each_value do |d|
    d[:insts].each do |inst|
      concrete = split_top(d[:targs]).map { |a| substitute(a, d[:outer][:names], inst, d[:outer][:pack]) }.join(", ")
      d[:wrapper] ||= {}
      d[:wrapper][inst] = template_site(d[:name], concrete)
    end
  end
  dl.each_value do |d|
    at = line_start(orig, d[:outer][:line])
    d[:wrapper].values.uniq.each { |w| lines << [at, "static void #{w}(#{$sites[w][:decl]});\n"] }
    lines << [at, "template <#{d[:outer][:decls].join(', ')}> struct #{d[:dname]};\n"]
    d[:insts].each do |inst|
      lines << [at, "template <> struct #{d[:dname]}<#{inst.join(', ')}> { static constexpr auto fn = &#{d[:wrapper][inst]}; };\n"]
    end
  end
  lines
end

def rewrite(text, orig)
  out = "#line 1 \"#{orig}\"\n"
  n = text.length
  i = 0
  # The wrapper declarations of the template launches, at file scope just before the top-level piece that holds
  # each launch: EDG rejects a linkage specification in block scope. Keyed by the piece's start index.
  pieces = top_pieces(text)
  decls_at = Hash.new { |h, k| h[k] = [] }
  # The dependent launches are found in the host-resolved unit: its top-level pieces are balanced (the untaken branches
  # of the conditionals are blank lines, the lines of the taken ones are unchanged).
  $cond_strict = true
  resolved = resolve_conditionals(text, {})
  $cond_strict = false
  $kernel_text = resolved
  dl = dependent_launches(resolved)
  template_launches(text).each do |nm, ta, pos|
    next unless dependent_on_template(text, pos, ta).nil?
    w = template_site(nm, ta)
    piece = pieces.find { |st, en, _kind, _body| st <= pos && pos < en }
    line = "static void #{w}(#{$sites[w][:decl]});\n"
    decls_at[piece ? piece[0] : 0] << line unless decls_at[piece ? piece[0] : 0].include?(line)
  end
  dependent_decls(dl, text).each { |at, line| decls_at[at] << line unless decls_at[at].include?(line) }
  dirs = directive_ends(text)
  while i < n
    if decls_at.key?(i)
      decls_at.delete(i).each { |line| out << line }
    end
    if dirs.key?(i)
      # a directive ends before its newline: the newline (and the declarations of the piece after it) follow it
      k = dirs[i]
      out << text[i...k]
      i = k
      if k < n && text[k] == "\n"
        out << "\n"
        i = k + 1
        decls_at.delete(k).each { |line| out << line } if decls_at.key?(k)
      end
      next
    end
    e = skip_literal(text, i)
    if e
      out << text[i...e]
      i = e
      next
    end
    if text[i, 3] == "<<<" && !(i + 3 < n && text[i + 3] == "<")
      line = line_col(text, i)[0]
      # The kernel name is the identifier before `<<<`, or before its template argument list.
      j = i - 1
      j -= 1 while j >= 0 && white?(text[j])
      targs = nil
      gt_at = j
      if text[j] == ">"
        depth = 0
        while j >= 0
          depth += 1 if text[j] == ">"
          depth -= 1 if text[j] == "<"
          break if depth == 0
          j -= 1
        end
        targs = text[(j + 1)...gt_at].strip
        j -= 1
        j -= 1 while j >= 0 && white?(text[j])
      end
      name_end = j + 1
      name_start = name_end
      name_start -= 1 while name_start > 0 && ident_char?(text[name_start - 1])
      name = text[name_start...name_end]
      refuse("launch without a kernel name at line #{line}") if name.empty?
      # The call copied so far ends with the name and its arguments: take them back out.
      out = out[0...(out.length - (i - name_start))]

      # The configuration runs to the first `>>>` outside brackets.
      k = i + 3
      depth = 0
      close_cfg = nil
      while k < n
        e2 = skip_literal(text, k)
        if e2
          k = e2
          next
        end
        c = text[k]
        if c == "(" || c == "[" || c == "{"
          depth += 1
        elsif c == ")" || c == "]" || c == "}"
          depth -= 1
        elsif depth == 0 && text[k, 3] == ">>>"
          close_cfg = k
          break
        end
        k += 1
      end
      refuse("unterminated launch configuration for #{name}") if close_cfg.nil?
      cfg = split_config(text, i + 3, close_cfg)
      refuse("launch of #{name} needs 2 to 4 configuration items") if cfg.length < 2 || cfg.length > 4
      cfg += ["0"] * (4 - cfg.length)
      cfg[2] = "0" if cfg[2].empty?
      cfg[3] = "0" if cfg[3].empty?

      p = close_cfg + 3
      p += 1 while p < n && (text[p] == " " || text[p] == "\t" || text[p] == "\n" || text[p] == "\r")
      refuse("launch of #{name} without an argument list") if text[p] != "("
      close_args = matching_paren(text, p)
      refuse("unterminated argument list for #{name}") if close_args.nil?
      args = text[(p + 1)...close_args].strip

      lines = text[i..close_args].count("\n")
      kernel = name
      if targs
        d = dl[line_col(text, i)]
        if d
          # The pack keeps its ... (disp<Ns...> expands it inside the template body).
          tn = d[:outer][:names].each_with_index.map { |n, k| k == d[:outer][:pack] ? "#{n}..." : n }
          kernel = "#{d[:dname]}<#{tn.join(', ')}>::fn"
        else
          refuse("template launch of #{name}<#{targs}> depends on a template parameter, and its enclosing template is not " \
                 "resolved in this unit (at line #{line})") unless dependent_on_template(text, i, targs).nil?
          kernel = template_site(name, targs)
        end
      end
      out << "__nfcxx_cuda_launch(#{kernel}, #{cfg[0]}, #{cfg[1]}, #{cfg[2]}, #{cfg[3]}"
      out << ", #{args}" unless args.empty?
      out << ")"
      out << ("\n" * lines)
      i = close_args + 1
      next
    end
    out << text[i]
    i += 1
  end
  # The wrappers are defined here, after the calls; each call has the declaration in its block.
  unless $sites.empty?
    out << "\n"
    $sites.each do |w, site|
      out << "static void #{w}(#{site[:decl]}) {}\n"
    end
  end
  out
end

# ---- launch forms the scan does not see: a launch inside a function-like macro, and template arguments that the
# launch leaves to deduction. Both are rewritten before the launch scan, so the scan and the dependent-launch analysis
# see ordinary explicit launches. An expansion keeps the line count: its newlines go after it.

QUAL_WORDS = ["const", "volatile", "__restrict__", "__restrict", "restrict"]

# The function-like macros whose body holds a launch: name => { params:, body: } (continuation lines joined).
def launch_macros(text)
  out = {}
  top_pieces(text).each do |st, en, kind, _body|
    next unless kind == :pp
    t = text[st...en].sub("#", "").gsub("\\\n", " ").strip
    next unless t.start_with?("define")
    rest = t[6..-1].lstrip
    k = 0
    k += 1 while k < rest.length && ident_char?(rest[k])
    name = rest[0...k]
    after = rest[k..-1]
    next if name.empty? || !after.start_with?("(")
    close = after.index(")")
    next if close.nil?
    body = after[(close + 1)..-1].strip
    # A launch macro, or a macro whose body is a template declaration (mmq's DECL_MMQ_CASE: an explicit instantiation
    # of mul_mat_q_case per type), is expanded so that its instances are the calls the unit really has.
    next unless body.include?("<<<") || body.start_with?("template ") || body.start_with?("extern template ")
    out[name] = { params: split_top(after[1...close]), body: body }
  end
  out
end

# Expands the calls of those macros in code (not in directives, comments or literals), nested calls included.
def expand_launch_macros(text, depth = 0)
  macros = launch_macros(text)
  return text if macros.empty?
  refuse("launch macros nest more than 4 deep") if depth > 4
  code = top_pieces(text).select { |pc| pc[2] == :code }.map { |pc| [pc[0], pc[1]] }
  n = text.length
  out = ""
  changed = false
  i = 0
  while i < n
    e = skip_literal(text, i)
    if e
      out << text[i...e]
      i = e
      next
    end
    if ident_char?(text[i]) && !(i > 0 && ident_char?(text[i - 1])) && code.any? { |a, b| a <= i && i < b }
      j = i
      j += 1 while j < n && ident_char?(text[j])
      name = text[i...j]
      m = macros[name]
      k = j
      k += 1 while k < n && white?(text[k])
      if m && k < n && text[k] == "("
        close = matching_paren(text, k)
        refuse("unterminated call of launch macro #{name}") if close.nil?
        args = split_top(text[(k + 1)...close])
        refuse("launch macro #{name} takes #{m[:params].length} arguments, its call gives #{args.length}") unless args.length == m[:params].length
        body = substitute(m[:body], m[:params], args).gsub("\n", " ")
        out << body << ("\n" * text[i..close].count("\n"))
        i = close + 1
        changed = true
        next
      end
      out << name
      i = j
      next
    end
    out << text[i]
    i += 1
  end
  changed ? expand_launch_macros(out, depth + 1) : out
end

# The argument expressions of the launch whose `<<<` is at i, split at the top-level commas; nil if not readable.
def launch_arguments(text, i)
  k = i + 3
  depth = 0
  while k < text.length
    e = skip_literal(text, k)
    if e
      k = e
      next
    end
    c = text[k]
    if c == "(" || c == "[" || c == "{"
      depth += 1
    elsif c == ")" || c == "]" || c == "}"
      depth -= 1
    elsif depth == 0 && text[k, 3] == ">>>"
      break
    end
    k += 1
  end
  return nil if k >= text.length
  p = k + 3
  p += 1 while p < text.length && white?(text[p])
  return nil if text[p] != "("
  close = matching_paren(text, p)
  return nil if close.nil?
  split_top(text[(p + 1)...close])
end

# The span of the template arguments of the launch whose `<<<` is at i (the text between `<` and `>`).
def targs_span(text, i)
  gt = i - 1
  gt -= 1 while gt >= 0 && white?(text[gt])
  j = gt
  depth = 0
  while j >= 0
    depth += 1 if text[j] == ">"
    depth -= 1 if text[j] == "<"
    break if depth == 0
    j -= 1
  end
  [j + 1, gt]
end

# The type of a parameter, as its identifiers, `*` and `&` in order (the parameter's name is left out).
def type_tokens(s)
  out = []
  i = 0
  while i < s.length
    e = skip_literal(s, i)
    if e
      i = e
      next
    end
    c = s[i]
    if c == "*" || c == "&"
      out << c
      i += 1
    elsif ident_char?(c) && !(c >= "0" && c <= "9")
      j = i
      j += 1 while j < s.length && ident_char?(s[j])
      out << s[i...j]
      i = j
    else
      i += 1
    end
  end
  out
end

# The declared type written before the identifier at i, as its tokens: `const float *` for `const float *x`. Empty when
# the identifier is not a declaration (a call argument, an assignment, a return).
def type_before(text, i)
  toks = []
  j = i - 1
  loop do
    j -= 1 while j >= 0 && white?(text[j])
    break if j < 0
    c = text[j]
    if c == "*" || c == "&"
      toks.unshift(c)
      j -= 1
    elsif ident_char?(c)
      k = j
      k -= 1 while k >= 0 && ident_char?(text[k])
      toks.unshift(text[(k + 1)..j])
      j = k
    else
      break
    end
  end
  return [] if toks.empty? || %w[return else case new delete throw do].include?(toks.first)
  # a declaration has a type name; `&p` (an address taken in a call) has only punctuation before it
  return [] unless toks.any? { |t| ident_char?(t[0]) && !(t[0] >= "0" && t[0] <= "9") }
  toks
end

# The type of an identifier declared as a later declarator of a comma-separated declaration: the statement's first
# declarator gives the type (its name is the last identifier of that declarator).
def comma_declaration_type(text, i)
  start = [text.rindex(";", i - 1), text.rindex("{", i - 1), text.rindex("}", i - 1), text.rindex("(", i - 1)].compact.max
  seg = text[((start || -1) + 1)...i]
  parts = split_top(seg)
  return [] if parts.length < 2
  toks = type_tokens(parts[0])
  toks.pop if toks.last && !toks.last.start_with?("*") && !toks.last.start_with?("&") && toks.length > 1
  toks.any? { |t| ident_char?(t[0]) } ? toks : []
end

# The type of a launch argument: a literal's, or the declared type of an identifier in the same top-level piece.
def argument_type(text, pos, arg, nm)
  if arg.length > 0 && arg.chars.all? { |c| (c >= "0" && c <= "9") || c == "u" || c == "U" || c == "l" || c == "L" }
    return ["int"]
  end
  if arg.length > 1 && arg[0] >= "0" && arg[0] <= "9" && (arg.end_with?("f") || arg.end_with?("F"))
    return ["float"]
  end
  if arg.length > 0 && arg[0] >= "0" && arg[0] <= "9" && (arg.include?(".") || arg.include?("e") || arg.include?("E"))
    return ["double"]
  end
  unless arg.chars.all? { |c| ident_char?(c) } && !(arg[0] >= "0" && arg[0] <= "9")
    refuse("template launch of #{nm}: cannot deduce a template argument from the argument #{arg} (only identifiers and literals)")
  end
  piece = top_pieces(text).find { |st, en, kind, _b| kind == :code && st <= pos && pos < en }
  found = nil
  i = piece ? piece[0] : 0
  while i < pos
    e = skip_literal(text, i)
    if e
      i = e
      next
    end
    if text[i, arg.length] == arg && !(i > 0 && ident_char?(text[i - 1])) && i + arg.length < pos &&
       !ident_char?(text[i + arg.length])
      after = i + arg.length
      after += 1 while after < pos && white?(text[after])
      if "=;,)".include?(text[after].to_s)
        t = type_before(text, i)
        # A later declarator of a comma-separated declaration (`float *df, *dof;`): the type is the first declarator's.
        t = comma_declaration_type(text, i) if t.empty?
        found = t unless t.empty?
      end
    end
    i += 1
  end
  refuse("template launch of #{nm}: no declaration of #{arg} before the launch, so its type is not known") if found.nil?
  found
end

# The type a kernel parameter of type ptoks gives to the template parameter p, from an argument of type atoks; nil when
# the shapes do not match.
def match_type(ptoks, atoks, p)
  pt = ptoks.reject { |x| QUAL_WORDS.include?(x) }
  at = atoks.reject { |x| QUAL_WORDS.include?(x) }
  return at.join(" ") if pt == [p]
  return nil unless pt.length == at.length
  k = pt.index(p)
  return nil if k.nil?
  at[k]
end

# The explicit arguments for the template parameters the launch leaves out (the trailing ones).
def deduce_types(nm, ta, kt, missing, args, text, pos)
  parts = split_top(kt[:params])
  refuse("launch of #{nm}: #{args.length} arguments for #{parts.length} kernel parameters") unless args.length == parts.length
  found = {}
  parts.each_with_index do |part, idx|
    ptoks = type_tokens(part)
    ptoks.pop if ptoks.last && !ptoks.last.start_with?("*") && !ptoks.last.start_with?("&") && ptoks.length > 1
    missing.each do |p|
      next unless ptoks.include?(p)
      at = argument_type(text, pos, args[idx], nm)
      t = match_type(ptoks, at, p)
      refuse("template launch of #{nm}<#{ta}>: cannot deduce #{p} from the argument #{args[idx]} of type #{at.join(' ')}") if t.nil?
      refuse("template launch of #{nm}<#{ta}>: #{p} is deduced as #{found[p]} and as #{t} (ambiguous)") if found[p] && found[p] != t
      found[p] = t
    end
  end
  missing.map do |p|
    found[p] || refuse("template launch of #{nm}<#{ta}>: no argument gives #{p}, so it cannot be deduced")
  end
end

# The launches with no template arguments at all (`kscale<<<...>>>(args)`): [name, end of name, position of <<<].
def plain_launches(text)
  out = []
  i = 0
  while i < text.length
    e = skip_literal(text, i)
    if e
      i = e
      next
    end
    if text[i, 3] == "<<<"
      b = i - 1
      b -= 1 while b >= 0 && white?(text[b])
      e2 = b
      b -= 1 while b >= 0 && ident_char?(text[b])
      name = text[(b + 1)..e2]
      out << [name, e2 + 1, i] unless name.empty? || (name[0] >= "0" && name[0] <= "9") || text[b] == ">"
    end
    i += 1
  end
  out
end

# Every launch with fewer template arguments than the kernel's parameters gets the deduced ones written after its own.
def deduce_launch_targs(text)
  edits = []
  plain_launches(text).each do |nm, at, pos|
    kt = kernel_template(nm)
    next if kt.nil?
    args = launch_arguments(text, pos)
    refuse("template launch of #{nm}: its arguments are not readable (at line #{text[0...pos].count("\n") + 1})") if args.nil?
    deduced = deduce_types(nm, "", kt, kt[:names], args, text, pos)
    edits << [at, at, "<#{deduced.join(", ")}>"]
  end
  template_launches(text).each do |nm, ta, pos|
    kt = kernel_template(nm)
    next if kt.nil?
    given = split_top(ta)
    next if given.length >= kt[:names].length
    args = launch_arguments(text, pos)
    refuse("template launch of #{nm}<#{ta}>: its arguments are not readable (at line #{text[0...pos].count("\n") + 1})") if args.nil?
    deduced = deduce_types(nm, ta, kt, kt[:names][given.length..-1], args, text, pos)
    a, b = targs_span(text, pos)
    edits << [a, b, (given + deduced).join(", ")]
  end
  edits.sort_by { |a, _b, _n| -a }.each do |a, b, new|
    text = text[0...a] + new + text[b..-1]
  end
  text
end

# The launch forms before the scan: the macro calls that hold a launch, then the deduced template arguments.
def launch_prepare(text)
  t = expand_launch_macros(text)
  $expanded = t
  deduce_launch_targs(t)
end

# ---- device side (--device): the __global__ and __device__ functions as a device-only translation unit

DEVICE_BUILTINS = {
  "threadIdx" => "tid", "blockIdx" => "ctaid", "blockDim" => "ntid", "gridDim" => "nctaid",
}
DEVICE_AXES = ["x", "y", "z"]
DEVICE_QUALIFIERS = ["__global__", "__device__", "__host__", "__forceinline__"]

def word_at?(s, i, w)
  s[i, w.length] == w && !(i > 0 && ident_char?(s[i - 1])) && !ident_char?(s[i + w.length])
end

# threadIdx.x and the others become calls of the intrinsics DEVICE_INTRINSICS (scripts/pathb-ptx-emit.rb) reads.
def rewrite_builtins(t)
  out = ""
  i = 0
  while i < t.length
    e = skip_literal(t, i)
    if e
      out << t[i...e]
      i = e
      next
    end
    # `extern __shared__ T x[];` is a shared-memory declaration: the prelude's static replaces both words
    if word_at?(t, i, "extern")
      j = i + 6
      j += 1 while t[j] == " " || t[j] == "\t" || t[j] == "\n"
      if word_at?(t, j, "__shared__")
        i = j
        next
      end
    end
    if word_at?(t, i, "__syncthreads") && t[i + 13] == "("
      out << "__nfcxx_syncthreads"
      i += 13
      next
    end
    # __syncwarp(mask) is the warp barrier of the mask; __syncwarp() is the full warp (CUDA's default mask)
    if word_at?(t, i, "__syncwarp") && t[i + 10] == "("
      out << "__nfcxx_syncwarp("
      j = i + 11
      j += 1 while j < t.length && white?(t[j])
      out << "0xffffffffu" if t[j] == ")"
      i += 11
      next
    end
    hit = false
    DEVICE_BUILTINS.each do |name, prefix|
      next if hit || !word_at?(t, i, name)
      j = i + name.length
      next unless t[j] == "." && DEVICE_AXES.include?(t[j + 1]) && !ident_char?(t[j + 2])
      out << "__nfcxx_#{prefix}_#{t[j + 1]}()"
      i = j + 2
      hit = true
    end
    next if hit
    out << t[i]
    i += 1
  end
  out
end

def device_decls
  decls = []
  DEVICE_BUILTINS.each_value do |prefix|
    DEVICE_AXES.each { |a| decls << "extern \"C\" unsigned __nfcxx_#{prefix}_#{a}(void);" }
  end
  decls.join("\n")
end

# The device unit's prelude: the CUDA names that the host headers would give (uint, NULL), the shared-memory
# qualifier (a static object here, which the emitter refuses until static data is lowered), and __syncthreads
# (an intrinsic the emitter does not lower yet, so a kernel that uses it is refused by name).
DEVICE_PRELUDE = <<'PRELUDE'
typedef unsigned int uint;
typedef unsigned short ushort;
typedef unsigned long ulong;
typedef unsigned long size_t;
#ifndef NULL
#define NULL 0
#endif
#define __shared__ static
// The device pass architecture, for plain uses of __CUDA_ARCH__ (the conditionals are resolved with it too).
#define __CUDA_ARCH__ 750
// The qualifiers as macros too: a macro body of a carried header can name them (ggml-common.h: GGML_TABLE_BEGIN).
#define __device__
#define __global__
#define __host__
#define __forceinline__
extern "C" void __nfcxx_syncthreads(void);
extern "C" void __nfcxx_syncwarp(unsigned int mask);
extern "C" void *__nfcxx_dynshared_addr(void);
// Device printf: the emitter lowers a call of printf to a call of vprintf with a packed argument buffer.
extern "C" int printf(const char *, ...);
extern "C" int vprintf(const char *, const void *);
PRELUDE

# CUDA's vector types (uchar4, uint2, float3, ...) come from the CUDA headers, which the device unit does not
# include. A vector type is defined here only when device code names it, so a unit that does not use one has no
# extra declaration. Each has its struct (members x, y, z, w) and its make_ constructor, as in vector_types.h.
VECTOR_BASES = [["char", "signed char"], ["uchar", "unsigned char"], ["short", "short"], ["ushort", "unsigned short"],
                ["int", "int"], ["uint", "unsigned int"], ["float", "float"]]
VECTOR_LANES = ["x", "y", "z", "w"]

def vector_defs
  defs = {}
  VECTOR_BASES.each do |base, ctype|
    [2, 3, 4].each do |n|
      name = "#{base}#{n}"
      members = VECTOR_LANES[0, n]
      params = members.map { |m| "#{ctype} #{m}" }.join(", ")
      init = members.join(", ")
      text = "struct #{name} { #{ctype} #{members.join(", ")}; };\n" \
             "static inline #{name} make_#{name}(#{params}) { #{name} r = {#{init}}; return r; }\n"
      defs[name] = text
      defs["make_#{name}"] = text
    end
  end
  defs
end

VECTOR_DEFS = vector_defs

# Device builtins that the CUDA headers define as functions, provided in the unit when device code names them
# (the same rule as the vector types). __mul24 takes the low 24 bits of each operand, sign-extended, and returns the
# low 32 bits of the product.
# The shuffle wrappers: name => the PTX mode the emitter uses (WARP_SHUFFLES: __nfcxx_shfl_<mode>_sync_i / _f).
SHFL_DEFS = {}
{ "bfly" => "xor", "down" => "down", "up" => "up", "idx" => "" }.each do |mode, cuda|
  base = cuda.empty? ? "__shfl_sync" : "__shfl_#{cuda}_sync"
  ext = cuda.empty? ? "__nfcxx_shfl_sync" : "__nfcxx_shfl_#{cuda}_sync"
  SHFL_DEFS[mode] = <<-SHFL
extern "C" int #{ext}_i(unsigned, int, int);
extern "C" float #{ext}_f(unsigned, float, int);
static inline int #{base}(unsigned m, int v, int l) { (void)m; return #{ext}_i(0xffffffffu, v, l); }
static inline int #{base}(unsigned m, int v, int l, int w) { (void)m; (void)w; return #{ext}_i(0xffffffffu, v, l); }
static inline float #{base}(unsigned m, float v, int l) { (void)m; return #{ext}_f(0xffffffffu, v, l); }
static inline float #{base}(unsigned m, float v, int l, int w) { (void)m; (void)w; return #{ext}_f(0xffffffffu, v, l); }
  SHFL
end

# The half type and its conversions, shared by the entries below (include-guarded: each entry carries them, the
# device unit gets them once). __float2half rounds to nearest, even, as CUDA does; __half2float is exact.
HALF_CORE = "#ifndef __NFCXX_HALF_CORE\n#define __NFCXX_HALF_CORE\n" \
  "typedef unsigned short __half;\n" \
  "static inline unsigned short __float2half(float f) { unsigned x = *(const unsigned *)&f; unsigned sign = x & 0x80000000u; x ^= sign; unsigned o; if (x >= 0x47800000u) { o = x > 0x7f800000u ? 0x7e00u : 0x7c00u; } else if (x < 0x38800000u) { float t = *(const float *)&x * 16777216.0f; float r = (t + 8388608.0f) - 8388608.0f; o = (unsigned)r; } else { unsigned odd = (x >> 13) & 1u; x += (0u - 112u) * 0x800000u + 0xfffu; x += odd; o = x >> 13; } return (unsigned short)((sign >> 16) | o); }\n" \
  "static inline float __half2float(unsigned short h) { unsigned u = (unsigned)h; unsigned sign = (u & 0x8000u) << 16; unsigned e = (u >> 10) & 0x1fu; unsigned m = u & 0x3ffu; unsigned r; if (e == 0) { if (m == 0) { r = sign; } else { float f = (float)m * (1.0f / 16777216.0f); r = *(const unsigned *)&f | sign; } } else if (e == 31) { r = sign | 0x7f800000u | (m << 13); } else { r = sign | ((e + 112u) << 23) | (m << 13); } return *(const float *)&r; }\n" \
  "#endif\n"

# The integer intrinsics of llama.cpp's ggml-cuda. __umulhi, __popc and __byte_perm wrap the scalar intrinsics of the
# emitter (SCALAR_U32 in pathb-ptx-emit.rb, one PTX instruction each); the others are plain integer code. The half type
# is an unsigned short here (16-bit integers are lowered by the emitter), and the conversions do the IEEE work in 32-bit
# integers and float arithmetic: round to nearest, even, as CUDA's __float2half. __hadd, __hsub, __hmul and __hfma compute
# in float and round once more to half: for these operands the float result is exact or rounds the same way, except for
# rare double-rounding cases of __hfma (the sum of an exact product with c).
# __half2: two halves packed in an unsigned int, the low half in bits 0..15 (x) and the high half in bits 16..31 (y).
# The pair functions are plain integer code on that packing; the lanes use the half operations above, through one
# guarded helper so that several pair functions in a unit define it once.
HALF2_TYPE = "#ifndef __NFCXX_HALF2_TYPE\n#define __NFCXX_HALF2_TYPE\ntypedef struct __nfcxx_half2 { unsigned short x, y; } __half2;\n#endif\n"
HALF_LANE = HALF_CORE + "#ifndef __NFCXX_HALF_LANE\n#define __NFCXX_HALF_LANE\n" \
  "static inline unsigned short __nfcxx_hlane(unsigned short a, unsigned short b, int add) { return add ? __hadd(a, b) : __hmul(a, b); }\n" \
  "#endif\n"
HALF_LANE = HALF_LANE.sub("__nfcxx_hlane(unsigned short a, unsigned short b, int add) { return add ? __hadd(a, b) : __hmul(a, b); }",
  "__nfcxx_hlane(unsigned short a, unsigned short b, int add) { return add ? __float2half(__half2float(a) + __half2float(b)) : __float2half(__half2float(a) * __half2float(b)); }")
HALF2_PAIR = HALF2_TYPE + HALF_LANE

# The C++ operators on __half2 (llama.cpp uses them). Included when the unit names half2 (or __half2); they call the
# pair functions above, which are included with them.
HALF2_OPS = HALF2_TYPE + [
  "static inline __half2 operator+(__half2 a, __half2 b) { return __hadd2(a, b); }\n",
  "static inline __half2 operator-(__half2 a, __half2 b) { return __hsub2(a, b); }\n",
  "static inline __half2 operator*(__half2 a, __half2 b) { return __hmul2(a, b); }\n",
  "static inline __half2 operator/(__half2 a, __half2 b) { return __hdiv2(a, b); }\n",
  "static inline __half2 operator-(__half2 a) { __half2 r; r.x = a.x ^ 0x8000u; r.y = a.y ^ 0x8000u; return r; }\n",
  "static inline __half2 &operator+=(__half2 &a, __half2 b) { a = __hadd2(a, b); return a; }\n",
  "static inline __half2 &operator-=(__half2 &a, __half2 b) { a = __hsub2(a, b); return a; }\n",
  "static inline __half2 &operator*=(__half2 &a, __half2 b) { a = __hmul2(a, b); return a; }\n",
  "static inline __half2 &operator/=(__half2 &a, __half2 b) { a = __hdiv2(a, b); return a; }\n",
  "static inline int operator==(__half2 a, __half2 b) { return __half2float(a.x) == __half2float(b.x) && __half2float(a.y) == __half2float(b.y); }\n",
].join

# __hmax2: the lane rule of __hmax (NaN loses; a zero tie gives +0 for mixed signs), defined once per unit.
HMAXL = "#ifndef __NFCXX_HMAXL\n#define __NFCXX_HMAXL\n" \
  "static inline unsigned short __nfcxx_hmaxl(unsigned short a, unsigned short b) { float x = __half2float(a), y = __half2float(b); float r = x != x ? y : (y != y ? x : (x > y ? x : y)); if (x == y && x == 0.0f) r = (1.0f / x < 0.0f) ? y : x; return __float2half(r); }\n" \
  "#endif\n"
# bf16 as a 16-bit integer (the upper half of a float, round to nearest even). nv_bfloat162 is a two-lane struct, as
# __half2 is (CUDA's type has .x and .y, and llama.cpp brace-initializes it as such). Operators on nv_bfloat16 are
# integer operators here, as for half: a unit that uses them is not handled correctly.
BF16_CORE = "#ifndef __NFCXX_BF16_CORE\n#define __NFCXX_BF16_CORE\n" \
  "typedef unsigned short nv_bfloat16;\n" \
  "typedef struct __nfcxx_bfloat162 { unsigned short x, y; } nv_bfloat162;\n" \
  "typedef unsigned short __nv_bfloat16;\n" \
  "typedef nv_bfloat162 __nv_bfloat162;\n" \
  "static inline float __bfloat162float(unsigned short b) { unsigned u = (unsigned)b << 16; return *(const float *)&u; }\n" \
  "static inline unsigned short __float2bfloat16(float f) { unsigned x = *(const unsigned *)&f; if ((x & 0x7fffffffu) > 0x7f800000u) return (unsigned short)((x >> 16) | 0x40u); x += 0x7fffu + ((x >> 16) & 1u); return (unsigned short)(x >> 16); }\n" \
  "#endif\n"

BUILTIN_DEFS = {
  "__mul24" => "static inline int __mul24(int x, int y) { int a = (int)((unsigned)x << 8) >> 8; int b = (int)((unsigned)y << 8) >> 8; return (int)((unsigned)a * (unsigned)b); }\n",
  "__umulhi" => "extern \"C\" unsigned __nfcxx_umulhi(unsigned, unsigned);\nstatic inline unsigned __umulhi(unsigned a, unsigned b) { return __nfcxx_umulhi(a, b); }\n",
  "__popc" => "extern \"C\" unsigned __nfcxx_popc(unsigned);\nstatic inline int __popc(unsigned x) { return (int)__nfcxx_popc(x); }\n",
  "__popcll" => "extern \"C\" unsigned __nfcxx_popc(unsigned);\nstatic inline int __popcll(unsigned long long x) { return (int)__nfcxx_popc((unsigned)x) + (int)__nfcxx_popc((unsigned)(x >> 32)); }\n",
  "__byte_perm" => "extern \"C\" unsigned __nfcxx_byte_perm(unsigned, unsigned, unsigned);\nstatic inline unsigned __byte_perm(unsigned x, unsigned y, unsigned s) { return __nfcxx_byte_perm(x, y, s); }\n",
  "__vsub4" => "static inline unsigned __vsub4(unsigned a, unsigned b) { unsigned r = 0; for (int i = 0; i < 4; i++) { unsigned sh = 8u * (unsigned)i; r |= ((((a >> sh) & 0xffu) - ((b >> sh) & 0xffu)) & 0xffu) << sh; } return r; }\n",
  "__vcmpne4" => "static inline unsigned __vcmpne4(unsigned a, unsigned b) { unsigned r = 0; for (int i = 0; i < 4; i++) { unsigned sh = 8u * (unsigned)i; if (((a >> sh) & 0xffu) != ((b >> sh) & 0xffu)) r |= 0xffu << sh; } return r; }\n",
  "__trap" => "static inline void __trap(void) { __builtin_trap(); }\n",
  # Scalar helpers of ggml-cuda. __float_as_uint is a union read (the bits); __float2int_rn rounds half to even and
  # saturates like cvt.rni (NaN gives 0) through exact float steps; __frcp_rn is a correctly rounded division.
  "__float_as_uint" => "static inline unsigned int __float_as_uint(float f) { union { float f; unsigned int u; } v; v.f = f; return v.u; }\n",
  "__float2int_rn" => "static inline int __float2int_rn(float f) { if (f != f) return 0; if (f >= 2147483647.0f) return 2147483647; if (f <= -2147483648.0f) return -2147483647 - 1; int i = (int)f; float d = f - (float)i; if (d > 0.5f || (d == 0.5f && (i & 1))) i += 1; else if (d < -0.5f || (d == -0.5f && (i & 1))) i -= 1; return i; }\n",
  "__frcp_rn" => "static inline float __frcp_rn(float x) { return 1.0f / x; }\n",
  # Not lowered: the address conversion (a PTX cvta.to.shared the emitter does not have) and the half2 mask (its lanes
  # are a pair of halves; the emitter has no half2 comparison). Both are declared; a device call is refused by name.
  "__cvta_generic_to_shared" => "extern \"C\" unsigned long __nfcxx_cvta_generic_to_shared(const void *p);\nstatic inline unsigned long __cvta_generic_to_shared(const void *p) { return __nfcxx_cvta_generic_to_shared(p); }\n",
  "__hgt2_mask" => "extern \"C\" unsigned int __nfcxx_hgt2_mask(unsigned int a, unsigned int b);\nstatic inline unsigned int __hgt2_mask(unsigned int a, unsigned int b) { return __nfcxx_hgt2_mask(a, b); }\n",
  # CUDA math overloads of min and max for the numeric types (unqualified calls in device code; fattn-common.cuh).
  "min" => "static inline int min(int a, int b) { return a < b ? a : b; }\nstatic inline unsigned int min(unsigned int a, unsigned int b) { return a < b ? a : b; }\nstatic inline long long min(long long a, long long b) { return a < b ? a : b; }\nstatic inline unsigned long long min(unsigned long long a, unsigned long long b) { return a < b ? a : b; }\nstatic inline float min(float a, float b) { return a < b ? a : b; }\nstatic inline double min(double a, double b) { return a < b ? a : b; }\n",
  "max" => "static inline int max(int a, int b) { return a > b ? a : b; }\nstatic inline unsigned int max(unsigned int a, unsigned int b) { return a > b ? a : b; }\nstatic inline long long max(long long a, long long b) { return a > b ? a : b; }\nstatic inline unsigned long long max(unsigned long long a, unsigned long long b) { return a > b ? a : b; }\nstatic inline float max(float a, float b) { return a > b ? a : b; }\nstatic inline double max(double a, double b) { return a > b ? a : b; }\n",
  # std::is_same and std::is_same_v for device code (ggml-cuda's templates): the device unit has no host <type_traits>,
  # so the two are defined here over plain types only.
  "is_same_v" => "",   # rewritten to std::is_same<A, B>::value (rewrite_is_same_v), which needs is_same below
  "is_same" => "namespace std { template <class A, class B> struct is_same { enum : bool { value = false }; }; template <class A> struct is_same<A, A> { enum : bool { value = true }; }; }\n",
  # assert in device code: a failed condition traps the kernel (CUDA's device assert). The host copy keeps <assert.h>.
  "assert" => "static inline void assert(int c) { if (!c) __builtin_trap(); }\n",
  # The float math functions and __dp4a: wrappers over the emitter's FLOAT_BUILTINS / SCALAR_U32 intrinsics. The
  # accuracy of the approximate ones (rsqrt, div, exp, log) is in docs/notes/gpu.md.
  "fminf" => "extern \"C\" float __nfcxx_fminf(float, float);\nstatic inline float fminf(float a, float b) { return __nfcxx_fminf(a, b); }\n",
  "fabsf" => "extern \"C\" float __nfcxx_fabsf(float);\nstatic inline float fabsf(float a) { return __nfcxx_fabsf(a); }\n",
  "sqrtf" => "extern \"C\" float __nfcxx_sqrtf(float);\nstatic inline float sqrtf(float a) { return __nfcxx_sqrtf(a); }\n",
  "rsqrtf" => "extern \"C\" float __nfcxx_rsqrtf(float);\nstatic inline float rsqrtf(float a) { return __nfcxx_rsqrtf(a); }\n",
  "expf" => "extern \"C\" float __nfcxx_expf(float);\nstatic inline float expf(float a) { return __nfcxx_expf(a); }\n",
  "__expf" => "extern \"C\" float __nfcxx_expf(float);\nstatic inline float __expf(float a) { return __nfcxx_expf(a); }\n",
  "logf" => "extern \"C\" float __nfcxx_logf(float);\nstatic inline float logf(float a) { return __nfcxx_logf(a); }\n",
  "__logf" => "extern \"C\" float __nfcxx_logf(float);\nstatic inline float __logf(float a) { return __nfcxx_logf(a); }\n",
  "__fdividef" => "extern \"C\" float __nfcxx_fdividef(float, float);\nstatic inline float __fdividef(float a, float b) { return __nfcxx_fdividef(a, b); }\n",
  "__saturatef" => "extern \"C\" float __nfcxx_saturatef(float);\nstatic inline float __saturatef(float a) { return __nfcxx_saturatef(a); }\n",
  "__dp4a" => "extern \"C\" int __nfcxx_dp4a(int, int, int);\nstatic inline int __dp4a(int a, int b, int c) { return __nfcxx_dp4a(a, b, c); }\n",
  # Block and system intrinsics (the emitter lowers the extern ones: bar.red.or.pred, the butterfly reduction, membar.sys, nanosleep).
  # __reduce_add_sync ignores its mask, as the shuffles do: the full warp is lowered; a partial mask is not honoured.
  "__syncthreads_or" => "extern \"C\" int __nfcxx_syncthreads_or(int);\nstatic inline int __syncthreads_or(int p) { return __nfcxx_syncthreads_or(p); }\n",
  "__reduce_add_sync" => "extern \"C\" unsigned __nfcxx_reduce_add_sync(unsigned, unsigned);\nstatic inline unsigned __reduce_add_sync(unsigned m, unsigned v) { (void)m; return __nfcxx_reduce_add_sync(0xffffffffu, v); }\n",
  "__threadfence_system" => "extern \"C\" void __nfcxx_threadfence_system(void);\nstatic inline void __threadfence_system(void) { __nfcxx_threadfence_system(); }\n",
  "__nanosleep" => "extern \"C\" void __nfcxx_nanosleep(unsigned);\nstatic inline void __nanosleep(unsigned ns) { __nfcxx_nanosleep(ns); }\n",
  "__isnanf" => "static inline int __isnanf(float x) { return x != x; }\n",
  "__hmax" => HALF_CORE + "static inline unsigned short __hmax(unsigned short a, unsigned short b) { float x = __half2float(a), y = __half2float(b); float r = x != x ? y : (y != y ? x : (x > y ? x : y)); if (x == y && x == 0.0f) r = (1.0f / x < 0.0f) ? y : x; return __float2half(r); }\n",
  # __ldg: a plain load of the pointee (the read-only cache is a performance hint, not a semantic change).
  "__ldg" => "static inline float __ldg(const float *p) { return *p; }\nstatic inline int __ldg(const int *p) { return *p; }\nstatic inline unsigned __ldg(const unsigned *p) { return *p; }\n",
  # The warp shuffles (the emitter's WARP_SHUFFLES): int and float overloads, with and without the width. The mask and the
  # width are ignored: the wrapper is the full warp (width 32, mask 0xffffffff), because the emitter needs the constant
  # mask at the call and a wrapper's parameter is not one. Llama.cpp uses the full warp; a partial mask is not honoured.
  "__half" => HALF_CORE,
  "__float2half" => HALF_CORE,
  "__half2float" => HALF_CORE,
  "half" => HALF_CORE + "typedef __half half;\n",
  "half2" => HALF2_TYPE + "typedef __half2 half2;\n",
  "int8_t" => "typedef signed char int8_t;\n",
  "uint8_t" => "typedef unsigned char uint8_t;\n",
  "int16_t" => "typedef short int16_t;\n",
  "uint16_t" => "typedef unsigned short uint16_t;\n",
  "int32_t" => "typedef int int32_t;\n",
  "uint32_t" => "typedef unsigned int uint32_t;\n",
  "int64_t" => "typedef long long int64_t;\n",
  "uint64_t" => "typedef unsigned long long uint64_t;\n",
  "ldexpf" => "static inline float ldexpf(float x, int e) { return x * (float)(1 << (e > 30 ? 30 : (e < -30 ? -30 : e))); }\n",
  "fmaxf" => "static inline float fmaxf(float a, float b) { return a != a ? b : (b != b ? a : (a > b ? a : b)); }\n",
  "__half2" => HALF2_TYPE,
  "__halves2half2" => HALF2_TYPE + "static inline __half2 __halves2half2(unsigned short a, unsigned short b) { __half2 r; r.x = a; r.y = b; return r; }\n",
  "__low2half" => HALF2_TYPE + "static inline unsigned short __low2half(__half2 h) { return h.x; }\n",
  "__high2half" => HALF2_TYPE + "static inline unsigned short __high2half(__half2 h) { return h.y; }\n",
  "__half2half2" => HALF2_TYPE + "static inline __half2 __half2half2(unsigned short h) { __half2 r; r.x = h; r.y = h; return r; }\n",
  "__lows2half2" => HALF2_TYPE + "static inline __half2 __lows2half2(__half2 a, __half2 b) { __half2 r; r.x = a.x; r.y = b.x; return r; }\n",
  "__highs2half2" => HALF2_TYPE + "static inline __half2 __highs2half2(__half2 a, __half2 b) { __half2 r; r.x = a.y; r.y = b.y; return r; }\n",
  "__half22float2" => HALF2_TYPE + HALF_CORE + "static inline float2 __half22float2(__half2 h) { return make_float2(__half2float(h.x), __half2float(h.y)); }\n",
  "__float22half2_rn" => HALF2_TYPE + HALF_CORE + "static inline __half2 __float22half2_rn(float2 f) { __half2 r; r.x = __float2half(f.x); r.y = __float2half(f.y); return r; }\n",
  "__high2float" => HALF2_TYPE + HALF_CORE + "static inline float __high2float(__half2 h) { return __half2float(h.y); }\n",
  "__low2float" => HALF2_TYPE + HALF_CORE + "static inline float __low2float(__half2 h) { return __half2float(h.x); }\n",
  "__hmax2" => HALF2_TYPE + HALF_CORE + HMAXL + "static inline __half2 __hmax2(__half2 a, __half2 b) { __half2 r; r.x = __nfcxx_hmaxl(a.x, b.x); r.y = __nfcxx_hmaxl(a.y, b.y); return r; }\n",
  "nv_bfloat16" => BF16_CORE,
  "nv_bfloat162" => BF16_CORE,
  "__nv_bfloat16" => BF16_CORE,
  "__nv_bfloat162" => BF16_CORE,
  "__float2bfloat16" => BF16_CORE,
  "__bfloat162float" => BF16_CORE,
  "__low2bfloat16" => BF16_CORE + "static inline unsigned short __low2bfloat16(nv_bfloat162 h) { return h.x; }\n",
  "__high2bfloat16" => BF16_CORE + "static inline unsigned short __high2bfloat16(nv_bfloat162 h) { return h.y; }\n",
  "__hadd2" => HALF2_PAIR + "static inline __half2 __hadd2(__half2 a, __half2 b) { __half2 r; r.x = __nfcxx_hlane(a.x, b.x, 1); r.y = __nfcxx_hlane(a.y, b.y, 1); return r; }\n",
  "__hmul2" => HALF2_PAIR + "static inline __half2 __hmul2(__half2 a, __half2 b) { __half2 r; r.x = __nfcxx_hlane(a.x, b.x, 0); r.y = __nfcxx_hlane(a.y, b.y, 0); return r; }\n",
  "__hsub2" => HALF2_TYPE + HALF_CORE + "static inline __half2 __hsub2(__half2 a, __half2 b) { __half2 r; r.x = __float2half(__half2float(a.x) - __half2float(b.x)); r.y = __float2half(__half2float(a.y) - __half2float(b.y)); return r; }\n",
  "__hdiv2" => HALF2_TYPE + HALF_CORE + "static inline __half2 __hdiv2(__half2 a, __half2 b) { __half2 r; r.x = __float2half(__half2float(a.x) / __half2float(b.x)); r.y = __float2half(__half2float(a.y) / __half2float(b.y)); return r; }\n",
  # The C++ operators on half2 (llama.cpp uses them). Included when the unit names half2; they use the pair functions above.
  "__nfcxx_half2_ops" => HALF2_OPS,
  "__hadd" => HALF_CORE + "static inline unsigned short __hadd(unsigned short a, unsigned short b) { return __float2half(__half2float(a) + __half2float(b)); }\n",
  "__hsub" => HALF_CORE + "static inline unsigned short __hsub(unsigned short a, unsigned short b) { return __float2half(__half2float(a) - __half2float(b)); }\n",
  "__hmul" => HALF_CORE + "static inline unsigned short __hmul(unsigned short a, unsigned short b) { return __float2half(__half2float(a) * __half2float(b)); }\n",
  "__hfma" => HALF_CORE + "static inline unsigned short __hfma(unsigned short a, unsigned short b, unsigned short c) { return __float2half(__half2float(a) * __half2float(b) + __half2float(c)); }\n",
  "__shfl_xor_sync" => SHFL_DEFS["bfly"],
  "__shfl_down_sync" => SHFL_DEFS["down"],
  "__shfl_up_sync" => SHFL_DEFS["up"],
  "__shfl_sync" => SHFL_DEFS["idx"],
  # The warp votes: the emitter lowers __nfcxx_ballot_sync / __nfcxx_any_sync / __nfcxx_all_sync (full mask only).
  "__ballot_sync" => "extern \"C\" unsigned __nfcxx_ballot_sync(unsigned, int);\nstatic inline unsigned __ballot_sync(unsigned m, int p) { (void)m; return __nfcxx_ballot_sync(0xffffffffu, p); }\n",
  "__any_sync" => "extern \"C\" int __nfcxx_any_sync(unsigned, int);\nstatic inline int __any_sync(unsigned m, int p) { (void)m; return __nfcxx_any_sync(0xffffffffu, p); }\n",
  "__all_sync" => "extern \"C\" int __nfcxx_all_sync(unsigned, int);\nstatic inline int __all_sync(unsigned m, int p) { (void)m; return __nfcxx_all_sync(0xffffffffu, p); }\n",
}

# The cooperative-groups names that the device code of scan, scalarProd and MC_EstimatePiP uses: a thread block
# group (cg::thread_block), cg::this_thread_block() and cg::sync(group). The group is a plain unsigned value here
# (it carries nothing), so no struct is passed by value. Methods on the group and tiled partitions are not
# provided: a unit that calls them still fails (simpleCooperativeGroups; tests/cuda/samples/README.md).
COOP_DEF = <<'COOP'
namespace cooperative_groups {
typedef unsigned int thread_block;
thread_block this_thread_block(void) { return 0u; }
void sync(thread_block) { __nfcxx_syncthreads(); }
}
namespace cg = cooperative_groups;
COOP

# Identifiers of a piece of code, outside literals and comments, in order.
def tokens_of(s)
  out = []
  i = 0
  while i < s.length
    e = skip_literal(s, i)
    if e
      i = e
      next
    end
    # comments are not code: a word in one (a `__device__` mentioned above a host function) is no token
    if s[i] == "/" && s[i + 1] == "/"
      e = s.index("\n", i)
      i = e.nil? ? s.length : e
      next
    end
    if s[i] == "/" && s[i + 1] == "*"
      e = s.index("*/", i + 2)
      i = e.nil? ? s.length : e + 2
      next
    end
    c = s[i]
    if c == "_" || (c.ord >= 65 && c.ord <= 90) || (c.ord >= 97 && c.ord <= 122)
      j = i
      j += 1 while j < s.length && ident_char?(s[j])
      out << s[i...j]
      i = j
    else
      i += 1
    end
  end
  out
end

# True if s has code outside comments and whitespace.
# The text of a piece without its comments (each comment becomes a space; its newlines stay, so offsets of lines hold).
# The classifier reads a piece's text for '(' and '=' before a body: a comment that has one of them (as the comment
# before `enum { N = 4096 };` in a benchmark has) must not make the piece a function.
def code_text(s)
  out = ""
  i = 0
  while i < s.length
    e = skip_literal(s, i)
    if e
      if s[i] == "/"
        s[i...e].each_char { |c| out << (c == "\n" ? "\n" : " ") }
      else
        out << s[i...e]
      end
      i = e
      next
    end
    out << s[i]
    i += 1
  end
  out
end

def code_only?(s)
  i = 0
  while i < s.length
    e = skip_literal(s, i)
    if e
      if s[i] == "/"
        i = e
        next
      end
      return true
    end
    return true unless s[i] == " " || s[i] == "\t" || s[i] == "\n" || s[i] == "\r"
    i += 1
  end
  false
end

# Top-level pieces of a translation unit: preprocessor lines, and declarations or definitions ending at a `;` or at
# the `}` of a function or namespace. Each piece is [start, stop, kind], kind :pp or :code, and :body if it has a
# brace block at depth 0.
def top_pieces(text)
  pieces = []
  n = text.length
  i = 0
  start = 0
  depth = 0
  paren0 = false
  body = false
  opener = nil   # text of the depth-0 `{`'s chunk start, to tell namespaces and extern "C" blocks
  while i < n
    if depth == 0 && text[i] == "#" && !code_only?(text[start...i])
      # a directive ends at a newline that is not in a comment or literal, or after a backslash
      k = i
      while k < n
        e2 = skip_literal(text, k)
        if e2
          k = e2
          next
        end
        break if text[k] == "\n" && text[k - 1] != "\\"
        k += 1
      end
      pieces << [i, k, :pp]
      i = k
      start = k
      next
    end
    e = skip_literal(text, i)
    if e
      i = e
      next
    end
    c = text[i]
    if c == "("
      paren0 = true if depth == 0
      depth += 1
    elsif c == "["
      depth += 1
    elsif c == ")" || c == "]"
      depth -= 1
    elsif c == "{"
      if depth == 0
        body = true
        opener = tokens_of(text[start...i]).first
      end
      depth += 1
    elsif c == "}"
      depth -= 1
      if depth == 0 && (opener == "namespace" || opener == "extern")
        pieces << [start, i + 1, :code, true]
        start = i + 1
        paren0 = false; body = false; opener = nil
      elsif depth == 0 && !(opener.nil?) && !%w[struct class union enum typedef using].include?(opener) && paren0
        pieces << [start, i + 1, :code, true]
        start = i + 1
        paren0 = false; body = false; opener = nil
      end
    elsif c == ";" && depth == 0
      pieces << [start, i + 1, :code, body]
      start = i + 1
      paren0 = false; body = false; opener = nil
    end
    i += 1
  end
  pieces << [start, n, :code, body] if text[start...n].strip != ""
  pieces
end

# Removes the whole words of `words` from s, outside literals and comments.
def remove_words(s, words)
  out = ""
  i = 0
  while i < s.length
    e = skip_literal(s, i)
    if e
      out << s[i...e]
      i = e
      next
    end
    hit = words.find { |w| word_at?(s, i, w) }
    if hit
      i += hit.length
      i += 1 while i < s.length && (s[i] == " " || s[i] == "\t")
      next
    end
    out << s[i]
    i += 1
  end
  out
end

# The name of the function a definition declares: the identifier before its first `(`.
def function_name(text)
  # the first `(` outside comments and literals
  paren = nil
  i = 0
  while i < text.length
    e = skip_literal(text, i)
    if e
      i = e
      next
    end
    if text[i] == "("
      paren = i
      break
    end
    i += 1
  end
  return nil if paren.nil?
  head = text[0...paren].strip
  head.reverse.chars.take_while { |c| ident_char?(c) }.reverse.join
end

# Device mode: a quoted #include of a file that exists is replaced by that file's text (recursively, relative to the
# including file), so kernels kept in a .cu or .cuh of the same program are in the unit. System includes stay.
# Each file is expanded once per unit (`seen`, by absolute path): the headers of a CUDA backend include each other
# heavily, and without this the expansion repeats them at every branch (llama.cpp's mmq.cu grew to 24 MB, from 20 KB).
# Its include guards would drop the repeats anyway; a file meant to be included twice is not expanded twice.
# The -I directories of the driver (project headers). A quoted include is looked up beside the including file first,
# then in these, as the compiler does; an angle-bracket include is looked up in these only. System headers (CUDA's,
# the C library's) are never inlined: the device unit has no use for them.
$incdirs = []

# mruby has no ENV, so the toolkit is the default prefix /usr/local/cuda (where the driver's CUDA_HOME points).
def system_path?(path)
  p = File.expand_path(path)
  p.start_with?("/usr/", "/opt/", "/usr/local/cuda/")
end

def find_include(dir, name, quoted)
  cands = []
  cands << dir + "/" + name if quoted
  $incdirs.each { |d| cands << d + "/" + name }
  cands.find { |c| File.file?(c) && !system_path?(c) }
end

def expand_includes(text, dir, depth, seen = {})
  return text if depth > 8
  out = ""
  last = 0
  top_pieces(text).each do |st, en, kind|
    next unless kind == :pp
    rest = text[st...en].sub("#", "").strip
    next unless rest.start_with?("include")
    q = rest[7..-1].to_s.strip
    quoted = q.start_with?("\"")
    next unless quoted || q.start_with?("<")
    name = q[1..-1].split(quoted ? "\"" : ">")[0].to_s
    path = find_include(dir, name, quoted)
    next if path.nil?
    key = File.expand_path(path)
    out << text[last...st]
    if seen[key]
      out << "\n"
    else
      seen[key] = true
      # The same two rewrites as the main file: a header of the backend has __launch_bounds__ in front of its
      # template kernels, which kernel_template would not match.
      inc = File.open(path, "rb") { |f| f.read }
      inc = dynamic_shared_rewrite(strip_launch_bounds($device ? blank_comments(inc) : inc))
      out << "\n" << expand_includes(inc, File.dirname(path), depth + 1, seen) << "\n"
    end
    last = en
  end
  out << text[last..-1].to_s
  out
end

# Returns [device translation unit text, kernel names].
#
# The unit has the prelude, every __global__ and __device__ function definition or declaration, and the host
# declarations that those reference, transitively: typedefs, using, struct/class/union/enum definitions, variables,
# and #define/#undef. Host function definitions are not carried over, and neither are the #include lines (their
# contents are not in the unit; a name they supply is a missing declaration, reported by the front end). The
# conditional directives (#if, #ifdef, ...) are kept as written. A __device__ variable is refused: device data is
# not lowered yet.
# ---- conditionals of the device pass

# An expression the evaluator does not handle (a float literal, a string, a call with odd arguments): the conditional
# is kept as it was, with its lines and both branches, as before the evaluator existed.
class CondUnsupported < StandardError
end

def cond_fail(msg)
  raise CondUnsupported, msg
end
#
# The device unit is cut into top-level pieces by brace counting, and a preprocessor conditional opens or closes
# braces in the text of both of its branches, so a kernel inside #if/#else never returns the count to zero. The
# device pass therefore evaluates the conditionals first: the branches not taken are blanked (the line count is
# kept), the #if/#ifdef/#else/#endif lines are removed, and #define and #undef of the taken branches stay.
# The device pass defines CUDA's device-compile macros; the host pass is not affected.
DEVICE_PASS_MACROS = { "__CUDACC__" => "1", "__NVCC__" => "1", "__CUDA_ARCH__" => "750" }

def cond_tokens(s, line)
  toks = []
  i = 0
  n = s.length
  while i < n
    c = s[i]
    if white?(c)
      i += 1
    elsif ident_char?(c)
      j = i
      j += 1 while j < n && ident_char?(s[j])
      w = s[i...j]
      if c.ord >= 48 && c.ord <= 57
        w = w[0...-1] while w.length > 0 && "uUlL".include?(w[-1])
        v = (w.length > 2 && w[0] == "0" && (w[1] == "x" || w[1] == "X")) ? w[2..-1].to_i(16) : w.to_i
        toks << [:num, v]
      else
        toks << [:id, w]
      end
      i = j
    else
      two = i + 1 < n ? s[i, 2] : ""
      if %w[&& || == != <= >= << >>].include?(two)
        toks << [:op, two]
        i += 2
      elsif "!~+-*/%<>&|^()?:,".include?(c)
        toks << [:op, c]
        i += 1
      else
        cond_fail("unsupported character #{c.inspect} in #if at line #{line}")
      end
    end
  end
  toks
end

# Evaluates a #if expression: integers, identifiers (their object-like macro value, else 0), defined(X), the usual C
# operators. An unknown function-like call, such as __has_include(...), counts as 0.
def cond_eval(s, defs, line, depth = 0)
  cond_fail("#if nesting too deep at line #{line}") if depth > 16
  st = { toks: cond_tokens(s, line), pos: 0 }
  v = cond_expr(st, defs, line, depth)
  cond_fail("unsupported #if expression at line #{line}") if st[:pos] != st[:toks].length
  v
end

def cond_peek(st, x = nil)
  t = st[:toks][st[:pos]]
  return false if t.nil?
  return false if x && !(t[0] == :op && t[1] == x)
  true
end

def cond_expr(st, defs, line, depth)
  c = cond_binary(st, defs, line, depth, 0)
  return c unless cond_peek(st, "?")
  st[:pos] += 1
  a = cond_expr(st, defs, line, depth)
  cond_fail("expected ':' in #if at line #{line}") unless cond_peek(st, ":")
  st[:pos] += 1
  b = cond_expr(st, defs, line, depth)
  c != 0 ? a : b
end

# Binary operators by precedence level, lowest first.
COND_LEVELS = [["||"], ["&&"], ["|"], ["^"], ["&"], ["==", "!="], ["<", ">", "<=", ">="], ["<<", ">>"], ["+", "-"], ["*", "/", "%"]]

def cond_binary(st, defs, line, depth, level)
  return cond_unary(st, defs, line, depth) if level >= COND_LEVELS.length
  l = cond_binary(st, defs, line, depth, level + 1)
  loop do
    t = st[:toks][st[:pos]]
    break unless t && t[0] == :op && COND_LEVELS[level].include?(t[1])
    op = t[1]
    st[:pos] += 1
    if op == "||"
      r = cond_binary(st, defs, line, depth, level + 1)
      l = (l != 0 || r != 0) ? 1 : 0
    elsif op == "&&"
      r = cond_binary(st, defs, line, depth, level + 1)
      l = (l != 0 && r != 0) ? 1 : 0
    else
      r = cond_binary(st, defs, line, depth, level + 1)
      l = case op
          when "|" then l | r
          when "^" then l ^ r
          when "&" then l & r
          when "==" then l == r ? 1 : 0
          when "!=" then l != r ? 1 : 0
          when "<" then l < r ? 1 : 0
          when ">" then l > r ? 1 : 0
          when "<=" then l <= r ? 1 : 0
          when ">=" then l >= r ? 1 : 0
          when "<<" then l << r
          when ">>" then l >> r
          when "+" then l + r
          when "-" then l - r
          when "*" then l * r
          when "/" then (r == 0 ? cond_fail("division by zero in #if at line #{line}") : l / r)
          when "%" then (r == 0 ? cond_fail("division by zero in #if at line #{line}") : l % r)
          end
    end
  end
  l
end

def cond_unary(st, defs, line, depth)
  t = st[:toks][st[:pos]]
  cond_fail("unexpected end of #if expression at line #{line}") if t.nil?
  if t[0] == :op && t[1] == "!"
    st[:pos] += 1
    return cond_unary(st, defs, line, depth) == 0 ? 1 : 0
  elsif t[0] == :op && t[1] == "-"
    st[:pos] += 1
    return -cond_unary(st, defs, line, depth)
  elsif t[0] == :op && t[1] == "+"
    st[:pos] += 1
    return cond_unary(st, defs, line, depth)
  elsif t[0] == :op && t[1] == "~"
    st[:pos] += 1
    return ~cond_unary(st, defs, line, depth)
  elsif t[0] == :op && t[1] == "("
    st[:pos] += 1
    v = cond_expr(st, defs, line, depth)
    cond_fail("expected ')' in #if at line #{line}") unless cond_peek(st, ")")
    st[:pos] += 1
    return v
  elsif t[0] == :num
    st[:pos] += 1
    return t[1]
  elsif t[0] == :id && t[1] == "defined"
    st[:pos] += 1
    paren = cond_peek(st, "(")
    st[:pos] += 1 if paren
    name = st[:toks][st[:pos]]
    cond_fail("defined without a name at line #{line}") unless name && name[0] == :id
    st[:pos] += 1
    if paren
      cond_fail("expected ')' after defined at line #{line}") unless cond_peek(st, ")")
      st[:pos] += 1
    end
    return defs.key?(name[1]) ? 1 : 0
  elsif t[0] == :id
    st[:pos] += 1
    if cond_peek(st, "(")
      # a call of a function-like macro or an unknown function: 0, with its arguments skipped
      st[:pos] += 1
      nest = 1
      while nest > 0
        u = st[:toks][st[:pos]]
        cond_fail("unbalanced parentheses in #if at line #{line}") if u.nil?
        nest += 1 if u[0] == :op && u[1] == "("
        nest -= 1 if u[0] == :op && u[1] == ")"
        st[:pos] += 1
      end
      return 0
    end
    val = defs[t[1]]
    # The host analysis (see rewrite) keeps both branches of a condition on a name the unit does not define: the name
    # may come from a system header (CUDART_VERSION), so its value is not known here.
    cond_fail("#if names #{t[1]}, which the unit does not define (line #{line})") if val.nil? && $cond_strict
    return 0 if val.nil? || val == :function
    return cond_eval(val, defs, line, depth + 1)
  end
  cond_fail("unsupported #if expression at line #{line}")
end

# Resolves the conditionals of a translation unit. defs maps a name to its object-like replacement text, a function-like
# macro to :function, and a macro with no value to "". A conditional that cannot be evaluated (CondUnsupported) is
# kept with its branches; the lines of the other conditionals are blanked, so the line count does not change.
# A line without its // comment (and without /* */ comments on it): for the values of #define in the conditionals.
def strip_comments_line(v)
  out = ""
  i = 0
  while i < v.length
    if v[i] == "/" && v[i + 1] == "/"
      break
    elsif v[i] == "/" && v[i + 1] == "*"
      e = v.index("*/", i + 2)
      break if e.nil?
      out << " "
      i = e + 2
    else
      out << v[i]
      i += 1
    end
  end
  out
end

def resolve_conditionals(text, defs)
  out = []
  stack = []
  active = true
  pending = nil
  lineno = 0
  text.split("\n", -1).each do |raw|
    lineno += 1
    line = raw
    if pending
      # the joined line is one output line: a newline here would shift every later line (launches are keyed by line)
      line = pending + " " + raw
      pending = nil
    end
    if line.end_with?("\\")
      pending = line[0...-1]
      out << ""
      next
    end
    s = line.lstrip
    unless s.start_with?("#")
      out << (active ? line : "")
      next
    end
    d = s[1..-1].lstrip
    name = ""
    k = 0
    while k < d.length && ident_char?(d[k])
      name += d[k]
      k += 1
    end
    rest = d[k..-1].to_s.strip
    case name
    when "if", "ifdef", "ifndef"
      parent = active
      begin
        if name == "if"
          cond = parent ? cond_eval(rest, defs, lineno) != 0 : false
        else
          nm = rest.split(" ")[0].to_s
          cond = parent ? (defs.key?(nm) == (name == "ifdef")) : false
        end
        stack << { parent: parent, taken: cond, kept: false }
        active = parent && cond
        out << ""
      rescue CondUnsupported
        stack << { parent: parent, taken: true, kept: true }
        active = parent
        out << (parent ? line : "")
      end
    when "elif"
      refuse("#elif without #if at line #{lineno}") if stack.empty?
      fr = stack.last
      if fr[:kept]
        out << (fr[:parent] ? line : "")
      elsif fr[:taken]
        active = false
        out << ""
      else
        begin
          cond = fr[:parent] ? cond_eval(rest, defs, lineno) != 0 : false
          fr[:taken] = cond
          active = fr[:parent] && cond
          out << ""
        rescue CondUnsupported
          fr[:kept] = true
          fr[:taken] = true
          active = fr[:parent]
          out << (fr[:parent] ? line : "")
        end
      end
    when "else"
      refuse("#else without #if at line #{lineno}") if stack.empty?
      fr = stack.last
      if fr[:kept]
        out << (fr[:parent] ? line : "")
      else
        active = fr[:parent] && !fr[:taken]
        fr[:taken] = true
        out << ""
      end
    when "endif"
      refuse("#endif without #if at line #{lineno}") if stack.empty?
      fr = stack.pop
      active = fr[:parent]
      out << (fr[:kept] && fr[:parent] ? line : "")
    when "define"
      if active
        mname = ""
        j = 0
        while j < rest.length && ident_char?(rest[j])
          mname += rest[j]
          j += 1
        end
        if rest[j] == "("
          defs[mname] = :function
        else
          # the value without its comment: `#define CUDART_HMAX 11070 // CUDA 11.7` is 11070
          defs[mname] = strip_comments_line(rest[j..-1].to_s).strip
        end
      end
      out << (active ? line : "")
    when "undef"
      defs.delete(rest.split(" ")[0].to_s) if active
      out << (active ? line : "")
    else
      out << (active ? line : "")
    end
  end
  refuse("#if without #endif") unless stack.empty?
  out.join("\n")
end

# The identifier written right after the first whole-word occurrence of kw in t, or nil (anonymous, or not found).
def tag_after(t, kw)
  i = 0
  while (j = t.index(kw, i))
    k = j + kw.length
    whole = (j == 0 || !ident_char?(t[j - 1])) && (k >= t.length || !ident_char?(t[k]))
    if whole
      k += 1 while k < t.length && white?(t[k])
      return nil unless k < t.length && (ident_char?(t[k]) && !(t[k].ord >= 48 && t[k].ord <= 57))
      e = k
      e += 1 while e < t.length && ident_char?(t[e])
      return t[k...e]
    end
    i = k
  end
  nil
end

# The names an enum defines: its enumerators (the identifier at the start of each comma-separated item of its body).
# Only these: every other identifier of the enum (a type it mentions) is not defined by it.
def enum_enumerators(t)
  open = t.index("{")
  return [] if open.nil?
  close = matching_brace(t, open)
  body = t[(open + 1)...(close || t.length)]
  names = []
  body.split(",").each do |item|
    first = tokens_of(item.split("=")[0].to_s)[0]
    names << first if first
  end
  names
end

# The text with its comments blanked (each comment character becomes a space; newlines and literals stay). The
# classification searches for ( = { in the text, and a comment's parentheses or braces must not count there.
def blank_comments(s)
  out = ""
  i = 0
  while i < s.length
    if s[i] == "/" && (s[i + 1] == "/" || s[i + 1] == "*")
      e = skip_literal(s, i)
      (i...e).each { |k| out << (s[k] == "\n" ? "\n" : " ") }
      i = e
      next
    end
    e = skip_literal(s, i)
    if e
      out << s[i...e]
      i = e
      next
    end
    out << s[i]
    i += 1
  end
  out
end

# A function definition or declaration whose head names a type keyword (`static enum ggml_status f(...) {`): the
# keyword is not a type definition. The head is the text before the first brace; a `(` in it marks a function.
def function_head?(t)
  b = t.index("{")
  h = b.nil? ? t : t[0...b]
  h.index("(") && !(h.index("=") && h.index("=") < h.index("("))
end

def device_tu(text)
  pieces = top_pieces(text).map do |pc|
    st, en, kind, body = pc
    t = text[st...en]
    info = { text: t, kind: kind, body: body, toks: tokens_of(t), defined: [], keep: false, device: false }
    if kind == :pp
      rest = t.sub("#", "").gsub("\n", " ").strip
      d = rest.split(" ")[0] || ""
      if d == "define"
        after = rest[6..-1].strip
        name = after.split(" ")[0].to_s.split("(")[0]
        info[:defined] = [name]
        info[:toks] = tokens_of(after[name.length..-1].to_s)
        info[:macro] = true
      elsif d == "undef"
        info[:keep] = true
      elsif %w[if ifdef ifndef elif else endif].include?(d)
        info[:keep] = true
      end
    else
      info[:device] = info[:toks].include?("__global__") || info[:toks].include?("__device__")
    end
    info
  end

  kernels = []
  seeds = []
  # The template launches of the source: each instance is a wrapper kernel (see template_site).
  # A launch whose template arguments depend on an enclosing template parameter is not a wrapper: its instance is
  # fixed only by the instantiation, and the host pass refuses it (see rewrite). Registering it here would give a
  # wrapper that still names the parameter.
  template_launches(text).each { |nm, ta, pos| template_site(nm, ta) if dependent_on_template(text, pos, ta).nil? }
  # the dependent launches: the wrapper of each instance of their enclosing template (see dependent_launches)
  dependent_launches(text).each_value do |d|
    d[:insts].each do |inst|
      template_site(d[:name], split_top(d[:targs]).map { |a| substitute(a, d[:outer][:names], inst, d[:outer][:pack]) }.join(", "))
    end
  end
  pieces.each do |pc|
    next if pc[:kind] == :pp
    if pc[:device]
      if pc[:text].include?("__device__") && !pc[:body] && !pc[:text].include?("(")
        refuse("device variable: #{pc[:text].strip[0, 60]}")
      end
      if pc[:body]
        if pc[:toks].include?("__global__") && pc[:toks].first != "template"
          name = function_name(remove_words(pc[:text], DEVICE_QUALIFIERS))
          refuse("kernel without a name: #{pc[:text].strip[0, 60]}") if name.nil? || name.empty?
          kernels << name
        end
        pc[:keep] = true
        pc[:text] = remove_words(pc[:text], DEVICE_QUALIFIERS)
        seeds.concat(pc[:toks])
      elsif pc[:text].include?("(")
        pc[:keep] = true
        pc[:text] = remove_words(pc[:text], DEVICE_QUALIFIERS)
        seeds.concat(pc[:toks])
      end
    end
  end

  # Host declarations: defined names, as far as a piece's text tells them.
  pieces.each do |pc|
    next if pc[:keep] || pc[:device]
    t = blank_comments(pc[:text])
    toks = pc[:toks]
    if pc[:kind] == :pp
      next unless pc[:macro]
      next
    end
    next if toks.empty?
    next if pc[:body] && t.index("(") && !toks.include?("struct") && !toks.include?("class") && !toks.include?("union") && !toks.include?("enum")
    next if !pc[:body] && t.index("(") && !t.index("=") && toks.first != "typedef" # host prototype (a typedef is not one)
    if toks.first == "typedef"
      # `typedef R (*name)(args)` names `name`, which follows the `(*`; otherwise the name is the last identifier.
      fp = t.index("(*")
      pc[:defined] = [fp ? tokens_of(t[(fp + 2)..-1].to_s)[0] : toks.last].compact
    elsif toks.first == "using"
      pc[:defined] = [toks[1]].compact
    elsif (kw = (toks & %w[struct class union enum]).first) && !function_head?(t)
      # The tag is the identifier written right after the keyword; an anonymous one (`union { ... }` inside a function)
      # names nothing. (The next token in tokens_of skips the brace, so it must not be taken from there.)
      pc[:defined] = [tag_after(t, kw)].compact
      pc[:defined] += enum_enumerators(t) if kw == "enum"
    elsif pc[:body]
      next
    elsif toks.include?("const") || toks.include?("constexpr")
      # a constant: device code may read it. Other host variables are not reachable from device code.
      cut = t.index("=") || t.index("[") || t.index(";") || t.length
      pc[:defined] = [tokens_of(t[0...cut]).last].compact
    end
  end

  # Fixed point: a host declaration is carried over when the unit refers to a name it defines.
  needed = {}
  (seeds + tokens_of(DEVICE_PRELUDE)).each { |x| needed[x] = true }
  changed = true
  while changed
    changed = false
    pieces.each do |pc|
      next if pc[:keep] || pc[:device]
      next if pc[:defined].empty?
      next unless pc[:defined].any? { |d| needed[d] }
      pc[:keep] = true
      changed = true
      pc[:toks].each { |x| needed[x] = true }
    end
  end
  pieces.each do |pc|
    next unless pc[:kind] == :pp && pc[:macro] && pc[:defined].any? { |d| needed[d] }
    pc[:keep] = true
  end

  out = "// Device side of a .cu file, generated by scripts/cuda-rewrite.rb --device. Do not edit.\n"
  out << DEVICE_PRELUDE << device_decls << "\n"
  # A vector type the device code names, and the source does not define: its declaration (once per type).
  done = {}
  # The float2 conversions below take or return float2: its declaration is needed whenever one of them is.
  needed["float2"] = true if needed["__half22float2"] || needed["__float22half2_rn"]
  VECTOR_DEFS.each do |name, text|
    next unless needed[name]
    next if pieces.any? { |pc| pc[:keep] && pc[:defined].include?(name) }
    base = name.start_with?("make_") ? name[5..-1] : name
    next if done[base]
    done[base] = true
    out << VECTOR_DEFS[base] << "\n"
  end
  if needed["half2"] || needed["__half2"]
    needed["__nfcxx_half2_ops"] = true
    %w[__hadd2 __hsub2 __hmul2 __hdiv2].each { |n| needed[n] = true }
  end
  needed["is_same"] = true if needed["is_same_v"]   # std::is_same_v is rewritten to std::is_same (rewrite_is_same_v)
  BUILTIN_DEFS.each do |name, text|
    next unless needed[name]
    next if pieces.any? { |pc| pc[:keep] && pc[:defined].include?(name) }
    out << text
  end
  if (needed["cg"] || needed["cooperative_groups"]) && pieces.none? { |pc| pc[:keep] && pc[:defined].include?("cooperative_groups") }
    out << COOP_DEF
  end
  pieces.each do |pc|
    next unless pc[:keep]
    out << rewrite_is_same_v(rewrite_builtins(pc[:text])) << "\n"
  end
  $sites.each do |w, site|
    out << "extern \"C\" void #{w}(#{site[:decl]}) { #{site[:name]}<#{site[:targs]}>(#{site[:call].join(", ")}); }\n"
    kernels << w
  end
  [out, kernels.uniq]
end

# std::is_same_v<A, B> is a variable template, and the emitter lowers only zero-initialized globals, so a device
# unit reads it through the struct form: std::is_same<A, B>::value (the prelude defines both over plain types).
# Literals and comments are skipped; the closing '>' is the one that balances the '<' after is_same_v.
def rewrite_is_same_v(s)
  key = "std::is_same_v<"
  out = ""
  i = 0
  while i < s.length
    e = skip_literal(s, i)
    if e
      out << s[i...e]
      i = e
      next
    end
    if s[i, key.length] == key && !(i > 0 && ident_char?(s[i - 1]))
      j = i + key.length
      depth = 1
      while j < s.length && depth > 0
        e2 = skip_literal(s, j)
        if e2
          j = e2
          next
        end
        depth += 1 if s[j] == "<"
        depth -= 1 if s[j] == ">"
        j += 1
      end
      out << "std::is_same<" << s[(i + key.length)...(j - 1)] << ">::value"
      i = j
      next
    end
    out << s[i]
    i += 1
  end
  out
end

# __launch_bounds__(...) is a compile hint (register and occupancy limits). The launch path does not use it, so it
# is removed with its argument list, host and device units alike. Literals and comments are skipped.
def strip_launch_bounds(s)
  out = ""
  i = 0
  while i < s.length
    e = skip_literal(s, i)
    if e
      out << s[i...e]
      i = e
      next
    end
    if word_at?(s, i, "__launch_bounds__")
      j = i + "__launch_bounds__".length
      j += 1 while j < s.length && white?(s[j])
      if j < s.length && s[j] == "("
        close = matching_paren(s, j)
        refuse("unterminated __launch_bounds__") if close.nil?
        # keep the newlines inside the argument list, so line numbers do not move
        out << ("\n" * s[i..close].count("\n"))
        i = close + 1
        next
      end
    end
    out << s[i]
    i += 1
  end
  out
end

# Dynamic shared memory: `extern __shared__ T name[];` has no size at compile time (the launch gives the bytes), so
# the declaration is removed and each `name[...]` becomes a subscript of a pointer from __nfcxx_dynshared_addr(),
# the block's dynamic shared memory. The device side lowers that call to the address of a module-level
# `.extern .shared` symbol (the emitter's job); the host copy has a placeholder (lib/cuda/nfcxx_cuda.h). A pointer
# subscript has no bounds check, which is right: the size is only known at launch.
def dynamic_shared_rewrite(s)
  names = {}
  out = ""
  i = 0
  while i < s.length
    e = skip_literal(s, i)
    if e
      out << s[i...e]
      i = e
      next
    end
    if word_at?(s, i, "extern")
      j = i + 6
      j += 1 while j < s.length && white?(s[j])
      if word_at?(s, j, "__shared__")
        k = j + 10
        semi = s.index(";", k)
        refuse("extern __shared__ declaration without ';'") if semi.nil?
        decl = s[k...semi].strip
        m = decl.rindex("[")
        refuse("extern __shared__ #{decl}: only an unsized array (T name[]) is dynamic shared memory") unless m && decl.end_with?("]") && decl[(m + 1)...-1].strip.empty?
        head = decl[0...m].strip
        q = head.length
        q -= 1 while q > 0 && ident_char?(head[q - 1])
        name = head[q...head.length]
        type = head[0...q].strip
        refuse("extern __shared__ #{decl}: no type or name") if name.empty? || type.empty?
        names[name] = type
        out << ("\n" * s[i..semi].count("\n"))
        i = semi + 1
        next
      end
    end
    out << s[i]
    i += 1
  end
  return out if names.empty?
  replace_dynamic_uses(out, names)
end

# Replaces the uses `name[` of the dynamic shared arrays. A member (`.name`, `->name`) is not a use. A static
# `__shared__ T name[N]` declared in a block (a type word right before the name) shadows the dynamic name until the
# block closes: ggml-cuda has a dynamic `ids_dst_shared` in one kernel and a static one in another.
STATEMENT_KEYWORDS = %w[return case else do sizeof throw delete new goto co_return co_await co_yield].freeze

def replace_dynamic_uses(s, names)
  out = ""
  i = 0
  depth = 0
  shadows = [] # [name, depth] of static shared declarations in an open block
  while i < s.length
    e = skip_literal(s, i)
    if e
      out << s[i...e]
      i = e
      next
    end
    if s[i] == "{"
      depth += 1
    elsif s[i] == "}"
      depth -= 1
      shadows.pop while shadows.any? && shadows.last[1] > depth
    end
    if ident_char?(s[i]) && !(s[i] >= "0" && s[i] <= "9")
      j = i
      j += 1 while j < s.length && ident_char?(s[j])
      tok = s[i...j]
      q = i - 1
      q -= 1 while q >= 0 && white?(s[q])
      member = q >= 0 && (s[q] == "." || (s[q] == ">" && q > 0 && s[q - 1] == "-"))
      n = j
      n += 1 while n < s.length && white?(s[n])
      if names.key?(tok) && !member && s[n] == "["
        prev_end = q + 1
        p = q
        p -= 1 while p >= 0 && ident_char?(s[p])
        prev = s[(p + 1)...prev_end]
        if prev.length > 0 && !(prev[0] >= "0" && prev[0] <= "9") && !STATEMENT_KEYWORDS.include?(prev)
          shadows << [tok, depth]
          out << tok
        elsif shadows.any? { |name, _| name == tok }
          out << tok
        else
          out << "((#{names[tok]} *)__nfcxx_dynshared_addr())"
        end
        i = j
        next
      end
      out << tok
      i = j
      next
    end
    out << s[i]
    i += 1
  end
  out
end

def usage
  $stderr.puts "usage: cuda-rewrite.rb [--device [--kernels=FILE]] FILE.cu"
  exit(2)
end

device = false
kernels_path = nil
path = nil
# The host copy of a unit gives each kernel internal linkage (static), as nvcc does: two translation units that
# include the same header with a kernel must not define the same host symbol. The embedded registration of each
# unit refers to its own host copy. Literals and comments are skipped; only the whole identifier is replaced.
# The storage keyword a host copy gets: `static`, unless the declaration already has one (then the qualifier goes).
# The check is on the declaration so far (from the last ; { or }), so `static constexpr __device__ int f()` keeps
# its one storage class.
def host_storage(out, kw)
  start = [out.rindex(";"), out.rindex("{"), out.rindex("}")].compact.max
  decl = start ? out[(start + 1)..-1] : out
  already = false
  word = ""
  (decl + " ").each_char do |c|
    if ident_char?(c)
      word << c
    else
      already = true if word == "static"
      word = ""
    end
  end
  already ? "" : kw
end

# True when the output so far is inside a class, struct or union body (the innermost unmatched {). A member keeps its
# own linkage: `static` on a member function (or a constructor, or a const member) is an error.
def in_class_body?(out)
  depth = 0
  j = out.length - 1
  while j >= 0
    c = out[j]
    if c == "}"
      depth += 1
    elsif c == "{"
      if depth == 0
        # The head is the text since the last ; { or }: `struct Name` (or `class Name : Base`) names a class body.
        start = [out.rindex(";", j - 1), out.rindex("}", j - 1), out.rindex("{", j - 1)].compact.max
        head = start ? out[(start + 1)...j] : out[0...j]
        word = ""
        (head + " ").each_char do |ch|
          if ident_char?(ch)
            word << ch
          else
            return true if KEYWORDS_OF_CLASS.include?(word)
            word = ""
          end
        end
        return false
      end
      depth -= 1
    end
    j -= 1
  end
  false
end

KEYWORDS_OF_CLASS = %w[class struct union]

def host_linkage(text)
  out = ""
  i = 0
  word = "__global__"
  while i < text.length
    e = skip_literal(text, i)
    if e
      out << text[i...e]
      i = e
      next
    end
    if text[i, word.length] == word && !(i > 0 && ident_char?(text[i - 1])) && !ident_char?(text[i + word.length])
      out << host_storage(out, "static")
      i += word.length
      next
    end
    # A __device__ function (not a variable) is device-only code, but its host copy would still be an external symbol:
    # the same header in two units would define it twice. Its host copy is static too.
    if text[i, 8] == "__device" && !(i > 0 && ident_char?(text[i - 1])) && text[i, 10] == "__device__" &&
       !ident_char?(text[i + 10])
      j = i + 10
      j += 1 while j < text.length && (text[j] == " " || text[j] == "\n" || text[j] == "\t")
      k = j
      k += 1 while k < text.length && !"(=;{".include?(text[k])
      if k < text.length && text[k] == "("
        # `__device__ static T f(...)`: the keyword after the qualifier already gives the storage class.
        # A class member keeps its linkage (static is not allowed on a member function, const member or constructor).
        after_static = text[j, 6] == "static" && !ident_char?(text[j + 6])
        out << (after_static || in_class_body?(out) ? "" : host_storage(out, "static"))
        i += 10
        next
      end
    end
    out << text[i]
    i += 1
  end
  out
end

# The text with its comments blanked: each comment character becomes a space, a newline stays. Parentheses and
# quotes inside a comment then cannot confuse a scan of the text (a comment's `(` made a top-level piece look like a
# host function). Positions and line numbers do not change.
def blank_comments(text)
  out = ""
  i = 0
  n = text.length
  while i < n
    c = text[i]
    if c == "/" && text[i + 1] == "/"
      while i < n && text[i] != "\n"
        out << " "
        i += 1
      end
      next
    end
    if c == "/" && text[i + 1] == "*"
      close = text.index("*/", i + 2)
      stop = close.nil? ? n : close + 2
      while i < stop
        out << (text[i] == "\n" ? "\n" : " ")
        i += 1
      end
      next
    end
    e = skip_literal(text, i)
    if e
      out << text[i...e]
      i = e
      next
    end
    out << c
    i += 1
  end
  out
end

ARGV.each do |a|
  if a.start_with?("-I")
    $incdirs << a[2..-1]
  elsif a == "--device"
    device = true
    $device = true
  elsif a.start_with?("--kernels=")
    kernels_path = a[10..-1]
  elsif path.nil?
    path = a
  else
    usage
  end
end
usage if path.nil?
text = File.open(path, "rb") { |f| f.read }
text = blank_comments(text) if device
text = dynamic_shared_rewrite(strip_launch_bounds(text))
$expanded = expand_includes(text, File.dirname(path), 0)
$expanded = launch_prepare($expanded)
if device
  # The device unit is built from the conditionals of the device pass (see resolve_conditionals).
  defs = {}
  DEVICE_PASS_MACROS.each { |k, v| defs[k] = v }
  $expanded = resolve_conditionals($expanded, defs)
  # #include lines of system headers (and of headers not inlined) are not in the device unit: a top-level piece may
  # carry one in front of a declaration, so they are removed here, not by the piece's keep decision.
  $expanded = $expanded.split("\n").reject { |l| l.lstrip.start_with?("#include") || (l.lstrip.start_with?("#") && l.lstrip[1..-1].to_s.lstrip.start_with?("include")) }.join("\n")
  dev, kernels = device_tu($expanded)
  File.open(kernels_path, "wb") { |f| f.write(kernels.map { |k| k + "\n" }.join) } unless kernels_path.nil?
  print dev
else
  # The host copy has the local headers expanded too: their launches are in the host unit as well.
  print host_linkage(rewrite($expanded, path))
end
