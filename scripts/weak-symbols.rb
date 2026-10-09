# Emit `.weak` directives for functions that EDG marks __attribute__((__weak__)).
#
# EDG puts COMDAT functions (inline and template instantiations) in every translation unit that
# uses them, marked __weak__. GCC honours the attribute so the link merges the copies; cproc drops
# attributes, so QBE emits them as strong symbols and the link fails with "multiple definition".
# Usage: scripts/mrb scripts/weak-symbols.rb PREPROCESSED_C ASSEMBLY  (appends .weak lines to ASSEMBLY)
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
# (leftmost match; inside a word run the match starts at its first letter or underscore).
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
    return s[b, e - b] if b < e
    from = q + 1
  end
end

# Declarations and definitions are delimited by ; { } at top level; each chunk that mentions __weak__
# names the function it declares.
def weak_names(text)
  names = {}
  pos = 0
  while true
    w = text.index("__weak__", pos)
    break if w.nil?
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
    n = first_call_name(strip_attributes(text[b, e - b]))
    names[n] = true if n
    pos = e + 1
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

c_path, asm_path = ARGV
text = File.open(c_path, "rb") { |f| f.read }
asm = File.open(asm_path, "rb") { |f| f.read }
defs = defined_labels(asm)
weak = weak_names(text).select { |n| defs[n] }.sort
unless weak.empty?
  File.open(asm_path, "ab") do |f|
    f.write("\n" + weak.map { |n| ".weak #{n}\n" }.join)
  end
end
