# Emit `.weak` directives for functions and data objects that EDG marks __attribute__((__weak__)).
#
# EDG puts COMDAT functions (inline and template instantiations) in every translation unit that
# uses them (and COMDAT data: variable templates, static data members of templates, local statics of inline
# functions), marked __weak__. GCC honours the attribute so the link merges the copies; cproc drops
# attributes, so QBE emits them as strong symbols and the link fails with "multiple definition".
# Usage: scripts/mrb scripts/weak-symbols.rb [--c-input] PREPROCESSED_C ASSEMBLY  (appends .weak lines to ASSEMBLY)
#
# mruby has no Regexp, so the scanning is by hand. It mirrors the Python original (tests/mruby/oracle/weak-symbols.py, deleted; the oracle port is tests/mruby/oracle/weak-symbols.rb).

SPACE = " \t\n\r\f\v"

def word_char?(c)
  c == "_" || (c >= "a" && c <= "z") || (c >= "A" && c <= "Z") || (c >= "0" && c <= "9")
end

def ident_start?(c)
  c == "_" || (c >= "a" && c <= "z") || (c >= "A" && c <= "Z")
end

# The first whole-word occurrence of kw in s at or after i, or nil.
def keyword_at(s, kw, i)
  while true
    j = s.index(kw, i)
    return nil if j.nil?
    return j unless (j > 0 && word_char?(s[j - 1])) || (j + kw.size < s.size && word_char?(s[j + kw.size]))
    i = j + 1
  end
end

# Remove __attribute__((...)) groups, which may contain nested parentheses, and _Alignas(...): qbe-prep.rb turns
# `T x[N] __attribute__((__aligned__(A)))` into `T _Alignas(A) x[N]`, and its "(" is not a function's.
def strip_attributes(s)
  out = []
  i = 0
  while true
    j = keyword_at(s, "__attribute__", i)
    a = keyword_at(s, "_Alignas", i)
    kw = "__attribute__"
    if a && (j.nil? || a < j)
      j = a
      kw = "_Alignas"
    end
    if j.nil?
      out << s[i, s.size - i]
      return out.join
    end
    out << s[i, j - i]
    k = j + kw.size
    k += 1 while k < s.size && SPACE.include?(s[k])
    depth = 0
    while k < s.size
      if s[k] == "("
        depth += 1
      elsif s[k] == ")"
        depth -= 1
        if depth == 0
          k += 1
          break
        end
      end
      k += 1
    end
    i = k
  end
end

# The first identifier followed by optional whitespace and "(": the Python regex [A-Za-z_]\w*\s*\(
# (leftmost match; inside a word run the match starts at its first letter or underscore), unless the "(" is
# followed by "*" or "(" (the Python regex has (?!\s*[*(]) after the parenthesis).
def first_call_name(s)
  from = 0
  while true
    q = s.index("(", from)
    return nil if q.nil?
    e = q
    e -= 1 while e > 0 && SPACE.include?(s[e - 1])
    b = e
    b -= 1 while b > 0 && word_char?(s[b - 1])
    b += 1 while b < e && !ident_start?(s[b])
    # "(" followed by "*" or "(" opens a grouping declarator, as in "void (**name(args))(void *)" (a function
    # returning a pointer to function): the word before it is a type, not the function name.
    if b < e
      n = q + 1
      n += 1 while n < s.size && SPACE.include?(s[n])
      return s[b, e - b] unless n < s.size && (s[n] == "*" || s[n] == "(")
    end
    from = q + 1
  end
end

# A word (identifier-delimited) occurs in s.
def has_word?(s, w)
  i = 0
  while true
    j = s.index(w, i)
    return false if j.nil?
    before = j == 0 ? " " : s[j - 1]
    after = j + w.size < s.size ? s[j + w.size] : " "
    return true if !word_char?(before) && !word_char?(after)
    i = j + w.size
  end
end

# Identifiers of s (outside attributes, which the caller strips).
def identifiers(s)
  ids = []
  i = 0
  while i < s.size
    c = s[i]
    if ident_start?(c)
      j = i + 1
      j += 1 while j < s.size && word_char?(s[j])
      ids << s[i, j - i]
      i = j
    elsif c >= "0" && c <= "9"
      i += 1
      i += 1 while i < s.size && word_char?(s[i])
    else
      i += 1
    end
  end
  ids
end

# The chunk (between the ; { } delimiters) around position w: [start, end].
def chunk_around(text, w)
  b = 0
  [";", "{", "}"].each do |d|
    x = w > 0 ? text.rindex(d, w - 1) : nil
    b = x + 1 if x && x + 1 > b
  end
  e = text.size
  [";", "{", "}"].each do |d|
    x = text.index(d, w)
    e = x if x && x < e
  end
  [b, e]
end

# Whether the __attribute__ at position a has a group that names weak (hand-written C: __attribute__((weak)); EDG's
# __weak__ is found on its own).
def attribute_weak?(text, a)
  i = text.index("(", a)
  return false if i.nil?
  depth = 0
  j = i
  n = text.bytesize
  while j < n
    c = text.getbyte(j)
    if c == 40
      depth += 1
    elsif c == 41
      depth -= 1
      break if depth == 0
    end
    j += 1
  end
  group = text[i, j - i + 1]
  # no "weak" substring in the group, no word: the common case (aligned, always_inline, ...)
  return false if group.index("weak").nil?
  has_word?(group, "weak") || has_word?(group, "__weak__")
end

# Declarations and definitions are delimited by ; { } at top level; each chunk that mentions __weak__
# names the function or object it declares. A function is the first identifier followed by "(". An object
# (COMDAT data: variable templates, static data members of templates, local statics of inline functions,
# helper constants such as __cmp_cat_id) has no such name, so every identifier before its "=" is a
# candidate; the caller keeps only the ones the assembly defines.
# With extern_inline, a function declared "extern" and "__inline__" is weak too: EDG emits the inline members of
# an "extern template" class that way (GNU89 meaning: the out-of-line copy lives in another translation unit,
# for libstdc++'s std::allocator<char> that is libstdc++ itself), while a C99 compiler such as cproc makes it a
# strong definition in every object that uses it.
def weak_names(text, extern_inline)
  names = {}
  pos = 0
  nw = text.index("__weak__", 0)       # the next EDG spelling
  na = text.index("__attribute__", 0)  # the next attribute group, which may be hand-written C's __attribute__((weak))
  while true
    # An attribute group counts when it names weak or __weak__.
    while na && !attribute_weak?(text, na)
      na = text.index("__attribute__", na + 13)
    end
    w = (nw && na) ? (nw < na ? nw : na) : (nw || na)
    break if w.nil?
    b, e = chunk_around(text, w)
    s = strip_attributes(text[b, e - b])
    q = s.index("=")
    s = s[0, q] if q
    n = first_call_name(s)
    if n
      names[n] = true
    else
      identifiers(s).each { |x| names[x] = true }
    end
    pos = e + 1
    nw = text.index("__weak__", pos) if nw && nw < pos
    na = text.index("__attribute__", pos) if na && na < pos
  end
  if extern_inline
    pos = 0
    while true
      w = text.index("__inline__", pos)
      break if w.nil?
      b, e = chunk_around(text, w)
      chunk = text[b, e - b]
      if has_word?(chunk, "extern") && !has_word?(chunk, "static")
        n = first_call_name(strip_attributes(chunk))
        names[n] = true if n
      end
      pos = e + 1
    end
  end
  names.keys
end

# Labels at the start of a line: ^([A-Za-z_.$][\w.$]*):
def defined_labels(asm)
  defs = {}
  n = asm.bytesize
  pos = 0
  while pos < n
    c = asm.getbyte(pos)
    # an instruction or directive line (tab or space) or an empty line: next line
    if c != 9 && c != 32 && c != 10 && (c == 95 || c == 46 || c == 36 || (c >= 97 && c <= 122) || (c >= 65 && c <= 90))
      i = pos + 1
      while i < n
        b = asm.getbyte(i)
        break unless b == 95 || b == 46 || b == 36 || (b >= 97 && b <= 122) || (b >= 65 && b <= 90) || (b >= 48 && b <= 57)
        i += 1
      end
      defs[asm.byteslice(pos, i - pos)] = true if i < n && asm.getbyte(i) == 58
    end
    nl = asm.index("\n", pos)
    break if nl.nil?
    pos = nl + 1
  end
  defs
end

extern_inline = true
# --sym-prefix=P: the target's prefix on every label (QBE's Apple targets prefix "_", so a Mach-O label is __Z5f for the C name
# _Z5f). The directive line names the label the assembly defines, so the names are looked up with the prefix. Empty elsewhere.
SYM_PREFIX_OPT = "--sym-prefix="
prefix = ""
# Mach-O (the prefixed mode): the Apple assembler rejects ".weak", and a weak definition is ".weak_definition".
weak_directive = ".weak "
args = ARGV.dup
while args.first && args.first[0, 2] == "--"
  opt = args.shift
  if opt == "--c-input"
    extern_inline = false
  elsif opt[0, SYM_PREFIX_OPT.size] == SYM_PREFIX_OPT
    prefix = opt[SYM_PREFIX_OPT.size, opt.size - SYM_PREFIX_OPT.size]
    weak_directive = ".weak_definition "
  end
end
c_path, asm_path = args
text = File.open(c_path, "rb") { |f| f.read }
asm = File.open(asm_path, "rb") { |f| f.read }
defs = defined_labels(asm)
weak = weak_names(text, extern_inline).map { |n| prefix + n }.select { |n| defs[n] }.sort
unless weak.empty?
  File.open(asm_path, "ab") do |f|
    f.write("\n" + weak.map { |n| "#{weak_directive}#{n}\n" }.join)
  end
end
