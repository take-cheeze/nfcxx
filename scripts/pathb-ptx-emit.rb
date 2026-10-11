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
# Model. Each IR function is a kernel (.visible .entry); a function that returns a value is refused. A parameter of
# pointer or of 4- or 8-byte integer type is a .param; the body copies it into its slot, as the IR says. A slot is a
# frame in .local memory (__local_depot<N>), addressed through its generic address (cvta.local). A register is a PTX
# register of its class: .pred for bool, .b32 for 4-byte integers (%r), .b64 for 8-byte integers and pointers (%rd).
# Registers are numbered per class in the order they are first set. Labels are $L<N>; `if` is a predicated branch
# over the then part, and the else part follows.
#
# Handled: block, set, let, store, if, return; the expressions load, index, wadd, wsub, wmul, the comparisons lt, le,
# gt, ge, eq, ne, const, and gpu (the special registers tid, ctaid, ntid, nctaid, .x .y .z, a Path B form for the
# GPU). Operands: registers, constants, slot addresses, null. Everything else is refused: the next steps are the
# remaining operators, 1- and 2-byte integers, bool in memory, floats, aggregates, switch, goto, static data, calls.
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
  return t[1] if t[0] == "int"
  raise Refused, "size of #{t[0]}"
end

# The PTX register class of an IR type: "p" for bool, "r" (.b32) for 4-byte integers, "rd" (.b64) for 8-byte integers
# and pointers.
def reg_class(t)
  return "p" if t[0] == "int" && t[3]
  return "rd" if t[0] == "ptr" || (t[0] == "int" && t[1] == 8)
  return "r" if t[0] == "int" && t[1] == 4
  raise Refused, "value of type #{t[0]} #{t[1]} bytes"
end

# The PTX type suffix for a value or a memory access of an IR type: s32, u32, s64, u64 (a pointer is u64).
def ptx_type(t)
  return "u64" if t[0] == "ptr"
  raise Refused, "bool in arithmetic or memory" if t[0] == "int" && t[3]
  raise Refused, "integer of #{t[1]} bytes" unless t[0] == "int" && (t[1] == 4 || t[1] == 8)
  (t[2] ? "s" : "u") + (t[1] * 8).to_s
end

# A constant as a PTX immediate of an IR integer or pointer type (the bits of v, read with the signedness of t).
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
def special_register?(name)
  parts = name.split(".")
  parts.length == 2 && ["tid", "ctaid", "ntid", "nctaid"].include?(parts[0]) && ["x", "y", "z"].include?(parts[1])
end

# ------------------------------------------------------------------ functions

class Fn
  def initialize(form, index)
    @form = form
    @index = index
    @name = form[1].to_s
    @regs = {}              # IR register "%N" => [PTX register, IR type]
    @count = { "p" => 0, "r" => 0, "rd" => 0 }
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

  # ---- the header: return type, parameters, slots

  def setup
    @body = []
    ret = nil
    @form.each_with_index do |f, i|
      next if i < 2
      h = head_of(f)
      if h == "ret"
        ret = parse_type(f[1])
        raise Refused, "function #{@name} returns a value (only void kernels are emitted)" unless ret[0] == "void"
      elsif h == "params"
        f.drop(1).each_with_index do |p, k|
          raise Refused, "variadic function" if head_of(p) == "ellipsis"
          raise Refused, "parameter form #{form_text(p)}" unless head_of(p) == "param" && p.length == 4
          raise BadIR, "parameter register must be %#{k}" unless p[1] == "%#{k}"
          ty = parse_type(p[3])
          raise Refused, "parameter of type #{ty[0]}" unless ty[0] == "ptr" || (ty[0] == "int" && !ty[3] && (ty[1] == 4 || ty[1] == 8))
          @params << ty
        end
      elsif h == "static"
        nil
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
      return [imm(ty, as_int(x[2])), ty]
    end
    if h == "null"
      return ["0", parse_type(x[1])]
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
    raise BadIR, "value of type #{ty[0]} stored in a #{dty[0]}" unless reg_class(dty) == reg_class(ty)
  end

  # ---- expressions: store the value of x in register dest, of IR type dty

  def rval(x, dest, dty)
    h = head_of(x)
    case h
    when "load"
      ty = parse_type(x[1])
      expect(dty, ty)
      addr, aty = operand(x[2])
      emit("ld.#{ptx_type(ty)} #{dest}, [#{reg_of(addr, aty)}];")
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
    when "lt", "le", "gt", "ge", "eq", "ne"
      ty = parse_type(x[1])
      raise BadIR, "comparison result is not bool" unless reg_class(dty) == "p"
      a, aty = operand(x[2])
      b, _ = operand(x[3])
      emit("setp.#{h}.#{ptx_type(ty)} #{dest}, #{reg_of(a, aty)}, #{b};")
    when "gpu"
      ty = parse_type(x[1])
      expect(dty, ty)
      name = x[2].to_s
      raise Refused, "special register #{name}" unless special_register?(name)
      emit("mov.u32 #{dest}, %#{name};")
    when "const"
      ty = parse_type(x[1])
      expect(dty, ty)
      text, _ = operand(x)
      emit("mov.#{ptx_type(ty)} #{dest}, #{text};")
    else
      raise Refused, "expression #{h || form_text(x)}"
    end
  end

  # ---- statements

  def stmt(s)
    h = head_of(s)
    case h
    when "block"
      s.drop(1).each { |t| stmt(t) }
    when "let"
      ty = parse_type(s[2])
      dest = ir_reg(s[1], ty)
      rval(s[3], dest, ty)
    when "set"
      r = @regs[s[1]]
      raise BadIR, "set of #{s[1]} before its let" if r.nil?
      raise Refused, "set of a bool register" if reg_class(r[1]) == "p"
      text, ty = operand(s[2])
      expect(r[1], ty)
      emit("mov.#{ptx_type(r[1])} #{r[0]}, #{text};")
    when "store"
      ty = parse_type(s[1])
      addr, aty = operand(s[2])
      val, _ = operand(s[3])
      emit("st.#{ptx_type(ty)} [#{reg_of(addr, aty)}], #{reg_of(val, ty)};")
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
    when "return"
      raise Refused, "return with a value" if s.length > 1
      emit("ret;")
    else
      raise Refused, "statement #{h || form_text(s)}"
    end
  end

  # ---- the function text

  def compile
    setup
    if @frame > 0
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
    out << ".visible .entry #{@name}("
    @params.each_with_index do |ty, k|
      comma = k + 1 < @params.length ? "," : ""
      out << "  .param .#{ptx_type(ty)} #{@name}_param_#{k}#{comma}"
    end
    out << ")"
    out << "{"
    out << "  .reg .pred %p<#{@count['p']}>;" if @count["p"] > 0
    out << "  .reg .b32 %r<#{@count['r']}>;" if @count["r"] > 0
    out << "  .reg .b64 %rd<#{@count['rd']}>;" if @count["rd"] > 0
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

def emit_module(src, sm)
  forms = parse_forms(tokenize(strip_comments(src)))
  fns = []
  forms.each do |f|
    h = head_of(f)
    if h == "ir-module"
      next
    elsif h == "function"
      fns << Fn.new(f, fns.length)
    elsif h == "global"
      raise Refused, "global #{form_text(f[1])} (static data is not lowered yet)"
    else
      raise Refused, "top-level form #{h || form_text(f)}"
    end
  end
  raise BadIR, "no function in the IR" if fns.empty?
  fns.each { |fn| fn.compile }
  out = "// Generated by scripts/pathb-ptx-emit.rb from the Path B IR; do not edit.\n"
  out << ".version 8.0\n.target #{sm}\n.address_size 64\n\n"
  fns.each { |fn| out << fn.text << "\n" }
  out
end

def read_input(path)
  File.open(path, "rb") { |f| f.read }
end

def main(argv)
  args = argv.dup
  sm = "sm_75"
  if args.length > 0 && args[0].start_with?("--sm=")
    sm = "sm_" + args.shift[5..-1]
  end
  if args.length > 1
    $stderr.write("usage: pathb-ptx-emit.rb [--sm=75] [FILE.ir | -] > out.ptx\n")
    return 1
  end
  src = (args.empty? || args[0] == "-") ? $stdin.read : read_input(args[0])
  begin
    ptx = emit_module(src, sm)
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
