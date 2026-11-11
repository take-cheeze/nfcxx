# strip-atomic.rb: mruby port of strip-atomic.py (oracle) (docs/notes/mruby-scripting.md).
# cproc has no _Atomic. Rewrites, in preprocessed C, _Atomic(T) to T (the qualifier only changes how the member is
# accessed, not its layout; the atomic operations are calls into libc++) and drops a bare _Atomic keyword. Balanced
# parentheses, so an argument that spans lines or nests parentheses is handled. Used on macOS by scripts/qbe-cc.
# Reads stdin and writes stdout as bytes: no Regexp in mruby, so the keyword is found by hand.

KEYWORD = "_Atomic"
UNDERSCORE = 95
OPEN_PAREN = 40
CLOSE_PAREN = 41

def ident_byte?(b)
  return false if b.nil?
  (b >= 48 && b <= 57) || (b >= 65 && b <= 90) || (b >= 97 && b <= 122) || b == UNDERSCORE
end

# The keyword at byte i, as a whole word (not part of a longer identifier).
def keyword_at?(text, i)
  return false unless text.byteslice(i, KEYWORD.bytesize) == KEYWORD
  before = i > 0 ? text.getbyte(i - 1) : nil
  !ident_byte?(before) && !ident_byte?(text.getbyte(i + KEYWORD.bytesize))
end

def strip(text)
  out = []
  n = text.bytesize
  i = 0
  while true
    m = nil
    j = i
    while j < n
      if text.getbyte(j) == UNDERSCORE && keyword_at?(text, j)
        m = j
        break
      end
      j += 1
    end
    if m.nil?
      out << text.byteslice(i, n - i) if i < n
      break
    end
    out << text.byteslice(i, m - i)
    k = m + KEYWORD.bytesize
    while k < n && [32, 9, 10].include?(text.getbyte(k))
      k += 1
    end
    if k < n && text.getbyte(k) == OPEN_PAREN
      # The inner type, without the parentheses; an unbalanced one runs to the end, as in the Python original.
      depth = 0
      e = k
      while e < n
        c = text.getbyte(e)
        if c == OPEN_PAREN
          depth += 1
        elsif c == CLOSE_PAREN
          depth -= 1
          break if depth == 0
        end
        e += 1
      end
      out << text.byteslice(k + 1, e - (k + 1))
      i = e + 1
    else
      # A bare keyword is dropped; the whitespace after it stays.
      i = m + KEYWORD.bytesize
    end
  end
  out.join
end

$stdout.write(strip($stdin.read))
