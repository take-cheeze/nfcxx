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

def rewrite(text, orig)
  out = "#line 1 \"#{orig}\"\n"
  n = text.length
  i = 0
  while i < n
    e = skip_literal(text, i)
    if e
      out << text[i...e]
      i = e
      next
    end
    if text[i, 3] == "<<<" && !(i + 3 < n && text[i + 3] == "<")
      # The kernel name is the identifier just before `<<<` in the output so far.
      k = out.length
      k -= 1 while k > 0 && ident_char?(out[k - 1])
      name = out[k...out.length]
      line = text[0...i].count("\n") + 1
      refuse("template kernel name at line #{line}") if k > 0 && out[k - 1] == ">"
      refuse("launch without a kernel name at line #{line}") if name.empty?
      out = out[0...k]

      # The configuration runs to the first `>>>` outside brackets.
      j = i + 3
      depth = 0
      close_cfg = nil
      while j < n
        e2 = skip_literal(text, j)
        if e2
          j = e2
          next
        end
        c = text[j]
        if c == "(" || c == "[" || c == "{"
          depth += 1
        elsif c == ")" || c == "]" || c == "}"
          depth -= 1
        elsif depth == 0 && text[j, 3] == ">>>"
          close_cfg = j
          break
        end
        j += 1
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
      out << "__nfcxx_cuda_launch(#{name}, #{cfg[0]}, #{cfg[1]}, #{cfg[2]}, #{cfg[3]}"
      out << ", #{args}" unless args.empty?
      out << ")"
      out << ("\n" * lines)
      i = close_args + 1
      next
    end
    out << text[i]
    i += 1
  end
  out
end

path = ARGV[0]
if path.nil?
  $stderr.puts "usage: cuda-rewrite.rb FILE.cu"
  exit(2)
end
text = File.open(path, "rb") { |f| f.read }
print rewrite(text, path)
