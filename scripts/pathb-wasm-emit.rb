# Path B: emit a WebAssembly module (binary format, MVP plus sign extension and bulk memory) from the nfcxx mid-level IR
# text (docs/notes/pathb-stage2.md, sections 6 and 7).
#
# Usage: scripts/mrb scripts/pathb-wasm-emit.rb [FILE.ir | -] > out.wasm
#
# Exit status:
#   0  the module was written to stdout
#   3  refused: the IR has a node, type or marker this emitter does not handle yet; the reason is on stderr
#   1  error: malformed IR text
#
# Layout and representation. The IR's layout is LP64 (pointers 8 bytes), and the emitter keeps it: a pointer value is an
# i64, and each memory access wraps it to the i32 address of the 32-bit linear memory. Integers of 1, 2 and 4 bytes are
# i32 values kept canonical (sign- or zero-extended from their width), so a comparison or a widening is a plain
# operation; 8-byte integers and pointers are i64; float and double are f32 and f64. A register is a wasm local (the
# IR is not SSA, so a register may be set more than once). A slot is a frame in the linear memory: a shadow stack grows
# down from the top of the memory (global 0). Each function's frame starts at the stack pointer it found on entry, minus
# its frame size, aligned to 16, and the stack pointer is restored before each return.
#
# Checked operations. Division by zero, INT_MIN / -1 and float-to-integer conversions out of range or from NaN trap
# through wasm's own traps, which match the IR's checked forms. A shift whose count is not below the width of its left
# operand traps through an explicit `unreachable`. `unreachable` and `trap` trap.
#
# Calls of functions that the module does not define become imports from the module "env" (the host supplies them).
# An import's signature is the one of its first call.
#
# This milestone handles scalars, pointers, arithmetic, comparisons, conversions, loads and stores, slots, direct calls,
# if, loop with break and continue, return, copy, trap and unreachable. Everything else is refused with the reason on
# stderr: switch, goto, static data and globals, bit-fields, aggregate parameters, results and arguments, variadic calls,
# function pointers, indirect calls, inline assembly, VLAs, exceptions and the 16-byte types. Those refusals are the next
# steps, not silent drops.

class Refused < StandardError; end   # a node this emitter does not handle (exit status 3)
class BadIR < StandardError; end     # malformed IR text (exit status 1)

# ------------------------------------------------------------------ reading the IR text (as pathb-qbe-emit.rb)

class IRStr
  attr_reader :bytes

  def initialize(bytes)
    @bytes = bytes
  end

  def to_s
    s = "".b
    @bytes.each { |c| s << (c & 255).chr }
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

def space_byte?(c)
  (c >= 9 && c <= 13) || (c >= 28 && c <= 32) || c == 0x85 || c == 0xa0
end

def octal?(c)
  c >= 48 && c <= 55
end

def read_string(text, i)
  out = []
  i += 1
  n = text.bytesize
  while true
    raise BadIR, "unterminated string in IR" if i >= n
    c = text.getbyte(i)
    return [out, i + 1] if c == 34
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

def head_of(x)
  x.is_a?(Array) && !x.empty? && x[0].is_a?(String) ? x[0] : nil
end

def form_text(x)
  if x.is_a?(Array)
    "(" + x.map { |y| form_text(y) }.join(" ") + ")"
  elsif x.is_a?(IRSym)
    x.sig + "\"" + x.name + "\""
  elsif x.is_a?(IRStr)
    "\"" + x.to_s + "\""
  else
    x.to_s
  end
end

# The signed 64-bit value with the bit pattern of n (an unsigned constant above 2**63 is negative in an i64).
def signed64(n)
  n &= 0xffffffffffffffff
  n >= 0x8000000000000000 ? n - 0x10000000000000000 : n
end

# A decimal or hexadecimal (0x...) integer, with an optional minus sign.
def as_int(x)
  raise BadIR, "expected an integer, got #{form_text(x)}" unless x.is_a?(String) && x.length > 0
  neg = false
  s = x
  if s[0] == "-"
    neg = true
    s = s[1..-1]
  end
  hex = s.length > 2 && s[0] == "0" && (s[1] == "x" || s[1] == "X")
  s = s[2..-1] if hex
  raise BadIR, "expected an integer, got #{x}" if s.length == 0
  base = hex ? 16 : 10
  v = 0
  s.each_char do |c|
    d = if c >= "0" && c <= "9" then c.ord - 48
        elsif hex && c >= "a" && c <= "f" then c.ord - 87
        elsif hex && c >= "A" && c <= "F" then c.ord - 55
        else raise BadIR, "expected an integer, got #{x}"
        end
    v = v * base + d
  end
  neg ? -v : v
end

# ------------------------------------------------------------------ types
# ["int", size, signed, bool], ["float", size], ["ptr", pointee], ["void"]

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
    raise Refused, "type #{x}"
  end
  raise BadIR, "bad type form #{form_text(x)}" if !x.is_a?(Array) || x.empty?
  head = x[0]
  # a pointer's pointee is not needed to emit it (a pointer is an i64, whatever it points to)
  return ["ptr", nil] if head == "ptr"
  return parse_type(x[1]) if head == "const" || head == "volatile"
  # (array N ELEM): N is "?" for a variable-length array, which has no size here
  return ["array", x[1] == "?" ? nil : as_int(x[1]), parse_type(x[2])] if head == "array"
  raise Refused, "aggregate type #{head}" if head == "struct" || head == "class" || head == "union"
  raise Refused, "type form (#{head} ...)"
end

# The size and alignment of an object of type t, from the layout of the IR (scalars and arrays of them).
def type_size(t)
  return 8 if t[0] == "ptr"
  return t[1] if t[0] == "int" || t[0] == "float"
  if t[0] == "array"
    raise Refused, "variable-length array" if t[1].nil?
    return t[1] * type_size(t[2])
  end
  raise Refused, "size of #{t[0]}"
end

def type_align(t)
  return type_align(t[2]) if t[0] == "array"
  type_size(t)
end

def void_type?(t)
  t[0] == "void"
end

def bool_type?(t)
  t[0] == "int" && t[3]
end

# The wasm value type of an IR type: :i32 for integers up to 4 bytes (bool included), :i64 for 8-byte integers and
# pointers, :f32 and :f64 for the floats. nil for void.
def wtype(t)
  return nil if void_type?(t)
  if t[0] == "int"
    return :i32 if t[1] <= 4
    return :i64 if t[1] == 8
    raise Refused, "integer of #{t[1]} bytes"
  end
  return :i64 if t[0] == "ptr"
  if t[0] == "float"
    return :f32 if t[1] == 4
    return :f64 if t[1] == 8
    raise Refused, "float of #{t[1]} bytes"
  end
  raise Refused, "value of type #{t[0]}"
end

# ------------------------------------------------------------------ bytes

def uleb(n, out)
  raise BadIR, "negative size or index in LEB128" if n < 0
  loop do
    b = n & 0x7f
    n >>= 7
    if n != 0
      out << (b | 0x80)
    else
      out << b
      break
    end
  end
  out
end

def sleb(v, out)
  loop do
    b = v & 0x7f
    v >>= 7
    done = (v == 0 && (b & 0x40) == 0) || (v == -1 && (b & 0x40) != 0)
    out << (done ? b : (b | 0x80))
    break if done
  end
  out
end

def name_bytes(s, out)
  uleb(s.bytesize, out)
  s.each_byte { |b| out << b }
  out
end

def section(id, body, out)
  out << id
  uleb(body.length, out)
  body.each { |b| out << b }
end

VT = { :i32 => 0x7f, :i64 => 0x7e, :f32 => 0x7d, :f64 => 0x7c }

# ------------------------------------------------------------------ module

class Module_
  attr_reader :types, :imports, :import_index, :defined_index

  def initialize(defs)
    @defs = defs                 # name => the (function ...) form
    @types = []                  # [params, result] pairs of wasm value types
    @type_index = {}
    @imports = []                # [name, type index]
    @import_index = {}           # name => function index
    @defined_index = {}          # name => function index (after the imports)
  end

  def type_of(params, result)
    key = [params, result]
    unless @type_index.key?(key)
      @type_index[key] = @types.length
      @types << key
    end
    @type_index[key]
  end

  # A call of a function the module does not define: an import, with the signature of its first call.
  def import_of(name, params, result)
    unless @import_index.key?(name)
      @import_index[name] = @imports.length
      @imports << [name, type_of(params, result)]
    end
    @import_index[name]
  end

  def defines?(name)
    @defs.key?(name)
  end
end

# ------------------------------------------------------------------ function bodies

class Fn
  attr_reader :type_index

  def initialize(mod, form)
    @mod = mod
    @form = form
    @code = []
    @labels = []             # the open structured constructs, innermost last: [:brk] [:loop] [:cont] [:if]
    @regs = {}               # "%N" => [wasm local index, wasm type, IR type]
    @slots = {}              # name => frame offset
    @frame = 0
    @param_types = []        # wasm types of the parameters, in order
    @local_types = []        # wasm types of the locals after the parameters, in index order
    @result = nil            # wasm type of the result, nil for void
    @cont = {}               # label name => the loop it continues (the label at the end of its body)
    @brk = {}                # label name => the loop it leaves (the label just after the loop)
    @loop_n = 0
    @pending_brk = nil       # the label that follows the loop being compiled
  end

  def e(*bytes)
    bytes.each { |b| @code << b }
  end

  def leb_u(n)
    uleb(n, @code)
  end

  def leb_s(n)
    sleb(n, @code)
  end

  def memarg
    e(0x00)                  # alignment 1 (a hint: 0 is always valid)
    e(0x00)                  # offset 0
  end

  # ---- the header: return type, parameters, slots, body

  def setup
    ret = nil
    params = []
    body_start = nil
    @form.each_with_index do |f, i|
      next if i < 2
      h = head_of(f)
      if h == "ret"
        ret = parse_type(f[1])
      elsif h == "params"
        f.drop(1).each_with_index do |p, k|
          raise Refused, "variadic function" if head_of(p) == "ellipsis"
          raise Refused, "parameter form #{form_text(p)}" unless head_of(p) == "param"
          raise BadIR, "bad parameter #{form_text(p)}" unless p.length == 4
          raise BadIR, "parameter register must be %#{k}" unless p[1] == "%#{k}"
          ty = parse_type(p[3])
          raise Refused, "aggregate parameter #{form_text(p)}" if wtype(ty).nil? || !(ty[0] == "int" || ty[0] == "ptr" || ty[0] == "float")
          params << [wtype(ty), ty]
        end
      elsif h == "static"
        nil
      elsif h == "slot"
        # (slot "x" TYPE [SIZE ALIGN]): the size and alignment are given for aggregates, and a scalar has its own
        if f.length == 5
          size = as_int(f[3])
          align = as_int(f[4])
        else
          slot_ty = parse_type(f[2])
          size = type_size(slot_ty)
          align = type_align(slot_ty)
        end
        align = 1 if align < 1
        @frame = (@frame + align - 1) / align * align
        @slots[f[1].to_s] = @frame
        @frame += size
      else
        body_start = i if body_start.nil?
      end
    end
    raise BadIR, "function without a return type" if ret.nil?
    @ret = ret
    @result = wtype(ret)
    @frame = (@frame + 15) / 16 * 16
    @param_types = params.map { |p| p[0] }
    params.each_with_index { |p, k| @regs["%#{k}"] = [k, p[0], p[1]] }
    # locals after the parameters: the stack pointer on entry, this frame's base and a 64-bit scratch, then one local per
    # register declared by a let
    @old_local = params.length
    @fp_local = params.length + 1
    @tmp64 = params.length + 2
    @local_types << :i32 << :i32 << :i64
    @next_local = params.length + 3
    @body = body_forms
    @body.each { |s| collect_lets(s) }
    @type_index = @mod.type_of(@param_types, @result)
  end

  # The forms that make up the body (everything after the header).
  def body_forms
    @form.drop(2).reject do |f|
      h = head_of(f)
      h == "ret" || h == "params" || h == "static" || h == "slot"
    end
  end

  def collect_lets(s)
    return unless s.is_a?(Array)
    if head_of(s) == "let"
      name = s[1]
      raise BadIR, "let without a register: #{form_text(s)}" unless name.is_a?(String) && name[0] == "%"
      raise BadIR, "register #{name} declared twice" if @regs.key?(name)
      ty = parse_type(s[2])
      w = wtype(ty)
      raise Refused, "let of a void value" if w.nil?
      @regs[name] = [@next_local, w, ty]
      @local_types << w
      @next_local += 1
    end
    s.drop(1).each { |c| collect_lets(c) if c.is_a?(Array) }
  end

  def reg_info(name)
    @regs.fetch(name) { raise BadIR, "unknown register #{name}" }
  end

  def slot_offset(name)
    @slots.fetch(name) { raise Refused, "unknown slot $\"#{name}\"" }
  end

  # ---- operands

  # The IR type of an operand (a pointer for a slot address).
  def op_type(op)
    if op.is_a?(String) && op[0] == "%"
      return reg_info(op)[2]
    end
    if op.is_a?(IRSym)
      raise Refused, "static object @\"#{op.name}\"" if op.sig == "@"
      raise Refused, "function address &\"#{op.name}\"" if op.sig == "&"
      return ["ptr", nil]
    end
    return parse_type(op[1]) if head_of(op) == "const"
    return ["ptr", nil] if head_of(op) == "null"
    raise Refused, "operand #{form_text(op)}"
  end

  # Pushes an operand in its natural wasm type (a slot address and a null pointer are i64). With want, the operand must
  # have that wasm type: the IR is typed, and an operand of another type is malformed.
  def push_op(op, want = nil)
    t = op_wtype(op)
    if want && t != want
      raise BadIR, "operand #{form_text(op)} has wasm type #{t.inspect} where #{want.inspect} is needed"
    end
    if op.is_a?(String) && op[0] == "%"
      e(0x20); leb_u(reg_info(op)[0])
    elsif op.is_a?(IRSym)
      e(0x20); leb_u(@fp_local)
      e(0x41); leb_s(slot_offset(op.name))
      e(0x6a)                              # i32.add
      e(0xad)                              # i64.extend_i32_u
    elsif head_of(op) == "null"
      e(0x42); leb_s(0)
    else
      push_const(parse_type(op[1]), op[2])
    end
    t
  end

  # The wasm type of an operand, without pushing it.
  def op_wtype(op)
    if op.is_a?(IRSym)
      raise Refused, "static object @\"#{op.name}\"" if op.sig == "@"
      raise Refused, "function address &\"#{op.name}\"" if op.sig == "&"
      return :i64
    end
    return reg_info(op)[1] if op.is_a?(String) && op[0] == "%"
    return :i64 if head_of(op) == "null"
    return wtype(parse_type(op[1])) if head_of(op) == "const"
    raise Refused, "operand #{form_text(op)}"
  end

  # Pushes an operand as the i32 address of memory.
  def addr32(op)
    if op.is_a?(IRSym) && op.sig == "$"
      e(0x20); leb_u(@fp_local)
      e(0x41); leb_s(slot_offset(op.name))
      e(0x6a)
    else
      push_op(op, :i64)
      e(0xa7)                              # i32.wrap_i64
    end
  end

  # Pushes an integer operand as an i64, sign-extended when sext is set, else by the signedness of its type.
  def push_i64(op, sext)
    ty = op_type(op)
    raise Refused, "non-integer where an integer is needed" unless ty[0] == "int" || ty[0] == "ptr"
    push_op(op)
    return if wtype(ty) == :i64
    e((sext || (ty[0] == "int" && ty[2])) ? 0xac : 0xad)   # i64.extend_i32_s / _u
  end

  def push_const(ty, v)
    if ty[0] == "float"
      val = float_value(v.to_s)
      if ty[1] == 4
        e(0x43); [val].pack("e").each_byte { |b| e(b) }
      else
        e(0x44); [val].pack("E").each_byte { |b| e(b) }
      end
      return
    end
    raise Refused, "constant of type #{ty[0]}" unless ty[0] == "int" || ty[0] == "ptr"
    n = as_int(v.to_s)
    if wtype(ty) == :i32
      n &= 0xffffffff
      n -= 0x100000000 if n >= 0x80000000
      e(0x41); leb_s(n)
    else
      n &= 0xffffffffffffffff
      n -= 0x10000000000000000 if n >= 0x8000000000000000
      e(0x42); leb_s(n)
    end
  end

  def float_value(text)
    return Float::INFINITY if text == "+Infinity" || text == "Infinity"
    return -Float::INFINITY if text == "-Infinity"
    return Float::NAN if text == "NaN" || text == "nan" || text == "+NaN" || text == "-NaN"
    text.to_f
  end

  # Canonical form of an i32 value of integer type ty: sign or zero extended from its width, bool as 0 or 1.
  def normalize(ty)
    return unless ty[0] == "int"
    if ty[3]
      e(0x41); leb_s(0); e(0x47)           # ne 0
    elsif ty[1] == 1
      if ty[2]
        e(0xc0)                            # i32.extend8_s
      else
        e(0x41); leb_s(0xff); e(0x71)      # and 0xff
      end
    elsif ty[1] == 2
      if ty[2]
        e(0xc1)                            # i32.extend16_s
      else
        e(0x41); leb_s(0xffff); e(0x71)    # and 0xffff
      end
    end
  end

  def float_type?(ty)
    ty[0] == "float"
  end

  # ---- rvalues: each leaves one value on the wasm stack and returns its wasm type

  def rval(x)
    h = head_of(x)
    case h
    when "load", "load.v"
      ty = parse_type(x[1])
      raise Refused, "load of #{ty[0]}" if wtype(ty).nil?
      addr32(x[2])
      load_op(ty)
      wtype(ty)
    when "wadd", "wsub", "wmul"
      ty = parse_type(x[1])
      raise Refused, "#{h} of a non-integer" unless ty[0] == "int"
      w = wtype(ty)
      push_op(x[2], w); push_op(x[3], w)
      base = { "wadd" => 0x6a, "wsub" => 0x6b, "wmul" => 0x6c }[h]
      e(w == :i32 ? base : base + 0x12)   # the i64 forms are 0x12 above the i32 ones (0x7c, 0x7d, 0x7e)
      normalize(ty)
      w
    when "wneg"
      ty = parse_type(x[1])
      raise Refused, "wneg of a non-integer" unless ty[0] == "int"
      w = wtype(ty)
      e(w == :i32 ? 0x41 : 0x42); leb_s(0)
      push_op(x[2], w)
      e(w == :i32 ? 0x6b : 0x7d)           # sub
      normalize(ty)
      w
    when "cdiv", "crem"
      ty = parse_type(x[1])
      raise Refused, "#{h} of a non-integer" unless ty[0] == "int"
      w = wtype(ty)
      push_op(x[2], w); push_op(x[3], w)
      if h == "cdiv"
        e(w == :i32 ? (ty[2] ? 0x6d : 0x6e) : (ty[2] ? 0x7f : 0x80))
      else
        e(w == :i32 ? (ty[2] ? 0x6f : 0x70) : (ty[2] ? 0x81 : 0x82))
      end
      normalize(ty)
      w
    when "cshl", "cshr"
      ty = parse_type(x[1])
      raise Refused, "#{h} of a non-integer" unless ty[0] == "int"
      w = wtype(ty)
      bits = ty[1] * 8
      # the count, as an i64: a count at or above the width (a negative count reads as huge) traps
      push_i64(x[3], false)
      e(0x21); leb_u(@tmp64)
      e(0x20); leb_u(@tmp64)
      e(0x42); leb_s(bits)
      e(0x5a)                              # i64.ge_u
      e(0x04, 0x40); e(0x00); e(0x0b)      # if unreachable end
      push_op(x[2])
      e(0x20); leb_u(@tmp64)
      e(0xa7) if w == :i32                 # the count as i32
      if w == :i32
        e(h == "cshl" ? 0x74 : (ty[2] ? 0x75 : 0x76))
      else
        e(h == "cshl" ? 0x86 : (ty[2] ? 0x87 : 0x88))
      end
      normalize(ty)
      w
    when "fadd", "fsub", "fmul", "fdiv"
      ty = parse_type(x[1])
      raise Refused, "#{h} of a non-float" unless float_type?(ty)
      push_op(x[2], wtype(ty)); push_op(x[3], wtype(ty))
      base = { "fadd" => 0, "fsub" => 1, "fmul" => 2, "fdiv" => 3 }[h]
      e(ty[1] == 4 ? 0x92 + base : 0xa0 + base)
      ty[1] == 4 ? :f32 : :f64
    when "fneg"
      ty = parse_type(x[1])
      raise Refused, "fneg of a non-float" unless float_type?(ty)
      push_op(x[2])
      e(ty[1] == 4 ? 0x8c : 0x9a)
      ty[1] == 4 ? :f32 : :f64
    when "and", "or", "xor"
      ty = parse_type(x[1])
      raise Refused, "#{h} of a non-integer" unless ty[0] == "int"
      w = wtype(ty)
      push_op(x[2], w); push_op(x[3], w)
      base = { "and" => 0, "or" => 1, "xor" => 2 }[h]
      e(w == :i32 ? 0x71 + base : 0x83 + base)
      w
    when "not"
      ty = parse_type(x[1])
      if bool_type?(ty)
        push_op(x[2])
        e(0x45)                            # i32.eqz
        :i32
      else
        raise Refused, "not of a non-integer" unless ty[0] == "int"
        w = wtype(ty)
        push_op(x[2])
        e(w == :i32 ? 0x41 : 0x42); leb_s(-1)
        e(w == :i32 ? 0x73 : 0x85)         # xor with -1
        normalize(ty)
        w
      end
    when "eq", "ne"
      ty = op_type(x[2])
      w = wtype(ty)
      push_op(x[2], w); push_op(x[3], w)
      eq = h == "eq"
      if w == :f32 then e(eq ? 0x5b : 0x5c)
      elsif w == :f64 then e(eq ? 0x61 : 0x62)
      elsif w == :i32 then e(eq ? 0x46 : 0x47)
      else e(eq ? 0x51 : 0x52)
      end
      :i32
    when "lt.s", "lt.u", "le.s", "le.u"
      ty = op_type(x[2])
      raise Refused, "#{h} of a non-integer" unless ty[0] == "int" || ty[0] == "ptr"
      w = wtype(ty)
      push_op(x[2], w); push_op(x[3], w)
      code = { "lt.s" => [0x48, 0x53], "lt.u" => [0x49, 0x54], "le.s" => [0x4c, 0x57], "le.u" => [0x4d, 0x58] }[h]
      e(w == :i32 ? code[0] : code[1])
      :i32
    when "lt.f", "le.f"
      ty = op_type(x[2])
      raise Refused, "#{h} of a non-float" unless float_type?(ty)
      push_op(x[2], wtype(ty)); push_op(x[3], wtype(ty))
      if ty[1] == 4
        e(h == "lt.f" ? 0x5d : 0x5f)
      else
        e(h == "lt.f" ? 0x63 : 0x65)
      end
      :i32
    when "iconv"
      dst = parse_type(x[1])
      raise Refused, "iconv to a non-integer" unless dst[0] == "int"
      src = op_type(x[2])
      raise Refused, "iconv from a non-integer" unless src[0] == "int" || src[0] == "ptr"
      sw = wtype(src)
      push_op(x[2])
      if wtype(dst) == :i64
        e((src[0] == "int" && src[2]) ? 0xac : 0xad) if sw == :i32
        :i64
      else
        e(0xa7) if sw == :i64
        normalize(dst)
        :i32
      end
    when "p2i"
      dst = parse_type(x[1])
      raise Refused, "p2i to a non-integer" unless dst[0] == "int"
      push_op(x[2])
      if wtype(dst) == :i32
        e(0xa7)
        normalize(dst)
        :i32
      else
        :i64
      end
    when "i2p"
      src = op_type(x[2])
      raise Refused, "i2p from a non-integer" unless src[0] == "int"
      push_op(x[2])
      e(src[2] ? 0xac : 0xad) if wtype(src) == :i32
      :i64
    when "i2f", "u2f"
      dst = parse_type(x[1])
      raise Refused, "i2f to a non-float" unless float_type?(dst)
      src = op_type(x[2])
      raise Refused, "i2f from a non-integer" unless src[0] == "int"
      push_op(x[2])
      signed = src[2] && !src[3]
      sw = wtype(src)
      if dst[1] == 4
        e(sw == :i32 ? (signed ? 0xb2 : 0xb3) : (signed ? 0xb4 : 0xb5))
        :f32
      else
        e(sw == :i32 ? (signed ? 0xb7 : 0xb8) : (signed ? 0xb9 : 0xba))
        :f64
      end
    when "fconv"
      dst = parse_type(x[1])
      raise Refused, "fconv to a non-float" unless float_type?(dst)
      src = op_type(x[2])
      raise Refused, "fconv from a non-float" unless float_type?(src)
      push_op(x[2])
      if dst[1] == 8 && src[1] == 4
        e(0xbb)
      elsif dst[1] == 4 && src[1] == 8
        e(0xb6)
      end
      dst[1] == 4 ? :f32 : :f64
    when "cf2i"
      dst = parse_type(x[1])
      raise Refused, "cf2i to a non-integer" unless dst[0] == "int"
      raise Refused, "cf2i to #{dst[1]} bytes (the range check is not lowered yet)" if dst[1] < 4
      src = op_type(x[2])
      raise Refused, "cf2i from a non-float" unless float_type?(src)
      push_op(x[2])
      w = wtype(dst)
      if src[1] == 4
        e(w == :i32 ? (dst[2] ? 0xa8 : 0xa9) : (dst[2] ? 0xae : 0xaf))
      else
        e(w == :i32 ? (dst[2] ? 0xaa : 0xab) : (dst[2] ? 0xb0 : 0xb1))
      end
      w
    when "bitcast"
      dst = parse_type(x[1])
      src = op_type(x[2])
      raise Refused, "bitcast between #{src[0]} and #{dst[0]}" if wtype(dst) != wtype(src)
      push_op(x[2])
      wtype(dst)
    when "const"
      push_const(parse_type(x[1]), x[2])
      wtype(parse_type(x[1]))
    when "null"
      e(0x42); leb_s(0)
      :i64
    when "offset"
      # (offset ADDR N): no type; the result is a pointer
      push_op(x[1])
      e(0x42); leb_s(as_int(x[2]))
      e(0x7c)                              # i64.add
      :i64
    when "index"
      # (index BASE IDX SIZE): no type; the result is a pointer. The index is sign-extended, as the IR says.
      push_op(x[1])
      push_i64(x[2], true)
      e(0x42); leb_s(as_int(x[3]))
      e(0x7e)                              # i64.mul
      e(0x7c)                              # i64.add
      :i64
    when "pdiff"
      # (pdiff A B SIZE): no type; the result is the pointer difference, a long
      push_op(x[1]); push_op(x[2])
      e(0x7d)                              # i64.sub
      e(0x42); leb_s(as_int(x[3]))
      e(0x7f)                              # i64.div_s
      :i64
    when "call"
      call(x)
    when "unsupported"
      raise Refused, unsupported_text(x)
    else
      raise Refused, "value form (#{h} ...)"
    end
  end

  def load_op(ty)
    if ty[0] == "int"
      case ty[1]
      when 1 then e(ty[2] && !ty[3] ? 0x2c : 0x2d)   # i32.load8_s / _u (bool: 0 or 1)
      when 2 then e(ty[2] ? 0x2e : 0x2f)
      when 4 then e(0x28)
      when 8 then e(0x29)
      else raise Refused, "load of #{ty[1]} bytes"
      end
    elsif ty[0] == "ptr"
      e(0x29)
    else
      e(ty[1] == 4 ? 0x2a : 0x2b)
    end
    memarg
  end

  def store_op(ty)
    if ty[0] == "int"
      case ty[1]
      when 1 then e(0x3a)
      when 2 then e(0x3b)
      when 4 then e(0x36)
      when 8 then e(0x37)
      else raise Refused, "store of #{ty[1]} bytes"
      end
    elsif ty[0] == "ptr"
      e(0x37)
    else
      e(ty[1] == 4 ? 0x38 : 0x39)
    end
    memarg
  end

  # (call TYPE CALLEE ARG*): pushes the arguments and calls. Returns the wasm type of the result, nil for void.
  def call(x)
    ret = parse_type(x[1])
    callee = x[2]
    raise Refused, "indirect call" unless callee.is_a?(IRSym) && callee.sig == "&"
    args = x.drop(3)
    raise Refused, "variadic call" if head_of(args[0]) == "variadic"
    args.each do |a|
      h = head_of(a)
      raise Refused, "aggregate argument (#{h})" if h == "byval" || h == "sret"
    end
    arg_types = args.map { |a| wtype(op_type(a)) }
    args.each { |a| push_op(a) }
    name = callee.name
    idx = if @mod.defines?(name)
            @mod.defined_index.fetch(name) { raise BadIR, "no index for #{name}" }
          else
            @mod.import_of(name, arg_types, wtype(ret))
          end
    e(0x10); leb_u(idx)
    wtype(ret)
  end

  # ---- statements

  def stmt_list(list)
    list.each_with_index do |s, i|
      nxt = list[i + 1]
      @pending_brk = (head_of(s) == "loop" && head_of(nxt) == "label") ? nxt[1].to_s : nil
      stmt(s)
    end
  end

  # The label that ends a loop body: the last statement of the body, or of a block that ends it.
  def tail_label(form)
    last = form.drop(1).last
    case head_of(last)
    when "label" then last[1].to_s
    when "block" then tail_label(last)
    else nil
    end
  end

  def stmt(s)
    raise BadIR, "statement is not a form: #{form_text(s)}" unless s.is_a?(Array)
    h = head_of(s)
    case h
    when "block"
      stmt_list(s.drop(1))
    when "let"
      info = reg_info(s[1])
      v = rval(s[3])
      raise BadIR, "let #{s[1]}: a value of wasm type #{v.inspect} for #{info[1].inspect}" if v != info[1]
      e(0x21); leb_u(info[0])
    when "set"
      info = reg_info(s[1])
      push_op(s[2], info[1])
      e(0x21); leb_u(info[0])
    when "store", "store.v"
      ty = parse_type(s[1])
      raise Refused, "store of #{ty[0]}" if wtype(ty).nil?
      addr32(s[2])
      push_op(s[3], wtype(ty))
      store_op(ty)
    when "copy"
      n = as_int(s[1])
      addr32(s[2])
      addr32(s[3])
      e(0x41); leb_s(n)
      e(0xfc, 0x0a, 0x00, 0x00)            # memory.copy: destination, source, length
    when "eval"
      inner = s[1]
      raise Refused, "eval of #{head_of(inner)}" unless head_of(inner) == "call"
      ret = call(inner)
      e(0x1a) if ret                        # drop the unused result
    when "if"
      push_op(s[1], :i32)
      @labels << [:if]
      e(0x04, 0x40)
      then_part = s[2]
      else_part = s[3]
      raise BadIR, "if without a then" unless head_of(then_part) == "then"
      stmt_list(then_part.drop(1))
      if else_part
        raise BadIR, "bad else" unless head_of(else_part) == "else"
        e(0x05)
        stmt_list(else_part.drop(1))
      end
      e(0x0b)
      @labels.pop
    when "loop"
      body = s[1]
      step = s[2]
      raise BadIR, "loop without body" unless head_of(body) == "body"
      raise BadIR, "loop without step" unless head_of(step) == "step"
      id = @loop_n
      @loop_n += 1
      @brk[@pending_brk] = id if @pending_brk
      @pending_brk = nil
      cont = tail_label(body)
      @cont[cont] = id if cont
      @labels << [:brk, id]
      e(0x02, 0x40)                        # block: the break target
      @labels << [:loop, id]
      e(0x03, 0x40)                        # loop: the back edge
      @labels << [:cont, id]
      e(0x02, 0x40)                        # block: the continue target, just before the step
      stmt_list(body.drop(1))
      e(0x0b)
      @labels.pop
      stmt_list(step.drop(1))
      e(0x0c); leb_u(0)                    # br to the loop head
      e(0x0b)
      @labels.pop
      e(0x0b)
      @labels.pop
    when "break"
      e(0x0c); leb_u(label_depth(:brk, nil))
    when "continue"
      e(0x0c); leb_u(label_depth(:cont, nil))
    when "goto"
      # the labels that end a loop body or follow a loop are the loop's continue and break; any other goto is refused
      name = s[1].to_s
      if @cont.key?(name)
        e(0x0c); leb_u(label_depth(:cont, @cont[name]))
      elsif @brk.key?(name)
        e(0x0c); leb_u(label_depth(:brk, @brk[name]))
      else
        raise Refused, "goto \"#{name}\" (not the end of a loop body or the label after one)"
      end
    when "label"
      name = s[1].to_s
      raise Refused, "label \"#{name}\" (not the end of a loop body or the label after one)" unless @cont.key?(name) || @brk.key?(name)
    when "return"
      if s.length > 1
        raise BadIR, "return value in a void function" if @result.nil?
        push_op(s[1], @result)
      else
        raise BadIR, "return without a value in a function that returns a value" unless @result.nil?
      end
      restore_sp
      e(0x0f)
    when "unreachable", "trap"
      e(0x00)
    when "nonnull"
      # (nonnull P): traps when the pointer is null
      push_op(s[1])
      e(0x50)                              # i64.eqz
      e(0x04, 0x40); e(0x00); e(0x0b)      # if unreachable end
    when "bounds"
      # (bounds IDX N): traps unless 0 <= IDX < N. The index is compared as unsigned, so a negative one traps too.
      raise Refused, "bounds with a run-time limit" if s[2].is_a?(String) && s[2][0] == "%"
      push_i64(s[1], false)
      e(0x21); leb_u(@tmp64)
      e(0x20); leb_u(@tmp64)
      e(0x42); leb_s(signed64(as_int(s[2])))
      e(0x5a)                              # i64.ge_u
      e(0x04, 0x40); e(0x00); e(0x0b)      # if unreachable end
    when "unsupported"
      raise Refused, unsupported_text(s)
    else
      raise Refused, "statement (#{h || form_text(s)})"
    end
  end

  # The IR's own marker for a node the front end did not lower, e.g. (unsupported cast): the refusal names it.
  def unsupported_text(x)
    "(" + x.map { |y| form_text(y) }.join(" ") + ")"
  end

  # The number of wasm blocks between here and the innermost entry of the kind (of the loop id, when given).
  def label_depth(kind, id)
    depth = 0
    @labels.reverse_each do |l|
      return depth if l[0] == kind && (id.nil? || l[1] == id)
      depth += 1
    end
    raise Refused, "a jump out of the loop it is in (not supported yet)" unless id.nil?
    raise BadIR, "#{kind} outside a loop"
  end

  def restore_sp
    e(0x20); leb_u(@old_local)
    e(0x24); leb_u(0)                      # global.set 0: the stack pointer
  end

  # ---- the whole function

  def compile
    setup
    # prologue: the frame base lies below the stack pointer found on entry, aligned to 16
    e(0x23); leb_u(0)                      # global.get 0
    e(0x21); leb_u(@old_local)
    e(0x20); leb_u(@old_local)
    e(0x41); leb_s(@frame)
    e(0x6b)                                # i32.sub
    e(0x41); leb_s(-16)
    e(0x71)                                # i32.and
    e(0x21); leb_u(@fp_local)
    e(0x20); leb_u(@fp_local)
    e(0x24); leb_u(0)                      # global.set 0
    stmt_list(@body)
    if @result.nil?
      restore_sp
    else
      e(0x00)                              # the end of a value-returning function is not reached (undefined in C++)
    end
    e(0x0b)
  end

  # The function body as a code section entry: local declarations, then the code.
  def encode
    out = []
    uleb(@local_types.length, out)
    @local_types.each { |t| out << 1 << VT[t] }
    out.concat(@code)
    out
  end
end

# ------------------------------------------------------------------ the module

def emit_module(src)
  forms = parse_forms(tokenize(src))
  defs = {}
  order = []
  forms.each do |f|
    h = head_of(f)
    if h == "ir-module"
      next
    elsif h == "function"
      name = f[1]
      raise BadIR, "function without a name" unless name.is_a?(IRStr)
      nm = name.to_s
      raise BadIR, "function #{nm} twice" if defs.key?(nm)
      defs[nm] = f
      order << nm
    elsif h == "global"
      raise Refused, "global #{form_text(f[1])} (static data is not lowered yet)"
    else
      raise Refused, "top-level form #{h || form_text(f)}"
    end
  end
  mod = Module_.new(defs)
  # The import list comes from the calls, so the first pass only collects it: the index of a defined function is not
  # known until the imports are, and the calls of the first pass are discarded.
  order.each_with_index { |nm, i| mod.defined_index[nm] = i }
  order.each { |nm| Fn.new(mod, defs[nm]).compile }
  order.each_with_index { |nm, i| mod.defined_index[nm] = mod.imports.length + i }
  bodies = order.map do |nm|
    fn = Fn.new(mod, defs[nm])
    fn.compile
    [nm, fn]
  end
  encode_module(mod, bodies)
end

def encode_module(mod, bodies)
  out = [0x00, 0x61, 0x73, 0x6d, 0x01, 0x00, 0x00, 0x00]
  # types
  t = []
  uleb(mod.types.length, t)
  mod.types.each do |params, result|
    t << 0x60
    uleb(params.length, t)
    params.each { |p| t << VT[p] }
    if result.nil?
      uleb(0, t)
    else
      uleb(1, t)
      t << VT[result]
    end
  end
  section(1, t, out)
  # imports: functions of the module "env"
  unless mod.imports.empty?
    im = []
    uleb(mod.imports.length, im)
    mod.imports.each do |name, ti|
      name_bytes("env", im)
      name_bytes(name, im)
      im << 0x00
      uleb(ti, im)
    end
    section(2, im, out)
  end
  # functions
  fsec = []
  uleb(bodies.length, fsec)
  bodies.each { |nm, fn| uleb(fn.type_index, fsec) }
  section(3, fsec, out)
  # memory: one memory of two pages; the stack grows down from its top
  mem = []
  uleb(1, mem)
  mem << 0x00
  uleb(2, mem)
  section(5, mem, out)
  # global 0: the stack pointer, mutable i32, starts at the top of the memory
  gl = []
  uleb(1, gl)
  gl << VT[:i32] << 0x01
  gl << 0x41
  sleb(2 * 65536, gl)
  gl << 0x0b
  section(6, gl, out)
  # exports: the memory, then each function under its IR name
  ex = []
  uleb(1 + bodies.length, ex)
  name_bytes("memory", ex)
  ex << 0x02
  uleb(0, ex)
  bodies.each_with_index do |(nm, _), i|
    raise Refused, "function name #{nm.inspect} is not ASCII (an export name must be UTF-8)" if nm.bytes.any? { |b| b >= 0x80 }
    name_bytes(nm, ex)
    ex << 0x00
    uleb(mod.imports.length + i, ex)
  end
  section(7, ex, out)
  # code
  code = []
  uleb(bodies.length, code)
  bodies.each do |nm, fn|
    b = fn.encode
    uleb(b.length, code)
    b.each { |x| code << x }
  end
  section(10, code, out)
  out
end

# File.open is in mruby-io; the QBE emitter reads files the same way.
def read_input(path)
  File.open(path, "rb") { |f| f.read }
end

def main(argv)
  args = argv.dup
  if args.length > 1
    $stderr.write("usage: pathb-wasm-emit.rb [FILE.ir | -] > out.wasm\n")
    return 1
  end
  src = (args.empty? || args[0] == "-") ? $stdin.read : read_input(args[0])
  begin
    bytes = emit_module(src)
  rescue Refused => e
    $stderr.write("refused: #{e.message}\n")
    return 3
  rescue BadIR => e
    $stderr.write("error: #{e.message}\n")
    return 1
  end
  $stdout.write(bytes.pack("C*"))
  0
end

rc = main(ARGV)
exit(rc) if rc != 0
