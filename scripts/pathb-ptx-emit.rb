# Path B: emit PTX (for a GPU kernel) from the nfcxx mid-level IR text (docs/notes/pathb-stage2.md), first milestone.
#
# Usage: scripts/mrb scripts/pathb-ptx-emit.rb [--sm=75] [FILE.ir | -] > out.ptx
#        then: ptxas -arch=sm_75 out.ptx -o out.cubin, and load the cubin (tests/gpu/run.sh does this)
#
# Exit status:
#   0  the PTX was written to stdout
#   3  refused: the IR has a node, type or form this emitter does not handle yet; the reason is on stderr
#   1  error: malformed IR text
#
# Model. A kernel is a `.visible .entry`; a device function is a `.func`. With --kernel=NAME (repeatable) the kernels
# are the named functions; with no --kernel, a function that another function calls is a `.func` and every other
# function is a kernel. A `.func` returns a scalar (4- or 8-byte integer, pointer, f32, f64) in a register; a kernel
# returns nothing. A call passes its operands in `.param` space (st.param, then call), and a call's callee must be a
# function of the same module. Recursion is refused. A parameter of
# pointer or of 4- or 8-byte integer type is a .param; the body copies it into its slot, as the IR says. A slot is a
# frame in .local memory (__local_depot<N>), addressed through its generic address (cvta.local). A register is a PTX
# register of its class: .pred for bool, .b32 for 4-byte integers (%r), .b64 for 8-byte integers and pointers (%rd).
# Registers are numbered per class in the order they are first set. Labels are $L<N>; `if` is a predicated branch
# over the then part, and the else part follows.
#
# Handled: block, set, let, store, if (with else), loop (with break and continue), trap, return; the expressions load,
# index, wadd, wsub, wmul, wneg, cdiv, crem (checked: trap on a zero divisor and on INT_MIN / -1), cshl, cshr (checked:
# trap on a count not below the width), and, or, xor, not (bool and integer), the comparisons lt, le, gt, ge, eq, ne (also
# spelled lt.s, lt.u, lt.f, ...), fadd, fsub, fmul, fdiv, fneg (IEEE, with explicit .rn so ptxas does not fuse them),
# iconv, fconv, i2f, u2f, cf2i (checked: trap on NaN or out of range), const (floats too, including +Infinity and
# -Infinity), and gpu (the special registers tid, ctaid, ntid, nctaid, .x .y .z, a Path B form for the GPU). Operands:
# registers, constants, slot addresses, null. Everything else is refused: the next steps are 1- and 2-byte integers,
# bool in memory, aggregates, switch, goto, global data other than zero-initialized static arrays, calls of anything but
# the device intrinsics and the module's own functions (see the model above), and float constants that are not exact decimals.
#
# Checks: bounds IDX N (one unsigned compare, 0 <= IDX < N), nonnull P (a null pointer traps), cf2i and the division
# and shift checks. A file-scope zero-initialized static array of the device unit is block-shared memory (CUDA's
# __shared__): a `.shared` declaration, its address through cvta.shared (`@"name"`), and __nfcxx_syncthreads() is
# bar.sync 0.
#
# Checked operations emit `trap;`, which aborts the kernel (the launch reports an error). PTX has no abort block, so
# each check is a predicated trap at the operation.
#
# The emitted code is checked by running it (tests/gpu/run.sh); it is not compared byte for byte with a hand translation.

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
  return ["ptr", nil] if x[0] == "ptr"          # a pointer is 8 bytes whatever it points to
  return parse_type(x[1]) if x[0] == "const" || x[0] == "volatile"
  raise Refused, "type form (#{x[0]} ...)"
end

def type_size(t)
  return 8 if t[0] == "ptr"
  return t[1] if t[0] == "int" || t[0] == "float"
  raise Refused, "size of #{t[0]}"
end

# The PTX register class of an IR type: "p" for bool, "r" (.b32) for 4-byte integers, "rd" (.b64) for 8-byte integers
# and pointers.
def reg_class(t)
  return "p" if t[0] == "int" && t[3]
  return "rd" if t[0] == "ptr" || (t[0] == "int" && t[1] == 8)
  return "r" if t[0] == "int" && (t[1] == 2 || t[1] == 4)
  return "f" if t[0] == "float" && t[1] == 4
  return "fd" if t[0] == "float" && t[1] == 8
  raise Refused, "value of type #{t[0]} #{t[1]} bytes"
end

# The PTX type suffix for a value or a memory access of an IR type: s32, u32, s64, u64 (a pointer is u64), f32, f64.
def ptx_type(t)
  return "u64" if t[0] == "ptr"
  return "f#{t[1] * 8}" if t[0] == "float" && (t[1] == 4 || t[1] == 8)
  raise Refused, "bool in arithmetic or memory" if t[0] == "int" && t[3]
  # a 2-byte integer (the IR's unsigned_short, and CUDA's half, which is one) is computed in 32 bits: its register
  # holds the value sign- or zero-extended, so the 32-bit operations give the 16-bit result (see Fn#canon)
  return(t[2] ? "s32" : "u32") if t[0] == "int" && t[1] == 2
  raise Refused, "integer of #{t[1]} bytes" unless t[0] == "int" && (t[1] == 4 || t[1] == 8)
  (t[2] ? "s" : "u") + (t[1] * 8).to_s
end

# The memory suffix of a load or store: the 16-bit forms for a 2-byte integer, else ptx_type.
def mem_type(t)
  return(t[2] ? "s16" : "u16") if t[0] == "int" && t[1] == 2 && !t[3]
  ptx_type(t)
end

# The untyped bit suffix (b32, b64) for and, or, xor, not and shl, where the signedness does not matter.
def bits_type(t)
  raise Refused, "bitwise operation on #{t[0]}" unless (t[0] == "int" && !t[3] && (t[1] == 2 || t[1] == 4 || t[1] == 8)) || t[0] == "ptr"
  "b" + (t[0] == "int" && t[1] == 2 ? 32 : type_size(t) * 8).to_s
end

# A decimal float literal, exact in the type: a finite number as printed by the IR (shortest form that reads back), or
# an infinity. Other spellings (NaN, hexadecimal) are refused, because the decimal form would round.
# A name as a PTX identifier: the IR names of template instances and of file-scope statics can carry characters PTX
# does not accept (`temp.1`). Each other character becomes _xHH, so distinct IR names stay distinct.
def ptx_sym(name)
  out = ""
  name.each_char do |c|
    o = c.ord
    if (o >= 48 && o <= 57) || (o >= 65 && o <= 90) || (o >= 97 && o <= 122) || o == 95
      out << c
    else
      out << "_x" << ("0" + o.to_s(16))[-2, 2]
    end
  end
  out
end

def float_lit(text, t)
  if text == "+Infinity" || text == "Infinity"
    return t[1] == 4 ? "0f7F800000" : "0d7FF0000000000000"
  elsif text == "-Infinity"
    return t[1] == 4 ? "0fFF800000" : "0dFFF0000000000000"
  end
  # a decimal with a point and an optional exponent (what the IR prints): no regex, as special_register? has none
  ok = text.count(".") == 1 && text.count("0123456789") > 0
  text.each_char { |c| ok = false unless "0123456789.eE+-".include?(c) }
  raise Refused, "float constant #{text}" unless ok
  text
end

# The instruction that sets predicate t to the bool constant v (IR text 0 or 1): setp of equal or unequal immediates.
def bool_const_setp(t, v)
  case v.to_s
  when "1", "0x1" then "setp.eq.u32 #{t}, 0, 0;"
  when "0", "0x0" then "setp.ne.u32 #{t}, 0, 0;"
  else raise Refused, "bool constant #{v}"
  end
end

# A constant as a PTX immediate of an IR integer, float or pointer type (the bits of v, read with the signedness of t).
def imm(t, v)
  return "0" if t[0] == "ptr"
  raise Refused, "bool constant" if t[3]
  raise Refused, "constant of #{t[0]}" unless t[0] == "int"
  bits = t[1] * 8
  v &= (1 << bits) - 1
  v -= (1 << bits) if t[2] && v >= (1 << (bits - 1))
  v.to_s
end

# The special registers of the GPU: tid, ctaid, ntid, nctaid with a component x, y or z (no regex: mruby's build may lack it).
# The dynamic shared memory of a launch: one extern symbol per module, used by every kernel that calls
# __nfcxx_dynshared_addr. The launch passes its size (dynamicSmemBytes).
DYNSHARED_SYM = "__nfcxx_dynshared"
# The module-level symbol of a string constant (a printf format): the IR's data name with this prefix.
STRING_PREFIX = "__nfcxx_str_"

# Device intrinsics a kernel calls by name (extern "C"), and the special register each reads.
DEVICE_INTRINSICS = {
  "__nfcxx_tid_x" => "tid.x", "__nfcxx_tid_y" => "tid.y", "__nfcxx_tid_z" => "tid.z",
  "__nfcxx_ctaid_x" => "ctaid.x", "__nfcxx_ctaid_y" => "ctaid.y", "__nfcxx_ctaid_z" => "ctaid.z",
  "__nfcxx_ntid_x" => "ntid.x", "__nfcxx_ntid_y" => "ntid.y", "__nfcxx_ntid_z" => "ntid.z",
  "__nfcxx_nctaid_x" => "nctaid.x", "__nfcxx_nctaid_y" => "nctaid.y", "__nfcxx_nctaid_z" => "nctaid.z",
}

# Warp and atomic intrinsics (extern "C", as DEVICE_INTRINSICS). The shuffles take the full-warp mask only (the
# mask operand must be the constant 0xffffffff) and use the whole warp (width 32), so the clamp is fixed.
# `_i` takes and returns a 32-bit integer, `_f` a float (moved through a 32-bit register).
WARP_SHUFFLES = {
  "__nfcxx_shfl_sync_i" => "idx", "__nfcxx_shfl_sync_f" => "idx",
  "__nfcxx_shfl_xor_sync_i" => "bfly", "__nfcxx_shfl_xor_sync_f" => "bfly",
  "__nfcxx_shfl_down_sync_i" => "down", "__nfcxx_shfl_down_sync_f" => "down",
  "__nfcxx_shfl_up_sync_i" => "up", "__nfcxx_shfl_up_sync_f" => "up",
}
WARP_VOTES = { "__nfcxx_ballot_sync" => "ballot", "__nfcxx_any_sync" => "any", "__nfcxx_all_sync" => "all" }
# Scalar 32-bit integer intrinsics that map to one PTX instruction: name => [PTX instruction, number of operands].
# The CUDA names (__umulhi, __popc, __byte_perm) are wrappers in the device prelude (cuda-rewrite.rb, BUILTIN_DEFS).
SCALAR_U32 = {
  "__nfcxx_umulhi" => ["mul.hi.u32", 2],
  "__nfcxx_popc" => ["popc.b32", 1],
  "__nfcxx_byte_perm" => ["prmt.b32", 3],
}
# name => [PTX atom op, PTX type]: the pointer is a generic address (global or shared), the result is the old value
ATOMICS = {
  "__nfcxx_atomic_add_i" => ["add", "s32"], "__nfcxx_atomic_add_f" => ["add", "f32"],
  "__nfcxx_atomic_max_i" => ["max", "s32"], "__nfcxx_atomic_cas_i" => ["cas", "b32"],
}

# A function the IR marks static (internal linkage: `(static)` after the signature, as the IR spec gives it).
def static_fn?(fn)
  fn.form.any? { |x| x.is_a?(Array) && head_of(x) == "static" }
end

def special_register?(name)
  parts = name.split(".")
  parts.length == 2 && ["tid", "ctaid", "ntid", "nctaid"].include?(parts[0]) && ["x", "y", "z"].include?(parts[1])
end

# ------------------------------------------------------------------ functions

# The names of the functions a form calls directly (the `&"name"` callee of every `call`), in order.
def collect_calls(x, acc)
  return acc unless x.is_a?(Array)
  if head_of(x) == "call" && x.length > 2 && x[2].is_a?(IRSym) && x[2].sig == "&"
    acc << x[2].name
  end
  x.each { |y| collect_calls(y, acc) }
  acc
end

# Raises Refused when a call cycle is reachable from name (PTX has no recursion in our lowering).
def check_recursion(name, callees, state)
  return if state[name] == :done
  raise Refused, "recursive call of #{name}" if state[name] == :open
  state[name] = :open
  (callees[name] || []).each { |c| check_recursion(c, callees, state) }
  state[name] = :done
end

class Fn
  attr_reader :name, :params, :ret, :form, :uses_dynshared
  attr_accessor :kernel, :module_fns, :shared, :globals, :strings, :uses_printf

  def initialize(form, index)
    @form = form
    @index = index
    @kernel = true
    @module_fns = {}
    @shared = {}
    @globals = {}
    @ret = nil
    @setup_done = false
    @ncall = 0
    @name = form[1].to_s
    @regs = {}              # IR register "%N" => [PTX register, IR type]
    @count = { "p" => 0, "r" => 0, "rd" => 0, "f" => 0, "fd" => 0 }
    @loops = []             # [continue label, break label] of the enclosing loops, innermost last
    @slots = {}             # slot name => byte offset in the frame
    @frame = 0
    @params = []            # IR types of the parameters, in order
    @prologue = []          # the address of the frame, the parameter loads
    @lines = []             # the body
    @sp = nil               # PTX register holding the frame's generic address
    @nlab = 0
  end

  def emit(s)
    @lines << "  #{s}"
  end

  def label(l)
    @lines << "#{l}:"
  end

  def fresh(cls)
    n = @count[cls]
    @count[cls] = n + 1
    "%#{cls}#{n}"
  end

  def new_label
    n = @nlab
    @nlab = n + 1
    "$L#{n}"
  end

  # The PTX label of an IR label: created on first use, so a goto may come before its label.
  def named_label(name)
    @named_labels ||= {}
    @named_labels[name] ||= new_label
  end

  # ---- the header: return type, parameters, slots

  def setup
    return if @setup_done
    @setup_done = true
    @body = []
    ret = nil
    @form.each_with_index do |f, i|
      next if i < 2
      h = head_of(f)
      if h == "ret"
        ret = parse_type(f[1])
        if ret[0] == "void"
          @ret = nil
        elsif @kernel
          raise Refused, "kernel #{@name} returns a value"
        else
          ok = (ret[0] == "ptr") || (ret[0] == "int" && !ret[3] && (ret[1] == 2 || ret[1] == 4 || ret[1] == 8)) || (ret[0] == "float" && (ret[1] == 4 || ret[1] == 8))
          raise Refused, "function #{@name} returns a #{ret[0]} (scalars only)" unless ok
          @ret = ret
        end
      elsif h == "params"
        f.drop(1).each_with_index do |p, k|
          raise Refused, "variadic function" if head_of(p) == "ellipsis"
          raise Refused, "parameter form #{form_text(p)}" unless head_of(p) == "param" && p.length == 4
          raise BadIR, "parameter register must be %#{k}" unless p[1] == "%#{k}"
          ty = parse_type(p[3])
          raise Refused, "parameter of type #{ty[0]}" unless ty[0] == "ptr" || (ty[0] == "int" && !ty[3] && (ty[1] == 2 || ty[1] == 4 || ty[1] == 8)) || (ty[0] == "float" && (ty[1] == 4 || ty[1] == 8))
          @params << ty
        end
      elsif h == "static" || h == "weak"
        nil   # linkage of the function: no effect on the PTX (the entry or helper is emitted the same way)
      elsif h == "slot"
        # (slot "x" TYPE) or (slot "x" TYPE SIZE ALIGN): the explicit size and alignment are the ones of the IR's layout
        raise Refused, "slot form #{form_text(f)}" unless f.length == 3 || f.length == 5
        if f.length == 5
          size = as_int(f[3])
          align = as_int(f[4])
        else
          size = type_size(parse_type(f[2]))
          align = size
        end
        align = 1 if align < 1
        @frame = (@frame + align - 1) / align * align
        @slots[f[1].to_s] = @frame
        @frame += size
      else
        @body << f
      end
    end
    raise BadIR, "function without a return type" if ret.nil?
    @frame = (@frame + 7) / 8 * 8
  end

  # ---- operands

  # An operand as [PTX text, IR type]: a register, an immediate, or the generic address of a slot (in a fresh register).
  def operand(x)
    if x.is_a?(String) && x.start_with?("%")
      r = @regs[x]
      raise BadIR, "register #{x} is used before it is set" if r.nil?
      return r
    end
    h = head_of(x)
    if h == "const"
      ty = parse_type(x[1])
      return [float_lit(x[2].to_s, ty), ty] if ty[0] == "float"
      if ty[0] == "int" && ty[3]
        # a bool constant is a predicate: setp of two equal (true) or unequal (false) immediates
        t = fresh("p")
        emit(bool_const_setp(t, x[2]))
        return [t, ty]
      end
      return [imm(ty, as_int(x[2])), ty]
    end
    if h == "null"
      return ["0", parse_type(x[1])]
    end
    if x.is_a?(IRSym) && x.sig == "@"
      t = fresh("rd")
      if @shared.key?(x.name)
        emit("cvta.shared.u64 #{t}, #{ptx_sym(x.name)};")
      elsif @globals.key?(x.name)
        emit("cvta.global.u64 #{t}, #{ptx_sym(x.name)};")
      elsif @strings.key?(x.name)
        emit("cvta.const.u64 #{t}, #{ptx_sym(STRING_PREFIX + x.name)};")
      else
        raise Refused, "static object @\"#{x.name}\" (only block-shared and device globals are lowered)"
      end
      return [t, ["ptr", nil]]
    end
    if x.is_a?(IRSym) && x.sig == "$"
      off = @slots[x.name]
      raise BadIR, "slot #{x.name} is not declared" if off.nil?
      t = fresh("rd")
      emit("add.u64 #{t}, #{@sp}, #{off};")
      return [t, ["ptr", nil]]
    end
    raise Refused, "operand #{form_text(x)}"
  end

  # The operand in a register: an immediate is moved into a fresh one (a first source operand must be a register).
  def reg_of(op, ty)
    text = op
    return text if text.start_with?("%")
    t = fresh(reg_class(ty))
    emit("mov.#{ptx_type(ty)} #{t}, #{text};")
    t
  end

  # The register for an IR register being set: declared on its first `let`, with the class of its type.
  def ir_reg(name, ty)
    r = @regs[name]
    return r[0] if r
    t = fresh(reg_class(ty))
    @regs[name] = [t, ty]
    t
  end

  def expect(dty, ty)
    raise BadIR, "value of type #{ty[0]} (#{type_size(ty)} bytes) stored in a #{dty[0]} (#{type_size(dty)} bytes)" unless reg_class(dty) == reg_class(ty)
  end

  # ---- expressions: store the value of x in register dest, of IR type dty

  def rval(x, dest, dty)
    h = head_of(x)
    case h
    when "load"
      ty = parse_type(x[1])
      expect(dty, ty)
      addr, aty = operand(x[2])
      if ty[0] == "int" && ty[3]
        b = fresh("r")
        emit("ld.u8 #{b}, [#{reg_of(addr, aty)}];")
        emit("setp.ne.u32 #{dest}, #{b}, 0;")
      else
        emit("ld.#{mem_type(ty)} #{dest}, [#{reg_of(addr, aty)}];")
      end
    when "bitcast"
      ty = parse_type(x[1])
      expect(dty, ty)
      raise Refused, "bitcast to a non-pointer" unless ty[0] == "ptr" && dty[0] == "ptr"
      v, vty = operand(x[2])
      raise Refused, "bitcast of a non-pointer" unless vty[0] == "ptr"
      emit("mov.u64 #{dest}, #{reg_of(v, vty)};")
    when "offset"
      # (offset ADDR N): the address of a field, N bytes past ADDR (pathb-stage2 section 5)
      expect(dty, ["ptr", nil])
      base, bty = operand(x[1])
      n = as_int(x[2])
      raise Refused, "offset of a non-pointer" unless bty[0] == "ptr"
      emit("add.s64 #{dest}, #{reg_of(base, bty)}, #{n};")
    when "index"
      expect(dty, ["ptr", nil])
      base, bty = operand(x[1])
      base = reg_of(base, bty)
      idx, ity = operand(x[2])
      idx = reg_of(idx, ity)
      size = as_int(x[3])
      off = fresh("rd")
      if reg_class(ity) == "r"
        emit("mul.wide.s32 #{off}, #{idx}, #{size};")
      else
        emit("mul.lo.s64 #{off}, #{idx}, #{size};")
      end
      emit("add.s64 #{dest}, #{base}, #{off};")
    when "wadd", "wsub", "wmul"
      ty = parse_type(x[1])
      expect(dty, ty)
      a, _ = operand(x[2])
      b, _ = operand(x[3])
      op = { "wadd" => "add", "wsub" => "sub", "wmul" => "mul.lo" }[h]
      emit("#{op}.#{ptx_type(ty)} #{dest}, #{reg_of(a, ty)}, #{b};")
    when "wneg"
      ty = parse_type(x[1])
      expect(dty, ty)
      raise Refused, "negation of bool" if ty[0] == "int" && ty[3]
      a, _ = operand(x[2])
      emit("neg.s#{type_size(ty) * 8} #{dest}, #{reg_of(a, ty)};")
    when "cdiv", "crem"
      ty = parse_type(x[1])
      expect(dty, ty)
      checked_div(h, dest, ty, x[2], x[3])
    when "cshl", "cshr"
      ty = parse_type(x[1])
      expect(dty, ty)
      checked_shift(h, dest, ty, x[2], x[3])
    when "and", "or", "xor"
      ty = parse_type(x[1])
      expect(dty, ty)
      a, _ = operand(x[2])
      b, _ = operand(x[3])
      if ty[0] == "int" && ty[3]
        emit("#{h}.pred #{dest}, #{reg_of(a, ty)}, #{b};")
      else
        emit("#{h}.#{bits_type(ty)} #{dest}, #{reg_of(a, ty)}, #{b};")
      end
    when "not"
      ty = parse_type(x[1])
      expect(dty, ty)
      a, _ = operand(x[2])
      if ty[0] == "int" && ty[3]
        emit("not.pred #{dest}, #{reg_of(a, ty)};")
      else
        emit("not.#{bits_type(ty)} #{dest}, #{reg_of(a, ty)};")
      end
    when "fadd", "fsub", "fmul", "fdiv"
      ty = parse_type(x[1])
      raise Refused, "#{h} on #{ty[0]}" unless ty[0] == "float"
      expect(dty, ty)
      a, _ = operand(x[2])
      b, _ = operand(x[3])
      op = { "fadd" => "add", "fsub" => "sub", "fmul" => "mul", "fdiv" => "div" }[h]
      # .rn: an explicit rounding mode, so ptxas does not contract a multiply and an add into a fused multiply-add
      emit("#{op}.rn.#{ptx_type(ty)} #{dest}, #{reg_of(a, ty)}, #{b};")
    when "fneg"
      ty = parse_type(x[1])
      raise Refused, "fneg on #{ty[0]}" unless ty[0] == "float"
      expect(dty, ty)
      a, _ = operand(x[2])
      emit("neg.#{ptx_type(ty)} #{dest}, #{reg_of(a, ty)};")
    when "iconv"
      ty = parse_type(x[1])
      expect(dty, ty)
      a, aty = operand(x[2])
      int_convert(dest, ty, a, aty)
    when "fconv"
      ty = parse_type(x[1])
      raise Refused, "fconv to #{ty[0]}" unless ty[0] == "float"
      expect(dty, ty)
      a, aty = operand(x[2])
      raise BadIR, "fconv of a #{aty[0]}" unless aty[0] == "float"
      if type_size(ty) == type_size(aty)
        emit("mov.#{ptx_type(ty)} #{dest}, #{a};")
      else
        # widening is exact; narrowing rounds to nearest even
        rnd = type_size(ty) < type_size(aty) ? ".rn" : ""
        emit("cvt#{rnd}.#{ptx_type(ty)}.#{ptx_type(aty)} #{dest}, #{reg_of(a, aty)};")
      end
    when "i2f", "u2f"
      ty = parse_type(x[1])
      raise Refused, "#{h} to #{ty[0]}" unless ty[0] == "float"
      expect(dty, ty)
      a, aty = operand(x[2])
      raise Refused, "#{h} of bool" if aty[0] == "int" && aty[3]
      emit("cvt.rn.#{ptx_type(ty)}.#{ptx_type(aty)} #{dest}, #{reg_of(a, aty)};")
    when "cf2i"
      ty = parse_type(x[1])
      expect(dty, ty)
      a, aty = operand(x[2])
      float_to_int(dest, ty, a, aty)
    when "lt", "le", "gt", "ge", "eq", "ne", "lt.s", "le.s", "gt.s", "ge.s", "eq.s", "ne.s",
         "lt.u", "le.u", "gt.u", "ge.u", "eq.u", "ne.u", "lt.f", "le.f", "gt.f", "ge.f", "eq.f", "ne.f"
      ty = parse_type(x[1])
      raise BadIR, "comparison result is not bool" unless reg_class(dty) == "p"
      compare(h.split(".")[0], dest, ty, x[2], x[3])
    when "call"
      # The device intrinsics of a kernel (`extern "C" unsigned __nfcxx_tid_x(void)` and the rest of the table
      # below) are special-register reads. Any other callee is a function of the module (call_site).
      ty = parse_type(x[1])
      expect(dty, ty)
      callee = x[2]
      name = callee.is_a?(IRSym) && callee.sig == "&" ? callee.name : nil
      reg = name && DEVICE_INTRINSICS[name]
      if name == "__nfcxx_dynshared_addr"
        # The dynamic shared memory of the launch (`extern __shared__ T buf[]`, rewritten by cuda-rewrite.rb): one
        # module-level extern .shared symbol, whose generic address is taken with cvta.shared (see emit_module).
        raise Refused, "intrinsic #{name} takes no arguments" if x.length != 3
        raise Refused, "intrinsic #{name} returns #{ty[0]}, not a pointer" unless ty[0] == "ptr"
        emit("cvta.shared.u64 #{dest}, #{DYNSHARED_SYM};")
        @uses_dynshared = true
      elsif reg
        raise Refused, "intrinsic #{name} takes no arguments" if x.length != 3
        raise Refused, "intrinsic #{name} returns #{ty[0]}, not a 32-bit unsigned" unless ty[0] == "int" && type_size(ty) == 4
        emit("mov.u32 #{dest}, %#{reg};")
      elsif name == "printf"
        printf_call(x, dest, ty)
      elsif WARP_SHUFFLES.key?(name) || WARP_VOTES.key?(name) || ATOMICS.key?(name)
        device_builtin(name, x, dest, ty)
      elsif SCALAR_U32.key?(name)
        scalar_u32(name, x, dest, ty)
      else
        call_site(x, dest, ty)
      end
    when "gpu"
      ty = parse_type(x[1])
      expect(dty, ty)
      name = x[2].to_s
      raise Refused, "special register #{name}" unless special_register?(name)
      emit("mov.u32 #{dest}, %#{name};")
    when "const"
      ty = parse_type(x[1])
      expect(dty, ty)
      if ty[0] == "int" && ty[3]
        emit(bool_const_setp(dest, x[2]))
      else
        text, _ = operand(x)
        emit("mov.#{ptx_type(ty)} #{dest}, #{text};")
      end
    else
      raise Refused, "expression #{h || form_text(x)}"
    end
  end

  # ---- operators with checks and conversions (called from rval)

  # The comparison op (lt, le, gt, ge, eq, ne) of the IR operands xa and xb, of type ty, into predicate dest.
  # A bool comparison is an xor, negated for eq. A float ne is unordered (neu): C's != holds when an operand is NaN.
  def compare(op, dest, ty, xa, xb)
    a, aty = operand(xa)
    b, _ = operand(xb)
    if ty[0] == "int" && ty[3]
      raise Refused, "bool comparison #{op}" unless op == "eq" || op == "ne"
      if op == "ne"
        emit("xor.pred #{dest}, #{a}, #{b};")
      else
        t = fresh("p")
        emit("xor.pred #{t}, #{a}, #{b};")
        emit("not.pred #{dest}, #{t};")
      end
      return
    end
    cmp = op
    cmp = "neu" if ty[0] == "float" && op == "ne"
    emit("setp.#{cmp}.#{ptx_type(ty)} #{dest}, #{reg_of(a, aty)}, #{b};")
  end

  # cdiv (signed or unsigned) and crem: trap on a zero divisor, and for signed types on INT_MIN / -1.
  # The checks are predicated traps; a constant divisor needs only the checks that can fail.
  def checked_div(op, dest, ty, xa, xb)
    raise Refused, "#{op} on #{ty[0]}" unless ty[0] == "int" && !ty[3] && (ty[1] == 2 || ty[1] == 4 || ty[1] == 8)
    t = ptx_type(ty)
    a, _ = operand(xa)
    b, _ = operand(xb)
    a = reg_of(a, ty)
    min = imm(ty, -(1 << (ty[1] * 8 - 1)))
    if b == "0"
      emit("trap;")
    elsif b.start_with?("%")
      p = fresh("p")
      emit("setp.eq.#{t} #{p}, #{b}, 0;")
      emit("@#{p} trap;")
      if ty[2]
        m = fresh("p")
        q = fresh("p")
        emit("setp.eq.#{t} #{m}, #{b}, -1;")
        emit("setp.eq.#{t} #{q}, #{a}, #{min};")
        emit("and.pred #{m}, #{m}, #{q};")
        emit("@#{m} trap;")
      end
    elsif ty[2] && b == "-1"
      q = fresh("p")
      emit("setp.eq.#{t} #{q}, #{a}, #{min};")
      emit("@#{q} trap;")
    end
    emit("#{op == "cdiv" ? "div" : "rem"}.#{t} #{dest}, #{a}, #{b};")
  end

  # cshl and cshr (count in ty's width, as the IR gives it): trap unless 0 <= count < width. The count is compared
  # unsigned, so a negative count fails the test too. A 64-bit count is narrowed to 32 bits after the test.
  def checked_shift(op, dest, ty, xa, xb)
    raise Refused, "#{op} on #{ty[0]}" unless ty[0] == "int" && !ty[3] && (ty[1] == 2 || ty[1] == 4 || ty[1] == 8)
    bits = ty[1] * 8
    a, _ = operand(xa)
    a = reg_of(a, ty)
    c, cty = operand(xb)
    raise Refused, "shift count of type #{cty[0]}" unless cty[0] == "int" && !cty[3] && (cty[1] == 4 || cty[1] == 8)
    cnt = c
    if c.start_with?("%")
      p = fresh("p")
      if reg_class(cty) == "rd"
        emit("setp.hs.u64 #{p}, #{c}, #{bits};")
        emit("@#{p} trap;")
        cnt = fresh("r")
        emit("cvt.u32.u64 #{cnt}, #{c};")
      else
        emit("setp.hs.u32 #{p}, #{c}, #{bits};")
        emit("@#{p} trap;")
      end
    else
      emit("trap;") if c.to_i < 0 || c.to_i >= bits
    end
    if op == "cshl"
      emit("shl.#{bits_type(ty)} #{dest}, #{a}, #{cnt};")
    else
      emit("shr.#{ptx_type(ty)} #{dest}, #{a}, #{cnt};")
    end
  end

  # iconv: integer to integer, sign-extending from a signed source and zero-extending from an unsigned one, and
  # truncating to a narrower target (cvt does all three).
  def int_convert(dest, ty, a, aty)
    raise Refused, "iconv to #{ty[0]}" unless ty[0] == "int" && !ty[3] && (ty[1] == 2 || ty[1] == 4 || ty[1] == 8)
    raise BadIR, "iconv of a #{aty[0]}" unless aty[0] == "int"
    if aty[3]
      b = fresh("r")
      emit("selp.u32 #{b}, 1, 0, #{a};")
      if type_size(ty) == 4
        emit("mov.b32 #{dest}, #{b};")
      else
        emit("cvt.#{ptx_type(ty)}.u32 #{dest}, #{b};")
      end
      return
    end
    if type_size(ty) == type_size(aty) || (type_size(ty) == 2 && type_size(aty) == 4)
      emit("mov.#{ptx_type(ty)} #{dest}, #{a};")
    elsif type_size(ty) == 2
      emit("cvt.u32.#{ptx_type(aty)} #{dest}, #{reg_of(a, aty)};")
    else
      emit("cvt.#{ptx_type(ty)}.#{ptx_type(aty)} #{dest}, #{reg_of(a, aty)};")
    end
  end

  # cf2i: a float to an integer, with C's truncation. The IR says it traps on NaN and on values whose truncation does
  # not fit the target. The test is ordered (NaN makes both comparisons false), so NaN traps too. Each bound is exact
  # in the source type: the lower one is strict (lo - 1) when that is a float of the source type, else lo itself.
  def float_to_int(dest, ty, a, aty)
    raise Refused, "cf2i to #{ty[0]}" unless ty[0] == "int" && !ty[3] && (ty[1] == 4 || ty[1] == 8)
    raise BadIR, "cf2i of a #{aty[0]}" unless aty[0] == "float"
    bits = ty[1] * 8
    fsz = aty[1]
    ft = ptx_type(aty)
    a = reg_of(a, aty)
    if ty[2]
      lo = -(1 << (bits - 1))
      hi = 1 << (bits - 1)
      exact_below = (fsz == 8 && bits <= 53) || (fsz == 4 && bits <= 24)
      lo_op, lo_v = exact_below ? ["gt", (lo - 1).to_f] : ["ge", lo.to_f]
    else
      lo_op, lo_v = "gt", -1.0
      hi = 1 << bits
    end
    p1 = fresh("p")
    p2 = fresh("p")
    emit("setp.#{lo_op}.#{ft} #{p1}, #{a}, #{lo_v.to_s};")
    emit("setp.lt.#{ft} #{p2}, #{a}, #{hi.to_f.to_s};")
    emit("and.pred #{p1}, #{p1}, #{p2};")
    emit("@!#{p1} trap;")
    emit("cvt.rzi.#{ptx_type(ty)}.#{ft} #{dest}, #{a};")
  end

  # ---- statements

  # A 2-byte integer lives in a 32-bit register extended to 32 bits: sign-extended for a signed type, zero-extended
  # for an unsigned one. A result computed in 32 bits is brought back into that form here.
  def canon(dest, t)
    return unless t[0] == "int" && t[1] == 2 && !t[3]
    if t[2]
      tmp = fresh("r")
      emit("shl.b32 #{tmp}, #{dest}, 16;")
      emit("shr.s32 #{dest}, #{tmp}, 16;")
    else
      emit("and.b32 #{dest}, #{dest}, 65535;")
    end
  end

  def stmt(s)
    h = head_of(s)
    case h
    when "block"
      s.drop(1).each { |t| stmt(t) }
    when "let"
      ty = parse_type(s[2])
      dest = ir_reg(s[1], ty)
      rval(s[3], dest, ty)
      canon(dest, ty)
    when "set"
      r = @regs[s[1]]
      raise BadIR, "set of #{s[1]} before its let" if r.nil?
      text, ty = operand(s[2])
      expect(r[1], ty)
      # a bool register is a predicate: its value is copied as a predicate (operand gives one for a bool)
      emit(reg_class(r[1]) == "p" ? "mov.pred #{r[0]}, #{text};" : "mov.#{ptx_type(r[1])} #{r[0]}, #{text};")
    when "store"
      ty = parse_type(s[1])
      addr, aty = operand(s[2])
      val, vty = operand(s[3])
      if ty[0] == "int" && ty[3]
        # a bool is one byte in memory, 0 or 1 (the IR's bool layout); the value is a predicate here
        expect(ty, vty)
        b = fresh("r")
        emit("selp.u32 #{b}, 1, 0, #{val};")
        emit("st.u8 [#{reg_of(addr, aty)}], #{b};")
      else
        emit("st.#{mem_type(ty)} [#{reg_of(addr, aty)}], #{reg_of(val, ty)};")
      end
    when "if"
      cond, cty = operand(s[1])
      raise BadIR, "if condition is not a bool register" unless reg_class(cty) == "p" && cond.start_with?("%")
      then_f = s.drop(2).find { |f| head_of(f) == "then" }
      else_f = s.drop(2).find { |f| head_of(f) == "else" }
      raise BadIR, "if without then" if then_f.nil?
      lab_else = new_label
      lab_end = new_label
      emit("@!#{cond} bra #{lab_else};")
      then_f.drop(1).each { |t| stmt(t) }
      emit("bra #{lab_end};")
      label(lab_else)
      (else_f ? else_f.drop(1) : []).each { |t| stmt(t) }
      label(lab_end)
    when "loop"
      # repeat { body; L_cont: step }: break leaves to L_end, continue goes to L_cont (the step), as pathb-stage2 says
      body_f = s.drop(1).find { |f| head_of(f) == "body" }
      step_f = s.drop(1).find { |f| head_of(f) == "step" }
      raise BadIR, "loop without body and step" if body_f.nil? || step_f.nil?
      top = new_label
      lab_cont = new_label
      lab_end = new_label
      label(top)
      @loops.push([lab_cont, lab_end])
      body_f.drop(1).each { |t| stmt(t) }
      label(lab_cont)
      step_f.drop(1).each { |t| stmt(t) }
      @loops.pop
      emit("bra #{top};")
      label(lab_end)
    when "switch"
      # The arms are a flat list with case and default markers (pathb-stage2 section 2). A dispatch chain compares
      # the operand with each case value and branches; the body follows, with C fallthrough between its markers.
      # `break` leaves to the end label (the switch is on the loop stack with no continue label).
      body_f = s.drop(1).find { |f| head_of(f) == "body" }
      raise BadIR, "switch without body" if body_f.nil?
      v, vty = operand(s[1])
      raise Refused, "switch on a #{vty[0]}" unless vty[0] == "int" && !vty[3]
      raise Refused, "switch on a #{type_size(vty)}-byte integer (only 32 and 64 bits are lowered)" unless type_size(vty) == 4 || type_size(vty) == 8
      v = reg_of(v, vty)
      items = []
      expand = lambda { |f| head_of(f) == "block" ? f.drop(1).each { |t| expand.call(t) } : items << f }
      body_f.drop(1).each { |f| expand.call(f) }
      lab_end = new_label
      arms = []        # [item index, label, case value or nil for default]
      default_lab = nil
      items.each_with_index do |it, idx|
        h = head_of(it)
        if h == "case"
          c = it[1]
          raise BadIR, "case value is not a constant" unless head_of(c) == "const"
          cty = parse_type(c[1])
          raise Refused, "case of a different type than the switch" unless cty == vty
          val = as_int(c[2])
          raise Refused, "duplicate case #{val}" if arms.any? { |a| a[2] == val }
          arms << [idx, new_label, val]
        elsif h == "default"
          raise Refused, "two default labels" if default_lab
          default_lab = new_label
          arms << [idx, default_lab, nil]
        end
      end
      bits = bits_type(vty)
      arms.each do |_, lab, val|
        next if val.nil?
        q = fresh("p")
        emit("setp.eq.#{bits} #{q}, #{v}, #{imm(vty, val)};")
        emit("@#{q} bra #{lab};")
      end
      emit("bra #{default_lab || lab_end};")
      @loops.push([nil, lab_end])
      by_index = arms.map { |idx, lab, _| [idx, lab] }.to_h
      items.each_with_index do |it, idx|
        if by_index.key?(idx)
          label(by_index[idx])
        else
          stmt(it)
        end
      end
      @loops.pop
      label(lab_end)
    when "label"
      label(named_label(s[1].to_s))
    when "goto"
      emit("bra #{named_label(s[1].to_s)};")
    when "break"
      raise Refused, "break outside a loop or switch" if @loops.empty?
      emit("bra #{@loops[-1][1]};")
    when "continue"
      # the innermost loop: a switch on the stack has no continue label
      enclosing = @loops.reverse.find { |e| e[0] }
      raise BadIR, "continue outside a loop" if enclosing.nil?
      emit("bra #{enclosing[0]};")
    when "trap", "unreachable"
      # (trap) and (unreachable): an illegal instruction on the GPU; the IR spec says unreachable traps
      emit("trap;")
    when "bounds"
      # (bounds IDX N): traps unless 0 <= IDX < N. One unsigned compare does both ends of a signed index.
      v, vty = operand(s[1])
      raise Refused, "bounds of a non-integer" unless vty[0] == "int"
      n = as_int(s[2])
      bits = vty[1] * 8
      uty = bits == 64 ? "u64" : "u32"
      q = fresh("p")
      emit("setp.ge.#{uty} #{q}, #{reg_of(v, vty)}, #{n};")
      emit("@#{q} trap;")
    when "nonnull"
      # (nonnull P): a null pointer traps (pathb-stage2 section 4). A null constant always traps.
      p, pty = operand(s[1])
      raise Refused, "nonnull of #{form_text(s[1])}" unless pty[0] == "ptr"
      if p == "0"
        emit("trap;")
      else
        q = fresh("p")
        emit("setp.eq.u64 #{q}, #{reg_of(p, pty)}, 0;")
        emit("@#{q} trap;")
      end
    when "return"
      if @ret.nil?
        raise Refused, "return with a value in a void function" if s.length > 1
        emit("ret;")
      else
        raise Refused, "return without a value in #{@name}" unless s.length == 2
        v, vty = operand(s[1])
        expect(@ret, vty)
        emit("mov.#{ret_bits(@ret)} %rv, #{reg_of(v, vty)};")
        emit("ret;")
      end
    when "eval"
      # an expression statement: only a call, whose value is discarded
      raise Refused, "eval of #{form_text(s[1])}" unless s.length == 2 && head_of(s[1]) == "call"
      call_site(s[1], nil, nil)
    else
      raise Refused, "statement #{h || form_text(s)}"
    end
  end

  # ---- the function text

  def ret_bits(t)
    t[0] == "float" ? "f#{t[1] * 8}" : bits_type(t)
  end

  # A call of a function of the module. dest is the PTX register of the value (nil if discarded); ty its IR type.
  # The full-warp mask operand: the constant 0xffffffff (as an unsigned or int constant).
  def full_mask!(op, name)
    text, _ = operand(op)
    raise Refused, "#{name}: only the full-warp mask 0xffffffff is lowered (mask operand #{text})" unless ["4294967295", "-1"].include?(text)
  end

  # A scalar 32-bit intrinsic of SCALAR_U32: one instruction, operands and result all 32-bit integers.
  def scalar_u32(name, x, dest, ty)
    op, arity = SCALAR_U32[name]
    args = x[3..-1] || []
    raise Refused, "#{name} has no value" if dest.nil?
    raise Refused, "#{name} takes #{arity} argument(s)" unless args.length == arity
    raise Refused, "#{name} returns #{ty[0]}" unless ty[0] == "int" && type_size(ty) == 4
    regs = args.map do |a|
      v, vty = operand(a)
      raise Refused, "#{name}: argument of type #{vty[0]}" unless vty[0] == "int" && vty[1] == 4
      reg_of(v, vty)
    end
    emit("#{op} #{dest}, #{regs.join(', ')};")
  end

  def device_builtin(name, x, dest, ty)
    args = x[3..-1] || []
    raise Refused, "#{name} has no value" if dest.nil?
    if WARP_SHUFFLES.key?(name)
      raise Refused, "#{name} takes (mask, value, lane)" unless args.length == 3
      full_mask!(args[0], name)
      float = name.end_with?("_f")
      raise Refused, "#{name} returns #{ty[0]}" unless (float ? ty[0] == "float" : ty[0] == "int") && type_size(ty) == 4
      v, vty = operand(args[1])
      raise Refused, "#{name}: value of type #{vty[0]}" unless float ? vty[0] == "float" && vty[1] == 4 : vty[0] == "int" && vty[1] == 4
      lane, lty = operand(args[2])
      raise Refused, "#{name}: lane of type #{lty[0]}" unless lty[0] == "int" && lty[1] == 4
      src = reg_of(v, vty)
      lane = reg_of(lane, lty)
      mode = WARP_SHUFFLES[name]
      clamp = mode == "up" ? "0" : "31"
      if float
        bits = fresh("r")
        out = fresh("r")
        emit("mov.b32 #{bits}, #{src};")
        emit("shfl.sync.#{mode}.b32 #{out}, #{bits}, #{lane}, #{clamp}, 0xffffffff;")
        emit("mov.b32 #{dest}, #{out};")
      else
        emit("shfl.sync.#{mode}.b32 #{dest}, #{src}, #{lane}, #{clamp}, 0xffffffff;")
      end
    elsif WARP_VOTES.key?(name)
      raise Refused, "#{name} takes (mask, predicate)" unless args.length == 2
      full_mask!(args[0], name)
      raise Refused, "#{name} returns #{ty[0]}" unless ty[0] == "int" && type_size(ty) == 4
      pv, pty = operand(args[1])
      raise Refused, "#{name}: predicate of type #{pty[0]}" unless pty[0] == "int" && pty[1] == 4
      pr = fresh("p")
      emit("setp.ne.s32 #{pr}, #{reg_of(pv, pty)}, 0;")
      case WARP_VOTES[name]
      when "ballot"
        emit("vote.sync.ballot.b32 #{dest}, #{pr}, 0xffffffff;")
      else
        q = fresh("p")
        emit("vote.sync.#{WARP_VOTES[name]}.pred #{q}, #{pr}, 0xffffffff;")
        emit("selp.s32 #{dest}, 1, 0, #{q};")
      end
    else
      op, aty = ATOMICS[name]
      want = name.end_with?("_f") ? "float" : "int"
      raise Refused, "#{name} takes (pointer, value)" unless (name == "__nfcxx_atomic_cas_i" ? args.length == 3 : args.length == 2)
      pv, pty = operand(args[0])
      raise Refused, "#{name}: first operand is a #{pty[0]}, not a pointer" unless pty[0] == "ptr"
      raise Refused, "#{name} returns #{ty[0]}" unless ty[0] == want && type_size(ty) == 4
      vals = args[1..-1].map do |a|
        v, t = operand(a)
        raise Refused, "#{name}: operand of type #{t[0]}" unless t[0] == want && t[1] == 4
        reg_of(v, t)
      end
      emit("atom.#{op}.#{aty} #{dest}, [#{reg_of(pv, pty)}], #{vals.join(", ")};")
    end
  end

  # Does this body call printf? (the function then needs its frame pointer, for the argument buffer)
  def contains_printf?(f)
    return false unless f.is_a?(Array)
    return true if head_of(f) == "call" && f.length > 2 && f[2].is_a?(IRSym) && f[2].sig == "&" && f[2].name == "printf"
    f.any? { |c| contains_printf?(c) }
  end

  # printf, as CUDA's device runtime lowers it: the format is a string constant (a module-level .const array, the IR's
  # `(data NAME (string ...))`), the arguments are stored into a frame buffer at their C layout by their IR types, and
  # vprintf(format, buffer) is called; the runtime prints the line when the kernel completes (cudaDeviceSynchronize).
  def printf_call(x, dest, ty)
    raise Refused, "printf returns #{ty[0]}, not int" unless ty[0] == "int" && type_size(ty) == 4
    raise Refused, "printf is not a variadic call of one fixed argument" unless head_of(x[3]) == "variadic" && x.length >= 5 && as_int(x[3][1]) == 1
    fmt = x[4]
    raise Refused, "printf format must be a string constant" unless fmt.is_a?(IRSym) && fmt.sig == "@" && @strings.key?(fmt.name)
    vargs = x.length > 5 ? x[5..-1] : []
    # the operands first (they may emit code), then the layout: each argument at its own size, naturally aligned
    ops = vargs.map { |a| operand(a) }
    layout = []
    off = 0
    ops.each do |op, t|
      unless (t[0] == "int" && (t[1] == 4 || t[1] == 8)) || (t[0] == "float" && t[1] == 8) || t[0] == "ptr"
        raise Refused, "printf argument of type #{t[0]} #{t[1]} bytes (an int of 4 or 8 bytes, a double or a pointer)"
      end
      size = t[0] == "ptr" ? 8 : t[1]
      off = (off + size - 1) / size * size
      layout << [op, t, off]
      off += size
    end
    buf = (@frame + 7) / 8 * 8
    @frame = buf + (off + 7) / 8 * 8
    base = fresh("rd")
    emit("add.u64 #{base}, #{@sp}, #{buf};")
    layout.each do |op, t, o|
      value = reg_of(op, t)
      addr = fresh("rd")
      emit("add.u64 #{addr}, #{base}, #{o};")
      emit("st.#{ptx_type(t)} [#{addr}], #{value};")
    end
    fmt_reg = fresh("rd")
    emit("cvta.const.u64 #{fmt_reg}, #{ptx_sym(STRING_PREFIX + fmt.name)};")
    n = (@nlab += 1)
    emit("{")
    emit("  .param .b64 __pf_fmt_#{n};")
    emit("  .param .b64 __pf_buf_#{n};")
    emit("  .param .b32 __pf_rv_#{n};")
    emit("  st.param.b64 [__pf_fmt_#{n}], #{fmt_reg};")
    emit("  st.param.b64 [__pf_buf_#{n}], #{base};")
    emit("  call (__pf_rv_#{n}), vprintf, (__pf_fmt_#{n}, __pf_buf_#{n});")
    emit("  ld.param.b32 #{dest}, [__pf_rv_#{n}];") if dest
    emit("}")
    @uses_printf = true
  end

  def call_site(x, dest, ty)
    callee_sym = x[2]
    raise Refused, "indirect call" unless callee_sym.is_a?(IRSym) && callee_sym.sig == "&"
    cname = callee_sym.name
    if cname == "__nfcxx_syncthreads"
      # the block barrier: every thread of the block waits here, and shared memory is visible after it
      raise Refused, "__nfcxx_syncthreads takes no arguments" unless x.length == 3
      raise Refused, "__nfcxx_syncthreads has no value" unless dest.nil?
      emit("bar.sync 0;")
      return
    end
    if cname == "__nfcxx_syncwarp"
      # the warp barrier of the mask: bar.warp.sync takes the mask (32 bits) as its operand
      raise Refused, "__nfcxx_syncwarp takes one mask argument" unless x.length == 4
      raise Refused, "__nfcxx_syncwarp has no value" unless dest.nil?
      mop, mty = operand(x[3])
      raise Refused, "__nfcxx_syncwarp mask is not a 32-bit integer" unless mty[0] == "int" && type_size(mty) == 4
      emit("bar.warp.sync #{reg_of(mop, mty)};")
      return
    end
    raise Refused, "call of intrinsic #{cname} as a statement" if DEVICE_INTRINSICS.key?(cname)
    callee = @module_fns[cname]
    raise Refused, "call of #{cname} (not a function of this module)" if callee.nil?
    raise Refused, "call of kernel #{cname}" if callee.kernel
    callee.setup
    args = x.length > 3 ? x[3..-1] : []
    raise Refused, "call of #{cname} with #{args.length} arguments, it takes #{callee.params.length}" unless args.length == callee.params.length
    if dest
      raise Refused, "call of #{cname} as a value, but it returns nothing" if callee.ret.nil?
      expect(ty, callee.ret)
    end
    @ncall += 1
    c = "$call#{@ncall}"
    emit("{")
    regs = []
    args.each_with_index do |a, k|
      v, aty = operand(a)
      expect(callee.params[k], aty)
      regs << reg_of(v, aty)
    end
    regs.each_with_index do |r, k|
      emit("  .param .#{ptx_type(callee.params[k])} #{c}_p#{k};")
      emit("  st.param.#{ptx_type(callee.params[k])} [#{c}_p#{k}], #{r};")
    end
    list = (0...regs.length).map { |k| "#{c}_p#{k}" }.join(", ")
    if dest
      emit("  call (#{dest}), #{cname}, (#{list});")
    else
      emit("  call #{cname}, (#{list});")
    end
    emit("}")
  end

  def compile
    setup
    if @frame > 0 || contains_printf?(@body)
      @sp = fresh("rd")
      @prologue << "mov.u64 #{@sp}, __local_depot#{@index};"
      @prologue << "cvta.local.u64 #{@sp}, #{@sp};"
    end
    @params.each_with_index do |ty, k|
      r = fresh(reg_class(ty))
      @regs["%#{k}"] = [r, ty]
      @prologue << "ld.param.#{ptx_type(ty)} #{r}, [#{@name}_param_#{k}];"
    end
    @body.each { |s| stmt(s) }
    emit("ret;") unless head_of(@body.last) == "return"
  end

  def text
    out = []
    if @kernel
      out << ".visible .entry #{@name}("
    elsif @ret
      out << ".func (.reg .#{ret_bits(@ret)} %rv) #{@name}("
    else
      out << ".func #{@name}("
    end
    @params.each_with_index do |ty, k|
      comma = k + 1 < @params.length ? "," : ""
      out << "  .param .#{ptx_type(ty)} #{@name}_param_#{k}#{comma}"
    end
    out << ")"
    out << "{"
    out << "  .reg .pred %p<#{@count['p']}>;" if @count["p"] > 0
    out << "  .reg .b32 %r<#{@count['r']}>;" if @count["r"] > 0
    out << "  .reg .b64 %rd<#{@count['rd']}>;" if @count["rd"] > 0
    out << "  .reg .f32 %f<#{@count['f']}>;" if @count["f"] > 0
    out << "  .reg .f64 %fd<#{@count['fd']}>;" if @count["fd"] > 0
    out << "  .local .align 8 .b8 __local_depot#{@index}[#{@frame}];" if @frame > 0
    @prologue.each { |s| out << "  #{s}" }
    out.concat(@lines)
    out << "}"
    out.join("\n") + "\n"
  end
end

# ------------------------------------------------------------------ module

# Whole-line comments (a line whose first non-blank character is ';') are dropped before the IR is read; the IR itself
# has no comments (docs/notes/pathb-stage2.md), and tests/gpu/mul2.ir uses them to say what the kernel does.
def strip_comments(src)
  keep = []
  src.split("\n").each do |line|
    keep << line unless line.lstrip.start_with?(";")
  end
  keep.join("\n")
end

def emit_module(src, sm, kernels = [])
  forms = parse_forms(tokenize(strip_comments(src)))
  fns = []
  shared = {}
  globals = {}
  strings = {}
  forms.each do |f|
    h = head_of(f)
    if h == "ir-module"
      next
    elsif h == "function"
      fns << Fn.new(f, fns.length)
    elsif h == "data"
      # a string constant (a printf format): its bytes, as a .const array in the module
      name = f[1].to_s
      payload = f[3]
      raise Refused, "data #{name} (only string constants are lowered)" unless head_of(payload) == "string" && payload.length == 2
      raise Refused, "data #{name} is defined twice" if strings.key?(name)
      strings[name] = payload[1].to_s.bytes
    elsif h == "global"
      # A file-scope static array of the device unit is block-shared memory (CUDA's __shared__): its name and
      # size come from the IR, and it must be zero-initialized. Any other global is refused.
      # Function-local __shared__ (a template instance's, mangled _ZZ..., linkage weak) and file-scope static
      # objects are block-shared memory; any other zero-initialized global is device memory (__device__), .global.
      name = f[1].to_s
      ty = f[2]
      size = as_int(f[3])
      align = as_int(f[4])
      # the optional linkage (static, weak, extern) and the initializer come after the size and alignment, in any case
      linkage = f.drop(5).map { |x| head_of(x) }.find { |h| h == "static" || h == "weak" || h == "extern" }
      raise Refused, "global #{name} is extern (no definition in this unit)" if linkage == "extern"
      init = f.drop(5).find { |x| head_of(x) == "init" }
      raise Refused, "global #{name}: only zero initializers are lowered" unless init && init.length == 2 && head_of(init[1]) == "zero"
      raise Refused, "global #{name}: partial zero initializer" unless as_int(init[1][1]) == 0 && as_int(init[1][2]) == size
      if linkage == "static" || (linkage == "weak" && name.start_with?("_ZZ"))
        shared[name] = [size, align]
      else
        globals[name] = [size, align]
      end
    elsif h == "abi-type"
      raise Refused, "aggregate type #{form_text(f[1])}: struct and union values by value are not lowered yet"
    else
      raise Refused, "top-level form #{h || form_text(f)}"
    end
  end
  raise BadIR, "no function in the IR" if fns.empty?
  # A listed kernel is named as the source names it (cuda-rewrite.rb --kernels writes plain names). A C++ function's IR
  # name is its Itanium mangled name, so a plain name matches by the rule scripts/cuda-embed.rb uses.
  kernels = kernels.map do |k|
    hits = fns.map(&:name).select { |n| n == k || n.start_with?("_Z#{k.length}#{k}") }
    raise BadIR, "no function named #{k} in the IR" if hits.empty?
    raise BadIR, "#{hits.length} functions named #{k} in the IR" if hits.length > 1
    hits[0]
  end
  # Keep the functions reachable from the kernels: the listed kernels, or else the functions that are not static and
  # not called. A static function that nothing reaches is dead code (a C++ header's unused inline helper): it is not
  # emitted, rather than taken for a kernel (which could not return its value).
  pre_by = {}
  fns.each { |fn| pre_by[fn.name] = fn }
  pre_callees = {}
  fns.each { |fn| pre_callees[fn.name] = collect_calls(fn.form, []).select { |c| pre_by.key?(c) }.uniq }
  pre_called = {}
  pre_callees.each { |caller, cs| cs.each { |c| pre_called[c] = caller } }
  roots = kernels.empty? ? fns.reject { |fn| static_fn?(fn) || pre_called.key?(fn.name) }.map(&:name) : kernels
  live = {}
  stack = roots.dup
  until stack.empty?
    n = stack.pop
    next if live[n] || !pre_by.key?(n)
    live[n] = true
    stack.concat(pre_callees[n])
  end
  fns = fns.select { |fn| live[fn.name] }
  by_name = {}
  fns.each { |fn| by_name[fn.name] = fn }
  callees = {}
  fns.each { |fn| callees[fn.name] = collect_calls(fn.form, []).select { |c| by_name.key?(c) }.uniq }
  called = {}
  callees.each { |caller, cs| cs.each { |c| called[c] = caller } }
  if kernels.empty?
    fns.each { |fn| fn.kernel = !called.key?(fn.name) }
  else
    kernels.each { |k| raise BadIR, "no function named #{k} in the IR" unless by_name.key?(k) }
    fns.each { |fn| fn.kernel = kernels.include?(fn.name) }
    called.each { |c, caller| raise Refused, "kernel #{c} is called by #{caller}" if by_name[c].kernel }
  end
  state = {}
  fns.each { |fn| check_recursion(fn.name, callees, state) }
  fns.each { |fn| fn.module_fns = by_name; fn.shared = shared; fn.globals = globals; fn.strings = strings }
  fns.each { |fn| fn.compile }
  out = "// Generated by scripts/pathb-ptx-emit.rb from the Path B IR; do not edit.\n"
  out << ".version 8.0\n.target #{sm}\n.address_size 64\n\n"
  out << ".extern .shared .align 16 .b8 #{DYNSHARED_SYM}[];\n" if fns.any?(&:uses_dynshared)
  strings.each { |name, bytes| out << ".const .align 1 .b8 #{ptx_sym(STRING_PREFIX + name)}[#{bytes.length}] = {#{bytes.join(',')}};\n" }
  out << ".extern .func (.param .b32 __vprintf_rv) vprintf (.param .b64 __vprintf_fmt, .param .b64 __vprintf_buf);\n" if fns.any?(&:uses_printf)
  shared.each { |name, (size, align)| out << ".shared .align #{align} .b8 #{ptx_sym(name)}[#{size}];\n" }
  globals.each { |name, (size, align)| out << ".global .align #{align} .b8 #{ptx_sym(name)}[#{size}];\n" }
  out << "\n" unless shared.empty? && globals.empty?
  # PTX needs a callee declared before its first call: emit the functions callee first (depth-first post-order).
  ordered = []
  seen = {}
  visit = lambda do |name|
    next if seen[name]
    seen[name] = true
    (callees[name] || []).each { |c| visit.call(c) }
    ordered << by_name[name]
  end
  fns.each { |fn| visit.call(fn.name) }
  ordered.each { |fn| out << fn.text << "\n" }
  out
end

def read_input(path)
  File.open(path, "rb") { |f| f.read }
end

def main(argv)
  args = argv.dup
  sm = "sm_75"
  kernels = []
  while args.length > 0 && args[0].start_with?("--")
    opt = args.shift
    if opt.start_with?("--sm=")
      sm = "sm_" + opt[5..-1]
    elsif opt.start_with?("--kernel=")
      kernels << opt[9..-1]
    else
      $stderr.write("usage: pathb-ptx-emit.rb [--sm=75] [--kernel=NAME]... [FILE.ir | -] > out.ptx\n")
      return 1
    end
  end
  if args.length > 1
    $stderr.write("usage: pathb-ptx-emit.rb [--sm=75] [--kernel=NAME]... [FILE.ir | -] > out.ptx\n")
    return 1
  end
  src = (args.empty? || args[0] == "-") ? $stdin.read : read_input(args[0])
  begin
    ptx = emit_module(src, sm, kernels)
  rescue Refused => e
    $stderr.write("refused: #{e.message}\n")
    return 3
  rescue BadIR => e
    $stderr.write("error: #{e.message}\n")
    return 1
  end
  $stdout.write(ptx)
  0
end

rc = main(ARGV)
exit(rc) if rc != 0
