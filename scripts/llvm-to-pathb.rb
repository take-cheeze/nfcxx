#!/usr/bin/env ruby
# llvm-to-pathb.rb: translate LLVM IR text (.ll, as `clang -S -emit-llvm` writes it) to the nfcxx IR text form
# (docs/notes/pathb-stage2.md, section 6). scripts/pathb-qbe-emit.rb then turns that into QBE IL.
# The subset, the mapping and the decisions are in docs/notes/pathb-llvm.md.
#
# Usage: scripts/mrb scripts/llvm-to-pathb.rb [--wasm] FILE.ll > FILE.ir
#
# --wasm: the IR is for a WebAssembly module (scripts/pathb-wasm-emit.rb), which runs on one thread and has no
# operating system. The atomic operations (load atomic, store atomic, cmpxchg, atomicrmw, fence) are plain loads and
# stores, and an x86-64 `syscall` instruction (inline assembly) is a call of the import __syscall(nr, a1 .. a6), which the
# host answers. Without it both are refused, since a native program may have threads and its own system calls. TinyGo's
# Linux runtime (the wasm explorer's Go) has both.
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
# Intrinsics that are hints, with no effect on the result (rustc writes them at -O1 and above).
NO_OP_INTRINSICS = %w[lifetime.start. lifetime.end. assume experimental.noalias.scope.decl dbg. stackrestore.]
FLOAT_TYPES = %w[float double]
# Words that may precede an instruction's operands and carry no meaning for the translation.
FLAGS = %w[nsw nuw exact nnan ninf nsz arcp contract afn reassoc fast inbounds nusw nneg disjoint samesign
           tail musttail notail]

# LLVM type text -> [IR type text, size, element type text (arrays only)]
# The named types of the module (`%T = type { ... }`), name => body text; read before the globals and functions.
NAMED_TYPES = {}

# A struct type, literal (`{ i32, ptr }`), packed (`<{ ptr, [16 x i8] }>`) or named (`%T`), laid out with the
# x86-64 data layout's rules: each field at the next multiple of its alignment (1 when packed), the size rounded up to
# the struct's alignment (the largest field's). Its IR type is a byte array: the IR reaches the fields by offset.
# Returns [ir, size, nil, fields] with fields [[offset, field type text], ...], or nil when text is not a struct.
def struct_type(s)
  if s.start_with?("%")
    body = NAMED_TYPES[s]
    refuse("type #{s}") if body.nil?
    refuse("opaque type #{s}") if body == "opaque"
    return struct_type(body)
  end
  packed = s.start_with?("<{") && s.end_with?("}>")
  return nil unless packed || (s.start_with?("{") && s.end_with?("}"))
  inner = packed ? s[2, s.size - 4] : s[1, s.size - 2]
  fields = []
  off = 0
  align = 1
  split_top(inner.strip).each do |f|
    a = packed ? 1 : ll_align(f)
    off = (off + a - 1) / a * a
    fields << [off, f.strip]
    off += ll_type(f)[1]
    align = a if a > align
  end
  size = (off + align - 1) / align * align
  ["(array #{size} char)", size, nil, fields]
end

def ll_align(text)
  s = text.strip
  return SCALARS[s][1] if SCALARS.key?(s)
  st = struct_type(s)
  return st[3].map { |f| s.start_with?("<{") ? 1 : ll_align(f[1]) }.max || 1 if st
  ll_align(ll_type(s)[2])
end

def ll_type(text)
  s = text.strip
  return SCALARS[s] + [nil] if SCALARS.key?(s)
  st = struct_type(s)
  return st if st
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

# The IR type of a value: a struct in a register (a first-class aggregate) is refused; in memory it is a byte array.
def ir_type(text)
  t = ll_type(text)
  refuse("a value of the struct type #{text.strip}") if t[3]
  t[0]
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

# Index of the parenthesis, bracket or brace that closes the one at `open`.
def close_of(s, open)
  depth = 0
  i = open
  while i < s.size
    depth += 1 if s[i] == "(" || s[i] == "[" || s[i] == "{"
    depth -= 1 if s[i] == ")" || s[i] == "]" || s[i] == "}"
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

# The text without its range(TYPE LO, HI) attributes, whose argument lists have spaces in them.
def strip_range(text)
  s = text
  k = s.index("range(")
  while k
    s = s[0, k] + s[close_of(s, k + 5) + 1, s.size].to_s
    k = s.index("range(")
  end
  s
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

# The index just after the name that starts at `at` (@f, %x, or a quoted @"(*T).m", whose text may hold parentheses).
def name_end(s, at)
  if s[at + 1] == '"'
    return s.index('"', at + 2) + 1
  end
  i = at + 1
  i += 1 while i < s.size && !" (,)".include?(s[i])
  i
end

# Name of the function defined or declared on a `define` or `declare` line.
def function_name(line)
  at = line.index("@")
  global_name(line[at, name_end(line, at) - at])
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
  def initialize(path, wasm)
    @wasm = wasm
    @path = path
    @file = path
    @funcs = {}       # functions defined or declared in the module: direct callees are &"f"
    @defined = {}     # the functions defined here: their aggregate parameters and results take this module's convention
    @agg_externals = {}   # functions only declared here whose signature has an aggregate: their address is refused
    @out_globals = []
    @out_data = []
    @out_funcs = []
  end

  def run
    lines = File.read(@path).split("\n")
    lines.each do |raw|
      line = raw.strip
      @funcs[function_name(line)] = true if line.start_with?("define ") || line.start_with?("declare ")
      @defined[function_name(line)] = true if line.start_with?("define ")
      if line.start_with?("%") && line.include?(" = type ")
        tname, body = line.split(" = type ", 2)
        NAMED_TYPES[tname.strip] = strip_comment(body)
      end
    end
    lines.each do |raw|
      line = raw.strip
      @agg_externals[function_name(line)] = true if line.start_with?("declare ") && aggregate_signature?(line)
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
    # debug metadata (`, !dbg !5`) does not change the global
    rest = rest[0, rest.index(", !")] if rest.include?(", !")
    # a string: an [N x i8] with a c"..." initializer (one inside a struct is an item of the struct's initializer)
    return string_global(name, rest) if rest.include?(' c"') && rest.include?("constant [") &&
                                        rest.index("constant [") < rest.index(' c"')
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
    # without an align, the type's own alignment (its size would be wrong for an array or a struct)
    align = align_text ? align_text.split(" ")[1].to_i : ll_align(type_text)
    if init.nil? && @wasm && name == "environ"
      # libc's environment (TinyGo's os reads it): an empty one, a null-terminated array of no strings
      @out_globals << "(global \"__nfcxx_no_env\" (ptr void) 8 8 (static) (init (zero 0 8)))"
      @out_globals << "(global \"environ\" (ptr void) 8 8 (init (addr 0 (ptr void) @\"__nfcxx_no_env\" 0)))"
      return
    end
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
    elsif init.start_with?("{") || init.start_with?("<{")
      refuse("initializer #{init} of #{ll}") if ty[3].nil?
      inner = init.start_with?("<{") ? init[2, init.size - 4] : init[1, init.size - 2]
      elems = split_top(inner.strip)
      refuse("initializer #{init} of #{ll}") unless elems.size == ty[3].size
      elems.each_with_index do |e, k|
        el, ev = split_type(e)
        init_items(ev, el, off + ty[3][k][0], items)
      end
    elsif init.start_with?('c"')
      # the bytes of an [N x i8] inside an aggregate (a top-level string is a data node, string_global)
      refuse("string initializer of #{ll}") unless ty[2] == "i8"
      byte_values(init[2, init.size - 3]).each_with_index { |b, k| items << "(scalar #{off + k} char (const char #{b}))" }
    elsif init == "undef" || init == "poison"
      items << "(zero #{off} #{ty[1]})" if ty[1] > 0
    elsif init.start_with?("inttoptr")
      # inttoptr (i64 N to ptr): the integer's 8 bytes
      inner = init[init.index("(") + 1, close_of(init, init.index("(")) - init.index("(") - 1]
      il, iv = typed(inner.split(" to ")[0])
      refuse("initializer #{init}") unless digits?(iv)
      items << "(scalar #{off} long (const long #{iv}))"
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
    if s.start_with?("[") || s.start_with?("{") || s.start_with?("<{")
      open = s.start_with?("<{") ? 1 : 0
      close = close_of(s, open)
      close += 1 if open == 1                  # the > of <{ ... }>
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

  # The bytes of an LLVM string body (\HH for a byte that is not printable), as signed char values.
  def byte_values(body)
    out = []
    i = 0
    while i < body.size
      if body[i] == "\\" && body[i + 1] == "\\"
        b = 92                              # LLVM writes a backslash as \\
        i += 2
      elsif body[i] == "\\"
        b = body[i + 1, 2].to_i(16)
        i += 3
      else
        b = body[i].ord
        i += 1
      end
      out << (b >= 128 ? b - 256 : b)
    end
    out
  end

  # LLVM writes each byte that is not printable as \HH, and a backslash as \\; the IR string takes C-style octal escapes.
  def escape_bytes(body)
    out = ""
    i = 0
    while i < body.size
      if body[i] == "\\" && body[i + 1] == "\\"
        out << "\\134"
        i += 2
      elsif body[i] == "\\"
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
    @pairs = {}              # register of a with.overflow result => [value register, flag register]
    @agg_slots = {}          # aggregate register => its slot operand (agg_operand)
    @agg_sizes = {}          # aggregate register => its size
    @agg_params = {}         # aggregate parameter registers: pointers to the caller's values
    @slots = []
    @ret_ptr = nil           # an aggregate result: the register of the caller's slot
    @next = 0
    hdr = header.strip
    hdr = hdr[0, hdr.size - 1].strip if hdr.end_with?("{")
    at = hdr.index("@")
    lp = hdr.index("(", name_end(hdr, at))
    name = global_name(hdr[at, lp - at])
    pre_text = strip_range(hdr[0, at]).strip
    ret_ll = nil
    if pre_text.end_with?("}") || pre_text.end_with?("}>")
      # an aggregate result type: the text from its opening brace
      # the brace that opens the type: scanned back from the end, counting nested braces
      k = pre_text.size - 1
      depth = 0
      while k >= 0
        depth += 1 if pre_text[k] == "}"
        depth -= 1 if pre_text[k] == "{"
        break if depth == 0
        k -= 1
      end
      k -= 1 if k > 0 && pre_text[k - 1] == "<"
      ret_ll = pre_text[k..-1]
      pre = pre_text[0, k].strip.split(" ")[1..-1] + ["void"]
    else
      pre = pre_text.split(" ")[1..-1]
      ret_ll = pre.last if aggregate?(pre.last)
    end
    if ret_ll
      ret = "void"
      @ret_ptr = temp
      @ret_size = ll_type(ret_ll)[1]
    else
      ret = ir_type(pre.last)
    end
    kind = function_kind(name, pre[0, pre.size - 1])
    rp = close_of(hdr, lp)
    attrs = hdr[rp + 1, hdr.size - rp - 1].strip.split(" ")
    refuse("function #{name}: #{attrs.join(' ')}") if attrs.any? { |a| a.start_with?("gc") || a.start_with?("section") }

    params = []
    params << "(param #{@ret_ptr} \"result\" (ptr void))" if @ret_ptr
    split_top(hdr[lp + 1, rp - lp - 1]).each do |p|
      if p == "..."
        params << "(ellipsis)"
        next
      end
      words = p.split(" ")
      refuse("parameter #{p} of #{name}") if words.any? { |w| %w[byval sret byref inalloca].include?(w) }
      plain = words.last.start_with?("%") ? words.last[1, words.last.size - 1] : words.last
      label = plain.to_i.to_s == plain ? "p#{plain}" : plain
      pty, = typed(p)
      if aggregate?(pty)
        r = reg(words.last)
        @agg_params[r] = true
        params << "(param %#{r} \"#{label}\" (ptr void))"
        next
      end
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
        ll, = split_type(rest)
        ty = ll_type(ll)
        incomings = []
        split_top(rest.strip[ll.size..-1].strip).each do |entry|
          value, pred = split_top(entry.strip[1, entry.strip.size - 2])
          incomings << [value, pred[1, pred.size - 1]]
        end
        d = reg(dst.strip)
        if aggregate?(ll)
          (@phis[bi] ||= []) << {dst: d, ll: ll, ty: ty, incomings: incomings, agg: agg_def(dst.strip, ll)}
          next
        end
        (@phis[bi] ||= []) << {dst: d, ll: ll, ty: ty, incomings: incomings}
        @prelude << "(let %#{d} #{ty[0]} #{zero_of(ty)})"
      end
    end

    body_out = []
    block_order(blocks).each do |bi|
      b = blocks[bi]
      body_out << "(label \"#{block_label(bi)}\")"
      b[:insts].each do |ins|
        next if ins.include?(" = phi ")
        body_out.concat(instruction(bi, ins))
      end
    end

    lines = ["(function \"#{name}\"", "  (ret #{ret})", "  (params #{params.join(' ')})"]
    lines << "  #{kind}" if kind
    @slots.each { |sl| lines << "  #{sl}" }
    (@prelude + body_out).each { |s| lines << "  #{s}" }
    lines.join("\n") + ")"
  end

  def function_kind(name, linkage)
    # Return-value attributes (noundef, zeroext, ...) do not change what the function does.
    # fastcc and ccc are calling conventions: within one module the IR's own convention serves every function.
    ignored = %w[dso_local hidden protected unnamed_addr local_unnamed_addr external default noundef zeroext signext nonnull
                 noalias fastcc ccc]
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
      next if line.empty? || line.start_with?("#dbg_")   # a debug record (LLVM 19), not an instruction
      # Debug and loop metadata (`, !llvm.loop !6`) does not change what the instruction does.
      meta = line.index(", !")
      line = line[0, meta].strip unless meta.nil?
      # A switch's case table spans lines; join them. Entries are separated by commas, as in the one-line form.
      while count_char(line, "[") > count_char(line, "]") && i < body.size
        extra = strip_comment(body[i])
        i += 1
        line = line + (line.end_with?("[") ? " " : ", ") + extra
      end
      # a label: a word, or a quoted name that may hold spaces ("f[[]int].exit":)
      if line.end_with?(":") && (line.index(" ").nil? || (line.start_with?('"') && line.end_with?('":')))
        blocks << {name: line[0, line.size - 1], insts: []}
        next
      end
      blocks << {name: nil, insts: []} if blocks.empty?
      blocks.last[:insts] << line
    end
    refuse("function without blocks") if blocks.empty?
    blocks
  end

  # The blocks in reverse post-order from the entry, then the unreachable ones. A definition dominates its uses, and a
  # dominator comes before the blocks it dominates in this order, so each register is declared (let) before it is
  # used in the text, as the QBE emitter needs; LLVM's own block order does not promise that (rustc's -Os puts a
  # block that returns a value before the block that computes it).
  def block_order(blocks)
    seen = {}
    post = []
    stack = [[0, successors(blocks[0]), 0]]
    seen[0] = true
    until stack.empty?
      top = stack.last
      if top[2] < top[1].size
        n = top[1][top[2]]
        top[2] += 1
        next if seen[n]
        seen[n] = true
        stack << [n, successors(blocks[n]), 0]
      else
        post << top[0]
        stack.pop
      end
    end
    order = post.reverse
    blocks.each_index { |i| order << i unless seen[i] }
    order
  end

  # The blocks that the terminator of a block (its last instruction) may go to: each `label %x` operand in it.
  def successors(b)
    term = b[:insts].last.to_s
    out = []
    k = term.index("label ")
    while k
      t = term[k + 6..-1].strip
      if t.start_with?('%"')
        e = t.index('"', 2) + 1
      else
        e = 0
        e += 1 while e < t.size && !" ,]".include?(t[e])
      end
      out << block_of(t[0, e])
      k = term.index("label ", k + 6)
    end
    out
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
    return agg_value(t, ll) if ll != "ptr" && ll != "label" && aggregate?(ll)
    if t.start_with?("ptrtoint")
      # ptrtoint (ptr @g to i64), a constant: the address as an integer
      inner = t[t.index("(") + 1, close_of(t, t.index("(")) - t.index("(") - 1]
      pl, pv = typed(inner.split(" to ")[0])
      di = ir_type(inner.split(" to ")[1])
      v = temp
      @pending << "(let #{v} #{di} (p2i #{di} #{operand(pv, pl)}))"
      return v
    end
    if t.start_with?("inttoptr")
      # inttoptr (i64 N to ptr), a constant
      inner = t[t.index("(") + 1, close_of(t, t.index("(")) - t.index("(") - 1]
      il, iv = typed(inner.split(" to ")[0])
      v = temp
      @pending << "(let #{v} (ptr void) (i2p (ptr void) #{operand(iv, il)}))"
      return v
    end
    if t.start_with?("%")
      "%#{reg(t)}"
    elsif t.start_with?("@")
      name = global_name(t)
      # a function pointer may be called with this module's convention for aggregates (call), so the address of a
      # function of another module that takes or returns one is refused
      refuse("address of #{name}, which takes or returns an aggregate and is not defined here") if @agg_externals[name]
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
    if base.start_with?("getelementptr")
      # a getelementptr of a getelementptr (TinyGo's type codes): the inner one's target and offset
      target, offset = constant_gep_parts(base)
    else
      refuse("constant getelementptr of #{base}") unless base.start_with?("@")
      target = operand(base, base_ll)
      offset = 0
    end
    cur_ll = parts[0]
    stride = ll_type(cur_ll)[1]
    parts[2, parts.size - 2].each_with_index do |idx, k|
      il, iv = typed(idx)
      refuse("constant getelementptr index #{iv}") unless digits?(iv) && INT_TYPES.include?(ir_type(il))
      fields = k > 0 ? ll_type(cur_ll)[3] : nil
      if fields
        refuse("constant getelementptr field #{iv} of #{cur_ll}") unless iv.to_i < fields.size
        offset += fields[iv.to_i][0]
        cur_ll = fields[iv.to_i][1]
        next
      end
      if k > 0
        cur_ll = ll_type(cur_ll)[2]
        refuse("constant getelementptr into #{cur_ll}") if cur_ll.nil?
        stride = ll_type(cur_ll)[1]
      end
      offset += iv.to_i * stride
    end
    [target, offset]
  end

  # `TYPE VALUE` as [LLVM type, value text]. Attributes between them are skipped; a constant getelementptr keeps
  # its whole text.
  def typed(text)
    s = text.strip
    if s.start_with?("{") || s.start_with?("<{") || s.start_with?("[")
      # an aggregate type: the value is a register (the last word) or a constant (all of the rest)
      ty, rest = split_type(s)
      return [ty, rest.start_with?("%") ? last_word(rest) : rest]
    end
    word = first_word(s)
    rest = s[word.size..-1].strip
    # a constant expression keeps its whole text, after the attributes in front of it (`ptr nonnull inttoptr (...)`)
    %w[getelementptr inttoptr ptrtoint].each do |cx|
      k = rest.index(cx)
      return [word, rest[k..-1]] if k && (k == 0 || rest[k - 1] == " ") && !rest[0, k].include?("%")
    end
    return [word, rest] if aggregate?(word) && !rest.start_with?("%") && !rest.include?(" %")
    [word, last_word(s)]
  end

  # Whether a declare line's result or a parameter is a struct or an array (named types are known by now).
  def aggregate_signature?(line)
    at = line.index("@")
    pre = line[0, at]
    return true if pre.include?("{") || pre.include?("[") || NAMED_TYPES.keys.any? { |t| pre.include?(t + " ") }
    lp = line.index("(", name_end(line, at))
    split_top(line[lp + 1, close_of(line, lp) - lp - 1]).any? { |p| aggregate?(p.start_with?("{") || p.start_with?("<{") || p.start_with?("[") ? split_type(p)[0] : first_word(p)) }
  end

  # ---- aggregate values ----------------------------------------------------------------------------------
  # A struct or array value in a register (a first-class aggregate: TinyGo's strings and interfaces, rustc's -O0 fat
  # pointers) lives in a slot of the function's frame, and the IR register is not used: the value's operand is the
  # slot's address. Since a value is never changed after it is made, a copy is made only where LLVM makes a new value
  # (insertvalue, a phi, a select, a load). A parameter of aggregate type is a pointer to the caller's value; a
  # function of this module that returns one takes a pointer to the caller's slot as its first parameter.

  def aggregate?(ll)
    t = ll.to_s.strip
    t.start_with?("{") || t.start_with?("<{") || t.start_with?("[") || NAMED_TYPES.key?(t)
  end

  # The operand of the aggregate register named `name` (%x): a pointer parameter, else its slot, made at first sight.
  def agg_operand(name)
    r = reg(name)
    return "%#{r}" if @agg_params[r]
    unless @agg_slots.key?(r)
      @agg_slots[r] = "$\"a#{r}\""
      @slots << "(slot \"a#{r}\" (array #{@agg_sizes[r] || 0} char) #{@agg_sizes[r] || 0} 16)"
    end
    @agg_slots[r]
  end

  # Records the size of the aggregate register `name` (its slot's size), from its type.
  def agg_def(name, ll)
    r = reg(name)
    size = ll_type(ll)[1]
    size = 1 if size < 1
    @agg_sizes[r] = size if @agg_sizes[r].nil? || @agg_sizes[r] < size
    agg_operand(name)
  end

  # A fresh slot for an aggregate constant or a temporary copy.
  def agg_temp(ll)
    size = ll_type(ll)[1]
    size = 1 if size < 1
    t = temp
    name = "t#{t[1, t.size - 1]}"
    @slots << "(slot \"#{name}\" (array #{size} char) #{size} 16)"
    "$\"#{name}\""
  end

  # An aggregate operand of type ll: a register's slot, or a constant written into a slot of its own.
  def agg_value(text, ll)
    t = text.strip
    return agg_operand(t) if t.start_with?("%")
    slot = agg_temp(ll)
    return slot if t == "undef" || t == "poison"
    items = []
    init_items(t, ll, 0, items)
    items.each { |it| @pending.concat(item_stores(slot, it)) }
    slot
  end

  # The statements that write an initializer item (init_items) into the object at slot.
  def item_stores(slot, item)
    form = item[1, item.size - 2]
    words = form.split(" ")
    off = words[1].to_i
    case words[0]
    when "zero"
      a = temp
      ["(let #{a} (ptr void) (offset #{slot} #{off}))", "(zero-fill #{words[2]} #{a})"]
    when "scalar"
      ty = words[2] == "(ptr" ? "(ptr void)" : words[2]
      value = form[form.index(ty) + ty.size..-1].strip
      a = temp
      ["(let #{a} (ptr void) (offset #{slot} #{off}))", "(store #{ty} #{a} #{value})"]
    when "addr"
      # (addr OFF (ptr void) TARGET ADDEND)
      rest = form[form.index("(ptr void)") + 10..-1].strip
      target = first_word(rest)
      addend = last_word(rest).to_i
      a = temp
      out = ["(let #{a} (ptr void) (offset #{slot} #{off}))"]
      v = target
      if addend != 0
        v = temp
        out << "(let #{v} (ptr void) (offset #{target} #{addend}))"
      end
      out << "(store (ptr void) #{a} #{v})"
      out
    else
      refuse("aggregate constant item #{item}")
    end
  end

  # The byte offset and the type of the field that the indices (constants) name in the aggregate type ll.
  def field_at(ll, idxs)
    off = 0
    cur = ll
    idxs.each do |i|
      k = i.strip
      refuse("aggregate index #{k}") unless digits?(k)
      t = ll_type(cur)
      if t[3]
        refuse("field #{k} of #{cur}") unless k.to_i < t[3].size
        off += t[3][k.to_i][0]
        cur = t[3][k.to_i][1]
      elsif t[2]
        cur = t[2]
        off += k.to_i * ll_type(cur)[1]
      else
        refuse("aggregate index into #{cur}")
      end
    end
    [off, cur]
  end

  # insertvalue AGG, VAL, IDX...: a copy of AGG with the field replaced.
  def insertvalue(dst, rest)
    parts = split_top(rest)
    al, av = typed(parts[0])
    vl, vv = typed(parts[1])
    off, fl = field_at(al, parts[2, parts.size - 2])
    out = []
    d = agg_def(dst, al)
    src = av.strip
    out << "(copy #{ll_type(al)[1]} #{d} #{agg_value(src, al)})" unless src == "undef" || src == "poison"
    a = temp
    out << "(let #{a} (ptr void) (offset #{d} #{off}))"
    if aggregate?(vl)
      out << "(copy #{ll_type(vl)[1]} #{a} #{agg_value(vv, vl)})"
    else
      out << "(store #{ir_type(vl)} #{a} #{operand(vv, vl)})"
    end
    out
  end

  # extractvalue AGG, IDX...: a load of the field (or a copy of an aggregate field).
  def extract_field(dst, al, av, idxs)
    off, fl = field_at(al, idxs)
    src = agg_value(av, al)
    a = temp
    out = ["(let #{a} (ptr void) (offset #{src} #{off}))"]
    if aggregate?(fl)
      out << "(copy #{ll_type(fl)[1]} #{agg_def(dst, fl)} #{a})"
    else
      out << "(let %#{reg(dst)} #{ir_type(fl)} (load #{ir_type(fl)} #{a}))"
    end
    out
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
    while FLAGS.include?(first_word(rest)) || first_word(rest) == "volatile" || first_word(rest) == "atomic"
      flags << first_word(rest)
      rest = rest[first_word(rest).size..-1].strip
    end
    d = dst ? reg(dst) : nil
    if flags.include?("atomic") || %w[cmpxchg atomicrmw fence].include?(op)
      refuse("atomic operation #{op} (needs --wasm)") unless @wasm
      rest = drop_ordering(rest)
    end

    case op
    when "alloca" then alloca(bi, d, rest)
    when "load" then load(d, rest, flags.include?("volatile"), dst)
    when "store" then store(rest, flags.include?("volatile"))
    when "add", "sub", "mul", "sdiv", "srem", "udiv", "urem", "shl", "lshr", "ashr", "and", "or", "xor"
      binary(d, op, rest, flags)
    when "fadd", "fsub", "fmul", "fdiv" then fbinary(d, op, rest)
    when "fneg" then fneg(d, rest)
    when "icmp" then icmp(d, rest)
    when "fcmp" then fcmp(d, rest)
    when "sext", "zext", "trunc", "sitofp", "fptosi", "fpext", "fptrunc", "ptrtoint", "inttoptr", "bitcast"
      conversion(d, op, rest)
    when "getelementptr" then gep(d, rest)
    when "call" then call(d, rest, dst)
    when "extractvalue" then extractvalue(d, rest, dst)
    when "insertvalue" then insertvalue(dst, rest)
    when "freeze"
      # a value with no poison in it: the IR's registers always hold one (undef and poison read as zero)
      fl, fv = typed(rest)
      refuse("freeze of #{fl}") if aggregate?(fl)
      ["(let %#{d} #{ir_type(fl)} #{operand(fv, fl)})"]
    when "cmpxchg" then cmpxchg(d, rest)
    when "atomicrmw" then atomicrmw(d, rest)
    when "fence" then []
    when "select" then select(d, rest, dst)
    when "br" then branch(bi, rest)
    when "switch" then switch(bi, rest)
    when "ret" then ret(rest)
    when "unreachable" then ["(unreachable)"]
    else refuse("instruction #{op}")
    end
  end

  def alloca(bi, d, rest)
    parts = split_top(rest)
    if bi != 0
      # outside the entry block (after llvm.stacksave): dynamic stack, released at the return
      refuse("variable-length alloca") if parts.size > 1 && !parts[1].start_with?("align")
      size = ll_type(parts[0])[1]
      return ["(let %#{d} (ptr void) (alloca (const int #{size > 0 ? size : 1})))"]
    end
    refuse("variable-length alloca") if parts.size > 1 && !parts[1].start_with?("align")
    ty = ll_type(parts[0])
    align = parts.find { |p| p.start_with?("align ") }
    refuse("alloca aligned to #{align}") if align && align.split(" ")[1].to_i > 16
    # a slot of the frame: the entry block's allocas live until the return, as a slot does (and the ASan mode of the
    # wasm emitter checks slots). A zero-sized object (rustc's [0 x i8] for a unit value) still gets an address.
    size = ty[1] > 0 ? ty[1] : 1
    name = "s#{d}"
    @slots << "(slot \"#{name}\" (array #{size} char) #{size} #{align ? align.split(' ')[1].to_i : 16})"
    ["(let %#{d} (ptr void) $\"#{name}\")"]
  end

  def load(d, rest, vol, dst)
    parts = split_top(rest)
    ll = parts[0]
    if aggregate?(ll)
      return ["(copy #{ll_type(ll)[1]} #{agg_def(dst, ll)} #{operand(typed(parts[1])[1], 'ptr')})"]
    end
    ["(let %#{d} #{ir_type(ll)} (load#{vol ? '.v' : ''} #{ir_type(ll)} #{operand(typed(parts[1])[1], 'ptr')}))"]
  end

  def store(rest, vol)
    parts = split_top(rest)
    vl, vv = typed(parts[0])
    if aggregate?(vl)
      return ["(copy #{ll_type(vl)[1]} #{operand(typed(parts[1])[1], 'ptr')} #{agg_value(vv, vl)})"]
    end
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
                   # unsigned: the wasm emitter takes them; the QBE emitter refuses checked unsigned operations
                   when "udiv" then ["cdiv", unsigned_of(ir)]
                   when "urem" then ["crem", unsigned_of(ir)]
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
           else return fcmp_other(d, pred, ir, x, y)
           end
    ["(let %#{d} bool #{text})"]
  end

  # The other predicates, from the ones above: ord is x == x and y == y (neither is NaN), uno its negation, one is
  # ordered and unequal, and each unordered u* is the negation of the opposite ordered one (ult is not oge).
  def fcmp_other(d, pred, ir, x, y)
    t1 = temp
    t2 = temp
    case pred
    when "ord", "uno"
      out = ["(let #{t1} bool (eq #{ir} #{x} #{x}))", "(let #{t2} bool (eq #{ir} #{y} #{y}))",
             "(let %#{d} bool (and bool #{t1} #{t2}))"]
      return out if pred == "ord"
      t3 = temp
      return out[0, 2] + ["(let #{t3} bool (and bool #{t1} #{t2}))", "(let %#{d} bool (eq bool #{t3} (const bool 0x0)))"]
    when "one", "ueq"
      t3 = temp
      out = ["(let #{t1} bool (lt.f #{ir} #{x} #{y}))", "(let #{t2} bool (lt.f #{ir} #{y} #{x}))"]
      return out + ["(let %#{d} bool (or bool #{t1} #{t2}))"] if pred == "one"
      return out + ["(let #{t3} bool (or bool #{t1} #{t2}))", "(let %#{d} bool (eq bool #{t3} (const bool 0x0)))"]
    when "ult", "ule", "ugt", "uge"
      ordered = { "ult" => "(le.f #{ir} #{y} #{x})", "ule" => "(lt.f #{ir} #{y} #{x})",
                  "ugt" => "(le.f #{ir} #{x} #{y})", "uge" => "(lt.f #{ir} #{x} #{y})" }[pred]
      return ["(let #{t1} bool #{ordered})", "(let %#{d} bool (eq bool #{t1} (const bool 0x0)))"]
    when "true", "false"
      return ["(let %#{d} bool (const bool #{pred == 'true' ? '0x1' : '0x0'}))"]
    end
    refuse("fcmp #{pred}")
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
      if sl == "i1"
        # true is all ones: 0 or 1, negated
        t = temp
        return ["(let #{t} #{di} (iconv #{di} #{x}))", "(let %#{d} #{di} (wneg #{di} #{t}))"]
      end
      ["(let %#{d} #{di} (iconv #{di} #{x}))"]
    when "zext"
      # The IR's integers are signed, so a zero extension is the sign extension masked to the source width.
      return ["(let %#{d} #{di} (iconv #{di} #{x}))"] if sl == "i1"
      mask = (1 << (ll_type(sl)[1] * 8)) - 1
      t = temp
      ["(let #{t} #{di} (iconv #{di} #{x}))", "(let %#{d} #{di} (and #{di} #{t} (const #{di} #{mask})))"]
    when "trunc"
      if to == "i1"
        # the low bit (rustc loads a bool as i8 and truncates it)
        t = temp
        return ["(let #{t} #{si} (and #{si} #{x} (const #{si} 1)))", "(let %#{d} bool (ne #{si} #{t} (const #{si} 0)))"]
      end
      ["(let %#{d} #{di} (iconv #{di} #{x}))"]
    when "sitofp" then ["(let %#{d} #{di} (i2f #{di} #{x}))"]
    when "fptosi" then ["(let %#{d} #{di} (cf2i #{di} #{x}))"]
    when "fpext", "fptrunc" then ["(let %#{d} #{di} (fconv #{di} #{x}))"]
    when "ptrtoint" then ["(let %#{d} #{di} (p2i #{di} #{x}))"]
    when "inttoptr" then ["(let %#{d} #{di} (i2p #{di} #{x}))"]
    when "bitcast"
      # a pointer, or the bits of a float as an integer of the same size (and back)
      same = ll_type(sl)[1] == ll_type(to)[1] && (FLOAT_TYPES.include?(si) != FLOAT_TYPES.include?(di)) &&
             [si, di].all? { |t| FLOAT_TYPES.include?(t) || %w[int long].include?(t) }
      refuse("bitcast #{sl} to #{to}") unless (si == "(ptr void)" && di == "(ptr void)") || same
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
      il, iv = typed(idx)
      target = k == idxs.size - 1 ? "%#{d}" : temp
      fields = k > 0 ? ll_type(cur_ll)[3] : nil
      if fields
        # a field of a struct: the index is a constant, and the address moves by the field's offset
        refuse("getelementptr into #{cur_ll} with the index #{iv}") unless digits?(iv) && iv.to_i < fields.size
        field = fields[iv.to_i]
        out << "(let #{target} (ptr void) (offset #{cur} #{field[0]}))"
        cur_ll = field[1]
      else
        if k > 0
          elem = ll_type(cur_ll)[2]
          refuse("getelementptr into #{cur_ll}") if elem.nil?
          cur_ll = elem
          stride = ll_type(cur_ll)[1]
        end
        out << "(let #{target} (ptr void) (index #{cur} #{operand(iv, il)} #{stride}))"
      end
      cur = target
    end
    out
  end

  def call(d, rest, dst = nil)
    r = rest.strip
    while %w[noalias noundef nonnull zeroext signext fastcc ccc align dereferenceable].include?(first_word(r)) ||
          r.start_with?("range(") || r.start_with?("dereferenceable") || digits?(first_word(r))
      # range(i32 0, 10) is an attribute with an argument list (rustc writes it on results); align 8 has a number
      cut = r.start_with?("range(") ? close_of(r, 5) + 1 : first_word(r).size
      r = r[cut..-1].strip
    end
    if r.start_with?("{") || r.start_with?("<{")
      ret_ll, after = split_type(r)
      lp0 = after.index("(")
      return overflow_call(d, r) if after[0, lp0].include?(".with.overflow.")
      r = after
    else
      ret_ll = first_word(r)
      r = r[ret_ll.size..-1].strip
    end
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
    return syscall_asm(d, r, ret_ll) if r.start_with?("asm ")
    lp = r.start_with?("@") || r.start_with?("%") ? r.index("(", name_end(r, 0)) : r.index("(")
    callee = r[0, lp].strip
    return intrinsic(d, callee, r[lp + 1, close_of(r, lp) - lp - 1]) if callee.start_with?("@llvm.")
    target = if callee.start_with?("@")
               name = global_name(callee)
               refuse("call of #{name}, which the module does not declare") unless @funcs.key?(name)
               "&\"#{name}\""
             else
               operand(callee, "ptr")
             end
    # a direct callee defined here, or a function pointer (whose value is the address of a function of this module, or
    # of an external one without aggregates: see operand), takes this module's convention for aggregates
    own = callee.start_with?("@") ? @defined[global_name(callee)] : true
    args = split_top(r[lp + 1, close_of(r, lp) - lp - 1]).map do |a|
      refuse("argument #{a}") if a.split(" ").any? { |w| w.start_with?("byval") || w.start_with?("sret") }
      al, av = typed(a)
      # an aggregate goes to a function of this module as a pointer; another function's convention is not known
      refuse("aggregate argument #{a} of #{callee}") if aggregate?(al) && !own
      operand(av, al)
    end
    if aggregate?(ret_ll)
      refuse("aggregate result #{ret_ll} of #{callee}") unless own
      return ["(eval (call void #{target} #{([agg_def(dst, ret_ll)] + args).join(' ')}))"]
    end
    ret = ir_type(ret_ll)
    head = ["call", ret, target]
    head << fixed_variadic.strip if fixed_variadic
    text = "(#{(head + args).join(' ')})"
    return ["(eval #{text})"] if ret == "void"
    ["(let %#{d} #{ret} #{text})"]
  end

  # `asm sideeffect inteldialect "syscall", "={rax},0,{rdi},..."(i64 NR, i64 A1, ...)` (--wasm): a call of the import
  # __syscall with the number and six arguments (the missing ones 0). Any other inline assembly is refused.
  def syscall_asm(d, r, ret_ll)
    q = r.index('"')
    # TinyGo's setjmp for defer and recover (leaq 1f(%rip) ...): its first return is 0, and with -panic=trap no
    # panic jumps back to it, so 0 is its only result
    return ["(let %#{d} long (const long 0))"] if @wasm && q && r[q..-1].start_with?('"\\0Aleaq 1f(%rip), ') && ret_ll == "i64"
    refuse("inline assembly #{r[0, 60]}") unless @wasm && q && r[q, 10] == '"syscall",' && ret_ll == "i64"
    # the argument list follows the constraint string
    q2 = r.index('"', r.index('"', q + 10) + 1)
    lp = r.index("(", q2)
    args = split_top(r[lp + 1, close_of(r, lp) - lp - 1]).map { |a| al, av = typed(a); operand(av, al) }
    args << "(const long 0)" while args.size < 7
    ["(let %#{d} long (call long &\"__syscall\" #{args.join(' ')}))"]
  end

  # The intrinsics in the subset:
  #   llvm.memcpy with a constant length: a copy statement; llvm.memset of zero: a zero-fill (both need the byte count
  #   as a constant); llvm.fmuladd: fmul then fadd, which LLVM allows (the fused form is optional); llvm.smax, smin,
  #   umax, umin: a compare and a conditional set.
  def intrinsic(d, callee, args_text)
    # hints that do not change what the program does: the lifetime of a stack object, an assumption, alias scopes
    return [] if NO_OP_INTRINSICS.any? { |n| callee.start_with?("@llvm.#{n}") }
    return ["(trap)"] if callee == "@llvm.trap" || callee == "@llvm.debugtrap"
    args = split_top(args_text).map { |a| typed(a) }
    if callee.start_with?("@llvm.memcpy.") || callee.start_with?("@llvm.memmove.")
      # the IR's copy has memmove's semantics (pathb-stage2.md), so an overlapping memmove is right too. The length
      # is a constant or an unsigned_long register (the wasm and QBE emitters take both).
      return ["(copy #{length(args[2])} #{operand(args[0][1], args[0][0])} #{operand(args[1][1], args[1][0])})"]
    elsif callee.start_with?("@llvm.memset.")
      dst = operand(args[0][1], args[0][0])
      return ["(zero-fill #{length(args[2])} #{dst})"] if args[1][1] == "0"
      refuse("memset of a non-zero value and a non-constant length") unless digits?(args[2][1])
      return fill(dst, args[1][1], args[2][1].to_i)
    end
    return count_zeros(d, callee, args) if callee.start_with?("@llvm.ctlz.") || callee.start_with?("@llvm.cttz.")
    return saturating(d, callee, args) if callee.start_with?("@llvm.usub.sat.") || callee.start_with?("@llvm.uadd.sat.")
    return funnel_shift(d, callee, args) if callee.start_with?("@llvm.fshl.") || callee.start_with?("@llvm.fshr.")
    # llvm.stacksave: the dynamic allocas after it (alloca, which the emitters release at the return) are not
    # released early by its stackrestore, so a token is enough
    return ["(let %#{d} (ptr void) (null (ptr void)))"] if callee.start_with?("@llvm.stacksave")
    if callee.start_with?("@llvm.abs.")
      # |x|, wrapping at the minimum (the poison flag is ignored: wrapping refines it)
      ir = ir_type(args[0][0])
      x = operand(args[0][1], args[0][0])
      neg = temp
      c = temp
      return ["(let %#{d} #{ir} #{x})", "(let #{c} bool (lt.s #{ir} #{x} (const #{ir} 0)))",
              "(let #{neg} #{ir} (wneg #{ir} #{x}))", "(if #{c} (then (set %#{d} #{neg})))"]
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

  # The length operand of memcpy, memmove or memset: a constant, or a register converted to unsigned_long.
  def length(arg)
    ll, v = arg
    return v if digits?(v)
    t = temp
    @pending << "(let #{t} unsigned_long (iconv unsigned_long #{operand(v, ll)}))"
    t
  end

  # memset of a constant byte other than zero, with a constant length (rustc's `[true; 100]`): stores of the byte
  # repeated in a long, then single bytes. The IR has no fill statement, so a long fill is refused rather than unrolled.
  def fill(dst, byte_text, n)
    refuse("memset of a non-constant value") unless digits?(byte_text)
    refuse("memset of #{n} bytes (more than 512)") if n > 512
    b = byte_text.to_i & 255
    word = 0
    8.times { word = word * 256 + b }
    word -= 18446744073709551616 if word >= 9223372036854775808
    byte = b >= 128 ? b - 256 : b
    out = []
    off = 0
    while off < n
      wide = n - off >= 8
      t = temp
      out << "(let #{t} (ptr void) (offset #{dst} #{off}))"
      out << (wide ? "(store long #{t} (const long #{word}))" : "(store char #{t} (const char #{byte}))")
      off += wide ? 8 : 1
    end
    out
  end

  # llvm.{s,u}{add,sub,mul}.with.overflow (rustc's overflow checks): the { iN, i1 } result is two registers, the
  # wrapped value and the overflow flag, which extractvalue reads. Signed add and sub overflow when the result's sign
  # is wrong for the operands' (((a ^ r) & (b ^ r)) < 0, and ((a ^ b) & (a ^ r)) < 0); unsigned add and sub when the
  # result wraps around (r < a, a < b). A product narrower than 64 bits is computed in long and compared with its
  # truncation; at 64 bits it is divided back (a != 0 && r / a != b, with a == -1 apart: there only b == INT64_MIN
  # overflows, and the division would trap).
  def overflow_call(d, r)
    close = close_of(r, 0)
    rest = r[close + 1, r.size - close - 1].strip
    lp = rest.index("(")
    callee = rest[0, lp].strip
    op = %w[sadd uadd ssub usub smul umul].find { |k| callee.start_with?("@llvm.#{k}.with.overflow.") }
    refuse("call returning #{r[0, close + 1]}") if op.nil?
    args = split_top(rest[lp + 1, close_of(rest, lp) - lp - 1]).map { |a| typed(a) }
    ll = args[0][0]
    ir = ir_type(ll)
    refuse("#{op}.with.overflow on #{ll}") unless INT_TYPES.include?(ir)
    a = operand(args[0][1], ll)
    b = operand(args[1][1], ll)
    signed = op[0] == "s"
    kind = op[1, 3]
    v = temp
    f = temp
    @pairs[d] = [v, f]
    out = ["(let #{v} #{ir} (w#{kind} #{ir} #{a} #{b}))"]
    if kind == "add" || kind == "sub"
      if signed
        x = temp; y = temp; z = temp
        out << (kind == "add" ? "(let #{x} #{ir} (xor #{ir} #{a} #{v}))" : "(let #{x} #{ir} (xor #{ir} #{a} #{b}))")
        out << (kind == "add" ? "(let #{y} #{ir} (xor #{ir} #{b} #{v}))" : "(let #{y} #{ir} (xor #{ir} #{a} #{v}))")
        out << "(let #{z} #{ir} (and #{ir} #{x} #{y}))"
        out << "(let #{f} bool (lt.s #{ir} #{z} (const #{ir} 0)))"
      else
        u = unsigned_of(ir)
        out << (kind == "add" ? "(let #{f} bool (lt.u #{u} #{v} #{a}))" : "(let #{f} bool (lt.u #{u} #{a} #{b}))")
      end
    elsif ir != "long"
      # the exact product in long, compared with the wrapped one widened back
      wide = signed ? "long" : "unsigned_long"
      narrow = signed ? ir : unsigned_of(ir)
      wides = [a, b, v].map do |o|
        n = temp
        w = temp
        out << "(let #{n} #{narrow} (iconv #{narrow} #{o}))"
        out << "(let #{w} #{wide} (iconv #{wide} #{n}))"
        w
      end
      p = temp
      out << "(let #{p} #{wide} (wmul #{wide} #{wides[0]} #{wides[1]}))"
      out << "(let #{f} bool (ne #{wide} #{p} #{wides[2]}))"
    else
      t = signed ? "long" : "unsigned_long"
      zero = temp; quo = temp; ne = temp
      out << "(let #{f} bool (const bool 0x0))"
      out << "(let #{zero} bool (eq long #{a} (const long 0)))"
      check = "(let #{quo} #{t} (cdiv #{t} #{v} #{a})) (let #{ne} bool (ne #{t} #{quo} #{b})) (set #{f} #{ne})"
      if signed
        m1 = temp; mn = temp
        out << "(let #{m1} bool (eq long #{a} (const long -1)))"
        out << "(let #{mn} bool (eq long #{b} (const long -9223372036854775808)))"
        out << "(if #{m1} (then (set #{f} #{mn})) (else (if #{zero} (then) (else #{check}))))"
      else
        out << "(if #{zero} (then) (else #{check}))"
      end
    end
    out
  end

  # The text of an atomic operation without its memory orderings and sync scope: on one thread they mean nothing.
  def drop_ordering(text)
    t = text
    k = t.index("syncscope(")
    t = t[0, k] + t[close_of(t, k + 9) + 1, t.size].to_s if k
    kept = []
    t.split(" ").each do |w|
      bare = w.end_with?(",") ? w[0, w.size - 1] : w
      if %w[unordered monotonic acquire release acq_rel seq_cst weak].include?(bare)
        # `seq_cst, align 4`: the comma stays with the word before
        kept[kept.size - 1] = kept.last + "," if w.end_with?(",") && !kept.empty? && !kept.last.end_with?(",")
      else
        kept << w
      end
    end
    kept.join(" ")
  end

  # cmpxchg (--wasm): the old value, and whether it equalled the expected one, in which case the new value is
  # stored. The { T, i1 } result is a pair of registers, as with.overflow's.
  def cmpxchg(d, rest)
    parts = split_top(rest)
    p = operand(typed(parts[0])[1], "ptr")
    ll, cmp = typed(parts[1])
    _, nv = typed(parts[2])
    ir = ir_type(ll)
    v = temp
    f = temp
    @pairs[d] = [v, f]
    ["(let #{v} #{ir} (load #{ir} #{p}))", "(let #{f} bool (eq #{ir} #{v} #{operand(cmp, ll)}))",
     "(if #{f} (then (store #{ir} #{p} #{operand(nv, ll)})))"]
  end

  # atomicrmw (--wasm): load, the operation, store; the result is the old value.
  def atomicrmw(d, rest)
    op = first_word(rest)
    parts = split_top(rest[op.size..-1].strip)
    p = operand(typed(parts[0])[1], "ptr")
    ll, val = typed(parts[1])
    ir = ir_type(ll)
    x = operand(val, ll)
    nv = temp
    ops = { "add" => "wadd", "sub" => "wsub", "and" => "and", "or" => "or", "xor" => "xor" }
    out = ["(let %#{d} #{ir} (load #{ir} #{p}))"]
    if op == "xchg"
      out << "(store #{ir} #{p} #{x})"
      return out
    end
    refuse("atomicrmw #{op}") unless ops.key?(op) && INT_TYPES.include?(ir)
    out << "(let #{nv} #{ir} (#{ops[op]} #{ir} %#{d} #{x}))"
    out << "(store #{ir} #{p} #{nv})"
    out
  end

  # extractvalue of a with.overflow result (overflow_call): field 0 is the value, field 1 the flag.
  def extractvalue(d, rest, dst)
    parts = split_top(rest)
    al, agg = typed(parts[0])
    pair = agg.start_with?("%") ? @pairs[reg(agg)] : nil
    return extract_field(dst, al, agg, parts[1, parts.size - 1]) if pair.nil?
    refuse("extractvalue of #{parts[0]}") unless %w[0 1].include?(parts[1])
    k = parts[1].to_i
    ty = k == 0 ? ir_type(first_field(parts[0])) : "bool"
    ["(let %#{d} #{ty} #{pair[k]})"]
  end

  # The first field type of `{ i32, i1 } %x`.
  def first_field(text)
    s = text.strip
    split_top(s[1, close_of(s, 0) - 1])[0]
  end

  # llvm.ctlz and llvm.cttz (TinyGo's heap and bits code): a binary search over halves of the word, in unsigned
  # arithmetic. A zero operand gives the width (the flag that would make it poison is ignored: the width is a valid
  # refinement).
  def count_zeros(d, callee, args)
    ll = args[0][0]
    ir = ir_type(ll)
    refuse("#{callee} on #{ll}") unless INT_TYPES.include?(ir)
    u = unsigned_of(ir)
    bits = ll_type(ll)[1] * 8
    lead = callee.start_with?("@llvm.ctlz.")
    x = temp
    out = ["(let %#{d} #{ir} (const #{ir} 0))", "(let #{x} #{u} (iconv #{u} #{operand(args[0][1], ll)}))"]
    z = temp
    out << "(let #{z} bool (eq #{u} #{x} (const #{u} 0)))"
    body = []
    half = bits / 2
    while half >= 1
      # the top (ctlz) or bottom (cttz) half of what is left is zero: count it and shift it away
      part = temp
      zero = temp
      sh = temp
      if lead
        body << "(let #{part} #{u} (cshr #{u} #{x} (const #{u} #{bits - half})))"
      else
        mask = (1 << half) - 1               # half is at most bits / 2, so the mask is positive
        body << "(let #{part} #{u} (and #{u} #{x} (const #{u} #{mask})))"
      end
      body << "(let #{zero} bool (eq #{u} #{part} (const #{u} 0)))"
      n = temp
      body << "(let #{n} #{ir} (wadd #{ir} %#{d} (const #{ir} #{half})))"
      body << "(let #{sh} #{u} (#{lead ? 'cshl' : 'cshr'} #{u} #{x} (const #{u} #{half})))"
      body << "(if #{zero} (then (set %#{d} #{n}) (set #{x} #{sh})))"
      half /= 2
    end
    out << "(if #{z} (then (set %#{d} (const #{ir} #{bits}))) (else #{body.join(' ')}))"
    out
  end

  # llvm.fshl(a, b, c): the high half of (a:b) << (c mod w); llvm.fshr(a, b, c): the low half of (a:b) >> (c mod w).
  # A count of 0 gives a (fshl) or b (fshr) unchanged.
  def funnel_shift(d, callee, args)
    ll = args[0][0]
    ir = ir_type(ll)
    u = unsigned_of(ir)
    w = ll_type(ll)[1] * 8
    a = operand(args[0][1], ll)
    b = operand(args[1][1], ll)
    c = operand(args[2][1], ll)
    k = temp; z = temp; inv = temp; hi = temp; lo = temp; r = temp
    left = callee.start_with?("@llvm.fshl.")
    ["(let #{k} #{u} (and #{u} #{c} (const #{u} #{w - 1})))",
     "(let %#{d} #{ir} #{left ? a : b})",
     "(let #{z} bool (eq #{u} #{k} (const #{u} 0)))",
     "(if #{z} (then) (else " \
       "(let #{inv} #{u} (wsub #{u} (const #{u} #{w}) #{k})) " \
       "(let #{hi} #{u} (cshl #{u} #{a} #{left ? k : inv})) " \
       "(let #{lo} #{u} (cshr #{u} #{b} #{left ? inv : k})) " \
       "(let #{r} #{u} (or #{u} #{hi} #{lo})) (set %#{d} #{r})))"]
  end

  # llvm.usub.sat (a < b ? 0 : a - b) and llvm.uadd.sat (the sum, or all ones when it wraps around).
  def saturating(d, callee, args)
    ll = args[0][0]
    ir = ir_type(ll)
    u = unsigned_of(ir)
    a = operand(args[0][1], ll)
    b = operand(args[1][1], ll)
    c = temp
    if callee.start_with?("@llvm.usub.sat.")
      return ["(let %#{d} #{ir} (wsub #{ir} #{a} #{b}))", "(let #{c} bool (lt.u #{u} #{a} #{b}))",
              "(if #{c} (then (set %#{d} (const #{ir} 0))))"]
    end
    ["(let %#{d} #{ir} (wadd #{ir} #{a} #{b}))", "(let #{c} bool (lt.u #{u} %#{d} #{a}))",
     "(if #{c} (then (set %#{d} (const #{ir} -1))))"]
  end

  def select(d, rest, dst = nil)
    parts = split_top(rest)
    cl, cv = typed(parts[0])
    refuse("select on a condition of type #{cl}") unless cl == "i1"
    tl, av = typed(parts[1])
    _, bv = typed(parts[2])
    if aggregate?(tl)
      n = ll_type(tl)[1]
      x = agg_value(av, tl)
      y = agg_value(bv, tl)
      return ["(if #{operand(cv, cl)} (then (copy #{n} #{agg_def(dst, tl)} #{x})) (else (copy #{n} #{agg_def(dst, tl)} #{y})))"]
    end
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
      return ["(copy #{p[:ty][1]} #{p[:agg]} #{operand(v, p[:ll])})"] if p[:agg]
      return ["(set %#{p[:dst]} #{operand(v, p[:ll])})"]
    end
    lines = []
    temps = []
    pairs.each do |p, v|
      if p[:agg]
        t = agg_temp(p[:ll])
        lines << "(copy #{p[:ty][1]} #{t} #{operand(v, p[:ll])})"
      else
        t = temp
        lines << "(let #{t} #{p[:ty][0]} #{operand(v, p[:ll])})"
      end
      temps << t
    end
    pairs.each_with_index do |pair, i|
      p = pair[0]
      lines << (p[:agg] ? "(copy #{p[:ty][1]} #{p[:agg]} #{temps[i]})" : "(set %#{p[:dst]} #{temps[i]})")
    end
    lines
  end

  # The block operand of `label %x` (or `label %"a b"`).
  def label_of(text)
    t = text.strip
    t.start_with?("label ") ? t[6..-1].strip : t
  end

  def branch(bi, rest)
    if rest.start_with?("label ")
      to = block_of(label_of(rest))
      return phi_copies(bi, to) + ["(goto \"#{block_label(to)}\")"]
    end
    parts = split_top(rest)
    cl, cv = typed(parts[0])
    refuse("branch on #{cl}") unless cl == "i1"
    t = block_of(label_of(parts[1]))
    f = block_of(label_of(parts[2]))
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
      target = block_of(label_of(entries[i + 1]))
      c = temp
      out << "(let #{c} bool (eq #{ir} #{value} #{operand(cv, cl)}))"
      out << "(if #{c} (then #{(phi_copies(bi, target) + ["(goto \"#{block_label(target)}\")"]).join(' ')}))"
      i += 2
    end
    default = block_of(label_of(parts[1]))
    out + phi_copies(bi, default) + ["(goto \"#{block_label(default)}\")"]
  end

  def ret(rest)
    return ["(return)"] if rest.strip == "void"
    tl, v = typed(rest)
    # an aggregate result goes to the caller's slot (the first parameter)
    return ["(copy #{@ret_size} #{@ret_ptr} #{operand(v, tl)})", "(return)"] if @ret_ptr
    ["(return #{operand(v, tl)})"]
  end
end

args = ARGV.dup
wasm = args.delete("--wasm") ? true : false
if args.size != 1
  $stderr.puts "usage: scripts/mrb scripts/llvm-to-pathb.rb [--wasm] FILE.ll > FILE.ir"
  exit 1
end
Translator.new(args[0], wasm).run
