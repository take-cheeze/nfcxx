# qbe2cil.rb: translate one translation unit's QBE IL (cproc's output, after qbe-prep.rb) into a JSON fragment that
# scripts/cil-link.py links into one CIL assembly (the nfcc `cil` backend; docs/notes/cil.md).
#
#   scripts/mrb scripts/qbe2cil.rb IN.ssa TAIL.s TU_NAME OUT.json
#
# Memory model: a C pointer is an int64 address in unmanaged memory (calloc at startup). Loads and stores are
# ldind/stind through conv.u. Each QBE temporary is an IL local (SSA: one definition). A phi becomes a copy on each
# edge; the copies go through the evaluation stack first, so they are one parallel assignment. Stack slots
# (`alloc`) are carved from one localloc per call. A global symbol's address is the IL static field
# `addr_<name>`, which the linker fills in. Symbols not exported by the unit are renamed `name@<TU>`.
# Refused with an error, not miscompiled: variadic definitions (va_start), bit casts other than float<->int of the
# same size, and inline asm.
#
# mruby has no Regexp, so every pattern of the Python original (tests/mruby/oracle/qbe2cil.py) is a hand-written
# scanner here, and the JSON is written by hand in json.dump(indent=1) format with ensure_ascii. Float constants are
# converted exactly (dec_to_double, hex_to_double), since String#to_f is not correctly rounded.
# Differences that no QBE IL from cproc can reach: Python's \s also matches non-ASCII spaces; a non-ASCII byte inside a
# string literal of a data item is taken as a byte (Python reads a code point); Python's `float()` accepts underscores.

WS = Array.new(256, false)
[9, 10, 11, 12, 13, 28, 29, 30, 31, 32].each { |k| WS[k] = true }   # Python's \s and str.strip() on ASCII

IL_TYPE = { 'w' => 'int32', 'l' => 'int64', 's' => 'float32', 'd' => 'float64' }
LOADS = {  # QBE load -> [ldind suffix, QBE type of the value it produces]
  'loadsb' => ['i1', 'w'], 'loadub' => ['u1', 'w'], 'loadsh' => ['i2', 'w'], 'loaduh' => ['u2', 'w'],
  'loadsw' => ['i4', 'w'], 'loaduw' => ['u4', 'w'], 'loadw' => ['i4', 'w'], 'loadl' => ['i8', 'l'],
  'loads' => ['r4', 's'], 'loadd' => ['r8', 'd'],
}
STORES = {  # QBE store -> [stind suffix, QBE type of the value]
  'storeb' => ['i1', 'w'], 'storeh' => ['i2', 'w'], 'storew' => ['i4', 'w'], 'storel' => ['i8', 'l'],
  'stores' => ['r4', 's'], 'stored' => ['r8', 'd'],
}
INT_OPS = {
  'add' => 'add', 'sub' => 'sub', 'mul' => 'mul', 'div' => 'div', 'udiv' => 'div.un', 'rem' => 'rem',
  'urem' => 'rem.un', 'and' => 'and', 'or' => 'or', 'xor' => 'xor', 'shl' => 'shl', 'shr' => 'shr.un', 'sar' => 'shr',
}
SHIFT_OPS = ['shl', 'shr', 'sar']
FLT_OPS = { 'add' => 'add', 'sub' => 'sub', 'mul' => 'mul', 'div' => 'div' }
CONV = {  # QBE conversion -> [source QBE type, result QBE type, IL instructions]
  'extsw' => ['w', 'l', ['conv.i8']], 'extuw' => ['w', 'l', ['conv.u8']],
  'extsh' => ['w', 'w', ['conv.i2']], 'extuh' => ['w', 'w', ['conv.u2']],
  'extsb' => ['w', 'w', ['conv.i1']], 'extub' => ['w', 'w', ['conv.u1']],
  'exts' => ['s', 'd', ['conv.r8']], 'truncd' => ['d', 's', ['conv.r4']],
  'stosi' => ['s', 'w', ['conv.i4']], 'dtosi' => ['d', 'w', ['conv.i4']],
  'stoui' => ['s', 'w', ['conv.u4']], 'dtoui' => ['d', 'w', ['conv.u4']],
  'stosl' => ['s', 'l', ['conv.i8']], 'dtosl' => ['d', 'l', ['conv.i8']],
  'stoul' => ['s', 'l', ['conv.u8']], 'dtoul' => ['d', 'l', ['conv.u8']],
  'swtof' => ['w', 's', ['conv.r4']], 'swtod' => ['w', 'd', ['conv.r8']],
  'sltof' => ['l', 's', ['conv.r4']], 'sltod' => ['l', 'd', ['conv.r8']],
  'uwtof' => ['w', 's', ['conv.r.un', 'conv.r4']], 'uwtod' => ['w', 'd', ['conv.r.un', 'conv.r8']],
  'ultof' => ['l', 's', ['conv.r.un', 'conv.r4']], 'ultod' => ['l', 'd', ['conv.r.un', 'conv.r8']],
}
BITCAST = {  # result QBE type -> [source QBE type, System.BitConverter method]
  's' => ['w', 'System.BitConverter::Int32BitsToSingle(int32)'],
  'w' => ['s', 'System.BitConverter::SingleToInt32Bits(float32)'],
  'd' => ['l', 'System.BitConverter::Int64BitsToDouble(int64)'],
  'l' => ['d', 'System.BitConverter::DoubleToInt64Bits(float64)'],
}
FIELD_SIZE = { 'b' => [1, 1], 'h' => [2, 2], 'w' => [4, 4], 'l' => [8, 8], 's' => [4, 4], 'd' => [8, 8] }
DATA_WIDTH = { 'b' => 1, 'h' => 2, 'w' => 4, 'l' => 8, 's' => 4, 'd' => 8 }
DATA_NAME = { 'b' => 'int8', 'h' => 'int16', 'w' => 'int32', 'l' => 'int64', 's' => 'float32', 'd' => 'float64' }
REL_OPS = ['eq', 'ne', 'lt', 'le', 'gt', 'ge']

# ---- byte helpers ----------------------------------------------------------------------------------------------

def die(msg)
  $stderr.puts 'qbe2cil: ' + msg
  exit 1
end

def ws?(b)
  !b.nil? && WS[b]
end

def digit?(b)
  !b.nil? && b >= 48 && b <= 57
end

def skip_ws(s, p)
  p += 1 while p < s.bytesize && WS[s.getbyte(p)]
  p
end

def skip_nonws(s, p)
  p += 1 while p < s.bytesize && !WS[s.getbyte(p)]
  p
end

def all_digits?(s, from = 0, to = s.bytesize)
  return false if from >= to
  k = from
  while k < to
    return false unless digit?(s.getbyte(k))
    k += 1
  end
  true
end

# Python's str.strip() on the bytes of an ASCII string.
def py_strip(s)
  a = 0
  b = s.bytesize
  a += 1 while a < b && WS[s.getbyte(a)]
  b -= 1 while b > a && WS[s.getbyte(b - 1)]
  s.byteslice(a, b - a)
end

def rest_from(s, k)
  s.byteslice(k, s.bytesize - k)
end

# Python's str.split() (no argument): the whitespace-separated words.
def py_split(s)
  out = []
  i = 0
  n = s.bytesize
  while i < n
    i = skip_ws(s, i)
    break if i >= n
    j = skip_nonws(s, i)
    out << s.byteslice(i, j - i)
    i = j
  end
  out
end

# Python's str.split(None, 1): at most two parts; the rest keeps its trailing whitespace, loses its leading one.
def py_split1(s)
  i = skip_ws(s, 0)
  return [] if i >= s.bytesize
  j = skip_nonws(s, i)
  head = s.byteslice(i, j - i)
  k = skip_ws(s, j)
  return [head] if k >= s.bytesize
  [head, rest_from(s, k)]
end

# Python's str.split('\n'): a trailing empty piece is kept.
def split_lines(text)
  out = []
  start = 0
  n = text.bytesize
  i = 0
  while i < n
    if text.getbyte(i) == 10
      out << text.byteslice(start, i - start)
      start = i + 1
    end
    i += 1
  end
  out << text.byteslice(start, n - start)
  out
end

# Python's open(path, encoding='utf-8').read(): universal newlines on read; the bytes are otherwise kept.
def read_text(path)
  s = File.open(path, 'rb') { |f| f.read } || ''
  s = s.gsub("\r\n", "\n").gsub("\r", "\n") if s.include?("\r")
  s
end

# Python's split_top: split on the commas outside parentheses and string literals; the parts are stripped.
def split_top(s)
  out = []
  start = 0
  depth = 0
  quoted = false
  n = s.bytesize
  i = 0
  while i < n
    c = s.getbyte(i)
    quoted = !quoted if c == 34
    unless quoted
      if c == 40
        depth += 1
      elsif c == 41
        depth -= 1
      elsif c == 44 && depth == 0
        out << py_strip(s.byteslice(start, i - start))
        start = i + 1
      end
    end
    i += 1
  end
  rest = py_strip(rest_from(s, start))
  out << rest unless rest.empty?
  out
end

def strip_extern(tok)
  tok.start_with?('extern ') ? rest_from(tok, 7) : tok
end

def index_byte(s, c, from = 0)
  i = from
  n = s.bytesize
  while i < n
    return i if s.getbyte(i) == c
    i += 1
  end
  nil
end

# ---- integers and floats ---------------------------------------------------------------------------------------

# Python: int(text, 0) for the text of an integer constant, decimal / 0x / 0o / 0b with an optional sign.
def py_int0(text)
  s = text
  base = 10
  if s.bytesize > 2 && s.getbyte(0) == 48
    case s.getbyte(1)
    when 120, 88 then base = 16
    when 111, 79 then base = 8
    when 98, 66 then base = 2
    end
    s = rest_from(s, 2) if base != 10
  end
  ok = !s.empty? && s.getbyte(0) != 95 && s.getbyte(s.bytesize - 1) != 95 && !s.include?('__')
  digits = s.delete('_')
  if ok
    ok = digits.bytes.all? { |b|
      v = if b >= 48 && b <= 57 then b - 48
          elsif b >= 97 && b <= 102 then b - 87
          elsif b >= 65 && b <= 70 then b - 55
          else 99 end
      v < base
    }
  end
  ok &&= !(base == 10 && digits.bytesize > 1 && digits.getbyte(0) == 48 && digits.delete('0') != '')
  die "ValueError: invalid literal for int() with base 0: '#{text}'" unless ok
  digits.to_i(base)
end

def int_base0(text)
  if text.start_with?('-')
    -py_int0(rest_from(text, 1))
  elsif text.start_with?('+')
    py_int0(rest_from(text, 1))
  else
    py_int0(text)
  end
end

# Python: int(text) (base 10) for the decimal numbers of the IL (a field size, a blit length, an offset).
def py_int10(text)
  neg = text.start_with?('-')
  t = (neg || text.start_with?('+')) ? rest_from(text, 1) : text
  die "ValueError: invalid literal for int() with base 10: '#{text}'" unless all_digits?(t)
  v = t.to_i
  neg ? -v : v
end

# int_value(text, bits) of the Python original: the integer in two's complement of `bits` bits.
def int_value(text, bits)
  v = int_base0(text) % (1 << bits)
  v -= (1 << bits) if (v >> (bits - 1)) != 0
  v
end

def hexval(c)
  return nil if c.nil?
  return c - 48 if c >= 48 && c <= 57
  return c - 87 if c >= 97 && c <= 102
  return c - 55 if c >= 65 && c <= 70
  nil
end

# The double nearest to n / d (n > 0, d > 0), rounded half to even: the core of dec_to_double and hex_to_double.
def ratio_to_double(n, d)
  e2 = n.to_s(2).length - d.to_s(2).length  # floor(log2(n / d)) or one more
  ge = e2 >= 0 ? n >= (d << e2) : (n << (-e2)) >= d
  e2 -= 1 unless ge
  e2 = -1022 if e2 < -1022                  # subnormals share the exponent of the smallest normal
  sh = 52 - e2
  num = n
  den = d
  if sh >= 0
    num = n << sh
  else
    den = d << (-sh)
  end
  q, r = num.divmod(den)
  q += 1 if 2 * r > den || (2 * r == den && q.odd?)
  if q >= (1 << 53)
    q >>= 1
    e2 += 1
  end
  return Float::INFINITY if e2 > 1023
  bits = q < (1 << 52) ? q : ((e2 + 1023) << 52) | (q - (1 << 52))
  bytes = []
  8.times do
    bytes << (bits & 255)
    bits >>= 8
  end
  bytes.pack('C*').unpack('E')[0]
end

# The double nearest to m * 10**e (m >= 0), as float(str): correctly rounded, half to even.
def dec_to_double(m, e)
  return 0.0 if m == 0
  digs = m.to_s.length
  return Float::INFINITY if e + digs > 310
  return 0.0 if e + digs < -330
  if e >= 0
    ratio_to_double(m * (10**e), 1)
  else
    ratio_to_double(m, 10**(-e))
  end
end

# float(text) of the Python original's grammar ([sign] digits[.digits][e[sign]digits] | inf | infinity | nan).
# Returns nil where Python raises ValueError.
def py_float(text)
  low = text.downcase
  neg = false
  body = low
  if body.start_with?('-')
    neg = true
    body = rest_from(body, 1)
  elsif body.start_with?('+')
    body = rest_from(body, 1)
  end
  return(neg ? -Float::INFINITY : Float::INFINITY) if body == 'inf' || body == 'infinity'
  return nil if body == 'nan'
  i = 0
  n = body.bytesize
  digits = ''
  while i < n && digit?(body.getbyte(i))
    digits << body.byteslice(i, 1)
    i += 1
  end
  fraclen = 0
  if i < n && body.getbyte(i) == 46
    i += 1
    while i < n && digit?(body.getbyte(i))
      digits << body.byteslice(i, 1)
      fraclen += 1
      i += 1
    end
  end
  ok = !digits.empty?
  ex = 0
  if ok && i < n && body.getbyte(i) == 101
    i += 1
    eneg = false
    if i < n && (body.getbyte(i) == 43 || body.getbyte(i) == 45)
      eneg = body.getbyte(i) == 45
      i += 1
    end
    edigits = ''
    while i < n && digit?(body.getbyte(i))
      edigits << body.byteslice(i, 1)
      i += 1
    end
    ok = !edigits.empty?
    ex = edigits.to_i
    ex = -ex if eneg
  end
  return nil unless ok && i == n
  v = dec_to_double(digits.to_i, ex - fraclen)
  neg ? v * -1.0 : v   # (-v would lose the sign of a zero)
end

# float.fromhex(text) for [-]0x<hex>[.<hex>][p[+-]<dec>]; Python raises for a value that overflows.
def hex_to_double(text)
  n = text.bytesize
  p = 0
  neg = text.getbyte(0) == 45
  p = 1 if neg
  die "ValueError: could not convert string to float: '#{text}'" unless text.getbyte(p) == 48 &&
    (text.getbyte(p + 1) == 120 || text.getbyte(p + 1) == 88)
  p += 2
  mant = 0
  nd = 0
  frac = 0
  dot = false
  while p < n
    c = text.getbyte(p)
    if c == 46
      die "ValueError: could not convert string to float: '#{text}'" if dot
      dot = true
    elsif (h = hexval(c))
      mant = mant * 16 + h
      nd += 1
      frac += 1 if dot
    else
      break
    end
    p += 1
  end
  die "ValueError: could not convert string to float: '#{text}'" if nd == 0
  ex = 0
  if p < n && (text.getbyte(p) == 112 || text.getbyte(p) == 80)
    p += 1
    eneg = false
    if text.getbyte(p) == 43
      p += 1
    elsif text.getbyte(p) == 45
      eneg = true
      p += 1
    end
    st = p
    while p < n && digit?(text.getbyte(p))
      ex = ex * 10 + (text.getbyte(p) - 48)
      p += 1
    end
    die "ValueError: could not convert string to float: '#{text}'" if p == st
    ex = -ex if eneg
  end
  die "ValueError: could not convert string to float: '#{text}'" unless p == n
  e2 = ex - 4 * frac
  x = 0.0
  if mant != 0
    bl = mant.to_s(2).length
    die 'OverflowError: hexadecimal value too large to represent as a float' if bl + e2 > 1100
    if bl + e2 >= -1200
      if e2 >= 0
        x = ratio_to_double(mant << e2, 1)
      else
        x = ratio_to_double(mant, 1 << (-e2))
      end
      die 'OverflowError: hexadecimal value too large to represent as a float' unless x.finite?
    end
  end
  neg ? x * -1.0 : x
end

# struct.pack('<f', x) then unpack: the single-precision value of a double, rounded as C's cast does; Python raises
# OverflowError when a finite value rounds to infinity.
def to_single(x)
  r = [x].pack('e').unpack('e')[0]
  die 'OverflowError: float too large to pack with f format' if !r.finite? && x.finite?
  r
end

def le_int(bytes)
  v = 0
  bytes.reverse_each { |b| v = v * 256 + b }
  v
end

# The little-endian bytes of an unsigned integer of n bytes.
def le_bytes(v, n)
  out = []
  n.times do
    out << (v & 255)
    v >>= 8
  end
  out
end

def le_hex(v, n)
  le_bytes(v, n).map { |b| format('%02x', b) }.join(' ')
end

def nan_bits(single, neg)
  if single
    (neg ? 0x80000000 : 0) | 0x7fc00000
  else
    (neg ? (1 << 63) : 0) | 0x7ff8000000000000
  end
end

# float_bits of the Python original: a QBE float literal (d_1.5, s_3, d_-2.25, d_0x1p-1) as [IEEE bits, byte width].
# The width comes from the first letter of the token (`s` is 4 bytes, anything else 8).
def float_bits(tok)
  u = index_byte(tok, 95)
  die "IndexError: list index out of range (no '_' in '#{tok}')" if u.nil?
  single = tok.getbyte(0) == 115
  v = rest_from(tok, u + 1)
  low = v.downcase
  if low.start_with?('0x') || low.start_with?('-0x')
    x = hex_to_double(v)
  elsif low == 'nan' || low == '+nan' || low == '-nan'
    return [nan_bits(single, low == '-nan'), single ? 4 : 8]
  else
    x = py_float(v)
    die "ValueError: could not convert string to float: '#{v}'" if x.nil?
  end
  if single
    return [le_int([to_single(x)].pack('e').unpack('C*')), 4]
  end
  [le_int([x].pack('E').unpack('C*')), 8]
end

# ---- strings and json --------------------------------------------------------------------------------------------

# The code points of a byte string, decoded as Python's utf-8 'replace' does (a bad sequence is one U+FFFD for its
# valid prefix, then decoding goes on at the byte that broke it).
def utf8_cps(s)
  out = []
  n = s.bytesize
  i = 0
  while i < n
    b = s.getbyte(i)
    if b < 0x80
      out << b
      i += 1
      next
    end
    need = 0
    cp = 0
    lo = 0x80
    hi = 0xbf
    if b >= 0xc2 && b <= 0xdf
      need = 1
      cp = b & 0x1f
    elsif b >= 0xe0 && b <= 0xef
      need = 2
      cp = b & 0x0f
      lo = 0xa0 if b == 0xe0
      hi = 0x9f if b == 0xed
    elsif b >= 0xf0 && b <= 0xf4
      need = 3
      cp = b & 0x07
      lo = 0x90 if b == 0xf0
      hi = 0x8f if b == 0xf4
    else
      out << 0xfffd
      i += 1
      next
    end
    j = i + 1
    k = 0
    ok = true
    while k < need
      c = s.getbyte(j)
      l1 = k == 0 ? lo : 0x80
      h1 = k == 0 ? hi : 0xbf
      if c.nil? || c < l1 || c > h1
        ok = false
        break
      end
      cp = (cp << 6) | (c & 0x3f)
      j += 1
      k += 1
    end
    if ok
      out << cp
      i = j
    else
      out << 0xfffd
      i = j
    end
  end
  out
end

# json.dumps of a str with its default ensure_ascii=True: only printable ASCII is written as it is.
def json_string(s)
  buf = ['"']
  utf8_cps(s).each do |c|
    if c == 34 then buf << '\\"'
    elsif c == 92 then buf << '\\\\'
    elsif c == 10 then buf << '\\n'
    elsif c == 13 then buf << '\\r'
    elsif c == 9 then buf << '\\t'
    elsif c == 8 then buf << '\\b'
    elsif c == 12 then buf << '\\f'
    elsif c >= 32 && c <= 126 then buf << c.chr
    elsif c > 0xffff
      c2 = c - 0x10000
      buf << format('\\u%04x', 0xd800 | (c2 >> 10)) << format('\\u%04x', 0xdc00 | (c2 & 0x3ff))
    else
      buf << format('\\u%04x', c)
    end
  end
  buf << '"'
  buf.join
end

# json.dump(value, fh, indent=1): one space per nesting level, ", " items on their own lines, "[]" / "{}" when empty.
def json_dump(v, level, out)
  if v.is_a?(Hash)
    if v.empty?
      out << '{}'
      return
    end
    out << "{\n"
    first = true
    v.each do |k, x|
      out << ",\n" unless first
      first = false
      out << (' ' * (level + 1)) << json_string(k) << ': '
      json_dump(x, level + 1, out)
    end
    out << "\n" << (' ' * level) << '}'
  elsif v.is_a?(Array)
    if v.empty?
      out << '[]'
      return
    end
    out << "[\n"
    first = true
    v.each do |x|
      out << ",\n" unless first
      first = false
      out << (' ' * (level + 1))
      json_dump(x, level + 1, out)
    end
    out << "\n" << (' ' * level) << ']'
  elsif v.nil?
    out << 'null'
  elsif v == true
    out << 'true'
  elsif v == false
    out << 'false'
  elsif v.is_a?(String)
    out << json_string(v)
  else
    out << v.to_s
  end
end

# ---- the input text: the pieces of the Python regexes ------------------------------------------------------------

# '%name' then \s* '=': [name, index after '='], or nil. The name is [^\s=]+.
def assign_head(s)
  return nil unless s.getbyte(0) == 37
  n = s.bytesize
  p = 1
  p += 1 while p < n && !WS[s.getbyte(p)] && s.getbyte(p) != 61
  return nil if p == 1
  name = s.byteslice(1, p - 1)
  p = skip_ws(s, p)
  return nil unless s.getbyte(p) == 61
  [name, p + 1]
end

# `%name = <type letter> phi <rest>`: [name, letter, rest] or nil.
def phi_head(s)
  h = assign_head(s)
  return nil if h.nil?
  name, p = h
  c = s.getbyte(p)
  return nil unless c == 119 || c == 108 || c == 115 || c == 100
  p += 1
  return nil unless ws?(s.getbyte(p))
  p = skip_ws(s, p)
  return nil unless s.byteslice(p, 3) == 'phi'
  p += 3
  return nil unless ws?(s.getbyte(p))
  [name, c.chr, rest_from(s, skip_ws(s, p))]
end

# `%name = (:type) call <space>`: [name, type] or nil.
def agg_call_decl(s)
  h = assign_head(s)
  return nil if h.nil?
  name, p = h
  return nil unless s.getbyte(p) == 58
  e = skip_nonws(s, p)
  return nil if e - p < 2
  ty = s.byteslice(p, e - p)
  return nil unless ws?(s.getbyte(e))
  p = skip_ws(s, e)
  return nil unless s.byteslice(p, 4) == 'call' && ws?(s.getbyte(p + 4))
  [name, ty]
end

# `%name = l alloc(4|8|16) %...`: the name, or nil.
def dynamic_alloc(s)
  h = assign_head(s)
  return nil if h.nil?
  name, p = h
  return nil unless s.getbyte(p) == 108 && ws?(s.getbyte(p + 1))
  p = skip_ws(s, p + 1)
  return nil unless s.byteslice(p, 5) == 'alloc'
  p += 5
  alt = ['4', '8', '16'].find { |a| s.byteslice(p, a.bytesize) == a && ws?(s.getbyte(p + a.bytesize)) }
  return nil if alt.nil?
  p = skip_ws(s, p + alt.bytesize)
  return nil unless s.getbyte(p) == 37
  name
end

# `%name = [l|w|s|d] alloc(4|8|16) N`: [name, align, size] or nil.
def static_alloc(s)
  h = assign_head(s)
  return nil if h.nil?
  name, p = h
  c = s.getbyte(p)
  p += 1 if c == 108 || c == 119 || c == 115 || c == 100
  p = skip_ws(s, p)
  return nil unless s.byteslice(p, 5) == 'alloc'
  p += 5
  alt = ['4', '8', '16'].find { |a| s.byteslice(p, a.bytesize) == a && ws?(s.getbyte(p + a.bytesize)) }
  return nil if alt.nil?
  p = skip_ws(s, p + alt.bytesize)
  return nil unless digit?(s.getbyte(p))
  e = p
  e += 1 while digit?(s.getbyte(e))
  [name, alt.to_i, s.byteslice(p, e - p).to_i]
end

# `%name = <type letter> <space>`: [name, letter] or nil.
def plain_def(s)
  h = assign_head(s)
  return nil if h.nil?
  name, p = h
  c = s.getbyte(p)
  return nil unless c == 119 || c == 108 || c == 115 || c == 100
  return nil unless ws?(s.getbyte(p + 1))
  [name, c.chr]
end

# `%name = <type> <op> <rest>` with the type a letter or :aggregate: [name, type, op, rest] or nil.
def assignment_parts(s)
  h = assign_head(s)
  return nil if h.nil?
  name, p = h
  c = s.getbyte(p)
  if c == 119 || c == 108 || c == 115 || c == 100
    ty = c.chr
    p += 1
    return nil unless ws?(s.getbyte(p))
  elsif c == 58
    e = skip_nonws(s, p)
    return nil if e - p < 2
    ty = s.byteslice(p, e - p)
    p = e
    return nil unless ws?(s.getbyte(p))
  else
    return nil
  end
  p = skip_ws(s, p)
  e = skip_nonws(s, p)
  return nil if e == p
  op = s.byteslice(p, e - p)
  [name, ty, op, rest_from(s, skip_ws(s, e))]
end

# CMP_INT: c(s|u)?(eq|ne|lt|le|gt|ge)[wl]: [unsigned, rel, type letter] or nil.
def cmp_int(op)
  return nil unless op.getbyte(0) == 99
  i = 1
  un = false
  c1 = op.getbyte(1)
  if c1 == 115 || c1 == 117
    un = c1 == 117
    i = 2
  end
  return nil unless op.bytesize == i + 3
  rel = op.byteslice(i, 2)
  last = op.byteslice(i + 2, 1)
  return nil unless REL_OPS.include?(rel) && (last == 'w' || last == 'l')
  [un, rel, last]
end

# CMP_FLT: c(eq|ne|lt|le|gt|ge)[sd]: [rel, type letter] or nil.
def cmp_flt(op)
  return nil unless op.bytesize == 4 && op.getbyte(0) == 99
  rel = op.byteslice(1, 2)
  last = op.byteslice(3, 1)
  return nil unless REL_OPS.include?(rel) && (last == 's' || last == 'd')
  [rel, last]
end

# `type :name = [align N] { fields }`: [name, body] or nil. The name is the shortest run of non-space that
# makes the rest match (the regex is lazy).
def type_def(t)
  return nil unless t.start_with?('type') && ws?(t.getbyte(4))
  i = skip_ws(t, 4)
  return nil unless t.getbyte(i) == 58
  e = skip_nonws(t, i)
  k = i + 2
  while k <= e
    body = type_body(t, k)
    return [t.byteslice(i, k - i), body] if body
    k += 1
  end
  nil
end

# The part after a type name: \s*=\s*(align\s+\d+\s*)?\{(.*)\}\s*$ (t is stripped): the body, or nil.
def type_body(t, k)
  n = t.bytesize
  p = skip_ws(t, k)
  return nil unless t.getbyte(p) == 61
  p = skip_ws(t, p + 1)
  if t.byteslice(p, 5) == 'align'
    p += 5
    return nil unless ws?(t.getbyte(p))
    p = skip_ws(t, p)
    return nil unless digit?(t.getbyte(p))
    p += 1 while digit?(t.getbyte(p))
    p = skip_ws(t, p)
  end
  return nil unless t.getbyte(p) == 123 && t.getbyte(n - 1) == 125 && n - 1 > p
  t.byteslice(p + 1, n - 2 - p)
end

# The head of a function definition: [export?, return type or nil, name, index after the '('] or nil. The
# regex is ^(export\s+)?function\s+(?:([wlsd]|:\S+)\s+)?\$([^\s(]+)\(
def fn_head(s)
  exp = false
  p = nil
  if s.start_with?('export') && ws?(s.getbyte(6))
    q = skip_ws(s, 6)
    if s.byteslice(q, 8) == 'function'
      p = q + 8
      exp = true
    end
  end
  if p.nil? && s.start_with?('function')
    p = 8
  end
  return nil if p.nil? || !ws?(s.getbyte(p))
  p = skip_ws(s, p)
  ret = nil
  c = s.getbyte(p)
  if (c == 119 || c == 108 || c == 115 || c == 100) && ws?(s.getbyte(p + 1))
    ret = c.chr
    p = skip_ws(s, p + 1)
  elsif c == 58
    e = skip_nonws(s, p)
    if e - p >= 2 && ws?(s.getbyte(e))
      ret = s.byteslice(p, e - p)
      p = skip_ws(s, e)
    end
  end
  return nil unless s.getbyte(p) == 36
  q = p + 1
  q += 1 while q < s.bytesize && s.getbyte(q) != 40 && !WS[s.getbyte(q)]
  return nil unless s.getbyte(q) == 40 && q > p + 1
  [exp, ret, s.byteslice(p + 1, q - p - 1), q + 1]
end

# A function definition line: fn_head plus the rest of the line, `(params) {`. [export?, ret, name, params] or nil.
def fn_full(s)
  h = fn_head(s)
  return nil if h.nil?
  n = s.bytesize
  return nil unless n > 0 && s.getbyte(n - 1) == 123
  q = n - 2
  q -= 1 while q >= 0 && WS[s.getbyte(q)]
  return nil unless q >= 0 && s.getbyte(q) == 41 && q >= h[3]
  [h[0], h[1], h[2], s.byteslice(h[3], q - h[3])]
end

# The head of a data definition: [export?, name, index after the name] or nil. ^(export\s+)?data\s+\$([^\s=]+)
def data_head(s)
  exp = false
  p = nil
  if s.start_with?('export') && ws?(s.getbyte(6))
    q = skip_ws(s, 6)
    if s.byteslice(q, 4) == 'data'
      p = q + 4
      exp = true
    end
  end
  if p.nil? && s.start_with?('data')
    p = 4
  end
  return nil if p.nil? || !ws?(s.getbyte(p))
  p = skip_ws(s, p)
  return nil unless s.getbyte(p) == 36
  e = p + 1
  e += 1 while e < s.bytesize && !WS[s.getbyte(e)] && s.getbyte(e) != 61
  return nil if e == p + 1
  [exp, s.byteslice(p + 1, e - p - 1), e]
end

# A data definition: [export?, name, align, body] or nil.
# The regex is ^(export\s+)?data\s+\$([^\s=]+)\s*=\s*(align\s+(\d+)\s*)?\{(.*)\}\s*$
def data_full(s)
  h = data_head(s)
  return nil if h.nil?
  n = s.bytesize
  p = skip_ws(s, h[2])
  return nil unless s.getbyte(p) == 61
  p = skip_ws(s, p + 1)
  align = 1
  if s.byteslice(p, 5) == 'align'
    p += 5
    return nil unless ws?(s.getbyte(p))
    p = skip_ws(s, p)
    return nil unless digit?(s.getbyte(p))
    e = p
    e += 1 while digit?(s.getbyte(e))
    align = s.byteslice(p, e - p).to_i
    p = skip_ws(s, e)
  end
  return nil unless s.getbyte(p) == 123 && n > 0 && s.getbyte(n - 1) == 125 && n - 1 > p
  [h[0], h[1], align, s.byteslice(p + 1, n - 2 - p)]
end

# A `.quad NAME` line of the assembly tail (^\s*\.quad\s+(\S+)\s*$, one line at a time): NAME or nil.
def quad_name(line)
  p = skip_ws(line, 0)
  return nil unless line.byteslice(p, 5) == '.quad'
  p += 5
  return nil unless ws?(line.getbyte(p))
  p = skip_ws(line, p)
  e = skip_nonws(line, p)
  return nil if e == p
  return nil unless skip_ws(line, e) == line.bytesize
  line.byteslice(p, e - p)
end

# A string literal of a data item, from the quote at body[i]: [byte values, index after it]. A backslash takes three
# octal digits (a value above 255 is an error, as bytearray refuses it) or else the next byte itself.
def parse_string(body, i)
  out = []
  i += 1
  while body.getbyte(i) != 34
    c = body.getbyte(i)
    die 'IndexError: string index out of range' if c.nil?
    if c == 92 && i + 1 < body.bytesize && all_octal?(body.byteslice(i + 1, 3))
      digits = body.byteslice(i + 1, 3)
      v = digits.to_i(8)
      die 'ValueError: bytes must be in range(0, 256)' if v > 255
      out << v
      i += 4
    elsif c == 92
      die 'IndexError: string index out of range' if i + 1 >= body.bytesize
      out << body.getbyte(i + 1)
      i += 2
    else
      out << c
      i += 1
    end
  end
  [out, i + 1]
end

def all_octal?(s)
  return false if s.empty?
  s.bytes.all? { |b| b >= 48 && b <= 55 }
end

# The next item token of a data body at i: [text, symbol name or nil, offset, index after it], or nil. Python's
# \$([^\s,}+]+)(\s*\+\s*(-?\d+))?|[^\s,}]+ tried in that order.
def data_token(body, i)
  n = body.bytesize
  if body.getbyte(i) == 36
    j = i + 1
    j += 1 while j < n && !WS[body.getbyte(j)] && ![44, 125, 43].include?(body.getbyte(j))
    if j > i + 1
      name = body.byteslice(i + 1, j - i - 1)
      q = skip_ws(body, j)
      if body.getbyte(q) == 43
        q = skip_ws(body, q + 1)
        r = q
        r += 1 if body.getbyte(r) == 45
        if digit?(body.getbyte(r))
          e = r
          e += 1 while digit?(body.getbyte(e))
          return [body.byteslice(i, e - i), name, py_int10(body.byteslice(q, e - q)), e]
        end
      end
      return [body.byteslice(i, j - i), name, 0, j]
    end
  end
  j = i
  j += 1 while j < n && !WS[body.getbyte(j)] && ![44, 125].include?(body.getbyte(j))
  return nil if j == i
  [body.byteslice(i, j - i), nil, 0, j]
end

# The items of a data body and their size in bytes (parse_data of the Python original).
def parse_data_items(body, dname, unit)
  items = []
  size = 0
  i = 0
  n = body.bytesize
  while i < n
    c = body.getbyte(i)
    if c == 32 || c == 44 || c == 9
      i += 1
      next
    end
    if c == 122  # z: zero fill, `z N`
      q = i + 1
      die "AttributeError: 'NoneType' object has no attribute 'group' (data $#{dname})" unless ws?(body.getbyte(q))
      q = skip_ws(body, q)
      die "AttributeError: 'NoneType' object has no attribute 'group' (data $#{dname})" unless digit?(body.getbyte(q))
      e = q
      e += 1 while digit?(body.getbyte(e))
      num = body.byteslice(q, e - q).to_i
      items << ['zero', num]
      size += num
      i = e
      next
    end
    k = c.chr
    die "data $#{dname}: unsupported item #{body.byteslice(i, 20).inspect}" unless DATA_WIDTH.key?(k)
    i += 1
    i += 1 while body.getbyte(i) == 32
    if k == 'b' && body.getbyte(i) == 34
      data, i = parse_string(body, i)
      data.each { |b| items << ['int8', b] }
      size += data.size
      next
    end
    tok = data_token(body, i)
    die "AttributeError: 'NoneType' object has no attribute 'group' (data $#{dname})" if tok.nil?
    i = tok[3]
    if tok[0].start_with?('$')
      items << ['addr', unit.name(tok[1]), tok[2]]
      size += 8
    elsif k == 's' || k == 'd'
      bits, nb = float_bits(tok[0])
      items << [DATA_NAME[k], bits]
      size += nb
    else
      items << [DATA_NAME[k], int_value(tok[0], 8 * DATA_WIDTH[k])]
      size += DATA_WIDTH[k]
    end
  end
  [items, size]
end

# ---- units, types and definitions ---------------------------------------------------------------------------------

# Layout of the `type` declarations: {':name' => [size, align]}. Natural alignment, as QBE and C use.
def parse_types(lines)
  raw = {}
  lines.each do |ln|
    r = type_def(py_strip(ln))
    raw[r[0]] = split_top(r[1]) if r
  end
  layout = {}
  raw.keys.each { |name| size_align(name, raw, layout) }
  layout
end

def size_align(name, raw, layout)
  return layout[name] if layout.key?(name)
  die "unknown aggregate type #{name}" unless raw.key?(name)
  off = 0
  al = 1
  raw[name].each do |f|
    parts = py_split(f)
    die 'IndexError: list index out of range (empty field)' if parts.empty?
    if parts[0].start_with?(':')
      fs, fa = size_align(parts[0], raw, layout)
    else
      sz = FIELD_SIZE[parts[0]]
      die "KeyError: #{parts[0]}" if sz.nil?
      fs, fa = sz
      fs *= py_int10(parts[1]) if parts.size > 1
    end
    off = (off + fa - 1) / fa * fa + fs
    al = fa if fa > al
  end
  layout[name] = [(off + al - 1) / al * al, al]
  layout[name]
end

class Unit
  attr_reader :tu, :types, :fn_defs, :data_defs, :exported

  def initialize(tu, types)
    @tu = tu
    @types = types
    @fn_defs = {}
    @data_defs = {}
    @exported = {}
  end

  # The linker name of a symbol referenced in this unit.
  def name(sym)
    if @exported.key?(sym) || (!@fn_defs.key?(sym) && !@data_defs.key?(sym))
      return sym
    end
    "#{sym}@#{@tu}"
  end
end

def scan_definitions(lines, unit)
  pending = false
  lines.each do |ln|
    s = py_strip(ln)
    if s == 'export'
      pending = true
      next
    end
    h = fn_head(s)
    if h
      unit.fn_defs[h[2]] = true
      unit.exported[h[2]] = true if h[0] || pending
    end
    d = data_head(s)
    if d
      unit.data_defs[d[1]] = true
      unit.exported[d[1]] = true if d[0]
    end
    pending = false unless s.empty?
  end
end

# split_call of the Python original: `extern $f(args)` / `$f(args)` / `%p(args)` -> [callee, [arg, ...]].
def split_call(rest)
  rest = strip_extern(py_strip(rest))
  p = index_byte(rest, 40)
  die 'ValueError: substring not found' if p.nil?
  callee = py_strip(rest.byteslice(0, p))
  callee = rest_from(callee, 7) if callee.start_with?('extern ')
  rp = rindex_byte(rest, 41)
  die 'ValueError: substring not found' if rp.nil?
  len = rp - (p + 1)
  args = len > 0 ? split_top(rest.byteslice(p + 1, len)) : []
  [callee, args]
end

def rindex_byte(s, c)
  i = s.bytesize - 1
  while i >= 0
    return i if s.getbyte(i) == c
    i -= 1
  end
  nil
end

class Function
  attr_reader :next_index

  def initialize(unit, fragment, lines, start, exported, ret_letter, sym, params_text)
    @unit = unit
    @fragment = fragment
    @exported = exported
    @name = unit.name(sym)
    @params = []
    @arg_index = {}
    @agg_params = []  # [temp name, size, align, IL argument index]: copied into the frame on entry
    @agg_ret = nil    # [size, align] of an aggregate result: the caller passes its address first
    if ret_letter && ret_letter.start_with?(':')
      @agg_ret = type_of(ret_letter)
      @params << 'int64'
    end
    @ret = @agg_ret ? 'void' : (IL_TYPE[ret_letter] || 'void')
    split_top(params_text).each do |p|
      if p == '...'
        err_fn("variadic definitions (va_start) are not supported by the CIL backend")
      end
      parts = py_split1(p)
      die 'ValueError: not enough values to unpack' unless parts.size == 2
      t, v = parts
      err_fn('env parameters are not supported') if t == 'env'
      if t.start_with?(':')
        size, align = type_of(t)
        @agg_params << [rest_from(v, 1), size, align, @params.size]
        @params << 'int64'
        next
      end
      @arg_index[rest_from(v, 1)] = @params.size
      ty = IL_TYPE[t]
      die "KeyError: #{t}" if ty.nil?
      @params << ty
    end
    @body, @next_index = read_body(lines, start)
  end

  def type_of(name)
    t = @unit.types[name]
    die "KeyError: #{name}" if t.nil?
    t
  end

  def err_fn(msg)
    die "#{@name}: #{msg}"
  end

  def read_body(lines, i)
    body = []
    while true
      err_fn('no closing brace') if i >= lines.size
      s = py_strip(lines[i])
      i += 1
      return [body, i] if s == '}'
      body << s if !s.empty? && !s.start_with?('#')
    end
  end

  def err(msg)
    err_fn(msg)
  end

  def translate
    blocks = {}
    order = []
    cur = nil
    @body.each do |s|
      if s.start_with?('@')
        cur = rest_from(s, 1)
        blocks[cur] = []
        order << cur
      else
        err("instruction before the first label: #{s}") if cur.nil?
        blocks[cur] << s
      end
    end
    @blocks = blocks
    @order = order

    # Pass 1: temporaries (IL locals), stack slots (offsets in the frame), phi nodes.
    @temps = {}
    @arg_index.each { |n, idx| @temps[n] = ['arg', idx, @params[idx]] }
    @allocs = {}
    @slots = {}
    @dynamic = {}
    frame = 0
    @phis = {}
    order.each { |lbl| @phis[lbl] = [] }
    @local_types = []
    @copies = []  # [local index, frame offset, size, IL argument index] for aggregate parameters
    @agg_params.each do |name, size, align, argi|
      frame = (frame + align - 1) / align * align
      add_local(name, 'int64')
      @copies << [@temps[name][1], frame, size, argi]
      frame += size
    end
    order.each do |lbl|
      blocks[lbl].each do |s|
        agg = agg_call_decl(s)
        if agg  # an aggregate result: a slot in this frame, its address passed to the callee
          size, align = type_of(agg[1])
          frame = (frame + align - 1) / align * align
          @slots[agg[0]] = frame
          frame += size
          add_local(agg[0], 'int64')
          next
        end
        dyn = dynamic_alloc(s)
        if dyn  # alloca: a stack allocation of a run-time size, freed when the function returns
          @dynamic[dyn] = true
          add_local(dyn, 'int64')
          next
        end
        st = static_alloc(s)
        if st
          name, align, size = st
          frame = (frame + align - 1) / align * align
          @allocs[name] = frame
          frame += size
          add_local(name, 'int64')
          next
        end
        ph = phi_head(s)
        if ph
          pairs = []
          split_top(ph[2]).each do |part|
            pieces = py_split(part)
            die 'ValueError: not enough values to unpack' unless pieces.size == 2
            pairs << [rest_from(pieces[0], 1), pieces[1]]
          end
          @phis[lbl] << [ph[0], IL_TYPE[ph[1]], pairs]
        end
        pl = plain_def(s)
        if pl && !@temps.key?(pl[0])
          add_local(pl[0], IL_TYPE[pl[1]])
        end
      end
    end
    @frame = (frame + 15) / 16 * 16
    @frame_local = @local_types.size
    @local_types << 'int64'
    @label_id = {}
    order.each_with_index { |lbl, n| @label_id[lbl] = n }
    @out = []
    @counter = 0
    emit_body
    @fragment['functions'] << render
  end

  def add_local(name, il_type)
    @temps[name] = ['local', @local_types.size, il_type]
    @local_types << il_type
  end

  def new_label
    @counter += 1
    "T#{@counter}"
  end

  def emit(*lines)
    lines.each { |l| @out << l }
  end

  # operands ---------------------------------------------------------------

  # Push operand `tok` converted to IL type `want` (int32, int64, float32, float64, or 'addr' = int64).
  def operand(tok, want)
    tok = strip_extern(tok)
    if tok.start_with?('%')
      name = rest_from(tok, 1)
      err("undefined temporary #{tok}") unless @temps.key?(name)
      kind, idx, ty = @temps[name]
      emit(kind == 'arg' ? "ldarg #{idx}" : "ldloc #{idx}")
      return coerce(ty, want)
    end
    if tok.start_with?('$')
      sym = @unit.name(rest_from(tok, 1))
      @fragment['addrs'][sym] = true
      emit("ldsfld int64 Prog::'addr_#{sym}'")
      return coerce('int64', want)
    end
    if (tok.getbyte(0) == 115 || tok.getbyte(0) == 100) && tok.getbyte(1) == 95
      bits, n = float_bits(tok)
      if n == 4
        emit('ldc.r4 (' + le_hex(bits, 4) + ')')
        return coerce('float32', want)
      end
      emit('ldc.r8 (' + le_hex(bits, 8) + ')')
      return coerce('float64', want)
    end
    if want == 'int64' || want == 'addr'
      emit("ldc.i8 #{int_value(tok, 64)}")
      return coerce('int64', want)
    end
    emit("ldc.i4 #{int_value(tok, 32)}")
    coerce('int32', want)
  end

  def coerce(have, want)
    return if want.nil? || want == have || (want == 'addr' && have == 'int64')
    want = 'int64' if want == 'addr'
    il = case [have, want]
         when ['int32', 'int64'] then 'conv.i8'
         when ['int64', 'int32'] then 'conv.i4'
         when ['float32', 'float64'] then 'conv.r8'
         when ['float64', 'float32'] then 'conv.r4'
         end
    err("no conversion from #{have} to #{want}") if il.nil?
    emit(il)
  end

  def store_result(dst)
    err("undefined temporary %#{dst}") unless @temps.key?(dst)
    emit("stloc #{@temps[dst][1]}")
  end

  # control flow -----------------------------------------------------------

  def label_index(lbl)
    idx = @label_id[lbl]
    die "KeyError: #{lbl}" if idx.nil?
    idx
  end

  def phi_copies(src, dst)
    phis = @phis[dst]
    die "KeyError: #{dst}" if phis.nil?
    moves = []
    phis.each do |name, ty, pairs|
      pairs.each { |lab, val| moves << [name, ty, val] if lab == src }
    end
    moves.each { |_, ty, val| operand(val, ty) }
    moves.reverse.each { |name, _, _| store_result(name) }
  end

  def branch(src, dst)
    phi_copies(src, dst)
    emit("br B#{label_index(dst)}")
  end

  # instructions -----------------------------------------------------------

  def emit_body
    frame_local = @frame_local
    emit("ldc.i4 #{@frame}", 'localloc', 'conv.u8', "stloc #{frame_local}") if @frame != 0
    @copies.each do |local, off, size, argi|
      emit("ldloc #{frame_local}", "ldc.i8 #{off}", 'add', "stloc #{local}")
      emit("ldloc #{local}", 'conv.u', "ldarg #{argi}", 'conv.u', "ldc.i4 #{size}", 'cpblk')
    end
    @order.each_with_index do |lbl, n|
      emit("B#{label_index(lbl)}:")
      @blocks[lbl].each do |s|
        next if phi_head(s)
        instruction(s, lbl)
      end
      # cproc leaves out a jump to the next block: the block falls through (with its phi copies).
      last = @blocks[lbl].empty? ? '' : @blocks[lbl][-1]
      unless last.start_with?('jmp ') || last.start_with?('jnz ') || last.start_with?('ret') || last.start_with?('hlt')
        err("block #{lbl} falls off the end of the function") if n + 1 >= @order.size
        branch(lbl, @order[n + 1])
      end
    end
  end

  def instruction(s, lbl)
    parts = assignment_parts(s)
    return assignment(parts[0], parts[1], parts[2], parts[3], lbl) if parts
    if s.start_with?('blit ')  # blit src, dst, n: a block copy
      src, dst, n = split_top(rest_from(s, 5))
      die 'ValueError: blit operands' if n.nil?
      operand(dst, 'addr')
      emit('conv.u')
      operand(src, 'addr')
      emit('conv.u', "ldc.i4 #{py_int10(n)}", 'cpblk')
      return
    end
    if s.start_with?('store') && 'bhwlsd'.include?(s.byteslice(5, 1)) && s.bytesize > 5 && ws?(s.getbyte(6))
      suffix, vt = STORES['store' + s.byteslice(5, 1)]
      val, addr = split_top(rest_from(s, skip_ws(s, 6)))
      die 'ValueError: store operands' if addr.nil?
      operand(addr, 'addr')
      emit('conv.u')
      operand(val, IL_TYPE[vt])
      return emit("stind.#{suffix}")
    end
    if s == 'ret' || s.start_with?('ret ')
      if s != 'ret' && @agg_ret  # copy the aggregate into the caller's result slot
        emit('ldarg 0', 'conv.u')
        operand(rest_from(s, 4), 'addr')
        emit('conv.u', "ldc.i4 #{@agg_ret[0]}", 'cpblk')
      elsif s != 'ret'
        operand(rest_from(s, 4), @ret)
      end
      return emit('ret')
    end
    if s.start_with?('jmp ')
      return branch(lbl, rest_from(py_strip(rest_from(s, 4)), 1))
    end
    if s.start_with?('jnz ')
      cond, t, f = split_top(rest_from(s, 4))
      die 'ValueError: jnz operands' if f.nil?
      tramp = new_label
      operand(cond, 'int32')
      emit("brtrue #{tramp}")
      branch(lbl, rest_from(f, 1))
      emit("#{tramp}:")
      return branch(lbl, rest_from(t, 1))
    end
    if s.start_with?('hlt')
      return emit('ldc.i4.1', 'call void [System.Runtime]System.Environment::Exit(int32)', 'ldnull', 'throw')
    end
    if s.start_with?('call')
      callee, args = split_call(rest_from(s, 4))
      return call(nil, nil, callee, args)
    end
    err("unsupported instruction #{s}")
  end

  def assignment(dst, dty, op, rest, lbl)
    if op.start_with?('alloc') && @dynamic[dst]
      operand(rest, 'int64')
      emit('conv.u', 'localloc', 'conv.u8', "stloc #{@temps[dst][1]}")
      return
    end
    if dty.start_with?(':')  # an aggregate result: op is call; the slot's address is the value
      err("aggregate value from #{op}") if op != 'call'
      die "KeyError: #{dst}" if @slots[dst].nil?
      emit("ldloc #{@frame_local}", "ldc.i8 #{@slots[dst]}", 'add', "stloc #{@temps[dst][1]}")
      callee, args = split_call(rest)
      return call(dst, dty, callee, args)
    end
    dt = IL_TYPE[dty]
    die "KeyError: #{dty}" if dt.nil?
    if op.start_with?('alloc')
      die "KeyError: #{dst}" if @allocs[dst].nil?
      emit("ldloc #{@frame_local}", "ldc.i8 #{@allocs[dst]}", 'add', "stloc #{@temps[dst][1]}")
      return
    end
    return if op == 'phi'  # the copies are on the edges
    if op == 'call'
      callee, args = split_call(rest)
      return call(dst, dty, callee, args)
    end
    if LOADS.key?(op)
      suffix, rty = LOADS[op]
      operand(rest, 'addr')
      emit('conv.u', "ldind.#{suffix}")
      if rty == 'w' && dty == 'l'  # a 32-bit load widened to a long
        emit(%w[loadw loadsw loadsb loadsh].include?(op) ? 'conv.i8' : 'conv.u8')
      else
        coerce(IL_TYPE[rty], dt)
      end
      return store_result(dst)
    end
    if op == 'copy'
      operand(rest, dt)
      return store_result(dst)
    end
    if CONV.key?(op)
      src, _, il = CONV[op]
      operand(rest, IL_TYPE[src])
      emit(*il)
      return store_result(dst)
    end
    if op == 'cast'
      src, method = BITCAST[dty]
      die "KeyError: #{dty}" if src.nil?
      operand(rest, IL_TYPE[src])
      emit("call #{dt} [System.Runtime]#{method}")
      return store_result(dst)
    end
    if op == 'neg'
      operand(rest, dt)
      emit('neg')
      return store_result(dst)
    end
    if cmp_int(op) || cmp_flt(op)
      return compare(op, rest, dst)
    end
    if INT_OPS.key?(op) || FLT_OPS.key?(op)
      comma = index_byte(rest, 44)
      die 'ValueError: not enough values to unpack' if comma.nil?
      a = py_strip(rest.byteslice(0, comma))
      b = py_strip(rest_from(rest, comma + 1))
      if dty == 'w' || dty == 'l'
        err("#{op} on integers") unless INT_OPS.key?(op)
        operand(a, dt)
        operand(b, SHIFT_OPS.include?(op) ? 'int32' : dt)
        emit(INT_OPS[op])
      else
        err("#{op} on floats") unless FLT_OPS.key?(op)
        operand(a, dt)
        operand(b, dt)
        emit(FLT_OPS[op])
      end
      return store_result(dst)
    end
    if op == 'vastart' || op == 'vaarg'
      err('va_arg is not supported by the CIL backend')
    end
    err("unsupported instruction %#{dst} = #{dty} #{op} #{rest}")
  end

  def compare(op, rest, dst)
    comma = index_byte(rest, 44)
    die 'ValueError: not enough values to unpack' if comma.nil?
    a = py_strip(rest.byteslice(0, comma))
    b = py_strip(rest_from(rest, comma + 1))
    m = cmp_int(op)
    if m
      un = m[0]
      rel = m[1]
      t = IL_TYPE[m[2]]
    else
      m = cmp_flt(op)
      un = false
      rel = m[0]
      t = IL_TYPE[m[1]]
    end
    operand(a, t)
    operand(b, t)
    # Ordered floats: clt/cgt are false on NaN, so ordered le/ge are the negations of the unordered-true forms.
    case rel
    when 'eq' then emit('ceq')
    when 'ne' then emit('ceq', 'ldc.i4.0', 'ceq')
    when 'lt' then emit(un ? 'clt.un' : 'clt')
    when 'gt' then emit(un ? 'cgt.un' : 'cgt')
    when 'le' then emit(un ? 'cgt.un' : 'cgt', 'ldc.i4.0', 'ceq')   # not (a > b)
    else emit(un ? 'clt.un' : 'clt', 'ldc.i4.0', 'ceq')           # ge: not (a < b)
    end
    store_result(dst)
  end

  def call(dst, dty, callee, args)
    typed = []
    variadic = false
    args.each do |a|
      if a == '...'
        variadic = true
        next
      end
      parts = py_split1(a)
      unless parts.size == 2 && (IL_TYPE.key?(parts[0]) || parts[0].start_with?(':'))
        err("call argument without a type: #{a}")
      end
      typed << [parts[0].start_with?(':') ? 'int64' : IL_TYPE[parts[0]], parts[1]]
    end
    aggregate = !dty.nil? && dty.start_with?(':')
    ret = aggregate ? 'void' : (dty ? IL_TYPE[dty] : 'void')
    params = typed.map { |t, _| t }
    if aggregate
      err('variadic calls returning aggregates are not supported') if variadic
      emit("ldloc #{@temps[dst][1]}")
      params = ['int64'] + params
      dst = nil
    end
    return variadic_call(dst, dty, callee, typed) if variadic
    if callee.start_with?('%')  # indirect: a managed function pointer loaded from memory
      err('indirect calls returning aggregates are not supported') if aggregate
      typed.each { |t, v| operand(v, t) }
      operand(callee, 'int64')
      emit('conv.i')
      emit("calli #{ret} (#{params.join(', ')})")
    else
      cname = @unit.name(rest_from(callee, 1))
      sig = { 'ret' => ret, 'params' => params, 'variadic' => variadic }
      known = @fragment['calls'][cname]
      err("calls to #{cname} with two signatures") if known && known != sig
      @fragment['calls'][cname] = sig
      typed.each { |t, v| operand(v, t) }
      emit("call #{ret} Prog::'#{cname}'(#{params.join(', ')})")
    end
    if !dst.nil?
      store_result(dst)
    elsif ret != 'void'
      emit('pop')
    end
  end

  # A C variadic call (printf): .NET cannot call a variadic function through P/Invoke, and the SysV ABI needs %al
  # set to the number of vector registers used. The linker's shim nfcxx_vcall(name, six integer slots, eight
  # double slots) calls the function through a variadic prototype, which sets %al. Integer and floating arguments
  # keep their order within their own register class, as the callee expects.
  def variadic_call(dst, dty, callee, typed)
    err('indirect variadic calls are not supported by the CIL backend') if callee.start_with?('%') || !callee.start_with?('$')
    name = @unit.name(rest_from(callee, 1))
    ints = typed.select { |t, _| t == 'int32' || t == 'int64' }
    flts = typed.select { |t, _| t == 'float32' || t == 'float64' }
    err("#{name}: more than 14 integer or 8 floating arguments to a variadic call") if ints.size > 14 || flts.size > 8
    @fragment['calls'][name] = { 'ret' => 'int64', 'params' => [], 'variadic' => true }
    @fragment['variadic'] = true
    # Integer arguments 7 to 14 go on the stack, in order: the shim's last eight integer slots.
    emit("ldstr \"#{name}\"")
    6.times do |k|
      if k < ints.size
        operand(ints[k][1], 'int64')
      else
        emit('ldc.i8 0')
      end
    end
    8.times do |k|
      if k < flts.size
        operand(flts[k][1], 'float64')
      else
        emit('ldc.r8 (00 00 00 00 00 00 00 00)')
      end
    end
    8.times do |k|
      if k + 6 < ints.size
        operand(ints[k + 6][1], 'int64')
      else
        emit('ldc.i8 0')
      end
    end
    emit("call int64 Prog::'nfcxx_vcall'(string, int64, int64, int64, int64, int64, int64, float64, float64, " \
         "float64, float64, float64, float64, float64, float64, int64, int64, int64, int64, int64, int64, " \
         "int64, int64)")
    if dty.nil?
      emit('pop')
    elsif dty == 'w'
      emit('conv.i4')
    elsif dty == 'l'
      nil
    else
      err("#{name}: a variadic call returning a float is not supported")
    end
    store_result(dst) unless dst.nil?
  end

  def render
    text = [".method static #{@ret} '#{@name}'(#{@params.join(', ')}) cil managed {", '  .maxstack 1024']
    unless @local_types.empty?
      decls = []
      @local_types.each_with_index { |t, n| decls << "#{t} V#{n}" }
      text << '  .locals init (' + decls.join(', ') + ')'
    end
    @out.each { |x| text << (x.end_with?(':') ? x : '    ' + x) }
    text << '}'
    { 'name' => @name, 'ret' => @ret, 'params' => @params, 'exported' => @exported, 'il' => text }
  end
end

def main(argv)
  die 'usage: qbe2cil.rb IN.ssa TAIL.s TU_NAME OUT.json' if argv.size < 4
  src, tail_path, tu, out_path = argv[0], argv[1], argv[2], argv[3]
  lines = split_lines(read_text(src))
  tail = tail_path != '-' ? read_text(tail_path) : ''
  unit = Unit.new(tu, parse_types(lines))
  scan_definitions(lines, unit)
  ctors = split_lines(tail).map { |ln| quad_name(ln) }.compact.map { |c| unit.name(c) }
  fragment = { 'tu' => tu, 'functions' => [], 'data' => [], 'calls' => {}, 'addrs' => {}, 'ctors' => ctors }
  pending = false
  i = 0
  while i < lines.size
    s = py_strip(lines[i])
    i += 1
    next if s.empty? || s.start_with?('#')
    if s == 'export'
      pending = true
      next
    end
    next if s.start_with?('type ')
    d = data_full(s)
    if d
      items, size = parse_data_items(d[3], d[1], unit)
      fragment['data'] << { 'name' => unit.name(d[1]), 'exported' => d[0], 'align' => d[2], 'size' => size, 'items' => items }
      next
    end
    m = fn_full(s)
    die "unexpected line: #{s.byteslice(0, 80)}" if m.nil?
    f = Function.new(unit, fragment, lines, i, m[0] || pending, m[1], m[2], m[3])
    pending = false
    f.translate
    i = f.next_index
  end
  fragment['addrs'] = fragment['addrs'].keys.sort
  out = []
  json_dump(fragment, 0, out)
  File.open(out_path, 'wb') { |f| f.write(out.join) }
end

main(ARGV)
