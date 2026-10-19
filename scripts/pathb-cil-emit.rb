# pathb-cil-emit.rb: Path B IR (scripts/pathb-dump --ir) -> a JSON fragment for scripts/cil-link.rb, the CIL spike of the
# Path B route (docs/notes/pathb-cil.md). Same memory model as qbe2cil.rb: pointers are int64 addresses, frame slots are
# one localloc per call, globals are the linker's addr_<name> fields.
#
#   pathb-dump --ir x.cpp | scripts/mrb scripts/pathb-cil-emit.rb - OUT.json
#   scripts/mrb scripts/pathb-cil-emit.rb x.ir OUT.json
#
# The fragment goes to OUT.json (nothing on stdout). Exit status 1 with `pathb-cil-emit: refused: ...` on stderr for a
# refusal; the same for an error the original would raise (a missing file, a malformed form).
#
# The EH idiom of the lowered try (the IR of `try { B } catch (T) { H }`, see docs/notes/pathb-stage3.md):
#   if (_setjmp(buf) == 0) { B } else { H }
# becomes  .try { B } catch CxxThrow { H }, and _setjmp is 0 (the linker's runtime). throw is __throw_setup (the
# exception object's storage) followed by __throw, which raises CxxThrow (see cil-link.py's runtime). The
# destructors of the try block's objects are not run during unwinding yet (a documented gap).
# Refused with an error, never miscompiled: forms outside the subset below (bounds, index, switch, sret, copy,
# long double, fence, cf2i, variadic calls, variadic definitions). A statement the emitter does not know
# is refused too, never dropped.
#
# A line-by-line port of the Python original (tests/mruby/oracle/pathb-cil-emit.py); tests/mruby/pathb-cil-emit.sh
# compares the fragment, the stderr text and the exit status. Notes on the port:
#   - mruby has no Regexp: the atoms are classified by hand (atom_value), the `%N` temporaries and the digit runs by
#     character loops. Python's str.isdigit is also true for the superscripts 1, 2 and 3, which int() then refuses;
#     the port reproduces that.
#   - Strings are sequences of code points (the IR is latin-1, one code point per byte; an octal escape can reach 511),
#     held as UTF-8 Ruby strings: cps / from_cps convert. Python's len() of a name is its code point count.
#   - Python's json.dump(indent=1) is written by json_val (ensure_ascii escapes, the empty [] and {} forms). No JSON gem.
#   - Python's int() and float() are py_int and py_float_of: Integer and Float have exact conversions (float_to_int,
#     dec_to_double), because Float#to_i is not exact for large values; struct.pack('<f') refuses an overflow, so
#     pack_single does too.
#   - A Python list index past the end raises IndexError, and an unsubscriptable value raises TypeError; pyidx raises
#     for both (exit 1), where Ruby would give nil or a bit.
#   - A Python `str(x)` of a non-string is its repr (a list prints as [...], None as None): pys.
#   - Python's text mode reads the file with universal newlines (\r\n and \r become \n); stdin is read as it is.
#     read_input does the same.
#   - Not reproduced: a Tmp (the default repr of a Python object, with its address) inside a message, and the traceback
#     text of an uncaught exception. The status is the same (1), the text is not.

class Refused < StandardError; end   # refuse(): exit 1, the reason on stderr
class PyError < StandardError; end   # an exception the Python original does not catch (a traceback there, exit 1)

EH_GLOBALS = { '__curr_eh_stack_entry' => true, '__eh_curr_region' => true, '__catch_clause_number' => true,
               '__caught_object_address' => true }
SCALARS = {  # IR type -> [IL type, size, signed]
  'bool' => ['int32', 1, false], 'char' => ['int32', 1, true], 'signed_char' => ['int32', 1, true],
  'unsigned_char' => ['int32', 1, false], 'short' => ['int32', 2, true], 'unsigned_short' => ['int32', 2, false],
  'int' => ['int32', 4, true], 'unsigned_int' => ['int32', 4, false], 'long' => ['int64', 8, true],
  'unsigned_long' => ['int64', 8, false], 'long_long' => ['int64', 8, true],
  'unsigned_long_long' => ['int64', 8, false], 'float' => ['float32', 4, true], 'double' => ['float64', 8, true],
  'void' => ['void', 0, false]
}
LDIND = { ['int32', 1, true] => 'i1', ['int32', 1, false] => 'u1', ['int32', 2, true] => 'i2',
          ['int32', 2, false] => 'u2', ['int32', 4, true] => 'i4', ['int32', 4, false] => 'u4',
          ['int64', 8, true] => 'i8', ['int64', 8, false] => 'i8', ['float32', 4, true] => 'r4',
          ['float64', 8, true] => 'r8' }
STIND = { 'int32' => { 1 => 'i1', 2 => 'i2', 4 => 'i4' }, 'int64' => { 8 => 'i8' }, 'float32' => { 4 => 'r4' },
          'float64' => { 8 => 'r8' } }
CMP = %w[eq ne lt.s lt.u gt.s gt.u le.s le.u ge.s ge.u]
BIN = { 'wadd' => 'add', 'wsub' => 'sub', 'wmul' => 'mul', 'and' => 'and', 'or' => 'or', 'xor' => 'xor' }
FUNCTION_HEADER = %w[ret params static weak constructor destructor]  # the function form's non-statements
INT_ITEM = { 1 => 'int8', 2 => 'int16', 4 => 'int32', 8 => 'int64' }
WIDTHS = { 'int8' => 1, 'int16' => 2, 'int32' => 4, 'int64' => 8, 'float32' => 4, 'float64' => 8 }
# Python's float('nan') is the quiet NaN with the sign bit clear (0x7ff8000000000000).
POS_NAN = [0, 0, 0, 0, 0, 0, 0xf8, 0x7f].pack('C*').unpack('E')[0]

def refuse(msg)
  raise Refused, msg
end

# ------------------------------------------------------------------ strings as code points

def cps(s)
  s.unpack('U*')
end

def from_cps(a)
  a.pack('U*')
end

def ch(c)
  [c].pack('U')
end

def alnum_(c)
  (c >= 48 && c <= 57) || (c >= 65 && c <= 90) || (c >= 97 && c <= 122) || c == 95
end

# Python's str.isdigit() for a latin-1 code: the ASCII digits and the superscripts one, two and three.
def isdigit_py(c)
  (c >= 48 && c <= 57) || c == 0xb2 || c == 0xb3 || c == 0xb9
end

def ws?(c)
  c == 32 || c == 9 || c == 13 || c == 10
end

def ascii_digit?(c)
  c >= 48 && c <= 57
end

# ------------------------------------------------------------------ Python semantics

# x[i] for a Python list or str (the index may be negative); IndexError or TypeError (an uncaught exception) otherwise.
def pyidx(x, i)
  if x.is_a?(Array)
    n = x.size
    j = i < 0 ? i + n : i
    raise PyError, 'IndexError: list index out of range' if j < 0 || j >= n
    x[j]
  elsif x.is_a?(String)
    cs = cps(x)
    j = i < 0 ? i + cs.size : i
    raise PyError, 'IndexError: string index out of range' if j < 0 || j >= cs.size
    from_cps([cs[j]])
  else
    raise PyError, 'TypeError: object is not subscriptable'
  end
end

# x[k:] for a list (empty when k is past the end).
def pytail(x, k)
  raise PyError, 'TypeError: object is not a list' unless x.is_a?(Array)
  x.size > k ? x[k..-1] : []
end

# len(x)
def pylen(x)
  return x.size if x.is_a?(Array)
  return cps(x).size if x.is_a?(String)
  raise PyError, 'TypeError: object has no len()'
end

# bool(x)
def truthy(x)
  case x
  when nil, false then false
  when Integer then x != 0
  when Float then x != 0.0
  when String, Array then !x.empty?
  else true
  end
end

# repr() of a str: single quotes unless the text has ' and no ".
def py_str_repr(s)
  cs = cps(s)
  q = (cs.include?(39) && !cs.include?(34)) ? 34 : 39
  out = ch(q)
  cs.each do |c|
    if c == q || c == 92
      out << "\\" << ch(c)
    elsif c == 10
      out << '\\n'
    elsif c == 13
      out << '\\r'
    elsif c == 9
      out << '\\t'
    elsif c < 32 || (c >= 127 && c <= 160) || c == 173
      out << format('\\x%02x', c)
    else
      out << ch(c)
    end
  end
  out << ch(q)
  out
end

# repr() of an IR value: a string, a number, None, a list, a Ref (its own repr: kind"name").
def py_repr(x)
  if x.nil? then 'None'
  elsif x == true then 'True'
  elsif x == false then 'False'
  elsif x.is_a?(String) then py_str_repr(x)
  elsif x.is_a?(Integer) then x.to_s
  elsif x.is_a?(Float) then py_float_repr(x)
  elsif x.is_a?(Array) then '[' + x.map { |y| py_repr(y) }.join(', ') + ']'
  elsif x.is_a?(Ref) then x.kind + '"' + x.name + '"'
  else '<__main__.Tmp object>'  # the default repr of a Python object includes its address (not reproduced)
  end
end

# str(x), as an f-string formats it.
def pys(x)
  x.is_a?(String) ? x : py_repr(x)
end

# ------------------------------------------------------------------ floats (exact)

def float_bits(v)
  bits = 0
  [v].pack('E').unpack('C*').reverse.each { |b| bits = bits * 256 + b }
  bits
end

# [digits, k] with v = d.ddd * 10**k, for a finite v > 0 (the shortest digits that read back as v).
def shortest_digits(v)
  bits = float_bits(v)
  ex = (bits >> 52) & 0x7ff
  frac = bits & ((1 << 52) - 1)
  if ex == 0
    m = frac
    e2 = -1074
  else
    m = frac | (1 << 52)
    e2 = ex - 1075
  end
  n = m
  d = 1
  if e2 >= 0
    n = m << e2
  else
    d = 1 << (-e2)
  end
  k = ((m.to_s(2).length + e2 - 1) * 0.30102999566398).floor
  while (k >= 0 ? n >= d * (10**(k + 1)) : n * (10**(-(k + 1))) >= d)
    k += 1
  end
  while (k >= 0 ? n < d * (10**k) : n * (10**(-k)) < d)
    k -= 1
  end
  p = 1
  while p <= 17
    s = p - 1 - k
    num = n
    den = d
    if s >= 0
      num = n * (10**s)
    else
      den = d * (10**(-s))
    end
    q, r = num.divmod(den)
    q += 1 if 2 * r > den || (2 * r == den && q.odd?)
    cands = [q]
    if !(dec_to_double(q, k - (p - 1)) == v)
      cands = [q + 1, q - 1].sort_by { |c| (c * den - num).abs }
    end
    cands.each do |c|
      next if c <= 0
      if dec_to_double(c, k - (p - 1)) == v
        digs = c.to_s
        exp10 = k + (digs.length - p)
        digs = digs[0, digs.length - 1] while digs.length > 1 && digs.getbyte(digs.length - 1) == 48
        return [digs, exp10]
      end
    end
    p += 1
  end
  raise PyError, 'float repr: no 17-digit decimal reads back'
end

# repr(float)
def py_float_repr(v)
  return 'nan' if v.nan?
  return (v > 0 ? 'inf' : '-inf') unless v.finite?
  neg = v < 0 || (v == 0 && 1.0 / v < 0)
  v = -v if neg
  return (neg ? '-0.0' : '0.0') if v == 0
  digs, k = shortest_digits(v)
  if k + 1 <= -4 || k + 1 > 16
    body = digs[0, 1] + (digs.length > 1 ? '.' + digs[1, digs.length - 1] : '')
    e = k.abs
    body += 'e' + (k < 0 ? '-' : '+') + (e < 10 ? '0' : '') + e.to_s
  elsif k >= 0
    if digs.length <= k + 1
      body = digs + '0' * (k + 1 - digs.length) + '.0'
    else
      body = digs[0, k + 1] + '.' + digs[k + 1, digs.length - k - 1]
    end
  else
    body = '0.' + '0' * (-k - 1) + digs
  end
  neg ? '-' + body : body
end

# The double nearest to m * 10**e (m >= 0 an Integer), rounded half to even as Python's float() rounds it.
def dec_to_double(m, e)
  return 0.0 if m == 0
  digs = m.to_s.length
  return Float::INFINITY if e + digs > 310
  return 0.0 if e + digs < -330
  n = m
  d = 1
  if e >= 0
    n = m * (10**e)
  else
    d = 10**(-e)
  end
  e2 = n.to_s(2).length - d.to_s(2).length
  ge = e2 >= 0 ? n >= (d << e2) : (n << (-e2)) >= d
  e2 -= 1 unless ge
  e2 = -1022 if e2 < -1022
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

# float(s) of a str: Python's grammar ([sign] digits[.digits][e[sign]digits] | inf | infinity | nan).
def py_float(s)
  t = s.strip
  low = t.downcase
  neg = false
  body = low
  if body.start_with?('-')
    neg = true
    body = body[1, body.length - 1]
  elsif body.start_with?('+')
    body = body[1, body.length - 1]
  end
  if body == 'inf' || body == 'infinity'
    return neg ? -Float::INFINITY : Float::INFINITY
  end
  return (neg ? -POS_NAN : POS_NAN) if body == 'nan'
  i = 0
  n = body.length
  digits = ''
  while i < n && body[i] >= '0' && body[i] <= '9'
    digits << body[i]
    i += 1
  end
  fraclen = 0
  if i < n && body[i] == '.'
    i += 1
    while i < n && body[i] >= '0' && body[i] <= '9'
      digits << body[i]
      fraclen += 1
      i += 1
    end
  end
  ok = digits.length > 0
  ex = 0
  if ok && i < n && body[i] == 'e'
    i += 1
    eneg = false
    if i < n && (body[i] == '+' || body[i] == '-')
      eneg = body[i] == '-'
      i += 1
    end
    edigits = ''
    while i < n && body[i] >= '0' && body[i] <= '9'
      edigits << body[i]
      i += 1
    end
    ok = edigits.length > 0
    ex = edigits.to_i
    ex = -ex if eneg
  end
  raise PyError, "ValueError: could not convert string to float: #{py_str_repr(s)}" unless ok && i == n
  v = dec_to_double(digits.to_i, ex - fraclen)
  neg ? v * -1.0 : v
end

# float(v) for an IR value: an int is rounded exactly (and an int too large for a double is an OverflowError), a
# str is parsed, a float is itself.
def py_float_of(v)
  if v.is_a?(Float)
    v
  elsif v.is_a?(Integer)
    f = dec_to_double(v.abs, 0)
    raise PyError, 'OverflowError: int too large to convert to float' unless f.finite?
    v < 0 ? -f : f
  elsif v.is_a?(String)
    py_float(v)
  else
    raise PyError, 'TypeError: float() argument must be a string or a number'
  end
end

# int(v) of a float: truncation toward zero, exact.
def float_to_int(v)
  raise PyError, 'ValueError: cannot convert float NaN to integer' if v.nan?
  raise PyError, 'OverflowError: cannot convert float infinity to integer' unless v.finite?
  a = v.abs
  bits = float_bits(a)
  ex = (bits >> 52) & 0x7ff
  frac = bits & ((1 << 52) - 1)
  if ex == 0
    m = frac
    e2 = -1074
  else
    m = frac | (1 << 52)
    e2 = ex - 1075
  end
  r = e2 >= 0 ? (m << e2) : (m >> (-e2))
  v < 0 ? -r : r
end

# int(v): an int is itself, a float truncates, a str is a decimal integer literal (optional sign, underscores between
# digits, surrounding whitespace); anything else is a TypeError.
def py_int(v)
  if v.is_a?(Integer)
    v
  elsif v.is_a?(Float)
    float_to_int(v)
  elsif v.is_a?(String)
    cs = cps(v)
    a = 0
    b = cs.size
    a += 1 while a < b && (ws?(cs[a]) || cs[a] == 11 || cs[a] == 12)
    b -= 1 while b > a && (ws?(cs[b - 1]) || cs[b - 1] == 11 || cs[b - 1] == 12)
    s = cs[a...b]
    neg = false
    if !s.empty? && (s[0] == 45 || s[0] == 43)
      neg = s[0] == 45
      s = s[1..-1]
    end
    # digits with single underscores between them: \d+(_\d+)*
    ok = !s.empty?
    val = 0
    after_us = true  # a leading underscore is not allowed
    s.each do |c|
      if c == 95
        ok = false if after_us
        after_us = true
      elsif ascii_digit?(c)
        val = val * 10 + (c - 48)
        after_us = false
      else
        ok = false
      end
    end
    ok = false if after_us
    raise PyError, "ValueError: invalid literal for int() with base 10: #{py_str_repr(v)}" unless ok
    neg ? -val : val
  else
    raise PyError, 'TypeError: int() argument must be a string or a number'
  end
end

# The bytes of a double (struct.pack('<d')) and of a single (struct.pack('<f'); an overflow is an OverflowError).
def pack_double(v)
  [v].pack('E').unpack('C*')
end

def pack_single(v)
  r = [v].pack('e')
  raise PyError, 'OverflowError: float too large to pack with f format' if v.finite? && !r.unpack('e')[0].finite?
  r.unpack('C*')
end

def le_int(bytes)
  v = 0
  bytes.reverse_each { |b| v = v * 256 + b }
  v
end

def hex_bytes(bytes)
  bytes.map { |b| format('%02x', b) }.join(' ')
end

# ------------------------------------------------------------------ JSON (json.dump(indent=1), ensure_ascii)

def json_str(s)
  out = '"'
  cps(s).each do |c|
    piece = if c == 34 then '\\"'
            elsif c == 92 then '\\\\'
            elsif c == 10 then '\\n'
            elsif c == 13 then '\\r'
            elsif c == 9 then '\\t'
            elsif c == 8 then '\\b'
            elsif c == 12 then '\\f'
            elsif c >= 0x20 && c <= 0x7e then ch(c)
            elsif c < 0x10000 then format('\\u%04x', c)
            else raise PyError, 'TypeError: code point outside the BMP is not reproduced'
            end
    out << piece
  end
  out << '"'
  out
end

def json_val(v, lvl)
  if v.nil? then 'null'
  elsif v == true then 'true'
  elsif v == false then 'false'
  elsif v.is_a?(Integer) then v.to_s
  elsif v.is_a?(String) then json_str(v)
  elsif v.is_a?(Array)
    return '[]' if v.empty?
    pad = ' ' * (lvl + 1)
    "[\n" + v.map { |x| pad + json_val(x, lvl + 1) }.join(",\n") + "\n" + (' ' * lvl) + ']'
  elsif v.is_a?(Hash)
    return '{}' if v.empty?
    pad = ' ' * (lvl + 1)
    "{\n" + v.map { |k, x| pad + json_str(k) + ': ' + json_val(x, lvl + 1) }.join(",\n") + "\n" + (' ' * lvl) + '}'
  else
    raise PyError, 'TypeError: object is not JSON serializable'
  end
end

# ------------------------------------------------------------------ reading the IR

class Ref
  attr_reader :kind, :name

  def initialize(kind, name)
    @kind = kind
    @name = name
  end
end

class Tmp
  attr_reader :n

  def initialize(n)
    @n = n
  end
end

# A double-quoted IR string at cs[i]: [its code points, the index after it]. The escapes are those of read_string in
# pathb-qbe-emit.rb: \n, \\, \" and a three-digit octal (which can reach 511).
def read_quoted(cs, i)
  out = []
  i += 1
  n = cs.size
  while true
    refuse('unterminated string in IR') if i >= n
    c = cs[i]
    return [from_cps(out), i + 1] if c == 34
    if c != 92
      out << c
      i += 1
      next
    end
    e = i + 1 < n ? cs[i + 1] : nil
    if e == 110
      out << 10
      i += 2
    elsif e == 34 || e == 92
      out << e
      i += 2
    elsif e && octal?(e) && i + 3 < n && octal?(cs[i + 2]) && octal?(cs[i + 3])
      out << (e - 48) * 64 + (cs[i + 2] - 48) * 8 + (cs[i + 3] - 48)
      i += 4
    else
      refuse("unknown escape \\#{e ? ch(e) : ''} in IR string")
    end
  end
end

def octal?(c)
  c >= 48 && c <= 55
end

# An integer or float atom, or the atom itself (a symbol). The patterns of the original, matched by hand:
#   -?\d+   ->  int;   -?0x[0-9a-fA-F]+   ->  int(atom, 16);   -?\d+\.\d*(e-?\d+)?   ->  float(atom)
def atom_value(a)
  n = a.size
  k = (n > 0 && a[0] == 45) ? 1 : 0
  if k < n && (k...n).all? { |j| ascii_digit?(a[j]) }
    v = 0
    (k...n).each { |j| v = v * 10 + (a[j] - 48) }
    return k == 1 ? -v : v
  end
  if n >= k + 3 && a[k] == 48 && a[k + 1] == 120 && (k + 2...n).all? { |j| hex_digit?(a[j]) }
    v = 0
    (k + 2...n).each { |j| v = v * 16 + hex_value(a[j]) }
    return k == 1 ? -v : v
  end
  j = k
  j += 1 while j < n && ascii_digit?(a[j])
  if j > k && j < n && a[j] == 46
    j += 1
    j += 1 while j < n && ascii_digit?(a[j])
    if j < n && a[j] == 101
      j += 1
      j += 1 if j < n && a[j] == 45
      d0 = j
      j += 1 while j < n && ascii_digit?(a[j])
      j = -1 if j == d0
    end
    return py_float(from_cps(a)) if j == n
  end
  from_cps(a)
end

def hex_digit?(c)
  ascii_digit?(c) || (c >= 97 && c <= 102) || (c >= 65 && c <= 70)
end

def hex_value(c)
  return c - 48 if ascii_digit?(c)
  return c - 87 if c >= 97 && c <= 102
  c - 55
end

def tokenize(cs)
  toks = []
  i = 0
  n = cs.size
  while i < n
    c = cs[i]
    if ws?(c)
      i += 1
    elsif c == 40 || c == 41
      toks << ch(c)
      i += 1
    elsif c == 34
      s, i = read_quoted(cs, i)
      toks << s
    elsif (c == 36 || c == 64 || c == 38) && i + 1 < n && cs[i + 1] == 34
      s, i = read_quoted(cs, i + 1)
      kind = { 36 => 'slot', 64 => 'glob', 38 => 'fn' }[c]
      toks << Ref.new(kind, s)
    elsif c == 37 && i + 1 < n && isdigit_py(cs[i + 1])
      j = i + 1
      j += 1 while j < n && isdigit_py(cs[j])
      run = cs[i + 1...j]
      raise PyError, 'ValueError: invalid literal for int()' unless run.all? { |x| ascii_digit?(x) }
      toks << Tmp.new(py_int(from_cps(run)))
      i = j
    else
      j = i
      j += 1 while j < n && !ws?(cs[j]) && cs[j] != 40 && cs[j] != 41
      toks << atom_value(cs[i...j])
      i = j
    end
  end
  toks
end

# The forms of the token list (a Python list of lists, with the parentheses as the tokens "(" and ")" compare).
class Parser
  def initialize(toks)
    @toks = toks
    @pos = 0
  end

  def cur
    raise PyError, 'IndexError: list index out of range' if @pos >= @toks.size
    @toks[@pos]
  end

  def read
    t = cur
    @pos += 1
    if t == '('
      out = []
      out << read while cur != ')'
      @pos += 1
      return out
    end
    refuse('unbalanced )') if t == ')'
    t
  end

  def forms
    out = []
    out << read while @pos < @toks.size
    out
  end
end

# ------------------------------------------------------------------ the emitter

class Emitter
  attr_reader :fragment_calls, :addrs
  attr_accessor :global_forms, :data_forms

  def initialize
    @addrs = {}          # name -> true (the set of the linker's addr_ fields the code reads)
    @fragment_calls = {} # name -> signature
    @global_forms = {}
    @data_forms = {}
  end

  def gname(n)
    n
  end

  def fn_name(n)
    n
  end

  # The bytes of the constant `ref`: a string literal (a data form) or a global with an initializer.
  def global_image(ref, who)
    unless ref.is_a?(Ref) && ref.kind == 'glob'
      refuse("#{pys(who)}: bytes from #{py_repr(ref)}, which is not a global of this unit")
    end
    return string_bytes(@data_forms[ref.name], self) if @data_forms.key?(ref.name)
    unless @global_forms.key?(ref.name)
      refuse("#{pys(who)}: bytes from #{pys(ref.name)}, which is not defined in this unit")
    end
    d = global_data(@global_forms[ref.name], self)
    refuse("#{pys(who)}: bytes from #{pys(ref.name)}, which has no initializer in this unit") if d.nil?
    img = []
    d['items'].each do |it|
      if it[0] == 'zero'
        img.concat([0] * it[1])
      elsif WIDTHS.key?(it[0])
        w = WIDTHS[it[0]]
        v = it[1] % (1 << (8 * w))
        w.times do
          img << (v % 256)
          v >>= 8
        end
      else
        refuse("#{pys(who)}: bytes from #{pys(ref.name)}, whose initializer has a #{pys(it[0])} item")
      end
    end
    img
  end

  # IR type -> [IL type, size, signed]; ptr and const are int64 addresses; aggregates are refused as values.
  def type_of(t)
    if t.is_a?(String)
      return SCALARS[t] if SCALARS.key?(t)
      refuse('long double is not supported by the CIL spike') if t == 'long_double'
      refuse("unsupported IR type #{t}")
    end
    if truthy(t) && pyidx(t, 0) == 'ptr'
      return ['int64', 8, false]
    end
    if truthy(t) && pyidx(t, 0) == 'const'
      return type_of(pyidx(t, 1))
    end
    if truthy(t) && pyidx(t, 0) == 'fn'
      return ['int64', 8, false]
    end
    refuse("aggregate or unsupported type #{py_repr(t)} used as a value")
  end
end

class Function
  attr_reader :ret, :params

  def initialize(em, form)
    @em = em
    @name = pyidx(form, 1)
    @out = []
    @locals = {}          # 'pN' (a parameter) or '%N' (a let) -> [kind, index, IL type]
    @local_types = []
    @defs = {}            # tmp number -> defining let expression (for the EH idiom)
    @loop_stack = []      # [break label, continue label, try depth]
    @try_depth = 0
    @labels = 0
    @ret = 'void'
    @params = []          # [number, name, IL type]
    @param_ty = {}        # parameter number -> IR type
    @tmp_ty = {}          # temporary number -> IR type of its let
    @slots = {}
    @frame = 0
    @ret_local = nil
    @ret_label = nil
    parse_header(form)
  end

  def parse_header(form)
    pytail(form, 2).each do |part|
      next unless part.is_a?(Array) && truthy(part)
      if pyidx(part, 0) == 'ret'
        @ret = @em.type_of(pyidx(part, 1))[0]
      elsif pyidx(part, 0) == 'params'
        pytail(part, 1).each do |p|
          if p.is_a?(Array) && truthy(p) && pyidx(p, 0) == 'ellipsis'
            # C-style variadic definitions read their arguments with va_start (a va_list): out of scope
            refuse("#{pys(@name)}: variadic definitions (va_start) are not supported by the spike")
          end
          # (param %N "name" TYPE) or, unnamed, (param %N TYPE)
          unless p.is_a?(Array) && pylen(p) >= 3 && pyidx(p, 1).is_a?(Tmp)
            refuse("#{pys(@name)}: parameter form #{py_repr(p)} is not supported by the spike")
          end
          pty = pyidx(p, -1)
          @param_ty[pyidx(p, 1).n] = pty
          pname = pylen(p) == 4 ? pyidx(p, 2) : nil
          @params << [pyidx(p, 1).n, pname, @em.type_of(pty)[0]]
        end
      end
    end
    unless ['void', 'int32', 'int64', 'float32', 'float64'].include?(@ret)
      refuse("#{pys(@name)}: unsupported return type #{pys(@ret)}")
    end
    @params.each { |pidx, _pname, pil| @locals["p#{pidx}"] = ['arg', pidx, pil] }
  end

  def new_label(prefix)
    @labels += 1
    "#{prefix}#{@labels}"
  end

  def new_local(il)
    @local_types << il
    @local_types.size - 1
  end

  def emit(*lines)
    @out.concat(lines)
  end

  # expressions -----------------------------------------------------------

  def coerce(have, want)
    return if have == want || want.nil? || want == 'void'
    table = { ['int32', 'int64'] => 'conv.i8', ['int64', 'int32'] => 'conv.i4', ['int32', 'float64'] => 'conv.r8',
              ['int32', 'float32'] => 'conv.r4', ['int64', 'float64'] => 'conv.r8', ['float64', 'int32'] => 'conv.i4',
              ['float32', 'int32'] => 'conv.i4', ['float64', 'float32'] => 'conv.r4', ['float32', 'float64'] => 'conv.r8',
              ['float64', 'int64'] => 'conv.i8', ['float32', 'int64'] => 'conv.i8' }
    refuse("#{pys(@name)}: no conversion #{pys(have)} -> #{pys(want)}") unless table.key?([have, want])
    emit(table[[have, want]])
  end

  # Emit expression e; returns its IL type (the value is on the stack; void calls leave nothing).
  def expr(e)
    if e.is_a?(Tmp)
      key = @locals.key?("p#{e.n}") ? "p#{e.n}" : "%#{e.n}"
      refuse("#{pys(@name)}: undefined temporary %#{e.n}") unless @locals.key?(key)
      kind, idx, il = @locals[key]
      emit(kind == 'arg' ? "ldarg #{idx}" : "ldloc #{idx}")
      return il
    end
    if e.is_a?(Ref)
      if e.kind == 'slot'
        refuse("#{pys(@name)}: unknown slot #{e.name}") unless @slots.key?(e.name)
        emit("ldloc #{@frame_local}", "ldc.i8 #{@slots[e.name]}", 'add')
        return 'int64'
      end
      if e.kind == 'glob'
        @em.addrs[@em.gname(e.name)] = true
        emit("ldsfld int64 Prog::'addr_#{@em.gname(e.name)}'")
        return 'int64'
      end
      if e.kind == 'fn'
        # A function's address is its linker field, as a global's is: cil-link.py stores ldftn of a function
        # the unit defines at Init, and dlsym of any other name (null when it is not in the process).
        @em.addrs[@em.fn_name(e.name)] = true
        emit("ldsfld int64 Prog::'addr_#{@em.fn_name(e.name)}'")
        return 'int64'
      end
    end
    refuse("#{pys(@name)}: bad expression #{py_repr(e)}") unless e.is_a?(Array) && truthy(e)
    head = pyidx(e, 0)
    if head == 'const'
      il, _size, _signed = @em.type_of(pyidx(e, 1))
      v = pyidx(e, 2)
      if il == 'float64'
        emit("ldc.r8 (#{hex_bytes(pack_double(py_float_of(v)))})")
      elsif il == 'float32'
        emit("ldc.r4 (#{hex_bytes(pack_single(py_float_of(v)))})")
      elsif il == 'int64'
        emit("ldc.i8 #{py_int(v)}")
      else
        emit("ldc.i4 #{py_int(v)}")
      end
      return il
    end
    if head == 'null'
      emit('ldc.i8 0')
      return 'int64'
    end
    if head == 'load' || head == 'load.v'
      il, size, signed = @em.type_of(pyidx(e, 1))
      expr(pyidx(e, 2))
      emit('conv.u')
      key = [il, size, signed]
      refuse("#{pys(@name)}: load of #{pys(pyidx(e, 1))}") unless LDIND.key?(key)
      emit('volatile.') if head == 'load.v'  # the CIL volatile. prefix: the JIT does not merge or drop this access
      emit("ldind.#{LDIND[key]}")
      return il == 'int32' ? 'int32' : il
    end
    return divrem(e, head) if head == 'cdiv' || head == 'crem'
    return shift(e, head == 'cshl') if head == 'cshl' || head == 'cshr'
    if head == 'pdiff'
      # (A - B) / SIZE in the pointer difference type (int64). A register SIZE (a VLA element) is zero-extended.
      a = expr(pyidx(e, 1))
      coerce(a, 'int64')
      b = expr(pyidx(e, 2))
      coerce(b, 'int64')
      emit('sub')
      size = pyidx(e, 3)
      if size.is_a?(Integer)
        refuse("#{pys(@name)}: pdiff with element size 0") if size == 0
        emit("ldc.i8 #{size}", 'div')
        return 'int64'
      end
      # A register SIZE: a zero one (a zero-length VLA element) aborts, as the checks of divrem do (the difference
      # and the size go to locals first, so the check is one compare and a branch).
      td = new_local('int64')
      emit("stloc #{td}")
      have = expr(size)
      if have == 'int32'
        emit('conv.u8')
      elsif have != 'int64'
        refuse("#{pys(@name)}: pdiff size of type #{pys(have)}")
      end
      ts = new_local('int64')
      emit("stloc #{ts}")
      ok = new_label('IL_ok')
      emit("ldloc #{ts}", 'ldc.i8 0', "bne.un #{ok}")
      check_fail_if(ok)
      emit("ldloc #{td}", "ldloc #{ts}", 'div')
      return 'int64'
    end
    if head == 'fneg'
      il = @em.type_of(pyidx(e, 1))[0]
      refuse("#{pys(@name)}: fneg of non-float type #{py_repr(pyidx(e, 1))}") unless ['float32', 'float64'].include?(il)
      have = expr(pyidx(e, 2))
      coerce(have, il)
      emit('neg')
      return il
    end
    if head == 'offset'
      expr(pyidx(e, 1))
      emit("ldc.i8 #{py_int(pyidx(e, 2))}", 'add')
      return 'int64'
    end
    if head == 'bitcast' || head == 'iconv'
      il = @em.type_of(pyidx(e, 1))[0]
      have = expr(pyidx(e, 2))
      coerce(have, il)
      return il
    end
    if CMP.include?(head)
      il = @em.type_of(pyidx(e, 1))[0]
      a = expr(pyidx(e, 2))
      coerce(a, il)
      b = expr(pyidx(e, 3))
      coerce(b, il)
      # le = not gt, ge = not lt; ne = not eq
      ops = { 'eq' => ['ceq'], 'ne' => ['ceq', 'ldc.i4.0', 'ceq'], 'lt.s' => ['clt'], 'lt.u' => ['clt.un'],
              'gt.s' => ['cgt'], 'gt.u' => ['cgt.un'], 'le.s' => ['cgt', 'ldc.i4.0', 'ceq'],
              'le.u' => ['cgt.un', 'ldc.i4.0', 'ceq'], 'ge.s' => ['clt', 'ldc.i4.0', 'ceq'],
              'ge.u' => ['clt.un', 'ldc.i4.0', 'ceq'] }
      emit(*ops[head])
      return 'int32'
    end
    if BIN.key?(head)
      il = @em.type_of(pyidx(e, 1))[0]
      a = expr(pyidx(e, 2))
      coerce(a, il)
      b = expr(pyidx(e, 3))
      coerce(b, il)
      emit(BIN[head])
      narrow_small(pyidx(e, 1))
      return il
    end
    if head == 'wneg'
      il = @em.type_of(pyidx(e, 1))[0]
      have = expr(pyidx(e, 2))
      coerce(have, il)
      emit('neg')
      narrow_small(pyidx(e, 1))
      return il
    end
    return call(e) if head == 'call'
    if head == 'index'
      # (index BASE IDX SIZE) = BASE + ext(IDX) * SIZE, wrapping. The extension follows IDX's IR type as in
      # pathb-qbe-emit.rb: zero for an unsigned 32-bit index, sign otherwise (a 64-bit index is used as it is).
      have = expr(pyidx(e, 1))
      coerce(have, 'int64')
      have = expr(pyidx(e, 2))
      if have == 'int32'
        emit(is_unsigned(ir_type(pyidx(e, 2))) ? 'conv.u8' : 'conv.i8')
      elsif have != 'int64'
        refuse("#{pys(@name)}: index with a #{pys(have)} index")
      end
      size_operand(pyidx(e, 3))
      emit('mul', 'add')
      return 'int64'
    end
    refuse("#{pys(@name)}: unsupported expression #{pys(head)}")
  end

  # Narrow the int32 value on the stack to the IR type ty when ty is a 1- or 2-byte integer, as the QBE emitter's
  # narrow does (its r_wbin, r_wneg, r_bitop, r_shift). bool is left alone, as QBE leaves it.
  def narrow_small(ty)
    while ty.is_a?(Array) && truthy(ty) && pyidx(ty, 0) == 'const'
      ty = pyidx(ty, 1)
    end
    return unless ty.is_a?(String) && ty != 'bool' && SCALARS.key?(ty)
    il, size, signed = @em.type_of(ty)
    return unless il == 'int32' && (size == 1 || size == 2)
    emit({ [1, true] => 'conv.i1', [1, false] => 'conv.u1', [2, true] => 'conv.i2', [2, false] => 'conv.u2' }[[size, signed]])
  end

  # Push an index SIZE as int64: a number, or a register (a VLA element size, zero-extended as in QBE).
  def size_operand(s)
    if s.is_a?(Integer)
      emit("ldc.i8 #{s}")
      return
    end
    have = expr(s)
    if have == 'int32'
      emit('conv.u8')
    elsif have != 'int64'
      refuse("#{pys(@name)}: size of a #{pys(have)} type")
    end
  end

  # The IR type of operand e when the IR states it (a parameter, a let, a constant, a load or a conversion).
  def ir_type(e)
    if e.is_a?(Tmp)
      return @param_ty[e.n] if @locals.key?("p#{e.n}")
      return @tmp_ty[e.n]
    end
    if e.is_a?(Array) && truthy(e) && ['const', 'load', 'iconv', 'bitcast', 'call', 'wadd', 'wsub', 'wmul', 'and',
                                       'or', 'xor', 'wneg'].include?(pyidx(e, 0)) && pylen(e) > 1
      return pyidx(e, 1)
    end
    nil
  end

  def is_unsigned(ty)
    if ty.is_a?(String)
      return SCALARS.key?(ty) && ty != 'void' && !SCALARS[ty][2]
    end
    if ty.is_a?(Array) && truthy(ty) && pyidx(ty, 0) == 'const'
      return is_unsigned(pyidx(ty, 1))
    end
    false
  end

  def note_call(gname, sig, who)
    known = @em.fragment_calls[gname]
    refuse("#{pys(who)}: #{pys(gname)} called with two signatures") if known && known != sig
    @em.fragment_calls[gname] = sig
  end

  # The abort path of the QBE emitter (its `call $abort()`): the linker binds abort to libc. The throw after it
  # is never reached; it only keeps the IL from falling through if abort ever returned.
  def abort
    sig = { 'ret' => 'void', 'params' => [], 'variadic' => false }
    known = @em.fragment_calls['abort']
    refuse("#{pys(@name)}: abort is called with two signatures") if known && known != sig
    @em.fragment_calls['abort'] = sig
    emit("call void Prog::'abort'()", 'ldnull', 'throw')
  end

  # The failing case of a check: the abort path, then the label `ok` that the passing case branches to.
  def check_fail_if(ok)
    abort
    emit("#{ok}:")
  end

  # (cdiv|crem T A B) as the QBE emitter's r_divrem: abort on a zero divisor, and on INT_MIN / -1 for signed
  # types (crem too). The operands go to locals first, so every check is one compare and a branch.
  def divrem(e, op)
    ty = pyidx(e, 1)
    il, size, signed = @em.type_of(ty)
    refuse("#{pys(@name)}: #{op} of non-integer type #{py_repr(ty)}") unless ['int32', 'int64'].include?(il)
    suffix = il == 'int64' ? 'i8' : 'i4'
    a = expr(pyidx(e, 2))
    coerce(a, il)
    ta = new_local(il)
    emit("stloc #{ta}")
    b = expr(pyidx(e, 3))
    coerce(b, il)
    tb = new_local(il)
    emit("stloc #{tb}")
    ok = new_label('IL_ok')
    emit("ldloc #{tb}", "ldc.#{suffix} 0", "bne.un #{ok}")
    check_fail_if(ok)
    if signed
      lo = -(1 << (8 * size - 1))  # the range of the type (its size is the IR type's size)
      ok2 = new_label('IL_ok')
      emit("ldloc #{ta}", "ldc.#{suffix} #{lo}", "bne.un #{ok2}",
           "ldloc #{tb}", "ldc.#{suffix} -1", "bne.un #{ok2}")
      check_fail_if(ok2)
    end
    il_op = op == 'cdiv' ? 'div' : 'rem'
    emit("ldloc #{ta}", "ldloc #{tb}", signed ? il_op : il_op + '.un')
    il
  end

  # (cshl|cshr T A COUNT) as the QBE emitter's r_shift: abort unless 0 <= COUNT < the bit width of T (an
  # unsigned compare of the whole count, before it is narrowed to int32). cshl narrows a small type, as QBE does;
  # cshr is arithmetic for signed and logical for unsigned types.
  def shift(e, left)
    ty = pyidx(e, 1)
    il, size, signed = @em.type_of(ty)
    refuse("#{pys(@name)}: shift of non-integer type #{py_repr(ty)}") unless ['int32', 'int64'].include?(il)
    a = expr(pyidx(e, 2))
    coerce(a, il)
    ta = new_local(il)
    emit("stloc #{ta}")
    cil = expr(pyidx(e, 3))
    refuse("#{pys(@name)}: shift count of type #{pys(cil)}") unless ['int32', 'int64'].include?(cil)
    tc = new_local(cil)
    emit("stloc #{tc}")
    suffix = cil == 'int64' ? 'i8' : 'i4'
    ok = new_label('IL_ok')
    emit("ldloc #{tc}", "ldc.#{suffix} #{8 * size}", "blt.un #{ok}")
    check_fail_if(ok)
    emit("ldloc #{ta}", "ldloc #{tc}")
    emit('conv.i4') if cil == 'int64'
    if left
      emit('shl')
      narrow_small(ty)
    else
      emit(signed ? 'shr' : 'shr.un')
    end
    il
  end

  def call(e)
    callee = pyidx(e, 2)
    indirect = !(callee.is_a?(Ref) && callee.kind == 'fn')
    name = indirect ? 'indirect' : callee.name
    ret = @em.type_of(pyidx(e, 1))[0]
    args = pytail(e, 3)
    if args.any? { |a| a.is_a?(Array) && truthy(a) && pyidx(a, 0) == 'variadic' }
      refuse("#{pys(@name)}: variadic calls (#{pys(name)}) are not supported by the spike")
    end
    if name == '_setjmp'
      args.each do |a|
        expr(a)
        emit('pop')
      end
      emit('ldc.i4.0')
      return 'int32'
    end
    typed = []
    args.each do |a|
      refuse("#{pys(@name)}: sret results are not supported by the spike") if a.is_a?(Array) && truthy(a) && pyidx(a, 0) == 'sret'
      typed << expr(a)
    end
    if indirect
      # The callee is a function address (int64, as every pointer is): a calli on it. Its signature is the
      # call's, as the arguments carry it (the same as qbe2cil.rb's indirect calls).
      refuse("#{pys(@name)}: indirect call through a value that is not a pointer") unless expr(callee) == 'int64'
      emit('conv.i', "calli #{ret} (#{typed.join(', ')})")
      return ret
    end
    gname = @em.fn_name(name)
    sig = { 'ret' => ret, 'params' => typed, 'variadic' => false }
    note_call(gname, sig, @name)
    emit("call #{ret} Prog::'#{gname}'(#{typed.join(', ')})")
    ret
  end

  # statements -------------------------------------------------------------

  # True if the IR tree compares something against the constant k in an eq (a clause-number test).
  def has_clause_test(node, k)
    if node.is_a?(Array)
      if pylen(node) == 4 && pyidx(node, 0) == 'eq' && pyidx(node, 3).is_a?(Array) && pylen(pyidx(node, 3)) == 3 &&
         pyidx(pyidx(node, 3), 0) == 'const' && pyidx(pyidx(node, 3), 2) == k
        return true
      end
      return node.any? { |x| has_clause_test(x, k) }
    end
    false
  end

  def ir_label(name)
    raise PyError, 'TypeError: expected a string' unless name.is_a?(String)
    cs = cps(name)
    from_cps(cs.map { |c| alnum_(c) ? c : 95 }) + '_' + cs.size.to_s
  end

  def stmts(lst)
    lst.each { |x| stmt(x) }
  end

  def stmt(s)
    refuse("#{pys(@name)}: bad statement #{py_repr(s)}") unless s.is_a?(Array) && truthy(s)
    head = pyidx(s, 0)
    if head == 'block'
      pytail(s, 1).each { |x| stmt(x) }
      return
    end
    if head == 'let'
      tmp, ty, e = pyidx(s, 1), pyidx(s, 2), pyidx(s, 3)
      il = @em.type_of(ty)[0]
      refuse("#{pys(@name)}: void let") if il == 'void'
      @defs[tmp.n] = e
      @tmp_ty[tmp.n] = ty
      idx = new_local(il)
      @locals["%#{tmp.n}"] = ['local', idx, il]
      have = expr(e)
      coerce(have, il)
      emit("stloc #{idx}")
      return
    end
    if head == 'set'
      tmp, e = pyidx(s, 1), pyidx(s, 2)
      key = "%#{tmp.n}"
      refuse("#{pys(@name)}: set of undefined %#{tmp.n}") unless @locals.key?(key)
      _kind, idx, il = @locals[key]
      have = expr(e)
      coerce(have, il)
      emit("stloc #{idx}")
      return
    end
    if head == 'store'
      ty, addr, val = pyidx(s, 1), pyidx(s, 2), pyidx(s, 3)
      il, size, _signed = @em.type_of(ty)
      expr(addr)
      emit('conv.u')
      have = expr(val)
      coerce(have, il)
      refuse("#{pys(@name)}: store of #{pys(ty)}") unless STIND.key?(il) && STIND[il].key?(size)
      emit("stind.#{STIND[il][size]}")
      return
    end
    if head == 'eval'
      il = expr(pyidx(s, 1))
      emit('pop') if il != 'void'
      return
    end
    if head == 'return'
      if pylen(s) > 1
        have = expr(pyidx(s, 1))
        coerce(have, @ret)
        if @try_depth > 0
          emit("stloc #{pys(@ret_local)}", "leave #{@ret_label}")
        else
          emit('ret')
        end
      else
        emit(@try_depth > 0 ? "leave #{@ret_label}" : 'ret')
      end
      return
    end
    if head == 'unreachable'
      emit('ldnull', 'throw')
      return
    end
    if head == 'bounds'
      # (bounds IDX N): abort() unless IDX < N as an unsigned integer (a negative IDX fails, as in QBE). N is a
      # number, or a register (a VLA's element count, unsigned_long), which needs a 64-bit IDX.
      have = expr(pyidx(s, 1))
      refuse("#{pys(@name)}: bounds on a #{pys(have)} index") unless ['int32', 'int64'].include?(have)
      bound = pyidx(s, 2)
      if bound.is_a?(Integer)
        if have == 'int32'
          v = bound % (1 << 32)
          emit("ldc.i4 #{v >= (1 << 31) ? v - (1 << 32) : v}")
        else
          emit("ldc.i8 #{bound % (1 << 64)}")
        end
      else
        refuse("#{pys(@name)}: bounds with a register bound needs a 64-bit index") unless have == 'int64'
        coerce(expr(bound), 'int64')
      end
      ok = new_label('IL_bounds_ok')
      emit("blt.un #{ok}")
      check_fail_if(ok)
      return
    end
    if head == 'trap'  # the abort path, as the QBE emitter's checked failures (its trap is hlt: see the notes)
      refuse("#{pys(@name)}: trap form") unless pylen(s) == 1
      abort
      return
    end
    if head == 'barrier'  # a compiler barrier: no effect in this model (the C backend's memory model, no reordering)
      refuse("#{pys(@name)}: barrier form") unless pylen(s) == 1
      return
    end
    if head == 'nonnull'
      expr(pyidx(s, 1))
      emit('pop')
      return
    end
    return if_stmt(s) if head == 'if'
    return loop_stmt(s) if head == 'loop'
    if head == 'label'
      emit("L_#{ir_label(pyidx(s, 1))}:")
      return
    end
    if head == 'goto'
      target = "L_#{ir_label(pyidx(s, 1))}"
      emit(@try_depth > 0 ? "leave #{target}" : "br #{target}")
      return
    end
    if head == 'break' || head == 'continue'
      refuse("#{pys(@name)}: #{head} outside a loop") if @loop_stack.empty?
      brk, cont, depth = @loop_stack[-1]
      target = head == 'break' ? brk : cont
      emit(@try_depth > depth ? "leave #{target}" : "br #{target}")
      return
    end
    refuse("#{pys(@name)}: unsupported statement #{pys(head)}")
  end

  # True if cond is the lowered try's `_setjmp(...) == 0` (the defining let is an eq against 0 of a _setjmp call).
  def cond_defined_by_setjmp(cond)
    return false unless cond.is_a?(Tmp)
    d = @defs[cond.n]
    return false unless d.is_a?(Array) && truthy(d) && pyidx(d, 0) == 'eq'
    a = pyidx(d, 2)
    b = pyidx(d, 3)
    return false unless a.is_a?(Tmp) && b.is_a?(Array) && truthy(b) && pyidx(b, 0) == 'const' && pyidx(b, 2) == 0
    da = @defs[a.n]
    da.is_a?(Array) && truthy(da) && pyidx(da, 0) == 'call' && pyidx(da, 2).is_a?(Ref) && pyidx(da, 2).name == '_setjmp'
  end

  def if_stmt(s)
    cond = pyidx(s, 1)
    th = pyidx(s, 2)
    els = pylen(s) > 3 ? pyidx(s, 3) : nil
    # (then S...) and (else S...) hold statement lists; a bare statement is a one-element list
    then_body = th.is_a?(Array) && truthy(th) && pyidx(th, 0) == 'then' ? pytail(th, 1) : [th]
    else_body = nil
    unless els.nil?
      else_body = els.is_a?(Array) && truthy(els) && pyidx(els, 0) == 'else' ? pytail(els, 1) : [els]
    end
    return try_stmt(then_body, else_body) if cond_defined_by_setjmp(cond)
    end_l = new_label('IL_end')
    expr(cond)
    if else_body.nil?
      emit("brfalse #{end_l}")
      stmts(then_body)
      emit("#{end_l}:")
      return
    end
    els_l = new_label('IL_else')
    emit("brfalse #{els_l}")
    stmts(then_body)
    emit("br #{end_l}", "#{els_l}:")
    stmts(else_body)
    emit("#{end_l}:")
  end

  def try_stmt(body, handler)
    # Only one catch clause is supported: the catch sets __catch_clause_number to 1, and selecting among several
    # clauses needs the typeinfo objects (not emitted yet). An eq against a larger clause number means more clauses.
    if !handler.nil? && has_clause_test(handler, 2)
      refuse("#{pys(@name)}: try with several catch clauses is not supported by the spike (needs typeinfo matching)")
    end
    end_l = new_label('IL_try_end')
    @try_depth += 1
    emit('.try {')
    stmts(body)
    emit("leave #{end_l}", '}')
    @try_depth -= 1
    emit('catch class CxxThrow {')
    @try_depth += 1
    emit('pop')  # the exception object; the thrown pointer is the linker's cxx_ptr
    emit("ldsfld int64 Prog::'addr_#{@em.gname('__caught_object_address')}'", 'conv.u',
         "ldsfld int64 Prog::'cxx_ptr'", 'stind.i8')
    emit("ldsfld int64 Prog::'addr_#{@em.gname('__catch_clause_number')}'", 'conv.u', 'ldc.i4.1', 'stind.i4')
    @em.addrs[@em.gname('__caught_object_address')] = true
    @em.addrs[@em.gname('__catch_clause_number')] = true
    stmts(handler) unless handler.nil?
    emit("leave #{end_l}", '}')
    @try_depth -= 1
    emit("#{end_l}:")
  end

  def loop_stmt(s)
    body = nil
    step = nil
    pytail(s, 1).each do |part|
      if part.is_a?(Array) && truthy(part) && pyidx(part, 0) == 'body'
        body = pytail(part, 1)
      elsif part.is_a?(Array) && truthy(part) && pyidx(part, 0) == 'step'
        step = pytail(part, 1)
      end
    end
    top = new_label('IL_top')
    cont = new_label('IL_cont')
    brk = new_label('IL_brk')
    emit("#{top}:")
    @loop_stack << [brk, cont, @try_depth]
    stmts(body || [])
    emit("#{cont}:")
    (step || []).each { |st| stmt(st) }  # break and continue in the step belong to this loop too
    @loop_stack.pop
    emit("br #{top}", "#{brk}:")
  end

  # the function -----------------------------------------------------------

  def translate(form)
    @frame_local = nil
    slots = []
    body = []
    pytail(form, 2).each do |part|
      if part.is_a?(Array) && truthy(part) && pyidx(part, 0) == 'slot'
        slots << part
      elsif part.is_a?(Array) && truthy(part) && pyidx(part, 0) == 'body'
        body.concat(pytail(part, 1))
      elsif part.is_a?(Array) && truthy(part) && FUNCTION_HEADER.include?(pyidx(part, 0))
        next  # (ret ...) and (params ...) were read by parse_header; the linkage markers need no code
      elsif part.is_a?(Array) && truthy(part)
        body << part  # a statement; stmt() refuses one it does not know (nothing is dropped)
      else
        refuse("#{pys(@name)}: unexpected #{py_repr(part)} in a function")
      end
    end
    off = 0
    slots.each do |sl|
      size = py_int(pyidx(sl, 3))
      align = py_int(pyidx(sl, 4))
      off = (off + align - 1) / align * align
      @slots[pyidx(sl, 1)] = off
      off += size
    end
    @frame = (off + 15) / 16 * 16
    @frame_local = new_local('int64')
    @ret_local = @ret == 'void' ? nil : new_local(@ret)
    @ret_label = new_label('IL_ret')
    emit("ldc.i4 #{@frame}", 'localloc', 'conv.u8', "stloc #{@frame_local}") if @frame != 0
    body.each { |stmt_form| stmt(stmt_form) }
    if @ret == 'void'
      emit("#{@ret_label}:", 'ret')
    else
      emit('ldnull', 'throw')  # falling off a non-void function: undefined behaviour in C++
      emit("#{@ret_label}:", "ldloc #{@ret_local}", 'ret')
    end
    lines = [".method static #{pys(@ret)} #{pys(@em.fn_name(@name))}(#{@params.map { |p| p[2] }.join(', ')}) cil managed {",
             '  .maxstack 1024']
    unless @local_types.empty?
      lines << '  .locals init (' + @local_types.each_with_index.map { |t, i| "#{t} V#{i}" }.join(', ') + ')'
    end
    @out.each do |x|
      lines << (x.end_with?(':') ? x : '    ' + x)
    end
    lines << '}'
    lines
  end
end

# ------------------------------------------------------------------ the module

# `(global NAME TYPE SIZE ALIGN [(static)] (init ITEM...))` -> a fragment data entry. ITEMs are (addr OFF TYPE REF
# ADD) and (scalar OFF TYPE (const TYPE V) | (null TYPE)); the offsets become zero fill. An EH runtime global
# (extern, in EH_GLOBALS) is zero storage here; any other extern is the linker's dlsym.
def global_data(f, em)
  name = pyidx(f, 1)
  size = py_int(pyidx(f, 3))
  align = py_int(pyidx(f, 4))
  init = nil
  pytail(f, 5).each do |part|
    init = pytail(part, 1) if part.is_a?(Array) && truthy(part) && pyidx(part, 0) == 'init'
    if part == ['extern']
      if EH_GLOBALS.key?(name)
        return { 'name' => name, 'exported' => true, 'align' => align, 'size' => size, 'items' => [] }
      end
      return nil
    end
  end
  return nil if init.nil?
  items = []
  pos = 0
  init.each do |it|
    kind = pyidx(it, 0)
    off = py_int(pyidx(it, 1))
    if off > pos
      items << ['zero', off - pos]
      pos = off
    end
    if kind == 'zero'  # (zero OFF SIZE)
      items << ['zero', py_int(pyidx(it, 2))]
      pos = off + py_int(pyidx(it, 2))
      next
    end
    if kind == 'bytes'  # (bytes OFF LEN @"const"): a copy of the bytes of a constant global (string literals)
      n = py_int(pyidx(it, 2))
      img = em.global_image(pyidx(it, 3), name)
      refuse("#{pys(name)}: bytes of #{n} from #{py_repr(pyidx(it, 3))}, which holds #{img.size} bytes") if img.size != n
      img.each { |b| items << ['int8', b] }
      pos = off + n
      next
    end
    if kind == 'addr'
      ref = pyidx(it, 3)
      refuse("#{pys(name)}: address item of #{py_repr(ref)}") unless ref.is_a?(Ref)
      items << ['addr', ref.name, py_int(pyidx(it, 4))]
      pos += 8
    elsif kind == 'scalar'
      val = pyidx(it, 3)
      ity = pyidx(it, 2)
      il, sz, _signed = if !ity.is_a?(Array)
                          em.type_of(ity)
                        elsif pyidx(ity, 0) == 'ptr'
                          ['int64', 8, false]
                        else
                          em.type_of(ity)
                        end
      if pyidx(val, 0) == 'null'
        items << ['int64', 0]
        pos += 8
        next
      end
      v = pyidx(val, 2)
      if il == 'float64'
        items << ['float64', le_int(pack_double(py_float_of(v)))]
      elsif il == 'float32'
        items << ['float32', le_int(pack_single(py_float_of(v)))]
      else
        items << [INT_ITEM.fetch(sz), py_int(v)]
      end
      pos += sz
    else
      refuse("#{pys(name)}: initializer item #{pys(kind)}")
    end
  end
  items << ['zero', size - pos] if pos < size
  { 'name' => name, 'exported' => true, 'align' => align, 'size' => size, 'items' => items }
end

# `(data "NAME" TYPE (string "..."))`, a string literal: the bytes of its array, zero padded to the array's size, as
# in emit_string of pathb-qbe-emit.rb. Other data forms are refused (nothing emits them yet).
def string_bytes(f, em)
  name = pyidx(f, 1)
  ty = pyidx(f, 2)
  text = pyidx(f, 3)
  unless text.is_a?(Array) && pylen(text) == 2 && pyidx(text, 0) == 'string' && pyidx(text, 1).is_a?(String)
    refuse("data #{pys(name)}: only string literals are supported by the spike")
  end
  t = ty
  t = pyidx(t, 1) while t.is_a?(Array) && truthy(t) && pyidx(t, 0) == 'const'
  unless t.is_a?(Array) && pylen(t) == 3 && pyidx(t, 0) == 'array'
    refuse("data #{pys(name)}: not an array")
  end
  total = py_int(pyidx(t, 1)) * em.type_of(pyidx(t, 2))[1]
  raw = cps(pyidx(text, 1))
  if raw.any? { |c| c > 255 } || raw.size > total
    refuse("data #{pys(name)}: string does not fit its array")
  end
  raw + [0] * (total - raw.size)
end

def main
  src = ARGV[0]
  out_path = ARGV[1]
  raise PyError, 'IndexError: list index out of range' if src.nil? || out_path.nil?
  bytes = if src == '-'
            $stdin.read.to_s  # sys.stdin.buffer: as it is
          else
            text = File.open(src, 'rb') { |f| f.read }.to_s
            # Python's text mode (universal newlines): \r\n and \r read as \n
            text = text.gsub("\r\n", "\n").gsub("\r", "\n") if text.include?("\r")
            text
          end
  forms = Parser.new(tokenize(bytes.unpack('C*'))).forms
  em = Emitter.new
  functions = []
  data = []
  em.global_forms = {}
  em.data_forms = {}
  forms.each do |f|
    em.global_forms[pyidx(f, 1)] = f if f.is_a?(Array) && truthy(f) && pyidx(f, 0) == 'global'
  end
  forms.each do |f|
    em.data_forms[pyidx(f, 1)] = f if f.is_a?(Array) && truthy(f) && pyidx(f, 0) == 'data'
  end
  forms.each do |f|
    next unless f.is_a?(Array) && truthy(f)
    if pyidx(f, 0) == 'global'
      d = global_data(f, em)
      data << d unless d.nil?
      next
    end
    if pyidx(f, 0) == 'data'
      raw = string_bytes(f, em)
      data << { 'name' => pyidx(f, 1), 'exported' => true, 'align' => 1, 'size' => raw.size,
                'items' => raw.map { |c| ['int8', c] } }
      next
    end
    next unless pyidx(f, 0) == 'function'
    name = pyidx(f, 1)
    if f.any? { |p| p.is_a?(Array) && truthy(p) && pyidx(p, 0) == 'variadic' }
      refuse("#{pys(name)}: variadic definitions are not supported by the spike")
    end
    fn = Function.new(em, f)
    il = fn.translate(f)
    functions << { 'name' => name, 'ret' => fn.ret, 'params' => fn.params.map { |p| p[2] }, 'exported' => true,
                   'il' => il }
  end
  fragment = { 'tu' => 'pathb', 'functions' => functions, 'data' => data, 'calls' => em.fragment_calls,
               'addrs' => em.addrs.keys.sort, 'ctors' => [] }
  File.open(out_path, 'wb') { |fh| fh.write(json_val(fragment, 0)) }
end

begin
  main
rescue Refused => e
  $stderr.write("pathb-cil-emit: refused: #{e.message}\n")
  exit 1
rescue StandardError => e
  $stderr.write("pathb-cil-emit: error: #{e.message}\n")
  exit 1
end
