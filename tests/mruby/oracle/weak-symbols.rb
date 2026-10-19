# Oracle for scripts/weak-symbols.rb: an mruby port of the Python original tests/mruby/oracle/weak-symbols.py (deleted
# with this change; it is in the git history at 972fccf). It follows the original exactly, quirks included, so that
# tests/mruby/run.sh can compare the production script against it. Known differences of scripts/weak-symbols.rb from
# the original (this file matches the original): a digit run inside a name ("0x1F" gives the name "x1F"); input that
# is not UTF-8 (the original stops with status 1); a lone CR as a line end in the assembly.
#
# Emit `.weak` directives for functions and data objects that EDG marks __attribute__((__weak__)).
#
# EDG puts COMDAT functions (inline and template instantiations) in every translation unit that
# uses them (and COMDAT data: variable templates, static data members of templates, local statics of inline
# functions), marked __weak__. GCC honours the attribute so the link merges the copies; cproc drops
# attributes, so QBE emits them as strong symbols and the link fails with "multiple definition".
# Usage: scripts/mrb scripts/weak-symbols.rb [--c-input] PREPROCESSED_C ASSEMBLY  (appends .weak lines to ASSEMBLY)
#
# mruby has no Regexp, so the scanning is by hand. It mirrors the Python original (tests/mruby/oracle/weak-symbols.py, deleted) exactly.

SPACE = " \t\n\r\f\v\x1c\x1d\x1e\x1f"   # Python str.isspace() on ASCII text (re.\s, str.isspace)

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
      # A digit run is not an identifier, and the letters after it start one (as re.findall does: "0x1F" gives "x1F").
      i += 1
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

# str.decode("utf-8") succeeds: no bad sequence, no overlong form, no surrogate, nothing above U+10FFFF.
def utf8_valid?(s)
  i = 0
  n = s.bytesize
  while i < n
    c = s.getbyte(i)
    if c < 0x80
      i += 1
      next
    end
    if c >= 0xc2 && c <= 0xdf
      k = 1; lo = 0x80; hi = 0xbf
    elsif c == 0xe0
      k = 2; lo = 0xa0; hi = 0xbf
    elsif (c >= 0xe1 && c <= 0xec) || c == 0xee || c == 0xef
      k = 2; lo = 0x80; hi = 0xbf
    elsif c == 0xed
      k = 2; lo = 0x80; hi = 0x9f
    elsif c == 0xf0
      k = 3; lo = 0x90; hi = 0xbf
    elsif c >= 0xf1 && c <= 0xf3
      k = 3; lo = 0x80; hi = 0xbf
    elsif c == 0xf4
      k = 3; lo = 0x80; hi = 0x8f
    else
      return false
    end
    return false if i + k >= n
    d1 = s.getbyte(i + 1)
    return false if d1 < lo || d1 > hi
    j = 2
    while j <= k
      d = s.getbyte(i + j)
      return false if d < 0x80 || d > 0xbf
      j += 1
    end
    i += k + 1
  end
  true
end

# Labels at the start of a line: ^([A-Za-z_.$][\w.$]*):
def defined_labels(asm)
  defs = {}
  # Python reads the file in text mode, where a lone "\r" also ends a line (universal newlines): so does this.
  asm.each_line.flat_map { |whole| whole.split("\r") }.each do |line|
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
# open(...).read() decodes UTF-8 in the Python original: invalid bytes end the run with status 1.
raise "UnicodeDecodeError: invalid UTF-8" unless utf8_valid?(text) && utf8_valid?(asm)
defs = defined_labels(asm)
weak = weak_names(text, extern_inline).map { |n| prefix + n }.select { |n| defs[n] }.sort
unless weak.empty?
  File.open(asm_path, "ab") do |f|
    f.write("\n" + weak.map { |n| "#{weak_directive}#{n}\n" }.join)
  end
end
