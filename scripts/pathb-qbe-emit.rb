# Path B stage 3: emit QBE IL from the nfcxx mid-level IR text (docs/notes/pathb-stage2.md, sections 6 and 7).
#
# Usage: scripts/mrb scripts/pathb-qbe-emit.rb [FILE.ir | -]   QBE IL on stdout (reads stdin for '-' or no argument)
#        scripts/mrb scripts/pathb-qbe-emit.rb --append-weak IL.ssa ASM.s
#                                                              append `.weak` lines for the IR (weak) definitions
#
# Exit status:
#   0  the module was emitted
#   3  refused: the IR has a node, type or marker this emitter does not handle; the reason is on stderr
#   1  error: malformed IR text, or an IR format older than this emitter (rebuild the harness)
#
# The emitter never guesses. Anything it does not know is a refusal, never silently dropped. Checked IR operations
# (cdiv, crem, cshl, cshr, cf2i, cadd, csub, cmul, cneg, bounds, nonnull, unreachable) become a compare and a branch
# to one shared abort block that calls abort(). Registers are stack slots; QBE's own promotion turns them back into
# SSA temporaries. Scalar sizes assume LP64 (int 4, long 8, pointers 8), which is what the x86-64 Linux target uses.
#
# This is a line-by-line port of the Python original (tests/mruby/oracle/pathb-qbe-emit.py) to mruby; the output,
# the messages on stderr and the exit status are identical (tests/mruby/run.sh compares them). Notes on the port:
#   - mruby has no Regexp: the three patterns of the original are character checks (as_int, reg?, qname?).
#   - Integer constants go up to 2**64 - 1, so the interpreter needs mruby-bigint (scripts/mruby-tool-config.rb).
#   - Python's repr(float) (the shortest digits that read back the same double) is rebuilt in py_float_repr with
#     exact bigint arithmetic, because mruby's own float formatting prints at most 15 significant digits.
#   - A Python tuple prints as (a, b) in messages, so types (Arrays here) print with tyrepr.
#   - Strings are byte strings. The Python original reads the IR as latin-1 and writes stderr as UTF-8, which
#     u8() reproduces for the messages.

class Refused < StandardError; end   # a node this emitter does not handle (exit status 3)
class BadIR < StandardError; end     # malformed IR text or an unknown IR format (exit status 1)

# ------------------------------------------------------------------ Python formatting helpers

# repr() of a str (single quotes unless the text has ' and no ").
def py_str_repr(s)
  q = (s.index("'") && !s.index('"')) ? '"' : "'"
  out = q.dup
  s.each_byte do |c|
    ch = c.chr
    if ch == q || ch == "\\"
      out << "\\" << ch
    elsif c == 10
      out << "\\n"
    elsif c == 13
      out << "\\r"
    elsif c == 9
      out << "\\t"
    elsif c < 32 || (c >= 127 && c <= 160) || c == 173
      out << "\\x" << (c < 16 ? "0" : "") << c.to_s(16)
    else
      out << ch
    end
  end
  out << q
  out
end

# repr() of a form (list, atom, IRStr, IRSym) as Python prints it.
def pyrepr(x)
  if x.is_a?(Array)
    "[" + x.map { |y| pyrepr(y) }.join(", ") + "]"
  elsif x.is_a?(IRSym)
    "(" + py_str_repr(x.sig) + ", " + py_str_repr(x.name) + ")"
  elsif x.is_a?(IRStr)
    py_str_repr(x.to_s)
  elsif x.is_a?(String)
    py_str_repr(x)
  else
    x.to_s
  end
end

# repr() of a type, which is a Python tuple of strings, ints, bools, None and nested types.
def tyrepr(t)
  if t.nil?
    "None"
  elsif t == true
    "True"
  elsif t == false
    "False"
  elsif t.is_a?(Array)
    "(" + t.map { |y| tyrepr(y) }.join(", ") + (t.length == 1 ? "," : "") + ")"
  elsif t.is_a?(String)
    py_str_repr(t)
  else
    t.to_s
  end
end

# str((ty,)): a one-element tuple holding a type.
def ty1(t)
  "(" + tyrepr(t) + ",)"
end

# Latin-1 text to UTF-8, for stderr (the original's sys.stderr is UTF-8).
def u8(s)
  return s unless s.bytes.any? { |c| c >= 128 }
  out = "".b
  s.each_byte do |c|
    if c < 128
      out << c.chr
    else
      out << (0xc0 | (c >> 6)).chr << (0x80 | (c & 0x3f)).chr
    end
  end
  out
end

# ---- float repr
#
# Python's repr(float): the shortest decimal that reads back as the same double (the closest one if several).
# Built from exact integer arithmetic: for 1..17 digits, round the exact value to that many digits and check
# that it parses back to the same double.

def float_bits(v)
  bits = 0
  [v].pack("E").unpack("C*").reverse.each { |b| bits = bits * 256 + b }
  bits
end

# [digits, k] with v = d.ddd * 10**k, for a finite v > 0.
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
    if !(parse_float_digits(q, k - (p - 1)) == v)
      cands = [q + 1, q - 1].sort_by { |c| (c * den - num).abs }
    end
    cands.each do |c|
      next if c <= 0
      if parse_float_digits(c, k - (p - 1)) == v
        digs = c.to_s
        exp10 = k + (digs.length - p)
        digs = digs[0, digs.length - 1] while digs.length > 1 && digs.getbyte(digs.length - 1) == 48
        return [digs, exp10]
      end
    end
    p += 1
  end
  raise "float repr: no 17-digit decimal reads back"
end

def parse_float_digits(c, e)
  dec_to_double(c, e)
end

def py_float_repr(v)
  return "nan" if v.nan?
  return (v > 0 ? "inf" : "-inf") unless v.finite?
  neg = v < 0 || (v == 0 && 1.0 / v < 0)
  v = -v if neg
  return (neg ? "-0.0" : "0.0") if v == 0
  digs, k = shortest_digits(v)
  if k + 1 <= -4 || k + 1 > 16
    body = digs[0, 1] + (digs.length > 1 ? "." + digs[1, digs.length - 1] : "")
    e = k.abs
    body += "e" + (k < 0 ? "-" : "+") + (e < 10 ? "0" : "") + e.to_s
  elsif k >= 0
    if digs.length <= k + 1
      body = digs + "0" * (k + 1 - digs.length) + ".0"
    else
      body = digs[0, k + 1] + "." + digs[k + 1, digs.length - k - 1]
    end
  else
    body = "0." + "0" * (-k - 1) + digs
  end
  neg ? "-" + body : body
end

# The double nearest to m * 10**e (m >= 0 an Integer), rounded half to even like Python's float(). mruby's own
# String#to_f is not correctly rounded for 17-digit input, so the conversion is done in exact integer arithmetic.
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
  e2 = n.to_s(2).length - d.to_s(2).length  # floor(log2(n / d)) or one more
  ge = e2 >= 0 ? n >= (d << e2) : (n << (-e2)) >= d
  e2 -= 1 unless ge
  e2 = -1022 if e2 < -1022                   # subnormals share the exponent of the smallest normal
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
  bytes.pack("C*").unpack("E")[0]
end

# float(str) for the text of a floating constant. Python's grammar: [sign] (digits[.digits][e[sign]digits] |
# inf | infinity | nan); anything else is an error (the original dies with a traceback and status 1).
def py_float(s)
  t = s.strip
  low = t.downcase
  neg = false
  body = low
  if body.start_with?("-")
    neg = true
    body = body[1, body.length - 1]
  elsif body.start_with?("+")
    body = body[1, body.length - 1]
  end
  if body == "inf" || body == "infinity"
    return neg ? -Float::INFINITY : Float::INFINITY
  end
  return 0.0 / 0.0 if body == "nan"
  i = 0
  n = body.length
  digits = ""
  while i < n && body[i] >= "0" && body[i] <= "9"
    digits << body[i]
    i += 1
  end
  fraclen = 0
  if i < n && body[i] == "."
    i += 1
    while i < n && body[i] >= "0" && body[i] <= "9"
      digits << body[i]
      fraclen += 1
      i += 1
    end
  end
  ok = digits.length > 0
  ex = 0
  if ok && i < n && body[i] == "e"
    i += 1
    eneg = false
    if i < n && (body[i] == "+" || body[i] == "-")
      eneg = body[i] == "-"
      i += 1
    end
    edigits = ""
    while i < n && body[i] >= "0" && body[i] <= "9"
      edigits << body[i]
      i += 1
    end
    ok = edigits.length > 0
    ex = edigits.to_i
    ex = -ex if eneg
  end
  raise "ValueError: could not convert string to float: #{py_str_repr(s)}" unless ok && i == n
  v = dec_to_double(digits.to_i, ex - fraclen)
  neg ? v * -1.0 : v   # (-v would lose the sign of a zero)
end

# ------------------------------------------------------------------ reading the IR text

# A double-quoted string. codes holds one integer per character (latin-1, or more for a large octal escape).
class IRStr
  attr_reader :codes

  def initialize(codes)
    @codes = codes
  end

  def to_s
    s = "".b
    @codes.each { |c| s << (c & 255).chr }
    s
  end
end

# A sigil and a quoted name: $"x" (slot), @"x" (static object), &"f" (function).
class IRSym
  attr_reader :sig, :name

  def initialize(sig, name)
    @sig = sig
    @name = name
  end
end

# str.isspace() for a latin-1 character
def space_byte?(c)
  (c >= 9 && c <= 13) || (c >= 28 && c <= 32) || c == 0x85 || c == 0xa0
end

def read_string(text, i)
  out = []
  i += 1
  n = text.bytesize
  while true
    raise BadIR, "unterminated string in IR" if i >= n
    c = text.getbyte(i)
    if c == 34
      return [out, i + 1]
    end
    if c == 92
      i += 1
      raise BadIR, "bad escape at end of IR" if i >= n
      e = text.getbyte(i)
      if e == 110
        out << 10
        i += 1
      elsif e == 34 || e == 92
        out << e
        i += 1
      elsif e >= 48 && e <= 55 && i + 2 < n && octal?(text.getbyte(i + 1)) && octal?(text.getbyte(i + 2))
        out << ((e - 48) * 64 + (text.getbyte(i + 1) - 48) * 8 + (text.getbyte(i + 2) - 48))
        i += 3
      else
        raise BadIR, "unknown escape \\#{e.chr} in IR string"
      end
    else
      out << c
      i += 1
    end
  end
end

def octal?(c)
  c >= 48 && c <= 55
end

def tokenize(text)
  toks = []
  i = 0
  n = text.bytesize
  while i < n
    c = text.getbyte(i)
    if space_byte?(c)
      i += 1
    elsif c == 40 || c == 41
      toks << c.chr
      i += 1
    elsif c == 34
      s, i = read_string(text, i)
      toks << IRStr.new(s)
    elsif (c == 36 || c == 64 || c == 38) && i + 1 < n && text.getbyte(i + 1) == 34
      s, i = read_string(text, i + 1)
      toks << IRSym.new(c.chr, IRStr.new(s).to_s)
    else
      j = i
      while j < n
        d = text.getbyte(j)
        break if space_byte?(d) || d == 40 || d == 41 || d == 34
        j += 1
      end
      toks << text.byteslice(i, j - i)
      i = j
    end
  end
  toks
end

# The list of top-level forms. A form is an Array, or an atom (String, IRStr, IRSym).
def parse_forms(toks)
  stack = [[]]
  toks.each do |t|
    if t.is_a?(String) && t == "("
      stack << []
    elsif t.is_a?(String) && t == ")"
      raise BadIR, "unbalanced ')' in IR" if stack.length == 1
      done = stack.pop
      stack[-1] << done
    else
      stack[-1] << t
    end
  end
  raise BadIR, "unbalanced '(' in IR" if stack.length != 1
  stack[0]
end

# ------------------------------------------------------------------ types
# A type is an Array standing for the Python tuple: ["int", size, signed, bool], ["float", size], ["ptr", pointee|nil],
# ["array", n, elem], ["agg", head, name], ["fn"], ["void"].

VOID = ["void"]
SCALARS = {
  "bool" => ["int", 1, false, true],
  "char" => ["int", 1, true, false],
  "signed_char" => ["int", 1, true, false],
  "unsigned_char" => ["int", 1, false, false],
  "short" => ["int", 2, true, false],
  "unsigned_short" => ["int", 2, false, false],
  "int" => ["int", 4, true, false],
  "unsigned_int" => ["int", 4, false, false],
  "long" => ["int", 8, true, false],
  "unsigned_long" => ["int", 8, false, false],
  "long_long" => ["int", 8, true, false],
  "unsigned_long_long" => ["int", 8, false, false],
  "float" => ["float", 4],
  "double" => ["float", 8],
}

def parse_type(x)
  if x.is_a?(String)
    return VOID if x == "void"
    return SCALARS[x] if SCALARS.key?(x)
    raise Refused, "type long_double (no QBE type; cproc refuses it too)" if x == "long_double"
    raise Refused, "type #{x}"
  end
  raise BadIR, "bad type form #{pyrepr(x)}" if !x.is_a?(Array) || x.empty?
  head = x[0]
  if head == "ptr"
    return ["ptr", x.length == 2 ? parse_type(x[1]) : nil]
  end
  return parse_type(x[1]) if head == "const" || head == "volatile"
  if head == "array"
    return ["array", nil, parse_type(x[2])] if x[1] == "?"   # variable-length: no count
    return ["array", x[1].to_i, parse_type(x[2])]
  end
  return ["agg", head, pstr(x[1])] if head == "struct" || head == "class" || head == "union"
  return ["fn"] if head == "fn"
  raise Refused, "type form (#{pstr(head)} ...)"
end

def is_agg(ty)
  ty[0] == "agg" || ty[0] == "array"
end

def is_int(ty)
  ty[0] == "int"
end

def is_bool(ty)
  ty[0] == "int" && ty[3]
end

def ty_size(ty)
  return ty[1] if ty[0] == "int"
  return ty[1] if ty[0] == "float"
  return 8 if ty[0] == "ptr" || ty[0] == "fn"
  raise Refused, "scalar size of aggregate type in value position"
end

# QBE class of a value of IR type ty.
def qcls(ty)
  if ty[0] == "int"
    return ty[1] <= 4 ? "w" : "l"
  end
  return (ty[1] == 4 ? "s" : "d") if ty[0] == "float"
  return "l" if ty[0] == "ptr" || ty[0] == "fn"
  return nil if ty[0] == "void"
  raise Refused, "aggregate value of type #{tyrepr(ty)} (aggregates are addresses in the IR)"
end

def int_is_signed(ty)
  ty[0] == "int" && ty[2]
end

def int_range(ty)
  bits = ty[1] * 8
  if int_is_signed(ty)
    return [-(1 << (bits - 1)), (1 << (bits - 1)) - 1]
  end
  [0, (1 << bits) - 1]
end

def wrap_int(v, cls)
  bits = cls == "w" ? 32 : 64
  v = v % (1 << bits)
  # (not `v >= 1 << (bits - 1)`: mruby compares a fixnum with a bigint through a double, so 2^63 - 1 >= 2^63 is true)
  v -= (1 << bits) if (v >> (bits - 1)) != 0
  v
end

# float(v) rounded to single precision, as struct.pack("f") does (it refuses a value that overflows)
def to_single(v)
  r = [v].pack("e").unpack("e")[0]
  raise "OverflowError: float too large to pack with f format" unless r.finite?
  r
end

def float_lit(v, size)
  raise Refused, "non-finite floating constant #{py_float_repr(v)}" unless v.finite?
  if size == 4
    v = to_single(v)
    return "s_" + py_float_repr(v)
  end
  "d_" + py_float_repr(v)
end

def data_float(v, size)
  raise Refused, "non-finite floating constant #{py_float_repr(v)}" unless v.finite?
  if size == 4
    v = to_single(v)
    return ["s", "s_" + py_float_repr(v)]
  end
  ["d", "d_" + py_float_repr(v)]
end

# ------------------------------------------------------------------ helpers over forms

def head_of(x)
  return x[0] if x.is_a?(Array) && !x.empty? && x[0].is_a?(String)
  nil
end

# str(x)
def pstr(x)
  return x if x.is_a?(String)
  return x.to_s if x.is_a?(IRStr)
  pyrepr(x)
end

def form_text(x)
  if x.is_a?(Array)
    "(" + x.map { |y| form_text(y) }.join(" ") + ")"
  elsif x.is_a?(IRSym)
    "#{x.sig}\"#{x.name}\""
  elsif x.is_a?(IRStr)
    "\"#{x}\""
  else
    x.to_s
  end
end

def digit_byte?(c)
  c >= 48 && c <= 57
end

# An integer atom. The IR prints unsigned constants in hexadecimal (0x...) as well as in decimal.
def as_int(x)
  if x.is_a?(String)
    s = x
    neg = false
    if s.start_with?("-")
      neg = true
      s = s.byteslice(1, s.bytesize - 1)
    end
    if s.bytesize > 2 && s.getbyte(0) == 48 && s.getbyte(1) == 120
      h = s.byteslice(2, s.bytesize - 2)
      if h.bytes.all? { |c| digit_byte?(c) || (c >= 97 && c <= 102) || (c >= 65 && c <= 70) }
        v = h.to_i(16)
        return neg ? -v : v
      end
    elsif s.bytesize > 0 && s.bytes.all? { |c| digit_byte?(c) }
      v = s.to_i
      return neg ? -v : v
    end
  end
  raise BadIR, "expected an integer, got #{form_text(x)}"
end

# re.match(r"%(\d+)$", op)
def reg?(op)
  return false unless op.is_a?(String)
  n = op.bytesize
  return false if n < 2 || op.getbyte(0) != 37
  i = 1
  i += 1 while i < n && digit_byte?(op.getbyte(i))
  i == n || (i == n - 1 && op.getbyte(i) == 10)   # `$` also matches before a final newline
end

# re.match(r"[A-Za-z_][A-Za-z0-9_.]*$", name)
def qname?(name)
  n = name.bytesize
  n -= 1 if n > 0 && name.getbyte(n - 1) == 10
  return false if n == 0
  c = name.getbyte(0)
  return false unless c == 95 || (c >= 65 && c <= 90) || (c >= 97 && c <= 122)
  i = 1
  while i < n
    c = name.getbyte(i)
    return false unless c == 95 || c == 46 || (c >= 65 && c <= 90) || (c >= 97 && c <= 122) || (c >= 48 && c <= 57)
    i += 1
  end
  true
end

def qsym(name)
  raise Refused, "symbol name #{py_str_repr(name)} needs quoting in QBE" unless qname?(name)
  name
end

# ------------------------------------------------------------------ values

class Val
  attr_reader :t, :cls, :ty

  def initialize(t, cls, ty)
    @t = t
    @cls = cls
    @ty = ty
  end
end

MEM_LOAD = { "w" => "loadw", "l" => "loadl", "s" => "loads", "d" => "loadd" }
MEM_STORE = { "w" => "storew", "l" => "storel", "s" => "stores", "d" => "stored" }
CMP_INT = { "lt.s" => "cslt", "le.s" => "csle", "lt.u" => "cult", "le.u" => "cule" }
CMP_FLT = { "lt.f" => "clt", "le.f" => "cle" }

class Module_
  attr_accessor :globals, :strings, :out, :need_sink, :thread, :vhelpers, :weakrefs, :startup, :funcs, :got

  def initialize
    @globals = {}       # IR name -> type
    @strings = {}       # data name -> array of character codes
    @out = []
    @need_sink = false  # a function that returns twice stores slot addresses into SINK
    @thread = {}        # IR name -> "def" or "ext": thread-local globals ((thread) marker; ext = declaration only)
    @vhelpers = {}      # volatile access helpers used so far: QBE function name -> its text lines
    @weakrefs = {}      # undefined functions that are weak references (TLS init functions, see weak_refs)
    @startup = []       # [".init_array" or ".fini_array", priority (0: none), QBE symbol] of (constructor)/(destructor)
    @funcs = {}         # IR name -> true for every function defined in this module
    @got = {}           # IR name of an external function whose address is taken -> its pointer cell (see opnd_)
  end
end

# Functions that return twice. QBE does not know that, and it promotes a stack slot to an SSA temporary when only
# loads and stores use its address. After longjmp the promoted value would be the one from the setjmp call, not the
# last one assigned. A function that calls one of these keeps every slot in memory (see escape_slots).
SINK = "pathb_escape"
RETURNS_TWICE = ["setjmp", "_setjmp", "sigsetjmp", "__sigsetjmp", "savectx", "vfork", "getcontext"]

# Store the address of every slot into a module-level sink. An address that escapes to memory is neither
# promoted to a temporary nor forwarded across calls by QBE's load optimisation, so each slot's value stays in
# memory, where longjmp finds the last assignment. (The sink has to be a global: a stack slot used for this would
# itself be promoted, and the stores would vanish before QBE looks at escapes.)
def escape_slots(allocs)
  allocs.map { |line| "\tstorel #{line.split[0]}, $#{SINK}" }
end

# One function body. Statements are emitted into body; registers and slots into allocs.
class Fn
  attr_accessor :mod, :name, :ret_ty, :body, :allocs, :inits, :returns_twice, :dead, :regs, :slots, :nslot,
                :breaks, :conts, :case_labels, :abort_used, :nvla

  def initialize(mod, name, ret_ty)
    @mod = mod
    @name = name
    @ret_ty = ret_ty
    @body = []
    @allocs = []
    @inits = []             # instructions that run first in @start, after the allocs
    @nvla = 0               # vlaalloc statements so far (each has a capacity slot)
    @returns_twice = false  # calls setjmp or another function that returns twice
    @ntmp = 0
    @nlab = 0
    @dead = false
    @regs = {}              # N -> [type, cls]
    @slots = {}             # IR name -> [qname, type]
    @nslot = 0
    @labels = {}            # IR label name -> @name
    @breaks = []            # exit labels of enclosing loops and switches
    @conts = []             # step labels of enclosing loops, for (continue)
    @case_labels = {}       # object_id(marker) -> @label, for the switch being emitted
    @abort_used = false
  end

  # ---- output
  def put(s)
    @body << ("\t" + s)
  end

  def tmp
    @ntmp += 1
    "%t#{@ntmp}"
  end

  def newlab
    @nlab += 1
    "@b#{@nlab}"
  end

  def start_block(lab)
    put("jmp #{lab}") unless @dead
    @body << lab
    @dead = false
  end

  def ensure_live
    if @dead
      @body << newlab
      @dead = false
    end
  end

  def emit(s)
    ensure_live
    put(s)
  end

  def jmp(lab)
    ensure_live
    put("jmp #{lab}")
    @dead = true
  end

  def jnz(c, yes, no)
    ensure_live
    put("jnz #{c}, #{yes}, #{no}")
    @dead = true
  end

  def ret(v = nil)
    ensure_live
    put(v.nil? ? "ret" : "ret #{v}")
    @dead = true
  end

  def label(lab)
    start_block(lab)
  end

  def abort_label
    @abort_used = true
    "@abort"
  end

  # Abort when the w value c is nonzero.
  def trap_if(c)
    ok = newlab
    jnz(c, abort_label, ok)
    label(ok)
  end

  # Abort when the w value c is zero.
  def trap_unless(c)
    ok = newlab
    jnz(c, ok, abort_label)
    label(ok)
  end

  def lab_for(name)
    @labels[name] = "@L#{@labels.length}" unless @labels.key?(name)
    @labels[name]
  end

  # ---- registers and slots
  def declare_reg(n, ty)
    raise BadIR, "register %#{n} declared twice in #{@name}" if @regs.key?(n)
    cls = qcls(ty)
    raise Refused, "register %#{n} of type void" if cls.nil?
    @regs[n] = [ty, cls]
    size = cls == "w" ? 4 : cls == "l" ? 8 : ty_size(ty)
    @allocs << "\t%r#{n} =l alloc#{size} #{size}"
    cls
  end

  def reg_val(n)
    raise BadIR, "register %#{n} used before its declaration in #{@name}" unless @regs.key?(n)
    ty, cls = @regs[n]
    t = tmp
    emit("#{t} =#{cls} #{MEM_LOAD[cls]} %r#{n}")
    Val.new(t, cls, ty)
  end

  def set_reg(n, v)
    raise BadIR, "assignment to undeclared register %#{n} in #{@name}" unless @regs.key?(n)
    ty, cls = @regs[n]
    raise Refused, "register %#{n} of class #{cls} assigned a value of class #{v.cls}" if v.cls != cls
    emit("#{MEM_STORE[cls]} #{v.t}, %r#{n}")
  end

  def slot_val(name)
    raise BadIR, "slot $\"#{name}\" not declared in #{@name}" unless @slots.key?(name)
    q, ty = @slots[name]
    Val.new(q, "l", ["ptr", ty])
  end

  # ---- operands
  def const(c)
    raise BadIR, "bad constant #{form_text(c)}" if c.length != 3
    ty = parse_type(c[1])
    v = c[2]
    raise Refused, "constant #{form_text(c)}" if v.is_a?(Array) || v.is_a?(IRStr)
    if ty[0] == "float"
      fv = py_float(pstr(v))
      return Val.new(float_lit(fv, ty[1]), qcls(ty), ty)
    end
    if ty[0] == "int" || ty[0] == "ptr"
      cls = qcls(ty)
      return Val.new(wrap_int(as_int(v), cls).to_s, cls, ty)
    end
    raise Refused, "constant of type #{tyrepr(ty)}"
  end

  # Value of an operand. want is the expected QBE class (checked).
  def opnd(op, want = nil)
    v = opnd_(op)
    if !want.nil? && v.cls != want
      raise Refused, "operand class #{v.cls} where #{want} is expected: #{form_text(op)}"
    end
    v
  end

  def opnd_(op)
    if op.is_a?(String)
      return reg_val(op.byteslice(1, op.bytesize - 1).to_i) if reg?(op)
      raise BadIR, "unknown operand #{op}"
    end
    if op.is_a?(IRSym)
      sig = op.sig
      name = op.name
      return slot_val(name) if sig == "$"
      if sig == "@"
        if @mod.thread.key?(name)
          # Thread-local object: its address is the thread pointer plus the object's TLS offset. A definition in this
          # module uses the local-exec model (`thread $x`); a declaration uses initial-exec through the GOT
          # (`extern thread $x`), so the object may live in another object file or in a shared library.
          # The address goes through a temporary so that it is a plain `l` value wherever it is used.
          t = tmp
          emit("#{t} =l copy #{@mod.thread[name] == "ext" ? "extern thread" : "thread"} $#{qsym(name)}")
          return Val.new(t, "l", ["ptr", @mod.globals[name]])
        end
        return Val.new("$" + qsym(name), "l", ["ptr", @mod.globals[name]])
      end
      if sig == "&"
        # A weak reference goes through the GOT (`extern`), so that an absent definition reads as null in a PIE too.
        return Val.new("extern $" + qsym(name), "l", ["ptr", ["fn"]]) if @mod.weakrefs.key?(name)
        return Val.new("$" + qsym(name), "l", ["ptr", ["fn"]]) if @mod.funcs.key?(name)
        # The address of a function defined elsewhere (a libstdc++ operator delete passed to __cxa_vec_delete, for
        # example). `leaq f(%rip)` is a PC-relative reference that a PIE link rejects for a symbol of a shared
        # library, so the address is loaded from a local pointer cell, which takes a dynamic relocation instead.
        cell = "pathb_got." + qsym(name)
        @mod.got[name] = cell
        t = tmp
        emit("#{t} =l loadl $#{cell}")
        return Val.new(t, "l", ["ptr", ["fn"]])
      end
    end
    return const(op) if head_of(op) == "const"
    if head_of(op) == "null"
      ty = parse_type(op[1])
      return Val.new("0", "l", ty)
    end
    raise Refused, form_text(op) if head_of(op) == "unsupported"
    raise BadIR, "bad operand #{form_text(op)}"
  end

  # ---- conversions
  # Normalize a w value to a 1- or 2-byte integer type (QBE has no narrow temporaries).
  def narrow(v, ty)
    if ty[0] == "int" && (ty[1] == 1 || ty[1] == 2) && !ty[3]
      op = if ty[1] == 1
             ty[2] ? "extsb" : "extub"
           else
             ty[2] ? "extsh" : "extuh"
           end
      t = tmp
      emit("#{t} =w #{op} #{v.t}")
      return Val.new(t, "w", ty)
    end
    Val.new(v.t, v.cls, ty)
  end

  # Integer or pointer conversion from the value v of type src to type dst (both integer or pointer).
  def int_conv(v, src, dst)
    if dst[0] == "int" && dst[3]  # bool: nonzero is true
      t = tmp
      emit("#{t} =w cne#{v.cls} #{v.t}, 0")
      return Val.new(t, "w", dst)
    end
    dcls = qcls(dst)
    if dcls == "w"
      if v.cls == "l"
        t = tmp
        emit("#{t} =w copy #{v.t}")
        v = Val.new(t, "w", src)
      end
      return narrow(Val.new(v.t, "w", dst), dst)
    end
    # 8-byte destination
    if v.cls == "w"
      if src[0] == "int" && int_is_signed(src) && !src[3]
        op = "extsw"
      else
        op = "extuw"
      end
      t = tmp
      emit("#{t} =l #{op} #{v.t}")
      return Val.new(t, "l", dst)
    end
    Val.new(v.t, "l", dst)
  end

  # ---- checked-operation helpers
  # A w value as an l value, sign-extended (the operands of checked operations are signed).
  def ext64(v)
    return v.t if v.cls == "l"
    t = tmp
    emit("#{t} =l extsw #{v.t}")
    t
  end

  # Trap unless the 64-bit value r is representable in the integer type ty; return it as a value of ty.
  def fits(r, ty)
    t32 = tmp
    emit("#{t32} =w copy #{r}")
    tn = tmp
    op = { 1 => "extsb", 2 => "extsh", 4 => nil }[ty[1]]
    if op.nil?
      tn = t32
    else
      emit("#{tn} =w #{op} #{t32}")
    end
    back = tmp
    emit("#{back} =l extsw #{tn}")
    c = tmp
    emit("#{c} =w ceql #{back}, #{r}")
    trap_unless(c)
    Val.new(tn, "w", ty)
  end

  # ---- rvalues: returns a Val
  def rval(x, declared = nil)
    h = head_of(x)
    return opnd(x) if h.nil? || h == "const" || h == "null" || h == "unsupported"
    fn = RVAL[h]
    raise Refused, "rvalue (#{h} ...)" if fn.nil?
    fn.call(self, x)
  end

  def stmt(x)
    raise BadIR, "statement expected, got #{form_text(x)}" unless x.is_a?(Array)
    h = head_of(x)
    fn = STMT[h]
    if fn.nil?
      raise Refused, "statement #{form_text(x)}" if h == "unsupported"   # an IR gap marker: say which
      raise Refused, "statement (#{h || "None"} ...)"
    end
    fn.call(self, x)
  end

  def stmts(xs)
    xs.each { |s| stmt(s) }
  end
end

# -------- rvalue handlers (x is the form, x[0] the head)

def arith_cls(ty, x)
  raise Refused, "#{x[0]} on non-integer type #{ty1(ty)}" unless is_int(ty)
  qcls(ty)
end

def r_wbin(op)
  lambda do |fn, x|
    ty = parse_type(x[1])
    cls = arith_cls(ty, x)
    a = fn.opnd(x[2], cls)
    b = fn.opnd(x[3], cls)
    t = fn.tmp
    fn.emit("#{t} =#{cls} #{op} #{a.t}, #{b.t}")
    fn.narrow(Val.new(t, cls, ty), ty)
  end
end

def r_wneg(fn, x)
  ty = parse_type(x[1])
  cls = arith_cls(ty, x)
  a = fn.opnd(x[2], cls)
  t = fn.tmp
  fn.emit("#{t} =#{cls} sub 0, #{a.t}")
  fn.narrow(Val.new(t, cls, ty), ty)
end

def check_signed(ty, x)
  unless int_is_signed(ty)
    raise Refused, "#{x[0]} on unsigned type #{ty1(ty)} (the IR only emits checked forms for signed types)"
  end
end

# Checked signed add, sub or mul. The operation runs in 64 bits and the result must fit the type; a 64-bit
# add or sub is checked with the sign-bit identities. A 64-bit multiply is refused.
def r_cadd_like(op)
  lambda do |fn, x|
    ty = parse_type(x[1])
    check_signed(ty, x)
    cls = arith_cls(ty, x)
    a = fn.opnd(x[2], cls)
    b = fn.opnd(x[3], cls)
    if ty_size(ty) == 8
      raise Refused, "checked 64-bit signed multiply (cmul on #{tyrepr(ty)})" if op == "mul"
      r = fn.tmp
      fn.emit("#{r} =l #{op == "add" ? "add" : "sub"} #{fn.ext64(a)}, #{fn.ext64(b)}")
      if op == "add"
        x1 = fn.tmp
        x2 = fn.tmp
        x3 = fn.tmp
        fn.emit("#{x1} =l xor #{fn.ext64(a)}, #{r}")
        fn.emit("#{x2} =l xor #{fn.ext64(b)}, #{r}")
        fn.emit("#{x3} =l and #{x1}, #{x2}")
      else
        x1 = fn.tmp
        x2 = fn.tmp
        x3 = fn.tmp
        fn.emit("#{x1} =l xor #{fn.ext64(a)}, #{fn.ext64(b)}")
        fn.emit("#{x2} =l xor #{fn.ext64(a)}, #{r}")
        fn.emit("#{x3} =l and #{x1}, #{x2}")
      end
      c = fn.tmp
      fn.emit("#{c} =w csltl #{x3}, 0")
      fn.trap_if(c)
      next Val.new(r, "l", ty)
    end
    # 1-, 2- and 4-byte types: 64-bit result, then it must survive truncation to the type
    r = fn.tmp
    fn.emit("#{r} =l #{op} #{fn.ext64(a)}, #{fn.ext64(b)}")
    fn.fits(r, ty)
  end
end

def r_divrem(op)
  lambda do |fn, x|
    ty = parse_type(x[1])
    cls = arith_cls(ty, x)
    a = fn.opnd(x[2], cls)
    b = fn.opnd(x[3], cls)
    c = fn.tmp
    fn.emit("#{c} =w ceq#{cls} #{b.t}, 0")
    fn.trap_if(c)
    if int_is_signed(ty)
      lo = int_range(ty)[0]
      c2 = fn.tmp
      c3 = fn.tmp
      c4 = fn.tmp
      fn.emit("#{c2} =w ceq#{cls} #{a.t}, #{lo}")
      fn.emit("#{c3} =w ceq#{cls} #{b.t}, -1")
      fn.emit("#{c4} =w and #{c2}, #{c3}")
      fn.trap_if(c4)
      qop = op == "div" ? "div" : "rem"
    else
      qop = op == "div" ? "udiv" : "urem"
    end
    t = fn.tmp
    fn.emit("#{t} =#{cls} #{qop} #{a.t}, #{b.t}")
    fn.narrow(Val.new(t, cls, ty), ty)
  end
end

def r_shift(left)
  lambda do |fn, x|
    ty = parse_type(x[1])
    cls = arith_cls(ty, x)
    a = fn.opnd(x[2], cls)
    b = fn.opnd(x[3])
    width = ty[1] * 8
    bcls = b.cls
    # Trap unless 0 <= count < width. An unsigned compare also rejects negative counts.
    c = fn.tmp
    fn.emit("#{c} =w cult#{bcls} #{b.t}, #{width}")
    fn.trap_unless(c)
    if left
      op = "shl"
    else
      op = int_is_signed(ty) ? "sar" : "shr"
    end
    t = fn.tmp
    fn.emit("#{t} =#{cls} #{op} #{a.t}, #{b.t}")
    left ? fn.narrow(Val.new(t, cls, ty), ty) : Val.new(t, cls, ty)
  end
end

def r_cneg(fn, x)
  ty = parse_type(x[1])
  check_signed(ty, x)
  cls = arith_cls(ty, x)
  a = fn.opnd(x[2], cls)
  lo = int_range(ty)[0]
  c = fn.tmp
  fn.emit("#{c} =w ceq#{cls} #{a.t}, #{lo}")
  fn.trap_if(c)
  t = fn.tmp
  fn.emit("#{t} =#{cls} sub 0, #{a.t}")
  fn.narrow(Val.new(t, cls, ty), ty)
end

def r_fbin(op)
  lambda do |fn, x|
    ty = parse_type(x[1])
    raise Refused, "#{x[0]} on non-float type" if ty[0] != "float"
    cls = qcls(ty)
    a = fn.opnd(x[2], cls)
    b = fn.opnd(x[3], cls)
    t = fn.tmp
    fn.emit("#{t} =#{cls} #{op} #{a.t}, #{b.t}")
    Val.new(t, cls, ty)
  end
end

def r_fneg(fn, x)
  ty = parse_type(x[1])
  raise Refused, "fneg on non-float type" if ty[0] != "float"
  cls = qcls(ty)
  a = fn.opnd(x[2], cls)
  t = fn.tmp
  fn.emit("#{t} =#{cls} neg #{a.t}")
  Val.new(t, cls, ty)
end

def r_bitop(op)
  lambda do |fn, x|
    ty = parse_type(x[1])
    raise Refused, "#{x[0]} on type #{ty1(ty)}" unless is_int(ty) || is_bool(ty)
    cls = qcls(ty)
    a = fn.opnd(x[2], cls)
    b = fn.opnd(x[3], cls)
    t = fn.tmp
    fn.emit("#{t} =#{cls} #{op} #{a.t}, #{b.t}")
    fn.narrow(Val.new(t, cls, ty), ty)
  end
end

def r_not(fn, x)
  ty = parse_type(x[1])
  cls = qcls(ty)
  a = fn.opnd(x[2], cls)
  t = fn.tmp
  if is_bool(ty)
    fn.emit("#{t} =w xor #{a.t}, 1")
    return Val.new(t, "w", ty)
  end
  raise Refused, "not on type #{tyrepr(ty)}" unless is_int(ty)
  fn.emit("#{t} =#{cls} xor #{a.t}, -1")
  fn.narrow(Val.new(t, cls, ty), ty)
end

def r_eqne(op)
  lambda do |fn, x|
    ty = parse_type(x[1])
    cls = qcls(ty)
    a = fn.opnd(x[2], cls)
    b = fn.opnd(x[3], cls)
    t = fn.tmp
    fn.emit("#{t} =w c#{op}#{cls} #{a.t}, #{b.t}")
    Val.new(t, "w", SCALARS["bool"])
  end
end

def r_cmp(op)
  lambda do |fn, x|
    ty = parse_type(x[1])
    cls = qcls(ty)
    a = fn.opnd(x[2], cls)
    b = fn.opnd(x[3], cls)
    if CMP_INT.key?(op)
      raise Refused, "#{op} on non-integer type" if ty[0] != "int" && ty[0] != "ptr"
      name = CMP_INT[op] + cls
    else
      raise Refused, "#{op} on non-float type" if ty[0] != "float"
      name = CMP_FLT[op] + cls
    end
    t = fn.tmp
    fn.emit("#{t} =w #{name} #{a.t}, #{b.t}")
    Val.new(t, "w", SCALARS["bool"])
  end
end

def r_iconv(fn, x)
  dst = parse_type(x[1])
  v = fn.opnd(x[2])
  src = v.ty.nil? ? ["int", 8, false, false] : v.ty
  if (dst[0] != "int" && dst[0] != "ptr") || (src[0] != "int" && src[0] != "ptr")
    raise Refused, "iconv between #{tyrepr(src)} and #{tyrepr(dst)}"
  end
  fn.int_conv(v, src, dst)
end

def r_p2i(fn, x)
  dst = parse_type(x[1])
  v = fn.opnd(x[2], "l")
  fn.int_conv(v, ["ptr", nil], dst)
end

def r_i2p(fn, x)
  dst = parse_type(x[1])
  v = fn.opnd(x[2])
  src = v.ty
  raise Refused, "i2p from #{tyrepr(src)}" if src.nil? || src[0] != "int"
  fn.int_conv(v, src, ["ptr", nil])
end

def r_bitcast(fn, x)
  pt = parse_type(x[1])
  v = fn.opnd(x[2], "l")
  Val.new(v.t, "l", pt)
end

def r_i2f(fn, x)
  dst = parse_type(x[1])
  raise Refused, "i2f to non-float" if dst[0] != "float"
  v = fn.opnd(x[2])
  src = v.ty
  raise Refused, "i2f from #{tyrepr(src)}" if src.nil? || src[0] != "int"
  signed = int_is_signed(src) && !src[3]
  op = { ["w", true] => "swtof", ["l", true] => "sltof", ["w", false] => "uwtof", ["l", false] => "ultof" }[[v.cls, signed]]
  t = fn.tmp
  fn.emit("#{t} =#{qcls(dst)} #{op} #{v.t}")
  Val.new(t, qcls(dst), dst)
end

def r_fconv(fn, x)
  dst = parse_type(x[1])
  v = fn.opnd(x[2])
  raise Refused, "fconv between non-float types" if dst[0] != "float" || v.ty.nil? || v.ty[0] != "float"
  return Val.new(v.t, v.cls, dst) if qcls(dst) == v.cls
  t = fn.tmp
  if v.cls == "s"
    fn.emit("#{t} =d exts #{v.t}")
  else
    fn.emit("#{t} =s truncd #{v.t}")
  end
  Val.new(t, qcls(dst), dst)
end

# Float to integer with the trap of section 4: NaN or a value that does not fit the type. The test is done
# in double, where the bounds of each integer range are exact, so a float source is widened first.
def r_cf2i(fn, x)
  dst = parse_type(x[1])
  raise Refused, "cf2i to #{tyrepr(dst)}" if !is_int(dst) || is_bool(dst)
  v = fn.opnd(x[2])
  raise Refused, "cf2i from non-float" if v.ty.nil? || v.ty[0] != "float"
  d = v.t
  if v.cls == "s"
    d = fn.tmp
    fn.emit("#{d} =d exts #{v.t}")
  end
  lo, hi = cf2i_bounds(dst)
  c1 = fn.tmp
  c2 = fn.tmp
  c3 = fn.tmp
  fn.emit("#{c1} =w #{lo[0]} #{d}, #{lo[1]}")
  fn.emit("#{c2} =w #{hi[0]} #{d}, #{hi[1]}")
  fn.emit("#{c3} =w and #{c1}, #{c2}")
  fn.trap_unless(c3)
  conv = int_is_signed(dst) ? "dtosi" : "dtoui"
  cls = dst[1] == 8 ? "l" : "w"
  t = fn.tmp
  fn.emit("#{t} =#{cls} #{conv} #{d}")
  fn.narrow(Val.new(t, cls, dst), dst)
end

# Comparisons that a double d must satisfy to truncate into ty: (op, literal) for the lower and the upper bound.
# Lower: d > MIN-1 (32-bit and smaller), or d >= MIN for 64-bit (no double lies strictly between -2^63-1 and -2^63).
# Upper: d < MAX+1.
def cf2i_bounds(ty)
  signed = int_is_signed(ty)
  bits = ty[1] * 8
  if signed
    if bits == 64
      lo = ["cged", py_float_repr((-(1 << 63)).to_f)]
    else
      lo = ["cgtd", py_float_repr((-(1 << (bits - 1)) - 1).to_f)]
    end
    hi = ["cltd", py_float_repr((1 << (bits - 1)).to_f)]
  else
    lo = ["cgtd", "-1.0"]
    hi = ["cltd", py_float_repr((bits == 64 ? 1 << 64 : 1 << bits).to_f)]
  end
  [[lo[0], "d_" + lo[1]], [hi[0], "d_" + hi[1]]]
end

def r_offset(fn, x)
  a = fn.opnd(x[1], "l")
  n = as_int(x[2])
  t = fn.tmp
  fn.emit("#{t} =l add #{a.t}, #{n}")
  Val.new(t, "l", ["ptr", nil])
end

# The SIZE of index and pdiff: a number, or a register (a VLA element type) as an l-class QBE operand.
def size_text(fn, s)
  if s.is_a?(String) && reg?(s)
    v = fn.opnd(s)
    return v.t if v.cls == "l"
    t = fn.tmp
    fn.emit("#{t} =l extuw #{v.t}")
    return t
  end
  as_int(s).to_s
end

def r_index(fn, x)
  base = fn.opnd(x[1], "l")
  idx = fn.opnd(x[2])
  size = size_text(fn, x[3])
  if idx.cls == "l"
    i64 = idx.t
  elsif !idx.ty.nil? && idx.ty[0] == "int" && idx.ty[2] && !idx.ty[3]
    i64 = fn.tmp
    fn.emit("#{i64} =l extsw #{idx.t}")
  else
    i64 = fn.tmp
    fn.emit("#{i64} =l extuw #{idx.t}")
  end
  m = fn.tmp
  fn.emit("#{m} =l mul #{i64}, #{size}")
  t = fn.tmp
  fn.emit("#{t} =l add #{base.t}, #{m}")
  Val.new(t, "l", ["ptr", nil])
end

def r_pdiff(fn, x)
  a = fn.opnd(x[1], "l")
  b = fn.opnd(x[2], "l")
  size = size_text(fn, x[3])
  raise Refused, "pdiff with element size 0" if size == "0"
  d = fn.tmp
  fn.emit("#{d} =l sub #{a.t}, #{b.t}")
  t = fn.tmp
  fn.emit("#{t} =l div #{d}, #{size}")
  Val.new(t, "l", ["int", 8, true, false])
end

# Volatile accesses. QBE has no volatile: its load optimisation forwards a store to a later load of the same
# address, merges equal loads, and drops a load whose result is unused. So a volatile access is never written as a
# QBE load or store. It is a call of a small helper function (defined in the module, so a call QBE cannot look into
# or inline) that does the one real access. A call is neither merged nor removed, calls keep their order, and the
# address operand of the call makes a stack slot escape, so a volatile local stays in memory (QBE promotes a slot
# only when loads and stores are its sole uses). Cost: one call per access.
def vhelper(mod, op, cls)
  kind = op.start_with?("load") ? "ld" : "st"
  suffix = op.byteslice(kind == "ld" ? 4 : 5, op.bytesize)
  name = "__pathb_v#{kind}_#{suffix}"
  unless mod.vhelpers.key?(name)
    if kind == "ld"
      mod.vhelpers[name] = ["function #{cls} $#{name}(l %p) {", "@start", "\t%v =#{cls} #{op} %p", "\tret %v", "}", ""]
    else
      mod.vhelpers[name] = ["function $#{name}(l %p, #{cls} %v) {", "@start", "\t#{op} %v, %p", "\tret", "}", ""]
    end
  end
  name
end

def r_load(fn, x)
  raise BadIR, "load form" if x.length != 3
  vol = x[0] == "load.v"
  ty = parse_type(x[1])
  raise Refused, "load of an aggregate (aggregates are addresses)" if is_agg(ty)
  addr = fn.opnd(x[2], "l")
  op, cls = load_op(ty)
  t = fn.tmp
  if vol
    fn.emit("#{t} =#{cls} call $#{vhelper(fn.mod, op, cls)}(l #{addr.t})")
  else
    fn.emit("#{t} =#{cls} #{op} #{addr.t}")
  end
  if ty[0] == "int" && ty[3]
    # A bool object may hold bytes other than 0 and 1 (memcpy, a union, a char alias). The IR and the rest of the
    # emitter assume a bool operand is 0 or 1 (! is xor 1, == compares bits), so a load normalises: nonzero is true.
    t0 = t
    t = fn.tmp
    fn.emit("#{t} =w cnew #{t0}, 0")
  end
  Val.new(t, cls, ty)
end

LOAD_INT = {
  [1, true] => "loadsb", [1, false] => "loadub", [2, true] => "loadsh", [2, false] => "loaduh",
  [4, true] => "loadw", [4, false] => "loadw", [8, true] => "loadl", [8, false] => "loadl",
}

def load_op(ty)
  return ["loadl", "l"] if ty[0] == "ptr" || ty[0] == "fn"
  return (ty[1] == 4 ? ["loads", "s"] : ["loadd", "d"]) if ty[0] == "float"
  if ty[0] == "int"
    size = ty[1]
    signed = ty[2]
    isbool = ty[3]
    return ["loadub", "w"] if isbool
    return [LOAD_INT[[size, signed]], size <= 4 ? "w" : "l"]
  end
  raise Refused, "load of type #{tyrepr(ty)}"
end

def r_call(fn, x)
  # (call TYPE CALLEE [(variadic N)] ARG*): with (variadic N) the first N arguments match named parameters
  # and the QBE call gets "..." after them, so the callee's register-save prologue is set up (%al).
  ret = parse_type(x[1])
  # A direct call of a function symbol needs no cell: the linker routes it through the PLT.
  callee = x[2].is_a?(IRSym) && x[2].sig == "&" ? Val.new("$" + qsym(x[2].name), "l", ["ptr", ["fn"]]) : fn.opnd(x[2])
  fn.returns_twice = true if x[2].is_a?(IRSym) && RETURNS_TWICE.include?(x[2].name)
  rest = x.drop(3)
  nfixed = nil
  if !rest.empty? && head_of(rest[0]) == "variadic"
    nfixed = as_int(rest[0][1])
    rest = rest.drop(1)
    raise BadIR, "call: (variadic #{nfixed}) with only #{rest.length} arguments" if nfixed > rest.length
  end
  args = rest.map { |a| fn.opnd(a) }
  parts = []
  args.each_with_index do |a, i|
    raise Refused, "call argument without a class" if a.cls.nil?
    parts << "..." if i == nfixed
    parts << "#{a.cls} #{a.t}"
  end
  parts << "..." if !nfixed.nil? && nfixed == args.length
  target = callee.t
  if ret == VOID
    fn.emit("call #{target}(#{parts.join(", ")})")
    return nil
  end
  cls = qcls(ret)
  t = fn.tmp
  fn.emit("#{t} =#{cls} call #{target}(#{parts.join(", ")})")
  Val.new(t, cls, ret)
end

RVAL = {
  "load" => ->(fn, x) { r_load(fn, x) },
  "load.v" => ->(fn, x) { r_load(fn, x) },
  "wadd" => r_wbin("add"), "wsub" => r_wbin("sub"), "wmul" => r_wbin("mul"),
  "wneg" => ->(fn, x) { r_wneg(fn, x) },
  "cadd" => r_cadd_like("add"), "csub" => r_cadd_like("sub"), "cmul" => r_cadd_like("mul"),
  "cneg" => ->(fn, x) { r_cneg(fn, x) },
  "cdiv" => r_divrem("div"), "crem" => r_divrem("rem"),
  "cshl" => r_shift(true), "cshr" => r_shift(false),
  "fadd" => r_fbin("add"), "fsub" => r_fbin("sub"), "fmul" => r_fbin("mul"), "fdiv" => r_fbin("div"),
  "fneg" => ->(fn, x) { r_fneg(fn, x) },
  "and" => r_bitop("and"), "or" => r_bitop("or"), "xor" => r_bitop("xor"),
  "not" => ->(fn, x) { r_not(fn, x) },
  "eq" => r_eqne("eq"), "ne" => r_eqne("ne"),
  "lt.s" => r_cmp("lt.s"), "le.s" => r_cmp("le.s"), "lt.u" => r_cmp("lt.u"), "le.u" => r_cmp("le.u"),
  "lt.f" => r_cmp("lt.f"), "le.f" => r_cmp("le.f"),
  "iconv" => ->(fn, x) { r_iconv(fn, x) }, "p2i" => ->(fn, x) { r_p2i(fn, x) },
  "i2p" => ->(fn, x) { r_i2p(fn, x) }, "bitcast" => ->(fn, x) { r_bitcast(fn, x) },
  "i2f" => ->(fn, x) { r_i2f(fn, x) }, "u2f" => ->(fn, x) { r_i2f(fn, x) },
  "fconv" => ->(fn, x) { r_fconv(fn, x) }, "cf2i" => ->(fn, x) { r_cf2i(fn, x) },
  "offset" => ->(fn, x) { r_offset(fn, x) }, "index" => ->(fn, x) { r_index(fn, x) },
  "pdiff" => ->(fn, x) { r_pdiff(fn, x) },
  "bfload" => ->(fn, x) { r_bfload(fn, x) }, "bfload.v" => ->(fn, x) { r_bfload(fn, x) },
  "call" => ->(fn, x) { r_call(fn, x) },
}

# -------- statement handlers

def s_block(fn, x)
  fn.stmts(x.drop(1))
end

def s_let(fn, x)
  raise BadIR, "let form" if x.length != 4
  raise BadIR, "let without a register" unless reg?(x[1])
  n = x[1].byteslice(1, x[1].bytesize - 1).to_i
  ty = parse_type(x[2])
  raise Refused, "register of aggregate type" if is_agg(ty)
  fn.declare_reg(n, ty)
  v = fn.rval(x[3], ty)
  raise BadIR, "void value assigned to a register" if v.nil?
  if v.cls != fn.regs[n][1]
    raise Refused, "let %#{n}: value class #{v.cls}, register class #{fn.regs[n][1]}"
  end
  fn.set_reg(n, v)
end

def s_set(fn, x)
  n = x[1].byteslice(1, x[1].bytesize - 1).to_i
  v = fn.opnd(x[2])
  fn.set_reg(n, v)
end

def s_store(fn, x)
  vol = x[0] == "store.v"
  ty = parse_type(x[1])
  raise Refused, "store of an aggregate type" if is_agg(ty)
  addr = fn.opnd(x[2], "l")
  val = fn.opnd(x[3])
  if ty[0] == "ptr" || ty[0] == "fn" || (ty[0] == "int" && ty[1] == 8)
    op = "storel"
    cls = "l"
  elsif ty[0] == "float"
    op, cls = ty[1] == 4 ? ["stores", "s"] : ["stored", "d"]
  elsif ty[0] == "int"
    op = { 1 => "storeb", 2 => "storeh", 4 => "storew" }[ty[1]]
    cls = "w"
  else
    raise Refused, "store of type #{tyrepr(ty)}"
  end
  raise Refused, "store class mismatch: value #{val.cls}, store #{cls}" if val.cls != cls
  if vol
    fn.emit("call $#{vhelper(fn.mod, op, cls)}(l #{addr.t}, #{cls} #{val.t})")
  else
    fn.emit("#{op} #{val.t}, #{addr.t}")
  end
end

# ---- bit-fields. (bfload T UNIT ADDR BOFF WIDTH) reads the UNIT-byte storage unit at ADDR and extracts WIDTH bits from
# bit BOFF (little-endian bit numbering); the result has type T (sign-extended when T is signed, else zero-extended).
# (bfstore T UNIT ADDR BOFF WIDTH VALUE) replaces those bits of the unit with the low WIDTH bits of VALUE and leaves
# the others alone. The unit is accessed whole (a read-modify-write for the store).
BF_LOAD = { 1 => "loadub", 2 => "loaduh", 4 => "loadw", 8 => "loadl" }
BF_STORE = { 1 => "storeb", 2 => "storeh", 4 => "storew", 8 => "storel" }

def bf_args(x, nargs)
  raise BadIR, "#{x[0]} form" if x.length != nargs
  unit = as_int(x[2])
  boff = as_int(x[4])
  width = as_int(x[5])
  raise BadIR, "#{x[0]}: unit #{unit}" unless BF_LOAD.key?(unit)
  raise BadIR, "#{x[0]}: bits #{boff}+#{width} outside a #{unit}-byte unit" if width < 1 || boff < 0 || boff + width > unit * 8
  [unit, boff, width]
end

def bf_mask(width, cls)
  wrap_int((1 << width) - 1, cls)
end

def r_bfload(fn, x)
  vol = x[0] == "bfload.v"
  unit, boff, width = bf_args(x, 6)
  ty = parse_type(x[1])
  raise Refused, "bit-field of type #{tyrepr(ty)}" if ty[0] != "int"
  addr = fn.opnd(x[3], "l")
  ucls = unit == 8 ? "l" : "w"
  ubits = unit == 8 ? 64 : 32
  t = fn.tmp
  if vol
    # a volatile bit-field: the whole unit is read once, through the volatile helper (see vhelper)
    fn.emit("#{t} =#{ucls} call $#{vhelper(fn.mod, BF_LOAD[unit], ucls)}(l #{addr.t})")
  else
    fn.emit("#{t} =#{ucls} #{BF_LOAD[unit]} #{addr.t}")
  end
  # Extraction is a shift pair (to the top of the register, then back down), never an `and` with a low mask: QBE's
  # width analysis (copy.c, "redundant and mask") drops such an `and` wrongly when the value comes round a loop through
  # memory (a phi it has visited and failed on is taken as narrow), which a do { } while (0) in a macro is enough
  # to produce. Shifts are never removed that way.
  if ubits - boff - width > 0
    t2 = fn.tmp
    fn.emit("#{t2} =#{ucls} shl #{t}, #{ubits - boff - width}")
    t = t2
  end
  if ubits - width > 0
    t2 = fn.tmp
    fn.emit("#{t2} =#{ucls} #{int_is_signed(ty) && !ty[3] ? "sar" : "shr"} #{t}, #{ubits - width}")
    t = t2
  end
  tcls = qcls(ty)
  if tcls != ucls
    t2 = fn.tmp
    if tcls == "l"
      fn.emit("#{t2} =l #{int_is_signed(ty) && !ty[3] ? "extsw" : "extuw"} #{t}")
    else
      fn.emit("#{t2} =w copy #{t}")
    end
    t = t2
  end
  Val.new(t, tcls, ty)
end

def s_bfstore(fn, x)
  vol = x[0] == "bfstore.v"
  unit, boff, width = bf_args(x, 7)
  ty = parse_type(x[1])
  raise Refused, "bit-field of type #{tyrepr(ty)}" if ty[0] != "int"
  addr = fn.opnd(x[3], "l")
  val = fn.opnd(x[6])
  ucls = unit == 8 ? "l" : "w"
  ubits = unit == 8 ? 64 : 32
  raise Refused, "bit-field store of a value of class #{val.cls}" if val.cls != qcls(ty)
  v = val.t
  if val.cls != ucls
    t2 = fn.tmp
    fn.emit(ucls == "l" ? "#{t2} =l extuw #{v}" : "#{t2} =w copy #{v}")
    v = t2
  end
  old = fn.tmp
  if vol
    fn.emit("#{old} =#{ucls} call $#{vhelper(fn.mod, BF_LOAD[unit], ucls)}(l #{addr.t})")
  else
    fn.emit("#{old} =#{ucls} #{BF_LOAD[unit]} #{addr.t}")
  end
  # The value's low WIDTH bits, moved to bit BOFF: a shift pair again (see r_bfload), no `and` with a low mask.
  if width < ubits
    t2 = fn.tmp
    fn.emit("#{t2} =#{ucls} shl #{v}, #{ubits - width}")
    v = t2
    if ubits - width - boff > 0
      t2 = fn.tmp
      fn.emit("#{t2} =#{ucls} shr #{v}, #{ubits - width - boff}")
      v = t2
    end
  end
  # (no ~ here: mruby's bigint gets the complement of a negative number wrong)
  clear = ((1 << ubits) - 1) ^ (((1 << width) - 1) << boff)
  nw = v
  if clear != 0
    keep = fn.tmp
    if boff + width == ubits
      # the field is the top of the unit, so the bits to keep are a low mask: shifts again
      fn.emit("#{keep} =#{ucls} shl #{old}, #{ubits - boff}")
      k2 = fn.tmp
      fn.emit("#{k2} =#{ucls} shr #{keep}, #{ubits - boff}")
      keep = k2
    else
      fn.emit("#{keep} =#{ucls} and #{old}, #{wrap_int(clear, ucls)}")
    end
    nw = fn.tmp
    fn.emit("#{nw} =#{ucls} or #{keep}, #{v}")
  end
  if vol
    fn.emit("call $#{vhelper(fn.mod, BF_STORE[unit], ucls)}(l #{addr.t}, #{ucls} #{nw})")
  else
    fn.emit("#{BF_STORE[unit]} #{nw}, #{addr.t}")
  end
end

# (vlaalloc $"slot" SIZE): the storage of a variable-length array. The slot receives the address of SIZE bytes of
# dynamic stack (QBE: alloc16 outside @start, released when the function returns). QBE cannot give the space back
# at the end of a block, so each statement keeps its capacity in a hidden slot (zero at function entry): the
# storage is allocated again only when SIZE exceeds it, and then for max(SIZE, 2 * capacity) bytes. Executing the
# statement again (a loop body, a backward goto) ends the previous array's lifetime, so its storage is reused, and
# the stack a function uses stays within a constant factor of its largest array.
def s_vlaalloc(fn, x)
  raise BadIR, "vlaalloc form" if x.length != 3
  slot = fn.opnd(x[1], "l")
  sz = fn.opnd(x[2])
  raise Refused, "vlaalloc size of type #{tyrepr(sz.ty)}" if sz.ty.nil? || sz.ty[0] != "int"
  size = sz.t
  if sz.cls != "l"
    size = fn.tmp
    fn.emit("#{size} =l extuw #{sz.t}")
  end
  capq = "%vc#{fn.nvla}"
  fn.nvla += 1
  fn.allocs << "\t#{capq} =l alloc8 8"
  fn.inits << "\tstorel 0, #{capq}"
  cap = fn.tmp
  fn.emit("#{cap} =l loadl #{capq}")
  need = fn.tmp
  fn.emit("#{need} =w cultl #{cap}, #{size}")
  grow = fn.newlab
  fix = fn.newlab
  alloc = fn.newlab
  done = fn.newlab
  fn.jnz(need, grow, done)
  fn.label(grow)
  dbl = fn.tmp
  fn.emit("#{dbl} =l add #{cap}, #{cap}")
  fn.emit("storel #{dbl}, #{capq}")
  lt = fn.tmp
  fn.emit("#{lt} =w cultl #{dbl}, #{size}")
  fn.jnz(lt, fix, alloc)
  fn.label(fix)
  fn.emit("storel #{size}, #{capq}")
  fn.label(alloc)
  n = fn.tmp
  fn.emit("#{n} =l loadl #{capq}")
  p = fn.tmp
  fn.emit("#{p} =l alloc16 #{n}")
  fn.emit("storel #{p}, #{slot.t}")
  fn.label(done)
end

def s_copy(fn, x)
  n = as_int(x[1])
  dst = fn.opnd(x[2], "l")
  src = fn.opnd(x[3], "l")
  return if n == 0
  fn.emit("call $memmove(l #{dst.t}, l #{src.t}, l #{n})")
end

# (zero-fill BYTES DST): clear an aggregate object (the part of a constant initializer that names no element).
def s_zero_fill(fn, x)
  n = as_int(x[1])
  dst = fn.opnd(x[2], "l")
  return if n == 0
  fn.emit("call $memset(l #{dst.t}, w 0, l #{n})")
end

def s_eval(fn, x)
  e = x[1]
  if head_of(e) == "call"
    r_call(fn, e)
    return
  end
  fn.rval(e)
end

def s_bounds(fn, x)
  idx = fn.opnd(x[1])
  n = as_int(x[2])
  raise Refused, "bounds on a non-integer index" if idx.ty.nil? || idx.ty[0] != "int"
  cls = idx.cls
  c = fn.tmp
  fn.emit("#{c} =w cult#{cls} #{idx.t}, #{wrap_int(n, cls)}")
  fn.trap_unless(c)
end

def s_nonnull(fn, x)
  p = fn.opnd(x[1], "l")
  return if p.t.start_with?("$")  # the address of an object or a function
  if p.t == "0"
    fn.jmp(fn.abort_label)
    return
  end
  c = fn.tmp
  fn.emit("#{c} =w cnel #{p.t}, 0")
  fn.trap_unless(c)
end

def s_if(fn, x)
  c = fn.opnd(x[1], "w")
  then_ = nil
  els = nil
  x.drop(2).each do |part|
    h = head_of(part)
    if h == "then"
      then_ = part.drop(1)
    elsif h == "else"
      els = part.drop(1)
    else
      raise BadIR, "if arm expected, got #{form_text(part)}"
    end
  end
  raise BadIR, "if without then" if then_.nil?
  lt = fn.newlab
  le = els.nil? ? nil : fn.newlab
  lend = fn.newlab
  fn.jnz(c.t, lt, le.nil? ? lend : le)
  fn.label(lt)
  fn.stmts(then_)
  fn.jmp(lend)
  unless els.nil?
    fn.label(le)
    fn.stmts(els)
    fn.jmp(lend)
  end
  fn.label(lend)
end

def s_loop(fn, x)
  body = nil
  step = nil
  x.drop(1).each do |part|
    h = head_of(part)
    if h == "body"
      body = part.drop(1)
    elsif h == "step"
      step = part.drop(1)
    else
      raise BadIR, "loop part expected, got #{form_text(part)}"
    end
  end
  raise BadIR, "loop without body or step" if body.nil? || step.nil?
  head = fn.newlab
  lstep = fn.newlab
  lexit = fn.newlab
  fn.label(head)
  fn.breaks << lexit  # a do-while test in step may break too, so the target covers body and step
  fn.conts << lstep
  fn.stmts(body)
  fn.conts.pop  # (continue) is not allowed in step
  fn.label(lstep)
  fn.stmts(step)
  fn.breaks.pop
  fn.jmp(head)
  fn.label(lexit)
end

# Case and default markers in the switch body, in order. Markers may sit in nested blocks only.
def switch_markers(xs, out)
  xs.each do |s|
    h = head_of(s)
    if h == "block"
      switch_markers(s.drop(1), out)
    elsif h == "case" || h == "default"
      out << s
    end
  end
  out
end

def s_switch(fn, x)
  v = fn.opnd(x[1])
  raise Refused, "switch on a non-integer value" if v.cls != "w" && v.cls != "l"
  raise BadIR, "switch form" if x.length != 3 || head_of(x[2]) != "body"
  markers = switch_markers(x[2].drop(1), [])
  lexit = fn.newlab
  ldefault = nil
  cases = []
  seen = {}
  markers.each do |m|
    lab = fn.newlab
    fn.case_labels[m.object_id] = lab
    if head_of(m) == "default"
      raise BadIR, "two default labels" unless ldefault.nil?
      ldefault = lab
    else
      cv = fn.const(m[1])
      key = cv.t.to_i
      raise BadIR, "duplicate case value #{key}" if seen.key?(key)
      seen[key] = true
      cases << [cv, lab]
    end
  end
  # Dispatch: one compare per case, in order; then the default (or the exit).
  cases.each do |cv, lab|
    c = fn.tmp
    fn.emit("#{c} =w ceq#{v.cls} #{v.t}, #{cv.t}")
    nxt = fn.newlab
    fn.jnz(c, lab, nxt)
    fn.label(nxt)
  end
  fn.jmp(ldefault.nil? ? lexit : ldefault)
  fn.breaks << lexit
  fn.stmts(x[2].drop(1))
  fn.breaks.pop
  fn.label(lexit)
end

def s_case(fn, x)
  lab = fn.case_labels[x.object_id]
  raise Refused, "case marker outside a switch body" if lab.nil?
  fn.label(lab)
end

def s_default(fn, x)
  lab = fn.case_labels[x.object_id]
  raise Refused, "default marker outside a switch body" if lab.nil?
  fn.label(lab)
end

def s_break(fn, x)
  raise BadIR, "break outside a loop or switch" if fn.breaks.empty?
  fn.jmp(fn.breaks[-1])
end

def s_continue(fn, x)
  raise BadIR, "continue outside a loop body" if fn.conts.empty?
  fn.jmp(fn.conts[-1])
end

def s_goto(fn, x)
  fn.jmp(fn.lab_for(pstr(x[1])))
end

def s_label(fn, x)
  fn.label(fn.lab_for(pstr(x[1])))
end

def s_return(fn, x)
  if fn.ret_ty == VOID
    raise BadIR, "return with a value in a void function" if x.length != 1
    fn.ret
    return
  end
  raise Refused, "return without a value in a non-void function" if x.length != 2
  v = fn.opnd(x[1], qcls(fn.ret_ty))
  fn.ret(v.t)
end

def s_unreachable(fn, x)
  fn.jmp(fn.abort_label)
end

STMT = {
  "block" => ->(fn, x) { s_block(fn, x) }, "let" => ->(fn, x) { s_let(fn, x) },
  "set" => ->(fn, x) { s_set(fn, x) },
  "store" => ->(fn, x) { s_store(fn, x) }, "store.v" => ->(fn, x) { s_store(fn, x) },
  "bfstore" => ->(fn, x) { s_bfstore(fn, x) }, "bfstore.v" => ->(fn, x) { s_bfstore(fn, x) },
  "vlaalloc" => ->(fn, x) { s_vlaalloc(fn, x) },
  "copy" => ->(fn, x) { s_copy(fn, x) }, "zero-fill" => ->(fn, x) { s_zero_fill(fn, x) }, "eval" => ->(fn, x) { s_eval(fn, x) },
  "bounds" => ->(fn, x) { s_bounds(fn, x) }, "nonnull" => ->(fn, x) { s_nonnull(fn, x) },
  "if" => ->(fn, x) { s_if(fn, x) }, "loop" => ->(fn, x) { s_loop(fn, x) },
  "switch" => ->(fn, x) { s_switch(fn, x) },
  "case" => ->(fn, x) { s_case(fn, x) }, "default" => ->(fn, x) { s_default(fn, x) },
  "break" => ->(fn, x) { s_break(fn, x) }, "continue" => ->(fn, x) { s_continue(fn, x) },
  "goto" => ->(fn, x) { s_goto(fn, x) }, "label" => ->(fn, x) { s_label(fn, x) },
  "return" => ->(fn, x) { s_return(fn, x) }, "unreachable" => ->(fn, x) { s_unreachable(fn, x) },
}

# ------------------------------------------------------------------ module and functions

# Items of a static initializer, as QBE data items; gaps are zero bytes. items: [offset, bytes, text, seq] rows.
def emit_data_items(mod, name, size, items)
  pieces = []
  pos = 0
  # sorted by offset; the sequence number keeps the order of equal offsets (Python's sort is stable)
  (0...items.length).to_a.sort_by { |i| [items[i][0], i] }.each do |i|
    it = items[i]
    off = it[0]
    nbytes = it[1]
    text = it[2]
    raise BadIR, "initializer items overlap at offset #{off} in #{name}" if off < pos
    pieces << "z #{off - pos}" if off > pos
    pieces << text
    pos = off + nbytes
  end
  raise BadIR, "initializer of #{name} runs past its size" if pos > size
  pieces << "z #{size - pos}" if size > pos
  pieces.empty? ? ["z 0"] : pieces
end

# A scalar item of IR type ty with the value text val_text. Returns [bytes, QBE data item].
def item_scalar(val_text, ty)
  if ty[0] == "float"
    cls, lit = data_float(py_float(pstr(val_text)), ty[1])
    return [ty[1], "#{cls} #{lit}"]
  end
  if ty[0] == "int" || ty[0] == "ptr" || ty[0] == "fn"
    size = ty_size(ty)
    v = wrap_int(as_int(val_text), size <= 4 ? "w" : "l")
    letter = { 1 => "b", 2 => "h", 4 => "w", 8 => "l" }[size]
    return [size, "#{letter} #{v}"]
  end
  raise Refused, "scalar item of type #{tyrepr(ty)}"
end

# Translate (init ITEM*) into [offset, bytes, text] triples.
def global_items(mod, name, items_form)
  out = []
  bits = {}   # byte offset -> value: the bits that (bitfield OFF UNIT BOFF WIDTH TYPE (const TYPE V)) items put in that byte
  items_form.drop(1).each do |it|
    h = head_of(it)
    if h == "bitfield"
      raise BadIR, "bitfield item form" if it.length != 7
      off = as_int(it[1])
      unit = as_int(it[2])
      boff = as_int(it[3])
      width = as_int(it[4])
      val = it[6]
      raise BadIR, "bitfield item: unit #{unit}" unless BF_LOAD.key?(unit)
      raise BadIR, "bitfield item: bits #{boff}+#{width} outside a #{unit}-byte unit" if width < 1 || boff < 0 || boff + width > unit * 8
      raise Refused, "bitfield item operand #{form_text(val)}" if head_of(val) != "const"
      # Fields are placed by absolute bit position; storage units of different fields may overlap, so the bits are
      # collected per byte (a bit-field never shares a byte with another kind of member).
      v = as_int(val[2]) & ((1 << width) - 1)
      width.times do |i|
        pos = off * 8 + boff + i
        bits[pos / 8] = (bits[pos / 8] || 0) | (((v >> i) & 1) << (pos % 8))
      end
    elsif h == "scalar"
      off = as_int(it[1])
      ty = parse_type(it[2])
      val = it[3]
      if head_of(val) == "null"
        size = ty_size(ty)
        out << [off, size, "#{{ 8 => "l", 4 => "w", 2 => "h", 1 => "b" }[size]} 0"]
        next
      end
      raise Refused, "scalar item operand #{form_text(val)}" if head_of(val) != "const"
      size, text = item_scalar(val[2], ty)
      out << [off, size, text]
    elsif h == "addr"
      off = as_int(it[1])
      target = it[3]
      add = as_int(it[4])
      raise Refused, "address item target #{form_text(target)}" unless target.is_a?(IRSym)
      raise Refused, "address of the thread-local object #{target.name} in a static initializer" if target.sig == "@" && mod.thread.key?(target.name)
      sym = "$" + qsym(target.name)
      if add == 0
        text = "l #{sym}"
      elsif add > 0
        text = "l #{sym} + #{add}"
      else
        text = "l #{sym} - #{-add}"
      end
      out << [off, 8, text]
    elsif h == "bytes"
      off = as_int(it[1])
      n = as_int(it[2])
      src = it[3]
      if !src.is_a?(IRSym) || src.sig != "@" || !mod.strings.key?(src.name)
        raise Refused, "bytes item from #{form_text(src)}"
      end
      data = mod.strings[src.name]
      raise BadIR, "bytes item of #{n} bytes from a #{data.length}-byte string" if data.length != n
      data.each_with_index { |ch, i| out << [off + i, 1, "b #{ch}"] }
    elsif h == "zero"
      off = as_int(it[1])
      n = as_int(it[2])
      out << [off, n, "z #{n}"] if n != 0
    elsif h == "unsupported"
      raise Refused, form_text(it)
    else
      raise BadIR, "unknown initializer item #{form_text(it)}"
    end
  end
  bits.keys.sort.each { |off| out << [off, 1, "b #{bits[off]}"] }
  out
end

# QBE has no weak linkage. A COMDAT definition (IR marker (weak)) is exported, and a comment line in the IL names it;
# `pathb-qbe-emit.rb --append-weak IL ASM` turns those comments into `.weak` directives at the end of the assembly
# that QBE produced (the same trick as scripts/weak-symbols.rb, but driven by the IR instead of EDG's __weak__ text).
WEAK_MARK = "# pathb-weak "

def read_text(path)
  text = File.open(path, "rb") { |f| f.read }
  universal_newlines(text)
end

# Python's text mode: \r\n and a lone \r read as \n.
def universal_newlines(text)
  return text unless text.index("\r")
  text.split("\r\n", -1).join("\n").split("\r", -1).join("\n")
end

def append_weak(il_path, asm_path)
  names = []
  read_text(il_path).split("\n").each do |line|
    names << line.byteslice(WEAK_MARK.bytesize, line.bytesize - WEAK_MARK.bytesize).strip if line.start_with?(WEAK_MARK)
  end
  unless names.empty?
    File.open(asm_path, "a") do |f|
      f.write("\n" + names.map { |n| ".weak #{n}\n" }.join)
    end
  end
  0
end

def emit_global(mod, g)
  # (global "NAME" TYPE BYTES ALIGN [(static)] INIT)
  raise BadIR, "global form too short: #{form_text(g)}" if g.length < 6
  name = pstr(g[1])
  size = as_int(g[3])
  align = as_int(g[4])
  rest = g.drop(5)
  static = false
  weak = false
  if !rest.empty? && head_of(rest[0]) == "static"
    static = true
    rest = rest.drop(1)
  elsif !rest.empty? && head_of(rest[0]) == "weak"
    weak = true
    rest = rest.drop(1)
  end
  thread = false
  if !rest.empty? && head_of(rest[0]) == "thread"
    thread = true
    rest = rest.drop(1)
  end
  raise BadIR, "global #{name}: expected one INIT" if rest.length != 1
  init = rest[0]
  h = head_of(init)
  return if h == "extern"
  raise Refused, "global #{name}: #{form_text(init)}" if h == "unsupported"
  raise BadIR, "global #{name}: unknown INIT #{form_text(init)}" if h != "init"
  raise BadIR, "global #{name}: alignment #{align}" unless [1, 2, 4, 8, 16].include?(align)
  items = global_items(mod, name, init)
  pieces = emit_data_items(mod, name, size, items)
  linkage = (thread ? "thread " : "") + (static ? "" : "export ")
  mod.out << (WEAK_MARK + qsym(name)) if weak
  mod.out << "#{linkage}data $#{qsym(name)} = align #{align} { #{pieces.join(", ")} }"
end

def emit_string(mod, d)
  # (data "NAME" TYPE (string "..."))
  name = pstr(d[1])
  ty = parse_type(d[2])
  raise BadIR, "data #{name} is not an array" if ty[0] != "array"
  text = d[3]
  raise Refused, "data #{name}: #{form_text(text)}" if head_of(text) != "string"
  raw = text[1].is_a?(IRStr) ? text[1].codes : pstr(text[1]).bytes
  # The string is bytes; a wide string (wchar_t, char16_t, char32_t) is an array of 2 or 4 byte integers.
  total = ty[1] * (ty[2][0] == "int" ? ty[2][1] : 1)
  raise BadIR, "string data #{name} longer than its array" if raw.length > total
  raw = raw + [0] * (total - raw.length)
  mod.strings[name] = raw
  parts = raw.map { |c| "b #{c}" }
  if parts.empty?
    mod.out << "data $#{qsym(name)} = { z 0 }"
  else
    mod.out << "data $#{qsym(name)} = { #{parts.join(", ")} }"
  end
end

def emit_function(mod, f)
  # (function "NAME" (ret TYPE|void) (params PARAM*) [(static)] SLOT* STMT*)
  name = pstr(f[1])
  ret_form = f[2]
  raise BadIR, "function #{name}: no (ret ...)" if head_of(ret_form) != "ret"
  ret = parse_type(ret_form[1])
  raise BadIR, "function #{name} returns an aggregate; it must use sret" if is_agg(ret)
  params_form = f[3]
  raise BadIR, "function #{name}: no (params ...)" if head_of(params_form) != "params"
  fn = Fn.new(mod, name, ret)
  static = false
  weak = false
  startup = []
  qparams = []
  param_stores = []
  body_forms = []
  f.drop(4).each do |part|
    h = head_of(part)
    if h == "static"
      static = true
    elsif h == "weak"
      weak = true
    elsif h == "constructor" || h == "destructor"
      # (constructor [PRIO]) / (destructor [PRIO]): the function runs before main / at exit (an array entry)
      raise BadIR, "function #{name}: bad #{form_text(part)}" if part.length > 2
      prio = part.length == 2 ? as_int(part[1]) : 0
      raise BadIR, "function #{name}: bad priority in #{form_text(part)}" if prio < 0 || prio > 65535
      startup << [h == "constructor" ? ".init_array" : ".fini_array", prio, qsym(name)]
    elsif h == "slot"
      # (slot "NAME" TYPE BYTES ALIGN)
      if part.length != 5
        raise BadIR, "slot form in #{name} is not (slot NAME TYPE BYTES ALIGN); rebuild the harness"
      end
      sname = pstr(part[1])
      sty = parse_type(part[2])
      raise Refused, "variable-length array type" if sty[0] == "array" && sty[1].nil?
      ssize = as_int(part[3])
      salign = as_int(part[4])
      q = "%s#{fn.nslot}"
      fn.nslot += 1
      a = salign >= 16 ? 16 : salign >= 8 ? 8 : 4
      fn.allocs << "\t#{q} =l alloc#{a} #{[ssize, 1].max}"
      fn.slots[sname] = [q, sty]
    else
      body_forms << part
    end
  end
  # Parameters: each arrives in a QBE temporary %pI and is copied into its register slot.
  pi = 0
  params_form.drop(1).each do |p|
    h = head_of(p)
    if h == "sret"
      n = p[1].byteslice(1, p[1].bytesize - 1).to_i
      fn.declare_reg(n, ["ptr", nil])
      qparams << "l %p#{pi}"
      param_stores << ["l", pi, n]
    elsif h == "param"
      n = p[1].byteslice(1, p[1].bytesize - 1).to_i
      pty = p[3]
      if head_of(pty) == "byval"
        fn.declare_reg(n, ["ptr", nil])
        qparams << "l %p#{pi}"
        param_stores << ["l", pi, n]
      else
        ty = parse_type(pty)
        cls = qcls(ty)
        fn.declare_reg(n, ty)
        qparams << "#{cls} %p#{pi}"
        param_stores << [cls, pi, n]
      end
    elsif h == "ellipsis"
      qparams << "..."
    else
      raise Refused, "parameter form #{form_text(p)}"
    end
    pi += 1
  end
  # Parameter copies into their register slots, at the top of the start block.
  param_stores.each do |cls, idx, n|
    fn.put("#{MEM_STORE[cls]} %p#{idx}, %r#{n}")
  end
  fn.stmts(body_forms)
  unless fn.dead
    if ret == VOID
      fn.ret
    else
      fn.jmp(fn.abort_label)
    end
  end
  if fn.abort_used
    fn.body << "@abort"
    fn.put("call $abort()")
    fn.put("hlt")
  end
  rc = ret == VOID ? "" : qcls(ret) + " "
  linkage = static ? "" : "export "
  mod.out << (WEAK_MARK + qsym(name)) if weak
  mod.out << "#{linkage}function #{rc}$#{qsym(name)}(#{qparams.join(", ")}) {"
  mod.out << "@start"
  mod.out.concat(fn.allocs)
  mod.out.concat(fn.inits)
  if fn.returns_twice
    mod.out.concat(escape_slots(fn.allocs))
    mod.need_sink = true
  end
  mod.out.concat(fn.body)
  mod.out << "}"
  mod.out << ""
  startup.each { |s| mod.startup << s }
end

# The start-up and exit tables. A (constructor [PRIO]) function gets a pointer in .init_array, a (destructor [PRIO])
# one in .fini_array (the dynamic loader runs .fini_array backwards). A priority P goes to the section
# .init_array.PPPPP (five digits, as GCC names it): the linker sorts those by name, before the plain section. Every
# entry is its own object, in the order of the functions in the IR.
def emit_startup_tables(mod)
  mod.startup.each_with_index do |(sect, prio, sym), i|
    sect += format(".%05d", prio) if prio != 0
    mod.out << "section \"#{sect}\" \"aw\""
    mod.out << "data $pathb_startup#{i} = align 8 { l $#{sym} }"
  end
end

LP64 = { "short" => 2, "int" => 4, "long" => 8, "long_long" => 8, "pointer" => 8, "float" => 4, "double" => 8 }

# The emitter's scalar sizes are LP64's. The module header carries the target's: (layout (int 4) ...).
# A target with other sizes is refused, not emitted with wrong sizes. An IR without (layout ...) is older
# than this check and is taken as LP64.
def check_layout(header)
  header.drop(2).each do |part|
    next if head_of(part) != "layout"
    part.drop(1).each do |item|
      name = pstr(item[0])
      size = as_int(item[1])
      if LP64.key?(name) && LP64[name] != size
        raise Refused, "layout: #{name} is #{size} bytes, the emitter assumes LP64 (#{LP64[name]})"
      end
    end
  end
end

# Collect the names of the global symbols (@"name" and &"name") that the form x refers to.
def symbols(x, out)
  if x.is_a?(IRSym)
    out[x.name] = true if x.sig == "@" || x.sig == "&"
  elsif x.is_a?(Array)
    x.each { |y| symbols(y, out) }
  end
end

# A function or global that other translation units can see: not (static), not (weak), and a definition.
def is_linked(f)
  f.drop(2).each do |part|
    h = head_of(part)
    return false if h == "static" || h == "weak" || h == "extern"
  end
  true
end

# A function that runs without being called: (constructor) or (destructor). It stays whatever refers to it.
def startup_function?(f)
  head_of(f) == "function" && f.drop(2).any? { |p| h = head_of(p); h == "constructor" || h == "destructor" }
end

def global_extern?(f)
  head_of(f) == "global" && f.drop(2).any? { |p| head_of(p) == "extern" }
end

# Reachability. The IR carries every routine EDG marks as needed, including inline and template code that
# nothing reaches. Keep the external definitions (they are the translation unit's interface) and what they refer
# to, transitively. A (weak) or (static) definition that nothing reaches is dropped: another translation unit that
# needs a weak definition has its own copy. A declaration ((extern) global) that nothing reaches is dropped too (a
# hosted program's headers declare many objects of types this emitter refuses). String data always stays.
def prune(forms)
  defs = {}
  forms.drop(1).each do |f|
    h = head_of(f)
    defs[pstr(f[1])] = f if h == "function" || h == "global"
  end
  live = {}
  work = []
  defs.each do |name, f|
    next if head_of(f) == "global" && f.drop(2).any? { |p| head_of(p) == "extern" }  # a declaration emits nothing
    if is_linked(f) || startup_function?(f)
      live[name] = true
      work << name
    end
  end
  until work.empty?
    refs = {}
    symbols(defs[work.pop], refs)
    refs.each_key do |r|
      if defs.key?(r) && !live.key?(r)
        live[r] = true
        work << r
      end
    end
  end
  forms.drop(1).select do |f|
    h = head_of(f)
    (h != "function" && h != "global") || live.key?(pstr(f[1]))
  end
end

# The Itanium C++ ABI declares the thread_local initialization function `_ZTH<name>` of an `extern thread_local`
# variable as a weak reference: the wrapper `_ZTW<name>` calls it only when it exists (`if (&_ZTH<name>) _ZTH<name>()`).
# The IR has no weak declarations, so an undefined function with this prefix that the module refers to is taken as one.
def weak_refs(forms)
  defined = {}
  forms.drop(1).each { |f| defined[pstr(f[1])] = true if head_of(f) == "function" }
  refs = {}
  forms.drop(1).each { |f| symbols(f, refs) if head_of(f) == "function" }
  out = {}
  refs.keys.sort.each { |n| out[n] = true if n.start_with?("_ZTH") && !defined.key?(n) }
  out
end

def emit_module(text, do_prune = true)
  forms = parse_forms(tokenize(text))
  raise BadIR, "the input is not an (ir-module ...) IR text" if forms.empty? || head_of(forms[0]) != "ir-module"
  check_layout(forms[0])
  mod = Module_.new
  all_forms = forms
  forms = [forms[0]] + prune(forms) if do_prune
  mod.weakrefs = weak_refs(forms)
  all_forms.drop(1).each { |f| mod.funcs[pstr(f[1])] = true if head_of(f) == "function" }
  forms.drop(1).each do |f|   # the globals that stay: a dropped one (unreferenced) may have a type this emitter refuses
    next if head_of(f) != "global"
    mod.globals[pstr(f[1])] = parse_type(f[2])
    if f.drop(5).any? { |p| head_of(p) == "thread" }
      mod.thread[pstr(f[1])] = f.drop(5).any? { |p| head_of(p) == "extern" } ? "ext" : "def"
    end
  end
  # Strings first: a string data item may be referenced from a global initializer.
  forms.drop(1).each { |f| emit_string(mod, f) if head_of(f) == "data" }
  forms.drop(1).each { |f| emit_global(mod, f) if head_of(f) == "global" }
  forms.drop(1).each do |f|
    h = head_of(f)
    if h == "function"
      begin
        emit_function(mod, f)
      rescue Refused => e
        raise Refused, "#{e.message} [in #{pstr(f[1])}]"   # which function holds the unsupported node
      end
    elsif h != "global" && h != "data"
      raise Refused, "top-level form (#{h || "None"} ...)"
    end
  end
  emit_startup_tables(mod)
  mod.got.each { |name, cell| mod.out << "data $#{cell} = align 8 { l $#{qsym(name)} }" }
  mod.out << "data $#{SINK} = align 8 { z 8 }" if mod.need_sink
  mod.vhelpers.each_value { |lines| mod.out.concat(lines) }
  mod.weakrefs.each_key { |n| mod.out << (WEAK_MARK + qsym(n)) }
  "# QBE IL generated from the nfcxx Path B IR by scripts/pathb-qbe-emit.py\n" + mod.out.join("\n") + "\n"
end

def die(msg, code)
  $stderr.write(u8(msg))
  code
end

def main(argv)
  args = argv.dup
  if !args.empty? && args[0] == "--append-weak"
    return die("usage: pathb-qbe-emit.py --append-weak IL.ssa ASM.s\n", 1) if args.length != 3
    return append_weak(args[1], args[2])
  end
  do_prune = true
  if !args.empty? && args[0] == "--no-prune"
    do_prune = false
    args = args.drop(1)
  end
  if args.length > 1
    return die("usage: pathb-qbe-emit.py [--no-prune] [FILE.ir | -]  |  --append-weak IL.ssa ASM.s\n", 1)
  end
  if args.empty? || args[0] == "-"
    src = universal_newlines($stdin.read)
  else
    src = read_text(args[0])
  end
  begin
    out = emit_module(src, do_prune)
  rescue Refused => e
    return die("refused: #{e.message}\n", 3)
  rescue BadIR => e
    return die("error: #{e.message}\n", 1)
  end
  $stdout.write(out)
  0
end

rc = main(ARGV)
exit(rc) if rc != 0
