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
# Usage with --asan (before the file): scripts/mrb scripts/pathb-wasm-emit.rb --asan prog.ir > out.wasm. The mruby
# interpreter has no ENV, so the mode is an argument, and tests/wasm/run.sh passes it when NFCXX_WASM_ASAN=1.
# The mode is an AddressSanitizer-style check (docs/notes/pathb-wasm.md, "AddressSanitizer"): a shadow region at the
# top of the memory, redzones around the static objects and the slots of each frame, and a check before each load,
# store and copy that reports a violation through the import env.__asan_report and traps. Without --asan the module is
# the same as before the mode existed, byte for byte.
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
# if, loop with break and continue, switch (arms that end in a jump, no fallthrough), return, copy, trap and unreachable,
# and static data: the defined globals and string data, at fixed addresses in the memory, with their initializers.
# Everything else is refused with the reason on stderr: general goto and labels, extern and dynamically initialized
# globals (when used), bit-field access, aggregate parameters, results and arguments, variadic calls, function pointers,
# indirect calls, inline assembly, VLAs, exceptions and the 16-byte types. Those refusals are the next steps, not silent
# drops.

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
  attr_accessor :data_end, :segments   # the end of the static objects; [address, bytes] of each data segment
  attr_accessor :asan, :pages, :stack_top, :shadow_base, :check_type, :check_index   # the ASan mode (see emit_module)

  def initialize(defs)
    @defs = defs                 # name => the (function ...) form
    @statics = {}                # name => StaticObj
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

  # The static objects of the module (defined globals and string data), by name. Each has its address (see
  # layout_statics); an object the module does not define is refused where it is used.
  def add_statics(objs)
    @statics = {}
    objs.each do |o|
      raise BadIR, "static object #{o.name} defined twice" if @statics.key?(o.name)
      @statics[o.name] = o
    end
  end

  def static_addr(name)
    static_obj(name).addr
  end

  # The object of a name. A use of one that has no storage here (an extern or dynamically initialized global) is refused.
  def static_obj(name)
    o = @statics.fetch(name) { raise Refused, "static object @\"#{name}\" is not defined in this module" }
    raise Refused, o.refusal unless o.refusal.nil?
    o
  end
end

# ------------------------------------------------------------------ static data

# A static object: a defined global (init is its (init ITEM*) form) or string data (data is true, and bytes holds it).
# addr is its address in the linear memory; bytes is its contents, size bytes long.
class StaticObj
  # refusal: the reason a use of the object is refused (no storage here: an extern or dynamic global), or nil
  attr_accessor :name, :size, :align, :init, :data, :bytes, :addr, :refusal

  def initialize(name, size, align, init, data)
    @name = name
    @size = size
    @align = align
    @init = init
    @data = data
    @bytes = nil
    @addr = nil
    @refusal = nil
  end
end

# Address 0 is no object, so a null pointer never points at one.
STATIC_BASE = 16

# ASan mode. The shadow byte of the granule (8 bytes) at address a is the byte at shadow_base + a / 8: 0 when the granule
# is addressable, k in 1..7 when its first k bytes are, and a poison code (>= 0x80) otherwise, as in libasan. The codes
# are libasan's: a stack redzone 0xf1, a global redzone 0xf9, and 0xf5 for the frame of a function that has returned.
ASAN_RZ = 32                  # the redzone before and after each object (a static object or a slot)
ASAN_STACK_RZ = 0xf1
ASAN_GLOBAL_RZ = 0xf9
ASAN_RETURN = 0xf5

# (global "NAME" TYPE BYTES ALIGN [(static)|(weak)] INIT): a defined global with its initializer. The TYPE is not needed:
# the size and alignment come from BYTES and ALIGN. An extern declaration, a thread-local and a dynamic initializer are
# refused.
def parse_global(f)
  raise BadIR, "global form too short: #{form_text(f)}" if f.length < 6
  raise BadIR, "global name is not a string" unless f[1].is_a?(IRStr)
  name = f[1].to_s
  size = as_int(f[3].to_s)
  align = as_int(f[4].to_s)
  raise BadIR, "global #{name}: alignment #{align} is not a power of two" unless align >= 1 && (align & (align - 1)) == 0
  rest = f.drop(5)
  rest = rest.reject { |p| head_of(p) == "static" || head_of(p) == "weak" }
  thread = rest.any? { |p| head_of(p) == "thread" }
  rest = rest.reject { |p| head_of(p) == "thread" }
  raise BadIR, "global #{name}: expected one INIT" if rest.length != 1
  init = rest[0]
  h = head_of(init)
  raise BadIR, "global #{name}: unknown INIT #{form_text(init)}" if h != "init" && h != "extern" && h != "unsupported"
  o = StaticObj.new(name, size, align, h == "init" ? init : nil, false)
  # no storage here: a use of the object is refused, and a declaration that nothing uses is not
  if thread
    o.refusal = "thread-local global #{name} (not lowered)"
  elsif h == "extern"
    o.refusal = "extern global #{name} (declared here, defined elsewhere: no storage in this module)"
  elsif h == "unsupported"
    o.refusal = "global #{name}: #{form_text(init)}"
  end
  o
end

# (data "NAME" TYPE (string "...")): string data, an array of bytes padded with zeros to its type's size.
def parse_data(d)
  raise BadIR, "data form too short: #{form_text(d)}" if d.length != 4 || !d[1].is_a?(IRStr)
  name = d[1].to_s
  ty = parse_type(d[2])
  raise BadIR, "data #{name} is not an array" if ty[0] != "array" || ty[1].nil?
  text = d[3]
  raise Refused, "data #{name}: #{form_text(text)}" if head_of(text) != "string"
  elem = ty[2]
  raise Refused, "wide string data #{name} (not lowered)" unless elem[0] == "int" && elem[1] == 1
  raise BadIR, "string data #{name}: no string" unless text[1].is_a?(IRStr)
  raw = text[1].bytes.dup
  raise BadIR, "string data #{name} longer than its array" if raw.length > ty[1]
  bytes = raw + [0] * (ty[1] - raw.length)
  o = StaticObj.new(name, ty[1], 1, nil, true)
  o.bytes = bytes
  o
end

# Gives each object an address, in order, after address 0. Returns the end of the data: the stack starts above it.
# With asan, each object is 8-byte aligned and has a redzone before it and after the last one (a granule of the
# redzone is never shared with an object), so that the shadow of the data is whole granules.
def layout_statics(objs, asan = false)
  pos = STATIC_BASE
  objs.each do |o|
    next unless o.refusal.nil?             # no storage for those
    al = asan && o.align < 8 ? 8 : o.align
    pos += ASAN_RZ if asan
    pos = (pos + al - 1) / al * al
    o.addr = pos
    pos += o.size
    pos = (pos + 7) / 8 * 8 if asan
  end
  pos += ASAN_RZ if asan && objs.any? { |o| o.refusal.nil? }
  pos
end

# ASan: the shadow of the static data, as [address, bytes] data segments. A granule of a redzone is ASAN_GLOBAL_RZ, the
# last granule of an object whose size is not a multiple of 8 holds its size mod 8, and the other granules are 0 (the
# memory starts zeroed). Null page granules are left at 0: no static object is there and no check reports them.
def static_shadow(objs, data_end, shadow_base)
  codes = Array.new(data_end / 8, 0)
  cur = STATIC_BASE / 8
  objs.each do |o|
    next unless o.refusal.nil?
    g = o.addr / 8
    (cur...g).each { |i| codes[i] = ASAN_GLOBAL_RZ }
    codes[g + o.size / 8] = o.size % 8 if o.size % 8 != 0
    cur = g + (o.size + 7) / 8
  end
  (cur...codes.length).each { |i| codes[i] = ASAN_GLOBAL_RZ }
  segs = []
  i = 0
  while i < codes.length
    if codes[i] == 0
      i += 1
      next
    end
    j = i
    j += 1 while j < codes.length && codes[j] != 0
    segs << [shadow_base + i, codes[i...j]]
    i = j
  end
  segs
end

# The little-endian bytes of an integer of n bytes.
def le_bytes(v, n)
  (0...n).map { |i| (v >> (8 * i)) & 255 }
end

# The contents of a defined global from its (init ITEM*) form. The items are (scalar OFF TYPE VALUE), (addr OFF TYPE
# TARGET ADD), (bytes OFF N @"string"), (zero OFF N) and (bitfield OFF UNIT BOFF WIDTH TYPE VALUE). The bytes of the
# other items are written first; a bit-field's bits are ORed in after them, since the bit-fields share bytes.
def static_contents(mod, o)
  items = []                               # [offset, length, bit-field?, bytes (nil: zero) or [[byte, bits]...]]
  o.init.drop(1).each do |it|
    h = head_of(it)
    if h == "scalar"
      off = as_int(it[1].to_s)
      ty = parse_type(it[2])
      val = it[3]
      size = type_size(ty)
      if head_of(val) == "null"
        items << [off, size, false, nil]
      elsif head_of(val) == "const" && ty[0] == "float"
        v = float_value(val[2].to_s)
        items << [off, size, false, (size == 4 ? [v].pack("e") : [v].pack("E")).bytes]
      elsif head_of(val) == "const" && (ty[0] == "int" || ty[0] == "ptr")
        items << [off, size, false, le_bytes(as_int(val[2].to_s), size)]
      else
        raise Refused, "scalar item operand #{form_text(val)}"
      end
    elsif h == "addr"
      off = as_int(it[1].to_s)
      ty = parse_type(it[2])
      target = it[3]
      add = as_int(it[4].to_s)
      raise Refused, "address item of type #{form_text(it[2])} (not a pointer)" if ty[0] != "ptr"
      raise Refused, "address item target #{form_text(target)}" unless target.is_a?(IRSym)
      raise Refused, "address of the function #{target.name} in a static initializer (a function table is not lowered)" if target.sig == "&"
      items << [off, 8, false, le_bytes(mod.static_addr(target.name) + add, 8)]
    elsif h == "bytes"
      off = as_int(it[1].to_s)
      n = as_int(it[2].to_s)
      src = it[3]
      raise Refused, "bytes item from #{form_text(src)}" unless src.is_a?(IRSym) && src.sig == "@"
      so = mod.static_obj(src.name)
      raise Refused, "bytes item from the global #{src.name} (only string data)" unless so.data
      raise BadIR, "bytes item of #{n} bytes from a #{so.bytes.length}-byte string" if so.bytes.length != n
      items << [off, n, false, so.bytes]
    elsif h == "zero"
      off = as_int(it[1].to_s)
      n = as_int(it[2].to_s)
      items << [off, n, false, nil] if n != 0
    elsif h == "bitfield"
      raise BadIR, "bitfield item form" if it.length != 7
      off = as_int(it[1].to_s)
      unit = as_int(it[2].to_s)
      boff = as_int(it[3].to_s)
      width = as_int(it[4].to_s)
      raise BadIR, "bitfield item: unit #{unit}" unless [1, 2, 4, 8].include?(unit)
      raise BadIR, "bitfield item: bits #{boff}+#{width} outside a #{unit}-byte unit" if width < 1 || boff < 0 || boff + width > unit * 8
      raise Refused, "bitfield item operand #{form_text(it[6])}" if head_of(it[6]) != "const"
      v = as_int(it[6][2].to_s) & ((1 << width) - 1)
      bits = {}
      width.times do |i|
        pos = off * 8 + boff + i
        bits[pos / 8] = (bits[pos / 8] || 0) | (((v >> i) & 1) << (pos % 8))
      end
      keys = bits.keys.sort
      items << [keys[0], keys[-1] - keys[0] + 1, true, keys.map { |b| [b, bits[b]] }]
    elsif h == "unsupported"
      raise Refused, form_text(it)
    else
      raise BadIR, "unknown initializer item #{form_text(it)}"
    end
  end
  # no two items overlap, except bit-fields among themselves
  items.sort! { |a, b| a[0] <=> b[0] }
  max_end = 0
  max_bf = false
  items.each do |it|
    off = it[0]
    len = it[1]
    raise BadIR, "initializer runs past the size of #{o.name}" if off < 0 || off + len > o.size
    if off < max_end && !(it[2] && max_bf)
      raise BadIR, "initializer items overlap at offset #{off} in #{o.name}"
    end
    if off + len > max_end
      max_end = off + len
      max_bf = it[2]
    end
  end
  buf = Array.new(o.size, 0)
  items.each do |it|
    next if it[2] || it[3].nil?
    it[3].each_with_index { |b, i| buf[it[0] + i] = b }
  end
  items.each do |it|
    next unless it[2]
    it[3].each { |b, bits| buf[b] |= bits }
  end
  buf
end

# The static objects of the module, with their addresses and contents, in the order of the forms.
def build_statics(mod, objs, asan = false)
  mod.add_statics(objs)
  end_addr = layout_statics(objs, asan)
  objs.each do |o|
    o.bytes = static_contents(mod, o) unless o.data || !o.refusal.nil?
  end
  end_addr
end

# The value of a float constant's text (the IR prints the infinities and NaN by name).
def float_value(text)
  return Float::INFINITY if text == "+Infinity" || text == "Infinity"
  return -Float::INFINITY if text == "-Infinity"
  return Float::NAN if text == "NaN" || text == "nan" || text == "+NaN" || text == "-NaN"
  text.to_f
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
    @asan = mod.asan
    @frame_codes = []        # asan: the granule codes of the frame (see layout_asan_slots)
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
    slot_list = []           # asan: [name, size, align] of each slot, laid out after the loop
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
        if @asan
          slot_list << [f[1].to_s, size, align]
        else
          @frame = (@frame + align - 1) / align * align
          @slots[f[1].to_s] = @frame
          @frame += size
        end
      else
        body_start = i if body_start.nil?
      end
    end
    raise BadIR, "function without a return type" if ret.nil?
    layout_asan_slots(slot_list) if @asan
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
    if @asan
      # asan: a scratch i32 for the address of a checked access (the check reads it back, see asan_addr)
      @tmp32 = @next_local
      @local_types << :i32
      @next_local += 1
    end
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

  # asan: each slot is an object of its own, 8-byte aligned, with a redzone of ASAN_RZ bytes before it and after the last
  # one, so a granule holds the bytes of one object only. Sets the frame size (a multiple of 16) and the granule codes
  # of the frame: the redzones, the objects' granules (0) and the partial granule of an object whose size is not a
  # multiple of 8 (its size mod 8).
  def layout_asan_slots(list)
    pos = 0
    objs = []
    list.each do |name, size, align|
      pos += ASAN_RZ
      a = align < 8 ? 8 : align
      pos = (pos + a - 1) / a * a
      @slots[name] = pos
      objs << [pos, size]
      pos = (pos + size + 7) / 8 * 8
    end
    pos += ASAN_RZ unless list.empty?
    pos = (pos + 15) / 16 * 16
    @frame = pos
    @frame_codes = Array.new(pos / 8, ASAN_STACK_RZ)
    objs.each do |off, size|
      g = off / 8
      (size / 8).times { |i| @frame_codes[g + i] = 0 }
      @frame_codes[g + size / 8] = size % 8 if size % 8 != 0
    end
  end

  # ---- operands

  # The IR type of an operand (a pointer for a slot address).
  def op_type(op)
    if op.is_a?(String) && op[0] == "%"
      return reg_info(op)[2]
    end
    if op.is_a?(IRSym)
      raise Refused, "function address &\"#{op.name}\"" if op.sig == "&"
      @mod.static_addr(op.name) if op.sig == "@"    # checks that the object is defined here
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
    elsif op.is_a?(IRSym) && op.sig == "@"
      e(0x42); leb_s(@mod.static_addr(op.name))   # the address of the static object
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
      raise Refused, "function address &\"#{op.name}\"" if op.sig == "&"
      @mod.static_addr(op.name) if op.sig == "@"
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

  # The address of a memory access of size bytes, as an i32: in asan mode it is checked first (asan_addr).
  def mem_addr(op, size)
    if @asan
      asan_addr(op, size)
    else
      addr32(op)
    end
  end

  # asan: pushes the address of an access of size bytes after a call of the check, which traps on a violation. The
  # address goes through the scratch local, since the check takes it as an argument and the access needs it again.
  def asan_addr(op, size)
    addr32(op)
    e(0x22); leb_u(@tmp32)                 # local.tee
    e(0x41); leb_s(size)
    e(0x10); leb_u(@mod.check_index)       # call the check: (address, size)
    e(0x20); leb_u(@tmp32)                 # local.get: the address of the access
  end

  # asan: memory.fill of the shadow of granules [g0, g0 + len) of this frame with code. The frame base is a multiple of 16,
  # so its granules are whole: the shadow of the granule at fp + 8 * g is at shadow_base + fp / 8 + g.
  def asan_fill(g0, len, code)
    e(0x20); leb_u(@fp_local)
    e(0x41); leb_s(3); e(0x76)             # i32.shr_u: fp / 8
    e(0x41); leb_s(@mod.shadow_base + g0); e(0x6a)
    e(0x41); leb_s(code)
    e(0x41); leb_s(len)
    e(0xfc, 0x0b, 0x00)                    # memory.fill
  end

  # asan: the redzones and objects of the frame, as the shadow of its granules, runs of equal codes at a time.
  def asan_poison_frame
    runs = []
    @frame_codes.each_with_index do |c, g|
      if !runs.empty? && runs[-1][2] == c
        runs[-1][1] += 1
      else
        runs << [g, 1, c]
      end
    end
    runs.each { |g0, len, code| asan_fill(g0, len, code) }
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
      mem_addr(x[2], type_size(ty))
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
      # a loop or a switch followed by a label: the label is the break target (the IR's goto "label" leaves it)
      @pending_brk = ((head_of(s) == "loop" || head_of(s) == "switch") && head_of(nxt) == "label") ? nxt[1].to_s : nil
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
      mem_addr(s[2], type_size(ty))
      push_op(s[3], wtype(ty))
      store_op(ty)
    when "copy"
      n = as_int(s[1])
      mem_addr(s[2], n)
      mem_addr(s[3], n)
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
    when "switch"
      switch_stmt(s)
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
    when "loc", "likely", "unlikely"
      # source position and branch hints (docs/notes/ubsan.md): no code
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

  # ---- switch. The body's case and default markers (also inside blocks of the body) split it into arms, in order. The
  # selector picks the arm of its marker, control falls through the arms that follow, and break leaves the switch.
  # The lowering: a block E for the exit (the break target), one block per arm, nested so that arm k starts right after
  # the end of its block L_k; a compare chain that branches to an arm (br_if L_k), or to the default arm, or to E.
  # An arm that is not empty must end in a jump (break, continue, return, unreachable, trap, goto), or be the last one:
  # falling into the next arm is refused, as docs/notes/pathb-stage2.md section 2 asks.
  def switch_stmt(s)
    brk_label = @pending_brk
    @pending_brk = nil
    raise BadIR, "switch form" if s.length != 3 || head_of(s[2]) != "body"
    sel = s[1]
    sel_w = op_wtype(sel)
    raise Refused, "switch on a value of wasm type #{sel_w.inspect}" unless sel_w == :i32 || sel_w == :i64
    # the arms: a marker starts a new arm when the arm before it has statements; consecutive markers share one arm
    arms = []                              # [markers, statements]
    cur = nil
    flatten_blocks(s[2].drop(1), []).each do |st|
      h = head_of(st)
      if h == "case" || h == "default"
        if cur.nil? || !cur[1].empty?
          cur = [[], []]
          arms << cur
        end
        cur[0] << st
      else
        raise Refused, "statement before the first case label of a switch (not lowered)" if cur.nil?
        cur[1] << st
      end
    end
    arms.each_with_index do |arm, k|
      next if k == arms.length - 1
      unless ends_list?(arm[1])
        raise Refused, "switch fallthrough: the case arm with #{form_text(arm[1].last)} falls into the next arm (not lowered)"
      end
    end
    default_arm = nil
    seen = {}
    cases = []                             # [arm index, selector constant]
    mask = sel_w == :i32 ? 0xffffffff : 0xffffffffffffffff
    arms.each_with_index do |arm, k|
      arm[0].each do |m|
        if head_of(m) == "default"
          raise BadIR, "two default labels" unless default_arm.nil?
          default_arm = k
        else
          raise BadIR, "case label without a constant: #{form_text(m)}" unless head_of(m[1]) == "const"
          n = as_int(m[1][2].to_s) & mask
          raise BadIR, "duplicate case value #{n}" if seen.key?(n)
          seen[n] = true
          n -= mask + 1 if n > mask >> 1          # the bit pattern of the selector's width, signed
          cases << [k, n]
        end
      end
    end
    push_op(sel)
    sel_local = @next_local
    @next_local += 1
    @local_types << sel_w
    e(0x21); leb_u(sel_local)
    id = @loop_n                           # a switch takes an id from the loop counter: its break label names it
    @loop_n += 1
    @brk[brk_label] = id if brk_label
    n = arms.length
    @labels << [:brk, id]
    e(0x02, 0x40)                          # block E: the exit
    (n - 1).downto(0) do |k|
      @labels << [:arm, k]
      e(0x02, 0x40)                        # block L_k
    end
    cases.each do |k, v|
      e(0x20); leb_u(sel_local)
      if sel_w == :i32
        e(0x41); leb_s(v)
        e(0x46)                            # i32.eq
      else
        e(0x42); leb_s(v)
        e(0x51)                            # i64.eq
      end
      e(0x0d); leb_u(k)                    # br_if L_k
    end
    e(0x0c); leb_u(default_arm.nil? ? n : default_arm)   # br to the default arm, or out of the switch
    n.times do |k|
      e(0x0b)                              # end of L_k: arm k starts here
      raise BadIR, "switch labels out of order" unless @labels.pop == [:arm, k]
      stmt_list(arms[k][1])
    end
    e(0x0b)                                # end of E
    raise BadIR, "switch labels out of order" unless @labels.pop == [:brk, id]
  end

  # The statements of a list with the blocks in it expanded (a block is a sequence; the case markers may sit in one).
  def flatten_blocks(list, out)
    list.each do |s|
      if head_of(s) == "block"
        flatten_blocks(s.drop(1), out)
      else
        out << s
      end
    end
    out
  end

  # Whether a list of statements ends in a jump, so that control does not reach the statement after it.
  def ends_list?(list)
    !list.empty? && ends_jump?(list.last)
  end

  def ends_jump?(st)
    case head_of(st)
    when "break", "continue", "return", "unreachable", "trap", "goto" then true
    when "block" then ends_list?(st.drop(1))
    when "if"
      then_part = st[2]
      else_part = st[3]
      !else_part.nil? && ends_list?(then_part.drop(1)) && ends_list?(else_part.drop(1))
    else false
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
    # asan: the frame has returned, so its shadow says so (a use after the return is reported as such)
    asan_fill(0, @frame / 8, ASAN_RETURN) if @asan && @frame > 0
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
    asan_poison_frame if @asan && @frame > 0
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

# ------------------------------------------------------------------ asan: the check

# asan: the body of the check, check(a, n) for an access of n bytes at a: it traps unless every granule the access
# touches is addressable. In a granule the access uses the bytes up to the last one it touches, and that count must be
# within the shadow byte's k (0 is all eight). A violation calls env.__asan_report(a, n, code) and traps: code is the
# poison code of the granule, or for a partial granule (k in 1..7, which ends an object) the code of the next granule,
# the redzone that follows the object. The function is the module's last one (after the defined functions).
#
#   if n == 0 return;  last = a + n - 1;  g = a >> 3
#   loop:  s = shadow[g];  if s != 0:  end = min(last - 8g + 1, 8)
#            if !(s < 8 && end <= s): report(a, n, s >= 0x80 ? s : shadow[g + 1]); unreachable
#          g = g + 1; br_if loop while g <= last >> 3
def asan_check_body(mod)
  sh = mod.shadow_base
  rep = mod.import_index.fetch("__asan_report")
  c = []
  c.concat([0x01, 0x04, VT[:i32]])                  # locals: last, g, s, end (after the parameters a and n)
  c.concat([0x20, 1, 0x45, 0x04, 0x40, 0x0f, 0x0b]) # if n == 0: return
  c.concat([0x20, 0, 0x20, 1, 0x6a, 0x41, 1, 0x6b, 0x21, 2])   # last = a + n - 1
  c.concat([0x20, 0, 0x41, 3, 0x76, 0x21, 3])                  # g = a >> 3
  c.concat([0x03, 0x40])                                       # loop
  c << 0x41; sleb(sh, c)
  c.concat([0x20, 3, 0x6a, 0x2d, 0, 0, 0x21, 4])               # s = shadow[g] (i32.load8_u)
  c.concat([0x20, 4, 0x04, 0x40])                              # if s != 0
  c.concat([0x20, 2, 0x20, 3, 0x41, 3, 0x74, 0x6b, 0x41, 1, 0x6a, 0x21, 5])  # end = last - 8g + 1
  c.concat([0x41, 8, 0x20, 5, 0x20, 5, 0x41, 8, 0x4b, 0x1b, 0x21, 5])        # end = min(end, 8)
  c.concat([0x20, 4, 0x41, 8, 0x49])                           # s < 8
  c.concat([0x20, 5, 0x20, 4, 0x4d, 0x71])                     # and end <= s
  c.concat([0x45, 0x04, 0x40])                                 # if not: the access is a violation
  c.concat([0x20, 0, 0x20, 1])                                 # report(a, n, code)
  c.concat([0x20, 4, 0x41]); sleb(0x80, c); c << 0x4f          # s >= 0x80 (i32.ge_u)
  c.concat([0x04, 0x7f, 0x20, 4, 0x05])                        # if (result i32) s else
  c << 0x41; sleb(sh, c)
  c.concat([0x20, 3, 0x6a, 0x2d, 0, 1])                        # shadow[g + 1] (the offset is 1)
  c.concat([0x0b])                                             # end
  c << 0x10; uleb(rep, c)                                      # call env.__asan_report
  c.concat([0x00, 0x0b])                                       # unreachable; end (the violation)
  c.concat([0x0b])                                             # end (s != 0)
  c.concat([0x20, 3, 0x41, 1, 0x6a, 0x22, 3])                  # g = g + 1
  c.concat([0x20, 2, 0x41, 3, 0x76, 0x4d, 0x0d, 0])            # br_if loop while g <= last >> 3
  c.concat([0x0b, 0x0b])                                       # end (loop); end (function)
  c
end

# asan: the shadow of the static data (see static_shadow), and the mode's imports and check function.
def asan_setup(mod, objs)
  pages = [2, (mod.data_end + 65536 + 57343) / 57344].max
  mod.pages = pages
  mod.shadow_base = pages * 57344        # the top of the memory less a shadow of 1/8 of it: pages * 65536 * 7 / 8
  mod.stack_top = mod.shadow_base
  mod.segments += static_shadow(objs, mod.data_end, mod.shadow_base)
  mod.import_of("__asan_report", [:i32, :i32, :i32], nil)
  mod.check_type = mod.type_of([:i32, :i32], nil)
  mod.check_index = 0                    # set once the imports are known (emit_module); the first pass discards its calls
end

# ------------------------------------------------------------------ the module

def emit_module(src, asan = false)
  forms = parse_forms(tokenize(src))
  defs = {}
  order = []
  objs = []
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
      objs << parse_global(f)
    elsif h == "data"
      objs << parse_data(f)
    else
      raise Refused, "top-level form #{h || form_text(f)}"
    end
  end
  mod = Module_.new(defs)
  mod.asan = asan
  mod.data_end = build_statics(mod, objs, asan)
  # the memory starts zeroed, so only the objects with a nonzero byte need a data segment
  mod.segments = objs.select { |o| o.refusal.nil? && o.bytes.any? { |b| b != 0 } }.map { |o| [o.addr, o.bytes] }
  if asan
    asan_setup(mod, objs)
  else
    # the memory: two pages (128 KB), or more when the static objects leave less than 64 KB for the stack; the stack
    # grows down from its top, above the static objects
    mod.pages = [2, (mod.data_end + 65536 + 65535) / 65536].max
    mod.stack_top = mod.pages * 65536
  end
  # The import list comes from the calls, so the first pass only collects it: the index of a defined function is not
  # known until the imports are, and the calls of the first pass are discarded.
  order.each_with_index { |nm, i| mod.defined_index[nm] = i }
  order.each { |nm| Fn.new(mod, defs[nm]).compile }
  order.each_with_index { |nm, i| mod.defined_index[nm] = mod.imports.length + i }
  # the check is the module's last function, after the defined ones
  mod.check_index = mod.imports.length + order.length if asan
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
  # functions (asan: the check is the last one)
  fsec = []
  uleb(bodies.length + (mod.asan ? 1 : 0), fsec)
  bodies.each { |nm, fn| uleb(fn.type_index, fsec) }
  uleb(mod.check_type, fsec) if mod.asan
  section(3, fsec, out)
  # memory: the pages were chosen with the static data (emit_module); in asan mode the top 1/8 is the shadow
  mem = []
  uleb(1, mem)
  mem << 0x00
  uleb(mod.pages, mem)
  section(5, mem, out)
  # global 0: the stack pointer, mutable i32, starts at the top of the memory (asan: below the shadow)
  gl = []
  uleb(1, gl)
  gl << VT[:i32] << 0x01
  gl << 0x41
  sleb(mod.stack_top, gl)
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
  uleb(bodies.length + (mod.asan ? 1 : 0), code)
  bodies.each do |nm, fn|
    b = fn.encode
    uleb(b.length, code)
    b.each { |x| code << x }
  end
  if mod.asan
    b = asan_check_body(mod)
    uleb(b.length, code)
    b.each { |x| code << x }
  end
  section(10, code, out)
  # data: the segments of the static objects, each at its address (an active segment in memory 0)
  unless mod.segments.empty?
    dsec = []
    uleb(mod.segments.length, dsec)
    mod.segments.each do |addr, bytes|
      dsec << 0x00 << 0x41                 # active, memory 0: the offset is an i32.const
      sleb(addr, dsec)
      dsec << 0x0b
      uleb(bytes.length, dsec)
      bytes.each { |b| dsec << b }
    end
    section(11, dsec, out)
  end
  out
end

# File.open is in mruby-io; the QBE emitter reads files the same way.
def read_input(path)
  File.open(path, "rb") { |f| f.read }
end

def main(argv)
  args = argv.dup
  asan = args.first == "--asan"
  args.shift if asan
  if args.length > 1
    $stderr.write("usage: pathb-wasm-emit.rb [--asan] [FILE.ir | -] > out.wasm\n")
    return 1
  end
  src = (args.empty? || args[0] == "-") ? $stdin.read : read_input(args[0])
  begin
    bytes = emit_module(src, asan)
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
