# Path B: emit SPIR-V assembly text (the input of spirv-as) for a GPU kernel, from the nfcxx mid-level IR text
# (docs/notes/pathb-stage2.md). The sibling of scripts/pathb-ptx-emit.rb, for the Intel XPU (OpenCL and SYCL take SPIR-V).
#
# Usage: scripts/mrb scripts/pathb-spirv-kernel-emit.rb [FILE.ir | -] > out.spvasm
#        then: spirv-as --target-env spv1.1 out.spvasm -o out.spv, spirv-val, and load out.spv (tests/gpu/spirv/run.sh)
#
# Exit status:
#   0  the assembly text was written to stdout
#   3  refused: the IR has a node, type or form this emitter does not handle yet; the reason is on stderr
#   1  error: malformed IR text
#
# Model. A function that no other function calls is a kernel (OpEntryPoint Kernel) and returns void. The module is
# Physical64 with the OpenCL memory model; every pointer is a CrossWorkgroup pointer to its pointee (typed pointers).
# Integers are OpTypeInt 32 0 or 64 0: signedness is in the operations (OpSLessThan, OpSConvert, ...), not in the type.
# Parameters are SSA values. A slot is a Function-storage variable (OpVariable), and so is a register that some `set`
# assigns; every other register is an SSA value. The GPU indices are Input builtins: tid is LocalInvocationId, ctaid is
# WorkgroupId, ntid is WorkgroupSize and nctaid is NumWorkgroups (the components x, y, z are the vector's 0, 1, 2). As
# in OpenCL these builtins are vectors of size_t (64 bits), so a component is narrowed to the IR's 32-bit unsigned.
# Control flow is structured: `if` is OpSelectionMerge and OpBranchConditional, and `loop` is an OpLoopMerge whose
# continue block runs the step.
#
# Handled: block, let, set, store, if (with else), loop (with break and continue), return, eval (of a device intrinsic);
# the expressions load, index, wadd, wsub, wmul, wneg, and, or, xor, not, the comparisons lt, le, gt, ge, eq, ne (int
# with .s or .u, float with .f, and pointers; the IR's own signedness applies when there is no suffix), fadd, fsub,
# fmul, fdiv, fneg (no contraction: SPIR-V does not fuse them without a decoration), iconv, fconv, i2f, u2f, const, null,
# gpu, and the device intrinsics of pathb-ptx-emit.rb (DEVICE_INTRINSICS names).
# Refused (exit 3): trap (OpKill is not a kernel exit), checked division and shifts, cf2i, bool in memory, 1- and 2-byte
# integers, calls of module functions, switch, goto, static data, aggregates, and float constants that are not decimals.
#
# The emitted code is checked by running it (tests/gpu/spirv/run.sh); it is not compared byte for byte with a hand translation.

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
BOOL = ["int", 1, false, true]
UINT = ["int", 4, false, false]
SIZE_T = ["int", 8, false, false]   # the OpenCL work-item builtins are vectors of size_t
SCALARS = {
  "bool" => BOOL,
  "char" => ["int", 1, true, false],
  "signed_char" => ["int", 1, true, false],
  "unsigned_char" => ["int", 1, false, false],
  "short" => ["int", 2, true, false],
  "unsigned_short" => ["int", 2, false, false],
  "int" => ["int", 4, true, false],
  "unsigned_int" => UINT,
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
  return ["ptr", parse_type(x[1])] if x[0] == "ptr" && x.length == 2
  return parse_type(x[1]) if x[0] == "const" || x[0] == "volatile"
  raise Refused, "type form (#{x[0]} ...)"
end

# A key that names an IR type up to what SPIR-V distinguishes: signedness is not part of it.
def tkey(t)
  return "void" if t[0] == "void"
  return "bool" if t[0] == "int" && t[3]
  return "i#{t[1]}" if t[0] == "int"
  return "f#{t[1]}" if t[0] == "float"
  "p(#{tkey(t[1])})"
end

def type_size(t)
  return 8 if t[0] == "ptr"
  return t[1] if t[0] == "int" || t[0] == "float"
  raise Refused, "size of #{t[0]}"
end

def bool?(t)
  t[0] == "int" && t[3] ? true : false
end

# An integer that is a value of its own (4 or 8 bytes, not bool).
def word?(t)
  t[0] == "int" && !t[3] && (t[1] == 4 || t[1] == 8) ? true : false
end

# A type a slot, a parameter or a memory access may have: an integer, a float or a pointer (not bool).
def mem_type?(t)
  return true if word?(t)
  return true if t[0] == "float" && (t[1] == 4 || t[1] == 8)
  t[0] == "ptr"
end

def check_type(got, want, what)
  raise BadIR, "#{what}: value of type #{tkey(got)}, expected #{tkey(want)}" unless tkey(got) == tkey(want)
end

# A decimal float literal, exact in the type: the form the IR prints (a point, optional exponent). Infinities and NaN
# are refused here: the decimal spelling of an infinity is not one spirv-as reads.
def float_lit(text)
  ok = text.count(".") == 1 && text.count("0123456789") > 0
  text.each_char { |c| ok = false unless "0123456789.eE+-".include?(c) }
  raise Refused, "float constant #{text}" unless ok
  text
end

# The GPU builtins. A device intrinsic (`extern "C" unsigned __nfcxx_tid_x(void)`) reads a component of one.
GPU_BUILTINS = { "tid" => "LocalInvocationId", "ctaid" => "WorkgroupId", "ntid" => "WorkgroupSize", "nctaid" => "NumWorkgroups" }
AXES = { "x" => 0, "y" => 1, "z" => 2 }
DEVICE_INTRINSICS = {
  "__nfcxx_tid_x" => "tid.x", "__nfcxx_tid_y" => "tid.y", "__nfcxx_tid_z" => "tid.z",
  "__nfcxx_ctaid_x" => "ctaid.x", "__nfcxx_ctaid_y" => "ctaid.y", "__nfcxx_ctaid_z" => "ctaid.z",
  "__nfcxx_ntid_x" => "ntid.x", "__nfcxx_ntid_y" => "ntid.y", "__nfcxx_ntid_z" => "ntid.z",
  "__nfcxx_nctaid_x" => "nctaid.x", "__nfcxx_nctaid_y" => "nctaid.y", "__nfcxx_nctaid_z" => "nctaid.z",
}

# The comparison opcodes: signed and unsigned integers, floats (ordered, except ne: C's != holds for NaN) and pointers.
SIGNED_CMP = { "lt" => "OpSLessThan", "le" => "OpSLessThanEqual", "gt" => "OpSGreaterThan", "ge" => "OpSGreaterThanEqual",
               "eq" => "OpIEqual", "ne" => "OpINotEqual" }
UNSIGNED_CMP = { "lt" => "OpULessThan", "le" => "OpULessThanEqual", "gt" => "OpUGreaterThan", "ge" => "OpUGreaterThanEqual",
                 "eq" => "OpIEqual", "ne" => "OpINotEqual" }
FLOAT_CMP = { "lt" => "OpFOrdLessThan", "le" => "OpFOrdLessThanEqual", "gt" => "OpFOrdGreaterThan",
              "ge" => "OpFOrdGreaterThanEqual", "eq" => "OpFOrdEqual", "ne" => "OpFUnordNotEqual" }

# ------------------------------------------------------------------ the module: types, constants, builtins

class SpvModule
  attr_reader :caps, :decor, :decls, :iface

  def initialize
    @n = 0
    @types = {}      # tkey (and "fp(...)" for Function pointers) => id
    @consts = {}     # "tkey text" => id
    @builtins = {}   # builtin name => [variable id, vector type id]
    @vec3 = nil
    @caps = ["Addresses", "Kernel"]
    @decor = []      # OpDecorate lines
    @decls = []      # types, constants and global variables, each after what it uses
    @iface = []      # the Input variables an entry point lists
  end

  def fresh(prefix)
    @n += 1
    "%#{prefix}#{@n}"
  end

  def cap(name)
    @caps << name unless @caps.include?(name)
  end

  def decl(id, text)
    @decls << "#{id} = #{text}"
  end

  def type_id(t)
    key = tkey(t)
    return @types[key] if @types.key?(key)
    id = fresh("T")
    if t[0] == "void"
      decl(id, "OpTypeVoid")
    elsif bool?(t)
      decl(id, "OpTypeBool")
    elsif word?(t)
      cap("Int64") if t[1] == 8
      decl(id, "OpTypeInt #{t[1] * 8} 0")
    elsif t[0] == "float" && (t[1] == 4 || t[1] == 8)
      cap("Float64") if t[1] == 8
      decl(id, "OpTypeFloat #{t[1] * 8}")
    elsif t[0] == "ptr"
      raise Refused, "pointer to void" if t[1][0] == "void"
      pointee = type_id(t[1])
      decl(id, "OpTypePointer CrossWorkgroup #{pointee}")
    else
      raise Refused, "type #{key} (1- and 2-byte integers and aggregates are not lowered yet)"
    end
    @types[key] = id
  end

  # The pointer type of a Function-storage variable (a slot or a mutable register) of IR type t.
  def function_ptr_id(t)
    key = "fp(#{tkey(t)})"
    return @types[key] if @types.key?(key)
    pointee = type_id(t)
    id = fresh("T")
    decl(id, "OpTypePointer Function #{pointee}")
    @types[key] = id
  end

  def function_type_id(ret, params)
    id = fresh("T")
    decl(id, "OpTypeFunction #{type_id(ret)} #{params.map { |p| type_id(p) }.join(" ")}".rstrip)
    id
  end

  # A constant of IR type t from its IR text: an integer (its bits), a bool (0 or 1) or a decimal float.
  def constant(t, text)
    key = "#{tkey(t)} #{text}"
    return @consts[key] if @consts.key?(key)
    tid = type_id(t)
    if bool?(t)
      raise Refused, "bool constant #{text}" unless text == "0" || text == "1"
      line = text == "1" ? "OpConstantTrue #{tid}" : "OpConstantFalse #{tid}"
    elsif t[0] == "int"
      line = "OpConstant #{tid} #{as_int(text) & ((1 << (t[1] * 8)) - 1)}"
    elsif t[0] == "float"
      line = "OpConstant #{tid} #{float_lit(text)}"
    else
      raise Refused, "constant of #{tkey(t)}"
    end
    id = fresh("C")
    decl(id, line)
    @consts[key] = id
  end

  def null_const(t)
    key = "null #{tkey(t)}"
    return @consts[key] if @consts.key?(key)
    id = fresh("C")
    decl(id, "OpConstantNull #{type_id(t)}")
    @consts[key] = id
  end

  # The Input variable of a GPU builtin (created on first use) and the type of its vector.
  def builtin(name)
    return @builtins[name] if @builtins.key?(name)
    if @vec3.nil?
      @vec3 = fresh("T")
      decl(@vec3, "OpTypeVector #{type_id(SIZE_T)} 3")
    end
    ptr = fresh("T")
    decl(ptr, "OpTypePointer Input #{@vec3}")
    var = fresh("G")
    decl(var, "OpVariable #{ptr} Input")
    @decor << "OpDecorate #{var} BuiltIn #{name}"
    @iface << var
    @builtins[name] = [var, @vec3]
  end
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

# The names of the registers a form assigns with `set` (they are variables, not SSA values).
def collect_sets(x, acc)
  return acc unless x.is_a?(Array)
  acc << x[1].to_s if head_of(x) == "set" && x.length > 1
  x.each { |y| collect_sets(y, acc) }
  acc
end

class SpvFn
  attr_reader :name, :id, :form

  def initialize(mod, form)
    @mod = mod
    @form = form
    @name = form[1].to_s
    @id = mod.fresh("F")
    @params = []     # [id, IR type] of the parameters, in order
    @slots = {}      # slot name => [variable id, IR type]
    @regs = {}       # IR register "%N" => [id, IR type, true if a variable]
    @mutable = {}    # registers that a `set` assigns
    @body = []
    @vars = []       # OpVariable lines of the entry block, first in it
    @lines = []      # the entry label, then the rest of the body
    @loops = []      # [continue label, break label] of the enclosing loops, innermost last
    @term = false    # the current block has its terminator
  end

  # ---- the blocks

  def emit(s)
    @lines << "  #{s}"
  end

  def new_label
    @mod.fresh("L")
  end

  def begin_block(l)
    @lines << "#{l} = OpLabel"
    @term = false
  end

  def terminate(s)
    emit(s)
    @term = true
  end

  # A branch to l, unless the block already has its terminator (a return or a break before it).
  def jump(l)
    terminate("OpBranch #{l}") unless @term
  end

  # ---- the header: the return, the parameters, the slots

  def setup
    @form.each_with_index do |f, i|
      next if i < 2
      h = head_of(f)
      if h == "ret"
        raise Refused, "function #{@name} returns a value (kernels return void)" unless parse_type(f[1])[0] == "void"
      elsif h == "params"
        f.drop(1).each_with_index do |p, k|
          raise Refused, "variadic function" if head_of(p) == "ellipsis"
          raise Refused, "parameter form #{form_text(p)}" unless head_of(p) == "param" && p.length == 4
          raise BadIR, "parameter register must be %#{k}" unless p[1] == "%#{k}"
          ty = parse_type(p[3])
          raise Refused, "parameter of type #{tkey(ty)}" unless mem_type?(ty)
          @params << ty
        end
      elsif h == "static"
        nil
      elsif h == "slot"
        raise Refused, "slot form #{form_text(f)}" unless f.length == 3 || f.length == 5
        ty = parse_type(f[2])
        raise Refused, "slot of type #{tkey(ty)}" unless mem_type?(ty)
        id = @mod.fresh("V")
        @vars << "  #{id} = OpVariable #{@mod.function_ptr_id(ty)} Function"
        @slots[f[1].to_s] = [id, ty]
      else
        @body << f
      end
    end
  end

  # ---- operands

  # The address of a memory access of IR type ty: a slot (its variable) or a pointer value to ty.
  def address(x, ty)
    if x.is_a?(IRSym) && x.sig == "$"
      s = @slots[x.name]
      raise BadIR, "slot #{x.name} is not declared" if s.nil?
      check_type(s[1], ty, "slot #{x.name}")
      return s[0]
    end
    v, vty = value(x)
    raise BadIR, "address of a #{tkey(vty)}" unless vty[0] == "ptr"
    check_type(vty[1], ty, "address")
    v
  end

  # The value of an expression: [SPIR-V id, IR type].
  def value(x)
    if x.is_a?(String) && x.start_with?("%")
      r = @regs[x]
      raise BadIR, "register #{x} is used before it is set" if r.nil?
      return [r[0], r[1]] unless r[2]
      id = @mod.fresh("v")
      emit("#{id} = OpLoad #{@mod.type_id(r[1])} #{r[0]}")
      return [id, r[1]]
    end
    h = head_of(x)
    case h
    when "const"
      ty = parse_type(x[1])
      raise Refused, "constant of #{tkey(ty)}" unless bool?(ty) || ty[0] == "int" || ty[0] == "float"
      return [@mod.constant(ty, x[2].to_s), ty]
    when "null"
      ty = parse_type(x[1])
      raise Refused, "null of #{tkey(ty)}" unless ty[0] == "ptr"
      return [@mod.null_const(ty), ty]
    when "load"
      ty = parse_type(x[1])
      raise Refused, "bool in memory" if bool?(ty)
      addr = address(x[2], ty)
      id = @mod.fresh("v")
      emit("#{id} = OpLoad #{@mod.type_id(ty)} #{addr}")
      return [id, ty]
    when "index"
      base, bty = value(x[1])
      raise BadIR, "index of a #{tkey(bty)}" unless bty[0] == "ptr"
      idx, ity = value(x[2])
      raise Refused, "index of type #{tkey(ity)}" unless word?(ity)
      size = as_int(x[3])
      raise Refused, "index scale #{size} is not the element size #{type_size(bty[1])}" unless size == type_size(bty[1])
      id = @mod.fresh("v")
      emit("#{id} = OpPtrAccessChain #{@mod.type_id(bty)} #{base} #{idx}")
      return [id, bty]
    when "wadd", "wsub", "wmul"
      ty = parse_type(x[1])
      raise Refused, "#{h} on #{tkey(ty)}" unless word?(ty)
      a, b = binary_operands(x, ty)
      op = { "wadd" => "OpIAdd", "wsub" => "OpISub", "wmul" => "OpIMul" }[h]
      return [emit_op(op, ty, a, b), ty]
    when "wneg"
      ty = parse_type(x[1])
      raise Refused, "negation of #{tkey(ty)}" unless word?(ty)
      a, aty = value(x[2])
      check_type(aty, ty, "wneg")
      return [emit_op("OpSNegate", ty, a), ty]
    when "and", "or", "xor"
      ty = parse_type(x[1])
      a, b = binary_operands(x, ty)
      if bool?(ty)
        op = { "and" => "OpLogicalAnd", "or" => "OpLogicalOr", "xor" => "OpLogicalNotEqual" }[h]
      elsif word?(ty)
        op = { "and" => "OpBitwiseAnd", "or" => "OpBitwiseOr", "xor" => "OpBitwiseXor" }[h]
      else
        raise Refused, "#{h} on #{tkey(ty)}"
      end
      return [emit_op(op, ty, a, b), ty]
    when "not"
      ty = parse_type(x[1])
      a, aty = value(x[2])
      check_type(aty, ty, "not")
      if bool?(ty)
        return [emit_op("OpLogicalNot", ty, a), ty]
      elsif word?(ty)
        return [emit_op("OpNot", ty, a), ty]
      end
      raise Refused, "not on #{tkey(ty)}"
    when "lt", "le", "gt", "ge", "eq", "ne", "lt.s", "le.s", "gt.s", "ge.s", "eq.s", "ne.s",
         "lt.u", "le.u", "gt.u", "ge.u", "eq.u", "ne.u", "lt.f", "le.f", "gt.f", "ge.f", "eq.f", "ne.f"
      ty = parse_type(x[1])
      raise Refused, "comparison of bool" if bool?(ty)
      op, suffix = h.split(".")
      table = if ty[0] == "float" then FLOAT_CMP
              elsif ty[0] == "ptr" then UNSIGNED_CMP
              elsif suffix == "u" || (suffix.nil? && !ty[2]) then UNSIGNED_CMP
              else SIGNED_CMP
              end
      raise BadIR, "comparison suffix .#{suffix} on #{tkey(ty)}" if suffix && (suffix == "f") != (ty[0] == "float")
      a, b = binary_operands(x, ty)
      return [emit_op(table[op], BOOL, a, b), BOOL]
    when "fadd", "fsub", "fmul", "fdiv"
      ty = parse_type(x[1])
      raise Refused, "#{h} on #{tkey(ty)}" unless ty[0] == "float" && mem_type?(ty)
      a, b = binary_operands(x, ty)
      op = { "fadd" => "OpFAdd", "fsub" => "OpFSub", "fmul" => "OpFMul", "fdiv" => "OpFDiv" }[h]
      return [emit_op(op, ty, a, b), ty]
    when "fneg"
      ty = parse_type(x[1])
      raise Refused, "fneg on #{tkey(ty)}" unless ty[0] == "float" && mem_type?(ty)
      a, aty = value(x[2])
      check_type(aty, ty, "fneg")
      return [emit_op("OpFNegate", ty, a), ty]
    when "iconv"
      ty = parse_type(x[1])
      raise Refused, "iconv to #{tkey(ty)}" unless word?(ty)
      a, aty = value(x[2])
      raise Refused, "iconv of #{tkey(aty)}" unless word?(aty)
      return [a, ty] if type_size(ty) == type_size(aty)
      op = type_size(ty) > type_size(aty) && aty[2] ? "OpSConvert" : "OpUConvert"
      return [emit_op(op, ty, a), ty]
    when "fconv"
      ty = parse_type(x[1])
      raise Refused, "fconv to #{tkey(ty)}" unless ty[0] == "float" && mem_type?(ty)
      a, aty = value(x[2])
      raise BadIR, "fconv of a #{tkey(aty)}" unless aty[0] == "float"
      return [a, ty] if type_size(ty) == type_size(aty)
      return [emit_op("OpFConvert", ty, a), ty]
    when "i2f", "u2f"
      ty = parse_type(x[1])
      raise Refused, "#{h} to #{tkey(ty)}" unless ty[0] == "float" && mem_type?(ty)
      a, aty = value(x[2])
      raise Refused, "#{h} of #{tkey(aty)}" unless word?(aty)
      return [emit_op(aty[2] ? "OpConvertSToF" : "OpConvertUToF", ty, a), ty]
    when "gpu"
      ty = parse_type(x[1])
      return builtin_component(x[2].to_s, ty)
    when "call"
      ty = parse_type(x[1])
      callee = x[2]
      name = callee.is_a?(IRSym) && callee.sig == "&" ? callee.name : nil
      if name && DEVICE_INTRINSICS.key?(name)
        raise Refused, "intrinsic #{name} takes no arguments" if x.length != 3
        return builtin_component(DEVICE_INTRINSICS[name], ty)
      end
      raise Refused, "call of #{name || form_text(callee)} (calls of module functions are not lowered yet)"
    else
      raise Refused, "expression #{h || form_text(x)}"
    end
  end

  # Two operands of type ty (x[2] and x[3] of the IR form).
  def binary_operands(x, ty)
    a, aty = value(x[2])
    b, bty = value(x[3])
    check_type(aty, ty, "operand")
    check_type(bty, ty, "operand")
    [a, b]
  end

  # An instruction of result type ty over the operands (ids); returns its result id.
  def emit_op(op, ty, *args)
    id = @mod.fresh("v")
    emit("#{id} = #{op} #{@mod.type_id(ty)} #{args.join(" ")}")
    id
  end

  # Component of a GPU builtin (name is "tid.x" and the like): a load of the vector, then its component.
  def builtin_component(name, ty)
    parts = name.split(".")
    raise Refused, "special register #{name}" unless parts.length == 2 && GPU_BUILTINS.key?(parts[0]) && AXES.key?(parts[1])
    raise Refused, "#{name} returns #{tkey(ty)}, not a 32-bit unsigned" unless tkey(ty) == "i4"
    var, vec = @mod.builtin(GPU_BUILTINS[parts[0]])
    v = @mod.fresh("v")
    emit("#{v} = OpLoad #{vec} #{var}")
    comp = @mod.fresh("v")
    emit("#{comp} = OpCompositeExtract #{@mod.type_id(SIZE_T)} #{v} #{AXES[parts[1]]}")
    id = @mod.fresh("v")
    emit("#{id} = OpUConvert #{@mod.type_id(UINT)} #{comp}")
    [id, UINT]
  end

  # The variable of a register that a `set` assigns (created by its first `let`).
  def var_for(name, ty)
    r = @regs[name]
    return r[0] if r && r[2]
    id = @mod.fresh("V")
    @vars << "  #{id} = OpVariable #{@mod.function_ptr_id(ty)} Function"
    @regs[name] = [id, ty, true]
    id
  end

  # ---- statements

  # The statements of a block, each after a terminator in a block of its own (it is unreachable, as the IR says).
  def stmts(list)
    list.each do |s|
      begin_block(new_label) if @term
      stmt(s)
    end
  end

  def stmt(s)
    h = head_of(s)
    case h
    when "block"
      stmts(s.drop(1))
    when "let"
      ty = parse_type(s[2])
      v, vty = value(s[3])
      check_type(vty, ty, "let #{s[1]}")
      name = s[1].to_s
      if @mutable[name]
        emit("OpStore #{var_for(name, ty)} #{v}")
      else
        @regs[name] = [v, ty, false]
      end
    when "set"
      name = s[1].to_s
      r = @regs[name]
      raise BadIR, "set of #{name} before its let" if r.nil? || !r[2]
      v, vty = value(s[2])
      check_type(vty, r[1], "set #{name}")
      emit("OpStore #{r[0]} #{v}")
    when "store"
      ty = parse_type(s[1])
      raise Refused, "store of bool" if bool?(ty)
      addr = address(s[2], ty)
      v, vty = value(s[3])
      check_type(vty, ty, "store")
      emit("OpStore #{addr} #{v}")
    when "if"
      cond, cty = value(s[1])
      raise BadIR, "if condition is not a bool" unless bool?(cty)
      then_f = s.drop(2).find { |f| head_of(f) == "then" }
      else_f = s.drop(2).find { |f| head_of(f) == "else" }
      raise BadIR, "if without then" if then_f.nil?
      lab_then = new_label
      lab_else = new_label
      lab_end = new_label
      emit("OpSelectionMerge #{lab_end} None")
      terminate("OpBranchConditional #{cond} #{lab_then} #{else_f ? lab_else : lab_end}")
      begin_block(lab_then)
      stmts(then_f.drop(1))
      jump(lab_end)
      if else_f
        begin_block(lab_else)
        stmts(else_f.drop(1))
        jump(lab_end)
      end
      begin_block(lab_end)
    when "loop"
      # repeat { body; L_cont: step }: break leaves to L_end, continue goes to L_cont (the step), as pathb-stage2 says
      body_f = s.drop(1).find { |f| head_of(f) == "body" }
      step_f = s.drop(1).find { |f| head_of(f) == "step" }
      raise BadIR, "loop without body and step" if body_f.nil? || step_f.nil?
      head = new_label
      lab_body = new_label
      lab_cont = new_label
      lab_end = new_label
      jump(head)
      begin_block(head)
      emit("OpLoopMerge #{lab_end} #{lab_cont} None")
      terminate("OpBranch #{lab_body}")
      begin_block(lab_body)
      @loops.push([lab_cont, lab_end])
      stmts(body_f.drop(1))
      jump(lab_cont)
      begin_block(lab_cont)
      stmts(step_f.drop(1))
      jump(head)
      @loops.pop
      begin_block(lab_end)
    when "break"
      raise Refused, "break outside a loop (switch is not lowered yet)" if @loops.empty?
      terminate("OpBranch #{@loops[-1][1]}")
    when "continue"
      raise BadIR, "continue outside a loop" if @loops.empty?
      terminate("OpBranch #{@loops[-1][0]}")
    when "trap"
      raise Refused, "trap (a kernel has no abort: OpKill is for fragment shaders)"
    when "return"
      raise Refused, "return with a value in kernel #{@name}" if s.length > 1
      terminate("OpReturn")
    when "eval"
      # an expression statement: only a device intrinsic, whose value is discarded
      raise Refused, "eval of #{form_text(s[1])}" unless s.length == 2 && head_of(s[1]) == "call"
      value(s[1])
    else
      raise Refused, "statement #{h || form_text(s)}"
    end
  end

  # ---- the function text

  def compile
    setup
    @mutable = {}
    collect_sets(@body, []).each { |n| @mutable[n] = true }
    @fty = @mod.function_type_id(VOID, @params)
    @param_lines = []
    @params.each_with_index do |ty, k|
      pid = @mod.fresh("P")
      @regs["%#{k}"] = [pid, ty, false]
      @param_lines << "#{pid} = OpFunctionParameter #{@mod.type_id(ty)}"
    end
    @lines << "#{new_label} = OpLabel"
    @term = false
    stmts(@body)
    jump_return
  end

  def jump_return
    terminate("OpReturn") unless @term
  end

  # The lines of the function: the header, the parameters, the entry label, its variables, then the body.
  def text
    out = ["#{@id} = OpFunction #{@mod.type_id(VOID)} None #{@fty}"]
    out.concat(@param_lines.map { |l| "  #{l}" })
    out << @lines[0]
    out.concat(@vars)
    out.concat(@lines[1..-1])
    out << "OpFunctionEnd"
    out.join("\n") + "\n"
  end
end

# Whole-line comments (a line whose first non-blank character is ';') are dropped before the IR is read; the IR itself
# has no comments (docs/notes/pathb-stage2.md).
def strip_comments(src)
  keep = []
  src.split("\n").each do |line|
    keep << line unless line.lstrip.start_with?(";")
  end
  keep.join("\n")
end

def emit_module(src)
  forms = parse_forms(tokenize(strip_comments(src)))
  mod = SpvModule.new
  fns = []
  forms.each do |f|
    h = head_of(f)
    if h == "ir-module"
      next
    elsif h == "function"
      fns << SpvFn.new(mod, f)
    elsif h == "global"
      raise Refused, "global #{form_text(f[1])} (static data is not lowered yet)"
    else
      raise Refused, "top-level form #{h || form_text(f)}"
    end
  end
  raise BadIR, "no function in the IR" if fns.empty?
  by_name = {}
  fns.each { |fn| by_name[fn.name] = fn }
  fns.each do |fn|
    callee = collect_calls(fn.form, []).find { |c| by_name.key?(c) }
    raise Refused, "call of #{callee} (calls between functions are not lowered yet)" if callee
  end
  fns.each { |fn| fn.compile }
  out = "; Generated by scripts/pathb-spirv-kernel-emit.rb from the Path B IR; do not edit.\n"
  mod.caps.each { |c| out << "OpCapability #{c}\n" }
  out << "OpMemoryModel Physical64 OpenCL\n"
  iface = mod.iface.map { |v| " #{v}" }.join("")
  fns.each { |fn| out << "OpEntryPoint Kernel #{fn.id} \"#{fn.name}\"#{iface}\n" }
  mod.decor.each { |d| out << "#{d}\n" }
  mod.decls.each { |d| out << "#{d}\n" }
  out << "\n"
  fns.each { |fn| out << fn.text << "\n" }
  out
end

def read_input(path)
  File.open(path, "rb") { |f| f.read }
end

def main(argv)
  args = argv.dup
  if args.length > 1 || (args.length == 1 && args[0].start_with?("--"))
    $stderr.write("usage: pathb-spirv-kernel-emit.rb [FILE.ir | -] > out.spvasm\n")
    return 1
  end
  src = (args.empty? || args[0] == "-") ? $stdin.read : read_input(args[0])
  begin
    text = emit_module(src)
  rescue Refused => e
    $stderr.write("refused: #{e.message}\n")
    return 3
  rescue BadIR => e
    $stderr.write("error: #{e.message}\n")
    return 1
  end
  $stdout.write(text)
  0
end

rc = main(ARGV)
exit(rc) if rc != 0
