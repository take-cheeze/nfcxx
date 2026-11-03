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
  INT_W = %w[bool char signed_char unsigned_char short unsigned_short int unsigned_int].freeze
  INT_L = %w[long long_long unsigned_long unsigned_long_long].freeze
  LOAD = { "bool" => "loadub", "char" => "loadsb", "signed_char" => "loadsb", "unsigned_char" => "loadub",
           "short" => "loadsh", "unsigned_short" => "loaduh", "int" => "loadsw", "unsigned_int" => "loaduw",
           "long" => "loadl", "long_long" => "loadl", "unsigned_long" => "loadl", "unsigned_long_long" => "loadl",
           "float" => "load", "double" => "load" }.freeze
  STORE = { "bool" => "storeb", "char" => "storeb", "signed_char" => "storeb", "unsigned_char" => "storeb",
            "short" => "storeh", "unsigned_short" => "storeh", "int" => "storew", "unsigned_int" => "storew",
            "long" => "storel", "long_long" => "storel", "unsigned_long" => "storel", "unsigned_long_long" => "storel",
            "float" => "stores", "double" => "stored" }.freeze
  # The std:: float typedefs whose objects are emitted as their bit patterns (storage only): the byte count of each.
  FLOAT_STORAGE = { "std::float16_t" => 2, "std::float32_t" => 4, "std::float64_t" => 8 }.freeze
  SIZE = { "bool" => 1, "char" => 1, "signed_char" => 1, "unsigned_char" => 1, "short" => 2, "unsigned_short" => 2,
           "int" => 4, "unsigned_int" => 4, "long" => 8, "long_long" => 8, "unsigned_long" => 8,
           "unsigned_long_long" => 8, "float" => 4, "double" => 8 }.freeze
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
    attr_accessor :safe, :module_has_data, :sp_objects, :sp_funcs
  end
  # The size of a frame object that QBE lays out with no padding byte after it (pathb-qbe-emit.rb's SP_NOPAD).
  SP_NOPAD = -(1 << 63)
  # The library's block functions whose pointer arguments are range-checked at a call (pathb-qbe-emit.rb's SP_MEMFN):
  # the argument indices, the length being argument 2.
  SP_MEMFN = { "memcpy" => [0, 1], "memmove" => [0, 1], "memset" => [0], "memcmp" => [0, 1], "bcmp" => [0, 1] }.freeze
  self.safe = false
  self.module_has_data = false
  self.sp_objects = []
  self.sp_funcs = []

  module_function

  def float?(t) = FLOAT_TYPES.key?(unqual(t))

  # The QBE class of a scalar type: w for 32-bit and narrower integers, l for 64-bit ones and pointers, s and d for
  # float and double.
  def cls(t)
    t = unqual(t)
    return "l" if head(t) == "ptr"
    return "w" if INT_W.include?(t)
    return "l" if INT_L.include?(t)
    return "s" if t == "float"
    return "d" if t == "double"

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
    return Integer(s, 16) if s.match?(/\A0[xX]/)
    return -Integer(s[1..], 16) if s.match?(/\A-0[xX]/)

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
    v = Float(text)
    raise QbeUnsupported, "float16 literal #{text}" if v.nan? || v.infinite?

    sig = text.sub(/[eE].*/, "").delete("-+.").sub(/\A0+/, "").length
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
    v = Float(text)
    raise QbeUnsupported, "float literal #{text}" if v.nan? || v.infinite?

    sig = text.sub(/[eE].*/, "").delete("-+.").sub(/\A0+/, "").length
    if n == 4
      packed = [v].pack("e")
      back = packed.unpack1("e")
      bits = packed.unpack1("L<")
    else
      packed = [v].pack("E")
      back = v
      bits = packed.unpack1("Q<")
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
    return "#{cls(t)}_nan" if text.to_s.match?(/nan/i)

    v = round_float(Float(text.to_s), unqual(t))
    return "#{cls(t)}_nan" if v.nan?

    body = v.infinite? ? (v.positive? ? "inf" : "-inf") : format("%a", v)
    "#{cls(t)}_#{body}"
  end

  # The QBE symbol of a quoted SSA name: letters, digits, `_` and `.` stay; any other byte is escaped.
  def symbol(raw) = raw.delete('"').gsub(/[^A-Za-z0-9_.]/) { |c| "_x#{c.ord.to_s(16)}_" }

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
    if Qbe.safe && !flags.include?("thread")
      parts << "z 1"   # padding: see the safe-pointers section of docs/notes/safe-pointers.md
      Qbe.sp_objects << [symbol(g[1].raw), size]
    end
    linkage = (flags.include?("thread") ? "thread " : "") + (flags.include?("static") ? "" : "export ")
    marker = flags.include?("weak") ? "# pathb-weak #{symbol(g[1].raw)}\n" : ""
    "#{marker}#{linkage}data $#{symbol(g[1].raw)} = align #{align} { #{parts.join(', ')} }"
  end

  # One function. An SSA register %N is %vN, a parameter %k is %pk, and an object of a slot that was not promoted
  # is %o<i>, allocated on the stack at entry.
  class Fn
    attr_reader :lines

    # globals: the raw names of the module globals that are emitted (a reference to any other global raises).
    def initialize(form, globals = {}, abi = {})
      @form = form
      @globals = globals
      @abi = abi
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
      @slot = {}
      @jumper = {}     # [target block, source block] => the emitted label whose jump reaches target
      @phi_expr = {}   # [block, pred, phi register] => the temporary of an expression phi operand
      @sp_objs = []    # --safe: [temporary, size] of the frame objects this function registers
    end

    def emit
      header
      allocs
      escape_slots if returns_twice?(@blocks)
      plan_phis
      @blocks.each do |b|
        @cur = b[1].to_s
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
            else "#{Qbe.cls(@ret[1])} "
            end
      # A (weak) function (an inline or template instance) is weak in the object file, as the IR says: the driver writes
      # the .weak directive for the marker.
      @lines << "# pathb-weak #{@name}" if @form.drop(2).any? { |p| p.is_a?(Array) && head(p) == "weak" && p.length == 1 }
      @lines << "export function #{ret}$#{@name}(#{sig.join(", ")}) {"
      @lines << "@start"
    end

    # The AbiInfo of an aggregate that is passed or returned by value: it must have an abi-type, and its class must be
    # one this emitter passes (not an empty class, not an unsupported one).
    def aggregate_info(tyform, what)
      raise QbeUnsupported, "#{what} aggregate #{sx(tyform)}" unless head(tyform) == "struct"

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
        # --safe: a slot is registered, with one byte of padding after it (as the emitter pads an escaped slot).
        pad = Qbe.safe ? 1 : 0
        @sp_objs << ["%o#{i}", size] if Qbe.safe
        @lines << "  %o#{i} =l alloc#{a} #{[size, 1].max + pad}"
      end
      unless @sp_objs.empty?
        @lines << "  call $__nfcxx_sp_frame(w #{@sp_objs.length}, ..., #{Qbe.sp_pairs(@sp_objs)})"
      end
      @blocks.each { |b| b[2..].each { |it| note_type(it) } }
    end

    def note_type(item)
      @types[item[1]] = item[2] if %w[let phi].include?(head(item))
    end

    def reg(name) = "%v#{name[1..]}"

    def block_label(num) = "b#{num}"

    # Checks that need no emission: a switch's targets may not repeat where a phi reads them, and a phi operand that is an
    # expression is computed at the end of its predecessor, so the phi reads a temporary.
    def plan_phis
      @phi_blocks = {}
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
        l.gsub(/@@J(\d+)_(\d+)@@/) do
          key = [Regexp.last_match(1), Regexp.last_match(2)]
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
      return "ptr" if x.is_a?(Array) && head(x) == "null"
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
          # A thread-local object: its address is the thread pointer plus the object's offset (initial-exec, as the
          # existing emitter does it).
          if info[:thread]
            t = fresh
            @lines << "  #{t} =l copy extern thread $#{Qbe.symbol(x.raw)}"
            return t
          end
          return "$#{Qbe.symbol(x.raw)}"
        end
        # A function used as a value: its address is the function's symbol (the existing emitter does the same).
        return "$#{Qbe.symbol(x.raw)}" if x.sigil == "&"
        raise QbeUnsupported, "address #{x.raw}" unless x.sigil == "$"

        @slot.fetch("$#{x.raw}") { raise QbeUnsupported, "slot #{x.raw}" }
      when String
        raise QbeUnsupported, "operand #{x}" unless x.start_with?("%")

        return @alias[x] if @alias.key?(x)

        @params_set[x] ? "%p#{x[1..]}" : reg(x)
      when Array
        case head(x)
        when "const"
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
        @lines << "  blit #{src}, #{dst}, #{n}"
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
        # --safe: the frame is released before the return (pathb-qbe-emit.rb's SP_LEAVE, with the first object).
        @lines << "  call $__nfcxx_sp_leave(l #{@sp_objs.first[0]})" if Qbe.safe && !@sp_objs.empty?
        # A function with an sret parameter returns its result buffer (the C convention; the caller copies it out).
        if @sret
          @lines << (@sret.shape == "empty" ? "  ret" : "  ret %sretbuf")
        else
          @lines << (item.size > 1 ? "  ret #{op(item[1])}" : "  ret")
        end
      when "unreachable", "trap" then @lines << "  hlt"
      when "bfstore", "bfstore.v" then bfstore_lines(item)
      when "nonnull" then nonnull_lines(item[1])
      when "bounds" then bounds_lines(item[1], item[2])
      # A compiler barrier is a call of an empty helper; a fence a call of a helper that executes mfence. QBE has no
      # fence instruction, so the driver (scripts/pathb-ssa-build) appends the helpers named by the marker comments.
      when "barrier" then barrier_lines
      when "fence" then fence_lines
      # A branch-likelihood hint (likely/unlikely) changes only the layout the optimiser would choose, never the
      # meaning of the code; QBE has no such hint, so the hint emits nothing.
      when "likely", "unlikely" then nil
      # (vastart ADDR): the va_list at ADDR starts reading the variadic arguments (the function has an ellipsis).
      when "vastart" then @lines << "  vastart #{op(item[1])}"
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
    def check_call(cond, code)
      asm_helpers << "check" unless asm_helpers.include?("check")
      @lines << "  call $pathb_check(w #{cond}, w #{code})"
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
      c = Qbe.cls(t)
      case head(rv)
      when *Qbe::BIN.keys
        @lines << "  #{dst} =#{c} #{Qbe::BIN[head(rv)]} #{op(rv[2])}, #{op(rv[3])}"
      when "wneg" then @lines << "  #{dst} =#{c} sub 0, #{op(rv[2])}"
      when "cdiv", "crem" then checked_div_lines(dst, t, rv)
      when "cshl", "cshr" then checked_shift_lines(dst, t, rv)
      when *Qbe::FBIN.keys
        @lines << "  #{dst} =#{c} #{Qbe::FBIN[head(rv)]} #{op(rv[2])}, #{op(rv[3])}"
      when "fneg" then @lines << "  #{dst} =#{c} neg #{op(rv[2])}"
      when *Qbe::CMP.keys
        oc = Qbe.cls(rv[1])
        @lines << "  #{dst} =w #{Qbe::CMP[head(rv)]}#{oc} #{op(rv[2])}, #{op(rv[3])}"
      when *Qbe::FCMP.keys
        oc = Qbe.cls(rv[1])
        @lines << "  #{dst} =w #{Qbe::FCMP[head(rv)]}#{oc} #{op(rv[2])}, #{op(rv[3])}"
      when "iconv" then conv_lines(dst, t, rv[2])
      # An integer to pointer conversion widens the integer as an iconv to a 64-bit type does (pathb-qbe-emit.rb's i2p).
      when "i2p" then conv_lines(dst, t, rv[2])
      when "i2f", "u2f" then int_to_float_lines(dst, t, rv[2])
      when "fconv" then float_conv_lines(dst, t, rv[2])
      when "cf2i" then float_to_int_lines(dst, t, rv[2])
      when "call" then @lines << "  #{dst} =#{c} #{call_text(rv)}"
      # (vaarg TYPE ADDR): the next variadic argument of the va_list at ADDR. QBE reads w, l, s and d only.
      when "vaarg"
        raise QbeUnsupported, "vaarg of #{sx(rv[1])}" unless %w[w l s d].include?(Qbe.cls(rv[1]))

        @lines << "  #{dst} =#{c} vaarg #{op(rv[2])}"
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
      when "bitcast" then bitcast_lines(dst, rv)
      when "bfload", "bfload.v" then bfload_lines(dst, rv)
      when "offset"
        base = op(rv[1])
        if Qbe.safe
          sum = fresh
          @lines << "  #{sum} =l add #{base}, #{Qbe.int_lit(rv[2])}"
          @lines << "  #{dst} =l call $__nfcxx_sp_derive(l #{base}, l #{sum}, l 0, w 0)"
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
        if unqual(rv[1]) == "bool"
          raw = fresh
          @lines << "  #{raw} =w loadub #{a}"
          @lines << "  #{dst} =w cnew #{raw}, 0"
        else
          @lines << "  #{dst} =#{c} #{Qbe.load_op(rv[1])} #{a}"
        end
      when "const", "null", nil
        @lines << "  #{dst} =#{c} copy #{op(rv)}" if rv.is_a?(Array) || rv.is_a?(String)
        raise QbeUnsupported, "let of #{sx(rv)}" unless rv.is_a?(Array) || rv.is_a?(String)
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
      @lines << "  #{dst} =#{Qbe.cls(rv[1])} call $#{Qbe.volatile_name("ld", op_name)}(l #{a})"
    end

    def volatile_store_lines(item)
      op_name = Qbe.store_op(item[1])
      a = op(item[2])
      v = op(item[3])
      safe_check(item[2], a, Qbe.size(item[1]))
      @lines << "  call $#{Qbe.volatile_name("st", op_name)}(l #{a}, #{Qbe.store_class(op_name)} #{v})"
    end

    # --safe (-fsafe-pointers): the check of an access of `bytes` bytes at `addr` (the text of the IR operand `x`), which
    # the existing emitter makes before every load and store through a computed address. A static address (a slot, a
    # global, an address-of) is not checked. The location is not in the SSA text, so a report has none ("?").
    def safe_check(x, addr, bytes)
      return unless Qbe.safe
      return if x.is_a?(Ref) || (x.is_a?(Array) && head(x) == "addr")
      @lines << "  call $__nfcxx_sp_check(l #{addr}, l #{bytes}, l 0, w 0)"
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
        @lines << "  #{dst} =l call $__nfcxx_sp_derive(l #{base}, l #{sum}, l 0, w 0)"
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
      ub = unit * 8
      t = fresh
      @lines << "  #{t} =#{uc} #{Qbe::BF_LOAD[unit]} #{op(rv[3])}"
      if ub - boff - width > 0
        t2 = fresh
        @lines << "  #{t2} =#{uc} shl #{t}, #{ub - boff - width}"
        t = t2
      end
      signed = Qbe.signed?(ty)
      if ub - width > 0
        t2 = fresh
        @lines << "  #{t2} =#{uc} #{signed ? 'sar' : 'shr'} #{t}, #{ub - width}"
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
      @lines << "  #{old} =#{uc} #{Qbe::BF_LOAD[unit]} #{addr}"
      if width < ub
        t2 = fresh
        @lines << "  #{t2} =#{uc} shl #{v}, #{ub - width}"
        v = t2
        if ub - width - boff > 0
          t3 = fresh
          @lines << "  #{t3} =#{uc} shr #{v}, #{ub - width - boff}"
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
          @lines << "  #{k1} =#{uc} shl #{old}, #{ub - boff}"
          @lines << "  #{keep} =#{uc} shr #{k1}, #{ub - boff}"
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
      name = head(rv) == "cdiv" ? (signed ? "div" : "udiv") : (signed ? "rem" : "urem")
      @lines << "  #{dst} =#{c} #{name} #{a}, #{b}"
    end

    # The count must be in [0, w): an unsigned comparison of the count against w also rejects a negative count.
    def checked_shift_lines(dst, t, rv)
      raise QbeUnsupported, "#{head(rv)} of bool" if t == "bool"

      c = Qbe.cls(t)
      w, signed = int_info(t)
      a = op(rv[2])
      count_cls = Qbe.cls(switch_operand_type(rv[3]))
      n = op(rv[3])
      if count_cls == "l" && c == "w"
        narrowed = fresh
        @lines << "  #{narrowed} =w copy #{n}"
        n = narrowed
      end
      bad = fresh
      @lines << "  #{bad} =w cuge#{count_cls} #{n}, #{w}"
      check_call(bad, 3)
      if head(rv) == "cshl"
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
        else args << "#{arg_cls(a)} #{op(a)}"
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
      if !(f.is_a?(Ref) && f.sigil == "&")
        rcls = sret ? (sret.shape == "empty" ? "" : sret.tn) : (c[1] == "void" ? "" : Qbe.cls(c[1]))
        classes = args.map { |a| a.split(" ", 2)[0] }
        @lines << "  call $__nfcxx_sp_call(l #{callee}, l #{Qbe.sp_sig(@abi, rcls, classes)}, l 0, w 0)"
      elsif (name = f.raw.delete('"')) && Qbe::SP_MEMFN.key?(name) && args.length == 3 && args[2].start_with?("l ")
        Qbe::SP_MEMFN[name].each do |i|
          @lines << "  call $__nfcxx_sp_check(l #{args[i].split(" ", 2)[1]}, l #{args[2].split(" ", 2)[1]}, l 0, w 0)"
        end
      end
    end

    def call_text(c)
      sret, _dest, sym, args = call_parts(c)
      raise QbeUnsupported, "a call with an aggregate result used as a value" if sret

      "call #{sym}(#{args.join(', ')})"
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
      raise QbeUnsupported, "integer to float of a float" if float_type?(src)

      name = { ["w", true] => "swtof", ["w", false] => "uwtof", ["l", true] => "sltof", ["l", false] => "ultof" }
             .fetch([Qbe.cls(src), Qbe.signed?(src)]) { raise QbeUnsupported, "integer to float of #{sx(src)}" }
      @lines << "  #{dst} =#{Qbe.cls(t)} #{name} #{op(x)}"
    end

    # A float to a float of another precision: a rounding to single (truncd) or an exact widening (exts).
    def float_conv_lines(dst, t, x)
      src = source_type(x)
      raise QbeUnsupported, "float conversion of an integer" unless float_type?(src)

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
      raise QbeUnsupported, "float to integer of #{sx(src)}" unless float_type?(src)
      raise QbeUnsupported, "float to bool" if t == "bool"

      w, signed = int_info(t)
      xv = op(x)
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
  def module_il(forms)
    ctx = module_context(forms)
    emitted = forms.select { |f| head(f) == "ssa-function" }.map { |f| Fn.new(f, ctx[:refs], ctx[:abi]).emit }
    helpers = emitted.flat_map(&:asm_helpers).uniq.map { |h| "# pathb-asm #{h}" }
    (ctx[:data] + helpers + emitted.map { |fn| fn.lines.join("\n") }).join("\n\n") + "\n"
  end

  # The part of a module that every function shares: the data of its globals and the references a function may make
  # to them. Built once, so a driver that emits function by function does not redo the globals for each function.
  # The volatile access helpers: one function per load and store operation. QBE has no volatile, so a volatile access is
  # a call of one of these (a call is kept in order and neither merged nor removed), as pathb-qbe-emit.rb does.
  VOLATILE_LOADS = %w[loadub loadsb loadsh loaduh loadsw loaduw loadl loads loadd].freeze
  VOLATILE_STORES = %w[storeb storeh storew storel stores stored].freeze

  # The type without its const and volatile qualifiers: they are access properties, not part of the value's class.
  def unqual(t)
    t = t[1] while head(t) == "const"
    head(t) == "volatile" ? unqual(t[1]) : t
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
    # What a function may reference: an emitted global, or an extern one (its symbol is linked in).
    flags = gs.to_h { |g| [g[1].raw, global_flags(g)] }
    refs = flags.select { |name, _| state[name].is_a?(String) || state[name] == :extern }
                .to_h { |name, f| [name, { thread: f.include?("thread"), weak: f.include?("weak"), extern: f.include?("extern") }] }
    strs.each do |d|
      name = d[1].raw
      refs[name] = { thread: false, weak: false, extern: false } if state[name].is_a?(String)
    end
    { data: data, refs: refs, abi: abi }
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

  # The bytes of a string literal and its data line: its bytes, then zeros up to the array's size (as the existing
  # emitter writes them, pathb-qbe-emit.rb's emit_string). Only a char array is emitted.
  def string_data(d)
    name = d[1].raw
    ty = d[2]
    raise QbeUnsupported, "string #{name} is not a char array" unless head(unqual(ty)) == "array"
    raise QbeUnsupported, "string #{name} is a wide string" unless size(unqual(ty)[2]) == 1

    text = d[3]
    raise QbeUnsupported, "string #{name} has no string data" unless head(text) == "string"

    total = size(ty)
    raw = string_bytes(text[1].raw)
    raise QbeUnsupported, "string #{name} is longer than its array" if raw.size > total

    bytes = raw + [0] * (total - raw.size)
    parts = bytes.map { |b| "b #{b}" }
    if Qbe.safe
      parts << "z 1"   # padding; the string is registered with the safe-pointers constructor
      Qbe.sp_objects << [symbol(name), total]
    end
    body = parts.empty? ? "z 0" : parts.join(", ")
    [bytes, "data $#{symbol(name)} = align 1 { #{body} }"]
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

      if nxt =~ /[0-7]/
        digits = s[i + 1, 3][/\A[0-7]{1,3}/]
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
    fn = Fn.new(fn_form, ctx[:refs], ctx[:abi]).emit
    helpers = fn.asm_helpers.map { |h| "# pathb-asm #{h}" }
    (helpers + [fn.lines.join("\n")]).join("\n\n")
  end
end

if $PROGRAM_NAME == __FILE__
  file = ARGV.first or abort "usage: pathb-ssa-qbe.rb FILE.ssa"
  print Qbe.module_il(read_forms(File.read(file)))
end
