#!/usr/bin/env ruby
# Path B: prototype IR -> C+HVX emitter (docs/notes/hexagon.md, section 5).
#
# Handles exactly two patterns, matched structurally (no function names consulted):
# a counted loop over three int16 pointers and an int bound whose body is a wrapping
# add narrowed back to short (emitted as a vaddh vector main loop plus a scalar tail),
# or a widening multiply with a constant arithmetic shift narrowed back to short
# (emitted as vmpyhv, split through a stack temporary, narrowed with vasrwh with the
# odd half first so lanes come back sequential, plus a scalar tail).
# Anything else in the module is refused, never silently dropped.
#
# Usage: scripts/mrb.rb scripts/pathb-hvx-emit.rb [FILE.ir | -]   C with HVX builtins on stdout
#
# Exit status:
#   0  the module was emitted
#   3  refused: the IR has a node, type or marker this emitter does not handle; the reason is on stderr
#   1  error: malformed IR text
#
# mruby-compatible: no Regexp, byte strings.
# The output C needs clang --target=hexagon -mhvx -mhvx-length=128b.

class Refused < StandardError; end
class BadIR < StandardError; end

# --- minimal s-expression reader (byte strings, no Regexp) ---

def tok_end?(c)
  c == 32 || c == 10 || c == 13 || c == 9 || c == 40 || c == 41 || c == 34
end

def tokenize(src)
  toks = []
  i = 0
  n = src.bytesize
  while i < n
    c = src.getbyte(i)
    if c == 32 || c == 10 || c == 13 || c == 9
      i += 1
    elsif c == 40
      toks << "("
      i += 1
    elsif c == 41
      toks << ")"
      i += 1
    elsif c == 34
      j = i + 1
      buf = "".b
      while j < n && src.getbyte(j) != 34
        if src.getbyte(j) == 92 && j + 1 < n
          buf << src.getbyte(j + 1)
          j += 2
        else
          buf << src.getbyte(j)
          j += 1
        end
      end
      raise BadIR, "unterminated string" if j >= n
      toks << [:str, buf]
      i = j + 1
    else
      j = i
      j += 1 while j < n && !tok_end?(src.getbyte(j))
      toks << src.byteslice(i, j - i)
      i = j
    end
  end
  toks
end

def parse_toks(toks, pos)
  raise BadIR, "unexpected end of input" if pos >= toks.size
  t = toks[pos]
  if t == "("
    list = []
    pos += 1
    while pos < toks.size && toks[pos] != ")"
      node, pos = parse_toks(toks, pos)
      list << node
    end
    raise BadIR, "unterminated list" if pos >= toks.size
    [list, pos + 1]
  elsif t == ")"
    raise BadIR, "unexpected )"
  else
    [t, pos + 1]
  end
end

def parse(src)
  toks = tokenize(src)
  forms = []
  pos = 0
  while pos < toks.size
    node, pos = parse_toks(toks, pos)
    forms << node
  end
  forms.map { |f| merge_slotrefs(f) }
end

# The IR spells a slot reference `$"name"` (two tokens: `$` and a string);
# merge each such pair into one "$name" string.
def merge_slotrefs(x)
  if x.is_a?(Array)
    out = []
    i = 0
    while i < x.size
      if x[i] == "$" && i + 1 < x.size && x[i + 1].is_a?(Array) && x[i + 1][0] == :str
        out << "$#{x[i + 1][1]}"
        i += 2
      else
        out << merge_slotrefs(x[i])
        i += 1
      end
    end
    out
  else
    x
  end
end

# No Regexp in mruby: true when s is an optional minus followed by digits.
def int_const?(s)
  return false unless s.is_a?(String) && s.bytesize > 0
  i = 0
  i = 1 if s.getbyte(0) == 45
  return false if i >= s.bytesize
  while i < s.bytesize
    c = s.getbyte(i)
    return false if c < 48 || c > 57
    i += 1
  end
  true
end

def refuse(reason)
  raise Refused, reason
end

def slot_ref?(x)
  x.is_a?(String) && x.bytesize > 1 && x.getbyte(0) == 36
end

def slot_name(x)
  x.byteslice(1, x.bytesize - 1)
end

# --- structural match of the counted int16 wadd loop ---
#
# (function NAME (ret void)
#   (params (param %0 P0 (ptr short)) (param %1 P1 (ptr (const short)))
#           (param %2 P2 (ptr (const short))) (param %3 P3 int))
#   (slot Sdst ...) (slot Sa ...) (slot Sb ...) (slot Sn ...) (slot Si ...)
#   (store ... $Sdst %0) (store ... $Sa %1) (store ... $Sb %2) (store ... $Sn %3)
#   (block (store int $Si (const int 0))
#     (loop (body (let ... (load int $Si)) (let ... (load int $Sn))
#                   (let ... bool (lt.s int ... ...)) (if ... (then) (else (break)))
#                   (block ... (store short DST (iconv short (wadd ...))) ...))
#            (step ... (store int $Si (wadd int $Si (const int 1))) ...))))
# Returns [dst, a, b, n] slot names on match.

def match_loop_fn(fn)
  refuse("not a function form") unless fn.is_a?(Array) && fn[0] == "function"
  params = []
  slots = {}
  pre = []
  loopform = nil
  fn.each do |item|
    next unless item.is_a?(Array)
    case item[0]
    when "params" then params = item[1..-1]
    when "slot"
      key = item[1].is_a?(Array) ? item[1][1] : item[1]
      slots[key] = item[2]
    when "store" then pre << item
    when "block"
      item[1..-1].each do |s|
        if s.is_a?(Array) && s[0] == "store"
          pre << s
        elsif s.is_a?(Array) && s[0] == "loop"
          loopform = s
        else
          refuse("function prologue has a #{s.is_a?(Array) ? s[0] : s}")
        end
      end
    end
  end
  refuse("function takes #{params.size} params, want 4") unless params.size == 4
  kinds = params.map { |p| p[3] }
  refuse("params are not (ptr short) (ptr (const short)) x2 int") unless
    kinds[0] == ["ptr", "short"] &&
    kinds[1] == ["ptr", ["const", "short"]] &&
    kinds[2] == ["ptr", ["const", "short"]] &&
    kinds[3] == "int"
  # Map each param register to its slot via the prologue stores.
  reg_slot = {}
  pre.each do |s|
    next unless s[0] == "store" && slot_ref?(s[2]) && s[3].is_a?(String)
    reg_slot[s[3]] = slot_name(s[2])
  end
  dst = reg_slot[params[0][1]]
  a = reg_slot[params[1][1]]
  b = reg_slot[params[2][1]]
  n = reg_slot[params[3][1]]
  refuse("params are not all spilled to slots") if dst.nil? || a.nil? || b.nil? || n.nil?
  refuse("no loop") if loopform.nil?
  body = nil
  step = nil
  loopform[1..-1].each do |s|
    next unless s.is_a?(Array)
    body = s if s[0] == "body"
    step = s if s[0] == "step"
  end
  refuse("loop has no body") if body.nil?
  refuse("loop has no step") if step.nil?
  # Counter: zero store then step of (wadd i 1).
  islot = nil
  pre.each do |s|
    if s[3].is_a?(Array) && s[3][0] == "const" && s[3][2] == "0" && slots[slot_name(s[2])] == "int"
      islot = slot_name(s[2])
    end
  end
  refuse("no zero-initialized int counter") if islot.nil?
  # Step must be i = i + 1 (wadd by const 1), possibly through let registers.
  step_lets = {}
  step[1..-1].each do |s|
    step_lets[s[1]] = s[3] if s.is_a?(Array) && s[0] == "let"
  end
  step_resolve = lambda do |x|
    while x.is_a?(String) && step_lets.key?(x)
      x = step_lets[x]
    end
    if x.is_a?(Array) && x[0] == "load" && slot_ref?(x[2])
      x = x[2]
    end
    x
  end
  ok_step = step[1..-1].any? do |s|
    next false unless s.is_a?(Array) && s[0] == "store" && s[2] == "$#{islot}"
    v = step_resolve.call(s[3])
    v.is_a?(Array) && v[0] == "wadd" &&
      step_resolve.call(v[2]) == "$#{islot}" &&
      v[3].is_a?(Array) && v[3][0] == "const" && v[3][2] == "1"
  end
  refuse("loop step is not i = i + 1") unless ok_step
  # Body lets are visible to the bound check and the compute block.
  body_lets = {}
  body[1..-1].each do |s|
    body_lets[s[1]] = s[3] if s.is_a?(Array) && s[0] == "let"
  end
  body_resolve = lambda do |x|
    while x.is_a?(String) && body_lets.key?(x)
      x = body_lets[x]
    end
    if x.is_a?(Array) && x[0] == "load" && slot_ref?(x[2])
      x = x[2]
    end
    x
  end
  # The bound check: (if COND (then) (else (break))) with COND resolving to
  # (lt.s int COUNTER BOUND) over the counter slot and the n slot.
  cond = body[1..-1].find { |s| s.is_a?(Array) && s[0] == "if" }
  refuse("no bound check") if cond.nil?
  cmp = body_resolve.call(cond[1])
  refuse("bound check is not lt.s") unless cmp.is_a?(Array) && cmp[0] == "lt.s"
  ops = [cmp[2], cmp[3]].map { |o| body_resolve.call(o) }
  refuse("bound check does not compare the counter against a slot") unless
    ops.include?("$#{islot}") && ops.include?("$#{n}")
  comp = body[1..-1].find { |s| s.is_a?(Array) && s[0] == "block" }
  refuse("loop body has no compute block") if comp.nil?
  comp = comp[1..-1]
  # Collect lets: reg -> value form. Resolve loads through to slots.
  lets = {}
  body_lets.each { |k, v| lets[k] = v }
  comp.each do |s|
    lets[s[1]] = s[3] if s.is_a?(Array) && s[0] == "let"
  end
  resolve = lambda do |x|
    while x.is_a?(String) && lets.key?(x)
      x = lets[x]
    end
    if x.is_a?(Array) && x[0] == "load"
      op = resolve.call(x[2])
      if slot_ref?(op)
        x = op
      elsif op.is_a?(Array) && op[0] == "index"
        x = op
      end
    end
    x
  end
  # The single store: (store short DST (iconv short (wadd A B))) with
  # DST = (index $dst i), A/B = widened (load (index $a/$b i)); or the
  # multiply-shift shape (iconv short (cshr int (wmul A B) (const K))).
  # Returns [:add] or [:mul, shift].
  found = nil
  comp.each do |s|
    next unless s.is_a?(Array) && s[0] == "store"
    v = resolve.call(s[3])
    next unless v.is_a?(Array) && v[0] == "iconv" && v[1] == "short"
    w = resolve.call(v[2])
    shift = nil
    if w.is_a?(Array) && w[0] == "cshr" && w[3].is_a?(Array) && w[3][0] == "const"
      shift = w[3][2]
      w = resolve.call(w[2])
    end
    next unless w.is_a?(Array) && (w[0] == "wadd" || w[0] == "wmul")
    next if shift.nil? != (w[0] == "wadd")
    l = resolve.call(w[2])
    r = resolve.call(w[3])
    next unless l.is_a?(Array) && l[0] == "iconv" && r.is_a?(Array) && r[0] == "iconv"
    d = resolve.call(s[2])
    next unless d.is_a?(Array) && d[0] == "index"
    la = resolve.call(l[2])
    lb = resolve.call(r[2])
    next unless la.is_a?(Array) && la[0] == "index" && lb.is_a?(Array) && lb[0] == "index"
    # index forms: (index BASE IDX 2); base resolves to the right slot, idx to the counter.
    db = resolve.call(d[1])
    ab = resolve.call(la[1])
    bb = resolve.call(lb[1])
    di = resolve.call(d[2])
    ai = resolve.call(la[2])
    bi = resolve.call(lb[2])
    next unless db == "$#{dst}" && ab == "$#{a}" && bb == "$#{b}"
    next unless di == "$#{islot}" && ai == "$#{islot}" && bi == "$#{islot}"
    next unless d[3] == "2" && la[3] == "2" && lb[3] == "2"
    if shift.nil?
      found = [:add]
    else
      refuse("shift #{shift} is not a constant int") unless int_const?(shift)
      found = [:mul, shift.to_i]
    end
  end
  refuse("loop body is not a[i]+b[i] narrowed into dst[i]") unless found
  [dst, a, b, n, found]
end

src = if ARGV[0].nil? || ARGV[0] == "-"
        $stdin.read
      else
        File.open(ARGV[0], "rb") { |f| f.read }
      end
begin
  forms = parse(src)
  mod = forms.find { |f| f.is_a?(Array) && f[0] == "ir-module" }
  refuse("no ir-module form") if mod.nil?
  fns = forms.select { |f| f.is_a?(Array) && f[0] == "function" }
  refuse("module has no functions") if fns.empty?
  out = []
  out << "typedef int V128 __attribute__((__vector_size__(128), __aligned__(128)));"
  out << "typedef int P256 __attribute__((__vector_size__(256), __aligned__(256)));"
  fns.each do |fn|
    kind = nil
    begin
      _dst, _a, _b, _n, kind = match_loop_fn(fn)
    rescue Refused => e
      fname = fn[1].is_a?(Array) ? fn[1][1] : fn[1]
      refuse("function #{fname}: #{e.message}")
    end
    if kind[0] == :add
      out << "__attribute__((noinline)) void hvx_vec_add_i16(short *dst, const short *a, const short *b, int n) {"
      out << "  int i = 0;"
      out << "  for (; i + 64 <= n; i += 64) {"
      out << "    V128 va = *(const V128 *)(a + i);"
      out << "    V128 vb = *(const V128 *)(b + i);"
      out << "    *(V128 *)(dst + i) = __builtin_HEXAGON_V6_vaddh_128B(va, vb);"
      out << "  }"
      out << "  for (; i < n; ++i) dst[i] = (short)(a[i] + b[i]);"
      out << "}"
    else
      k = kind[1]
      out << "__attribute__((noinline)) void hvx_vec_mul_i16(short *dst, const short *a, const short *b, int n) {"
      out << "  int wtmp[64] __attribute__((aligned(256)));"
      out << "  int i = 0;"
      out << "  for (; i + 64 <= n; i += 64) {"
      out << "    V128 va = *(const V128 *)(a + i);"
      out << "    V128 vb = *(const V128 *)(b + i);"
      out << "    *(P256 *)wtmp = __builtin_HEXAGON_V6_vmpyhv_128B(va, vb);"
      out << "    V128 v0 = *(const V128 *)wtmp, v1 = *(const V128 *)((const char *)wtmp + 128);"
      out << "    *(V128 *)(dst + i) = (V128)__builtin_HEXAGON_V6_vasrwh_128B(v1, v0, #{k});"
      out << "  }"
      out << "  for (; i < n; ++i) dst[i] = (short)((a[i] * b[i]) >> #{k});"
      out << "}"
    end
  end
  puts out.join("\n")
rescue Refused => e
  $stderr.puts "refused: #{e.message}"
  exit 3
rescue BadIR => e
  $stderr.puts "pathb-hvx-emit: bad IR: #{e.message}"
  exit 1
end
