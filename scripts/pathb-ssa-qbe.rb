#!/usr/bin/env ruby
# frozen_string_literal: true
#
# SSA to QBE (docs/notes/pathb-ssa-qbe.md). Reads the SSA text of a module (scripts/pathb-ssa.rb, optionally optimised
# by scripts/pathb-egraph.rb) and writes QBE IL, which is SSA with blocks and phi. The first subset: integer and pointer
# scalars, arithmetic, comparisons, integer conversions, loads and stores of scalar objects, phi, branches and return.
# A function outside the subset raises QbeUnsupported; nothing is emitted for it.
#
#   scripts/pathb-ssa-qbe.rb FILE.ssa > FILE.qbe      then:  build/qbe/qbe FILE.qbe > FILE.s
#
require_relative "pathb-ssa"

QbeUnsupported = Class.new(StandardError)

module Qbe
  # The text helpers below stand where the script used Regexp, Digest, Base64 and format("%a"): the script world has none
  # of them. Each is the character scan of the pattern named, and pathb-ssa-qbe is fuzzed against the originals.
  DIGITS = "0123456789"
  HEX_DIGITS = "0123456789abcdef"

  # /\A\d+\z/
  def self.all_digits?(s)
    s = s.to_s
    !s.empty? && s.each_char.all? { |c| DIGITS.include?(c) }
  end

  # /\A%\d+\z/
  def self.reg_name?(s) = s.start_with?("%") && all_digits?(s[1..])

  # /nan/i
  def self.nan_text?(text) = text.to_s.downcase.include?("nan")

  # The number of significant digits a float literal prints: text.sub(/[eE].*/, "").delete("-+.").sub(/\A0+/, "").length
  def self.sig_digits(text)
    cut = [text.index("e"), text.index("E")].compact.min
    mant = (cut ? text[0, cut] : text).delete("-+.")
    i = 0
    i += 1 while i < mant.size && mant[i] == "0"
    mant.size - i
  end

  # raw.gsub(/\\(.)/, '\1'): a backslash and the character after it become that character (a newline is not matched by .)
  def self.unescape_backslashes(raw)
    out = +""
    i = 0
    while i < raw.size
      if raw[i] == "\\" && i + 1 < raw.size && raw[i + 1] != "\n"
        out << raw[i + 1]
        i += 2
      else
        out << raw[i]
        i += 1
      end
    end
    out
  end

  # line.gsub(/@@J(\d+)_(\d+)@@/) { yield target, pred }
  def self.each_phi_placeholder(line)
    out = +""
    i = 0
    while i < line.size
      j = line.index("@@J", i)
      unless j
        out << line[i..]
        break
      end
      out << line[i, j - i]
      a = j + 3
      b = a
      b += 1 while b < line.size && DIGITS.include?(line[b])
      c = b + 1
      d = c
      d += 1 while d < line.size && DIGITS.include?(line[d])
      if b > a && line[b] == "_" && d > c && line[d, 2] == "@@"
        out << yield(line[a, b - a], line[c, d - c])
        i = d + 2
      else
        out << "@"
        i = j + 1
      end
    end
    out
  end

  # The hex float C's %a prints for a finite double (Ruby's spelling: 0x1.8p+1, 0x0p+0, a subnormal normalised).
  def self.hex_float(v)
    lo, hi = [v].pack("E").unpack("L<L<") # (two halves: unpack1("Q<") is refused above 2**63)
    sign = hi >> 31 == 1 ? "-" : ""
    ebits = (hi >> 20) & 0x7ff
    mant = ((hi & 0xfffff) << 32) | lo
    return "#{sign}0x0p+0" if ebits.zero? && mant.zero?

    exp = ebits - 1023
    if ebits.zero? # a subnormal is normalised, as Ruby's %a spells it: shift the leading one up to bit 52
      n = 0
      n += 1 while (mant >> n) > 0
      shift = 53 - n
      mant = (mant << shift) & 0xfffffffffffff
      exp = -1022 - shift
    end
    lead = 1
    frac = +""
    13.times { |k| frac << HEX_DIGITS[(mant >> (48 - 4 * k)) & 15] }
    n = frac.size
    n -= 1 while n > 0 && frac[n - 1] == "0"
    frac = frac[0, n]
    "#{sign}0x#{lead}#{frac.empty? ? "" : "."}#{frac}p#{exp >= 0 ? "+" : "-"}#{exp.abs}"
  end

  # Digest::SHA1.hexdigest(str) (FIPS 180-4, 32-bit words held in Integers).
  def self.sha1_hex(str)
    m = 0xffffffff
    rotl = ->(x, n) { ((x << n) | (x >> (32 - n))) & m }
    msg = str.b.bytes
    len = msg.size * 8
    msg << 0x80
    msg << 0 while msg.size % 64 != 56
    8.times { |k| msg << ((len >> (56 - 8 * k)) & 0xff) }
    h = [0x67452301, 0xefcdab89, 0x98badcfe, 0x10325476, 0xc3d2e1f0]
    (msg.size / 64).times do |block|
      off = block * 64
      w = Array.new(80, 0)
      16.times { |t| w[t] = (msg[off + 4 * t] << 24) | (msg[off + 4 * t + 1] << 16) | (msg[off + 4 * t + 2] << 8) | msg[off + 4 * t + 3] }
      (16...80).each { |t| w[t] = rotl.call(w[t - 3] ^ w[t - 8] ^ w[t - 14] ^ w[t - 16], 1) }
      a, b, c, d, e = h
      80.times do |t|
        if t < 20 then f = (b & c) | ((~b & m) & d); k = 0x5a827999
        elsif t < 40 then f = b ^ c ^ d; k = 0x6ed9eba1
        elsif t < 60 then f = (b & c) | (b & d) | (c & d); k = 0x8f1bbcdc
        else f = b ^ c ^ d; k = 0xca62c1d6
        end
        tmp = (rotl.call(a, 5) + f + e + k + w[t]) & m
        e = d
        d = c
        c = rotl.call(b, 30)
        b = a
        a = tmp
      end
      h = [(h[0] + a) & m, (h[1] + b) & m, (h[2] + c) & m, (h[3] + d) & m, (h[4] + e) & m]
    end
    h.map { |x| format("%08x", x) }.join
  end

  INT_W = %w[bool char signed_char unsigned_char short unsigned_short int unsigned_int].freeze
  INT_L = %w[long long_long unsigned_long unsigned_long_long].freeze
  LOAD = { "bool" => "loadub", "char" => "loadsb", "signed_char" => "loadsb", "unsigned_char" => "loadub",
           "short" => "loadsh", "unsigned_short" => "loaduh", "int" => "loadsw", "unsigned_int" => "loaduw",
           "long" => "loadl", "long_long" => "loadl", "unsigned_long" => "loadl", "unsigned_long_long" => "loadl",
           "float" => "loads", "double" => "loadd", "std::float16_t" => "loaduh" }.freeze
  STORE = { "bool" => "storeb", "char" => "storeb", "signed_char" => "storeb", "unsigned_char" => "storeb",
            "short" => "storeh", "unsigned_short" => "storeh", "int" => "storew", "unsigned_int" => "storew",
            "long" => "storel", "long_long" => "storel", "unsigned_long" => "storel", "unsigned_long_long" => "storel",
            "float" => "stores", "double" => "stored", "std::float16_t" => "storeh" }.freeze
  # The std:: float typedefs whose objects are emitted as their bit patterns (storage only): the byte count of each.
  FLOAT_STORAGE = { "std::float16_t" => 2, "std::float32_t" => 4, "std::float64_t" => 8 }.freeze
  SIZE = { "bool" => 1, "char" => 1, "signed_char" => 1, "unsigned_char" => 1, "short" => 2, "unsigned_short" => 2,
           "int" => 4, "unsigned_int" => 4, "long" => 8, "long_long" => 8, "unsigned_long" => 8,
           "unsigned_long_long" => 8, "float" => 4, "double" => 8, "std::float16_t" => 2 }.freeze
  EXT = { "char" => "sb", "signed_char" => "sb", "unsigned_char" => "ub", "short" => "sh", "unsigned_short" => "uh" }.freeze
  BIN = { "wadd" => "add", "wsub" => "sub", "wmul" => "mul", "and" => "and", "or" => "or", "xor" => "xor" }.freeze
  CMP = { "eq" => "ceq", "ne" => "cne", "lt.s" => "cslt", "lt.u" => "cult", "le.s" => "csle", "le.u" => "cule" }.freeze
  # Float operations: the comparisons are ordered (false on NaN), as the interpreter's < and <= are.
  FBIN = { "fadd" => "add", "fsub" => "sub", "fmul" => "mul", "fdiv" => "div" }.freeze
  FCMP = { "lt.f" => "clt", "le.f" => "cle" }.freeze
  CMP_HEADS = (CMP.keys + FCMP.keys).freeze
  # The access of a bit-field's storage unit, by its size in bytes (pathb-qbe-emit.rb's BF_LOAD and BF_STORE).
  BF_LOAD = { 1 => "loadub", 2 => "loaduh", 4 => "loadw", 8 => "loadl" }.freeze
  BF_STORE = { 1 => "storeb", 2 => "storeh", 4 => "storew", 8 => "storel" }.freeze

  # --safe (-fsafe-pointers, pathb-qbe-emit.rb's rules): set by the driver. module_has_data: the module defines a global
  # or a string, which the safe-pointers constructor registers (slice 3); a function that makes a memory access in such a
  # module is refused until then, as is one with a stack slot (its frame registration is slice 3 too).
  class << self
    # darwin: the module is for a Darwin target (the builder sets it from the host; a closed script world has no RbConfig).
    attr_accessor :safe, :asan, :darwin, :module_has_data, :sp_objects, :sp_funcs, :asan_objects
  end
  # --asan, milestone 2: the redzone on each side of a slot that stays in memory (poisoned at the function's entry, unpoisoned
  # before its return). 32 bytes, as the qbe backend's (docs/notes/asan.md).
  ASAN_RZ = 32
  # The size of a frame object that QBE lays out with no padding byte after it (pathb-qbe-emit.rb's SP_NOPAD).
  SP_NOPAD = -(1 << 63)
  # The library's block functions whose pointer arguments are range-checked at a call (pathb-qbe-emit.rb's SP_MEMFN):
  # the argument indices, the length being argument 2.
  SP_MEMFN = { "memcpy" => [0, 1], "memmove" => [0, 1], "memset" => [0], "memcmp" => [0, 1], "bcmp" => [0, 1] }.freeze
  self.safe = false
  # --asan (NFCXX_PATHB_ASAN=1, docs/notes/asan-plan.md): a call of libasan's check before each access through a computed address.
  self.asan = false
  self.module_has_data = false
  self.sp_objects = []
  self.sp_funcs = []
  self.asan_objects = []   # --asan, milestone 3: [symbol, size rounded up to 8] of each global with a redzone after it

  module_function

  def float?(t) = FLOAT_TYPES.key?(unqual(t))

  # _Float16 (std::float16_t): QBE has no half type. A value is its binary16 pattern, zero-extended, in a w register; every
  # operation is a call of a __nfcxx_f16_* helper of be/nfcxx_ldrt.c (libnfcxxld.a), which rounds to half after each
  # operation as gcc does. Only at a call, a parameter and a return does it become the C convention's: the low 16 bits of
  # an SSE register (QBE's s class, by `cast`; see f16_to_sse and f16_from_sse in Fn).
  F16 = "std::float16_t"
  def f16?(t) = unqual(t) == F16

  # The class of a value as it is passed or returned: s for a _Float16, else its own class.
  def abi_cls(t) = f16?(t) ? "s" : cls(t)

  # The QBE class of a scalar type: w for 32-bit and narrower integers, l for 64-bit ones and pointers, s and d for
  # float and double.
  def cls(t)
    t = unqual(t)
    return "l" if head(t) == "ptr"
    return "w" if INT_W.include?(t)
    return "l" if INT_L.include?(t)
    return "s" if t == "float"
    return "d" if t == "double"
    return "w" if t == F16

    raise QbeUnsupported, "type #{sx(t)}"
  end

  def size(t)
    t = unqual(t)
    return size(t[1]) if head(t) == "volatile"
    return 8 if head(t) == "ptr"
    if head(t) == "array"
      # (array COUNT ELEM): a variable-length array's count is a register, which has no size here: refused.
      return size(t[2]) * int_lit(t[1])
    end

    SIZE.fetch(t) { raise QbeUnsupported, "object of type #{sx(t)}" }
  end

  def load_op(t)
    t = unqual(t)
    return "loadl" if head(t) == "ptr"

    LOAD.fetch(t) { raise QbeUnsupported, "load of #{sx(t)}" }
  end

  def store_op(t)
    t = unqual(t)
    return "storel" if head(t) == "ptr"

    STORE.fetch(t) { raise QbeUnsupported, "store of #{sx(t)}" }
  end

  def signed?(t)
    t = unqual(t)
    return false if head(t) == "ptr"

    INT_TYPES.fetch(t) { raise QbeUnsupported, "type #{sx(t)}" }[1]
  end

  # The type of an operator expression: a comparison is bool, an address is a pointer, and any other operator carries its type in its second element.
  def expr_type(x)
    return "bool" if CMP_HEADS.include?(head(x))
    return ["ptr", "void"] if %w[addr index offset].include?(head(x))

    x[1]
  end

  # The frame's objects as QBE call arguments, `l TEMP, l SIZE, ...` (pathb-qbe-emit.rb's sp_frame).
  def sp_pairs(objs) = objs.map { |q, n| "l #{q}, l #{n}" }.join(", ")

  # An integer literal: decimal, or hexadecimal with a 0x prefix (the reader keeps the spelling of a literal).
  def int_lit(s)
    return s if s.is_a?(Integer)
    raise QbeUnsupported, "not an integer literal: #{s.inspect}" unless s.is_a?(String)
    return Integer(s, 16) if s.start_with?("0x", "0X")
    return -Integer(s[1..], 16) if s.start_with?("-0x", "-0X")

    Integer(s, 10)
  rescue ArgumentError, TypeError
    # A register (a variable-length array's count or bound) or another non-literal has no value here: refused.
    raise QbeUnsupported, "not an integer literal: #{s.inspect}"
  end

  # The IEEE binary16 pattern of a decimal float literal (`(const std::float16_t 2.71875)`): the value nearest to it in
  # half precision, ties to even. The literal's printed digits set the precision; the half value must agree with it to
  # within the last printed digit, else the literal is refused. Infinities and NaN are not literals of this emitter.
  def half_bits(lit)
    text = (lit.is_a?(Array) && head(lit) == "const" ? lit[2] : lit).to_s
    return 0x7e00 if Qbe.nan_text?(text) # the positive quiet NaN, as float_bits spells a NaN

    v = Float(text)
    raise QbeUnsupported, "float16 literal #{text}" if v.nan?
    return v.positive? ? 0x7c00 : 0xfc00 if v.infinite?

    sig = Qbe.sig_digits(text)
    sign = text.start_with?("-") ? 0x8000 : 0
    a = v.abs
    return sign if a.zero?

    e = Math.log2(a).floor
    e -= 1 while a < 2.0**e
    e += 1 while a >= 2.0**(e + 1)
    if e < -14
      bits = sign | (a / 2.0**-24).round(half: :even)
    else
      m = (a / 2.0**(e - 10)).round(half: :even)
      if m == 2048
        m = 1024
        e += 1
      end
      raise QbeUnsupported, "float16 literal #{text} overflows" if e > 15

      bits = sign | ((e + 15) << 10) | (m - 1024)
    end
    decoded = half_value(bits)
    # The half value must print, to the literal's significant digits, as the literal does.
    same = format("%.#{sig - 1}e", decoded.abs) == format("%.#{sig - 1}e", a)
    raise QbeUnsupported, "float16 literal #{text} is not a half value" unless same
    bits
  end

  # The bit pattern of a float literal of n bytes (2 binary16, 4 binary32, 8 binary64): nearest value, ties to even,
  # checked against the literal's printed significant digits as half_bits does. Refused where the literal is not that
  # precision.
  def float_bits(lit, n)
    return half_bits(lit) if n == 2

    text = (lit.is_a?(Array) && head(lit) == "const" ? lit[2] : lit).to_s
    # NaN is written as text (`(const float NaN)`, the emitter's spelling); its bits are the positive quiet NaN, as
    # float_lit spells it.
    return n == 4 ? 0x7fc00000 : 0x7ff8000000000000 if Qbe.nan_text?(text)

    v = Float(text)
    raise QbeUnsupported, "float literal #{text}" if v.nan?
    # An infinity (the reader gives +Infinity as 1e999): `double d = INFINITY;`, numeric_limits<double>::infinity() as a
    # static initializer. It was refused, and a unit with one fell back to gcc.
    return v.positive? ? (n == 4 ? 0x7f800000 : 0x7ff00000 << 32) : (n == 4 ? 0xff800000 : 0xfff00000 << 32) if v.infinite?

    sig = Qbe.sig_digits(text)
    if n == 4
      packed = [to_float32(v)].pack("e")   # FLT_MAX is the literal 3.4028235E38: pack("e") alone would make it an infinity
      back = packed.unpack1("e")
      bits = packed.unpack1("L<")
    else
      packed = [v].pack("E")
      back = v
      lo, hi = packed.unpack("L<L<") # (two halves: unpack1("Q<") is refused above 2**63 by the script world's mruby)
      bits = (hi << 32) | lo
    end
    same = sig.zero? || format("%.#{[sig - 1, 0].max}e", back.abs) == format("%.#{[sig - 1, 0].max}e", v.abs)
    raise QbeUnsupported, "float literal #{text} is not of its type" unless same

    bits
  end

  # The value of a binary16 pattern (for the check in half_bits).
  def half_value(bits)
    sign = bits & 0x8000 != 0 ? -1.0 : 1.0
    ebits = (bits >> 10) & 31
    mant = bits & 1023
    mag = ebits.zero? ? mant * 2.0**-24 : (1024 + mant) * 2.0**(ebits - 25)
    sign * mag
  end

  # A constant of type t, wrapped to its QBE class (w: 32 bits, l: 64 bits), as the target computes it.
  def wrap_lit(v, t)
    bits = cls(t) == "w" ? 32 : 64
    v &= (1 << bits) - 1
    v >= 1 << (bits - 1) ? v - (1 << bits) : v
  end

  # A float literal of type t: the value is rounded to t as the interpreter rounds it, then written as an exact hex float
  # (QBE reads it with scanf). Infinities are written as inf; NaN is not a literal of the subset.
  def float_lit(t, text)
    # NaN is the positive quiet NaN, as the emitter spells it (its sign and payload are not in the IR).
    return "#{cls(t)}_nan" if Qbe.nan_text?(text)

    v = round_float(Float(text.to_s), unqual(t))
    return "#{cls(t)}_nan" if v.nan?

    body = v.infinite? ? (v.positive? ? "inf" : "-inf") : Qbe.hex_float(v)
    "#{cls(t)}_#{body}"
  end

  # The QBE symbol of a quoted SSA name: letters, digits, `_` and `.` stay; any other byte is escaped.
  def symbol(raw)
    raw.delete('"').each_char.map do |c|
      (c >= "A" && c <= "Z") || (c >= "a" && c <= "z") || DIGITS.include?(c) || c == "_" || c == "." ? c : "_x#{c.ord.to_s(16)}_"
    end.join
  end

  # The data of one global (install_module's rules, emitted as QBE data): zero bytes, integer and pointer scalars, and
  # addresses of other module globals. A global with an extern or thread-local storage class, a float, a bitfield or
  # any other initialiser is not emitted; a reference to it raises QbeUnsupported. Returns the data line or nil.
  def global_data(g, by_name, state)
    name = g[1].raw
    if state.key?(name)
      return state[name] == :busy ? nil : state[name]
    end

    state[name] = :busy
    state[name] = build_data(g, by_name, state)
  end

  def global_flags(g) = g.map { |x| x.is_a?(Array) ? head(x) : x }

  # An extern global is declared elsewhere: nothing is emitted, and a reference to it is a reference to that symbol.
  # Otherwise the data is emitted with the linkage of the existing emitter: thread-local when (thread), exported unless
  # (static), and a `# pathb-weak` marker for (weak) (the driver writes the .weak directive; see scripts/pathb-ssa-build).
  def build_data(g, by_name, state)
    flags = global_flags(g)
    return :extern if flags.include?("extern")
    # (section "S" [ro]), from __attribute__((section("S"))): the data goes into that section (ELF: the linker delimits
    # it with __start_S / __stop_S), allocated, and writable unless the object is const (gcc: "a", else "aw"). `used`
    # needs nothing more: a static object is emitted whether or not anything refers to it (no --gc-sections here).
    sec = g.find { |x| head(x) == "section" }
    raise QbeUnsupported, "section attribute on a thread-local #{sx(sec)}" if sec && flags.include?("thread")

    init = g.find { |x| head(x) == "init" } or return nil
    size = int_lit(g[3])
    align = [int_lit(g[4]), 1].max
    items = []
    bits = {}   # byte offset -> the bits that the bit-field items put in that byte
    init[1..].each do |item|
      case head(item)
      when "zero" then next
      when "bitfield"
        # (bitfield OFF UNIT BOFF WIDTH TYPE (const TYPE V)): WIDTH bits at bit BOFF of the unit at byte OFF, as
        # pathb-qbe-emit.rb places them, collected per byte (a field's unit may overlap another field's).
        off, _unit, boff, width, _type, val = item[1..]
        return nil unless head(val) == "const"

        width = int_lit(width)
        v = int_lit(val[2]) & ((1 << width) - 1)
        width.times do |i|
          pos = int_lit(off) * 8 + int_lit(boff) + i
          bits[pos / 8] = (bits[pos / 8] || 0) | (((v >> i) & 1) << (pos % 8))
        end
      when "scalar"
        off, type, v = item[1..]
        if (n = FLOAT_STORAGE[unqual(type)])
          # Storage only: the bit pattern of the literal, written as an integer of the same size (no arithmetic on it).
          letter = { 2 => "h", 4 => "w", 8 => "l" }.fetch(n)
          items << [int_lit(off), n, "#{letter} #{Qbe.float_bits(v, n)}"]
          next
        end
        if (fsize = { "float" => 4, "double" => 8 }[unqual(type)])
          # The same storage-only rule for the built-in floating types (a thread-local or volatile object of a double needs
          # its initializer too): the bit pattern of the literal, no arithmetic.
          items << [int_lit(off), fsize, "#{fsize == 4 ? "w" : "l"} #{Qbe.float_bits(v, fsize)}"]
          next
        end
        return nil if FLOAT_TYPES.key?(unqual(type))

        bytes = Qbe.size(type)
        letter = { 1 => "b", 2 => "h", 4 => "w", 8 => "l" }.fetch(bytes) { return nil }
        items << [int_lit(off), bytes, "#{letter} #{literal(v, type)}"]
      when "bytes"
        # (bytes OFF N @"NAME"): the first N bytes of a string literal, one item per byte at the same offsets.
        off, n, target = item[1..]
        src = target.is_a?(Ref) && target.sigil == "@" ? state[[:bytes, target.raw]] : nil
        return nil unless src && int_lit(n) <= src.size

        (0...int_lit(n)).each { |i| items << [int_lit(off) + i, 1, "b #{src[i]}"] }
      when "addr"
        off, _type, target, add = item[1..]
        if target.is_a?(Ref) && target.sigil == "&"
          # A function's address is its symbol, a link-time constant (as pathb-qbe-emit.rb writes it).
          suffix = int_lit(add).zero? ? "" : " + #{int_lit(add)}"
          items << [int_lit(off), 8, "l $#{symbol(target.raw)}#{suffix}"]
          next
        end
        return nil unless target.is_a?(Ref) && target.sigil == "@" && by_name.key?(target.raw)
        # The address of a thread-local object is not a link-time constant: it is left out.
        return nil if global_flags(by_name[target.raw]).include?("thread")
        # A global may point into itself; a longer cycle of addresses is left out (global_data returns nil for it).
        return nil unless target.raw == g[1].raw || global_data(by_name[target.raw], by_name, state)

        suffix = int_lit(add).zero? ? "" : " + #{int_lit(add)}"
        items << [int_lit(off), 8, "l $#{symbol(target.raw)}#{suffix}"]
      else return nil
      end
    end
    # A bit-field's byte is written only by bit-field items: a byte another item also writes is not modelled.
    return nil if bits.keys.any? { |b| items.any? { |off, n, _| b >= off && b < off + n } }

    bits.each { |b, v| items << [b, 1, "b #{v}"] }
    parts = []
    cur = 0
    items.sort_by(&:first).each do |off, bytes, text|
      parts << "z #{off - cur}" if off > cur
      parts << text
      cur = off + bytes
    end
    parts << "z #{size - cur}" if size > cur
    parts = ["z #{size}"] if parts.empty?
    if Qbe.asan && !flags.include?("thread")
      # --asan (milestone 3): a redzone after the object, in its own data item. The object is aligned to 8 (the shadow granule) and
      # padded to a multiple of 8, so the redzone starts on a granule; asan_constructor poisons it at startup.
      align = [align, 8].max
      osz = (size + 7) & ~7
      parts << "z #{osz - size + Qbe::ASAN_RZ}"
      Qbe.asan_objects << [symbol(g[1].raw), osz]
    end
    if Qbe.safe && !flags.include?("thread")
      parts << "z 1"   # padding: see the safe-pointers section of docs/notes/safe-pointers.md
      Qbe.sp_objects << [symbol(g[1].raw), size]
    end
    linkage = (flags.include?("thread") ? "thread " : "") + (flags.include?("static") ? "" : "export ")
    marker = flags.include?("weak") ? "# pathb-weak #{symbol(g[1].raw)}\n" : ""
    if sec
      sec_flags = sec[2] == "ro" ? "a" : "aw"
      linkage += "section " + sec[1].raw + " " + '"' + sec_flags + '"' + " "
    end
    "#{marker}#{linkage}data $#{symbol(g[1].raw)} = align #{align} { #{parts.join(', ')} }"
  end

  # One function. An SSA register %N is %vN, a parameter %k is %pk, and an object of a slot that was not promoted
  # is %o<i>, allocated on the stack at entry.
  class Fn
    attr_reader :lines, :dbg_file, :asan_data

    # globals: the raw names of the module globals that are emitted (a reference to any other global raises).
    def initialize(form, globals = {}, abi = {}, link = {})
      @ubfiles = (link[:ubfiles] ||= {})
      @loc = nil
      @form = form
      @globals = globals
      @abi = abi
      @link = link
      @name = Qbe.symbol(form[1].raw)
      @ret = form.find { |x| head(x) == "ret" }
      @params = form.find { |x| head(x) == "params" }.drop(1)
      @sret = nil      # the AbiInfo of an aggregate result (the function returns its buffer, the C convention)
      @alias = {}      # a register that names another value: the sret parameter names the result buffer
      @empty_bufs = [] # the buffers of the empty by-value parameters (their registers name them)
      @slots = form.select { |x| head(x) == "slot" }
      @blocks = form.select { |x| head(x) == "bb" }
      @lines = []
      @temps = 0
      @types = {}
      @params_set = {}
      @f16_params = [] # the numbers of the _Float16 parameters (they arrive in an SSE register)
      @slot = {}
      @jumper = {}     # [target block, source block] => the emitted label whose jump reaches target
      @phi_expr = {}   # [block, pred, phi register] => the temporary of an expression phi operand
      @sp_objs = []    # --safe: [temporary, size] of the frame objects this function registers
      @asan_alloca = false   # --asan: the function has an alloca, so it keeps the head of its chain in the slot %aah
      @asan_data = []  # --asan: the data items of the fake frames' descriptions (function_text writes them before the function)
      @asan_fakes = [] # --asan, use after return: [fake frame temporary, its size, its class] of each slot that has one
      @asan_ssz = {}   # --asan: the slot's name ($"x") => its exact size, for the elision of checks
      @asan_known = {} # --asan: a register => [slot name, byte offset] when it holds a constant offset into a slot's own object
      @asan_osz = {}   # --asan: the slot's temporary (%oN) => its size rounded up to 8, for the scope facts
      @asan_objs = []  # --asan: [index, temporary of the left redzone, size of the object rounded up to 8] of each slot in memory
    end

    def emit
      header
      allocs
      escape_slots if returns_twice?(@blocks)
      plan_phis
      @blocks.each do |b|
        @cur = b[1].to_s
        @loc = nil
        @label = block_label(@cur)
        @lines << "@#{@label}"
        items = b[2..]
        # A trap or unreachable ends the block in QBE (hlt): what follows it in the SSA block is dead, and QBE rejects an
        # instruction after hlt, so the block is cut there.
        halt = items.index { |it| %w[trap unreachable].include?(head(it)) }
        items = items[0..halt] if halt
        items[0...-1].each { |item| item_lines(item) }
        pending_phi_operands(@cur)
        item_lines(items.last) if items.any?
      end
      @lines << "}"
      resolve_phi_predecessors
      self
    end

    private

    def header
      sig = []
      @params.each_with_index do |p, i|
        case head(p)
        when "param"
          if head(p[3]) == "byval"
            info = aggregate_info(p[3][1], "passed")
            @types[p[1]] = ["ptr", "void"]
            if info.shape == "empty"
              # An empty class is passed as nothing; the function sees the address of a buffer of its own.
              @alias[p[1]] = "%ebuf#{i}"
              @empty_bufs << "%ebuf#{i}"
            else
              # A by-value aggregate is passed as its QBE aggregate type; the register is the address of that copy.
              sig << "#{info.tn} %p#{p[1][1..]}"
              @params_set[p[1]] = true
              @sp_objs << ["%p#{p[1][1..]}", info.size + Qbe::SP_NOPAD] if Qbe.safe
            end
          elsif Qbe.f16?(p[3])
            # A _Float16 arrives in the low 16 bits of an SSE register: its pattern is taken from there.
            @types[p[1]] = p[3]
            sig << "s %p#{p[1][1..]}"
            @alias[p[1]] = "%h#{p[1][1..]}"
            @f16_params << p[1][1..]
          else
            @types[p[1]] = p[3]
            sig << "#{Qbe.cls(p[3])} %p#{p[1][1..]}"
            @params_set[p[1]] = true
          end
        when "sret"
          raise QbeUnsupported, "more than one sret parameter" if @sret
          @sret = aggregate_info(p[2], "returned")
          @alias[p[1]] = "%sretbuf"
          @types[p[1]] = ["ptr", "void"]
        when "ellipsis"
          # A variadic function: the `...` follows the named parameters (its arguments are read with vastart/vaarg).
          sig << "..."
        else raise QbeUnsupported, "#{head(p)} parameter"
        end
      end
      ret = if @sret && @sret.shape != "empty" then "#{@sret.tn} "
            elsif @sret || @ret[1] == "void" then ""
            else "#{Qbe.abi_cls(@ret[1])} "
            end
      # A (weak) function (an inline or template instance) is weak in the object file, as the IR says: the driver writes
      # the .weak directive for the marker.
      @lines << "# pathb-weak #{@name}" if @form.drop(2).any? { |p| p.is_a?(Array) && head(p) == "weak" && p.length == 1 }
      @lines << "export function #{ret}$#{@name}(#{sig.join(", ")}) {"
      @lines << "@start"
      @f16_params.each { |n| f16_from_sse("%h#{n}", "%p#{n}") }
    end

    # The AbiInfo of an aggregate that is passed or returned by value: it must have an abi-type, and its class must be
    # one this emitter passes (not an empty class, not an unsupported one).
    def aggregate_info(tyform, what)
      # A const or volatile struct is passed and returned as the struct: the qualifier does not change its layout.
      tyform = unqual(tyform)
      raise QbeUnsupported, "#{what} aggregate #{sx(tyform)}" unless head(tyform) == "struct" || head(tyform) == "union"

      info = @abi[Qbe.name_of(tyform[1])]
      raise QbeUnsupported, "#{what} aggregate #{sx(tyform)} has no abi-type" if info.nil?
      raise QbeUnsupported, "#{what} by value: #{info.why}" if info.shape == "unsupported"

      info
    end

    def allocs
      @lines << "  %sretbuf =l alloc#{@sret.align >= 16 ? 16 : 8} #{[@sret.size, 1].max}" if @sret
      @sp_objs << ["%sretbuf", @sret.size + Qbe::SP_NOPAD] if @sret && @sret.size > 0 && Qbe.safe
      @empty_bufs.each do |name|
        @lines << "  #{name} =l alloc8 8"
        @sp_objs << [name, 8 + Qbe::SP_NOPAD] if Qbe.safe
      end
      @slots.each_with_index do |s, i|
        @slot["$#{s[1].raw}"] = "%o#{i}"
        # A slot carries its own size and alignment (slot NAME TYPE SIZE ALIGN); a scalar's size is also its type's.
        size = s.size > 4 ? Qbe.int_lit(s[3]) : Qbe.size(s[2])
        align = s.size > 4 ? Qbe.int_lit(s[4]) : size
        a = [16, 8, 4, 2].find { |k| align >= k } || 1
        if Qbe.asan
          @asan_ssz["$#{s[1].raw}"] = size
          asan_slot(i, [size, 1].max, align, s[1].raw)
          next
        end
        # --safe: a slot is registered, with one byte of padding after it (as the emitter pads an escaped slot).
        pad = Qbe.safe ? 1 : 0
        @sp_objs << ["%o#{i}", size] if Qbe.safe
        if align > 16
  # QBE's alloc has no alignment past 16: take the object from a 16-aligned block with align - 16 bytes spare,
  # and round its address up (as pathb-qbe-emit.rb does for an over-aligned slot).
  @lines << "  %o#{i}r =l alloc16 #{[size, 1].max + pad + align}"
  @lines << "  %o#{i}a =l add %o#{i}r, #{align - 1}"
  @lines << "  %o#{i} =l and %o#{i}a, #{-align}"
else
  @lines << "  %o#{i} =l alloc#{a} #{[size, 1].max + pad}"
end
      end
      unless @sp_objs.empty?
        @lines << "  call $__nfcxx_sp_frame(w #{@sp_objs.length}, ..., #{Qbe.sp_pairs(@sp_objs)})"
      end
      if Qbe.asan && @blocks.any? { |b| b[2..].any? { |it| head(it) == "let" && it[3].is_a?(Array) && head(it[3]) == "alloca" } }
        @asan_alloca = true
        @lines << "  %aah =l alloc8 8"
        @lines << "  storel 0, %aah"
      end
      asan_poison
      @blocks.each { |b| b[2..].each { |it| note_type(it) } }
    end

    # --asan: the slot as [left redzone | object | right redzone]. The object keeps its alignment (a 16-aligned block with
    # the left redzone before it, so an object of up to 16 stays aligned; a larger alignment is rounded up inside a block
    # with that much spare). Its size is rounded up to 8, the shadow granule, so the right redzone starts on a granule.
    def asan_slot(i, size, align, name = '""')
      rz = Qbe::ASAN_RZ
      osz = (size + 7) & ~7
      total = rz + osz + rz
      if align > 16
        @lines << "  %o#{i}r =l alloc16 #{total + align}"
        @lines << "  %o#{i}q =l add %o#{i}r, #{rz + align - 1}"
        @lines << "  %o#{i} =l and %o#{i}q, #{-align}"
        @lines << "  %o#{i}l =l sub %o#{i}, #{rz}"
      else
        frame = (total + 63) & ~63
        cls = (0..10).find { |c| (64 << c) >= frame }
        if cls
          asan_fake_frame(i, size, total, frame, cls, name)
        else
          @lines << "  %o#{i}l =l alloc16 #{total}"
        end
        @lines << "  %o#{i} =l add %o#{i}l, #{rz}"
      end
      @asan_objs << [i, "%o#{i}l", osz]
      @asan_osz["%o#{i}"] = osz
    end

    # --asan, milestone 6 (use after scope): (decl $"x" val|ref) unpoisons the local's object, (scope-end $"x") poisons it, with
    # libasan's stack-memory calls, so a read after the scope reports stack-use-after-scope (the front end prints the facts under
    # NFCXX_IR_SCOPES=1). Only a slot in memory has an object; the facts of a promoted slot never get here (pathb-ssa.rb).
    def asan_scope(item, entering)
      return unless Qbe.asan

      ref = item[1]
      return unless ref.is_a?(Ref) && ref.sigil == "$"

      tmp = @slot["$#{ref.raw}"]
      osz = tmp && @asan_osz[tmp]
      return unless osz

      @lines << "  call $__asan_#{entering ? 'unpoison' : 'poison'}_stack_memory(l #{tmp}, l #{osz})"
    end

    # --asan, milestone 7 (use after return): the slot's frame is libasan's fake frame when it can give one (the runtime keeps a fake
    # stack per thread; __asan_stack_malloc_N(frame) returns 0 when detect_stack_use_after_return is off or the class is full), else
    # the real frame, which is always allocated too (qbe's asanalloc, docs/notes/asan.md): the base is picked branch-free,
    # and gcc's header goes in front of the object (the magic, the description, the pc), as libasan reads it for the report.
    # asan_leave gives the fake frame back, and libasan then poisons it as stack-use-after-return.
    def asan_fake_frame(i, size, total, frame, cls, name)
      nm = name.delete('"').chars.map { |c| (c >= "A" && c <= "Z") || (c >= "a" && c <= "z") || (c >= "0" && c <= "9") || c == "_" || c == "." ? c : "_" }.join
      desc = "__asan_desc.#{@name}.#{i}"
      @asan_data << "data $#{desc} = align 1 { b \"1 #{Qbe::ASAN_RZ} #{size} #{nm.length} #{nm}\", b 0 }"
      @lines << "  %o#{i}rl =l alloc16 #{total}"
      @lines << "  %o#{i}f =l call $__asan_stack_malloc_#{cls}(l #{frame})"
      @lines << "  %o#{i}n =l sub 0, %o#{i}f"
      @lines << "  %o#{i}m0 =l or %o#{i}f, %o#{i}n"
      @lines << "  %o#{i}m =l sar %o#{i}m0, 63"
      @lines << "  %o#{i}x0 =l xor %o#{i}rl, %o#{i}f"
      @lines << "  %o#{i}x =l and %o#{i}x0, %o#{i}m"
      @lines << "  %o#{i}l =l xor %o#{i}rl, %o#{i}x"
      @lines << "  storel #{0x41B58AB3}, %o#{i}l"
      @lines << "  %o#{i}h8 =l add %o#{i}l, 8"
      @lines << "  storel $#{desc}, %o#{i}h8"
      @lines << "  %o#{i}h16 =l add %o#{i}l, 16"
      @lines << "  storel $#{@name}, %o#{i}h16"
      @asan_fakes << ["%o#{i}f", frame, cls]
    end

    # --asan: poison both redzones of every slot (after all the allocations, at the function's entry).
    def asan_poison
      @asan_objs.each do |i, left, osz|
        @lines << "  call $__asan_poison_memory_region(l #{left}, l #{Qbe::ASAN_RZ})"
        @lines << "  %o#{i}e =l add %o#{i}, #{osz}"
        @lines << "  call $__asan_poison_memory_region(l %o#{i}e, l #{Qbe::ASAN_RZ})"
      end
    end

    # --asan: before a return, the whole of each slot's block is addressable again, for the next frame on this stack.
    def asan_leave
      if @asan_alloca
        h = fresh
        @lines << "  #{h} =l loadl %aah"
        @lines << "  call $__nfcxx_asan_alloca_release(l #{h})"
      end
      @asan_objs.each do |_i, left, osz|
        @lines << "  call $__asan_unpoison_memory_region(l #{left}, l #{osz + 2 * Qbe::ASAN_RZ})"
      end
      # Each fake frame is given back on a branch (libasan's free reads the frame, so it is not called with 0).
      @asan_fakes.each do |fake, frame, cls|
        @temps += 1
        fr = "afr#{@temps}"
        nx = "afn#{@temps}"
        @lines << "  jnz #{fake}, @#{fr}, @#{nx}"
        @lines << "@#{fr}"
        @lines << "  call $__asan_stack_free_#{cls}(l #{fake}, l #{frame})"
        @lines << "@#{nx}"
        @label = nx
      end
    end

    def note_type(item)
      @types[item[1]] = item[2] if %w[let phi].include?(head(item))
    end

    # The location a failed check reports: the file (its data name, see Qbe.ubfile_data) and the line of the last
    # (loc ...) statement before the check in its block, or 0 when there is none (pathb-qbe-emit.rb's sp_where).
    def sp_where
      return "l 0, w 0" if @loc.nil?

      idx = (@ubfiles[@loc[0]] ||= @ubfiles.length)
      "l $__nfcxx_ubf#{idx}, w #{@loc[1]}"
    end

    # A (loc FILE LINE) statement: the statements after it in the block are at that location.
    def set_loc(item)
      file = item[1].respond_to?(:raw) ? item[1].raw : item[1].to_s
      @loc = [Qbe.unescape_backslashes(file.delete_prefix('"').delete_suffix('"')), Qbe.int_lit(item[2])]
      asan_dbgloc
    end

    # --asan: the source line of an access, for libasan's report. QBE's `dbgfile` is a top-level directive that applies to the
    # functions after it, so a function takes the file of its first (loc ...) (module_il writes the `dbgfile` before it), and
    # a `dbgloc LINE` follows each (loc ...) of that file (a location from another file, an inlined header, is left out).
    # The assembler turns them into .file and .loc, so the object has a line table whether or not -g was given.
    def asan_dbgloc
      return unless Qbe.asan

      file, line = @loc
      return if line <= 0 || file.empty? || (file.include?('"') || file.include?("\\") || file.include?("\n"))

      @dbg_file ||= file
      @lines << "  dbgloc #{line}" if file == @dbg_file
    end

    # (asm-block "HEX" (opnd KIND "CODE" SIZE ARG)...): a general x86 template (be/nfcxx_ir.c). The operand block holds eight
    # bytes per operand: an input's value (zero-extended to 64 bits), a memory operand's address. The helper
    # (Qbe.asm_block) reads them, runs the template and writes the outputs back; they are stored to their addresses here.
    # The symbol and constant offset an address register stands for ([Ref, offset]), through the (bitcast), (offset) and
    # (index) lets that built it from an object's address; nil when it is anything else.
    def asm_symbol_of(x, depth = 0)
      return [x, 0] if x.is_a?(Ref) && x.sigil == "@"
      return nil unless x.is_a?(String) && depth < 16

      rv = @ptr_defs && @ptr_defs[x]
      return nil if rv.nil?

      case head(rv)
      when "bitcast"
        asm_symbol_of(rv[2], depth + 1)
      when "offset", "index"
        return nil unless head(rv[2]) == "const"

        base, off = asm_symbol_of(rv[1], depth + 1)
        return nil if base.nil?

        [base, off + Qbe.int_lit(rv[2][2]) * (head(rv) == "index" ? Qbe.int_lit(rv[3]) : 1)]
      end
    end

    def asm_block_lines(item)
      ops = []
      clobbers = []
      labels = []
      item[2..].each do |o|
        if head(o) == "clobber"
          clobbers << o[1].raw.delete('"')
        elsif head(o) == "label"
          labels << o[1].raw.delete('"')
        elsif head(o) == "opnd"
          ops << { kind: o[1].to_s, code: o[2].raw.delete('"'), size: Qbe.int_lit(o[3]), arg: o[4],
                   name: o[5] ? o[5].raw.delete('"') : "", off: o[6] ? Qbe.int_lit(o[6]) : 0 }
        else
          raise QbeUnsupported, "asm-block: an operand that is not opnd"
        end
      end
      # immv / symv: an immediate that the front end could not fold ("i"(1 << (bit & 7)) of an inlined parameter): the
      # operand's value, after the folding of the e-graph, must be an integer constant or a symbol plus a constant offset.
      ops.each do |o|
        if o[:kind] == "immv"
          raise QbeUnsupported, "asm: an immediate operand that is not a constant" unless head(o[:arg]) == "const"

          o[:kind] = "imm"
          o[:arg] = ["const", "long", Qbe.int_lit(o[:arg][2]).to_s]
        elsif o[:kind] == "symv"
          base, off = asm_symbol_of(o[:arg])
          raise QbeUnsupported, "asm: an address operand that is not a symbol and a constant offset" if base.nil?

          o[:kind] = "sym"
          o[:arg] = base
          o[:off] = off
        end
      end
      ops.each { |o| o[:sym] = Qbe.symbol(o[:arg].raw) if o[:kind] == "sym" }
      ops.each { |o| o[:imm] = Qbe.int_lit(o[:arg][2]) if o[:kind] == "imm" }
      name, text = Qbe.asm_block(item[1].raw.delete('"'), ops, clobbers, labels)
      (@link[:asm_texts] ||= {})[name] ||= text
      blk = fresh
      @lines << "  #{blk} =l alloc8 #{8 * [ops.size, 1].max}"
      addrs = {}
      ops.each_with_index do |o, i|
        slot = fresh
        @lines << "  #{slot} =l add #{blk}, #{8 * i}"
        if o[:kind] == "sym"
          # The symbol's address goes into the cell although the template names the symbol: the reference keeps a static
          # object that only the asm uses from being pruned.
          @lines << "  storel #{op(o[:arg])}, #{slot}"
        elsif %w[in inout mem].include?(o[:kind])
          v = op(o[:arg])
          val = v
          cls = nil
          if o[:kind] == "inout"
            # The operand is read first: its current value, at its address (the statement passes the address).
            ld = { 1 => "loadub", 2 => "loaduh", 4 => "loaduw", 8 => "loadl" }.fetch(o[:size]) do
              raise QbeUnsupported, "asm-block operand of #{o[:size]} bytes"
            end
            cls = o[:size] == 8 ? "l" : "w"
            val = fresh
            @lines << "  #{val} =#{cls} #{ld} #{v}"
          elsif o[:kind] == "in"
            cls = Qbe.cls(operand_type(o[:arg]))
            if cls == "s" || cls == "d"
              bits = fresh
              @lines << "  #{bits} =#{cls == "s" ? "w" : "l"} cast #{v}"
              v = bits
              val = bits
              cls = cls == "s" ? "w" : "l"
            end
            raise QbeUnsupported, "asm-block input of class #{cls}" unless %w[w l].include?(cls)
          end
          if cls == "w"
            ext = fresh
            @lines << "  #{ext} =l extuw #{val}"
            val = ext
          end
          @lines << "  storel #{val}, #{slot}"
        end
        addrs[i] = op(o[:arg]) if %w[out inout flag gsel].include?(o[:kind])
      end
      @lines << "  call $#{name}(l #{blk})"
      ops.each_with_index do |o, i|
        next unless %w[out inout flag gsel].include?(o[:kind])

        slot = fresh
        @lines << "  #{slot} =l add #{blk}, #{8 * i}"
        load, store = { 1 => %w[loadub storeb], 2 => %w[loaduh storeh], 4 => %w[loaduw storew], 8 => %w[loadl storel] }
                      .fetch(o[:size]) { raise QbeUnsupported, "asm-block output of #{o[:size]} bytes" }
        t = fresh
        @lines << "  #{t} =#{o[:size] == 8 ? "l" : "w"} #{load} #{slot}"
        @lines << "  #{store} #{t}, #{addrs[i]}"
      end
    end

    def reg(name) = "%v#{name[1..]}"

    # How often each SSA register (`%N`) appears in the function: a `let` names its register once, so 1 means unused.
    def reg_uses
      @reg_uses ||= begin
        counts = Hash.new(0)
        walk = lambda do |x|
          if x.is_a?(String)
            counts[x] += 1 if Qbe.reg_name?(x)
          elsif x.is_a?(Array)
            x.each { |y| walk.call(y) }
          end
        end
        walk.call(@form)
        counts
      end
    end

    def block_label(num) = "b#{num}"

    # Checks that need no emission: a switch's targets may not repeat where a phi reads them, and a phi operand that is an
    # expression is computed at the end of its predecessor, so the phi reads a temporary.
    def plan_phis
      @phi_blocks = {}
      @block_by_num = {}
      @blocks.each { |b| @block_by_num[b[1].to_s] = b }
      @blocks.each do |b|
        @phi_blocks[b[1].to_s] = true if b[2..].any? { |it| head(it) == "phi" }
      end
      @blocks.each do |b|
        b[2..].each do |it|
          next unless head(it) == "switch"

          cases, default = switch_parts(it)
          targets = cases.map(&:last) + [default]
          dup = targets.find { |t| targets.count(t) > 1 }
          raise QbeUnsupported, "switch edges to block #{dup} that has phi" if dup && @phi_blocks[dup]
        end
      end
      @pending = Hash.new { |h, k| h[k] = [] }
      @blocks.each do |b|
        b[2..].each do |it|
          next unless head(it) == "phi"

          it[3..].each do |pred, v|
            next unless expression?(v)

            name = "%pe#{it[1][1..]}_#{pred}"
            @pending[pred.to_s] << [name, v]
            @phi_expr[[b[1].to_s, pred.to_s, it[1]]] = name
          end
        end
      end
    end

    # A phi names its predecessors by block. The label that jumps to a block is known only once the predecessor is
    # emitted (a split block may take the jump), so the phi carries a placeholder, resolved at the end.
    def phi_placeholder(target, pred) = "@@J#{target}_#{pred}@@"

    def resolve_phi_predecessors
      @lines.map! do |l|
        Qbe.each_phi_placeholder(l) do |target, pred|
          key = [target, pred]
          "@#{@jumper.fetch(key) { block_label(key[1]) }}"
        end
      end
    end

    # A jump from the current block to target: the phi of target names the label that jumps.
    def jump_to(target)
      @jumper[[target.to_s, @cur]] = @label
    end

    def expression?(v) = v.is_a?(Array) && !%w[const null].include?(head(v))

    def pending_phi_operands(num)
      @pending.fetch(num, []).each do |name, v|
        let_lines(name, v[1], v)
        @types[name] = v[1]
      end
    end

    def switch_parts(item)
      cases = item[2..].select { |c| head(c) == "case" }.map { |c| [c[1], c[2].to_s] }
      default = item[2..].find { |c| head(c) == "default" } or raise QbeUnsupported, "switch without a default"
      [cases, default[1].to_s]
    end

    # The type of an operand: a constant's or an expression's own type, or the declared type of a register.
    def switch_operand_type(x)
      return x[1] if x.is_a?(Array) && head(x) == "const"
      return(x[1].is_a?(Array) ? x[1] : ["ptr", "void"]) if x.is_a?(Array) && head(x) == "null"
      return Qbe.expr_type(x) if expression?(x)

      @types.fetch(x) { raise QbeUnsupported, "operand #{sx(x)} has no declared type" }
    end

    # A switch is a chain of tests; the first is in the block where the switch is emitted, each later one in its own
    # block. QBE has no switch, so each test is `jnz` on an equality. Each jump is recorded for the phi of its target.
    def switch_lines(item)
      cases, default = switch_parts(item)
      if cases.empty?
        jump_to(default)
        @lines << "  jmp @#{block_label(default)}"
        return
      end
      opnd = item[1]
      if expression?(opnd)
        # An operator in operand position: computed into a temporary first, in the switch's own block.
        name = "%swop#{@cur}"
        let_lines(name, opnd[1], opnd)
        @types[name] = opnd[1]
        operand = reg(name)
      else
        operand = op(opnd)
      end
      cls = Qbe.cls(switch_operand_type(opnd))
      # A bit test, or four or more items: a balanced tree (GCC's decision tree; docs/notes/pathb-switch.md, which
      # cites https://xoranth.net/gcc-switch/). Fewer: the chain, which is cheaper.
      # The tree's targets skip the blocks that only jump on (a case label that falls into the next one, or an empty arm),
      # so labels with one body share a target and can form a bit test.
      tree_cases = cases.map { |value, target| [value, switch_forward(target)] }
      tree_default = switch_forward(default)
      items = switch_items(switch_ranges(tree_cases), cls)
      if items.any? { |it| it[0] == :bits } || items.size >= 4
        switch_tree_lines(operand, cls, Qbe.signed?(switch_operand_type(opnd)), items, tree_default)
      else
        switch_chain_lines(operand, cls, cases, default)
      end
    end

    # The chain of equality tests, one per case, in source order.
    def switch_chain_lines(operand, cls, cases, default)
      labels = [@label] + (1...cases.size).map { |k| "#{block_label(@cur)}.s#{k}" }
      cases.each_with_index do |(value, target), k|
        cond = "%sw#{@cur}_#{k}"
        @lines << "  #{cond} =w ceq#{cls} #{operand}, #{Qbe.int_lit(value)}"
        @jumper[[target, @cur]] = labels[k]
        if k + 1 < cases.size
          @lines << "  jnz #{cond}, @#{block_label(target)}, @#{labels[k + 1]}"
          @lines << "@#{labels[k + 1]}"
        else
          @jumper[[default, @cur]] = labels[k]
          @lines << "  jnz #{cond}, @#{block_label(target)}, @#{block_label(default)}"
        end
      end
    end

    # GCC's clusters: the case values in order as [lo, hi, target], adjacent values with one target merged into one range.
    def switch_ranges(cases)
      out = []
      pairs = cases.map { |value, target| [Qbe.int_lit(value), target] }
      pairs = pairs.sort { |a, b| a[0] <=> b[0] }
      pairs.each do |v, target|
        last = out.last
        if last && last[2] == target && last[1] + 1 == v
          last[1] = v
        else
          out << [v, v, target]
        end
      end
      out
    end

    # The block a jump to target reaches: target itself, or the block it forwards to while that block only jumps on (its one
    # item is a br) and the block it jumps to has no phi (a phi would name the forwarding block as its predecessor).
    def switch_forward(target)
      t = target.to_s
      seen = {}
      while !seen[t] && @block_by_num[t] && @block_by_num[t].size == 3 && head(@block_by_num[t][2]) == "br"
        seen[t] = true
        nxt = @block_by_num[t][2][1].to_s
        break if @phi_blocks[nxt]

        t = nxt
      end
      t
    end

    # The items the tree is built over, in value order. A range is [:range, lo, hi, target]. A bit-test group is
    # [:bits, lo, span, tests]: the values of ranges i..j, all within span <= 30 of lo, reaching at most three targets, with
    # tests [[target, mask], ...] where bit v - lo of mask is set for each value v of that target (GCC's bit_test_cluster,
    # gcc/tree-switch-conversion.cc: 3 case labels for one target, 5 for two, 6 for three). Only for 32-bit operands: a shift
    # count is a 32-bit value in QBE.
    def switch_items(ranges, cls)
      return ranges.map { |lo, hi, t| [:range, lo, hi, t] } unless cls == "w"

      items = []
      i = 0
      while i < ranges.size
        j = i + 1
        j += 1 while j < ranges.size && switch_fits?(ranges, i, j)
        taken = nil
        last = j - 1
        while last > i
          if switch_beneficial?(ranges, i, last)
            taken = last
            break
          end
          last -= 1
        end
        if taken
          items << switch_bits_item(ranges, i, taken)
          i = taken + 1
        else
          items << [:range, ranges[i][0], ranges[i][1], ranges[i][2]]
          i += 1
        end
      end
      items
    end

    def switch_fits?(ranges, i, j)
      ranges[j][1] - ranges[i][0] <= 30 && switch_targets(ranges, i, j).size <= 3
    end

    def switch_targets(ranges, i, j)
      out = []
      (i..j).each { |k| out << ranges[k][2] unless out.include?(ranges[k][2]) }
      out
    end

    def switch_beneficial?(ranges, i, j)
      uniq = switch_targets(ranges, i, j).size
      count = 0
      (i..j).each { |k| count += ranges[k][1] - ranges[k][0] + 1 }
      (uniq == 1 && count >= 3) || (uniq == 2 && count >= 5) || (uniq == 3 && count >= 6)
    end

    def switch_bits_item(ranges, i, j)
      lo = ranges[i][0]
      tests = switch_targets(ranges, i, j).map { |t| [t, 0] }
      (i..j).each do |k|
        slot = tests.find { |t, _| t == ranges[k][2] }
        (ranges[k][0]..ranges[k][1]).each { |v| slot[1] |= 1 << (v - lo) }
      end
      [:bits, lo, ranges[j][1] - lo, tests]
    end

    # A balanced binary tree over the items. Each inner block splits its items at the lower bound of the middle one: a value
    # below it goes left. A range leaf tests its range (x == lo for one value, else x - lo <=u hi - lo) and jumps to its target,
    # or to the default. A bit-test leaf tests the window, then one bit per target, each failing on to the next. The tree
    # sends several jumps to the default, and to a target reached from several leaves: a phi of such a target names one
    # predecessor, so those jumps go through one block that jumps on.
    def switch_tree_lines(operand, cls, signed, items, default)
      st = { uses: Hash.new(0), seq: 0, traps: {} }
      items.each do |it|
        if it[0] == :range
          st[:uses][it[3]] += 1
          st[:uses][default] += 1
        else
          it[3].each { |t, _| st[:uses][t] += 1 }
          st[:uses][default] += 2
        end
      end
      switch_tree_node(st, operand, cls, signed, items, @label, true, default)
      st[:traps].each do |target, label|
        @lines << "@#{label}"
        @lines << "  jmp @#{block_label(target)}"
      end
    end

    # The label a jump from block `from` to target goes to; records the jump for the phi of target.
    def switch_tree_edge(st, target, from)
      if @phi_blocks[target.to_s]
        if st[:uses][target] > 1
          st[:traps][target] ||= "#{block_label(@cur)}.j#{target}"
          @jumper[[target, @cur]] = st[:traps][target]
          return st[:traps][target]
        end
        @jumper[[target, @cur]] = from
      end
      block_label(target)
    end

    def switch_tree_node(st, operand, cls, signed, items, label, root, default)
      @lines << "@#{label}" unless root
      st[:seq] += 1
      n = st[:seq]
      if items.size == 1
        it = items[0]
        if it[0] == :bits
          switch_bits_leaf(st, operand, it, label, default, n)
          return
        end
        _, lo, hi, target = it
        cond = "%swc#{@cur}_#{n}"
        if lo == hi
          @lines << "  #{cond} =w ceq#{cls} #{operand}, #{lo}"
        else
          shifted = "%swr#{@cur}_#{n}"
          @lines << "  #{shifted} =#{cls} sub #{operand}, #{lo}"
          @lines << "  #{cond} =w cule#{cls} #{shifted}, #{hi - lo}"
        end
        yes = switch_tree_edge(st, target, label)
        no = switch_tree_edge(st, default, label)
        @lines << "  jnz #{cond}, @#{yes}, @#{no}"
        return
      end
      mid = items.size / 2
      cond = "%swc#{@cur}_#{n}"
      @lines << "  #{cond} =w c#{signed ? "slt" : "ult"}#{cls} #{operand}, #{items[mid][1]}"
      left = "#{block_label(@cur)}.t#{n}l"
      right = "#{block_label(@cur)}.t#{n}r"
      @lines << "  jnz #{cond}, @#{left}, @#{right}"
      switch_tree_node(st, operand, cls, signed, items[0, mid], left, false, default)
      switch_tree_node(st, operand, cls, signed, items[mid, items.size - mid], right, false, default)
    end

    # A bit-test leaf (32-bit operand): the window test, then for each target `(mask >> (x - lo)) & 1`. A test that fails
    # goes on to the next; the last one fails to the default.
    def switch_bits_leaf(st, operand, it, label, default, n)
      _, lo, span, tests = it
      shifted = "%swr#{@cur}_#{n}"
      inside = "%swc#{@cur}_#{n}"
      @lines << "  #{shifted} =w sub #{operand}, #{lo}"
      @lines << "  #{inside} =w culew #{shifted}, #{span}"
      first = "#{label}.b#{n}_0"
      @lines << "  jnz #{inside}, @#{first}, @#{switch_tree_edge(st, default, label)}"
      tests.each_with_index do |(target, mask), k|
        block = "#{label}.b#{n}_#{k}"
        @lines << "@#{block}"
        bit = "%swb#{@cur}_#{n}_#{k}"
        hit = "%swh#{@cur}_#{n}_#{k}"
        @lines << "  #{bit} =w shr #{mask}, #{shifted}"
        @lines << "  #{hit} =w and #{bit}, 1"
        miss = k + 1 < tests.size ? "#{label}.b#{n}_#{k + 1}" : switch_tree_edge(st, default, block)
        @lines << "  jnz #{hit}, @#{switch_tree_edge(st, target, block)}, @#{miss}"
      end
    end

    # An operand: a register, a parameter, an integer constant, null, or the address of an object.
    def op(x)
      case x
      when Ref
        if x.sigil == "@"
          info = @globals.fetch(x.raw) { raise QbeUnsupported, "global #{x.raw}" }
          # A weak undefined object is loaded through the GOT in the existing emitter; that is not modelled here.
          # A weak undefined object is read through the GOT (`copy extern`), so an absent definition reads as null.
          if info[:weak] && info[:extern]
            t = fresh
            @lines << "  #{t} =l copy extern $#{Qbe.symbol(x.raw)}"
            return t
          end
          # On Darwin an extern object is usually in a dylib (libc++'s vtable or typeinfo for std::length_error): the
          # adrp/add pair to its @page is a relocation ld64 cannot resolve for an imported data symbol ("does not have
          # address"), so its address is read through the GOT, as clang does (QBE's extern on an Apple target).
          if info[:extern] && Qbe.darwin
            t = fresh
            @lines << "  #{t} =l copy extern $#{Qbe.symbol(x.raw)}"
            return t
          end
          # A thread-local object: its address is the thread pointer plus the object's offset (initial-exec, as the
          # existing emitter does it).
          if info[:thread]
            t = fresh
            @lines << "  #{t} =l copy extern thread $#{Qbe.symbol(x.raw)}"
            return t
          end
          return "$#{Qbe.symbol(x.raw)}"
        end
# A function used as a value. A function this module defines is addressed by its symbol. Any other function
# is loaded from a pointer cell (`pathb_got.NAME`, one data word the module defines), as scripts/pathb-qbe-emit.rb
# does: `leaq f(%rip)` is a PC-relative reference that a PIE link rejects for a symbol of a shared library.
if x.sigil == "&"
  sym = Qbe.symbol(x.raw)
  return "$#{sym}" if !@link.key?(:funcs) || @link[:funcs].include?(sym)
  t = fresh
  @lines << "  #{t} =l loadl $pathb_got.#{sym}"
  return t
end
        raise QbeUnsupported, "address #{x.raw}" unless x.sigil == "$"

        @slot.fetch("$#{x.raw}") { raise QbeUnsupported, "slot #{x.raw}" }
      when String
        raise QbeUnsupported, "operand #{x}" unless x.start_with?("%")

        return @alias[x] if @alias.key?(x)

        @params_set[x] ? "%p#{x[1..]}" : reg(x)
      when Array
        case head(x)
        when "const"
          return Qbe.half_bits(x).to_s if Qbe.f16?(x[1])
          return Qbe.float_lit(x[1], x[2]) if float_type?(x[1])

          Qbe.wrap_lit(Qbe.int_lit(x[2]), x[1]).to_s
        when "null" then "0"
        when "addr" then op(x[1])
        else
          # A nested expression: computed into a temporary, whose line is appended before the caller's line.
          raise QbeUnsupported, "operand #{sx(x)}" unless expression?(x)

          name = "%ne#{@temps += 1}"
          t = Qbe.expr_type(x)
          let_lines(name, t, x)
          @types[name] = t
          reg(name)
        end
      else raise QbeUnsupported, "operand #{sx(x)}"
      end
    end

    def item_lines(item)
      case head(item)
      when "phi"
        pairs = item[3..].map do |pred, v|
          text = expression?(v) ? reg(@phi_expr.fetch([@cur, pred.to_s, item[1]])) : op(v)
          "#{phi_placeholder(@cur, pred)} #{text}"
        end.join(", ")
        @lines << "  #{reg(item[1])} =#{Qbe.cls(item[2])} phi #{pairs}"
      when "let" then let_lines(item[1], item[2], item[3])
      # A volatile store is a call of its helper (QBE merges, forwards and drops plain volatile stores; a call is kept).
      when "store"
        v = op(item[3])
        a = op(item[2])
        safe_check(item[2], a, Qbe.size(item[1]))
        asan_check(item[2], a, Qbe.size(item[1]), "store")
        @lines << "  #{Qbe.store_op(item[1])} #{v}, #{a}"
      when "store.v" then volatile_store_lines(item)
      # `(copy N DST SRC)`: N bytes from SRC to DST (the interpreter's copy_cells). QBE's blit copies a byte count.
      when "copy"
        # The addresses of a copy are pointers. A register holding a by-value aggregate (a byval parameter) is not one:
        # that ABI case is refused, not emitted.
        [item[2], item[3]].each do |a|
          next unless a.is_a?(String) && a.start_with?("%")

          t = @types[a]
          raise QbeUnsupported, "copy of an address with no declared type #{a}" if t.nil?
          raise QbeUnsupported, "copy of the by-value aggregate #{a}" unless head(unqual(t)) == "ptr"
        end
        src = op(item[3])
        dst = op(item[2])
        n = Qbe.int_lit(item[1])
        safe_check(item[2], dst, n)
        safe_check(item[3], src, n)
        asan_check(item[3], src, n, "load")
        asan_check(item[2], dst, n, "store")
        @lines << "  blit #{src}, #{dst}, #{n}"
      # `(zero-fill N DST)`: clear N bytes at DST (be/nfcxx_ir.c emits it for a zero-initialised object of more than 128
      # stores, as the QBE emitter does: one call of memset).
      when "zero-fill"
        raise QbeUnsupported, "zero-fill of a register count" unless item[1].is_a?(Integer) || Qbe.all_digits?(item[1])
        if item[2].is_a?(String) && item[2].start_with?("%")
          t = @types[item[2]]
          raise QbeUnsupported, "zero-fill of an address with no declared type #{item[2]}" if t.nil?
          raise QbeUnsupported, "zero-fill of the by-value aggregate #{item[2]}" unless head(unqual(t)) == "ptr"
        end
        n = Qbe.int_lit(item[1])
        dst = op(item[2])
        safe_check(item[2], dst, n)
        asan_check(item[2], dst, n, "store")
        @lines << "  call $memset(l #{dst}, w 0, l #{n})" unless n.to_i.zero?
      when "br"
        jump_to(item[1])
        @lines << "  jmp @#{block_label(item[1])}"
      when "switch" then switch_lines(item)
      when "eval"
        if head(item[1]) == "rdtsc"
          # A time-stamp read whose value is discarded: the helper is called for its effect on nothing.
          asm_helpers << "rdtsc"
          @lines << "  call $__pathb_rdtsc()"
          return
        end
        raise QbeUnsupported, "statement #{sx(item)}" unless head(item[1]) == "call"

        # A fetch-and-add whose old value is discarded (a shared_ptr's count) is the same locked xadd, not a libatomic call.
        if atomic_fetch?(item[1])
          atomic_fetch_lines(fresh, nil, item[1])
          return
        end
        if atomic_store?(item[1])
          atomic_store_lines(item[1])
          return
        end

        sret, dest, sym, args = call_parts(item[1])
        if sret.nil? || sret.shape == "empty"
          @lines << "  call #{sym}(#{args.join(', ')})"
        else
          # The callee returns the aggregate in its own buffer; it is copied to the destination the caller named.
          t = fresh
          @lines << "  #{t} =#{sret.tn} call #{sym}(#{args.join(', ')})"
          @lines << "  call $memmove(l #{dest}, l #{t}, l #{sret.size})"
        end
      when "condbr"
        cond = op(item[1])
        jump_to(item[2])
        jump_to(item[3])
        @lines << "  jnz #{cond}, @#{block_label(item[2])}, @#{block_label(item[3])}"
      when "ret"
        asan_leave
        # --safe: the frame is released before the return (pathb-qbe-emit.rb's SP_LEAVE, with the first object).
        @lines << "  call $__nfcxx_sp_leave(l #{@sp_objs.first[0]})" if Qbe.safe && !@sp_objs.empty?
        # A function with an sret parameter returns its result buffer (the C convention; the caller copies it out).
        if @sret
          @lines << (@sret.shape == "empty" ? "  ret" : "  ret %sretbuf")
        elsif item.size > 1 && Qbe.f16?(@ret[1])
          @lines << "  ret #{f16_to_sse(op(item[1]))[2..]}"
        else
          @lines << (item.size > 1 ? "  ret #{op(item[1])}" : "  ret")
        end
      when "unreachable", "trap" then @lines << "  hlt"
      when "loc" then set_loc(item)
      when "decl" then asan_scope(item, true)
      when "scope-end" then asan_scope(item, false)
      when "bfstore", "bfstore.v" then bfstore_lines(item)
      when "nonnull" then nonnull_lines(item[1])
      when "bounds" then bounds_lines(item[1], item[2])
      # A compiler barrier is a call of an empty helper; a fence a call of a helper that executes mfence. QBE has no
      # fence instruction, so the driver (scripts/pathb-ssa-build) appends the helpers named by the marker comments.
      when "barrier" then barrier_lines
      # (asm-block ...): a general x86 template (see asm_block_lines).
      when "asm-block" then asm_block_lines(item)
      when "fence" then fence_lines
      # A branch-likelihood hint (likely/unlikely) changes only the layout the optimiser would choose, never the
      # meaning of the code; QBE has no such hint, so the hint emits nothing.
      when "likely", "unlikely" then nil
      # (vastart ADDR): the va_list at ADDR starts reading the variadic arguments (the function has an ellipsis).
      when "vastart" then @lines << "  vastart #{op(item[1])}"
      # An `unsupported` statement carries the lowering's reason, which is reported as the form itself (as pathb-qbe-emit.rb does).
      when "unsupported" then raise QbeUnsupported, sx(item)
      else raise QbeUnsupported, "statement #{head(item) || sx(item)}"
      end
    end

    # The helpers the assembly needs ("barrier", "fence"); module_il writes them as marker comments.
    def asm_helpers = @asm_helpers ||= []
    public :asm_helpers

    # A function that calls one that returns twice (setjmp and its kin) keeps its slots in memory: QBE does not know
    # that the function returns twice, and it would promote a slot to a temporary holding the value from the setjmp
    # call. Passing each slot's address to an empty helper makes the address escape, as pathb-qbe-emit.rb does.
    RETURNS_TWICE = %w[setjmp _setjmp sigsetjmp __sigsetjmp savectx vfork getcontext].freeze

    def returns_twice?(x)
      return false unless x.is_a?(Array)
      return true if head(x) == "call" && x[2].is_a?(Ref) && x[2].sigil == "&" && RETURNS_TWICE.include?(x[2].raw.delete('"'))

      x.any? { |y| returns_twice?(y) }
    end

    def escape_slots
      asm_helpers << "escape"
      @slots.each_index { |i| @lines << "  call $__pathb_escape(l %o#{i})" }
    end

# `pathb_check(cond, code)`: a check that traps when cond is nonzero. The module names the `check` helper, which
# the driver appends (scripts/pathb-ssa-build): an abort, as scripts/pathb-qbe-emit.rb's shared abort block.
# The call is out of the flow: a `jnz` to a trap block of its own (the call, then hlt: the helper does not return),
# and the operation goes on in the block after it. A call in the hot path cost about 40% of token generation.
    def check_call(cond, code)
      asm_helpers << "check" unless asm_helpers.include?("check")
      @temps += 1
      trap = "ckt#{@temps}"
      ok = "cko#{@temps}"
      @lines << "  jnz #{cond}, @#{trap}, @#{ok}"
      @lines << "@#{trap}"
      @lines << "  call $pathb_check(w 1, w #{code})"
      @lines << "  hlt"
      @lines << "@#{ok}"
      @label = ok # a jump out of the split block is the one that the phi of its target names
    end

    def barrier_lines
      asm_helpers << "barrier"
      @lines << "  call $__pathb_barrier()"
    end

    def fence_lines
      asm_helpers << "fence"
      @lines << "  call $__pathb_fence()"
    end

    def let_lines(r, t, rv)
      dst = reg(r)
      (@ptr_defs ||= {})[r] = rv if %w[offset bitcast index].include?(head(rv))
      if Qbe.asan && %w[offset bitcast].include?(head(rv)) && (k = asan_slot_addr(rv))
        @asan_known[r] = k
      end
      c = Qbe.cls(t)
      case head(rv)
      when "wadd", "wsub", "wmul"
        # A wrapping sum, difference or product of a narrow type is wrapped to that type: the 32-bit register would
        # keep the high bits, and a later comparison or overflow test of the value (the sign bit) would see them.
        if Qbe::EXT.key?(t)
          raw = fresh
          @lines << "  #{raw} =#{c} #{Qbe::BIN[head(rv)]} #{op(rv[2])}, #{op(rv[3])}"
          canon_lines(dst, t, raw)
        else
          @lines << "  #{dst} =#{c} #{Qbe::BIN[head(rv)]} #{op(rv[2])}, #{op(rv[3])}"
        end
      when *Qbe::BIN.keys
        @lines << "  #{dst} =#{c} #{Qbe::BIN[head(rv)]} #{op(rv[2])}, #{op(rv[3])}"
      when "wneg" then @lines << "  #{dst} =#{c} sub 0, #{op(rv[2])}"
      when "cdiv", "crem" then checked_div_lines(dst, t, rv)
      when "cshl", "cshr", "wshl" then checked_shift_lines(dst, t, rv)
      when "cadd", "csub", "cmul", "cneg" then checked_arith_lines(dst, t, rv)
      when *Qbe::FBIN.keys
        if Qbe.f16?(t)
          f16_call(dst, Qbe::FBIN[head(rv)], ["w #{op(rv[2])}", "w #{op(rv[3])}"])
        else
          @lines << "  #{dst} =#{c} #{Qbe::FBIN[head(rv)]} #{op(rv[2])}, #{op(rv[3])}"
        end
      when "fneg" then @lines << (Qbe.f16?(t) ? "  #{dst} =w xor #{op(rv[2])}, 32768" : "  #{dst} =#{c} neg #{op(rv[2])}")
      when *Qbe::CMP.keys
        if Qbe.f16?(rv[1])
          f16_call(dst, head(rv), ["w #{op(rv[2])}", "w #{op(rv[3])}"])
          return
        end
        oc = Qbe.cls(rv[1])
        @lines << "  #{dst} =w #{Qbe::CMP[head(rv)]}#{oc} #{op(rv[2])}, #{op(rv[3])}"
      when *Qbe::FCMP.keys
        if Qbe.f16?(rv[1])
          f16_call(dst, head(rv)[0, 2], ["w #{op(rv[2])}", "w #{op(rv[3])}"])
          return
        end
        oc = Qbe.cls(rv[1])
        @lines << "  #{dst} =w #{Qbe::FCMP[head(rv)]}#{oc} #{op(rv[2])}, #{op(rv[3])}"
      when "iconv" then conv_lines(dst, t, rv[2])
      # An integer to pointer conversion widens the integer as an iconv to a 64-bit type does (pathb-qbe-emit.rb's i2p).
      when "i2p" then conv_lines(dst, t, rv[2])
      when "i2f", "u2f" then int_to_float_lines(dst, t, rv[2])
      when "fconv" then float_conv_lines(dst, t, rv[2])
      when "cf2i" then float_to_int_lines(dst, t, rv[2])
      when "call"
        if atomic_fetch?(rv)
          atomic_fetch_lines(dst, c, rv)
        elsif Qbe.f16?(rv[1])
          # The result is the low 16 bits of xmm0.
          raw = fresh
          @lines << "  #{raw} =s #{call_text(rv)}"
          f16_from_sse(dst, raw)
        elsif atomic_load?(rv)
          @lines << "  #{dst} =#{ATOMIC_LOAD_OP[rv[2].raw.delete('"')[-1]]} #{op(rv[3])}"
        # A bool result is defined in its low byte only (the ABI sets %al): take that byte, then normalise it to 0 or 1.
        elsif unqual(rv[1]) == "bool"
          raw = fresh
          @lines << "  #{raw} =w #{call_text(rv)}"
          low = fresh
          @lines << "  #{low} =w extub #{raw}"
          @lines << "  #{dst} =w cnew #{low}, 0"
        else
          @lines << "  #{dst} =#{c} #{call_text(rv)}"
        end
      # (vaarg TYPE ADDR): the next variadic argument of the va_list at ADDR. QBE reads w, l, s and d only.
      when "vaarg"
        raise QbeUnsupported, "vaarg of #{sx(rv[1])}" unless %w[w l s d].include?(Qbe.cls(rv[1])) && !Qbe.f16?(rv[1])

        @lines << "  #{dst} =#{c} vaarg #{op(rv[2])}"
        # QBE drops a vaarg whose value is unused, and then the va_list does not advance: keep the read alive.
        if reg_uses["%#{dst[2..]}"] <= 1
          sink = "vasink_#{c}"
          asm_helpers << sink unless asm_helpers.include?(sink)
          @lines << "  call $__pathb_#{sink}(#{c} #{dst})"
        end
        # QBE does not know that vaarg writes the va_list: a load of it after this read would reuse an earlier load.
        # The barrier call is a memory clobber for QBE.
        barrier_lines
      when "addr" then @lines << "  #{dst} =l copy #{op(rv)}"
      # `(not T A)`: a bitwise complement of an integer, or a logical negation of a bool. The complement is narrowed to
      # the type's canonical form. Floats are not integers and are refused.
      when "not"
        raise QbeUnsupported, "not on a floating type #{sx(t)}" if FLOAT_TYPES.key?(unqual(t))

        if unqual(t) == "bool"
          @lines << "  #{dst} =w xor #{op(rv[2])}, 1"
        else
          raw = fresh
          @lines << "  #{raw} =#{c} xor #{op(rv[2])}, -1"
          canon_lines(dst, t, raw)
        end
      # `(p2i T P)`: a pointer's address as an integer of type T, truncated or kept as the type's canonical form.
      when "p2i" then canon_lines(dst, t, op(rv[2]))
      # `(rdtsc)`: the time-stamp counter, from the helper the driver appends.
      when "rdtsc"
        asm_helpers << "rdtsc"
        @lines << "  #{dst} =l call $__pathb_rdtsc()"
      # `(retaddr)`, `(frameaddr)`: __builtin_return_address(0) and __builtin_frame_address(0). QBE gives each function a frame
      # pointer, so the helper the driver appends reads this function's frame (%rbp on x86-64, x29 on arm64: the frame record).
      when "retaddr", "frameaddr"
        # The empty call after it keeps QBE from turning `return __builtin_return_address(0);` into a tail call (`leave; jmp`),
        # which would run the helper in the caller's frame.
        asm_helpers << head(rv)
        asm_helpers << "barrier" unless asm_helpers.include?("barrier")
        @lines << "  #{dst} =l call $__pathb_#{head(rv)}()"
        @lines << "  call $__pathb_barrier()"
      when "bitcast" then bitcast_lines(dst, rv)
      when "bfload", "bfload.v" then bfload_lines(dst, rv)
      when "offset"
        base = op(rv[1])
        if Qbe.safe
          sum = fresh
          @lines << "  #{sum} =l add #{base}, #{Qbe.int_lit(rv[2])}"
          @lines << "  #{dst} =l call $__nfcxx_sp_derive(l #{base}, l #{sum}, #{sp_where})"
        else
          @lines << "  #{dst} =l add #{base}, #{Qbe.int_lit(rv[2])}"
        end
      when "index" then index_lines(dst, rv)
      when "alloca" then alloca_lines(dst, rv)
      when "pdiff" then pdiff_lines(dst, t, rv)
      # A volatile load is a call of its helper (see volatile_load_lines).
      when "load.v" then volatile_load_lines(dst, rv)
      when "load"
        # A bool object holding another byte is read as true, and a load yields 0 or 1 (EDG's model): normalise the byte.
        a = op(rv[2])
        safe_check(rv[2], a, Qbe.size(rv[1]))
        asan_check(rv[2], a, Qbe.size(rv[1]), "load")
        if unqual(rv[1]) == "bool"
          raw = fresh
          @lines << "  #{raw} =w loadub #{a}"
          @lines << "  #{dst} =w cnew #{raw}, 0"
        else
          @lines << "  #{dst} =#{c} #{Qbe.load_op(rv[1])} #{a}"
        end
      when "const", "null", nil
        # A bare slot address (a Ref): the inliner's copies of an argument's slot (an SSA rewrite can leave one as a let's value).
        @lines << "  #{dst} =#{c} copy #{op(rv)}" if rv.is_a?(Array) || rv.is_a?(String) || rv.is_a?(Ref)
        raise QbeUnsupported, "let of #{sx(rv)}" unless rv.is_a?(Array) || rv.is_a?(String) || rv.is_a?(Ref)
      else raise QbeUnsupported, "operator #{head(rv) || sx(rv)}"
      end
    end

    # An integer conversion to type t from the operand x. A widening keeps the value; a conversion to bool compares
    # with zero; a conversion to a narrower type sign- or zero-extends the low bits.
    def conv_lines(dst, t, x)
      src = x.is_a?(Array) && head(x) == "const" ? x[1] : @types[x]
      raise QbeUnsupported, "conversion of an untyped operand #{sx(x)}" unless src
      raise QbeUnsupported, "float to integer by iconv" if float_type?(src)

      dc = Qbe.cls(t)
      sc = Qbe.cls(src)
      if dc == "l" && sc == "w"
        @lines << "  #{dst} =l #{Qbe.signed?(src) ? 'extsw' : 'extuw'} #{op(x)}"
      elsif dc == "w" && sc == "l" && t != "bool" && !Qbe::EXT.key?(t)
        @lines << "  #{dst} =w copy #{op(x)}"
      elsif t == "bool"
        @lines << "  #{dst} =w cne#{sc} #{op(x)}, 0"
      elsif Qbe::EXT.key?(t)
        @lines << "  #{dst} =w ext#{Qbe::EXT[t]} #{op(x)}"
      else
        @lines << "  #{dst} =#{dc} copy #{op(x)}"
      end
    end

    # The checks of the interpreter (pathb-ssa.rb, Machine#eval_rv; pathb-egraph.rb, CheckedMachine for the shifts).
    # Each check is a call `pathb_check(cond, code)` before the operation: the runtime does not return when cond is
    # nonzero (it traps, or longjmps out in the test driver), so the operation after it is never reached with the
    # bad operands and no block is split. Codes: 1 division by zero, 2 signed overflow, 3 shift count out of range.
    def fresh = "%ck#{@temps += 1}"

    # `(alloca N)`: N bytes of dynamic stack, 16-byte aligned, as pathb-qbe-emit.rb's r_alloca. A 32-bit size is widened.
    def alloca_lines(dst, rv)
      n = rv[1]
      t = operand_type(n)
      Qbe.signed?(t) # refuses a size that is not an integer
      size = op(n)
      if Qbe.cls(t) == "w"
        wide = fresh
        @lines << "  #{wide} =l extuw #{size}"
        size = wide
      end
      if Qbe.asan
        # --asan (milestone 4): [32 | object | 32], the object's size rounded up to 8, linked into the frame's chain
        # (lib/asan/nfcxx_vla_asan.c) that asan_leave releases before the return.
        up = fresh
        osz = fresh
        total = fresh
        blk = fresh
        @lines << "  #{up} =l add #{size}, 7"
        @lines << "  #{osz} =l and #{up}, -8"
        @lines << "  #{total} =l add #{osz}, #{2 * Qbe::ASAN_RZ}"
        @lines << "  #{blk} =l alloc16 #{total}"
        @lines << "  call $__nfcxx_asan_alloca_mark(l #{blk}, l #{osz}, l %aah)"
        @lines << "  #{dst} =l add #{blk}, #{Qbe::ASAN_RZ}"
        return
      end
      @lines << "  #{dst} =l alloc16 #{size}"
    end

    def memory_access?(x)
      return false unless x.is_a?(Array)
      return true if %w[load load.v store store.v copy index offset].include?(head(x))
      x.any? { |y| memory_access?(y) }
    end

    # A volatile load or store: a call of the module's helper for its operation (see Qbe.volatile_helpers).
    def volatile_load_lines(dst, rv)
      op_name = Qbe.load_op(rv[1])
      a = op(rv[2])
      safe_check(rv[2], a, Qbe.size(rv[1]))
      asan_check(rv[2], a, Qbe.size(rv[1]), "load")
      @lines << "  #{dst} =#{Qbe.cls(rv[1])} call $#{Qbe.volatile_name("ld", op_name)}(l #{a})"
    end

    def volatile_store_lines(item)
      op_name = Qbe.store_op(item[1])
      a = op(item[2])
      v = op(item[3])
      safe_check(item[2], a, Qbe.size(item[1]))
      asan_check(item[2], a, Qbe.size(item[1]), "store")
      @lines << "  call $#{Qbe.volatile_name("st", op_name)}(l #{a}, #{Qbe.store_class(op_name)} #{v})"
    end

    # --safe (-fsafe-pointers): the check of an access of `bytes` bytes at `addr` (the text of the IR operand `x`), which
    # the existing emitter makes before every load and store through a computed address. A static address (a slot, a
    # global, an address-of) is not checked. The location is not in the SSA text, so a report has none ("?").
    def safe_check(x, addr, bytes)
      return unless Qbe.safe
      return if x.is_a?(Ref) || (x.is_a?(Array) && head(x) == "addr")
      @lines << "  call $__nfcxx_sp_check(l #{addr}, l #{bytes}, #{sp_where})"
    end

    # --asan: before an access of `bytes` bytes at `addr` (the text of the IR operand `x`), a call of libasan's check:
    # __asan_load1/2/4/8/16 or __asan_store1/2/4/8/16, and __asan_loadN/__asan_storeN(addr, size) for any other size. The
    # call also keeps QBE from forwarding or merging the access, as a volatile access is kept. A static address (a slot,
    # a global, an address-of) is not checked: nothing poisons those yet (milestones 2 and 3 of the plan).
    # --asan: [slot name, offset] when the address operand `x` is a constant offset into a slot's own object (the slot, or
    # (offset X C) and (bitcast T X) of one, or a register holding one), else nil.
    def asan_slot_addr(x)
      case x
      when Ref then x.sigil == "$" && @asan_ssz.key?("$#{x.raw}") ? ["$#{x.raw}", 0] : nil
      when String then @asan_known[x]
      when Array
        case head(x)
        when "bitcast" then asan_slot_addr(x[2])
        when "offset"
          b = asan_slot_addr(x[1])
          c = (Qbe.int_lit(x[2]) rescue nil)
          b && c ? [b[0], b[1] + c] : nil
        end
      end
    end

    # --asan: a check is not needed for an access that stays inside a local's own object through its own address: the slot's
    # redzones and its poison are for pointers that reach it from elsewhere. (A fixed offset in bounds cannot overflow.)
    def asan_known_inbounds?(x, bytes)
      k = asan_slot_addr(x)
      k && k[1] >= 0 && k[1] + bytes <= @asan_ssz[k[0]]
    end

    def asan_check(x, addr, bytes, kind)
      return unless Qbe.asan
      return if x.is_a?(Ref) || (x.is_a?(Array) && head(x) == "addr")
      n = bytes.to_i
      return if n <= 0
      return if asan_known_inbounds?(x, n)
      if [1, 2, 4, 8, 16].include?(n)
        @lines << "  call $__asan_#{kind}#{n}(l #{addr})"
      else
        @lines << "  call $__asan_#{kind}N(l #{addr}, l #{n})"
      end
    end

    # The unqualified type: const and volatile are access qualifiers, not part of the value's class.
    def unqual(t) = Qbe.unqual(t)

    # The class of an operand whose type is known: a constant, a declared register, or an expression's type.
    def operand_type(x) = expression?(x) ? Qbe.expr_type(x) : switch_operand_type(x)

    # `(index BASE I SIZE)`: BASE plus I times SIZE. A 32-bit index is widened (signed or unsigned as its type) first.
    def index_lines(dst, rv)
      base = op(rv[1])
      idx = rv[2]
      signed = Qbe.signed?(operand_type(idx))
      i = op(idx)
      if Qbe.cls(operand_type(idx)) == "w"
        wide = fresh
        @lines << "  #{wide} =l #{signed ? 'extsw' : 'extuw'} #{i}"
        i = wide
      end
      scaled = fresh
      @lines << "  #{scaled} =l mul #{i}, #{Qbe.int_lit(rv[3])}"
      if Qbe.safe
        # --safe: the derived address must stay in base's object (sp_derive in pathb-qbe-emit.rb).
        sum = fresh
        @lines << "  #{sum} =l add #{base}, #{scaled}"
        @lines << "  #{dst} =l call $__nfcxx_sp_derive(l #{base}, l #{sum}, #{sp_where})"
      else
        @lines << "  #{dst} =l add #{base}, #{scaled}"
      end
    end

    # Bit-fields, with pathb-qbe-emit.rb's rules: `(bfload T UNIT ADDR BOFF WIDTH)` reads the whole UNIT-byte unit and
    # extracts WIDTH bits from bit BOFF (little-endian bit numbering), sign- or zero-extended to T. The extraction is a
    # shift pair, never an `and` with a low mask. `(bfstore T UNIT ADDR BOFF WIDTH VALUE)` replaces those bits of the
    # unit, leaves the others alone, and stores the whole unit back.
    def bf_args(x, nargs)
      raise QbeUnsupported, "#{head(x)} form" unless x.length == nargs

      unit = Qbe.int_lit(x[2])
      boff = Qbe.int_lit(x[4])
      width = Qbe.int_lit(x[5])
      raise QbeUnsupported, "#{head(x)} of a #{unit}-byte unit" unless Qbe::BF_LOAD.key?(unit)
      raise QbeUnsupported, "#{head(x)}: bits #{boff}+#{width} outside the unit" if width < 1 || boff < 0 || boff + width > unit * 8

      [unit, boff, width]
    end

    def bf_type!(ty)
      raise QbeUnsupported, "bit-field of type #{sx(ty)}" unless Qbe::INT_W.include?(ty) || Qbe::INT_L.include?(ty)
    end

    def bfload_lines(dst, rv)
      ty = rv[1]
      bf_type!(ty)
      unit, boff, width = bf_args(rv, 6)
      uc = unit == 8 ? "l" : "w"
      # The field goes to the top of the register (32 or 64 bits), not of the storage unit: a 1- or 2-byte unit then
      # sign-extends from its own top bit.
      rb = uc == "l" ? 64 : 32
      t = fresh
      asan_check(rv[3], op(rv[3]), unit, "load")
      @lines << "  #{t} =#{uc} #{Qbe::BF_LOAD[unit]} #{op(rv[3])}"
      if rb - boff - width > 0
        t2 = fresh
        @lines << "  #{t2} =#{uc} shl #{t}, #{rb - boff - width}"
        t = t2
      end
      signed = Qbe.signed?(ty)
      if rb - width > 0
        t2 = fresh
        @lines << "  #{t2} =#{uc} #{signed ? 'sar' : 'shr'} #{t}, #{rb - width}"
        t = t2
      end
      tc = Qbe.cls(ty)
      if tc != uc
        t2 = fresh
        @lines << (tc == "l" ? "  #{t2} =l #{signed ? 'extsw' : 'extuw'} #{t}" : "  #{t2} =w copy #{t}")
        t = t2
      end
      @lines << "  #{dst} =#{tc} copy #{t}"
    end

    def bfstore_lines(x)
      ty = x[1]
      bf_type!(ty)
      unit, boff, width = bf_args(x, 7)
      uc = unit == 8 ? "l" : "w"
      ub = unit * 8
      tc = Qbe.cls(ty)
      raise QbeUnsupported, "bit-field store of a value of another class" unless Qbe.cls(operand_type(x[6])) == tc

      addr = op(x[3])
      v = op(x[6])
      if tc != uc
        t2 = fresh
        @lines << (uc == "l" ? "  #{t2} =l extuw #{v}" : "  #{t2} =w copy #{v}")
        v = t2
      end
      old = fresh
      asan_check(x[3], addr, unit, "store")
      @lines << "  #{old} =#{uc} #{Qbe::BF_LOAD[unit]} #{addr}"
      # The value is cut to the field in the register width: a unit narrower than the register keeps high bits otherwise.
      rb = uc == "l" ? 64 : 32
      if width < rb
        t2 = fresh
        @lines << "  #{t2} =#{uc} shl #{v}, #{rb - width}"
        v = t2
        if rb - width - boff > 0
          t3 = fresh
          @lines << "  #{t3} =#{uc} shr #{v}, #{rb - width - boff}"
          v = t3
        end
      end
      clear = ((1 << ub) - 1) ^ (((1 << width) - 1) << boff)
      nw = v
      if clear != 0
        keep = fresh
        if boff + width == ub
          # the field is the top of the unit: keep the low bits by a shift pair
          k1 = fresh
          @lines << "  #{k1} =#{uc} shl #{old}, #{rb - boff}"
          @lines << "  #{keep} =#{uc} shr #{k1}, #{rb - boff}"
        elsif boff.zero?
          # the field is the bottom of the unit: keep the high bits by a shift pair
          k1 = fresh
          @lines << "  #{k1} =#{uc} shr #{old}, #{width}"
          @lines << "  #{keep} =#{uc} shl #{k1}, #{width}"
        else
          signed_clear = uc == "w" && clear >= 1 << 31 ? clear - (1 << 32) : clear
          @lines << "  #{keep} =#{uc} and #{old}, #{signed_clear}"
        end
        nw = fresh
        @lines << "  #{nw} =#{uc} or #{keep}, #{v}"
      end
      @lines << "  #{Qbe::BF_STORE[unit]} #{nw}, #{addr}"
    end

    # `(bitcast (ptr T) P)`: a pointer reinterpreted as a pointer keeps its address (the interpreter's rule). Any other
    # reinterpretation is refused: the interpreter does not model it either.
    def bitcast_lines(dst, rv)
      raise QbeUnsupported, "bitcast to #{sx(rv[1])}" unless head(unqual(rv[1])) == "ptr"

      src = rv[2]
      src_type = src.is_a?(String) ? @types[src] : nil
      pointer = src.is_a?(Ref) || (src_type && head(unqual(src_type)) == "ptr") ||
                (src.is_a?(Array) && %w[null addr].include?(head(src)))
      raise QbeUnsupported, "bitcast of #{sx(src)}" unless pointer

      @lines << "  #{dst} =l copy #{op(src)}"
    end

    # `(pdiff A B SIZE)`: (A - B) / SIZE, signed, in the 64-bit pointer difference type (docs/notes/pathb-stage2.md).
    # A VLA element size is a register, which is not a constant here, so it is refused.
    def pdiff_lines(dst, t, rv)
      raise QbeUnsupported, "pdiff of type #{sx(t)}" unless Qbe.cls(t) == "l"

      n = begin
        Qbe.int_lit(rv[3])
      rescue ArgumentError, TypeError
        raise QbeUnsupported, "pdiff with a non-constant element size"
      end
      raise QbeUnsupported, "pdiff with element size 0" if n.zero?

      a = op(rv[1])
      b = op(rv[2])
      d = fresh
      @lines << "  #{d} =l sub #{a}, #{b}"
      @lines << "  #{dst} =l div #{d}, #{n}"
    end

    # `(nonnull P)`: a null pointer traps (code 5).
    def nonnull_lines(p)
      cond = fresh
      @lines << "  #{cond} =w ceql #{op(p)}, 0"
      check_call(cond, 5)
    end

    # `(bounds I N)`: an index outside [0, N) traps (code 6). The unsigned comparison also rejects a negative index.
    def bounds_lines(idx, n)
      # --asan: no trap. A variable-length array is a malloc block of its own under -fsanitize=address
      # (lib/asan/nfcxx_vla_asan.c), and stack and global arrays have redzones (milestones 2 and 3 of docs/notes/asan-plan.md), so
      # libasan reports an access past the end, and the trap would hide that report. As with gcc's ASan, an overflow that stays
      # inside the enclosing object (an array member of a struct) is not reported.
      return if Qbe.asan

      c = Qbe.cls(operand_type(idx))
      i = op(idx)
      # The bound: a typed constant, or a register (a variable-length array's element count) of the index's class, so
      # the unsigned comparison is of equal width.
      bound =
        if n.is_a?(Array) && head(n) == "const"
          Qbe.int_lit(n[2]).to_s
        elsif (n.is_a?(String) && n.start_with?("%")) || expression?(n)
          nc = Qbe.cls(operand_type(n))
          raise QbeUnsupported, "bounds of class #{nc} against an index of class #{c}" unless nc == c

          op(n)
        else
          Qbe.int_lit(n).to_s
        end
      bad = fresh
      @lines << "  #{bad} =w cuge#{c} #{i}, #{bound}"
      check_call(bad, 6)
    end

    def checked_div_lines(dst, t, rv)
      raise QbeUnsupported, "#{head(rv)} of bool" if t == "bool"

      c = Qbe.cls(t)
      w, signed = int_info(t)
      a = op(rv[2])
      b = op(rv[3])
      zero = fresh
      @lines << "  #{zero} =w ceq#{c} #{b}, 0"
      check_call(zero, 1)
      if signed
        lo = fresh
        minus_one = fresh
        both = fresh
        @lines << "  #{lo} =w ceq#{c} #{a}, #{-(1 << (w - 1))}"
        @lines << "  #{minus_one} =w ceq#{c} #{b}, -1"
        @lines << "  #{both} =w and #{lo}, #{minus_one}"
        check_call(both, 2)
      end
      d = const_int_value(rv[3])
      if signed && w == 32 && d && d >= 3 && (d & (d - 1)) != 0 && const_int_value(rv[2]).nil?
        return magic_div32_lines(dst, head(rv) == "crem", a, d)
      end
      name = head(rv) == "cdiv" ? (signed ? "div" : "udiv") : (signed ? "rem" : "urem")
      @lines << "  #{dst} =#{c} #{name} #{a}, #{b}"
    end

    # The value of an integer constant operand as a number, or nil (a register, or a constant that is not an integer literal).
    def const_int_value(x)
      return nil unless x.is_a?(Array) && head(x) == "const"

      int_lit(x[2])
    rescue QbeUnsupported
      nil
    end

    # Signed 32-bit division or remainder by a constant d >= 3 that is not a power of two: no division instruction (Lemire,
    # "Beating the compiler at signed 32-bit division", 2026, https://lemire.me/blog/2026/10/31/beating-the-compiler-at-signed-32-bit-division/).
    # With s = 31 + ceil(log2 d) and c = floor(2^s / d) + 1 (c fits
    # in 32 bits), the quotient is the low 32 bits of ((int64)x * c) >> s, plus 1 when x is negative (x >> 31 is -1). The
    # 64-bit product is below 2^63 in magnitude, so it does not overflow; the whole sequence is exact for every int32 x.
    # The remainder is x - q * d. tests/pathb-ssa-qbe/cases/div_const_signed32.ir checks it against the interpreter.
    def magic_div32_lines(dst, rem, a, d)
      s = 31 + (d - 1).bit_length
      c = (1 << s) / d + 1
      raise QbeUnsupported, "signed division by #{d}: multiplier #{c} is not 32 bits" if c >= (1 << 32)

      wide = fresh
      prod = fresh
      hi64 = fresh
      hi = fresh
      sign = fresh
      @lines << "  #{wide} =l extsw #{a}"
      @lines << "  #{prod} =l mul #{wide}, #{c}"
      @lines << "  #{hi64} =l sar #{prod}, #{s}"
      @lines << "  #{hi} =w copy #{hi64}"
      @lines << "  #{sign} =w sar #{a}, 31"
      q = rem ? fresh : dst
      @lines << "  #{q} =w sub #{hi}, #{sign}"
      return unless rem

      back = fresh
      @lines << "  #{back} =w mul #{q}, #{d}"
      @lines << "  #{dst} =w sub #{a}, #{back}"
    end

    # Checked signed add, sub, mul and negate: the exact result must fit the type, else the check traps (code 2, signed
    # overflow). A narrow type is computed in 64 bits and range-checked, then truncated; an 8-byte add or sub uses the
    # sign-bit identities; an 8-byte multiply asks the runtime (__nfcxx_smul64_ovf, be/nfcxx_ldrt.c) since QBE has no
    # 128-bit product. The IR emits these only for signed types, so an unsigned one is refused (as the flat emitter does).
    def checked_arith_lines(dst, t, rv)
      raise QbeUnsupported, "#{head(rv)} of bool" if t == "bool"

      w, signed = int_info(t)
      a = head(rv) == "cneg" ? "0" : op(rv[2])
      b = head(rv) == "cneg" ? op(rv[2]) : op(rv[3])
      name = { "cadd" => "add", "csub" => "sub", "cneg" => "sub", "cmul" => "mul" }[head(rv)]
      return unsigned_checked_lines(dst, w, name, a, b) unless signed
      if w == 64
        r = fresh
        if name == "mul"
          # The product, and the test that dividing it back by a gives b. A divisor of 0 or -1 would trap (the quotient
          # overflows for -1), so those use 1 instead: 0 never overflows, and -1 overflows only for the minimum b.
          @lines << "  #{r} =l mul #{a}, #{b}"
          zero = fresh
          minus_one = fresh
          special = fresh
          special_l = fresh
          mask = fresh
          divisor = fresh
          masked = fresh
          @lines << "  #{zero} =w ceql #{a}, 0"
          @lines << "  #{minus_one} =w ceql #{a}, -1"
          @lines << "  #{special} =w or #{zero}, #{minus_one}"
          @lines << "  #{special_l} =l extuw #{special}"
          @lines << "  #{mask} =l sub 0, #{special_l}"
          flipped = fresh
          @lines << "  #{flipped} =l xor #{a}, 1"
          @lines << "  #{masked} =l and #{flipped}, #{mask}"
          @lines << "  #{divisor} =l xor #{a}, #{masked}"
          quotient = fresh
          @lines << "  #{quotient} =l div #{r}, #{divisor}"
          differs = fresh
          @lines << "  #{differs} =w cnel #{quotient}, #{b}"
          not_special = fresh
          @lines << "  #{not_special} =w xor #{special}, 1"
          general = fresh
          @lines << "  #{general} =w and #{differs}, #{not_special}"
          min_value = fresh
          @lines << "  #{min_value} =l shl 1, 63"
          min_b = fresh
          @lines << "  #{min_b} =w ceql #{b}, #{min_value}"
          at_minus_one = fresh
          @lines << "  #{at_minus_one} =w and #{minus_one}, #{min_b}"
          bad = fresh
          @lines << "  #{bad} =w or #{general}, #{at_minus_one}"
          check_call(bad, 2)
        else
          @lines << "  #{r} =l #{name} #{a}, #{b}"
          # the overflow of a + b or a - b: the sign of the result differs from the sign the operands imply
          x1 = fresh
          x2 = fresh
          x3 = fresh
          if name == "add"
            @lines << "  #{x1} =l xor #{a}, #{r}"
            @lines << "  #{x2} =l xor #{b}, #{r}"
          else
            @lines << "  #{x1} =l xor #{a}, #{b}"
            @lines << "  #{x2} =l xor #{a}, #{r}"
          end
          @lines << "  #{x3} =l and #{x1}, #{x2}"
          bad = fresh
          @lines << "  #{bad} =w csltl #{x3}, 0"
          check_call(bad, 2)
        end
        @lines << "  #{dst} =l copy #{r}"
      else
        ea = fresh
        eb = fresh
        r = fresh
        @lines << "  #{ea} =l extsw #{a}"
        @lines << "  #{eb} =l extsw #{b}"
        @lines << "  #{r} =l #{name} #{ea}, #{eb}"
        lo = -(1 << (w - 1))
        hi = (1 << (w - 1)) - 1
        below = fresh
        above = fresh
        bad = fresh
        @lines << "  #{below} =w csltl #{r}, #{lo}"
        @lines << "  #{above} =w csgtl #{r}, #{hi}"
        @lines << "  #{bad} =w or #{below}, #{above}"
        check_call(bad, 2)
        @lines << "  #{dst} =w copy #{r}"
      end
    end

    # Checked unsigned add, subtract, multiply and negate (a negate is 0 minus the operand). A narrow type is computed in
    # 64 bits from zero-extended operands and must not exceed its maximum; the 64-bit forms test the wrapped result with
    # unsigned comparisons (an add wraps below an operand, a subtract is a borrow, a multiply divides back).
    def unsigned_checked_lines(dst, w, name, a, b)
      if w < 64
        ea = fresh
        eb = fresh
        r = fresh
        @lines << "  #{ea} =l extuw #{a}"
        @lines << "  #{eb} =l extuw #{b}"
        @lines << "  #{r} =l #{name} #{ea}, #{eb}"
        bad = fresh
        @lines << "  #{bad} =w cugtl #{r}, #{(1 << w) - 1}"
        check_call(bad, 2)
        @lines << "  #{dst} =w copy #{r}"
        return
      end
      r = fresh
      @lines << "  #{r} =l #{name} #{a}, #{b}"
      bad = fresh
      case name
      when "add" then @lines << "  #{bad} =w cultl #{r}, #{a}"        # the sum wrapped below a
      when "sub" then @lines << "  #{bad} =w cultl #{a}, #{b}"        # a borrow: a < b
      else
        # a != 0 and r / a != b, with a divisor of 0 replaced by 1 (0 never overflows)
        zero = fresh
        mask = fresh
        zero_l = fresh
        divisor = fresh
        masked = fresh
        quotient = fresh
        differs = fresh
        @lines << "  #{zero} =w ceql #{a}, 0"
        @lines << "  #{zero_l} =l extuw #{zero}"
        @lines << "  #{mask} =l sub 0, #{zero_l}"
        flipped = fresh
        @lines << "  #{flipped} =l xor #{a}, 1"
        @lines << "  #{masked} =l and #{flipped}, #{mask}"
        @lines << "  #{divisor} =l xor #{a}, #{masked}"
        @lines << "  #{quotient} =l udiv #{r}, #{divisor}"
        @lines << "  #{differs} =w cnel #{quotient}, #{b}"
        not_zero = fresh
        @lines << "  #{not_zero} =w xor #{zero}, 1"
        @lines << "  #{bad} =w and #{differs}, #{not_zero}"
      end
      check_call(bad, 2)
      @lines << "  #{dst} =l copy #{r}"
    end

    # The count must be in [0, w): an unsigned comparison of the count against w also rejects a negative count.
    def checked_shift_lines(dst, t, rv)
      raise QbeUnsupported, "#{head(rv)} of bool" if t == "bool"

      c = Qbe.cls(t)
      w, signed = int_info(t)
      a = op(rv[2])
      count_cls = Qbe.cls(switch_operand_type(rv[3]))
      n = op(rv[3])
      # The count is checked at its own width (a long count such as 0x100000005 must trap, not wrap to 5 when narrowed).
      bad = fresh
      @lines << "  #{bad} =w cuge#{count_cls} #{n}, #{w}"
      check_call(bad, 3)
      if count_cls == "l" && c == "w"
        narrowed = fresh
        @lines << "  #{narrowed} =w copy #{n}"
        n = narrowed
      end
      if %w[cshl wshl].include?(head(rv))
        shifted = fresh
        @lines << "  #{shifted} =#{c} shl #{a}, #{n}"
        canon_lines(dst, t, shifted)
      else
        @lines << "  #{dst} =#{c} #{signed ? 'sar' : 'shr'} #{a}, #{n}"
      end
    end

    # The value of t in its low bits, sign- or zero-extended as the canonical form of t (a cshl wraps to the type).
    def canon_lines(dst, t, src)
      if Qbe::EXT.key?(t)
        @lines << "  #{dst} =w ext#{Qbe::EXT[t]} #{src}"
      else
        @lines << "  #{dst} =#{Qbe.cls(t)} copy #{src}"
      end
    end

    # A call `(call RET &"name" ARG...)`: a direct call of a C symbol. The module's functions are exported under their
    # names, and any other callee is linked as a C function. Each argument is passed with the class of its value.
    # The parts of a call: the sret result (its AbiInfo and destination, or nil), the callee, and the arguments. A byval
    # argument is passed as its aggregate type; an sret argument is the result, not an argument.
    def call_parts(c)
      f = c[2]
      # The callee is a function (its symbol) or a pointer operand (an indirect call).

      sret = nil
      dest = nil
      args = []
      nfixed = nil
      c[3..].each do |a|
        case head(a)
        when "sret"
          raise QbeUnsupported, "sret argument is not the first" unless args.empty? && sret.nil?

          sret = aggregate_info(a[1], "returned")
          dest = op(a[2])
        when "byval"
          info = aggregate_info(a[1], "passed")
          # An empty class is passed as nothing (its argument is dropped, as the callee does not take it).
          args << "#{info.tn} #{op(a[2])}" unless info.shape == "empty"
        when "variadic"
          # (variadic N): the first N arguments are named; QBE takes "..." after them (as pathb-qbe-emit.rb does).
          nfixed = Qbe.int_lit(a[1])
        else args << (Qbe.f16?(arg_type(a)) ? f16_to_sse(op(a)) : "#{arg_cls(a)} #{op(a)}")
        end
      end
      if nfixed
        raise QbeUnsupported, "variadic call with #{nfixed} named arguments but #{args.size}" if nfixed > args.size

        args.insert(nfixed, "...")
      end
      callee = f.is_a?(Ref) && f.sigil == "&" ? "$#{Qbe.symbol(f.raw)}" : op(f)
      sp_call_checks(c, f, sret, callee, args) if Qbe.safe
      [sret, dest, callee, args]
    end

    # --safe (pathb-qbe-emit.rb's call rules): a call through a pointer is checked against the function's signature
    # (__nfcxx_sp_call); a direct call of a block function (SP_MEMFN) checks its pointer arguments over the length.
    def sp_call_checks(c, f, sret, callee, args)
      rcls = sret ? (sret.shape == "empty" ? "" : sret.tn) : (c[1] == "void" ? "" : Qbe.abi_cls(c[1]))
      classes = args.map { |a| a.split(" ", 2)[0] }
      sig = Qbe.sp_sig(@abi, rcls, classes)
      # A call through a pointer that the converter has turned into a direct call (a function address stored in a
      # promoted slot): the callee of the defined function it names must have this signature, or the call is wrong.
      direct_entry = f.is_a?(Ref) && f.sigil == "&" && (Qbe.sp_funcs || []).find { |sym, _| sym == Qbe.symbol(f.raw) }
      if !(f.is_a?(Ref) && f.sigil == "&")
        @lines << "  call $__nfcxx_sp_call(l #{callee}, l #{sig}, #{sp_where})"
      elsif direct_entry && direct_entry[1] != sig
        @lines << "  call $__nfcxx_sp_call(l #{callee}, l #{sig}, #{sp_where})"
      elsif (name = f.raw.delete('"')) && Qbe::SP_MEMFN.key?(name) && args.length == 3 && args[2].start_with?("l ")
        Qbe::SP_MEMFN[name].each do |i|
          @lines << "  call $__nfcxx_sp_check(l #{args[i].split(" ", 2)[1]}, l #{args[2].split(" ", 2)[1]}, #{sp_where})"
        end
      end
    end

    # __atomic_fetch_add_N and __atomic_fetch_sub_N (N = 4 or 8, be/nfcxx_ir.c lowers every atomic to a call): a locked xadd (QBE's xadd op, amd64 lock xadd). Only without --safe, which checks the calls.
    # (Plain string tests: the bundled script runs under mruby, which has no regular expressions.)
    ATOMIC_FETCH_PREFIX = "__atomic_fetch_"

    # [op, size] of a __atomic_fetch_{add,sub}_{4,8} call, or nil.
    def atomic_fetch_kind(c)
      f = c[2]
      return nil if Qbe.safe || !f.is_a?(Ref) || f.sigil != "&" || c.length != 6
      name = f.raw.delete('"')
      return nil unless name.start_with?(ATOMIC_FETCH_PREFIX)
      rest = name[ATOMIC_FETCH_PREFIX.length..]
      op = rest[0, 3]
      size = rest[4..]
      return nil unless rest[3] == "_" && (op == "add" || op == "sub") && (size == "4" || size == "8")
      [op, size]
    end

    # On with the fork's xadd of 3rd/qbe a5fa6c2 or later: the old value is in the result's register (the isel), a load is not forwarded
    # across the locked add (load.c), and the add is kept when its old value is unused (a shared_ptr's count). Before them the
    # lowering read a stale register (tests/cases/qbe_atomics.cpp, tests/pathb-qbe/cases/gaps_atomic.cpp), and was off.
    ATOMIC_XADD = true

    def atomic_fetch?(c)
      return false unless ATOMIC_XADD
      return false unless atomic_fetch_kind(c)
      order = c[5]
      # Any memory order: a locked xadd is a full barrier, so it satisfies relaxed, acquire, release, acq_rel and seq_cst alike
      # (libstdc++'s shared_ptr counts use acq_rel, 4).
      head(order) == "const" && %w[0 1 2 3 4 5].include?(order[2].to_s)
    end

    # __atomic_load_N (N = 1, 2, 4 or 8): a plain load, which on x86 is already acquire (and sequentially consistent with the
    # locked stores and exchanges the lowering uses). Only without --safe.
    ATOMIC_LOAD = %w[__atomic_load_1 __atomic_load_2 __atomic_load_4 __atomic_load_8].freeze
    ATOMIC_LOAD_OP = { "1" => "w loadub", "2" => "w loaduh", "4" => "w loadw", "8" => "l loadl" }.freeze

    def atomic_load?(c)
      f = c[2]
      return false if Qbe.safe || !f.is_a?(Ref) || f.sigil != "&"
      return false unless ATOMIC_LOAD.include?(f.raw.delete('"')) && c.length == 5

      head(c[4]) == "const" && %w[0 1 2 3 4 5].include?(c[4][2].to_s)
    end

    # __atomic_store_N (N = 1, 2, 4, 8) with a constant order: a plain store, which on x86 is already a release store. A
    # sequentially consistent store (order 5) needs a full barrier after it: a locked add of 0 (xadd) on the object, or for 1 and
    # 2 bytes on the aligned 4-byte word that holds it (adding 0 changes no byte; the word is in the object's page).
    ATOMIC_STORE_OP = { "1" => "storeb", "2" => "storeh", "4" => "storew", "8" => "storel" }.freeze

    def atomic_store?(c)
      f = c[2]
      return false unless ATOMIC_XADD
      return false if Qbe.safe || !f.is_a?(Ref) || f.sigil != "&" || c.length != 6

      name = f.raw.delete('"')
      return false unless name.start_with?("__atomic_store_") && ATOMIC_STORE_OP.key?(name[-1])

      order = c[5]
      return false unless head(order) == "const"

      o = order[2].to_s
      return true if o == "0" || o == "3"

      o == "5"
    end

    def atomic_store_lines(c)
      size = c[2].raw.delete('"')[-1]
      addr = op(c[3])
      @lines << "  #{ATOMIC_STORE_OP[size]} #{op(c[4])}, #{addr}"
      return unless c[5][2].to_s == "5"

      if size == "1" || size == "2"
        word = fresh
        @lines << "  #{word} =l and #{addr}, -4"
        @lines << "  #{fresh} =w xadd #{word}, 0"
      else
        @lines << "  #{fresh} =#{size == "4" ? "w" : "l"} xadd #{addr}, 0"
      end
    end

    def atomic_fetch_lines(dst, cls, c)
      op, size = atomic_fetch_kind(c)
      w = size == "4" ? "w" : "l"
      addr = op(c[3])
      val = op(c[4])
      if op == "sub"
        neg = fresh
        @lines << "  #{neg} =#{w} sub 0, #{val}"
        val = neg
      end
      @lines << "  #{dst} =#{w} xadd #{addr}, #{val}"
    end

    def call_text(c)
      sret, _dest, sym, args = call_parts(c)
      raise QbeUnsupported, "a call with an aggregate result used as a value" if sret

      "call #{sym}(#{args.join(', ')})"
    end

    # The type of a call argument, or nil for an address.
    def arg_type(a)
      case a
      when String then @types[a]
      when Array
        case head(a)
        when "addr", "null" then nil
        when "const" then a[1]
        else Qbe.expr_type(a)
        end
      end
    end

    # A _Float16 pattern (w) as the SSE value of the C convention: `s TEMP`, the pattern in the low 16 bits.
    def f16_to_sse(v)
      t = fresh
      @lines << "  #{t} =s cast #{v}"
      "s #{t}"
    end

    # dst (w) := the _Float16 pattern in the low 16 bits of the SSE value src; the upper bits are not defined (a gcc callee
    # or caller leaves what it likes there).
    def f16_from_sse(dst, src)
      raw = fresh
      @lines << "  #{raw} =w cast #{src}"
      @lines << "  #{dst} =w and #{raw}, 65535"
    end

    # A call of the helper __nfcxx_f16_NAME on the given typed operands (`w X`, `l X`, `d X`); the result is a w.
    def f16_call(dst, name, args, rcls = "w")
      @lines << "  #{dst} =#{rcls} call $__nfcxx_f16_#{name}(#{args.join(', ')})"
    end

    def arg_cls(a)
      case a
      when Ref then "l"
      when String then Qbe.cls(@types.fetch(a) { raise QbeUnsupported, "argument #{a} has no declared type" })
      when Array
        case head(a)
        when "addr", "null" then "l"
        when "const" then Qbe.cls(a[1])
        else Qbe.cls(Qbe.expr_type(a))
        end
      else raise QbeUnsupported, "argument #{sx(a)}"
      end
    end

    def float_type?(t) = Qbe.float?(t)

    # The type of an operand: a literal's own type, or the type of a register or an expression.
    def source_type(x)
      return x[1] if x.is_a?(Array) && head(x) == "const"
      return switch_operand_type(x) if expression?(x) || x.is_a?(Array)

      @types.fetch(x) { raise QbeUnsupported, "untyped operand #{sx(x)}" }
    end

    # An integer to a float: the IEEE conversion of the integer, rounded once to the target (as the interpreter's
    # conversion of an integer up to 2**53 is). The conversion follows the signedness of the source type.
    def int_to_float_lines(dst, t, x)
      src = source_type(x)
      if Qbe.f16?(t)
        # Rounded once from the exact integer (from_s64 and from_u64 of be/nfcxx_ldrt.c): a narrow one is widened first.
        signed = Qbe.signed?(src)
        v = op(x)
        if Qbe.cls(src) == "w"
          wide = fresh
          @lines << "  #{wide} =l #{signed ? 'extsw' : 'extuw'} #{v}"
          v = wide
        end
        f16_call(dst, signed ? "from_s64" : "from_u64", ["l #{v}"])
        return
      end
      raise QbeUnsupported, "integer to float of a float" if float_type?(src)

      name = { ["w", true] => "swtof", ["w", false] => "uwtof", ["l", true] => "sltof", ["l", false] => "ultof" }
             .fetch([Qbe.cls(src), Qbe.signed?(src)]) { raise QbeUnsupported, "integer to float of #{sx(src)}" }
      @lines << "  #{dst} =#{Qbe.cls(t)} #{name} #{op(x)}"
    end

    # A float to a float of another precision: a rounding to single (truncd) or an exact widening (exts).
    def float_conv_lines(dst, t, x)
      src = unqual(source_type(x))
      t = unqual(t)
      raise QbeUnsupported, "float conversion of an integer" unless float_type?(src) || Qbe.f16?(src)

      if Qbe.f16?(t) || Qbe.f16?(src)
        v = op(x)
        if Qbe.f16?(src) && Qbe.f16?(t)
          @lines << "  #{dst} =w copy #{v}"
        elsif Qbe.f16?(src) # exact in double, then to the target
          if t == "float"
            d = fresh
            @lines << "  #{d} =d call $__nfcxx_f16_to_f64(w #{v})"
            @lines << "  #{dst} =s truncd #{d}"
          else
            @lines << "  #{dst} =d call $__nfcxx_f16_to_f64(w #{v})"
          end
        else # to half from double (a float is widened first: exact)
          if src == "float"
            d = fresh
            @lines << "  #{d} =d exts #{v}"
            v = d
          end
          f16_call(dst, "from_f64", ["d #{v}"])
        end
        return
      end
      if t == src
        @lines << "  #{dst} =#{Qbe.cls(t)} copy #{op(x)}"
      elsif t == "float"
        @lines << "  #{dst} =s truncd #{op(x)}"
      else
        @lines << "  #{dst} =d exts #{op(x)}"
      end
    end

    # A float to an integer, truncating toward zero. The interpreter traps on NaN, an infinity, or a value outside the
    # target type. The check is an exact range test: the truncated value is in [lo, hi] exactly when x is in
    # (lo - 1, hi + 1), and a float source is first widened to double so that the bounds are exact. The check is a
    # call `pathb_check(cond, 4)` before the conversion, like the integer checks: the runtime does not return when the
    # operand is bad, so no block is split.
    def float_to_int_lines(dst, t, x)
      src = source_type(x)
      raise QbeUnsupported, "float to integer of #{sx(src)}" unless float_type?(src) || Qbe.f16?(src)
      raise QbeUnsupported, "float to bool" if t == "bool"

      w, signed = int_info(t)
      xv = op(x)
      if Qbe.f16?(src)
        # Exact in double: the checks and the conversion are those of a double.
        d = fresh
        @lines << "  #{d} =d call $__nfcxx_f16_to_f64(w #{xv})"
        xv = d
        src = "double"
      end
      if src == "float"
        widened = fresh
        @lines << "  #{widened} =d exts #{xv}"
        xv = widened
      end
      lower = if signed && w == 64 then ["cged", -(2**63)]
              elsif signed then ["cgtd", -(2**(w - 1)) - 1]
              else ["cgtd", -1]
              end
      upper = ["cltd", signed ? 2**(w - 1) : 2**w]
      tests = [lower, upper].map do |cmp, bound|
        tmp = fresh
        @lines << "  #{tmp} =w #{cmp} #{xv}, #{Qbe.float_lit('double', bound.to_f.to_s)}"
        tmp
      end
      ok = fresh
      @lines << "  #{ok} =w and #{tests[0]}, #{tests[1]}"
      bad = fresh
      @lines << "  #{bad} =w ceqw #{ok}, 0"
      check_call(bad, 4)
      @lines << "  #{dst} =#{Qbe.cls(t)} #{signed ? 'dtosi' : 'dtoui'} #{xv}"
    end
  end

  AbiInfo = Struct.new(:tn, :size, :align, :shape, :why)
  LEAF_BYTES = { "b" => 1, "h" => 2, "w" => 4, "l" => 8, "s" => 4, "d" => 8 }.freeze

  def name_of(x) = x.is_a?(Ref) ? x.raw : x.to_s

  # The QBE type declarations of the module's abi-type forms, and the AbiInfo of each by name. The shapes are those of
  # scripts/pathb-qbe-emit.rb (declare_abi_type): the leaves of a struct, a memory class, an empty one, or an unsupported
  # one (its reason is kept; a use of it is refused).
  def abi_types(forms)
    abi = {}
    decls = []
    forms.each do |f|
      next unless head(f) == "abi-type"

      name = name_of(f[1])
      size = int_lit(f[2])
      align = int_lit(f[3])
      raise QbeUnsupported, "abi-type #{name}: alignment #{align}" unless [1, 2, 4, 8, 16].include?(align)

      spec = f[4]
      tn = ":ty#{abi.size}"
      case head(spec)
      when "memory"
        decls << "type #{tn} = align #{align} { #{size} }"
        abi[name] = AbiInfo.new(tn, size, align, "memory", nil)
      when "empty"
        abi[name] = AbiInfo.new(tn, size, align, "empty", nil)
      when "unsupported"
        abi[name] = AbiInfo.new(tn, size, align, "unsupported", name_of(spec[1]).delete('"'))
      when "leaf"
        parts = []
        cur = 0
        f.drop(4).each do |lf|
          raise QbeUnsupported, "abi-type #{name}: bad leaf" unless head(lf) == "leaf" && lf.length == 3

          off = int_lit(lf[1])
          k = lf[2]
          raise QbeUnsupported, "abi-type #{name}: leaf kind" unless k.is_a?(String) && LEAF_BYTES.key?(k)

          ks = LEAF_BYTES[k]
          raise QbeUnsupported, "abi-type #{name}: leaf at #{off} out of order" if off < cur
          raise QbeUnsupported, "abi-type #{name}: member at #{off} is not aligned" if off % ks != 0

          parts << "b #{off - cur}" if off > cur
          parts << k
          cur = off + ks
        end
        raise QbeUnsupported, "abi-type #{name}: leaves exceed the size" if cur > size

        parts << "b #{size - cur}" if size > cur
        decls << "type #{tn} = align #{align} { #{parts.join(", ")} }"
        abi[name] = AbiInfo.new(tn, size, align, "leaves", nil)
      else raise QbeUnsupported, "abi-type #{name}: unknown shape"
      end
    end
    [abi, decls]
  end

  # The data of the module's globals, then the functions. A global the emitter cannot model is left out, and a
  # reference to it raises QbeUnsupported where it is used.
  # The file names of the checks' reports: one NUL-terminated byte array for each (pathb-qbe-emit.rb's data).
  def ubfile_data(link)
    (link[:ubfiles] || {}).map do |file, i|
      "data $__nfcxx_ubf#{i} = { #{(file.bytes + [0]).map { |c| "b #{c}" }.join(", ")} }"
    end
  end

  # ---- general x86 inline assembly (be/nfcxx_ir.c's asm-block) ----------------------------------------------------------
  # The registers: each 64-bit name with its 32-, 16- and 8-bit names. r11 is the base of the operand block and rbp the
  # frame of the helper, so neither is an operand's register; the helper saves every callee-saved register it uses.
  ASM_REGS = {
    "rax" => %w[rax eax ax al], "rbx" => %w[rbx ebx bx bl], "rcx" => %w[rcx ecx cx cl], "rdx" => %w[rdx edx dx dl],
    "rsi" => %w[rsi esi si sil], "rdi" => %w[rdi edi di dil], "r8" => %w[r8 r8d r8w r8b], "r9" => %w[r9 r9d r9w r9b],
    "r10" => %w[r10 r10d r10w r10b], "r12" => %w[r12 r12d r12w r12b], "r13" => %w[r13 r13d r13w r13b],
    "r14" => %w[r14 r14d r14w r14b], "r15" => %w[r15 r15d r15w r15b]
  }.freeze
  ASM_FIXED = { "a" => "rax", "b" => "rbx", "c" => "rcx", "d" => "rdx", "S" => "rsi", "D" => "rdi" }.freeze
  ASM_POOL = %w[rax rcx rdx rsi rdi r8 r9 r10 r12 r13 r14 r15 rbx].freeze
  ASM_SAVED = %w[rbx r12 r13 r14 r15].freeze
  ASM_XMM = %w[xmm0 xmm1 xmm2 xmm3 xmm4 xmm5 xmm6 xmm7].freeze # caller-saved on SysV: the helper saves none

  # The helper for one general template: it reads each operand from the operand block (rdi, eight bytes an operand),
  # runs the template with the operands' registers, and writes the outputs back. ops are {kind:, code:, size:, arg:} in
  # gcc's order (kind: in, out, inout or mem; code: a register letter, a digit for a tied operand, or m). Returns
  # [symbol, assembly text]. Raises QbeUnsupported for a template or an operand outside this helper.
  # A tied operand's code: a single digit (/\A\d\z/).
  def self.tied_code?(code) = code.size == 1 && DIGITS.include?(code)

  ASM_FLAG_CONDS = %w[a ae b be c e z g ge l le o p s na nae nb nbe nc ne ng nge nl nle no np ns nz pe po].freeze
  ASM_NOREG = %w[imm sym].freeze

  # An operand's text in the template: letter is the modifier (b w k q c P n a, or empty).
  def self.asm_operand_text(o, reg, letter)
    case o[:kind]
    when "imm"
      raise QbeUnsupported, "asm: modifier %#{letter} on an immediate" if letter == "a"

      return (letter == "c" || letter == "P" ? o[:imm].to_s : letter == "n" ? (-o[:imm]).to_s : "$#{o[:imm]}")
    when "sym"
      txt = o[:off].zero? ? o[:sym] : "#{o[:sym]}#{o[:off] > 0 ? "+" : ""}#{o[:off]}"
      return "#{txt}(%rip)" if letter == "a"
      return txt if letter == "c" || letter == "P"

      return "$#{txt}"
    when "flag"
      raise QbeUnsupported, "asm: a flag output named in the template"
    end
    return "(%#{reg})" if o[:code] == "m" || letter == "a"
    return "%#{reg}" if o[:code] == "x"
    raise QbeUnsupported, "asm: modifier %#{letter} on a register" if letter == "c" || letter == "P" || letter == "n"

    size = { "b" => 1, "w" => 2, "k" => 4, "q" => 8 }.fetch(letter) { o[:size] }
    slot = { 8 => 0, 4 => 1, 2 => 2, 1 => 3 }.fetch(size) { raise QbeUnsupported, "asm: operand size #{size}" }
    "%#{ASM_REGS.fetch(reg)[slot]}"
  end

  def self.asm_block(hex, ops, clobbers = [], labels = [])
    tpl = [hex].pack("H*")
    regs = Array.new(ops.size)
    used = {}
    clob = {}
    clobbers.each do |c|
      r = c == "ax" ? "rax" : c == "bx" ? "rbx" : c == "cx" ? "rcx" : c == "dx" ? "rdx" : c == "si" ? "rsi" : c == "di" ? "rdi" : c
      raise QbeUnsupported, "asm: clobber of #{c}" unless r == "r11" || ASM_REGS.key?(r)

      clob[r] = true
    end
    ops.each_with_index do |o, i|
      next unless (r = ASM_FIXED[o[:code]])

      regs[i] = r
      used[r] = true
    end
    xfree = ASM_XMM.dup
    ops.each_with_index do |o, i|
      next unless o[:code] == "x"

      raise QbeUnsupported, "asm: more SSE operands than registers" if xfree.empty?

      regs[i] = xfree.shift
    end
    free = ASM_POOL.reject { |r| used[r] || clob[r] }
    ops.each_with_index do |o, i|
      next if regs[i] || tied_code?(o[:code]) || ASM_NOREG.include?(o[:kind])
      raise QbeUnsupported, "asm: more operands than registers" if free.empty?

      regs[i] = o[:kind] == "flag" ? free.pop : free.shift
    end
    ops.each_with_index do |o, i|
      next unless tied_code?(o[:code])

      src = o[:code].to_i
      raise QbeUnsupported, "asm: a tied operand names operand #{src}" if src >= ops.size || src == i
      raise QbeUnsupported, "asm: a tied operand names an operand with no register" if regs[src].nil?

      regs[i] = regs[src]
    end
    ops.each do |o|
      raise QbeUnsupported, "asm: flag condition #{o[:code]}" if o[:kind] == "flag" && !ASM_FLAG_CONDS.include?(o[:code])
    end
    # asm goto: the last operand (gsel) is the cell for the number of the label left by; it is not numbered in the template.
    nreal = ops.count { |o| o[:kind] != "gsel" }
    parts = []
    body = +""
    i = 0
    while i < tpl.size
      if tpl[i] != "%"
        body << tpl[i]
        i += 1
        next
      end
      if tpl[i + 1] == "%"
        body << "%"
        i += 2
        next
      end
      if tpl[i + 1] == "="
        body << "0"
        i += 2
        next
      end
      # %[MODIFIER](DIGITS | [NAME]) at i
      j = i + 1
      letter = %w[b w k q c P n a l].include?(tpl[j]) ? tpl[j] : ""
      j += letter.size
      idx = nil
      if tpl[j] == "["
        close = j + 1
        close += 1 while close < tpl.size && tpl[close] != "]"
        raise QbeUnsupported, "asm template: an unterminated %[name]" if close >= tpl.size

        nm = tpl[j + 1...close]
        if letter == "l"
          idx = labels.index(nm)
          raise QbeUnsupported, "asm template: no label named #{nm}" if idx.nil? || nm.empty?

          idx += nreal
        else
          idx = ops.index { |o| o[:name] == nm }
          raise QbeUnsupported, "asm template: no operand named #{nm}" if idx.nil? || nm.empty?
        end

        k = close + 1
      else
        k = j
        k += 1 while k < tpl.size && DIGITS.include?(tpl[k])
        raise QbeUnsupported, "asm template: a % that is not an operand (#{tpl[i, 3].inspect})" if k == j

        idx = tpl[j...k].to_i
      end
      if letter == "l"
        raise QbeUnsupported, "asm template: label #{idx - nreal} of #{labels.size}" if idx < nreal || idx - nreal >= labels.size

        parts << body << [idx - nreal + 1]
        body = +""
        i = k
        next
      end
      raise QbeUnsupported, "asm template: operand #{idx} of #{nreal}" if idx >= nreal

      body << asm_operand_text(ops[idx], regs[idx], letter)
      i = k
    end
    parts << body
    flat = parts.map { |x| x.is_a?(Array) ? "<L#{x[0]}>" : x }.join
    digest = sha1_hex("#{hex}|#{ops.map { |o| [o[:kind], o[:code], o[:size]].join(",") }.join(";")}|#{clobbers.join(",")}|#{labels.join(",")}|#{flat}")[0, 12]
    sym = "__pathb_asm_#{digest}"
    body = parts.map { |x| x.is_a?(Array) ? ".L#{sym}_#{x[0]}" : x }.join
    lines = [".text", ".weak #{sym}", ".type #{sym}, @function", "#{sym}:", "\tpushq %rbp", "\tmovq %rsp, %rbp"]
    ASM_SAVED.each { |r| lines << "\tpushq %#{r}" }
    # 6 pushes and the return address leave %rsp 8 mod 16: 24 more bytes make it 16-aligned for a call in the template.
    lines << "\tsubq $24, %rsp" << "\tmovq %rdi, -48(%rbp)" << "\tmovq -48(%rbp), %r11"
    ops.each_with_index do |o, i|
      if %w[in inout mem].include?(o[:kind])
        lines << (o[:code] == "x" ? "\t#{o[:size] == 4 ? "movss" : "movsd"} #{8 * i}(%r11), %#{regs[i]}" : "\tmovq #{8 * i}(%r11), %#{regs[i]}")
      end
    end
    ops.each_with_index do |o, i|
      lines << "\tmovl $0, %#{ASM_REGS.fetch(regs[i])[1]}" if o[:kind] == "gsel"
    end
    lines << body.chomp
    ops.each_with_index do |o, i|
      next unless o[:kind] == "flag"

      lines << "\tset#{o[:code]} %#{ASM_REGS.fetch(regs[i])[3]}" << "\tmovzbl %#{ASM_REGS.fetch(regs[i])[3]}, %#{ASM_REGS.fetch(regs[i])[1]}"
    end
    lines << ".L#{sym}_exit:" unless labels.empty?
    lines << "\tmovq -48(%rbp), %r11"
    ops.each_with_index do |o, i|
      next unless %w[out inout flag gsel].include?(o[:kind])

      lines << (o[:code] == "x" ? "\t#{o[:size] == 4 ? "movss" : "movsd"} %#{regs[i]}, #{8 * i}(%r11)" : "\tmovq %#{regs[i]}, #{8 * i}(%r11)")
    end
    lines << "\tleaq -#{8 * ASM_SAVED.size}(%rbp), %rsp"
    lines.concat(ASM_SAVED.reverse.map { |r| "\tpopq %#{r}" })
    lines << "\tpopq %rbp" << "\tret"
    gi = ops.index { |o| o[:kind] == "gsel" }
    labels.each_with_index do |_, li|
      lines << ".L#{sym}_#{li + 1}:" << "\tmovl $#{li + 1}, %#{ASM_REGS.fetch(regs[gi])[1]}" << "\tjmp .L#{sym}_exit"
    end
    lines << ".size #{sym}, .-#{sym}"
    [sym, lines.join("\n") + "\n"]
  end

  # The helpers of a module, as marker lines the driver turns into assembly (scripts/pathb-ssa-build's marker_asm).
  def self.asm_text_markers(link)
    (link[:asm_texts] || {}).values.map { |text| "# pathb-text #{[text].pack("m0")}" }.join("\n")
  end

  def module_il(forms)
    ctx = module_context(forms)
    emitted = forms.select { |f| head(f) == "ssa-function" }.map { |f| Fn.new(f, ctx[:refs], ctx[:abi], ctx[:link]).emit }
    helpers = emitted.flat_map(&:asm_helpers).uniq.map { |h| "# pathb-asm #{h}" }
    (ctx[:data] + helpers + emitted.map { |fn| (fn.dbg_file ? "dbgfile #{fn.dbg_file.inspect}\n\n" : "") + fn.lines.join("\n") } + ubfile_data(ctx[:link]) + [Qbe.asm_text_markers(ctx[:link])]).join("\n\n") + "\n"
  end

  # The part of a module that every function shares: the data of its globals and the references a function may make
  # to them. Built once, so a driver that emits function by function does not redo the globals for each function.
  # The volatile access helpers: one function per load and store operation. QBE has no volatile, so a volatile access is
  # a call of one of these (a call is kept in order and neither merged nor removed), as pathb-qbe-emit.rb does.
  VOLATILE_LOADS = %w[loadub loadsb loadsh loaduh loadsw loaduw loadl loads loadd].freeze
  VOLATILE_STORES = %w[storeb storeh storew storel stores stored].freeze

  # The type without its const and volatile qualifiers: they are access properties, not part of the value's class.
  # _Float32x (ISO/IEC TS 18661-3) is an IEEE binary64 type: on x86-64 it is double, so it is emitted as one.
  def unqual(t)
    t = t[1] while head(t) == "const"
    return unqual(t[1]) if head(t) == "volatile"
    t == "_Float32x" ? "double" : t
  end

  def volatile_name(kind, op_name) = "__pathb_v#{kind}_#{op_name}"

  # The class of the value a store writes, for its volatile helper.
  def store_class(op_name)
    { "storel" => "l", "stores" => "s", "stored" => "d" }.fetch(op_name, "w")
  end

  # The helpers' text, emitted once in a module that has a volatile access.
  def volatile_helpers
    loads = VOLATILE_LOADS.flat_map do |op_name|
      cls = { "loadl" => "l", "loads" => "s", "loadd" => "d" }.fetch(op_name, "w")
      ["function #{cls} $#{volatile_name("ld", op_name)}(l %p) {", "@start", "\t%v =#{cls} #{op_name} %p",
       "\tret %v", "}", ""]
    end
    stores = VOLATILE_STORES.flat_map do |op_name|
      cls = store_class(op_name)
      ["function $#{volatile_name("st", op_name)}(l %p, #{cls} %v) {", "@start", "\t#{op_name} %v, %p", "\tret", "}", ""]
    end
    (loads + stores).join("\n")
  end

  # Whether a module has a volatile access (a load.v or store.v, or a volatile type): then its helpers are emitted.
  def uses_volatile?(forms)
    walk = lambda do |x|
      next false unless x.is_a?(Array)
      next true if %w[load.v store.v volatile].include?(head(x))

      x.any? { |y| walk.call(y) }
    end
    forms.any? { |f| walk.call(f) }
  end

  # --safe: the signature hash of a function or of a call through a pointer (pathb-qbe-emit.rb's sp_sig): the return class
  # and the parameter classes up to a "...", with an aggregate's ABI type replaced by its size and alignment, then FNV-1a.
  def sp_sig(abi, rcls, classes)
    canon = lambda do |c|
      next c unless c.start_with?(":")

      a = abi.values.find { |t| t.tn == c }
      a.nil? ? c : "a#{a.size}.#{a.align}"
    end
    text = canon.call(rcls) + "("
    classes.each do |c|
      text += canon.call(c) + ","
      break if c == "..."
    end
    h = 0x811c9dc5
    text.each_byte { |b| h = ((h ^ b) * 0x01000193) & 0xffffffff }
    h
  end

  # --safe: the return class and the parameter classes of a defined function (the header's rules, without emitting it).
  def sp_entry_sig(form, abi)
    ret = form.find { |x| head(x) == "ret" }
    params = form.find { |x| head(x) == "params" }.drop(1)
    sret = params.find { |p| head(p) == "sret" }
    classes = []
    params.each do |p|
      case head(p)
      when "param"
        if head(p[3]) == "byval"
          info = abi[name_of(p[3][1][1])]
          raise QbeUnsupported, "by-value aggregate has no abi-type" if info.nil?

          classes << info.tn unless info.shape == "empty"
        else
          classes << cls(p[3])
        end
      when "ellipsis" then classes << "..."
      end
    end
    rcls = if sret
             info = abi[name_of(sret[2][1])]
             raise QbeUnsupported, "returned aggregate has no abi-type" if info.nil?

             info.shape == "empty" ? "" : info.tn
           elsif ret[1] == "void"
             ""
           else
             cls(ret[1])
           end
    [rcls, classes]
  end

  def module_context(forms)
    gs = forms.select { |g| head(g) == "global" }
    self.module_has_data = forms.any? { |f| %w[global data].include?(head(f)) }
    self.sp_objects = []
    self.asan_objects = []
    by_name = gs.to_h { |g| [g[1].raw, g] }
    state = {}
    abi, type_decls = abi_types(forms)
    # --safe: every defined function, with its signature, for the checks of calls through pointers (pathb-qbe-emit.rb's
    # mod.sp_funcs; a long double function's name starts with __nfcxx_ldr_ and is not registered).
    self.sp_funcs = !safe ? [] : forms.select { |f| head(f) == "ssa-function" && !f[1].raw.delete('"').start_with?("__nfcxx_ldr_") }
                                      .filter_map do |f|
                                        # A function the emitter refuses is not emitted, so it needs no table row.
                                        [symbol(f[1].raw), sp_sig(abi, *sp_entry_sig(f, abi))]
                                      rescue QbeUnsupported
                                        nil
                                      end
    # The bytes of string literals: a top-level (data NAME TYPE (string ...)) form, copied into an array by a
    # (bytes OFF N @"NAME") initializer item. A string the emitter cannot express is left out, so a reference to it
    # is refused where it is used.
    strs = forms.select { |f| head(f) == "data" }
    string_decls = strs.filter_map do |d|
      by_name[d[1].raw] = d
      bytes, decl = string_data(d)
      state[[:bytes, d[1].raw]] = bytes
      state[d[1].raw] = decl
      decl
    rescue QbeUnsupported
      nil
    end
    global_decls = gs.filter_map do |g|
      d = global_data(g, by_name, state)
      d if d.is_a?(String)
    end
    data = type_decls + string_decls + global_decls
    data << volatile_helpers if uses_volatile?(forms)
    data.concat(sp_constructor) if Qbe.safe && !(Qbe.sp_objects.empty? && Qbe.sp_funcs.empty?)
    data.concat(asan_constructor) if Qbe.asan && !Qbe.asan_objects.empty?
    # What a function may reference: an emitted global, or an extern one (its symbol is linked in).
    flags = gs.to_h { |g| [g[1].raw, global_flags(g)] }
    refs = {} # (a loop: Hash#to_h in the script world's mruby ignores its block)
    flags.each do |name, f|
      next unless state[name].is_a?(String) || state[name] == :extern

      refs[name] = { thread: f.include?("thread"), weak: f.include?("weak"), extern: f.include?("extern") }
    end
    strs.each do |d|
      name = d[1].raw
      refs[name] = { thread: false, weak: false, extern: false } if state[name].is_a?(String)
    end
# The functions this module defines, and the external functions it takes the address of as a value (not a direct
# call, which goes through the PLT): each gets one pointer cell, defined once here.
funcs = {}   # a Hash (symbol => true): every & reference looks it up, and a list was searched linearly
forms.each { |f| funcs[Qbe.symbol(f[1].raw)] = true if head(f) == "ssa-function" }
cells = []
cell_seen = {}
collect = lambda do |x|
  next unless x.is_a?(Array) || x.is_a?(Ref)
  if x.is_a?(Ref)
    if x.sigil == "&"
      sym = Qbe.symbol(x.raw)
      unless funcs.key?(sym) || cell_seen.key?(sym)
        cell_seen[sym] = true
        cells << sym
      end
    end
    next
  end
  if head(x) == "call" && x[2].is_a?(Ref) && x[2].sigil == "&"
    x[3..].each { |a| collect.call(a) }
  else
    x.each { |y| collect.call(y) }
  end
end
forms.select { |f| head(f) == "ssa-function" }.each { |f| collect.call(f) }
data += cells.map { |sym| "data $pathb_got.#{sym} = align 8 { l $#{sym} }" }
{ data: data, refs: refs, abi: abi, link: { funcs: funcs, cells: cells, ubfiles: {} } }
  end

  # --safe: the table of the module's globals and strings, and the constructor that registers them (pathb-qbe-emit.rb's
  # sp_globals_ctor, at priority 101 as the emitter does). The module's function table is slice 4.
  def sp_constructor
    out = []
    unless Qbe.sp_objects.empty?
      rows = Qbe.sp_objects.map { |q, n| "l $#{q}, l #{n}" }.join(", ")
      out << "data $__nfcxx_sp_gtab = align 8 { #{rows} }"
    end
    unless Qbe.sp_funcs.empty?
      rows = Qbe.sp_funcs.map { |q, n| "l $#{q}, l #{n}" }.join(", ")
      out << "data $__nfcxx_sp_ftab = align 8 { #{rows} }"
    end
    calls = []
    calls << "\tcall $__nfcxx_sp_globals(l $__nfcxx_sp_gtab, l #{Qbe.sp_objects.length})" unless Qbe.sp_objects.empty?
    calls << "\tcall $__nfcxx_sp_funcs(l $__nfcxx_sp_ftab, l #{Qbe.sp_funcs.length})" unless Qbe.sp_funcs.empty?
    out << "function $__nfcxx_sp_gctor() {\n@start\n#{calls.join("\n")}\n\tret\n}"
    out << "# pathb-startup .init_array 101 __nfcxx_sp_gctor"
  end

  # --asan: the constructor that poisons the redzone after each global and string of the module (milestone 3 of
  # docs/notes/asan-plan.md; at priority 101 as the safe-pointers one is, after libasan's own start in the preinit array).
  def asan_constructor
    calls = Qbe.asan_objects.each_with_index.flat_map do |(sym, osz), i|
      ["\t%g#{i} =l add $#{sym}, #{osz}", "\tcall $__asan_poison_memory_region(l %g#{i}, l #{Qbe::ASAN_RZ})"]
    end
    ["function $__nfcxx_asan_gctor() {\n@start\n#{calls.join("\n")}\n\tret\n}",
     "# pathb-startup .init_array 101 __nfcxx_asan_gctor"]
  end

  # The bytes of a string literal and its data line: its bytes, then zeros up to the array's size (as the existing
  # emitter writes them, pathb-qbe-emit.rb's emit_string). Only a char array is emitted.
  def string_data(d)
    name = d[1].raw
    ty = d[2]
    raise QbeUnsupported, "string #{name} is not a char array" unless head(unqual(ty)) == "array"
    # A wide string (an array of 2- or 4-byte elements) carries its encoding in the bytes: the same rule, aligned to its element.
    elem = size(unqual(ty)[2])
    raise QbeUnsupported, "string #{name} has elements of #{elem} bytes" unless [1, 2, 4].include?(elem)

    text = d[3]
    raise QbeUnsupported, "string #{name} has no string data" unless head(text) == "string"

    total = size(ty)
    raw = string_bytes(text[1].raw)
    raise QbeUnsupported, "string #{name} is longer than its array" if raw.size > total

    bytes = raw + [0] * (total - raw.size)
    parts = bytes.map { |b| "b #{b}" }
    if Qbe.asan
      # --asan: a redzone after the string, as after a global (see build_data).
      elem = 8 if elem < 8
      osz = (total + 7) & ~7
      parts << "z #{osz - total + Qbe::ASAN_RZ}"
      Qbe.asan_objects << [symbol(name), osz]
    end
    if Qbe.safe
      parts << "z 1"   # padding; the string is registered with the safe-pointers constructor
      Qbe.sp_objects << [symbol(name), total]
    end
    body = parts.empty? ? "z 0" : parts.join(", ")
    [bytes, "data $#{symbol(name)} = align #{elem} { #{body} }"]
  end

  # The bytes a quoted SSA string denotes: the escapes \\, \", \n, \t and \ooo (one to three octal digits).
  # Anything else is refused.
  def string_bytes(quoted)
    s = quoted[1...-1].b
    out = []
    i = 0
    while i < s.size
      c = s[i]
      if c != "\\"
        out << c.ord
        i += 1
        next
      end
      nxt = s[i + 1]
      raise QbeUnsupported, "string escape #{nxt.inspect}" if nxt.nil?

      if "01234567".include?(nxt)
        n = 1
        n += 1 while n < 3 && i + 1 + n < s.size && "01234567".include?(s[i + 1 + n])
        digits = s[i + 1, n]
        out << digits.to_i(8)
        i += 1 + digits.size
      else
        out << { "\\" => 92, "\"" => 34, "n" => 10, "t" => 9 }.fetch(nxt) { raise QbeUnsupported, "string escape #{nxt.inspect}" }
        i += 2
      end
    end
    out
  end

  # One function's text (its helper comments, then its body), against a context from module_context.
  def function_text(ctx, fn_form)
    fn = Fn.new(fn_form, ctx[:refs], ctx[:abi], ctx[:link]).emit
    helpers = fn.asm_helpers.map { |h| "# pathb-asm #{h}" }
    dbg = fn.dbg_file ? ["dbgfile #{fn.dbg_file.inspect}"] : []   # --asan: the function's source file (see Fn#asan_dbgloc)
    (helpers + fn.asan_data + dbg + [fn.lines.join("\n")]).join("\n\n")
  end
end

def main(argv)
  file = argv.first
  unless file
    $stderr.write "usage: pathb-ssa-qbe.rb FILE.ssa\n"
    return 1
  end
  print Qbe.module_il(read_forms(File.read(file)))
  0
rescue SystemCallError => e
  $stderr.write "pathb-ssa-qbe: #{e.message}\n"
  1
end

# pathb-ssa-build requires this file for its emitter, so the command line runs only as the program.
if $0 == __FILE__
  rc = main(ARGV)
  exit(rc) if rc != 0
end
