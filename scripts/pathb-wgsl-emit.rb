# Path B: emit WGSL (WebGPU compute shaders) from the nfcxx mid-level IR text (docs/notes/pathb-stage2.md), for the SYCL
# path (docs/notes/sycl-webgpu.md).
#
# Usage: scripts/mrb scripts/pathb-wgsl-emit.rb [--manifest=FILE] [--narrow-i64] [FILE.ir | -] > out.wgsl
#
# Exit status: 0 the WGSL was written; 3 refused (a node, type or form not handled yet, reason on stderr); 1 malformed IR.
#
# Kernels. Every function whose name contains `__nfcxx_sycl_entry_` is a kernel (lib/sycl/include/sycl/sycl.hpp). Only
# the functions a kernel reaches are lowered, so the rest of a hosted translation unit (the host half of the program) is
# never looked at. Each kernel becomes a compute entry point `k<N>` plus the WGSL functions it calls. The manifest has one
# line per kernel, `k<N> TAB key TAB size`, where the key is the name of the closure type the kernel casts `__nfcxx_sycl_closure()`
# to, without its leading `_Z` (what typeid(F).name() gives on the host, with g++ and with this front end).
#
# Memory model. WGSL has no general pointers, so an IR pointer is a u32 and the top two bits say which memory it is in:
#   00  the heap: one storage buffer, `array<atomic<u32>>`, addresses HEAP_BASE + byte offset. The SYCL buffers and USM blocks
#       are where the host allocated them; word 1 is the trap flag.
#   11  the kernel's closure object, in a uniform buffer of 4096 bytes (the host copies it for each dispatch). Read-only, and
#       uniform to the shader's uniformity analysis, so loop bounds taken from captured variables may guard a barrier.
#   01  work-group memory (`wg`): WG_WORDS words (a pipeline constant) of local_accessor storage, then 256 words of scratch
#       for the group algorithms.
#   10  the invocation's own stack (`stk`, a private array): the IR slots that need an address. A scalar slot that is only
#       loaded and stored by name becomes a WGSL local variable instead.
# A load or store of 1, 2, 4 bytes is on the word that holds it (shifts and masks; a byte store is an and/or pair); a
# 4-byte access must be 4-aligned. 8-byte integers are narrowed to 32 bits (--narrow-i64, the only mode): `unsigned long`
# is u32, so size_t arithmetic is exact below 2^32, and a pointer in memory keeps its low word. double is refused.
#
# Checked operations (division, shifts, bounds, nonnull, trap) cannot trap on a GPU: they set the trap flag with
# atomicMax(heap[1], code) and execution goes on with WGSL's defined result. The host reads the flag after the dispatch.
#   codes: 1 division by zero or INT_MIN / -1, 2 shift count, 3 bounds, 4 null pointer, 5 trap/unreachable, 6 float->int,
#   7 a write to the closure.
#
# Static objects (`@"x"`: constant tables, string literals, globals with a constant initializer) live in a region the server
# allocates and fills at load time (manifest lines `S size hex` and `R offset target`); a kernel writing a mutable one shares it
# across invocations and launches, as a C++ global would. A zero-initialized global is refused: a dynamic initializer looks the same.
#
# Not handled (refused with the reason): double, 64-bit values above 32 bits, function addresses,
# goto other than loop break/continue, recursion, switch arms that fall through, a kernel with parameters.
# A program with no kernel gets an empty module.

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

# EDG's exception-handling state (lib_src/eh.h). A noexcept function (libstdc++'s std::array::operator[], for one) pushes
# a kind-6 entry on __curr_eh_stack_entry and pops it on every exit; nothing on the device unwinds, so the cells are
# ordinary static storage here, not an extern to refuse.
EH_RUNTIME_STATE = %w[__curr_eh_stack_entry __eh_curr_region __catch_clause_number __caught_object_address].freeze

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
# ["int", size, signed, bool], ["float", size], ["ptr"], ["void"]. Aggregates exist only in memory (slots, copy).

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
  return ["ptr"] if x[0] == "ptr" || x[0] == "byval" || x[0] == "sret"
  return parse_type(x[1]) if x[0] == "const" || x[0] == "volatile"
  raise Refused, "type form (#{x[0]} ...)"
end

# true when the type form is a scalar or pointer (a candidate for a WGSL local variable)
def scalar_form?(x)
  parse_type(x)
  true
rescue Refused
  false
end

def int_ty?(t)
  t[0] == "int" && !t[3]
end

def bool_ty?(t)
  t[0] == "int" && t[3]
end

# The WGSL type of a value of IR type t. Pointers and all integers are 32 bits (8-byte integers are narrowed).
def wt(t)
  case t[0]
  when "ptr" then "u32"
  when "int" then t[3] ? "bool" : (t[2] ? "i32" : "u32")
  when "float"
    raise Refused, "double (WebGPU core has no f64)" unless t[1] == 4
    "f32"
  else raise Refused, "value of type #{t[0]}"
  end
end

# the u32 bit pattern of expression e of type t
def bits_of(e, t)
  return "select(0u, 1u, #{e})" if bool_ty?(t)
  return "bitcast<u32>(#{e})" if t[0] == "float" || (t[0] == "int" && t[2])
  e
end

# the value of type t that has the low bits of the u32 expression e (narrow types are sign- or zero-extended)
def from_bits(e, t)
  return "(#{e} != 0u)" if bool_ty?(t)
  return "bitcast<f32>(#{e})" if t[0] == "float"
  return e if t[0] == "ptr"
  sz = t[1]
  if sz >= 4
    t[2] ? "bitcast<i32>(#{e})" : e
  else
    sh = (4 - sz) * 8
    t[2] ? "(bitcast<i32>(#{e} << #{sh}u) >> #{sh}u)" : "(#{e} & #{sz == 1 ? '0xffu' : '0xffffu'})"
  end
end

# an expression of type t after arithmetic that may have left the narrow range
def canon(e, t)
  return e if t[0] != "int" || t[3] || t[1] >= 4
  from_bits(bits_of(e, t), t)
end

def int_lit(t, v)
  return (v != 0 ? "true" : "false") if bool_ty?(t)
  return "0u" if t[0] == "ptr" && v == 0
  bits = [t[1] || 4, 4].min * 8
  v &= (1 << bits) - 1
  if t[0] == "int" && t[2]
    v -= (1 << bits) if v >= (1 << (bits - 1))
    return "bitcast<i32>(0x80000000u)" if v == -2147483648
    return "#{v}i"
  end
  "#{v}u"
end

def float_lit(text)
  return "bitcast<f32>(0x7f800000u)" if text == "+Infinity" || text == "Infinity"
  return "bitcast<f32>(0xff800000u)" if text == "-Infinity"
  ok = text.count("0123456789") > 0
  text.each_char { |c| ok = false unless "0123456789.eE+-".include?(c) }
  raise Refused, "float constant #{text}" unless ok
  "f32(#{text.include?('.') || text.include?('e') || text.include?('E') ? text : text + '.0'})"
end

# ------------------------------------------------------------------ SYCL intrinsics

# name => WGSL expression (u32). Calls take no arguments.
SYCL_VALUES = {
  "__nfcxx_sycl_gid_x" => "gid.x", "__nfcxx_sycl_gid_y" => "gid.y", "__nfcxx_sycl_gid_z" => "gid.z",
  "__nfcxx_sycl_lid_x" => "lid.x", "__nfcxx_sycl_lid_y" => "lid.y", "__nfcxx_sycl_lid_z" => "lid.z",
  "__nfcxx_sycl_group_x" => "wid.x", "__nfcxx_sycl_group_y" => "wid.y", "__nfcxx_sycl_group_z" => "wid.z",
  "__nfcxx_sycl_grange_x" => "args.gsize.x", "__nfcxx_sycl_grange_y" => "args.gsize.y", "__nfcxx_sycl_grange_z" => "args.gsize.z",
  "__nfcxx_sycl_lrange_x" => "WGX", "__nfcxx_sycl_lrange_y" => "WGY", "__nfcxx_sycl_lrange_z" => "WGZ",
  "__nfcxx_sycl_closure" => "0xc0000000u", "__nfcxx_sycl_local_base" => "0x40000000u",
  "__nfcxx_sycl_scratch" => "(0x40000000u + WG_WORDS * 4u)",
}

# op number => WGSL template (X, Y, Z are the operands); the numbers are detail::math_op in sycl.hpp
SYCL_MATH = {
  1 => "sqrt(X)", 2 => "exp(X)", 3 => "log(X)", 4 => "sin(X)", 5 => "cos(X)", 6 => "tan(X)", 7 => "abs(X)",
  8 => "floor(X)", 9 => "ceil(X)", 10 => "trunc(X)", 11 => "(sign(X) * floor(abs(X) + 0.5))", 12 => "inverseSqrt(X)",
  13 => "exp2(X)", 14 => "log2(X)", 15 => "asin(X)", 16 => "acos(X)", 17 => "atan(X)", 18 => "sinh(X)", 19 => "cosh(X)",
  20 => "tanh(X)",
  32 => "pow(X, Y)", 33 => "min(X, Y)", 34 => "max(X, Y)", 35 => "atan2(X, Y)", 36 => "(X - Y * trunc(X / Y))",
  37 => "bitcast<f32>((bitcast<u32>(X) & 0x7fffffffu) | (bitcast<u32>(Y) & 0x80000000u))",
  48 => "fma(X, Y, Z)", 49 => "clamp(X, Y, Z)", 50 => "mix(X, Y, Z)",
}

# C library float functions, lowered to WGSL builtins (so std::sqrt(float), sqrtf and the like work in a kernel). X, Y, Z as above.
LIBM_F32 = {
  "sqrtf" => "sqrt(X)", "expf" => "exp(X)", "logf" => "log(X)", "sinf" => "sin(X)", "cosf" => "cos(X)", "tanf" => "tan(X)",
  "fabsf" => "abs(X)", "floorf" => "floor(X)", "ceilf" => "ceil(X)", "truncf" => "trunc(X)",
  "roundf" => "(sign(X) * floor(abs(X) + 0.5))", "exp2f" => "exp2(X)", "log2f" => "log2(X)", "asinf" => "asin(X)",
  "acosf" => "acos(X)", "atanf" => "atan(X)", "sinhf" => "sinh(X)", "coshf" => "cosh(X)", "tanhf" => "tanh(X)",
  "powf" => "pow(X, Y)", "fmodf" => "(X - Y * trunc(X / Y))", "atan2f" => "atan2(X, Y)", "fminf" => "min(X, Y)",
  "fmaxf" => "max(X, Y)", "fmaf" => "fma(X, Y, Z)", "hypotf" => "sqrt(X * X + Y * Y)", "log10f" => "(log(X) * 0.4342944819)",
  "copysignf" => "bitcast<f32>((bitcast<u32>(X) & 0x7fffffffu) | (bitcast<u32>(Y) & 0x80000000u))",
}
LIBM_F32.keys.each { |k| LIBM_F32["__builtin_" + k] = LIBM_F32[k] }

SYCL_ATOMICS = ["add", "max", "min", "umax", "umin", "and", "or", "xor", "xchg", "load", "fadd", "fmin", "fmax", "cas"]

def subst_math(tpl, xs)
  out = ""
  tpl.each_char do |c|
    if c == "X" then out << xs[0]
    elsif c == "Y" then out << xs[1]
    elsif c == "Z" then out << xs[2]
    else out << c
    end
  end
  out
end

# ------------------------------------------------------------------ functions

def collect_calls(x, acc)
  return acc unless x.is_a?(Array)
  if head_of(x) == "call" && x.length > 2 && x[2].is_a?(IRSym) && x[2].sig == "&"
    acc << x[2].name
  end
  x.each { |y| collect_calls(y, acc) }
  acc
end

# Names of the slots a form takes the address of in a way other than the address of a load or a store.
def scan_slots(x, direct, escaped)
  if x.is_a?(IRSym)
    escaped[x.name] = true if x.sig == "$"
    return
  end
  return unless x.is_a?(Array)
  h = head_of(x)
  if (h == "load" || h == "store" || h == "load.v" || h == "store.v") && x[2].is_a?(IRSym) && x[2].sig == "$"
    (direct[x[2].name] ||= []) << parse_type_safe(x[1])
    scan_slots(x[3], direct, escaped) if h == "store" || h == "store.v"
    return
  end
  x.each { |y| scan_slots(y, direct, escaped) }
end

def parse_type_safe(x)
  parse_type(x)
rescue Refused
  nil
end

class Mod
  attr_accessor :defs, :fns, :need, :globals, :datas, :statics, :static_order, :static_size
  def initialize
    @defs = {}     # IR name => function form
    @fns = {}      # IR name => Fn (the reachable ones)
    @need = {}     # prelude helpers used
    @globals = {}  # IR name => global form
    @datas = {}    # IR name => data form (string literals)
    @statics = {}  # name => byte offset in the static region (the objects a kernel uses)
    @static_order = []
    @static_size = 0
  end

  # The WGSL expression for the address of a static object. The region is allocated by the server at load time
  # (STATIC_BASE is a pipeline constant) and filled from the manifest.
  def static_addr(name)
    unless @statics.key?(name)
      f = @globals[name]
      d = @datas[name]
      raise Refused, "static object @\"#{name}\" has no definition in the device unit" if f.nil? && d.nil?
      size, align = if f
                      raise Refused, "static object @\"#{name}\" is extern" if f.drop(5).any? { |x| head_of(x) == "extern" } && !EH_RUNTIME_STATE.include?(name)
                      [as_int(f[3]), as_int(f[4])]
                    else
                      [static_bytes(d).length, 1]
                    end
      align = 4 if align < 4
      off = (@static_size + align - 1) / align * align
      @statics[name] = off
      @static_order << name
      @static_size = off + size
      # objects this one points to are laid out too
      if f
        init = f.drop(5).find { |x| head_of(x) == "init" }
        init.drop(1).each { |it| static_addr(it[3].name) if head_of(it) == "addr" && it[3].is_a?(IRSym) && it[3].sig == "@" } if init
      end
    end
    "(STATIC_BASE + #{@statics[name]}u)"
  end

  def static_bytes(d)
    str = d[3]
    raise Refused, "data #{d[1]}: form #{form_text(d[3])}" unless head_of(str) == "string"
    str[1].to_s.bytes
  end

  # The initial bytes of the static region and its relocations ([offset, target offset]).
  def static_image
    bytes = Array.new(@static_size, 0)
    relocs = []
    @static_order.each do |name|
      base = @statics[name]
      if @datas.key?(name)
        static_bytes(@datas[name]).each_with_index { |b, i| bytes[base + i] = b }
        next
      end
      f = @globals[name]
      init = f.drop(5).find { |x| head_of(x) == "init" }
      raise Refused, "static object #{name} has no initializer" if init.nil?
      nonzero = false
      init.drop(1).each do |it|
        h = head_of(it)
        off = base + as_int(it[1])
        case h
        when "scalar"
          ty = parse_type(it[2])
          v = it[3]
          if head_of(v) == "null"
            n = 0
          elsif ty[0] == "float"
            raise Refused, "static #{name}: double" unless ty[1] == 4
            n = float_bits(v[2].to_s)
          else
            n = as_int(v[2])
          end
          nonzero = true if n != 0
          size = ty[0] == "ptr" ? 8 : ty[1]
          size.times { |i| bytes[off + i] = (n >> (8 * i)) & 255 }
        when "bytes"
          src = @datas[it[3].name]
          raise Refused, "static #{name}: bytes of #{it[3].name}" if src.nil?
          sb = static_bytes(src)
          as_int(it[2]).times { |i| bytes[off + i] = sb[i] || 0 }
          nonzero = true
        when "zero"
          nil
        when "addr"
          raise Refused, "static #{name}: address of a function" unless it[3].is_a?(IRSym) && it[3].sig == "@"
          relocs << [off, @statics[it[3].name] + as_int(it[4])]
          nonzero = true
        else
          raise Refused, "static #{name}: initializer item #{h}"
        end
      end
      raise Refused, "static object #{name} is zero-initialized (a dynamic initializer would look the same in the IR, so it is not trusted)" unless nonzero
    end
    [bytes, relocs]
  end
end

# the bit pattern of a float32 given as the IR's decimal text (or an infinity)
def float_bits(text)
  return 0x7f800000 if text == "+Infinity" || text == "Infinity"
  return 0xff800000 if text == "-Infinity"
  [text.to_f].pack("f").unpack("V")[0]
end

class Fn
  attr_reader :name, :wname, :form, :ptypes, :ret, :frame, :callees, :call_args
  attr_accessor :base, :param_sp

  def initialize(form, wname, mod)
    @form = form
    @name = form[1].to_s
    @wname = wname
    @mod = mod
    @ptypes = []
    @ret = nil
    @slots = {}          # memory slot name => byte offset in the frame
    @locals = {}         # scalar slot name => [WGSL variable, IR type]
    @frame = 0
    @body = []
    @regs = {}           # "%N" => [WGSL expression, IR type]
    @decls = {}          # WGSL variable => WGSL type
    @lines = []
    @ind = 1
    @callees = []
    @base = 0
    @tmp = 0
    @ctx = []            # the open loops and switches, innermost last: {kind:, pending:}
    @labels = {}         # label name => [frame, :brk or :cont]
    @pending_brk = nil
    @nflag = 0
    @param_sp = nil     # per parameter: :cl (every caller passes a pointer into the closure), :unset (no caller seen yet) or nil
    @rsp = {}            # "%N" => :cl, :unset or nil: registers holding pointers into the closure
    @ssp = {}            # scalar slot name => the same
    @call_args = []      # [callee, [space per argument]] found by the last analyze
    setup
  end

  def setup
    slots = []
    @form.each_with_index do |f, i|
      next if i < 2
      h = head_of(f)
      if h == "ret"
        t = parse_type(f[1])
        @ret = t[0] == "void" ? nil : t
      elsif h == "params"
        f.drop(1).each_with_index do |p, k|
          raise Refused, "variadic function #{@name}" if head_of(p) == "ellipsis"
          ph = head_of(p)
          if ph == "param"
            raise BadIR, "parameter register must be %#{k}" unless p[1] == "%#{k}"
            @ptypes << parse_type(p[3])
          elsif ph == "sret"
            raise BadIR, "parameter register must be %#{k}" unless p[1] == "%#{k}"
            @ptypes << ["ptr"]
          else
            raise Refused, "parameter form #{form_text(p)}"
          end
        end
      elsif h == "static" || h == "weak"
        nil
      elsif h == "slot"
        slots << f
      else
        @body << f
      end
    end
    @ptypes.each_with_index { |t, k| @regs["%#{k}"] = ["p#{k}", t] }
    direct = {}
    escaped = {}
    @body.each { |s| scan_slots(s, direct, escaped) }
    off = 0
    slots.each do |f|
      sname = f[1].to_s
      size = f.length == 5 ? as_int(f[3]) : 4
      align = f.length == 5 ? as_int(f[4]) : 4
      ty = scalar_form?(f[2]) ? parse_type(f[2]) : nil
      uses = direct[sname] || []
      if ty && !escaped[sname] && uses.all? { |u| u == ty } && ty[0] != "void"
        v = "s_#{@locals.length}"
        @locals[sname] = [v, ty]
        @decls[v] = wt(ty)
      else
        align = 4 if align < 4
        off = (off + align - 1) / align * align
        @slots[sname] = off
        off += size
      end
    end
    @frame = (off + 15) / 16 * 16
    @callees = collect_calls(@form, []).select { |c| @mod.defs.key?(c) }.uniq
  end

  def emit(s)
    @lines << ("  " * @ind) + s
  end

  def tmp
    @tmp += 1
    "t#{@tmp}"
  end

  def need(k)
    @mod.need[k] = true
  end

  def trap(code)
    need(:trap)
    emit("trap(#{code}u);")
  end


  # ---- address spaces. A pointer into the closure is read from the uniform buffer, whose values the shader's uniformity
  # analysis knows to be uniform: a loop bound captured by value may then guard a barrier. The spaces are found by a
  # flow-insensitive pass over the body (registers and scalar slots that only ever hold such pointers), and over the call
  # graph (a parameter is one if every caller passes one).

  def merge_sp(old, new)
    return new if old == :unset
    return old if new == :unset
    old == new ? old : nil
  end

  def sp_of_operand(x)
    return @rsp.fetch(x, :unset) if x.is_a?(String) && x.start_with?("%")
    return sp_of_operand(x[2]) if head_of(x) == "sret" || head_of(x) == "byval"
    nil
  end

  def sp_of_rhs(x)
    case head_of(x)
    when "bitcast" then sp_of_operand(x[2])
    when "offset", "index" then sp_of_operand(x[1])
    when "load", "load.v"
      a = x[2]
      if parse_type_safe(x[1]) == ["ptr"] && a.is_a?(IRSym) && a.sig == "$" && @locals.key?(a.name)
        return @ssp.fetch(a.name, :unset)
      end
      nil
    when "call"
      callee = x[2]
      callee.is_a?(IRSym) && callee.name == "__nfcxx_sycl_closure" ? :cl : nil
    else nil
    end
  end

  SP_STRUCT = %w[block if then else loop body step switch]

  def walk_sp(s)
    return unless s.is_a?(Array)
    h = head_of(s)
    if SP_STRUCT.include?(h)
      s.drop(1).each { |t| walk_sp(t) }
      return
    end
    case h
    when "let"
      v = sp_of_rhs(s[3])
      @rsp[s[1]] = merge_sp(@rsp.fetch(s[1], :unset), v) if v != :unset
    when "set"
      v = sp_of_operand(s[2])
      @rsp[s[1]] = merge_sp(@rsp.fetch(s[1], :unset), v) if v != :unset
    when "store", "store.v"
      a = s[2]
      if a.is_a?(IRSym) && a.sig == "$" && @locals.key?(a.name) && @locals[a.name][1] == ["ptr"]
        v = sp_of_operand(s[3])
        @ssp[a.name] = merge_sp(@ssp.fetch(a.name, :unset), v) if v != :unset
      end
    end
    note_calls(s)
  end

  def note_calls(x)
    return unless x.is_a?(Array)
    if head_of(x) == "call" && x[2].is_a?(IRSym) && x[2].sig == "&" && @mod.defs.key?(x[2].name)
      @call_args << [x[2].name, x.drop(3).map { |a| sp_of_operand(a) }]
    end
    x.each { |y| note_calls(y) if y.is_a?(Array) }
  end

  def analyze
    # parameter registers
    @ptypes.each_index { |k| @rsp["%#{k}"] = (@param_sp && @param_sp[k]) || nil if @ptypes[k] == ["ptr"] }
    @ptypes.each_index do |k|
      next unless @ptypes[k] == ["ptr"]
      v = @param_sp ? @param_sp[k] : nil
      @rsp["%#{k}"] = v == :unset ? :cl : v   # optimistic until a caller says otherwise
    end
    3.times do
      @call_args = []
      @body.each { |s| walk_sp(s) }
    end
  end

  def closure_ptr?(x)
    @rsp[x] == :cl && x.is_a?(String)
  end

  # ---- operands

  def operand(x)
    if x.is_a?(String) && x.start_with?("%")
      r = @regs[x]
      raise BadIR, "register #{x} is used before it is set" if r.nil?
      return r
    end
    h = head_of(x)
    if h == "const"
      ty = parse_type(x[1])
      return [float_lit(x[2].to_s), ty] if ty[0] == "float"
      return [int_lit(ty, as_int(x[2])), ty]
    end
    return ["0u", ["ptr"]] if h == "null"
    return operand(x[2]) if h == "sret" || h == "byval"
    if x.is_a?(IRSym) && x.sig == "$"
      off = @slots[x.name]
      raise Refused, "address of the scalar slot #{x.name}" if off.nil? && @locals.key?(x.name)
      raise BadIR, "slot #{x.name} is not declared" if off.nil?
      return ["#{0x80000000 + @base + off}u", ["ptr"]]
    end
    return [@mod.static_addr(x.name), ["ptr"]] if x.is_a?(IRSym) && x.sig == "@"
    raise Refused, "address of function #{x.name}" if x.is_a?(IRSym) && x.sig == "&"
    raise Refused, "operand #{form_text(x)}"
  end

  def reg_name(n)
    "r#{n[1..-1]}"
  end

  def set_reg(name, ty)
    r = @regs[name]
    return r[0] if r
    v = reg_name(name)
    @regs[name] = [v, ty]
    @decls[v] = wt(ty)
    v
  end

  # ---- memory

  def load_expr(a, ty, cl = false)
    pre = cl ? "cl" : "ld"
    need(cl ? :cl32 : :ld32)
    if ty[0] == "float"
      return "bitcast<f32>(#{pre}32(#{a}))"
    end
    if bool_ty?(ty)
      need(cl ? :cl8 : :ld8)
      return "(#{pre}8(#{a}) != 0u)"
    end
    if ty[0] == "int" && ty[1] == 1
      need(cl ? :cl8 : :ld8)
      return from_bits("#{pre}8(#{a})", ty)
    end
    if ty[0] == "int" && ty[1] == 2
      need(cl ? :cl16 : :ld16)
      return from_bits("#{pre}16(#{a})", ty)
    end
    from_bits("#{pre}32(#{a})", ty)
  end

  def store_stmt(a, ty, v)
    if ty[0] == "float"
      need(:st32)
      emit("st32(#{a}, bitcast<u32>(#{v}));")
    elsif bool_ty?(ty)
      need(:st8)
      emit("st8(#{a}, select(0u, 1u, #{v}));")
    elsif ty[0] == "int" && ty[1] == 1
      need(:st8)
      emit("st8(#{a}, #{bits_of(v, ty)});")
    elsif ty[0] == "int" && ty[1] == 2
      need(:st16)
      emit("st16(#{a}, #{bits_of(v, ty)});")
    else
      need(:st32)
      emit("st32(#{a}, #{bits_of(v, ty)});")
      if ty[0] == "ptr" || (ty[0] == "int" && ty[1] == 8)
        hi = ty[0] == "int" && ty[2] ? "select(0u, 0xffffffffu, #{v} < 0i)" : "0u"
        emit("st32(#{a} + 4u, #{hi});")
      end
    end
  end

  # ---- expressions: the WGSL expression for x (type dty)

  def rval(x, dty)
    h = head_of(x)
    case h
    when "load", "load.v"   # a volatile access is an ordinary one here: the memory accesses are relaxed atomics already
      ty = parse_type(x[1])
      if x[2].is_a?(IRSym) && x[2].sig == "$" && @locals.key?(x[2].name)
        return @locals[x[2].name][0]
      end
      a, _ = operand(x[2])
      load_expr(a, ty, closure_ptr?(x[2]))
    when "bitcast"
      v, vty = operand(x[2])
      raise Refused, "bitcast of a #{vty[0]}" unless vty[0] == "ptr"
      v
    when "offset"
      b, _ = operand(x[1])
      "(#{b} + #{as_int(x[2])}u)"
    when "index"
      b, _ = operand(x[1])
      i, ity = operand(x[2])
      sz = x[3].is_a?(String) && x[3].start_with?("%") ? bits_of(*operand(x[3])) : "#{as_int(x[3])}u"
      "(#{b} + #{bits_of(i, ity)} * #{sz})"
    when "pdiff"
      a, _ = operand(x[1])
      b, _ = operand(x[2])
      "(bitcast<i32>(#{a} - #{b}) / #{as_int(x[3])}i)"
    when "wadd", "wsub", "wmul"
      ty = parse_type(x[1])
      a, _ = operand(x[2])
      b, _ = operand(x[3])
      op = { "wadd" => "+", "wsub" => "-", "wmul" => "*" }[h]
      canon("(#{a} #{op} #{b})", ty)
    when "wneg"
      ty = parse_type(x[1])
      a, _ = operand(x[2])
      canon(ty[2] ? "(-#{a})" : "(0u - #{a})", ty)
    when "cdiv", "crem"
      ty = parse_type(x[1])
      checked_div(h, ty, x[2], x[3])
    when "cshl", "cshr"
      ty = parse_type(x[1])
      checked_shift(h, ty, x[2], x[3])
    when "and", "or", "xor"
      ty = parse_type(x[1])
      a, _ = operand(x[2])
      b, _ = operand(x[3])
      if bool_ty?(ty)
        return "(#{a} != #{b})" if h == "xor"
        return "(#{a} #{h == 'and' ? '&' : '|'} #{b})"
      end
      op = { "and" => "&", "or" => "|", "xor" => "^" }[h]
      "(#{a} #{op} #{b})"
    when "not"
      ty = parse_type(x[1])
      a, _ = operand(x[2])
      bool_ty?(ty) ? "(!#{a})" : canon("(~#{a})", ty)
    when "fadd", "fsub", "fmul", "fdiv"
      ty = parse_type(x[1])
      raise Refused, "#{h} on #{ty[0]}" unless ty[0] == "float"
      wt(ty)
      a, _ = operand(x[2])
      b, _ = operand(x[3])
      "(#{a} #{{ 'fadd' => '+', 'fsub' => '-', 'fmul' => '*', 'fdiv' => '/' }[h]} #{b})"
    when "fneg"
      ty = parse_type(x[1])
      wt(ty)
      a, _ = operand(x[2])
      "(-#{a})"
    when "iconv"
      ty = parse_type(x[1])
      a, aty = operand(x[2])
      int_convert(ty, a, aty)
    when "p2i"
      ty = parse_type(x[1])
      a, _ = operand(x[2])
      from_bits(a, ty)
    when "i2p"
      a, aty = operand(x[2])
      bits_of(a, aty)
    when "fconv"
      ty = parse_type(x[1])
      a, aty = operand(x[2])
      wt(ty)
      wt(aty)
      a
    when "i2f", "u2f"
      ty = parse_type(x[1])
      wt(ty)
      a, aty = operand(x[2])
      raise Refused, "#{h} of bool" if bool_ty?(aty)
      "f32(#{a})"
    when "cf2i"
      ty = parse_type(x[1])
      a, aty = operand(x[2])
      float_to_int(ty, a, aty)
    when "lt", "le", "gt", "ge", "eq", "ne", "lt.s", "le.s", "gt.s", "ge.s", "eq.s", "ne.s",
         "lt.u", "le.u", "gt.u", "ge.u", "eq.u", "ne.u", "lt.f", "le.f", "gt.f", "ge.f", "eq.f", "ne.f"
      op = h.split(".")[0]
      a, _ = operand(x[2])
      b, _ = operand(x[3])
      "(#{a} #{{ 'lt' => '<', 'le' => '<=', 'gt' => '>', 'ge' => '>=', 'eq' => '==', 'ne' => '!=' }[op]} #{b})"
    when "call"
      e = call_expr(x)
      raise Refused, "value of a call of void function" if e.nil?
      e
    when "const"
      ty = parse_type(x[1])
      return float_lit(x[2].to_s) if ty[0] == "float"
      int_lit(ty, as_int(x[2]))
    else
      raise Refused, "expression #{h || form_text(x)}"
    end
  end

  def checked_div(h, ty, xa, xb)
    raise Refused, "#{h} on #{ty[0]}" unless int_ty?(ty)
    a, _ = operand(xa)
    b, _ = operand(xb)
    if ty[2]
      min = ty[1] >= 4 ? "bitcast<i32>(0x80000000u)" : "#{-(1 << (ty[1] * 8 - 1))}i"
      emit("if (#{b} == 0i || (#{b} == -1i && #{a} == #{min})) {")
    else
      emit("if (#{b} == 0u) {")
    end
    @ind += 1
    trap(1)
    @ind -= 1
    emit("}")
    # WGSL defines x / 0 = x and x % 0 = 0 (and INT_MIN / -1), so the division itself cannot fault after the flag is set
    canon("(#{a} #{h == 'cdiv' ? '/' : '%'} #{b})", ty)
  end

  def checked_shift(h, ty, xa, xb)
    raise Refused, "#{h} on #{ty[0]}" unless int_ty?(ty)
    a, _ = operand(xa)
    c, cty = operand(xb)
    raise Refused, "shift count of type #{cty[0]}" unless int_ty?(cty)
    width = [ty[1] * 8, 32].min
    cb = bits_of(c, cty)
    emit("if (#{cb} >= #{width}u) {")
    @ind += 1
    trap(2)
    @ind -= 1
    emit("}")
    canon("(#{a} #{h == 'cshl' ? '<<' : '>>'} #{cb})", ty)
  end

  # iconv: integer to integer, with sign- or zero-extension from the source and truncation to the target
  def int_convert(ty, a, aty)
    if bool_ty?(ty)
      return "(#{a} != #{bool_ty?(aty) ? 'false' : (aty[0] == 'int' && aty[2] ? '0i' : '0u')})"
    end
    raise Refused, "iconv to #{ty[0]}" unless ty[0] == "int"
    raise Refused, "iconv of a #{aty[0]}" unless aty[0] == "int" || aty[0] == "ptr"
    from_bits(bits_of(a, aty), ty)
  end

  # cf2i: C truncation; sets the trap flag (code 6) on NaN and on values that do not fit the target
  def float_to_int(ty, a, aty)
    raise Refused, "cf2i to #{ty[0]}" unless int_ty?(ty)
    wt(aty)
    bits = [ty[1] * 8, 32].min
    if ty[2]
      lo = -(1 << (bits - 1))
      hi = 1 << (bits - 1)
      exact_below = bits <= 24
      lo_op, lo_v = exact_below ? [">", (lo - 1).to_f] : [">=", lo.to_f]
    else
      lo_op, lo_v = ">", -1.0
      hi = 1 << bits
    end
    emit("if (!(#{a} #{lo_op} f32(#{lo_v}) && #{a} < f32(#{hi.to_f}))) {")
    @ind += 1
    trap(6)
    @ind -= 1
    emit("}")
    if ty[2]
      from_bits("bitcast<u32>(i32(clamp(#{a}, f32(#{lo.to_f}), f32(#{(hi - 1).to_f}))))", ty)
    else
      from_bits("u32(clamp(#{a}, 0.0, f32(#{(hi - 1).to_f})))", ty)
    end
  end

  # ---- calls

  # The expression of a call, or nil for a statement-only intrinsic (emitted here).
  def call_expr(x)
    ty = parse_type(x[1])
    callee = x[2]
    raise Refused, "indirect call" unless callee.is_a?(IRSym) && callee.sig == "&"
    name = callee.name
    args = x.drop(3)
    if SYCL_VALUES.key?(name)
      return SYCL_VALUES[name]
    elsif name == "__nfcxx_sycl_barrier"
      emit("workgroupBarrier();")
      return nil
    elsif name == "__nfcxx_sycl_fn1" || name == "__nfcxx_sycl_fn2" || name == "__nfcxx_sycl_fn3"
      op = args[0]
      raise Refused, "#{name} with a non-constant operation" unless head_of(op) == "const"
      tpl = SYCL_MATH[as_int(op[2])]
      raise Refused, "#{name} operation #{as_int(op[2])}" if tpl.nil?
      xs = args.drop(1).map { |a| operand(a)[0] }
      return subst_math(tpl, xs)
    elsif name.start_with?("__nfcxx_sycl_atomic_")
      kind = name[20..-1]
      raise Refused, "intrinsic #{name}" unless SYCL_ATOMICS.include?(kind)
      need(:"atomic_#{kind}")
      xs = args.map { |a| operand(a)[0] }
      return "at_#{kind}(#{xs.join(', ')})"
    elsif name.start_with?("__nfcxx_")
      raise Refused, "unknown device intrinsic #{name}"
    end
    if LIBM_F32.key?(name)
      xs = args.map { |a| operand(a)[0] }
      return subst_math(LIBM_F32[name], xs)
    end
    if (name == "abs" || name == "labs" || name == "llabs") && args.length == 1
      return "abs(#{operand(args[0])[0]})"
    end
    # memcpy, memmove and memset of a constant size are block copies and stores in the device unit
    if %w[memcpy memmove __builtin_memcpy __builtin_memmove].include?(name) && args.length == 3 && head_of(args[2]) == "const"
      n = as_int(args[2][2])
      d = operand(args[0])[0]
      sv = operand(args[1])[0]
      if n % 4 == 0
        need(:cpy_w)
        emit("cpy_w(#{d}, #{sv}, #{n / 4}u);")
      else
        need(:cpy_b)
        emit("cpy_b(#{d}, #{sv}, #{n}u);")
      end
      return d
    end
    if %w[memset __builtin_memset].include?(name) && args.length == 3 && head_of(args[1]) == "const" && head_of(args[2]) == "const"
      n = as_int(args[2][2])
      d = operand(args[0])[0]
      byte = as_int(args[1][2]) & 255
      need(:st8)
      emit("for (var mi = 0u; mi < #{n}u; mi = mi + 1u) { st8(#{d} + mi, #{byte}u); }")
      return d
    end
    callee_fn = @mod.fns[name]
    raise Refused, "call of #{name}, which has no body in the device unit (a host function, or a declaration)" if callee_fn.nil?
    raise Refused, "call of #{name} with #{args.length} arguments, it takes #{callee_fn.ptypes.length}" if args.length != callee_fn.ptypes.length
    xs = args.map { |a| operand(a)[0] }
    "#{callee_fn.wname}(#{xs.join(', ')})"
  end

  # ---- statements

  def stmts(list)
    list.each_with_index do |s, i|
      nxt = list[i + 1]
      # a loop or a switch followed by a label: the label is its break target (the IR's goto "label" leaves it)
      @pending_brk = ((head_of(s) == "loop" || head_of(s) == "switch") && head_of(nxt) == "label") ? nxt[1].to_s : nil
      stmt(s)
    end
  end

  # the label that ends a loop body (the last statement of the body, or of a block that ends it): the loop's continue
  def tail_label(list)
    last = list.last
    case head_of(last)
    when "label" then last[1].to_s
    when "block" then tail_label(last.drop(1))
    else nil
    end
  end

  def open_frame(kind, brk, cont)
    f = { kind: kind, pending: {}, flag: nil }
    @labels[brk] = [f, :brk] if brk
    @labels[cont] = [f, :cont] if cont
    @ctx.push(f)
    f
  end

  # After the closing brace of construct f: a goto that left it from inside a nested construct set a flag; carry the jump on.
  def close_frame(f)
    @ctx.pop
    f[:pending].each_key do |target|
      flag = target[:flag]
      emit("if (#{flag} != 0u) {")
      @ind += 1
      parent = @ctx[-1]
      if parent.equal?(target)
        if target[:kind] == :loop
          emit("if (#{flag} == 1u) {")
          emit("  #{flag} = 0u;")
          emit("  break;")
          emit("}")
          emit("#{flag} = 0u;")
          emit("continue;")
        else
          emit("#{flag} = 0u;")
          emit("break;")
        end
      else
        raise Refused, "goto leaves its construct" if parent.nil?
        emit("break;")
        parent[:pending][target] = true
      end
      @ind -= 1
      emit("}")
    end
  end

  def goto_stmt(name)
    ent = @labels[name]
    raise Refused, "goto \"#{name}\" (not the end of a loop body or the label after a loop or switch)" if ent.nil?
    frame, kind = ent
    idx = @ctx.index { |c| c.equal?(frame) }
    raise Refused, "goto \"#{name}\" from outside its construct" if idx.nil?
    between = @ctx[(idx + 1)..-1]
    if between.empty?
      emit(kind == :brk ? "break;" : "continue;")
    elsif kind == :cont && between.all? { |c| c[:kind] == :switch }
      emit("continue;")
    else
      if frame[:flag].nil?
        @nflag += 1
        frame[:flag] = "g#{@nflag}"
        @decls[frame[:flag]] = "u32"
      end
      emit("#{frame[:flag]} = #{kind == :brk ? 1 : 2}u;")
      emit("break;")
      @ctx[-1][:pending][frame] = true
    end
  end

  def stmt(s)
    h = head_of(s)
    case h
    when "block"
      stmts(s.drop(1))
    when "let"
      ty = parse_type(s[2])
      e = rval(s[3], ty)
      v = set_reg(s[1], ty)
      emit("#{v} = #{e};")
    when "set"
      r = @regs[s[1]]
      raise BadIR, "set of #{s[1]} before its let" if r.nil?
      v, _ = operand(s[2])
      emit("#{r[0]} = #{v};")
    when "store", "store.v"
      ty = parse_type(s[1])
      v, _ = operand(s[3])
      if s[2].is_a?(IRSym) && s[2].sig == "$" && @locals.key?(s[2].name)
        emit("#{@locals[s[2].name][0]} = #{v};")
      else
        a, _ = operand(s[2])
        store_stmt(a, ty, v)
      end
    when "if"
      c, cty = operand(s[1])
      raise BadIR, "if condition is not a bool" unless bool_ty?(cty)
      then_f = s.drop(2).find { |f| head_of(f) == "then" }
      else_f = s.drop(2).find { |f| head_of(f) == "else" }
      raise BadIR, "if without then" if then_f.nil?
      emit("if (#{c}) {")
      @ind += 1
      stmts(then_f.drop(1))
      @ind -= 1
      if else_f && else_f.length > 1
        emit("} else {")
        @ind += 1
        stmts(else_f.drop(1))
        @ind -= 1
      end
      emit("}")
    when "loop"
      body_f = s.drop(1).find { |f| head_of(f) == "body" }
      step_f = s.drop(1).find { |f| head_of(f) == "step" }
      raise BadIR, "loop without body and step" if body_f.nil? || step_f.nil?
      brk = @pending_brk
      @pending_brk = nil
      frame = open_frame(:loop, brk, tail_label(body_f.drop(1)))
      emit("loop {")
      @ind += 1
      stmts(body_f.drop(1))
      if step_f.length > 1
        emit("continuing {")
        @ind += 1
        stmts(step_f.drop(1))
        @ind -= 1
        emit("}")
      end
      @ind -= 1
      emit("}")
      close_frame(frame)
    when "switch"
      switch_stmt(s)
    when "break"
      emit("break;")
    when "continue"
      emit("continue;")
    when "goto"
      goto_stmt(s[1].to_s)
    when "label"
      raise Refused, "label \"#{s[1]}\" (not the end of a loop body or the label after a loop or switch)" unless @labels.key?(s[1].to_s)
    when "trap", "unreachable"
      trap(5)
    when "bounds"
      v, vty = operand(s[1])
      n = s[2].is_a?(String) && s[2].start_with?("%") ? operand(s[2])[0] : "#{as_int(s[2])}u"
      emit("if (#{bits_of(v, vty)} >= #{n}) {")
      @ind += 1
      trap(3)
      @ind -= 1
      emit("}")
    when "nonnull"
      # the address of a function is never null (the front end's check on a function pointer that is a template argument)
      unless s[1].is_a?(IRSym) && s[1].sig == "&"
        p, _ = operand(s[1])
        emit("if (#{p} == 0u) {")
        @ind += 1
        trap(4)
        @ind -= 1
        emit("}")
      end
    when "return"
      if @ret.nil?
        emit("return;")
      else
        v, _ = operand(s[1])
        emit("return #{v};")
      end
    when "eval"
      raise Refused, "eval of #{form_text(s[1])}" unless s.length == 2
      if head_of(s[1]) == "call"
        e = call_expr(s[1])
        emit("_ = #{e};") if e && s[1][1] != "void"
        emit("#{e};") if e && s[1][1] == "void"
      else
        raise Refused, "eval of #{form_text(s[1])}"
      end
    when "copy"
      n = as_int(s[1])
      d, _ = operand(s[2])
      src, _ = operand(s[3])
      if n % 4 == 0
        need(:cpy_w)
        emit("cpy_w(#{d}, #{src}, #{n / 4}u);")
      else
        need(:cpy_b)
        emit("cpy_b(#{d}, #{src}, #{n}u);")
      end
    else
      raise Refused, "statement #{h || form_text(s)}"
    end
  end

  def jump?(s)
    h = head_of(s)
    return true if h == "break" || h == "continue" || h == "return" || h == "unreachable" || h == "trap" || h == "goto"
    if h == "block"
      return s.length > 1 && jump?(s[-1])
    end
    if h == "if"
      t = s.drop(2).find { |f| head_of(f) == "then" }
      e = s.drop(2).find { |f| head_of(f) == "else" }
      return t && e && t.length > 1 && e.length > 1 && jump?(t[-1]) && jump?(e[-1])
    end
    false
  end

  def switch_stmt(s)
    brk = @pending_brk
    @pending_brk = nil
    body_f = s.drop(1).find { |f| head_of(f) == "body" }
    raise BadIR, "switch without body" if body_f.nil?
    v, vty = operand(s[1])
    raise Refused, "switch on a #{vty[0]}" unless int_ty?(vty)
    items = []
    expand = lambda { |f| head_of(f) == "block" ? f.drop(1).each { |t| expand.call(t) } : items << f }
    body_f.drop(1).each { |f| expand.call(f) }
    arms = []   # [[labels], [stmts]]; consecutive case markers share an arm
    cur = nil
    items.each do |it|
      h = head_of(it)
      if h == "case" || h == "default"
        if cur.nil? || !cur[1].empty?
          cur = [[], []]
          arms << cur
        end
        cur[0] << (h == "case" ? int_lit(vty, as_int(it[1][2])) : "default")
      else
        raise Refused, "statement before the first case of a switch" if cur.nil?
        cur[1] << it
      end
    end
    arms.each_with_index do |arm, i|
      next if i == arms.length - 1 || arm[1].empty?
      raise Refused, "switch arm falls through into the next one" unless jump?(arm[1][-1])
    end
    frame = open_frame(:switch, brk, nil)
    emit("switch (#{v}) {")
    @ind += 1
    has_default = arms.any? { |a| a[0].include?("default") }
    arms.each do |arm|
      labels = arm[0].reject { |l| l == "default" }
      sel = labels.dup
      sel << "default" if arm[0].include?("default")
      emit("case #{sel.join(', ')} {") unless sel == ["default"]
      emit("default {") if sel == ["default"]
      @ind += 1
      stmts(arm[1])
      @ind -= 1
      emit("}")
    end
    unless has_default
      emit("default {")
      emit("}")
    end
    @ind -= 1
    emit("}")
    close_frame(frame)
  end

  # ---- the function text

  def compile
    stmts(@body)
  end

  def text
    ps = []
    @ptypes.each_with_index { |t, k| ps << "p#{k}: #{wt(t)}" }
    out = []
    out << "// #{@name}"
    out << "fn #{@wname}(#{ps.join(', ')})#{@ret ? ' -> ' + wt(@ret) : ''} {"
    @decls.each { |v, t| out << "  var #{v}: #{t};" }
    out.concat(@lines)
    out << "  return #{@ret[0] == 'float' ? '0.0' : (@ret[0] == 'int' && @ret[3] ? 'false' : (@ret[0] == 'int' && @ret[2] ? '0i' : '0u'))};" if @ret && !(@lines.last && @lines.last.strip.start_with?("return") && @lines.last.start_with?("  return"))
    out << "}"
    out.join("\n") + "\n"
  end
end

# ------------------------------------------------------------------ the module

PRELUDE_BASE = <<'WGSL'
override WGX: u32 = 1u;
override WGY: u32 = 1u;
override WGZ: u32 = 1u;
override WG_WORDS: u32 = 1u;
override HEAP_BASE: u32 = 0x10000000u;
override STATIC_BASE: u32 = 0u;
struct Args { gsize: vec4<u32>, goff: vec4<u32> };
@group(0) @binding(0) var<storage, read_write> heap: array<atomic<u32>>;
@group(0) @binding(1) var<uniform> args: Args;
@group(0) @binding(2) var<uniform> cl: array<vec4<u32>, 256>;
var<workgroup> wg: array<atomic<u32>, WG_WORDS + 256u>;   // WG_WORDS of local_accessor storage, then 256 words of scratch for the group algorithms
var<private> stk: array<u32, STK_WORDS>;
var<private> gid: vec3<u32>;
var<private> lid: vec3<u32>;
var<private> wid: vec3<u32>;

fn trap(c: u32) { atomicMax(&heap[1], c); }
fn hix(p: u32) -> u32 { return (p - HEAP_BASE) >> 2u; }
fn lix(p: u32) -> u32 { return (p & 0x3fffffffu) >> 2u; }
fn ld32(p: u32) -> u32 {
  let s = p >> 30u;
  if (s == 3u) { let w = lix(p); return cl[w >> 2u][w & 3u]; }
  if (s == 2u) { return stk[lix(p)]; }
  if (s == 1u) { return atomicLoad(&wg[lix(p)]); }
  return atomicLoad(&heap[hix(p)]);
}
fn st32(p: u32, v: u32) {
  let s = p >> 30u;
  if (s == 3u) { trap(7u); return; }
  if (s == 2u) { stk[lix(p)] = v; return; }
  if (s == 1u) { atomicStore(&wg[lix(p)], v); return; }
  atomicStore(&heap[hix(p)], v);
}
WGSL

PRELUDE_SUB = <<'WGSL'
fn ld8(p: u32) -> u32 { return (ld32(p & 0xfffffffcu) >> ((p & 3u) * 8u)) & 0xffu; }
fn ld16(p: u32) -> u32 { return (ld32(p & 0xfffffffcu) >> ((p & 2u) * 8u)) & 0xffffu; }
fn stsub(p: u32, v: u32, mask: u32, sh: u32) {
  let s = p >> 30u;
  let m = ~(mask << sh);
  let x = (v & mask) << sh;
  if (s == 3u) { trap(7u); return; }
  if (s == 2u) { let i = lix(p); stk[i] = (stk[i] & m) | x; return; }
  if (s == 1u) { atomicAnd(&wg[lix(p)], m); atomicOr(&wg[lix(p)], x); return; }
  atomicAnd(&heap[hix(p)], m);
  atomicOr(&heap[hix(p)], x);
}
fn st8(p: u32, v: u32) { stsub(p, v, 0xffu, (p & 3u) * 8u); }
fn st16(p: u32, v: u32) { stsub(p, v, 0xffffu, (p & 2u) * 8u); }
WGSL

PRELUDE_CL = <<'WGSL'
fn cl32(p: u32) -> u32 { let w = lix(p); return cl[w >> 2u][w & 3u]; }
WGSL

PRELUDE_CL_SUB = <<'WGSL'
fn cl8(p: u32) -> u32 { return (cl32(p & 0xfffffffcu) >> ((p & 3u) * 8u)) & 0xffu; }
fn cl16(p: u32) -> u32 { return (cl32(p & 0xfffffffcu) >> ((p & 2u) * 8u)) & 0xffffu; }
WGSL

PRELUDE_CPY_W = <<'WGSL'
fn cpy_w(d: u32, s: u32, n: u32) { for (var i = 0u; i < n; i = i + 1u) { st32(d + i * 4u, ld32(s + i * 4u)); } }
WGSL

PRELUDE_CPY_B = <<'WGSL'
fn cpy_b(d: u32, s: u32, n: u32) { for (var i = 0u; i < n; i = i + 1u) { st8(d + i, ld8(s + i)); } }
WGSL

# the body of an atomic helper: `old` is the u32 before, `v` the operand, the memory is `m` (heap or wg)
ATOMIC_OPS = {
  "add" => "atomicAdd(&M[i], bitcast<u32>(v))",
  "and" => "atomicAnd(&M[i], bitcast<u32>(v))",
  "or" => "atomicOr(&M[i], bitcast<u32>(v))",
  "xor" => "atomicXor(&M[i], bitcast<u32>(v))",
  "xchg" => "atomicExchange(&M[i], bitcast<u32>(v))",
  "load" => "atomicLoad(&M[i])",
}

FLOAT_ATOMIC_OPS = { "fadd" => "(bitcast<f32>(old) + v)", "fmin" => "min(bitcast<f32>(old), v)", "fmax" => "max(bitcast<f32>(old), v)" }

# a compare-and-swap loop over the bits of an f32 (WGSL has no float atomics)
def float_atomic_helper(kind)
  out = "fn at_#{kind}(p: u32, v: f32) -> f32 {\n  let i = lix(p);\n  let h = hix(p);\n  let s = p >> 30u;\n  var old: u32;\n"
  ["wg", "heap"].each_with_index do |m, k|
    ix = k == 0 ? "i" : "h"
    out << (k == 0 ? "  if (s == 1u) {\n" : "  {\n")
    out << "    old = atomicLoad(&#{m}[#{ix}]);\n    loop {\n"
    out << "      let nv = bitcast<u32>(#{FLOAT_ATOMIC_OPS[kind]});\n"
    out << "      let r = atomicCompareExchangeWeak(&#{m}[#{ix}], old, nv);\n      if (r.exchanged) { break; }\n      old = r.old_value;\n    }\n"
    out << "    return bitcast<f32>(old);\n  }\n"
  end
  out << "}\n"
  out
end

# compare and swap: returns the old value, whether or not it swapped (the strong form: spurious failures retry)
def cas_helper
  out = "fn at_cas(p: u32, e: i32, d: i32) -> i32 {\n  let i = lix(p);\n  let h = hix(p);\n  let s = p >> 30u;\n"
  ["wg", "heap"].each_with_index do |m, k|
    ix = k == 0 ? "i" : "h"
    out << (k == 0 ? "  if (s == 1u) {\n" : "  {\n")
    out << "    loop {\n      let r = atomicCompareExchangeWeak(&#{m}[#{ix}], bitcast<u32>(e), bitcast<u32>(d));\n"
    out << "      if (r.exchanged || r.old_value != bitcast<u32>(e)) { return bitcast<i32>(r.old_value); }\n    }\n  }\n"
  end
  out << "  return 0i;\n}\n"
  out
end

def atomic_helper(kind)
  return cas_helper if kind == "cas"
  return float_atomic_helper(kind) if FLOAT_ATOMIC_OPS.key?(kind)
  sig = kind == "load" ? "fn at_#{kind}(p: u32) -> i32" : "fn at_#{kind}(p: u32, v: i32) -> i32"
  out = "#{sig} {\n  let i = lix(p);\n  let h = hix(p);\n  let s = p >> 30u;\n"
  if ATOMIC_OPS.key?(kind)
    ["wg", "heap"].each_with_index do |m, k|
      out << "  if (s == 1u) { return bitcast<i32>(#{ATOMIC_OPS[kind].sub('M', m).sub('[i]', '[i]')}); }\n" if k == 0
      out << "  return bitcast<i32>(#{ATOMIC_OPS[kind].sub('M', m).sub('[i]', '[h]')});\n" if k == 1
    end
  else
    signed = kind == "max" || kind == "min"
    cmp = kind.end_with?("max") ? ">" : "<"
    out << "  var old: u32;\n"
    ["wg", "heap"].each_with_index do |m, k|
      out << "  if (s == 1u) {\n" if k == 0
      out << "  {\n" if k == 1
      ix = k == 0 ? "i" : "h"
      out << "    old = atomicLoad(&#{m}[#{ix}]);\n    loop {\n"
      if signed
        out << "      let nv = select(bitcast<u32>(v), old, bitcast<i32>(old) #{cmp} v);\n"
      else
        out << "      let nv = select(bitcast<u32>(v), old, old #{cmp} bitcast<u32>(v));\n"
      end
      out << "      let r = atomicCompareExchangeWeak(&#{m}[#{ix}], old, nv);\n      if (r.exchanged) { break; }\n      old = r.old_value;\n    }\n"
      out << "    return bitcast<i32>(old);\n  }\n"
    end
  end
  out << "}\n"
  out
end

def emit_module(src, narrow)
  forms = parse_forms(tokenize(strip_comments(src)))
  mod = Mod.new
  sizes = {}
  forms.each do |f|
    h = head_of(f)
    if h == "function"
      mod.defs[f[1].to_s] = f
    elsif h == "abi-type"
      sizes[f[1].to_s] = as_int(f[2])
    elsif h == "global"
      mod.globals[f[1].to_s] = f
    elsif h == "data"
      mod.datas[f[1].to_s] = f
    end   # globals, data, aliases and the rest are looked at only when a kernel uses them (an operand @"x" is refused)
  end
  entries = mod.defs.keys.select { |n| n.include?("__nfcxx_sycl_entry_") }
  # a program that launches no kernel gets an empty module (the host side never asks the server for anything)
  return ["// no SYCL kernel in this program\n", []] if entries.empty?
  # reachable functions, callers first
  order = []
  state = {}
  visit = lambda do |name|
    next if state[name] == :done
    raise Refused, "recursive call of #{name}" if state[name] == :open
    state[name] = :open
    callees = collect_calls(mod.defs[name], []).select { |c| mod.defs.key?(c) }.uniq
    callees.each { |c| visit.call(c) }
    state[name] = :done
    order << name
  end
  entries.each { |e| visit.call(e) }
  order = order.reverse   # callers first
  # create the Fns: callees must be known by name when a call is lowered, so register all names first
  order.each_with_index { |n, i| mod.fns[n] = :pending }
  order.each_with_index do |n, i|
    mod.fns[n] = nil
  end
  # Fn.new reads mod.defs only for the callee names; the callee Fn objects are looked up at compile time
  wnames = {}
  order.each_with_index { |n, i| wnames[n] = "F#{i}" }
  order.each { |n| mod.fns[n] = Fn.new(mod.defs[n], wnames[n], mod) }
  # which pointer parameters always receive a pointer into the closure (callers first, repeated until nothing changes)
  order.each { |n| f = mod.fns[n]; f.param_sp = Array.new(f.ptypes.length, :unset) }
  loop do
    changed = false
    order.each do |n|
      f = mod.fns[n]
      f.analyze
      f.call_args.each do |callee, sps|
        cf = mod.fns[callee]
        sps.each_with_index do |sp, k|
          next if k >= cf.param_sp.length || cf.ptypes[k] != ["ptr"]
          nv = cf.merge_sp(cf.param_sp[k], sp.nil? ? nil : sp)
          if nv != cf.param_sp[k]
            cf.param_sp[k] = nv
            changed = true
          end
        end
      end
    end
    break unless changed
  end
  # frames: a callee's frame starts after its callers' frames
  order.each do |n|
    f = mod.fns[n]
    f.callees.each do |c|
      cf = mod.fns[c]
      cf.base = f.base + f.frame if f.base + f.frame > cf.base
    end
  end
  stk_bytes = 0
  order.each { |n| f = mod.fns[n]; stk_bytes = f.base + f.frame if f.base + f.frame > stk_bytes }
  order.each { |n| mod.fns[n].compile }

  manifest = []
  eps = []
  entries.each_with_index do |e, k|
    f = mod.fns[e]
    raise Refused, "kernel #{e} takes parameters" unless f.ptypes.empty?
    key, struct = kernel_key(mod.defs[e])
    raise Refused, "kernel #{e}: cannot find the closure type (no cast of __nfcxx_sycl_closure())" if key.nil?
    manifest << "k#{k}\t#{key}\t#{sizes[struct] || 0}"
    eps << "@compute @workgroup_size(WGX, WGY, WGZ)\nfn k#{k}(@builtin(global_invocation_id) g: vec3<u32>, @builtin(local_invocation_id) l: vec3<u32>, @builtin(workgroup_id) w: vec3<u32>) {\n  gid = g + args.goff.xyz * vec3<u32>(WGX, WGY, WGZ);\n  lid = l;\n  wid = w + args.goff.xyz;\n  #{f.wname}();\n}\n"
  end

  if mod.static_size > 0
    bytes, relocs = mod.static_image
    manifest << "S\t#{mod.static_size}\t#{bytes.map { |b| ('0' + b.to_s(16))[-2, 2] }.join}"
    relocs.each { |o, t| manifest << "R\t#{o}\t#{t}" }
  end
  out = "// Generated by scripts/pathb-wgsl-emit.rb from the Path B IR; do not edit.\n"
  out << PRELUDE_BASE.sub("STK_WORDS", ((stk_bytes + 3) / 4 + 1).to_s)
  need = mod.need
  out << PRELUDE_SUB if need[:ld8] || need[:ld16] || need[:st8] || need[:st16] || need[:cpy_b]
  out << PRELUDE_CL if need[:cl32] || need[:cl8] || need[:cl16]
  out << PRELUDE_CL_SUB if need[:cl8] || need[:cl16]
  out << PRELUDE_CPY_W if need[:cpy_w]
  out << PRELUDE_CPY_B if need[:cpy_b]
  SYCL_ATOMICS.each { |k| out << atomic_helper(k) if need[:"atomic_#{k}"] }
  out << "\n"
  order.reverse.each { |n| out << mod.fns[n].text << "\n" }
  eps.each { |e| out << e << "\n" }
  [out, manifest]
end

# The kernel key: the closure type that the entry casts __nfcxx_sycl_closure() to.
def kernel_key(form)
  reg = nil
  found = nil
  walk = lambda do |x|
    next unless x.is_a?(Array)
    if head_of(x) == "let" && x.length == 4 && head_of(x[3]) == "call" && x[3][2].is_a?(IRSym) && x[3][2].name == "__nfcxx_sycl_closure"
      reg = x[1]
    elsif found.nil? && reg && head_of(x) == "let" && x.length == 4 && head_of(x[3]) == "bitcast" && x[3][2] == reg
      t = x[3][1]
      t = t[1] while t.is_a?(Array) && (t[0] == "ptr" || t[0] == "const" || t[0] == "volatile")
      found = t[1].to_s if head_of(t) == "struct"
    end
    x.each { |y| walk.call(y) }
  end
  walk.call(form)
  return nil if found.nil?
  [found.start_with?("_Z") ? found[2..-1] : "#{found.length}#{found}", found]
end

def strip_comments(src)
  keep = []
  src.split("\n").each do |line|
    keep << line unless line.lstrip.start_with?(";")
  end
  keep.join("\n")
end

def read_input(path)
  File.open(path, "rb") { |f| f.read }
end

def main(argv)
  args = argv.dup
  manifest_path = nil
  while args.length > 0 && args[0].start_with?("--")
    opt = args.shift
    if opt.start_with?("--manifest=")
      manifest_path = opt[11..-1]
    elsif opt == "--narrow-i64"
      nil
    else
      $stderr.write("usage: pathb-wgsl-emit.rb [--manifest=FILE] [FILE.ir | -] > out.wgsl\n")
      return 1
    end
  end
  src = (args.empty? || args[0] == "-") ? $stdin.read : read_input(args[0])
  begin
    wgsl, manifest = emit_module(src, true)
  rescue Refused => e
    $stderr.write("refused: #{e.message}\n")
    return 3
  rescue BadIR => e
    $stderr.write("error: #{e.message}\n")
    return 1
  end
  $stdout.write(wgsl)
  File.open(manifest_path, "wb") { |f| f.write(manifest.join("\n") + "\n") } if manifest_path
  0
end

rc = main(ARGV)
exit(rc) if rc != 0
