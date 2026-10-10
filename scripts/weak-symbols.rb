# Emit `.weak` directives for functions and data objects that EDG marks __attribute__((__weak__)).
#
# EDG puts COMDAT functions (inline and template instantiations) in every translation unit that
# uses them (and COMDAT data: variable templates, static data members of templates, local statics of inline
# functions), marked __weak__. GCC honours the attribute so the link merges the copies; cproc drops
# attributes, so QBE emits them as strong symbols and the link fails with "multiple definition".
# Usage: scripts/mrb scripts/weak-symbols.rb [--c-input] PREPROCESSED_C ASSEMBLY  (appends .weak lines to ASSEMBLY)
#
# mruby has no Regexp, so the scanning is by hand. It mirrors the Python original (tests/mruby/oracle/weak-symbols.py) exactly.

SPACE = " \t\n\r\f\v"

def word_char?(c)
  c == "_" || (c >= "a" && c <= "z") || (c >= "A" && c <= "Z") || (c >= "0" && c <= "9")
end

def ident_start?(c)
  c == "_" || (c >= "a" && c <= "z") || (c >= "A" && c <= "Z")
end

# Remove __attribute__((...)) groups, which may contain nested parentheses.
def strip_attributes(s)
  out = []
  i = 0
  while true
    j = s.index("__attribute__", i)
    if j.nil?
      out << s[i, s.size - i]
      return out.join
    end
    out << s[i, j - i]
    k = j + "__attribute__".size
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
  while true
    w = text.index("__weak__", pos)
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
  asm.each_line do |line|
    c = line[0]
    next if c.nil?
    next unless ident_start?(c) || c == "." || c == "$"
    i = 1
    i += 1 while i < line.size && (word_char?(line[i]) || line[i] == "." || line[i] == "$")
    defs[line[0, i]] = true if line[i] == ":"
  end
  defs
end

extern_inline = true
args = ARGV.dup
if args.first == "--c-input"
  extern_inline = false
  args.shift
end
c_path, asm_path = args
text = File.open(c_path, "rb") { |f| f.read }
asm = File.open(asm_path, "rb") { |f| f.read }
defs = defined_labels(asm)
weak = weak_names(text, extern_inline).select { |n| defs[n] }.sort
unless weak.empty?
  File.open(asm_path, "ab") do |f|
    f.write("\n" + weak.map { |n| ".weak #{n}\n" }.join)
  end
end
