#!/usr/bin/env ruby
# llvm-to-pathb.rb: translate LLVM IR text (.ll, as `clang -S -emit-llvm` writes it) to the nfcxx IR text form
# (docs/notes/pathb-stage2.md, section 6). scripts/pathb-qbe-emit.rb then turns that into QBE IL.
# The subset, the mapping and the decisions are in docs/notes/pathb-llvm.md.
#
# Usage: scripts/mrb scripts/llvm-to-pathb.rb FILE.ll > FILE.ir
#
# Exit status:
#   0  translated; the IR is on stdout
#   3  refused: a construct outside the subset (reason on stderr); nothing is printed
#   1  malformed input
#
# Policy: `nsw` add, sub and mul become checked IR operations (cadd, csub, cmul), which trap on overflow where LLVM
# says poison. The other wrapping flags are dropped: wrapping is a valid refinement of poison. Shifts are always
# checked (cshl, cshr), because a shift count out of range is poison. `undef` reads as zero. `inbounds` is not
# checked: the IR has no length for a pointer.
#
# Written in the subset of Ruby that the mruby interpreter (scripts/mrb) runs: string scanning by index, no keyword
# arguments, no regular expressions.

def refuse(why)
  $stderr.puts "refused: #{why}"
  exit 3
end

def malformed(why)
  $stderr.puts "error: #{why}"
  exit 1
end

# LLVM scalar type -> [IR type, size in bytes]. The IR's integer types are signed; unsigned forms are chosen per
# instruction (lt.u, unsigned shifts), never from the declared type of a register.
SCALARS = {
  "i1" => ["bool", 1], "i8" => ["char", 1], "i16" => ["short", 2], "i32" => ["int", 4], "i64" => ["long", 8],
  "ptr" => ["(ptr void)", 8], "float" => ["float", 4], "double" => ["double", 8], "void" => ["void", 0]
}
INT_TYPES = %w[char short int long]
FLOAT_TYPES = %w[float double]
# Words that may precede an instruction's operands and carry no meaning for the translation.
FLAGS = %w[nsw nuw exact nnan ninf nsz arcp contract afn reassoc fast inbounds nusw nneg disjoint samesign
           tail musttail notail]

# LLVM type text -> [IR type text, size, element type text (arrays only)]
def ll_type(text)
  s = text.strip
  return SCALARS[s] + [nil] if SCALARS.key?(s)
  if s.start_with?("[") && s.end_with?("]")
    inner = s[1, s.size - 2].strip
    x = inner.index(" x ")
    malformed("array type #{s}") if x.nil?
    n = inner[0, x].to_i
    elem = inner[x + 3, inner.size - x - 3].strip
    et = ll_type(elem)
    return ["(array #{n} #{et[0]})", n * et[1], elem]
  end
  refuse("type #{s}")
end

def ir_type(text)
  ll_type(text)[0]
end

def unsigned_of(ir)
  refuse("unsigned operation on #{ir}") unless INT_TYPES.include?(ir)
  "unsigned_#{ir}"
end

def digits?(s)
  return false if s.empty?
  i = s[0] == "-" ? 1 : 0
  return false if i == s.size
  while i < s.size
    return false unless "0123456789".include?(s[i])
    i += 1
  end
  true
end

# Splits at commas outside parentheses, brackets, braces and quotes.
def split_top(s)
  out = []
  depth = 0
  inq = false
  cur = ""
  i = 0
  while i < s.size
    c = s[i]
    if inq
      inq = false if c == '"'
    elsif c == '"'
      inq = true
    elsif c == "(" || c == "[" || c == "{"
      depth += 1
    elsif c == ")" || c == "]" || c == "}"
      depth -= 1
    elsif c == "," && depth == 0
      out << cur.strip
      cur = ""
      i += 1
      next
    end
    cur << c
    i += 1
  end
  out << cur.strip unless cur.strip.empty?
  out
end

# Index of the parenthesis or bracket that closes the one at `open`.
def close_of(s, open)
  depth = 0
  i = open
  while i < s.size
    depth += 1 if s[i] == "(" || s[i] == "["
    depth -= 1 if s[i] == ")" || s[i] == "]"
    return i if depth == 0
    i += 1
  end
  malformed("unbalanced brackets in #{s}")
end

# Drops a `;` comment outside quotes.
def strip_comment(line)
  inq = false
  i = 0
  while i < line.size
    c = line[i]
    inq = !inq if c == '"'
    return line[0, i].strip if c == ";" && !inq
    i += 1
  end
  line.strip
end

def count_char(s, ch)
  n = 0
  i = 0
  while i < s.size
    n += 1 if s[i] == ch
    i += 1
  end
  n
end

def first_word(s)
  s.strip.split(" ")[0].to_s
end

def last_word(s)
  w = s.strip.split(" ")
  w[w.size - 1].to_s
end

def global_name(token)
  name = token[1, token.size - 1]
  name = name[1, name.size - 2] if name.start_with?('"')
  # LLVM's private names such as .str are not QBE identifiers; the rename applies to every spelling of the name.
  name.start_with?(".") ? "llvm#{name}" : name
end

# Name of the function defined or declared on a `define` or `declare` line.
def function_name(line)
  at = line.index("@")
  global_name(line[at, line.index("(", at) - at])
end

# A float constant. LLVM writes a float or double constant that is not a short decimal as its 64-bit pattern
# (0x...); a float constant is the double it widens to, so the pattern is always a double's.
def hex_float(text)
  bits = text[2, text.size - 2].to_i(16)
  neg = (bits >> 63) == 1
  e = (bits >> 52) & 0x7ff
  m = bits & 0xfffffffffffff
  refuse("non-finite float constant #{text}") if e == 0x7ff
  v = if e == 0
        m.to_f * (2.0 ** -1074)
      else
        (1.0 + m.to_f / 4503599627370496.0) * (2.0 ** (e - 1023))
      end
  neg ? -v : v
end

# Decimal text that reads back as the same double.
def float_text(v)
  "%.17g" % v
end

class Translator
  def initialize(path)
    @path = path
    @file = path
    @funcs = {}       # functions defined or declared in the module: direct callees are &"f"
    @out_globals = []
    @out_data = []
    @out_funcs = []
  end

  def run
    lines = File.read(@path).split("\n")
    lines.each do |raw|
      line = raw.strip
      @funcs[function_name(line)] = true if line.start_with?("define ") || line.start_with?("declare ")
    end
    i = 0
    while i < lines.size
      line = strip_comment(lines[i])
      i += 1
      next if line.empty?
      if line.start_with?("source_filename")
        @file = line.split('"')[1].to_s
      elsif line.start_with?("target triple")
        refuse("target #{line}") unless line.include?("64")
      elsif line.start_with?("target datalayout") || line.start_with?("!") || line.start_with?("attributes") ||
            line.start_with?("declare ") || line.start_with?("%")
        next
      elsif line.start_with?("module asm")
        refuse("module asm")
      elsif line.start_with?("@")
        global_line(line)
      elsif line.start_with?("define ")
        body = []
        while i < lines.size && strip_comment(lines[i]) != "}"
          body << lines[i]
          i += 1
        end
        malformed("function #{line} is not closed") if i >= lines.size
        i += 1
        @out_funcs << function(line, body)
      else
        refuse("top level: #{line}")
      end
    end
    puts "(ir-module \"#{@file}\" (layout (short 2) (int 4) (long 8) (long_long 8) (pointer 8) (float 4) (double 8) (long_double 16)))"
    @out_globals.each { |g| puts g }
    @out_data.each { |d| puts d }
    @out_funcs.each { |f| puts f }
  end

  # ---- globals -------------------------------------------------------------------------------------------

  def global_line(line)
    name, rest = line.split(" = ", 2)
    name = global_name(name.strip)
    refuse("global #{name} with metadata") if rest.include?(", !")
    return string_global(name, rest) if rest.include?(' c"')
    words = rest.split(" ")
    kw = words.index("global")
    kw = words.index("constant") if kw.nil?
    refuse("global #{name}: #{rest}") if kw.nil?
    linkage = words[0, kw]
    refuse("global #{name}: linkage #{linkage.join(' ')}") if (linkage & %w[common appending extern_weak thread_local]).any?
    type_text, after = split_type(words[kw + 1, words.size - kw - 1].join(" "))
    tail = split_top(after)
    ty = ll_type(type_text)
    init = tail[0]
    init = nil if init && init.start_with?("align")
    align_text = (tail + [""]).find { |t| t.start_with?("align ") }
    align = align_text ? align_text.split(" ")[1].to_i : (ty[1] > 0 ? ty[1] : 1)
    if init.nil?
      refuse("global #{name} has no initializer and no external linkage") unless linkage.include?("external")
      @out_globals << "(global \"#{name}\" #{ty[0]} #{ty[1]} #{align} (extern))"
      return
    end
    kind = linkage_marker(linkage)
    items = initializer(init, type_text)
    @out_globals << "(global \"#{name}\" #{ty[0]} #{ty[1]} #{align}#{kind ? ' ' + kind : ''} (init #{items}))"
  end

  def linkage_marker(linkage)
    return "(static)" if linkage.include?("internal") || linkage.include?("private")
    return "(weak)" if linkage.include?("linkonce_odr") || linkage.include?("weak_odr")
    return "(weak attr)" if linkage.include?("weak")
    nil
  end

  # The items of an initializer: a scalar, zero, or arrays (nested to any depth) of scalars, each at its byte offset.
  def initializer(init, ll)
    items = []
    init_items(init, ll, 0, items)
    items.join(" ")
  end

  def init_items(init, ll, off, items)
    ty = ll_type(ll)
    if init == "zeroinitializer"
      items << "(zero #{off} #{ty[1]})"
    elsif init.start_with?("[")
      refuse("array initializer of #{ll}") if ty[2].nil?
      et = ll_type(ty[2])
      split_top(init[1, init.size - 2]).each_with_index do |e, k|
        el, ev = split_type(e)
        refuse("element #{e} of #{ll}") unless el == ty[2]
        init_items(ev, el, off + k * et[1], items)
      end
    elsif init.start_with?("{") || init.start_with?("<")
      refuse("initializer #{init}")
    elsif init.start_with?("getelementptr")
      target, addend = constant_gep_parts(init)
      items << "(addr #{off} (ptr void) #{target} #{addend})"
    elsif init.start_with?("@")
      items << "(addr #{off} (ptr void) #{operand(init, 'ptr')} 0)"
    else
      refuse("initializer #{init} of #{ll}") if ty[2]
      items << "(scalar #{off} #{ty[0]} #{constant(init, ll)})"
    end
  end

  # `TYPE rest`: the type is a word, or a bracketed array type. Returns [type, rest].
  def split_type(text)
    s = text.strip
    if s.start_with?("[")
      close = close_of(s, 0)
      return [s[0, close + 1], s[close + 1, s.size - close - 1].to_s.strip]
    end
    raw = first_word(s)
    word = raw.end_with?(",") ? raw[0, raw.size - 1] : raw
    rest = s[raw.size..-1].to_s.strip
    rest = rest[1, rest.size - 1].strip if rest.start_with?(",")
    [word, rest]
  end

  # `@.str = private unnamed_addr constant [6 x i8] c"hello\0A\00"`: a data node, referenced as @".str".
  def string_global(name, rest)
    k = rest.index(' c"')
    head = rest[0, k].split(" ")
    refuse("string global #{name} is not constant") unless head.include?("constant")
    ty = ll_type(rest[0, k].split("constant")[1].strip)
    refuse("string global #{name} of #{ty[2]}") unless ty[2] == "i8"
    close = rest.index('"', k + 3)
    body = rest[k + 3, close - k - 3]
    @out_data << "(data \"#{name}\" (const (array #{ty[1]} (const char))) (string \"#{escape_bytes(body)}\"))"
  end

  # LLVM writes each byte that is not printable as \HH; the IR string takes C-style octal escapes.
  def escape_bytes(body)
    out = ""
    i = 0
    while i < body.size
      if body[i] == "\\"
        o = body[i + 1, 2].to_i(16).to_s(8)
        o = "0" + o while o.size < 3
        out << "\\" + o
        i += 3
      else
        out << body[i]
        i += 1
      end
    end
    out
  end

  # ---- functions -----------------------------------------------------------------------------------------

  def function(header, body)
    @regs = {}
    @next = 0
    hdr = header.strip
    hdr = hdr[0, hdr.size - 1].strip if hdr.end_with?("{")
    at = hdr.index("@")
    lp = hdr.index("(", at)
    name = global_name(hdr[at, lp - at])
    pre = hdr[0, at].strip.split(" ")[1..-1]
    ret = ir_type(pre.last)
    kind = function_kind(name, pre[0, pre.size - 1])
    rp = close_of(hdr, lp)
    attrs = hdr[rp + 1, hdr.size - rp - 1].strip.split(" ")
    refuse("function #{name}: #{attrs.join(' ')}") if attrs.any? { |a| a.start_with?("gc") || a.start_with?("section") }

    params = []
    split_top(hdr[lp + 1, rp - lp - 1]).each do |p|
      if p == "..."
        params << "(ellipsis)"
        next
      end
      words = p.split(" ")
      refuse("parameter #{p} of #{name}") if words.any? { |w| %w[byval sret byref inalloca].include?(w) }
      plain = words.last.start_with?("%") ? words.last[1, words.last.size - 1] : words.last
      label = plain.to_i.to_s == plain ? "p#{plain}" : plain
      params << "(param %#{reg(words.last)} \"#{label}\" #{ir_type(words[0])})"
    end

    blocks = blocks_of(body)
    @block_index = {}
    blocks.each_with_index { |b, i| @block_index[b[:name].to_s] = i }
    @entry_unnamed = blocks[0][:name].nil?
    @phis = {}
    @prelude = []
    blocks.each_with_index do |b, bi|
      b[:insts].each do |ins|
        next unless ins.include?(" = phi ")
        dst, rest = ins.split(" = phi ", 2)
        ll = rest.split(" ")[0]
        ty = ll_type(ll)
        incomings = []
        split_top(rest[ll.size..-1].strip).each do |entry|
          value, pred = split_top(entry.strip[1, entry.strip.size - 2])
          incomings << [value, pred[1, pred.size - 1]]
        end
        d = reg(dst.strip)
        (@phis[bi] ||= []) << {dst: d, ll: ll, ty: ty, incomings: incomings}
        @prelude << "(let %#{d} #{ty[0]} #{zero_of(ty)})"
      end
    end

    body_out = []
    blocks.each_with_index do |b, bi|
      body_out << "(label \"#{block_label(bi)}\")"
      b[:insts].each do |ins|
        next if ins.include?(" = phi ")
        body_out.concat(instruction(bi, ins))
      end
    end

    lines = ["(function \"#{name}\"", "  (ret #{ret})", "  (params #{params.join(' ')})"]
    lines << "  #{kind}" if kind
    (@prelude + body_out).each { |s| lines << "  #{s}" }
    lines.join("\n") + ")"
  end

  def function_kind(name, linkage)
    # Return-value attributes (noundef, zeroext, ...) do not change what the function does.
    ignored = %w[dso_local hidden protected unnamed_addr local_unnamed_addr external default noundef zeroext signext nonnull noalias]
    unknown = linkage.reject { |w| ignored.include?(w) || %w[internal private linkonce_odr weak_odr weak].include?(w) }
    refuse("function #{name}: linkage #{unknown.join(' ')}") if unknown.any?
    linkage_marker(linkage)
  end

  # Blocks as [{name:, insts:}]. A block starts at a label line; the entry block may have none.
  def blocks_of(body)
    blocks = []
    i = 0
    while i < body.size
      line = strip_comment(body[i])
      i += 1
      next if line.empty?
      # Debug and loop metadata (`, !llvm.loop !6`) does not change what the instruction does.
      meta = line.index(", !")
      line = line[0, meta].strip unless meta.nil?
      # A switch's case table spans lines; join them. Entries are separated by commas, as in the one-line form.
      while count_char(line, "[") > count_char(line, "]") && i < body.size
        extra = strip_comment(body[i])
        i += 1
        line = line + (line.end_with?("[") ? " " : ", ") + extra
      end
      if line.end_with?(":") && line.index(" ").nil?
        blocks << {name: line[0, line.size - 1], insts: []}
        next
      end
      blocks << {name: nil, insts: []} if blocks.empty?
      blocks.last[:insts] << line
    end
    refuse("function without blocks") if blocks.empty?
    blocks
  end

  def block_label(bi)
    "b#{bi}"
  end

  # The index of a block named by a label operand (`%7`). An unnamed entry block is also reached by its number.
  def block_of(name)
    key = name.start_with?("%") ? name[1, name.size - 1] : name
    return @block_index[key] if @block_index.key?(key)
    return 0 if @entry_unnamed && digits?(key)
    malformed("unknown label #{name}")
  end

  # ---- registers and operands ----------------------------------------------------------------------------

  def reg(name)
    @regs[name] ||= (@next += 1)
  end

  def temp
    @next += 1
    "%#{@next}"
  end

  def zero_of(ty)
    if ty[0] == "(ptr void)"
      "(null (ptr void))"
    elsif ty[0] == "bool"
      "(const bool 0x0)"
    elsif FLOAT_TYPES.include?(ty[0])
      "(const #{ty[0]} 0.0)"
    elsif INT_TYPES.include?(ty[0])
      "(const #{ty[0]} 0)"
    else
      refuse("zero value of #{ty[0]}")
    end
  end

  # A constant of LLVM type `ll`.
  def constant(text, ll)
    t = text.strip
    ty = ll_type(ll)
    irt = ty[0]
    if t == "undef" || t == "poison"
      zero_of(ty)
    elsif t == "null"
      refuse("null of #{ll}") unless irt == "(ptr void)"
      "(null (ptr void))"
    elsif t == "true" || t == "false"
      refuse("#{t} of #{ll}") unless ll == "i1"
      t == "true" ? "(const bool 0x1)" : "(const bool 0x0)"
    elsif FLOAT_TYPES.include?(irt) && t.start_with?("0x")
      "(const #{irt} #{float_text(hex_float(t))})"
    elsif FLOAT_TYPES.include?(irt) && (t.include?(".") || t.include?("e") || t.include?("E"))
      "(const #{irt} #{float_text(t.to_f)})"
    elsif INT_TYPES.include?(irt) && digits?(t)
      "(const #{irt} #{t})"
    else
      refuse("constant #{t} of #{ll}")
    end
  end

  # An operand of LLVM type `ll`: a register, a global, a constant, or a constant getelementptr.
  def operand(text, ll)
    t = text.strip
    if t.start_with?("%")
      "%#{reg(t)}"
    elsif t.start_with?("@")
      name = global_name(t)
      @funcs.key?(name) ? "&\"#{name}\"" : "@\"#{name}\""
    elsif t.start_with?("getelementptr")
      constant_gep(t)
    else
      constant(t, ll)
    end
  end

  # `getelementptr [inbounds] (T, ptr @g, i64 C0, ...)` as a constant: the global plus a constant byte offset. A
  # non-zero offset needs a register, so its statement goes to @pending, ahead of the instruction that uses it.
  def constant_gep(text)
    target, offset = constant_gep_parts(text)
    return target if offset == 0
    t = temp
    @pending << "(let #{t} (ptr void) (offset #{target} #{offset}))"
    t
  end

  # [target operand, byte offset] of a constant getelementptr.
  def constant_gep_parts(text)
    inner_start = text.index("(")
    inner = text[inner_start + 1, close_of(text, inner_start) - inner_start - 1]
    parts = split_top(inner)
    refuse("constant getelementptr #{text}") if parts.size < 3
    base_ll, base = typed(parts[1])
    refuse("constant getelementptr of #{base}") unless base.start_with?("@")
    cur_ll = parts[0]
    stride = ll_type(cur_ll)[1]
    offset = 0
    parts[2, parts.size - 2].each_with_index do |idx, k|
      if k > 0
        cur_ll = ll_type(cur_ll)[2]
        refuse("constant getelementptr into #{cur_ll}") if cur_ll.nil?
        stride = ll_type(cur_ll)[1]
      end
      il, iv = typed(idx)
      refuse("constant getelementptr index #{iv}") unless digits?(iv) && INT_TYPES.include?(ir_type(il))
      offset += iv.to_i * stride
    end
    [operand(base, base_ll), offset]
  end

  # `TYPE VALUE` as [LLVM type, value text]. Attributes between them are skipped; a constant getelementptr keeps
  # its whole text.
  def typed(text)
    s = text.strip
    word = first_word(s)
    rest = s[word.size..-1].strip
    return [word, rest] if rest.start_with?("getelementptr")
    [word, last_word(s)]
  end

  # ---- instructions --------------------------------------------------------------------------------------

  # The statements of one instruction. A constant operand that needs a register adds its statement in front.
  def instruction(bi, ins)
    @pending = []
    body = instruction_body(bi, ins)
    @pending + body
  end

  def instruction_body(bi, ins)
    dst = nil
    if ins.start_with?("%") && ins.include?(" = ")
      dst, ins = ins.split(" = ", 2)
      dst = dst.strip
    end
    # Flags come before the opcode (`tail call`) and after it (`add nsw`).
    flags = []
    rest = ins.strip
    while FLAGS.include?(first_word(rest)) || first_word(rest) == "volatile"
      flags << first_word(rest)
      rest = rest[first_word(rest).size..-1].strip
    end
    op = first_word(rest)
    rest = rest[op.size..-1].to_s.strip
    while FLAGS.include?(first_word(rest)) || first_word(rest) == "volatile"
      flags << first_word(rest)
      rest = rest[first_word(rest).size..-1].strip
    end
    d = dst ? reg(dst) : nil

    case op
    when "alloca" then alloca(bi, d, rest)
    when "load" then load(d, rest, flags.include?("volatile"))
    when "store" then store(rest, flags.include?("volatile"))
    when "add", "sub", "mul", "sdiv", "srem", "shl", "lshr", "ashr", "and", "or", "xor"
      binary(d, op, rest, flags)
    when "fadd", "fsub", "fmul", "fdiv" then fbinary(d, op, rest)
    when "fneg" then fneg(d, rest)
    when "icmp" then icmp(d, rest)
    when "fcmp" then fcmp(d, rest)
    when "sext", "zext", "trunc", "sitofp", "fptosi", "fpext", "fptrunc", "ptrtoint", "inttoptr", "bitcast"
      conversion(d, op, rest)
    when "getelementptr" then gep(d, rest)
    when "call" then call(d, rest)
    when "select" then select(d, rest)
    when "br" then branch(bi, rest)
    when "switch" then switch(bi, rest)
    when "ret" then ret(rest)
    when "unreachable" then ["(unreachable)"]
    else refuse("instruction #{op}")
    end
  end

  def alloca(bi, d, rest)
    refuse("alloca outside the entry block") unless bi == 0
    parts = split_top(rest)
    refuse("variable-length alloca") if parts.size > 1 && !parts[1].start_with?("align")
    ty = ll_type(parts[0])
    refuse("alloca of void") if ty[1] == 0
    align = parts.find { |p| p.start_with?("align ") }
    refuse("alloca aligned to #{align}") if align && align.split(" ")[1].to_i > 16
    ["(let %#{d} (ptr void) (alloca (const int #{ty[1]})))"]
  end

  def load(d, rest, vol)
    parts = split_top(rest)
    ll = parts[0]
    ["(let %#{d} #{ir_type(ll)} (load#{vol ? '.v' : ''} #{ir_type(ll)} #{operand(typed(parts[1])[1], 'ptr')}))"]
  end

  def store(rest, vol)
    parts = split_top(rest)
    vl, vv = typed(parts[0])
    ["(store#{vol ? '.v' : ''} #{ir_type(vl)} #{operand(typed(parts[1])[1], 'ptr')} #{operand(vv, vl)})"]
  end

  # Integer operations. An nsw add, sub or mul is checked; the other wrapping forms wrap. Shifts are checked.
  def binary(d, op, rest, flags)
    parts = split_top(rest)
    tl, a = typed(parts[0])
    refuse("#{op} on i1") if tl == "i1" && !%w[and or xor].include?(op)
    ir = ir_type(tl)
    x = operand(a, tl)
    y = operand(parts[1], tl)
    nsw = flags.include?("nsw")
    text, optype = case op
                   when "add" then [nsw ? "cadd" : "wadd", ir]
                   when "sub" then [nsw ? "csub" : "wsub", ir]
                   when "mul" then [nsw ? "cmul" : "wmul", ir]
                   when "sdiv" then ["cdiv", ir]
                   when "srem" then ["crem", ir]
                   when "shl" then ["cshl", ir]
                   when "lshr" then ["cshr", unsigned_of(ir)]
                   when "ashr" then ["cshr", ir]
                   when "and", "or", "xor" then [op, ir]
                   else refuse("instruction #{op} (unsigned division)")
                   end
    ["(let %#{d} #{ir} (#{text} #{optype} #{x} #{y}))"]
  end

  def fbinary(d, op, rest)
    parts = split_top(rest)
    tl, a = typed(parts[0])
    ir = ir_type(tl)
    refuse("#{op} on #{tl}") unless FLOAT_TYPES.include?(ir)
    ["(let %#{d} #{ir} (#{op} #{ir} #{operand(a, tl)} #{operand(parts[1], tl)}))"]
  end

  def fneg(d, rest)
    tl, a = typed(split_top(rest)[0])
    ir = ir_type(tl)
    refuse("fneg on #{tl}") unless FLOAT_TYPES.include?(ir)
    ["(let %#{d} #{ir} (fneg #{ir} #{operand(a, tl)}))"]
  end

  def icmp(d, rest)
    pred = first_word(rest)
    parts = split_top(rest[pred.size..-1].strip)
    tl, a = typed(parts[0])
    ir = ir_type(tl)
    x = operand(a, tl)
    y = operand(parts[1], tl)
    text = case pred
           when "eq" then "(eq #{ir} #{x} #{y})"
           when "ne" then "(ne #{ir} #{x} #{y})"
           when "slt" then "(lt.s #{ir} #{x} #{y})"
           when "sle" then "(le.s #{ir} #{x} #{y})"
           when "sgt" then "(lt.s #{ir} #{y} #{x})"
           when "sge" then "(le.s #{ir} #{y} #{x})"
           when "ult" then "(lt.u #{unsigned_ir(ir)} #{x} #{y})"
           when "ule" then "(le.u #{unsigned_ir(ir)} #{x} #{y})"
           when "ugt" then "(lt.u #{unsigned_ir(ir)} #{y} #{x})"
           when "uge" then "(le.u #{unsigned_ir(ir)} #{y} #{x})"
           else refuse("icmp #{pred}")
           end
    ["(let %#{d} bool #{text})"]
  end

  # Pointers compare as unsigned longs.
  def unsigned_ir(ir)
    ir == "(ptr void)" ? "unsigned_long" : unsigned_of(ir)
  end

  # Ordered predicates, and `une` (C's `!=`, true on NaN). uno, ord, ueq and the other unordered forms are outside
  # the subset.
  def fcmp(d, rest)
    pred = first_word(rest)
    parts = split_top(rest[pred.size..-1].strip)
    tl, a = typed(parts[0])
    ir = ir_type(tl)
    refuse("fcmp on #{tl}") unless FLOAT_TYPES.include?(ir)
    x = operand(a, tl)
    y = operand(parts[1], tl)
    text = case pred
           when "oeq" then "(eq #{ir} #{x} #{y})"
           when "une" then "(ne #{ir} #{x} #{y})"
           when "olt" then "(lt.f #{ir} #{x} #{y})"
           when "ole" then "(le.f #{ir} #{x} #{y})"
           when "ogt" then "(lt.f #{ir} #{y} #{x})"
           when "oge" then "(le.f #{ir} #{y} #{x})"
           else refuse("fcmp #{pred}")
           end
    ["(let %#{d} bool #{text})"]
  end

  def conversion(d, op, rest)
    src, to = rest.split(" to ", 2)
    refuse("#{op} without a target type") if to.nil?
    sl, sv = typed(src)
    si = ir_type(sl)
    di = ir_type(to)
    x = operand(sv, sl)
    case op
    when "sext"
      refuse("sext from i1") if sl == "i1"
      ["(let %#{d} #{di} (iconv #{di} #{x}))"]
    when "zext"
      # The IR's integers are signed, so a zero extension is the sign extension masked to the source width.
      return ["(let %#{d} #{di} (iconv #{di} #{x}))"] if sl == "i1"
      mask = (1 << (ll_type(sl)[1] * 8)) - 1
      t = temp
      ["(let #{t} #{di} (iconv #{di} #{x}))", "(let %#{d} #{di} (and #{di} #{t} (const #{di} #{mask})))"]
    when "trunc"
      refuse("trunc to i1") if to == "i1"
      ["(let %#{d} #{di} (iconv #{di} #{x}))"]
    when "sitofp" then ["(let %#{d} #{di} (i2f #{di} #{x}))"]
    when "fptosi" then ["(let %#{d} #{di} (cf2i #{di} #{x}))"]
    when "fpext", "fptrunc" then ["(let %#{d} #{di} (fconv #{di} #{x}))"]
    when "ptrtoint" then ["(let %#{d} #{di} (p2i #{di} #{x}))"]
    when "inttoptr" then ["(let %#{d} #{di} (i2p #{di} #{x}))"]
    when "bitcast"
      refuse("bitcast #{sl} to #{to}") unless si == "(ptr void)" && di == "(ptr void)"
      ["(let %#{d} #{di} (bitcast #{di} #{x}))"]
    end
  end

  # One `(index BASE IDX SIZE)` per index. The first index strides by the source element type; each later index
  # walks into an array. Struct indices are outside the subset.
  def gep(d, rest)
    parts = split_top(rest)
    refuse("getelementptr without an index") if parts.size < 3
    cur = operand(typed(parts[1])[1], "ptr")
    cur_ll = parts[0]
    stride = ll_type(cur_ll)[1]
    out = []
    idxs = parts[2, parts.size - 2]
    idxs.each_with_index do |idx, k|
      if k > 0
        elem = ll_type(cur_ll)[2]
        refuse("getelementptr into #{cur_ll}") if elem.nil?
        cur_ll = elem
        stride = ll_type(cur_ll)[1]
      end
      il, iv = typed(idx)
      target = k == idxs.size - 1 ? "%#{d}" : temp
      out << "(let #{target} (ptr void) (index #{cur} #{operand(iv, il)} #{stride}))"
      cur = target
    end
    out
  end

  def call(d, rest)
    r = rest.strip
    while %w[noalias noundef nonnull zeroext signext].include?(first_word(r))
      r = r[first_word(r).size..-1].strip
    end
    ret_ll = first_word(r)
    r = r[ret_ll.size..-1].strip
    fixed_variadic = nil
    if r.start_with?("(")
      close = close_of(r, 0)
      fnty = r[1, close - 1]
      r = r[close + 1, r.size - close - 1].strip
      if fnty.include?("...")
        fixed = split_top(fnty).reject { |p| p == "..." }.size
        fixed_variadic = " (variadic #{fixed})"
      end
    end
    lp = r.index("(")
    callee = r[0, lp].strip
    return intrinsic(d, callee, r[lp + 1, close_of(r, lp) - lp - 1]) if callee.start_with?("@llvm.")
    target = if callee.start_with?("@")
               name = global_name(callee)
               refuse("call of #{name}, which the module does not declare") unless @funcs.key?(name)
               "&\"#{name}\""
             else
               operand(callee, "ptr")
             end
    args = split_top(r[lp + 1, close_of(r, lp) - lp - 1]).map do |a|
      refuse("argument #{a}") if a.split(" ").any? { |w| w.start_with?("byval") || w.start_with?("sret") }
      al, av = typed(a)
      operand(av, al)
    end
    ret = ir_type(ret_ll)
    head = ["call", ret, target]
    head << fixed_variadic.strip if fixed_variadic
    text = "(#{(head + args).join(' ')})"
    return ["(eval #{text})"] if ret == "void"
    ["(let %#{d} #{ret} #{text})"]
  end

  # The intrinsics in the subset:
  #   llvm.memcpy with a constant length: a copy statement; llvm.memset of zero: a zero-fill (both need the byte count
  #   as a constant); llvm.fmuladd: fmul then fadd, which LLVM allows (the fused form is optional); llvm.smax, smin,
  #   umax, umin: a compare and a conditional set.
  def intrinsic(d, callee, args_text)
    args = split_top(args_text).map { |a| typed(a) }
    if callee.start_with?("@llvm.memcpy.")
      refuse("memcpy of a non-constant length") unless digits?(args[2][1])
      return ["(copy #{args[2][1]} #{operand(args[0][1], args[0][0])} #{operand(args[1][1], args[1][0])})"]
    elsif callee.start_with?("@llvm.memset.")
      refuse("memset of a non-zero value") unless args[1][1] == "0"
      refuse("memset of a non-constant length") unless digits?(args[2][1])
      return ["(zero-fill #{args[2][1]} #{operand(args[0][1], args[0][0])})"]
    end
    kind = %w[smax smin umax umin].find { |k| callee.start_with?("@llvm.#{k}.") }
    refuse("call of the intrinsic #{callee}") if kind.nil? && !callee.start_with?("@llvm.fmuladd.")
    ir = ir_type(args[0][0])
    if callee.start_with?("@llvm.fmuladd.")
      refuse("fmuladd on #{ir}") unless FLOAT_TYPES.include?(ir)
      t = temp
      return ["(let #{t} #{ir} (fmul #{ir} #{operand(args[0][1], args[0][0])} #{operand(args[1][1], args[1][0])}))",
              "(let %#{d} #{ir} (fadd #{ir} #{t} #{operand(args[2][1], args[2][0])}))"]
    end
    x = operand(args[0][1], args[0][0])
    y = operand(args[1][1], args[1][0])
    cmp = kind.start_with?("s") ? "lt.s #{ir}" : "lt.u #{unsigned_ir(ir)}"
    # max: take y when x < y; min: take y when y < x.
    less = kind.end_with?("max") ? "(#{cmp} #{x} #{y})" : "(#{cmp} #{y} #{x})"
    c = temp
    ["(let %#{d} #{ir} #{x})", "(let #{c} bool #{less})", "(if #{c} (then (set %#{d} #{y})))"]
  end

  def select(d, rest)
    parts = split_top(rest)
    cl, cv = typed(parts[0])
    refuse("select on a condition of type #{cl}") unless cl == "i1"
    tl, av = typed(parts[1])
    _, bv = typed(parts[2])
    ir = ir_type(tl)
    @prelude << "(let %#{d} #{ir} #{zero_of(ll_type(tl))})"
    ["(if #{operand(cv, cl)} (then (set %#{d} #{operand(av, tl)})) (else (set %#{d} #{operand(bv, tl)})))"]
  end

  # The copies that the phi nodes of block `to` need when control comes from block `from`. Every source is read
  # before any destination is written, so a phi that reads another phi of the same block sees the old value.
  def phi_copies(from, to)
    pairs = []
    (@phis[to] || []).each do |p|
      p[:incomings].each { |v, pred| pairs << [p, v] if block_of(pred) == from }
    end
    return [] if pairs.empty?
    if pairs.size == 1
      p, v = pairs[0]
      return ["(set %#{p[:dst]} #{operand(v, p[:ll])})"]
    end
    lines = []
    temps = []
    pairs.each do |p, v|
      t = temp
      temps << t
      lines << "(let #{t} #{p[:ty][0]} #{operand(v, p[:ll])})"
    end
    pairs.each_with_index { |pair, i| lines << "(set %#{pair[0][:dst]} #{temps[i]})" }
    lines
  end

  def branch(bi, rest)
    if rest.start_with?("label ")
      to = block_of(rest.split(" ")[1])
      return phi_copies(bi, to) + ["(goto \"#{block_label(to)}\")"]
    end
    parts = split_top(rest)
    cl, cv = typed(parts[0])
    refuse("branch on #{cl}") unless cl == "i1"
    t = block_of(parts[1].split(" ")[1])
    f = block_of(parts[2].split(" ")[1])
    then_part = (phi_copies(bi, t) + ["(goto \"#{block_label(t)}\")"]).join(" ")
    else_part = (phi_copies(bi, f) + ["(goto \"#{block_label(f)}\")"]).join(" ")
    ["(if #{operand(cv, cl)} (then #{then_part}) (else #{else_part}))"]
  end

  # `switch TYPE V, label %default [ TYPE C, label %L ... ]` becomes a chain of compares, in table order.
  def switch(bi, rest)
    head, table = rest.split(" [", 2)
    table = table[0, table.rindex("]")]
    parts = split_top(head)
    vl, vv = typed(parts[0])
    refuse("switch on #{vl}") unless INT_TYPES.include?(ir_type(vl))
    ir = ir_type(vl)
    value = operand(vv, vl)
    entries = split_top(table)
    out = []
    i = 0
    while i + 1 < entries.size
      cl, cv = typed(entries[i])
      target = block_of(entries[i + 1].split(" ")[1])
      c = temp
      out << "(let #{c} bool (eq #{ir} #{value} #{operand(cv, cl)}))"
      out << "(if #{c} (then #{(phi_copies(bi, target) + ["(goto \"#{block_label(target)}\")"]).join(' ')}))"
      i += 2
    end
    default = block_of(parts[1].split(" ")[1])
    out + phi_copies(bi, default) + ["(goto \"#{block_label(default)}\")"]
  end

  def ret(rest)
    return ["(return)"] if rest.strip == "void"
    tl, v = typed(rest)
    ["(return #{operand(v, tl)})"]
  end
end

if ARGV.empty?
  $stderr.puts "usage: scripts/mrb scripts/llvm-to-pathb.rb FILE.ll > FILE.ir"
  exit 1
end
Translator.new(ARGV[0]).run
