# Rewrite EDG's preprocessed C so cproc accepts it, and emit the assembly the C cannot express.
#
# cproc (the QBE front end) rejects a few GNU forms that EDG emits. This script tokenizes the
# preprocessed C and rewrites only those forms; everything else passes through unchanged:
#
#   * `__asm__ volatile("int $3\n" : :);` (doctest's DOCTEST_BREAK_INTO_DEBUGGER, a statement with
#     no operands) becomes a call to `__nfcxx_int3()`. The assembly tail defines it as a weak
#     `int3; ret` stub, so the trap is the same and the program resumes after it. Any other inline asm
#     is left in place, and cproc rejects it.
#   * Builtins cproc does not know, which doctest uses. `__builtin_memcpy`, `memmove`, `memset`, `memcmp` and
#     `strlen` are renamed to the libc functions, with prototypes in the prelude. `__builtin_clzl` becomes a small
#     helper (`__nfcxx_clzl`), defined in the prelude.
#     `__builtin_mul_overflow(x, C, &x)` with an unsigned long decimal constant C (the only shape doctest
#     uses; `(&x)` also accepted) becomes `__nfcxx_mulov_ul`, a checked multiply with the same result.
#     Other uses of these builtins, and every other builtin, are left alone, so cproc rejects them.
#   * `__builtin_{add,sub,mul}_overflow(a, b, &r)` in general (mruby's numeric.h and time gem), when `a`, `b`
#     and `*r` all have the same type among int, unsigned, long, unsigned long, long long, unsigned long long
#     (a literal is an int or long like any other operand): nested `_Generic`s pick a small
#     helper function (`__nfcxx_addov_l`, ...) that computes the wrapped result and the overflow flag. Any other
#     mix of integer types (and literals, and char/short operands or results) goes through `__nfcxx_ovx`, which
#     computes the exact result in sign and 128-bit magnitude as GCC does and reports whether `*r` can hold it.
#     A non-integer operand or result selects `__nfcxx_overflow_unsupported_operand_types`, declared and never
#     defined: a link error naming that symbol, never a silently converted operand.
#   * `(double)1.5e308L` / `(float)...L` (hand-written C): glibc's <float.h> spells DBL_MIN, DBL_MAX and DBL_EPSILON
#     this way (`((double)2.2250738585072014e-308L)`). cproc types the literal as long double and emits an invalid
#     QBE `truncd` for the cast. The `L` is dropped when the literal is directly cast to double or float, which
#     rounds the same decimal to the target format. A long double literal anywhere else is left alone.
#   * `alloca(n)` (hand-written C only; glibc's <alloca.h> declares a function when `__GNUC__` is unset, and libc
#     has no such symbol) becomes cproc's `__builtin_alloca(n)`. A declaration (`... *alloca(...)`) is left alone.
#   * `__builtin_fabs`, `__builtin_fabsf` (libcu++ and the CUDA headers) and the other libm builtins that libstdc++ <cmath>
#     wrappers call (`__builtin_sqrtf`, `__builtin_powf`, ... see LIBC_BUILTINS) become the libm functions, with
#     prototypes. `fabsl` is not mapped: cproc has no `long double`.
#   * `__builtin_popcount{,l,ll}`, `__builtin_ctz{,l,ll}`, `__builtin_clz{,ll}` become helper functions
#     (like `__builtin_clzl` above). For a zero argument ctz and clz return the width; GCC leaves that undefined.
#   * GCC 14's type-generic `__builtin_{clz,ctz,popcount,parity}g(x[, d])` become `__nfcxx_*g` calls with x zero-extended,
#     the width of x (sizeof) and d, so one helper serves every unsigned type. With one argument a zero input gives the
#     width (as above); with two it gives d. Only the call shape is rewritten (see G_OPS).
#   * Sized atomics `__atomic_{load,store,exchange,compare_exchange,fetch_OP,OP_fetch}_{1,2,4,8}` (what
#     libstdc++'s std::atomic calls) get prototypes for the libatomic functions of the same name. The QBE
#     link adds -latomic (scripts/qbe-cc). The 16-byte forms are left alone; they need __int128.
#   * A bare `return;` in a function whose return type is not void (EDG's cleanup code after a call to exit, which
#     never runs; cproc: "expected primary expression"). It becomes `return (T){};`, a zero value of the return type.
#     The void types are the names of `typedef void` (bare_return_edits, void_typedefs).
#   * `__asm__(".align 2");` alignment hints (anywhere): dropped, as the old sed did. The hint
#     only matters to EDG's own output, and it is not a semantic change.
#   * Top-level `__asm__("...")` statements (not declarator labels) are removed from the C and
#     re-emitted in the assembly tail: `.global X` / `.globl X` become `.globl X`, and `X = Y`
#     becomes `.set X, Y`. EDG uses these for thread_local initialization aliases
#     (`_ZTHx = __tls_init`). A `_ZTHx` alias is marked `.weak` when its `_ZTWx` wrapper is weak
#     (COMDAT), as gcc does.
#   * `__attribute__((__constructor__))` on a function declaration (EDG's static initializers, `__sti_*`)
#     is removed from the C, and the function is listed in `.init_array` in the assembly tail, so the
#     C runtime runs it before main. Only the plain form is handled; a priority argument is left alone.
#   * `__attribute__((__aligned__(N)))` after an array declarator (`T x[40] __attribute__(...)`)
#     becomes `_Alignas(N)` just before the declared name (cproc takes the GNU attribute there only on struct members, not on objects). Same alignment.
#   * `struct T {...;} __attribute__((__aligned__(N)))` (std::aligned_storage, `struct alignas(N) T`) becomes
#     `struct T {_Alignas(N) ...;}` on the first member (not a bit-field): same alignment, same rounded-up size.
#   * Floating types cproc lacks: `__bf16` and `_Float128` (16 bytes) become structs with the same size
#     and alignment and no arithmetic, so a real use of the value is a compile error rather than a silent
#     mis-typed float. `_Float16` is passed through: cproc has it (qbe.c, f16binary). `_Float32` and
#     `_Float64` are IEEE binary32 and binary64, the same formats as `float` and `double` on x86-64, so they
#     map to those. libstdc++'s std::numbers variables (pulled in by <map>) use all of them. Their literals
#     (`2.71875f16`) are rewritten to the binary16 value, as a cast of an exact hex float, or to a plain
#     `float`/`double` literal (`f32`, `f64`); `f128` to the bit pattern.
#   * `volatile` is dropped everywhere (cproc errors on any store to a volatile object; it already emits
#     volatile loads as plain loads; a volatile block-scope local gets `__nfcxx_keep(&x);` after its
#     declaration so QBE keeps it in memory across setjmp/longjmp). The stores that remain are plain, in
#     program order, on x86-64 (TSO): the same code gcc emits for a volatile store there, which is what CoreCLR's
#     GC needs (src/coreclr/gc/env/volatile.h). Not for other targets: a plain store has no release ordering on
#     arm64, and the fence stub below is x86 mfence. Hand-written C (--c-input) gets the same rule.
#   * Hand-written C (--c-input; glibc headers and user code): `typedef T _Float32;`-style typedefs of the
#     floating types above are removed (the names are mapped instead), as glibc's <bits/floatn.h> declares them.
#   * GCC's `__sync_{add,sub,and,or,xor}_and_fetch_{4,8}` and `__sync_val_compare_and_swap_{4,8}` (the Interlocked
#     operations of CoreCLR's gcenv.interlocked.inl) become helpers over cproc's `__atomic_fetch_OP` and
#     `__atomic_compare_exchange_n`, seq_cst, with GCC's results. `__builtin_prefetch` and `__builtin_ia32_pause`
#     are hints and become empty helpers; `__builtin_ffs` a small helper.
#
# Usage: scripts/mrb scripts/qbe-prep.rb [--c-input] PREPROCESSED_C REWRITTEN_C ASM_TAIL
# ASM_TAIL is appended to the QBE assembly by qbe-cc.
#
# Port of the Python original (tests/mruby/oracle/qbe-prep.py), byte for byte (tests/mruby/qbe-prep.sh).
# mruby has no Regexp (and strings are bytes), so the tokenizer and the few regex checks are by hand.
# Where Python's `\w`/`\s`/`\d` would match non-ASCII characters this accepts the bytes >= 0x80 as word
# characters and nothing else non-ASCII (EDG's output and glibc's headers are ASCII outside literals).

# ---- character classes (by byte value) ----------------------------------------------------------------

def class_table
  t = Array.new(256, false)
  yield t
  t
end

SPACE_B = class_table { |t| [9, 10, 11, 12, 13, 28, 29, 30, 31, 32].each { |b| t[b] = true } }  # Python's \s
WORD_B = class_table do |t|
  (48..57).each { |b| t[b] = true }
  (65..90).each { |b| t[b] = true }
  (97..122).each { |b| t[b] = true }
  t[95] = true
  (128..255).each { |b| t[b] = true }
end
IDSTART_B = class_table do |t|
  (65..90).each { |b| t[b] = true }
  (97..122).each { |b| t[b] = true }
  t[95] = true
  t[36] = true  # $
end
# Identifier characters after the first: the word characters and `$` (cproc accepts `$` in identifiers, and mrustc's
# mangled names use it, see scripts/mrustc-prep.rb).
IDCONT_B = class_table { |t| (0...256).each { |b| t[b] = true if WORD_B[b] }; t[36] = true }

def digit_b?(b)
  !b.nil? && b >= 48 && b <= 57
end

def all_digits?(s, from = 0, to = s.bytesize)
  return false if from >= to
  k = from
  while k < to
    return false unless digit_b?(s.getbyte(k))
    k += 1
  end
  true
end

# Python's str.strip() on the bytes of an ASCII string.
def py_strip(s)
  a = 0
  b = s.bytesize
  a += 1 while a < b && SPACE_B[s.getbyte(a)]
  b -= 1 while b > a && SPACE_B[s.getbyte(b - 1)]
  s.byteslice(a, b - a)
end

def die(msg)
  $stderr.puts msg
  exit 1
end

# ---- tables ---------------------------------------------------------------------------------------

FLOAT_TYPE = {
  '_Float32' => 'float',
  '_Float64' => 'double',
  '__bf16' => 'struct __nfcxx_half16',
  '_Float128' => 'struct __nfcxx_float128',
}
DROP_TYPEDEF = FLOAT_TYPE.keys + ['_Float32x', '_Float64x', '_Float128x']
FLOAT_DECL = {
  'struct __nfcxx_half16' => 'struct __nfcxx_half16 { unsigned short bits; };',
  'struct __nfcxx_float128' => 'struct __nfcxx_float128 { _Alignas(16) unsigned long bits[2]; };',
}
FLOAT_SUFFIXES = ['f16', 'f32', 'f64', 'f128']

# Python: FLOAT_LIT.fullmatch(text) with r'(\.?\d[\d.]*(?:[eE][+-]?\d+)?)(f16|f32|f64|f128)'.
# Returns [body, suffix] or nil.
def float_lit(text)
  suffix = FLOAT_SUFFIXES.find { |s| text.end_with?(s) }
  return nil if suffix.nil?
  n = text.bytesize - suffix.bytesize
  k = 0
  k += 1 if text.getbyte(0) == 46
  return nil unless k < n && digit_b?(text.getbyte(k))
  k += 1
  while k < n
    b = text.getbyte(k)
    break unless digit_b?(b) || b == 46
    k += 1
  end
  if k < n
    b = text.getbyte(k)
    return nil unless b == 101 || b == 69  # e E
    k += 1
    b = text.getbyte(k)
    k += 1 if b == 43 || b == 45
    return nil unless k < n && all_digits?(text, k, n)
  end
  [text.byteslice(0, n), suffix]
end

# Decimal literal text (as Fraction accepts it, without sign) -> [integer, exponent10]; value = int * 10**exp.
def parse_decimal(lit)
  n = lit.bytesize
  k = 0
  intpart = k
  k += 1 while k < n && digit_b?(lit.getbyte(k))
  digits = lit.byteslice(intpart, k - intpart)
  frac = ''
  if k < n && lit.getbyte(k) == 46
    k += 1
    f0 = k
    k += 1 while k < n && digit_b?(lit.getbyte(k))
    frac = lit.byteslice(f0, k - f0)
  end
  exp = 0
  if k < n && (lit.getbyte(k) == 101 || lit.getbyte(k) == 69)
    k += 1
    sign = 1
    if k < n && (lit.getbyte(k) == 43 || lit.getbyte(k) == 45)
      sign = -1 if lit.getbyte(k) == 45
      k += 1
    end
    e0 = k
    k += 1 while k < n && digit_b?(lit.getbyte(k))
    die "qbe-prep: invalid literal #{lit}" if k == e0
    exp = sign * lit.byteslice(e0, k - e0).to_i
  end
  die "qbe-prep: invalid literal #{lit}" if k != n || (digits.empty? && frac.empty?)
  [(digits + frac).to_i, exp - frac.bytesize]
end

def pow2_gt?(e, num, den)  # 2**e > num/den
  e >= 0 ? (den << e) > num : den > (num << -e)
end

def hex_pad(v, width)
  s = v.to_s(16)
  s = '0' * (width - s.bytesize) + s if s.bytesize < width
  s
end

# Bit pattern of the decimal literal LIT in an IEEE binary format (round to nearest even), computed exactly
# on integers (the Python original uses fractions.Fraction).
def ieee_bits(lit, mant, ebits)
  digits, exp = parse_decimal(lit)
  bias = 2**(ebits - 1) - 1
  return 0 if digits == 0
  num = exp >= 0 ? digits * 10**exp : digits
  den = exp >= 0 ? 1 : 10**(-exp)
  e = num.bit_length - den.bit_length
  e -= 1 if pow2_gt?(e, num, den)
  e += 1 unless pow2_gt?(e + 1, num, den)
  # m = round(x / 2**(e - mant)), ties to even
  sh = mant - e
  n2 = sh >= 0 ? num << sh : num
  d2 = sh >= 0 ? den : den << -sh
  m, r = n2.divmod(d2)
  twice = r * 2
  m += 1 if twice > d2 || (twice == d2 && m.odd?)
  if m == 2**(mant + 1)
    m /= 2
    e += 1
  end
  if e < 1 - bias || e + bias >= 2**ebits - 1
    die "qbe-prep: literal #{lit} is out of range for this format (subnormal or overflow)"
  end
  ((e + bias) << mant) | (m - 2**mant)
end

# The value of a binary16 bit pattern as a C hexadecimal floating constant (exact): 1.f * 2^(e-15), or 0.f * 2^-14
# for a subnormal, with f the 10 fraction bits as three hex digits (the value of m << 2 over 16^3).
def half_literal(bits)
  e = (bits >> 10) & 31
  m = bits & 1023
  x = m << 2
  digits = '0123456789abcdef'
  frac = digits[x >> 8] + digits[(x >> 4) & 15] + digits[x & 15]
  frac = frac.chop while frac.end_with?('0')
  ex = e == 0 ? -14 : e - 15
  (bits >> 15 == 1 ? '-' : '') + '0x' + (e == 0 ? '0' : '1') + (frac.empty? ? '' : '.' + frac) +
    'p' + (ex < 0 ? '-' : '+') + ex.abs.to_s
end

# ---- tokens ---------------------------------------------------------------------------------------

# Token codes: a punctuation token is its byte value (0..255); the other kinds are these.
ID_CODE = 256
NUM_CODE = 257
STR_CODE = 258
CHR_CODE = 259

# One shared string per single-byte punct token.
PUNCT_S = (0..255).map { |b| b.chr }

# The tokens are three parallel Arrays of Integers, not an object per token: the 34 MB preprocessed sys_predef
# has about 9 million tokens, and the mruby GC marks every live object on each collection.
#   K[i]  code | (brace depth before token i + DEP_OFF) << 9 | (paren depth before it + DEP_OFF) << 31
#   P[i]  byte offset of token i in the source
#   L[i]  byte length of token i; for an identifier also the index of its name << SYM_SHIFT
# An identifier's text is names[sym], one string per distinct name, so comparing names allocates nothing.
DEP_OFF = 1 << 20
DEP_SHIFT = 9
PDEP_SHIFT = 31
LEN_MASK = (1 << 40) - 1
SYM_SHIFT = 40

class Toks
  attr_reader :src, :k, :p, :l, :names

  def initialize(src, k, p, l, names)
    @src = src
    @k = k
    @p = p
    @l = l
    @names = names
  end

  def size
    @k.size
  end

  # Code of token i, or -1 when i is out of range (the nil of the Python original).
  def code(i)
    i >= 0 && i < @k.size ? @k[i] & 511 : -1
  end

  def start(i)
    @p[i]
  end

  def stop(i)
    @p[i] + (@l[i] & LEN_MASK)
  end

  def sym(i)
    @l[i] >> SYM_SHIFT
  end

  def depth(i)
    ((@k[i] >> DEP_SHIFT) & ((1 << 22) - 1)) - DEP_OFF
  end

  def pdepth(i)
    (@k[i] >> PDEP_SHIFT) - DEP_OFF
  end

  def text(i)
    c = code(i)
    if c == ID_CODE
      @names[sym(i)]
    elsif c < 256
      PUNCT_S[c]
    else
      @src.byteslice(start(i), stop(i) - start(i))
    end
  end

  # Token i is the punctuation token whose one byte is s (a one-character string).
  def punct?(i, s)
    c = code(i)
    c >= 0 && c < 256 && PUNCT_S[c] == s
  end

  def id?(i, s)
    code(i) == ID_CODE && @names[sym(i)] == s
  end

  # The text of token i is s (any kind of token).
  def text?(i, s)
    code(i) >= 0 && text(i) == s
  end
end

# Scan a quoted literal whose opening quote is at q; returns the index just past
# the closing quote, or nil (the Python regexes: `(?:[^"\\\n]|\\.)*` with re.S, so a backslash takes any next character).
def scan_quoted(src, q, n)
  quote = src.getbyte(q)
  k = q + 1
  while k < n
    b = src.getbyte(k)
    if b == quote
      return k + 1
    elsif b == 92
      return nil if k + 1 >= n
      k += 2
    elsif b == 10
      return nil
    else
      k += 1
    end
  end
  nil
end

# The ordered alternation of the Python TOKEN_RE, tried at each position: whitespace, comments, string,
# char literal, number, identifier, any single character. Whitespace and comments are dropped.
def tokenize(src)
  ks = []
  ps = []
  ls = []
  names = []
  syms = {}
  n = src.bytesize
  i = 0
  braces = 0
  parens = 0
  while i < n
    c = src.getbyte(i)
    if SPACE_B[c]
      i += 1
      i += 1 while i < n && SPACE_B[src.getbyte(i)]
      next
    end
    c2 = src.getbyte(i + 1)
    # a line of the preprocessor (`# 12 "file"`, the markers of cc -E without -P): not C, skipped like a comment
    if c == 35 && (i == 0 || src.getbyte(i - 1) == 10)
      j = src.index("\n", i)
      i = j.nil? ? n : j
      next
    end
    if c == 47 && c2 == 47
      j = src.index("\n", i)
      i = j.nil? ? n : j
      next
    end
    if c == 47 && c2 == 42
      j = src.index('*/', i + 2)
      unless j.nil?
        i = j + 2
        next
      end
    end
    # string or char literal, with an optional u8/L/u/U prefix
    q = nil
    if c == 34 || c == 39
      q = i
    elsif c == 117 && c2 == 56 && src.getbyte(i + 2) == 34   # u8"
      q = i + 2
    elsif (c == 117 || c == 76 || c == 85) && (c2 == 34 || c2 == 39)   # u L U
      q = i + 1
    end
    unless q.nil?
      stop = scan_quoted(src, q, n)
      unless stop.nil?
        code = src.getbyte(q) == 34 ? STR_CODE : CHR_CODE
        ks << (code | ((braces + DEP_OFF) << DEP_SHIFT) | ((parens + DEP_OFF) << PDEP_SHIFT))
        ps << i
        ls << (stop - i)
        i = stop
        next
      end
    end
    if digit_b?(c) || (c == 46 && digit_b?(c2))
      j = c == 46 ? i + 2 : i + 1
      while j < n
        b = src.getbyte(j)
        if (b == 101 || b == 69 || b == 112 || b == 80) && (src.getbyte(j + 1) == 43 || src.getbyte(j + 1) == 45)
          j += 2
        elsif WORD_B[b] || b == 46
          j += 1
        else
          break
        end
      end
      ks << (NUM_CODE | ((braces + DEP_OFF) << DEP_SHIFT) | ((parens + DEP_OFF) << PDEP_SHIFT))
      ps << i
      ls << (j - i)
      i = j
      next
    end
    if IDSTART_B[c]
      j = i + 1
      j += 1 while j < n && IDCONT_B[src.getbyte(j)]
      name = src.byteslice(i, j - i)
      sym = syms[name]
      if sym.nil?
        sym = names.size
        names << name
        syms[name] = sym
      end
      ks << (ID_CODE | ((braces + DEP_OFF) << DEP_SHIFT) | ((parens + DEP_OFF) << PDEP_SHIFT))
      ps << i
      ls << ((j - i) | (sym << SYM_SHIFT))
      i = j
      next
    end
    ks << (c | ((braces + DEP_OFF) << DEP_SHIFT) | ((parens + DEP_OFF) << PDEP_SHIFT))
    ps << i
    ls << 1
    if c == 123
      braces += 1
    elsif c == 125
      braces -= 1
    elsif c == 40
      parens += 1
    elsif c == 41
      parens -= 1
    end
    i += 1
  end
  Toks.new(src, ks, ps, ls, names)
end

# Index of the token matching the close token at i, searching backwards.
def match_back(tk, i, open_s, close_s)
  level = 0
  j = i
  while j >= 0
    if tk.punct?(j, close_s)
      level += 1
    elsif tk.punct?(j, open_s)
      level -= 1
      return j if level == 0
    end
    j -= 1
  end
  -1
end

def match_fwd(tk, i, open_s, close_s)
  level = 0
  j = i
  while j < tk.size
    if tk.punct?(j, open_s)
      level += 1
    elsif tk.punct?(j, close_s)
      level -= 1
      return j if level == 0
    end
    j += 1
  end
  -1
end

# The statement starts at token i: nothing, or `;`, `{` or `}` before it.
def stmt_ctx?(tk, i)
  c = tk.code(i - 1)
  c == -1 || c == 59 || c == 123 || c == 125
end

# Python's int(text, 0): decimal, 0x, 0o, 0b, underscores between digits; anything else is a ValueError.
def py_int0(text)
  s = text
  base = 10
  if s.bytesize > 2 && s.getbyte(0) == 48
    case s.getbyte(1)
    when 120, 88 then base = 16
    when 111, 79 then base = 8
    when 98, 66 then base = 2
    end
    s = s.byteslice(2, s.bytesize - 2) if base != 10
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

# True if the struct body toks[o+1...close] starts with a member that is not a bit-field (a first member
# can carry _Alignas; a bit-field cannot). Python: first_member_plain.
def first_member_plain?(tk, o, close)
  return false if o + 1 >= close
  depth = 0
  k = o + 1
  while k < close
    c = tk.code(k)
    if c < 256
      case PUNCT_S[c]
      when '(', '[', '{' then depth += 1
      when ')', ']', '}' then depth -= 1
      when ':' then return false if depth == 0
      when ';' then return true if depth == 0
      end
    end
    k += 1
  end
  false
end

# `T x __attribute__((__aligned__(N)))` on a plain (non-array) object: toks[i] is the name, the attribute follows
# it and the declarator ends with `;`, `,` or `=`. Not a typedef, and not `struct T __attribute__...` (a tag).
# Python: plain_aligned_object.
def plain_aligned_object?(tk, i)
  return false unless tk.id?(i + 1, '__attribute__')
  g = aligned_group(tk, i + 1)
  return false if g.nil?
  f = g[0]
  return false unless tk.punct?(f, ';') || tk.punct?(f, ',') || tk.punct?(f, '=')
  return false if i == 0 || tk.code(i - 1) == -1 || tk.id?(i - 1, 'struct') || tk.id?(i - 1, 'union') ||
                  tk.id?(i - 1, 'enum')
  k = i - 1
  while k >= 0
    c = tk.code(k)
    break if c == 59 || c == 123 || c == 125   # ; { }
    return false if tk.id?(k, 'typedef')
    k -= 1
  end
  true
end

# If toks[i] starts __attribute__((__aligned__(N))), return [end_index_exclusive, N].
def aligned_group(tk, i)
  return nil if i + 8 >= tk.size || !tk.id?(i, '__attribute__')
  return nil unless tk.punct?(i + 1, '(') && tk.punct?(i + 2, '(') && tk.code(i + 3) == ID_CODE &&
                    (tk.text(i + 3) == '__aligned__' || tk.text(i + 3) == 'aligned') && tk.punct?(i + 4, '(') &&
                    tk.code(i + 5) == NUM_CODE && tk.punct?(i + 6, ')') && tk.punct?(i + 7, ')') &&
                    tk.punct?(i + 8, ')')
  [i + 9, py_int0(tk.text(i + 5))]
end

# unicode_escape decoding of the body of a string literal (what Python's decode_str does for ASCII text).
def hex_digits?(h)
  h.bytes.all? { |d| (d >= 48 && d <= 57) || (d >= 97 && d <= 102) || (d >= 65 && d <= 70) }
end

def decode_str(lit)
  body = lit.byteslice(lit.index('"') + 1, lit.bytesize - lit.index('"') - 2)
  out = ''
  n = body.bytesize
  k = 0
  while k < n
    b = body.getbyte(k)
    if b != 92
      out << b.chr
      k += 1
      next
    end
    k += 1
    die "UnicodeDecodeError: \\ at end of string" if k >= n
    e = body.getbyte(k)
    k += 1
    case e
    when 10 then nil
    when 92 then out << '\\'
    when 39 then out << "'"
    when 34 then out << '"'
    when 97 then out << "\a"
    when 98 then out << "\b"
    when 102 then out << "\f"
    when 110 then out << "\n"
    when 114 then out << "\r"
    when 116 then out << "\t"
    when 118 then out << "\v"
    when 48..55
      v = e - 48
      2.times do
        d = body.getbyte(k)
        break unless !d.nil? && d >= 48 && d <= 55
        v = v * 8 + (d - 48)
        k += 1
      end
      out << (v < 256 ? v.chr : [v].pack('U'))
    when 120, 117, 85   # \x \u \U
      w = e == 120 ? 2 : (e == 117 ? 4 : 8)
      h = body.byteslice(k, w)
      die "UnicodeDecodeError: truncated escape" unless h.bytesize == w && hex_digits?(h)
      v = h.to_i(16)
      k += w
      out << (e == 120 && v < 256 ? v.chr : [v].pack('U'))
    else
      out << '\\' << e.chr
    end
  end
  out
end

INT3_TEXT = ["int $3\n", 'int $3']
INT3_STUB = "\t.pushsection .text.__nfcxx_int3,\"ax\",@progbits\n" \
            "\t.weak __nfcxx_int3\n" \
            "\t.type __nfcxx_int3,@function\n" \
            "__nfcxx_int3:\n" \
            "\tint3\n" \
            "\tret\n" \
            "\t.popsection"

# __atomic_thread_fence / __atomic_signal_fence (libstdc++ shared_ptr, nlohmann::json): cproc has no fences, so the
# call goes to a weak stub with mfence, a full barrier on x86-64 whatever the memory order.
FENCE_STUB = "\t.pushsection .text.__nfcxx_fence,\"ax\",@progbits\n" \
             "\t.weak __nfcxx_fence\n" \
             "\t.type __nfcxx_fence,@function\n" \
             "__nfcxx_fence:\n" \
             "\tmfence\n" \
             "\tret\n" \
             "\t.popsection"

# builtin -> [libc function, prototype]; cproc has the builtin names but not the functions
LIBC_BUILTINS = {
  '__builtin_memcpy' => ['memcpy', 'void *memcpy(void *, const void *, unsigned long);'],
  '__builtin_memmove' => ['memmove', 'void *memmove(void *, const void *, unsigned long);'],
  '__builtin_memset' => ['memset', 'void *memset(void *, int, unsigned long);'],
  '__builtin_memcmp' => ['memcmp', 'int memcmp(const void *, const void *, unsigned long);'],
  '__builtin_memchr' => ['memchr', 'void *memchr(const void *, int, unsigned long);'],  # std::string::find
  '__builtin_strlen' => ['strlen', 'unsigned long strlen(const char *);'],
  '__builtin_ldexp' => ['ldexp', 'double ldexp(double, int);'],
  '__builtin_strcmp' => ['strcmp', 'int strcmp(const char *, const char *);'],  # JSON_HEDLEY / char_traits
  '__builtin_fabsf' => ['fabsf', 'float fabsf(float);'],  # libcu++ (<cuda/cmath>) and the CUDA headers
  '__builtin_fabs' => ['fabs', 'double fabs(double);'],
}
# libm functions behind the compiler builtins that libstdc++ <cmath> wrappers call (std::sqrt(float) and the like)
%w[sqrt exp log sin cos tan floor ceil trunc round exp2 log2 asin acos atan sinh cosh tanh log10].each do |n|
  LIBC_BUILTINS["__builtin_#{n}f"] = ["#{n}f", "float #{n}f(float);"]
  LIBC_BUILTINS["__builtin_#{n}"] = [n, "double #{n}(double);"]
end
%w[pow fmod atan2 copysign fmin fmax hypot].each do |n|
  LIBC_BUILTINS["__builtin_#{n}f"] = ["#{n}f", "float #{n}f(float, float);"]
  LIBC_BUILTINS["__builtin_#{n}"] = [n, "double #{n}(double, double);"]
end
# builtin -> [helper name, definition in the prelude]
HELPER_BUILTINS = {
  # nlohmann::json: float constants and conversions (double only; cproc has no long double anyway)
  '__builtin_huge_val' => ['__nfcxx_huge_val', 'static double __nfcxx_huge_val(void) { return __builtin_inff(); }'],
  '__builtin_nan' => ['__nfcxx_nan', 'static double __nfcxx_nan(const char *s) { return __builtin_nanf(""); }'],
  # __builtin_isinf and __builtin_isfinite are not rewritten: cproc lowers them for every float type (expr.c fpbuiltin)
  '__builtin_bswap16' => ['__nfcxx_bswap16',
                          'static unsigned short __nfcxx_bswap16(unsigned short x) { return (unsigned short)((x << 8) | (x >> 8)); }'],
  '__builtin_bswap32' => ['__nfcxx_bswap32',
                          'static unsigned int __nfcxx_bswap32(unsigned int x) {' \
                          ' return (x << 24) | ((x & 0xff00u) << 8) | ((x >> 8) & 0xff00u) | (x >> 24); }'],
  '__builtin_bswap64' => ['__nfcxx_bswap64',
                          'static unsigned long __nfcxx_bswap64(unsigned long x) {' \
                          ' unsigned long r = 0; int i; for (i = 0; i < 8; i++) { r = (r << 8) | (x & 0xff); x >>= 8; } return r; }'],
  '__builtin_signbit' => ['__nfcxx_signbit',
                          'static int __nfcxx_signbit(double x) {' \
                          ' union { double d; unsigned long u; } v; v.d = x; return (int)(v.u >> 63); }'],
  '__builtin_clzl' => ['__nfcxx_clzl',
                       'static int __nfcxx_clzl(unsigned long x) {' \
                       ' if (x == 0) return 64; int n = 0; while (!(x >> 63)) { x <<= 1; ++n; } return n; }'],
}

def add_bit_helpers
  [['', 'unsigned int', 32], ['l', 'unsigned long', 64], ['ll', 'unsigned long long', 64]].each do |suffix, t, bits|
    HELPER_BUILTINS['__builtin_popcount' + suffix] = [
      '__nfcxx_popcount' + suffix,
      "static int __nfcxx_popcount#{suffix}(#{t} x) { int n = 0; while (x) { x &= x - 1; ++n; } return n; }"]
    HELPER_BUILTINS['__builtin_ctz' + suffix] = [
      '__nfcxx_ctz' + suffix,
      "static int __nfcxx_ctz#{suffix}(#{t} x) { int n = 0; if (x == 0) return #{bits};" \
      ' while (!(x & 1)) { x >>= 1; ++n; } return n; }']
    if suffix != 'l'  # clzl is defined above
      HELPER_BUILTINS['__builtin_clz' + suffix] = [
        '__nfcxx_clz' + suffix,
        "static int __nfcxx_clz#{suffix}(#{t} x) { if (x == 0) return #{bits}; int n = 0;" \
        " while (!(x >> #{bits - 1})) { x <<= 1; ++n; } return n; }"]
    end
  end
end
add_bit_helpers

# GCC's __sync read-modify-write builtins over cproc's __atomic_fetch_OP (which returns the old value, so the new one
# is old OP v) and __atomic_compare_exchange_n (on failure it writes the current value into the expected one, so the
# result is the old value either way). Sizes 4 and 8 are the ones CoreCLR uses.
[4, 8].each do |bytes|
  t = bytes == 4 ? 'unsigned int' : 'unsigned long'
  { 'add' => '+', 'sub' => '-', 'and' => '&', 'or' => '|', 'xor' => '^' }.each do |op, sym|
    name = "__sync_#{op}_and_fetch_#{bytes}"
    HELPER_BUILTINS[name] = ["__nfcxx_#{name}",
      "static #{t} __nfcxx_#{name}(void *p, #{t} v) { return __atomic_fetch_#{op}((#{t} *)p, v, 5) #{sym} v; }"]
  end
  name = "__sync_val_compare_and_swap_#{bytes}"
  HELPER_BUILTINS[name] = ["__nfcxx_#{name}",
    "static #{t} __nfcxx_#{name}(void *p, #{t} o, #{t} n) { __atomic_compare_exchange_n((#{t} *)p, &o, n, 0, 5, 5); return o; }"]
end
HELPER_BUILTINS['__builtin_ia32_pause'] = ['__nfcxx_pause', 'static void __nfcxx_pause(void) { }']
HELPER_BUILTINS['__builtin_prefetch'] = ['__nfcxx_prefetch', 'static void __nfcxx_prefetch(const void *p, ...) { (void)p; }']
HELPER_BUILTINS['__builtin_ffs'] = ['__nfcxx_ffs',
  'static int __nfcxx_ffs(int x) { unsigned int u = (unsigned int)x; int n = 0; if (u == 0) return 0;' \
  ' while (!(u & 1)) { u >>= 1; ++n; } return n + 1; }']

# Type-generic overflow builtins: [C type, helper suffix, unsigned counterpart of a signed type].
OV_TYPES = [['int', 'i', 'unsigned int'], ['unsigned int', 'u', nil], ['long', 'l', 'unsigned long'],
            ['unsigned long', 'ul', nil], ['long long', 'll', 'unsigned long long'],
            ['unsigned long long', 'ull', nil]]
OV_BAD = '__nfcxx_overflow_unsupported_operand_types'
OV_OPS = {'__builtin_add_overflow' => 'add', '__builtin_sub_overflow' => 'sub', '__builtin_mul_overflow' => 'mul'}

# GCC 14 type-generic bit builtins: name => operation. The helper takes (unsigned long long x, int bits, int d): x is
# masked to `bits` (the width of the argument's type), and d is the result for a zero input.
G_OPS = {'__builtin_clzg' => 'clz', '__builtin_ctzg' => 'ctz', '__builtin_popcountg' => 'popcount',
         '__builtin_parityg' => 'parity'}
G_MASK = 'unsigned long long m = bits == 64 ? (unsigned long long)-1 : (1ULL << bits) - 1; x &= m;'
G_BODY = {
  'clz' => 'if (x == 0) return d; int n = 0; while (!(x >> 63)) { x <<= 1; ++n; } return n - (64 - bits);',
  'ctz' => 'if (x == 0) return d; int n = 0; while (!(x & 1)) { x >>= 1; ++n; } return n;',
  'popcount' => 'int n = 0; while (x) { x &= x - 1; ++n; } return n;',
  'parity' => 'int n = 0; while (x) { x &= x - 1; ++n; } return n & 1;',
}

# [name, definition] of the overflow helper for OP on type T; U is the unsigned counterpart of a signed T.
def ov_helper(op, t, suf, u)
  name = "__nfcxx_#{op}ov_#{suf}"
  head = "static int #{name}(#{t} a, #{t} b, #{t} *r) { "
  if u.nil?
    body = {'add' => '*r = a + b; return *r < a;',
            'sub' => '*r = a - b; return a < b;',
            'mul' => '*r = a * b; return a != 0 && *r / a != b;'}[op]
  else
    mn = "((#{t})((#{u})1 << (sizeof(#{t}) * 8 - 1)))"
    body = {'add' => "#{u} s = (#{u})a + (#{u})b; *r = (#{t})s; return ((a ^ (#{t})s) & (b ^ (#{t})s)) < 0;",
            'sub' => "#{u} s = (#{u})a - (#{u})b; *r = (#{t})s; return ((a ^ b) & (a ^ (#{t})s)) < 0;",
            'mul' => "#{u} p = (#{u})a * (#{u})b; *r = (#{t})p; if (a == 0 || b == 0) return 0;" \
                     " if (a == -1) return b == #{mn}; if (b == -1) return a == #{mn}; return (#{t})p / a != b;"}[op]
  end
  [name, head + body + ' }']
end

# Top-level argument token ranges of the call whose '(' is toks[lp]; returns [ranges, index of the ')'].
def split_args(tk, lp)
  rp = match_fwd(tk, lp, '(', ')')
  return [nil, -1] if rp < 0
  ranges = []
  start = lp + 1
  level = 0
  (lp + 1...rp).each do |k|
    c = tk.code(k)
    next unless c >= 0 && c < 256
    if c == 40 || c == 91 || c == 123   # ( [ {
      level += 1
    elsif c == 41 || c == 93 || c == 125   # ) ] }
      level -= 1
    elsif c == 44 && level == 0   # ,
      ranges << [start, k]
      start = k + 1
    end
  end
  ranges << [start, rp]
  [ranges, rp]
end


VOLATILE_QUALS = ['volatile', '__volatile__', '__volatile']
KEEP_NAME = '__nfcxx_keep'
KEEP_DEF = "static void #{KEEP_NAME}(void *p) { }"

def opener?(t)
  t == '(' || t == '[' || t == '{'
end

def closer?(t)
  t == ')' || t == ']' || t == '}'
end

# Edits that keep volatile block-scope locals in memory (C inputs; the qualifier itself is dropped later).
#
# QBE promotes a stack slot to a register unless its address escapes, so a volatile local that is written
# after setjmp and read after longjmp would be stale. After each declaration of such a local this adds
# `__nfcxx_keep(&x);` (a call to an empty function in the prelude), which makes the address escape.
# Skipped: arrays, function pointers and function declarations, typedef/static/extern/register
# declarations, `for` declarations and function parameters (none of which need it or can take it).
def volatile_locals(tk)
  edits = []
  stack = []  # :func, :block or :other for each open brace
  seen = {}
  n = tk.size
  (0...n).each do |i|
    c = tk.code(i)
    if c < 256
      if c == 123
        if stack.empty?
          stack << (tk.punct?(i - 1, ')') ? :func : :other)
        elsif stack.last == :other
          stack << :other
        elsif [-1, 59, 123, 125, 41, 58].include?(tk.code(i - 1)) || tk.id?(i - 1, 'else') || tk.id?(i - 1, 'do')
          stack << :block
        else
          stack << :other
        end
      elsif c == 125 && !stack.empty?
        stack.pop
      end
      next
    end
    next unless c == ID_CODE && VOLATILE_QUALS.include?(tk.text(i))
    next if stack.empty? || stack.last == :other || tk.pdepth(i) != 0
    # A declaration: only identifiers and `*` between the statement start and the qualifier.
    s = i
    s -= 1 while s > 0 && ![59, 123, 125].include?(tk.code(s - 1))
    next if seen[s] || !(s...i).all? { |k| tk.code(k) == ID_CODE || tk.punct?(k, '*') }
    seen[s] = true
    e = i  # the terminating `;`
    level = 0
    while e < n
      x = tk.code(e)
      if x < 256
        xs = PUNCT_S[x]
        if opener?(xs)
          level += 1
        elsif closer?(xs)
          level -= 1
          break if level < 0
        elsif xs == ';' && level == 0
          break
        end
      end
      e += 1
    end
    next if e >= n || level < 0
    next if (s...e).any? { |k|
      tk.code(k) == ID_CODE && ['typedef', 'static', 'extern', 'register', '_Thread_local', '__thread'].include?(tk.text(k))
    }
    pieces = []
    cur = []
    level = 0
    (s...e).each do |k|
      x = tk.code(k)
      if x < 256
        xs = PUNCT_S[x]
        if opener?(xs)
          level += 1
        elsif closer?(xs)
          level -= 1
        elsif xs == ',' && level == 0
          pieces << cur
          cur = []
          next
        end
      end
      cur << k
    end
    pieces << cur
    names = []
    base_vol = false
    pieces.each_with_index do |piece, idx|
      decl = []
      piece.each do |k|
        break if tk.punct?(k, '=')
        decl << k
      end
      stars = []
      vols = []
      decl.each_with_index do |k, kk|
        stars << kk if tk.punct?(k, '*')
        vols << kk if tk.code(k) == ID_CODE && VOLATILE_QUALS.include?(tk.text(k))
      end
      base_vol = vols.any? { |kk| stars.empty? || kk < stars[0] } if idx == 0
      next if decl.any? { |k| tk.punct?(k, '(') || tk.punct?(k, '[') }
      ids = decl.select { |k| tk.code(k) == ID_CODE }
      vol = stars.empty? ? base_vol : vols.any? { |kk| kk > stars[-1] }
      names << tk.text(ids[-1]) if vol && !ids.empty?
    end
    unless names.empty?
      edits << [tk.stop(e), tk.stop(e), names.map { |nm| " #{KEEP_NAME}(&#{nm});" }.join]
    end
  end
  edits
end

# Result types of the general (mixed-operand) overflow lowering: [C type, bits, signed].
OVX_TYPES = [['signed char', 8, 1], ['unsigned char', 8, 0], ['short', 16, 1], ['unsigned short', 16, 0],
             ['int', 32, 1], ['unsigned int', 32, 0], ['long', 64, 1], ['unsigned long', 64, 0],
             ['long long', 64, 1], ['unsigned long long', 64, 0]]
OVX_CORE = <<'EOS'.chomp
static int __nfcxx_ovx(int op, unsigned long long a, int as, unsigned long long b, int bs, int w, int rs, unsigned long long *out) {
  int an = as && (long long)a < 0, bn = bs && (long long)b < 0, neg;
  unsigned long long am = an ? -a : a, bm = bn ? -b : b, hi = 0, lo;
  if (op == 2) {
    unsigned long long a0 = am & 0xffffffffULL, a1 = am >> 32, b0 = bm & 0xffffffffULL, b1 = bm >> 32;
    unsigned long long p00 = a0 * b0, p01 = a0 * b1, p10 = a1 * b0, p11 = a1 * b1;
    unsigned long long mid = (p00 >> 32) + (p01 & 0xffffffffULL) + (p10 & 0xffffffffULL);
    lo = (p00 & 0xffffffffULL) | (mid << 32);
    hi = p11 + (p01 >> 32) + (p10 >> 32) + (mid >> 32);
    neg = an != bn;
  } else {
    if (op == 1) bn = !bn;
    if (an == bn) { lo = am + bm; hi = lo < am; neg = an; }
    else if (am >= bm) { lo = am - bm; neg = an; }
    else { lo = bm - am; neg = bn; }
  }
  if (hi == 0 && lo == 0) neg = 0;
  *out = neg ? -lo : lo;
  if (hi) return 1;
  if (rs) return neg ? lo > (1ULL << (w - 1)) : lo > (1ULL << (w - 1)) - 1;
  if (neg) return 1;
  return w < 64 && (lo >> w) != 0;
}
EOS
OV_OPNUM = {'add' => 0, 'sub' => 1, 'mul' => 2}

def ov_sign(x)
  "_Generic(((#{x})+0), int: 1, long: 1, long long: 1, unsigned: 0, unsigned long: 0," \
  " unsigned long long: 0, default: #{OV_BAD}(0))"
end

# C expression for __builtin_OP_overflow(a, b, r) given the argument texts.
#
# The result is the exact value a OP b converted (wrapping) to *r, the flag is whether that value differs, as in GCC.
# Same-type int/long/long long operands use the small helpers; every other mix of integer operand
# types (literals included) goes through __nfcxx_ovx, which computes in sign and 128-bit magnitude.
def overflow_call(op, text, prelude)
  a, b, r = text
  prelude['__nfcxx_ovx'] = OVX_CORE
  prelude[OV_BAD] = "int #{OV_BAD}(long long, ...);"
  fast = {}
  OV_TYPES.each { |ty, suf, u| fast[ty] = [suf, u] }
  cases = []
  OVX_TYPES.each do |ty, bits, signed|
    wname = '__nfcxx_ovx_' + ty.gsub(' ', '_')
    prelude[wname] = "static int #{wname}(int op, unsigned long long a, int as, unsigned long long b, int bs, #{ty} *r) {" \
                     " unsigned long long o; int f = __nfcxx_ovx(op, a, as, b, bs, #{bits}, #{signed}, &o); *r = (#{ty})o; return f; }"
    mix = "#{wname}(#{OV_OPNUM[op]}, (unsigned long long)(#{a}), #{ov_sign(a)}, (unsigned long long)(#{b}), #{ov_sign(b)}, (#{ty} *)(#{r}))"
    sel = mix
    if fast.key?(ty)
      hname, hdef = ov_helper(op, ty, *fast[ty])
      prelude[hname] = hdef
      sel = "_Generic((#{a}), #{ty}: _Generic((#{b}), #{ty}: #{hname}(#{a}, #{b}, (#{ty} *)(#{r})), default: #{mix}), default: #{mix})"
    end
    cases << "#{ty} *: #{sel}"
  end
  "_Generic((#{r}), " + cases.join(', ') + ", default: #{OV_BAD}(0, #{a}, #{b}, #{r}))"
end

MULOV_NAME = '__nfcxx_mulov_ul'
MULOV_DEF = 'static int __nfcxx_mulov_ul(unsigned long a, unsigned long b, unsigned long *r) {' \
            ' unsigned long p = a * b; *r = p; return a != 0 && p / a != b; }'

# Python: UL_CONST.fullmatch(text) with r'\d+(?:[uU][lL]|[lL][uU])'
def ul_const?(text)
  n = text.bytesize
  return false if n < 3
  a = text.getbyte(n - 2)
  b = text.getbyte(n - 1)
  suffix = ((a == 117 || a == 85) && (b == 108 || b == 76)) || ((a == 108 || a == 76) && (b == 117 || b == 85))
  suffix && all_digits?(text, 0, n - 2)
end

# GCC's sized atomics for 1, 2, 4 and 8 bytes (libstdc++'s std::atomic calls them). GCC inlines them; cproc has
# no atomics, so they are calls to the functions libatomic exports (GCC 13 has all of them; 16 bytes needs
# __int128, which cproc lacks, so it is left out and fails loudly). The memory-order arguments are passed on.
ATOMIC_OPS = ['load', 'store', 'exchange', 'compare_exchange'] +
             ['add', 'sub', 'and', 'or', 'xor', 'nand'].flat_map { |o| ["fetch_#{o}", "#{o}_fetch"] }
ATOMIC_TYPE = {'1' => 'unsigned char', '2' => 'unsigned short', '4' => 'unsigned int', '8' => 'unsigned long'}

# [op, size] if NAME is `__atomic_OP_N`, else nil (Python: ATOMIC_RE.fullmatch)
def atomic_parts(name)
  return nil unless name.start_with?('__atomic_') && name.bytesize > 11
  n = name.bytesize
  size = name.byteslice(n - 1, 1)
  return nil unless name.getbyte(n - 2) == 95 && ATOMIC_TYPE.key?(size)
  op = name.byteslice(9, n - 11)
  ATOMIC_OPS.include?(op) ? [op, size] : nil
end

def atomic_prototype(name)
  op, size = atomic_parts(name)
  t = ATOMIC_TYPE[size]
  return "#{t} #{name}(const volatile void *, int);" if op == 'load'
  return "void #{name}(volatile void *, #{t}, int);" if op == 'store'
  # EDG passes GCC's six arguments; libatomic reads the first three (always seq_cst)
  return "_Bool #{name}(volatile void *, void *, #{t}, _Bool, int, int);" if op == 'compare_exchange'
  "#{t} #{name}(volatile void *, #{t}, int);"  # exchange, fetch_OP and OP_fetch: (ptr, value, order)
end

# True if toks[lp] is the '(' of `( x , C , &x )` (or `( x , C , (&x) )`), x an identifier and C an unsigned long constant.
def mulov_const_shape(tk, lp)
  return false unless tk.punct?(lp, '(')
  k = lp + 1
  return false unless tk.code(k) == ID_CODE && tk.punct?(k + 1, ',')
  xname = tk.text(k)
  return false unless tk.code(k + 2) == NUM_CODE && ul_const?(tk.text(k + 2)) && tk.punct?(k + 3, ',')
  k += 4
  paren = tk.punct?(k, '(')
  k += 1 if paren
  return false if !tk.punct?(k, '&') || tk.code(k + 1) != ID_CODE || tk.text(k + 1) != xname
  k += 2
  if paren
    return false unless tk.punct?(k, ')')
    k += 1
  end
  tk.punct?(k, ')')
end

# If toks[i] starts `__asm__ [volatile] ("int $3\n" : :);`, return the index just past its `;`, else nil.
def int3_statement_end(tk, i)
  j = i + 1
  j += 1 if tk.code(j) == ID_CODE && VOLATILE_QUALS.include?(tk.text(j))
  return nil unless tk.punct?(j, '(') && tk.code(j + 1) == STR_CODE && INT3_TEXT.include?(decode_str(tk.text(j + 1)))
  [':', ':', ')', ';'].each_with_index { |p, k| return nil unless tk.punct?(j + 2 + k, p) }
  j + 6
end

# Names of functions declared or defined with __attribute__((__weak__)), as weak-symbols.rb finds them.
def weak_function_names(tk)
  names = {}
  n = tk.size
  (0...n).each do |i|
    next unless tk.id?(i, '__attribute__') && tk.punct?(i + 1, '(')
    stop = match_fwd(tk, i + 1, '(', ')') + 1
    next unless (i...stop).any? { |k| tk.id?(k, '__weak__') }
    # The first identifier followed by '(' after the attribute, before the declaration ends.
    k = stop
    while k < n && !(tk.punct?(k, ';') || tk.punct?(k, '{') || tk.punct?(k, '}'))
      if tk.id?(k, '__attribute__') && tk.punct?(k + 1, '(')
        k = match_fwd(tk, k + 1, '(', ')') + 1
        next
      end
      if tk.code(k) == ID_CODE && tk.punct?(k + 1, '(')
        names[tk.text(k)] = true
        break
      end
      k += 1
    end
  end
  names
end

# Return type text of the function whose body opens at token brace (a file-scope `{` after the parameter list of
# a declaration that starts at token decl), or nil when that `{` opens no function body. The type is the tokens
# before the name, without __attribute__ groups and storage-class words.
FN_DECL_SKIP = %w[static extern inline __inline __inline__]
def function_return_type(tk, decl, brace)
  return nil unless tk.punct?(brace - 1, ')')
  lp = match_back(tk, brace - 1, '(', ')')
  return nil if lp < 1 || tk.code(lp - 1) != ID_CODE
  name = lp - 1
  words = []
  k = decl
  while k < name
    if tk.id?(k, '__attribute__') && tk.punct?(k + 1, '(')
      k = match_fwd(tk, k + 1, '(', ')') + 1
      next
    end
    words << tk.text(k) unless tk.code(k) == ID_CODE && FN_DECL_SKIP.include?(tk.text(k))
    k += 1
  end
  words.empty? ? nil : words.join(' ')
end

# Names of the typedefs of void (`typedef void T;`, or of another such name): a function returning one is void.
def void_typedefs(tk)
  names = {}
  n = tk.size
  changed = true
  while changed
    changed = false
    (0...n - 3).each do |i|
      next unless tk.id?(i, 'typedef') && tk.punct?(i + 3, ';') && tk.code(i + 2) == ID_CODE
      next if names.key?(tk.text(i + 2))
      base = tk.text(i + 1)
      next unless base == 'void' || names.key?(base)
      names[tk.text(i + 2)] = true
      changed = true
    end
  end
  names
end

# A bare `return;` in a function whose return type is not void: C makes it a constraint violation (gcc only
# warns) and cproc rejects it ("expected primary expression"). EDG emits one in the cleanup code after a call that
# does not return (exit), which never runs. It becomes `return (T){};`, a zero value of the return type: cproc
# accepts that for scalars, pointers and structs (`(T){0}` crashes it for an empty struct).
def bare_return_edits(tk)
  edits = []
  n = tk.size
  voids = void_typedefs(tk)
  decl = 0  # first token of the current file-scope declaration
  i = 0
  while i < n
    if tk.punct?(i, ';') && tk.depth(i) == 0
      decl = i + 1
    elsif tk.punct?(i, '{') && tk.depth(i) == 0
      close = match_fwd(tk, i, '{', '}')
      break if close < 0
      ret = function_return_type(tk, decl, i)
      if ret && ret != 'void' && !voids.key?(ret)
        (i + 1...close).each do |k|
          next unless tk.id?(k, 'return') && tk.punct?(k + 1, ';')
          edits << [tk.start(k), tk.stop(k), "return (#{ret}){}"]
        end
      end
      i = close
      decl = close + 1
    end
    i += 1
  end
  edits
end

# Python: re.fullmatch(r'(?:\d+\.\d*|\.\d+|\d+)(?:[eE][+-]?\d+)?[lL]', text) and re.search(r'[.eE]', text)
def long_double_literal?(text)
  n = text.bytesize
  last = text.getbyte(n - 1)
  return false unless last == 108 || last == 76
  n -= 1
  k = 0
  k += 1 while k < n && digit_b?(text.getbyte(k))
  nint = k
  if k < n && text.getbyte(k) == 46
    k += 1
    nfrac0 = k
    k += 1 while k < n && digit_b?(text.getbyte(k))
    return false if nint == 0 && k == nfrac0
  elsif nint == 0
    return false
  end
  if k < n && (text.getbyte(k) == 101 || text.getbyte(k) == 69)
    k += 1
    k += 1 if k < n && (text.getbyte(k) == 43 || text.getbyte(k) == 45)
    return false unless k < n && all_digits?(text, k, n)
    k = n
  end
  k == n && (text.include?('.') || text.include?('e') || text.include?('E'))
end

# ".align N" / ".globl X" / ".global X" / "A = B" tests of the top-level asm text (Python re.fullmatch).
def align_text?(text)
  return false unless text.start_with?('.align')
  k = 6
  k += 1 while k < text.bytesize && SPACE_B[text.getbyte(k)]
  k > 6 && all_digits?(text, k)
end

def asm_name_char?(b, dot_dollar)
  WORD_B[b] && b < 128 || (dot_dollar && (b == 46 || b == 36))
end

def globl_name(text)
  rest = if text.start_with?('.global') then text.byteslice(7, text.bytesize - 7)
         elsif text.start_with?('.globl') then text.byteslice(6, text.bytesize - 6)
         end
  return nil if rest.nil?
  k = 0
  k += 1 while k < rest.bytesize && SPACE_B[rest.getbyte(k)]
  return nil if k == 0 || k >= rest.bytesize
  name = rest.byteslice(k, rest.bytesize - k)
  b0 = name.getbyte(0)
  return nil unless IDSTART_B[b0] || b0 == 46
  name.each_byte { |b| return nil unless asm_name_char?(b, true) }
  name
end

def set_names(text)
  n = text.bytesize
  return nil if n == 0
  return nil unless IDSTART_B[text.getbyte(0)] && text.getbyte(0) != 36
  k = 1
  k += 1 while k < n && WORD_B[text.getbyte(k)] && text.getbyte(k) < 128
  lhs = text.byteslice(0, k)
  k += 1 while k < n && SPACE_B[text.getbyte(k)]
  return nil unless k < n && text.getbyte(k) == 61
  k += 1
  k += 1 while k < n && SPACE_B[text.getbyte(k)]
  return nil unless k < n && IDSTART_B[text.getbyte(k)] && text.getbyte(k) != 36
  r0 = k
  k += 1 while k < n && WORD_B[text.getbyte(k)] && text.getbyte(k) < 128
  return nil if k != n
  [lhs, text.byteslice(r0, n - r0)]
end

# ---- main -----------------------------------------------------------------------------------------

def read_text(path)
  s = File.open(path, 'rb') { |f| f.read } || ''
  # Python's text mode: universal newlines on read
  s = s.gsub("\r\n", "\n").gsub("\r", "\n") if s.include?("\r")
  s
end

# Identifiers some rewrite looks at (besides the ones followed by '[' and the __atomic_ names). Every other
# token falls through all the rewrites below and is skipped at once: most of the (mruby VM) time otherwise
# goes into testing each token against each rewrite.
SPECIAL_ID = {}
(['typedef', '__attribute__', '__asm__', '__asm', 'alloca', '__builtin_mul_overflow'] + VOLATILE_QUALS +
 LIBC_BUILTINS.keys + HELPER_BUILTINS.keys + OV_OPS.keys + G_OPS.keys + FLOAT_TYPE.keys).each { |k| SPECIAL_ID[k] = true }

def main(argv)
  c_input = false
  args = argv.dup
  # --macho: Mach-O labels carry the target's underscore prefix, and the Apple assembler takes .weak_definition, not .weak
  macho = false
  while args.first == '--c-input' || args.first == '--macho'
    if args.shift == '--macho' then macho = true else c_input = true end
  end
  label = ->(name) { macho ? "_#{name}" : name }
  die 'usage: qbe-prep.rb [--c-input] PREPROCESSED_C REWRITTEN_C ASM_TAIL' if args.size != 3
  src_path, out_path, tail_path = args
  src = read_text(src_path)
  tk = tokenize(src)
  n = tk.size
  edits = []  # [start, end, replacement]
  tail = []   # assembly directives, in source order
  edits.concat(bare_return_edits(tk))
  weak = weak_function_names(tk)
  weak_marked = {}
  ctors = []  # constructor functions, in source order
  need_float = {}
  need_int3 = false
  need_fence = false
  prelude = {}  # name -> C declaration or definition that the rewritten code uses; prepended to the file
  keep = volatile_locals(tk)
  unless keep.empty?
    edits.concat(keep)
    prelude[KEEP_NAME] = KEEP_DEF
  end
  # Identifiers some rewrite looks at (by sym: a name in SPECIAL_ID, or __atomic_*). Every other token
  # falls through all the rewrites below and is skipped at once.
  flags = tk.names.map { |nm| SPECIAL_ID.key?(nm) || nm.start_with?('__atomic_') }

  # _ZTHx is the thread_local init alias for _ZTWx; if the wrapper is COMDAT (weak), so is the alias.
  mark_weak_alias = lambda do |name|
    if name.start_with?('_ZTH') && weak.key?('_ZTW' + name.byteslice(4, name.bytesize - 4)) && !weak_marked.key?(name)
      weak_marked[name] = true
      tail << (macho ? "\t.weak_definition #{label.call(name)}" : "\t.weak #{name}")
    end
  end

  i = 0
  while i < n
    c = tk.code(i)
    if c == ID_CODE
      unless flags[tk.sym(i)] || tk.punct?(i + 1, '[') || tk.id?(i + 1, '__attribute__')
        i += 1
        next
      end
    elsif c == STR_CODE || c == CHR_CODE || (c < 256 && c != 125)
      i += 1
      next
    end
    nm = c == ID_CODE ? tk.text(i) : nil

    # 0b. cproc rejects every store to a volatile object ("volatile store is not yet supported"), yet it already
    # emits volatile loads as plain loads and QBE does not reorder or remove memory accesses of an object whose
    # address escapes (struct members, globals). So the qualifier is dropped, except on inline asm (see the file
    # comment). A volatile local whose address is never taken is promoted to a register by QBE, so
    # volatile_locals() makes its address escape.
    if nm && VOLATILE_QUALS.include?(nm) &&
       !(tk.code(i - 1) == ID_CODE && ['__asm__', '__asm', 'asm'].include?(tk.text(i - 1)))
      edits << [tk.start(i), tk.stop(i), '']
      i += 1
      next
    end

    # 0a. glibc's <bits/floatn.h> (hand-written C, no __GNUC__) typedefs `float _Float32;`,
    # `long double _Float64x;` and the like. The names are mapped below (or have no cproc
    # equivalent), so the plain typedef of one of them is dropped; a use of an unmapped one is an error.
    if nm == 'typedef'
      j = i + 1
      while j < n && !(tk.punct?(j, ';') || tk.punct?(j, '{') || tk.punct?(j, '(') || tk.punct?(j, '['))
        j += 1
      end
      if j < n && tk.punct?(j, ';') && tk.code(j - 1) == ID_CODE && DROP_TYPEDEF.include?(tk.text(j - 1))
        edits << [tk.start(i), tk.stop(j), '']
        i = j + 1
        next
      end
    end

    # 0. __attribute__((__constructor__)) on a function declaration: remove it, and list the function.
    if nm == '__attribute__'
      # Exactly __attribute__((__constructor__)), after a parameter list: NAME ( params ) __attribute__(...)
      if tk.punct?(i + 1, '(') && tk.punct?(i + 2, '(') && tk.id?(i + 3, '__constructor__') &&
         tk.punct?(i + 4, ')') && tk.punct?(i + 5, ')') && tk.punct?(i - 1, ')')
        lp = match_back(tk, i - 1, '(', ')')
        name_i = lp > 0 ? lp - 1 : -1
        die 'qbe-prep: cannot find the name of a constructor declaration' if name_i < 0 || tk.code(name_i) != ID_CODE
        ctors << tk.text(name_i) unless ctors.include?(tk.text(name_i))
        edits << [tk.start(i), tk.stop(i + 5), '']
        i += 6
        next
      end
    end

    # 1a. __asm__ volatile("int $3\n" : :); (doctest's debugger break): a call to the int3 stub.
    if (nm == '__asm__' || nm == '__asm') && stmt_ctx?(tk, i)
      stop = int3_statement_end(tk, i)
      unless stop.nil?
        edits << [tk.start(i), tk.stop(stop - 1), '__nfcxx_int3();']
        need_int3 = true
        i = stop
        next
      end
    end

    # 1. __asm__("...") statements.
    if (nm == '__asm__' || nm == '__asm') && tk.punct?(i + 1, '(') && stmt_ctx?(tk, i)
      j = i + 2
      strs = []
      while j < n && tk.code(j) == STR_CODE
        strs << decode_str(tk.text(j))
        j += 1
      end
      if !strs.empty? && tk.punct?(j, ')') && tk.punct?(j + 1, ';')
        text = py_strip(strs.join)
        stmt_start = tk.start(i)
        stmt_end = tk.stop(j + 1)
        if align_text?(text)
          edits << [stmt_start, stmt_end, '']
          i = j + 2
          next
        end
        if tk.depth(i) == 0 && tk.pdepth(i) == 0
          m = globl_name(text)
          s = m.nil? ? set_names(text) : nil
          if m
            tail << "\t.globl #{label.call(m)}"
            mark_weak_alias.call(m)
          elsif s
            tail << "\t.set #{label.call(s[0])}, #{label.call(s[1])}"
            mark_weak_alias.call(s[0])
          else
            die "qbe-prep: unsupported top-level asm \"#{text}\""
          end
          edits << [stmt_start, stmt_end, '']
          i = j + 2
          next
        end
      end
    end

    # 2. __attribute__((__aligned__(N))) after a declarator name (array or not): becomes _Alignas(N) before the name (valid for members and objects; cproc takes the GNU form only on members).
    if c == ID_CODE && nm != '__attribute__' && (tk.punct?(i + 1, '[') || plain_aligned_object?(tk, i))
      j = i + 1
      while j < n && tk.punct?(j, '[')
        j = match_fwd(tk, j, '[', ']')
        break if j < 0
        j += 1
      end
      g = j > 0 && j < n ? aligned_group(tk, j) : nil
      unless g.nil?
        stop, nn = g
        edits << [tk.start(j), tk.stop(stop - 1), '']
        edits << [tk.start(i), tk.start(i), "_Alignas(#{nn}) "]
        i = stop
        next
      end
    end

    # 3. struct T { ...; } __attribute__((__aligned__(N)));  (alignas on a class, std::aligned_storage):
    # _Alignas(N) on the first member gives the struct the same alignment and the same rounded-up size.
    if c == 125
      g = aligned_group(tk, i + 1)
      if !g.nil? && tk.punct?(g[0], ';')
        stop, nn = g
        o = match_back(tk, i, '{', '}')
        ob = o < 0 ? n + o : o   # toks[o] in the Python original: a negative o indexes from the end
        if first_member_plain?(tk, o, i)
          edits << [tk.stop(ob), tk.stop(ob), " _Alignas(#{nn})"]
          edits << [tk.start(i + 1), tk.stop(stop - 1), '']
          i = stop
          next
        end
      end
    end

    # 4. Floating literals of the types above: f32/f64 drop the suffix; f16/f128 in parentheses become
    # the bit pattern as a brace initializer.
    if c == NUM_CODE && (fl = float_lit(tk.text(i)))
      body, suffix = fl
      paren = tk.punct?(i - 1, '(') && tk.punct?(i + 1, ')')
      if suffix == 'f32'
        edits << [tk.start(i), tk.stop(i), body + 'f']
      elsif suffix == 'f64'
        edits << [tk.start(i), tk.stop(i), body]
      elsif suffix == 'f16' && paren
        # the binary16 value, rounded from the decimal literal, as a cast of its exact double
        edits << [tk.start(i - 1), tk.stop(i + 1), '((_Float16)' + half_literal(ieee_bits(body, 10, 5)) + ')']
        i += 2
        next
      elsif suffix == 'f128' && paren
        bits = ieee_bits(body, 112, 15)
        edits << [tk.start(i - 1), tk.stop(i + 1),
                  '{ { 0x' + hex_pad(bits & ((1 << 64) - 1), 16) + 'UL, 0x' + hex_pad(bits >> 64, 16) + 'UL } }']
        i += 2
        next
      else
        die "qbe-prep: float literal #{tk.text(i)} is not in a supported form"
      end
      i += 1
      next
    end

    # 4c. (double)LITERALL: see the file comment.
    if c_input && c == NUM_CODE && long_double_literal?(tk.text(i)) &&
       tk.punct?(i - 3, '(') && tk.code(i - 2) >= 0 &&
       (tk.text?(i - 2, 'double') || tk.text?(i - 2, 'float')) && tk.punct?(i - 1, ')')
      edits << [tk.stop(i) - 1, tk.stop(i), '']
      i += 1
      next
    end

    # 4a. alloca (hand-written C): a call, not the declaration `void *alloca (size_t)`, is cproc's builtin.
    if c_input && nm == 'alloca' && tk.punct?(i + 1, '(') && !tk.punct?(i - 1, '*')
      edits << [tk.start(i), tk.stop(i), '__builtin_alloca']
      i += 1
      next
    end

    # 4b. Builtins cproc lacks (see the file comment).
    if nm
      if LIBC_BUILTINS.key?(nm)
        name, proto = LIBC_BUILTINS[nm]
        edits << [tk.start(i), tk.stop(i), name]
        prelude[name] = proto
      elsif HELPER_BUILTINS.key?(nm)
        name, definition = HELPER_BUILTINS[nm]
        edits << [tk.start(i), tk.stop(i), name]
        prelude[name] = definition
      elsif nm == '__builtin_mul_overflow' && mulov_const_shape(tk, i + 1)
        edits << [tk.start(i), tk.stop(i), MULOV_NAME]
        prelude[MULOV_NAME] = MULOV_DEF
      elsif G_OPS.key?(nm) && tk.punct?(i + 1, '(')
        ranges, rp = split_args(tk, i + 1)
        want = G_OPS[nm] == 'clz' || G_OPS[nm] == 'ctz' ? [1, 2] : [1]
        die "qbe-prep: #{nm} expects #{want.join(' or ')} argument(s)" if ranges.nil? || !want.include?(ranges.size)
        text = ranges.map { |a, b| src.byteslice(tk.start(a), tk.stop(b - 1) - tk.start(a)) }
        x = text[0]
        d = text[1] || "sizeof(#{x}) * 8"
        name = '__nfcxx_' + nm.delete_prefix('__builtin_')
        prelude[name] = "static int #{name}(unsigned long long x, int bits, int d) { #{G_MASK} #{G_BODY[G_OPS[nm]]} }"
        edits << [tk.start(i), tk.stop(rp), "#{name}((unsigned long long)(#{x}), sizeof(#{x}) * 8, #{d})"]
        i = rp + 1
        next
      elsif OV_OPS.key?(nm) && tk.punct?(i + 1, '(')
        ranges, rp = split_args(tk, i + 1)
        die "qbe-prep: #{nm} expects three arguments" if ranges.nil? || ranges.size != 3
        text = ranges.map { |a, b| src.byteslice(tk.start(a), tk.stop(b - 1) - tk.start(a)) }
        edits << [tk.start(i), tk.stop(rp), overflow_call(OV_OPS[nm], text, prelude)]
        i = rp + 1
        next
      elsif nm == '__atomic_thread_fence' || nm == '__atomic_signal_fence'
        edits << [tk.start(i), tk.stop(i), '__nfcxx_fence']
        prelude['__nfcxx_fence'] = 'void __nfcxx_fence(int);'
        need_fence = true
      elsif nm.start_with?('__atomic_') && atomic_parts(nm)
        prelude[nm] = atomic_prototype(nm)
      end
    end

    # 5. Floating types cproc lacks.
    if nm && FLOAT_TYPE.key?(nm)
      edits << [tk.start(i), tk.stop(i), FLOAT_TYPE[nm]]
      need_float[FLOAT_TYPE[nm]] = true
    end
    i += 1
  end

  decls = ['struct __nfcxx_half16', 'struct __nfcxx_float128'].select { |nm| need_float.key?(nm) }.map { |nm| FLOAT_DECL[nm] }
  if need_int3
    prelude['__nfcxx_int3'] = 'void __nfcxx_int3(void);'
    tail << INT3_STUB
  end
  tail << FENCE_STUB if need_fence
  decls.concat(prelude.values)
  edits << [0, 0, decls.join("\n") + "\n"] unless decls.empty?
  unless ctors.empty?
    tail << "\t.pushsection .init_array,\"aw\""
    tail << "\t.p2align 3"
    ctors.each { |name| tail << "\t.quad #{name}" }
    tail << "\t.popsection"
  end

  File.open(out_path, 'wb') { |f| f.write(apply_edits(src, edits)) }
  File.open(tail_path, 'wb') { |f| f.write(tail.empty? ? '' : tail.join("\n") + "\n") }
end

# Apply the edits from the end, so earlier offsets stay valid: sorted by (start, end) descending, equal
# keys in their original order (Python's stable sorted(..., reverse=True)), each edit on the result of
# the previous ones. Non-overlapping edits are spliced in one pass; anything else replays them one by one.
def apply_edits(src, edits)
  keyed = []
  edits.each_with_index { |e, idx| keyed << [-e[0], -e[1], idx, e] }
  order = keyed.sort.map { |k| k[3] }
  cursor = src.bytesize
  pieces = []
  order.each do |s, e, repl|
    if e > cursor
      cursor = -1
      break
    end
    pieces << src.byteslice(e, cursor - e)
    pieces << repl
    cursor = s
  end
  if cursor >= 0
    return src.byteslice(0, cursor) + pieces.reverse.join
  end
  out = src
  order.each do |s, e, repl|
    out = out.byteslice(0, s) + repl + out.byteslice(e, out.bytesize - e)
  end
  out
end

main(ARGV)
