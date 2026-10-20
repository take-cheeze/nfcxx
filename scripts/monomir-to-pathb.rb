#!/usr/bin/env ruby
# monomir-to-pathb.rb: translate mrustc monomir (.mir) to Path B IR (.ir)
abort "usage: #{$0} INPUT.mir [OUTPUT.ir]" if ARGV.empty?
input = ARGV[0]
outpath = ARGV[1]
src = File.read(input)

types = {}
src.scan(/^type (.+?) \{\n(.*?)\n\}/m) do |name, body|
  size = 0; align = 1; fields = []; drop = nil; tag = nil
  # tag encoding block is multiline: @[FIELD, SUB] = { "BYTES" =IDX, ... * =IDX, ... }
  m = body.match(/@\[(\d+),\s*([^\]]*)\] = \{(.*?)\}/m)
  if m
    tagfield = m[1].to_i; tagsub = m[2].strip; tagbody = m[3]
    arms = []
    tagbody.scan(/("(?:\\.|[^"\\])*"|\*)\s*(?:=\s*(\d+))?/) do |val, idx|
      arms << {val: val, idx: idx.nil? || idx.empty? ? nil : idx.to_i}
    end
    tag = {field: tagfield, sub: tagsub, arms: arms}
    body = body.sub(m[0], "")
  end
  body.each_line do |ln|
    ln = ln.strip
    m = ln.match(/^SIZE (\d+), ALIGN (\d+);/)
    if m
      size = m[1].to_i; align = m[2].to_i; next
    end
    m = ln.match(/^DROP (\S+);$/)
    if m
      drop = m[1].strip; next
    end
    m = ln.match(/^(\d+) = (.+);$/)
    if m
      fields << {off: m[1].to_i, type: m[2].strip}
    end
  end
  types[name.strip] = {size: size, align: align, fields: fields, drop: drop, tag: tag}
end

def split_top(s)
  res = []; depth = 0; cur = ""; instr = false; esc = false
  s.each_char do |c|
    if instr
      cur << c
      if esc
        esc = false
      elsif c == "\\"
        esc = true
      elsif c == "\""
        instr = false
      end
      next
    end
    if c == "\""
      instr = true; cur << c
    elsif c == "(" || c == "[" || c == "{" || c == "<"
      depth += 1; cur << c
    elsif c == ")" || c == "]" || c == "}"
      depth -= 1; cur << c
    elsif c == ">"
      if cur.size > 0 && cur[-1] != "-"
        depth -= 1
      end
      cur << c
    elsif c == "," && depth == 0
      res << cur.strip; cur = ""
    else
      cur << c
    end
  end
  res << cur.strip unless cur.strip.empty?
  res
end

def parse_params_str(s)
  s = s.strip
  return [] if s.empty?
  split_top(s)
end

def fat_rest?(rest)
  rest = rest.strip
  return true if rest == "str"
  return true if rest.start_with?("dyn")
  if rest.start_with?("[") && rest.end_with?("]")
    inner = rest[1...-1].strip
    return true unless inner.include?(";")
  end
  false
end

def type_size_align(ty, types)
  ty = ty.strip
  case ty
  when "i8","u8","bool" then return [1,1]
  when "i16","u16" then return [2,2]
  when "i32","u32","f32","char" then return [4,4]
  when "i64","u64","f64","isize","usize" then return [8,8]
  when "()" then return [0,1]
  end
  if ty.start_with?("&") || ty.start_with?("*const") || ty.start_with?("*mut") || ty.start_with?("*move")
    rest = ty.sub(/^&mut\s+|^&move\s+|^&\s*|^\*const\s+|^\*mut\s+|^\*move\s+/, "")
    if fat_rest?(rest)
      return [16, 8]
    end
    return [8,8]
  end
  if ty.start_with?("[") && ty.include?(";")
    inner, n = ty[1...-1].split(";", 2).map(&:strip)
    es, ea = type_size_align(inner, types)
    n = n.to_i
    return [es * n, ea]
  end
  if ty.start_with?("[") && ty.end_with?("]")
    return [16, 8]
  end
  if ty.start_with?("fn")
    return [8,8]
  end
  if types.key?(ty)
    t = types[ty]
    return [t[:size], t[:align]]
  end
  [8,8]
end

def rust_type_to_pathb(ty, types)
  ty = ty.strip
  case ty
  when "i8" then "signed_char"
  when "u8" then "unsigned_char"
  when "i16" then "short"
  when "u16" then "unsigned_short"
  when "i32" then "int"
  when "u32" then "unsigned_int"
  when "i64" then "long"
  when "u64" then "unsigned_long"
  when "isize" then "long"
  when "usize" then "unsigned_long"
  when "f32" then "float"
  when "f64" then "double"
  when "bool" then "bool"
  when "char" then "unsigned_int"
  when "()" then "void"
  when "!" then "void"
  else
    if ty.start_with?("&") || ty.start_with?("*const") || ty.start_with?("*mut") || ty.start_with?("*move")
      rest = ty.sub(/^&mut\s+|^&move\s+|^&\s*|^\*const\s+|^\*mut\s+|^\*move\s+/, "")
      if fat_rest?(rest)
        return "(struct #{ty.inspect})"
      end
      return "(ptr #{rust_type_to_pathb(rest, types)})"
    end
    if ty.start_with?("[")
      if ty.include?(";")
        inner, n = ty[1...-1].split(";", 2).map(&:strip)
        return "(array #{n.to_i} #{rust_type_to_pathb(inner, types)})"
      else
        inner = ty[1...-1].strip
        return "(array ? #{rust_type_to_pathb(inner, types)})"
      end
    end
    if ty.include?("fn") && (ty.include?("extern") || ty.include?("unsafe") || ty.strip.start_with?("fn"))
      return "(fn void ())"
    end
    "(struct #{ty.inspect})"
  end
end

def parse_fn_header(header)
  header = header.strip
  m = header.match(/^(\S+?)\s*\((.*)\)\s*:\s*(.+)$/)
  name = pb_sym(m[1])
  name = "main" if name == "main#"
  name = "panic_impl" if name == "panic_impl#" || name.start_with?("panic_impl#")
  params_str = m[2]
  ret = m[3].strip
  ret = ret.sub(/\s*=.*$/, "").strip
  [name, params_str, ret]
end

def program_item?(name)
  name.include?("D3bin") || name == "main" || name == "main#" || name.start_with?("panic_impl")
end

def static_type(name)
  return nil unless $statics_types
  $statics_types[name]
end

def local_type(name, locals, params)
  if name == "retval" || name == "$\"retval\""
    return $cur_ret
  end
  st = static_type(name)
  return st unless st.nil?
  t = nil
  locals.each { |n, ty| t = ty if n == name }
  if t.nil? && name.start_with?("arg")
    i = name.sub("arg", "").to_i
    t = params[i] if i < params.size
  end
  t
end

def parse_place(expr)
  s = expr.strip
  s = s[1..-1].strip if s.start_with?("=")
  events = []
  loop do
    m = s.match(/^(.*)\.(\d+)$/)
    if m
      events << {k: :field, idx: m[2].to_i}
      s = m[1].strip
      next
    end
    m = s.match(/^(.*)@(\d+)$/)
    if m
      events << {k: :downcast, idx: m[2].to_i}
      s = m[1].strip
      next
    end
    m = s.match(/^(.*)\[([A-Za-z0-9_]+)\]$/)
    if m
      events << {k: :index, idx: m[2].strip}
      s = m[1].strip
      next
    end
    if s.start_with?("(*") && s.end_with?(")")
      s = s[2..-2].strip
      events << {k: :deref}
      next
    end
    break
  end
  ops = events.reverse
  nderef = ops.count { |o| o[:k] == :deref }
  pre_deref = []
  post_deref = []
  seen_deref = false
  ops.each do |o|
    if o[:k] == :deref
      seen_deref = true
      next
    end
    if seen_deref
      post_deref << o
    else
      pre_deref << o
    end
  end
  {root: s, derefs: nderef, wrappers: pre_deref + post_deref, inner: pre_deref, outer: post_deref, ops: ops}
end

def type_deref_once(ty, types)
  ty = ty.strip
  m = ty.match(/^(?:&mut\s+|&move\s+|&\s*|\*const\s+|\*mut\s+|\*move\s+)(.+)$/)
  if m
    rest = m[1].strip
    if fat_rest?(rest)
      if rest.start_with?("[")
        inner = rest[1...-1].strip
        return [inner, :slice_elem] unless inner.include?(";")
      end
      return [nil, :fat]
    end
    return [rest, nil]
  end
  if ty.start_with?("[") && ty.include?(";")
    inner, _ = ty[1...-1].split(";", 2).map(&:strip)
    return [inner, :array_elem]
  end
  if ty.start_with?("[") && ty.end_with?("]")
    return [ty[1...-1].strip, :slice_elem]
  end
  [nil, nil]
end

def field_offset_and_type(ty, idx, types)
  ty = ty.strip
  if types.key?(ty)
    f = types[ty][:fields][idx]
    return [f[:off], f[:type]] if f
    return [idx * 8, nil]
  end
  if ty.start_with?("[") && ty.include?(";")
    inner, _ = ty[1...-1].split(";", 2).map(&:strip)
    es, _ = type_size_align(inner, types)
    return [idx * es, inner]
  end
  if ty.start_with?("[") && ty.end_with?("]")
    return [0, nil]
  end
  [idx * 8, nil]
end

def apply_wrapper_ty(cur, w, types)
  case w[:k]
  when :field
    _, ft = field_offset_and_type(cur || "", w[:idx], types)
    return nil if ft.nil?
    ft.strip
  when :downcast
    if cur && types.key?(cur)
      vf = types[cur][:fields][w[:idx]]
      return nil if vf.nil?
      vf[:type].strip
    else
      nil
    end
  when :index
    inner, _ = type_deref_once(cur || "", types)
    return nil if inner.nil?
    inner.strip
  end
end

def place_type(expr, types, locals, params)
  p = parse_place(expr)
  t = nil
  if p[:root].start_with?("STATIC_") || (p[:root] =~ /^[A-Z]/ && local_type(p[:root], locals, params).nil?)
    return nil
  end
  t = local_type(p[:root], locals, params)
  return nil if t.nil?
  cur = t.strip
  (p[:ops] || p[:wrappers]).each do |w|
    if w[:k] == :deref
      inner, _ = type_deref_once(cur, types)
      return nil if inner.nil?
      cur = inner.strip
    else
      cur = apply_wrapper_ty(cur, w, types)
      return nil if cur.nil?
    end
  end
  cur
end

def place_root_addr(root, types, locals, params, param_reg, stmts, regi)
  if root == "$\"retval\"" || root == "retval"
    return ["$\"retval\"", regi]
  end
  if static_type(root)
    return ["@\"#{pb_sym(root)}\"", regi]
  end
  known = locals.map(&:first).include?(root) || (root.start_with?("arg") && local_type(root, locals, params))
  unless known
    if root.match(/^[A-Z]/) && root.match(/^[A-Za-z0-9_]+$/)
      return ["@\"#{pb_sym(root)}\"", regi]
    end
  end
  ["$\"#{root}\"", regi]
end

def apply_wrapper_addr(addr, cur_ty, w, types, locals, params, stmts, regi)
  case w[:k]
  when :field
    off, ft = field_offset_and_type(cur_ty || "", w[:idx], types)
    if off != 0
      fpt = ft ? rust_type_to_pathb(ft, types) : "unsigned_long"
      r = regi; regi += 1
      stmts << "(let %#{r} (ptr #{fpt}) (offset #{addr} #{off}))"
      addr = "%#{r}"
    end
    [addr, ft, regi]
  when :downcast
    if cur_ty && types.key?(cur_ty)
      vf = types[cur_ty][:fields][w[:idx]]
      cur_ty = vf ? vf[:type].strip : nil
      [addr, cur_ty, regi]
    else
      [addr, nil, regi]
    end
  when :index
    inner, _ = type_deref_once(cur_ty || "", types)
    if inner.nil? && cur_ty && !cur_ty.empty?
      inner = cur_ty.strip
    end
    es = 8
    ept = "unsigned_long"
    if inner
      es, _ = type_size_align(inner, types)
      ept = rust_type_to_pathb(inner, types)
    end
    idxv = w[:idx]
    irm = idxv.match(/^(\d+)$/)
    if irm
      off = irm[1].to_i * es
      if off != 0
        r = regi; regi += 1
        stmts << "(let %#{r} (ptr #{ept}) (offset #{addr} #{off}))"
        addr = "%#{r}"
      end
    else
      it = local_type(idxv, locals, params)
      ipt = it ? rust_type_to_pathb(it, types) : "unsigned_long"
      r0 = regi; regi += 1
      stmts << "(let %#{r0} #{ipt} (load #{ipt} $\"#{idxv}\"))"
      r2 = regi; regi += 1
      stmts << "(let %#{r2} (ptr #{ept}) (index #{addr} %#{r0} #{es}))"
      addr = "%#{r2}"
    end
    [addr, inner, regi]
  end
end

def place_addr(expr, types, locals, params, param_reg, stmts, regi, want_type = false)
  p = parse_place(expr)
  base, regi = place_root_addr(p[:root], types, locals, params, param_reg, stmts, regi)
  cur_ty = local_type(p[:root], locals, params)
  cur_ty = cur_ty.strip unless cur_ty.nil?
  addr = base
  addr_ty = cur_ty
  (p[:ops] || p[:wrappers]).each do |w|
    if w[:k] == :deref
      inner, kind = type_deref_once(cur_ty || "", types)
      if inner.nil?
        r = regi; regi += 1
        stmts << "(let %#{r} (ptr unsigned_long) (load (ptr unsigned_long) #{addr}))"
        addr = "%#{r}"
        addr_ty = nil
        cur_ty = nil
      elsif kind == :slice_elem || kind == :array_elem
        et = inner
        es, _ = type_size_align(et, types)
        ept = rust_type_to_pathb(et, types)
        r = regi; regi += 1
        stmts << "(let %#{r} (ptr #{ept}) (load (ptr #{ept}) #{addr}))"
        addr = "%#{r}"
        addr_ty = et
        cur_ty = et
      else
        ipt = rust_type_to_pathb(inner, types)
        r = regi; regi += 1
        stmts << "(let %#{r} (ptr #{ipt}) (load (ptr #{ipt}) #{addr}))"
        addr = "%#{r}"
        addr_ty = inner
        cur_ty = inner
      end
    else
      addr, cur_ty, regi = apply_wrapper_addr(addr, cur_ty, w, types, locals, params, stmts, regi)
      addr_ty = cur_ty
    end
  end
  if want_type
    return [addr, addr_ty, regi]
  end
  [addr, regi]
end

def place_load(expr, types, locals, params, param_reg, stmts, regi)
  addr, fty, regi = place_addr(expr, types, locals, params, param_reg, stmts, regi, true)
  pt = fty ? rust_type_to_pathb(fty, types) : "unsigned_long"
  if pt == "void" || fty == "()" || fty == "!"
    return ["(const unsigned_char 0)", "unsigned_char", regi]
  end
  if fty.nil?
    r = regi; regi += 1
    stmts << "(let %#{r} unsigned_long (load unsigned_long #{addr}))"
    return ["%#{r}", "unsigned_long", regi]
  end
  if pt.start_with?("(") && !pt.start_with?("(ptr") && !pt.start_with?("(fn")
    return [addr, pt, regi]
  end
  r = regi; regi += 1
  stmts << "(let %#{r} #{pt} (load #{pt} #{addr}))"
  ["%#{r}", pt, regi]
end

def store_place(expr, val, vty, types, locals, params, param_reg, stmts, regi)
  addr, fty, regi = place_addr(expr, types, locals, params, param_reg, stmts, regi, true)
  sz = 8
  if fty
    sz, _ = type_size_align(fty, types)
    sz = 1 if sz == 0
  end
  return regi if sz == 0
  pt = fty ? rust_type_to_pathb(fty, types) : (vty || "unsigned_long")
  return regi if pt == "void"
  if pt.start_with?("(") && !pt.start_with?("(ptr") && !pt.start_with?("(fn")
    stmts << "(copy #{sz} #{addr} #{val})"
  else
    stmts << "(store #{pt} #{addr} #{val})"
  end
  regi
end

def unescape_mir(s)
  out = []
  i = 0
  n = s.bytesize
  while i < n
    c = s[i]
    if c == "\\"
      if i + 1 < n
        e = s[i+1]
        if e == "n"
          out << 10; i += 2; next
        elsif e == "t"
          out << 9; i += 2; next
        elsif e == "r"
          out << 13; i += 2; next
        elsif e == "\\" || e == "\""
          out << e.ord; i += 2; next
        elsif e == "x"
          if i + 3 < n
            out << s[i+2,2].to_i(16); i += 4; next
          end
        elsif e >= "0" && e <= "7"
          # octal up to 3 digits
          oct = s[i+1,3].match(/^[0-7]+/)&.to_s || ""
          out << oct.to_i(8); i += 1 + oct.length; next
        end
      end
      out << c.ord; i += 1
    else
      out << c.ord; i += 1
    end
  end
  out
end

def encode_pb_str(bytes)
  res = ""
  bytes.each do |b|
    if b == 10
      res << "\\n"
    elsif b == 34
      res << "\\\""
    elsif b == 92
      res << "\\\\"
    elsif b >= 32 && b <= 126
      res << b.chr
    else
      res << "\\%03o" % b
    end
  end
  res
end

statics = []
src.scan(/^static (.+?): (.+?) = (.*?);\n/m) do |name, ty, init|
  statics << {name: name.strip, type: ty.strip, init: init.strip}
end
$statics_names = statics.map { |st| st[:name] }
$statics_types = {}
statics.each { |st| $statics_types[st[:name]] = st[:type] }

fn_path_map = {}
src.scan(/\/\* (.+?) \*\/\nfn (\S+?)\(/) do |comment, fname|
  fn_path_map[comment.strip] = fname.strip
end
$fn_path_map = fn_path_map

src.scan(/^fn \S+?\(.*?\)\s*:\s*.+? \{\n(.*?)\n\}/m) do |m|
  body = m[0]
  var_fn_ty = {}
  body.scan(/^\tlet (var\d+): fn (\S+?);$/) { |v, t| var_fn_ty[v] = t }
  body.scan(/^\t\tASSIGN (var\d+) = fn (.+);$/) do |v, path|
    if var_fn_ty[v]
      $fn_path_map[path.strip] ||= var_fn_ty[v]
    end
  end
end

def resolve_fn_item(expr)
  m = expr.strip.match(/^fn (.+)$/)
  return nil if m.nil?
  ($fn_path_map || {})[m[1].strip]
end

def pb_sym(name)
  name.gsub("$", "__DOLLAR__")
end

def abi_leaves(ty, types, base_off = 0)
  ty = ty.strip
  case ty
  when "i8", "u8", "bool" then return [[base_off, "b"]]
  when "i16", "u16" then return [[base_off, "h"]]
  when "i32", "u32", "f32", "char" then return [[base_off, ty == "f32" ? "s" : "w"]]
  when "i64", "u64", "f64", "isize", "usize" then return [[base_off, ty == "f64" ? "d" : "l"]]
  when "()", "!" then return []
  end
  if ty.start_with?("&") || ty.start_with?("*const") || ty.start_with?("*mut") || ty.start_with?("*move")
    rest = ty.sub(/^&mut\s+|^&move\s+|^&\s*|^\*const\s+|^\*mut\s+|^\*move\s+/, "")
    if fat_rest?(rest)
      return [[base_off, "l"], [base_off + 8, "l"]]
    end
    return [[base_off, "l"]]
  end
  if ty.start_with?("[") && ty.include?(";")
    inner, n = ty[1...-1].split(";", 2).map(&:strip)
    es, _ = type_size_align(inner, types)
    out = []
    n.to_i.times do |i|
      sub = abi_leaves(inner, types, base_off + i * es)
      return nil if sub.nil?
      out.concat(sub)
    end
    return out
  end
  if ty.start_with?("[") && ty.end_with?("]")
    return [[base_off, "l"], [base_off + 8, "l"]]
  end
  if ty.start_with?("fn")
    return [[base_off, "l"]]
  end
  if types.key?(ty)
    t = types[ty]
    return [] if t[:size] == 0
    out = []
    t[:fields].each do |f|
      sub = abi_leaves(f[:type], types, base_off + f[:off])
      return nil if sub.nil?
      out.concat(sub)
    end
    return out
  end
  nil
end

def abi_shape(ty, types)
  ty = ty.strip
  sz, al = type_size_align(ty, types)
  return ["empty", nil] if sz == 0
  return ["memory", nil] if sz > 16
  leaves = abi_leaves(ty, types, 0)
  return ["memory", nil] if leaves.nil?
  leaves = leaves.sort_by(&:first)
  classes = []
  [0, 8].each do |base|
    chunk = leaves.select { |off, _| off >= base && off < base + 8 }
    if chunk.empty?
      classes << nil
      next
    end
    kinds = chunk.map(&:last).uniq
    if kinds.include?("d") || kinds.include?("s")
      if chunk.any? { |off, k| (k == "l" || k == "w" || k == "h" || k == "b") }
        return ["memory", nil]
      end
      classes << "sse"
    else
      classes << "int"
    end
  end
  if classes.all?(&:nil?)
    return ["empty", nil]
  end
  if classes.compact.size == 1 && sz <= 8
    k = leaves.first[1]
    return ["one", k]
  end
  ["two", classes]
end

$abi_table = {}

def abi_form(ty, types)
  return nil if ty.nil?
  key = ty.strip
  return $abi_table[key] if $abi_table.key?(key)
  shape, extra = abi_shape(key, types)
  sz, al = type_size_align(key, types)
  al = 8 if al > 8
  al = 1 if al < 1
  form = nil
  if shape == "memory" || shape == "empty"
    form = "(#{shape})"
  else
    leaves = abi_leaves(key, types, 0)
    if leaves.nil? || leaves.empty?
      form = "(empty)"
    else
      by8 = {}
      leaves.each do |off, k|
        b = (off / 8) * 8
        by8[b] ||= []
        by8[b] << k
      end
      mem = false
      parts = []
      by8.keys.sort.each do |b|
        ks = by8[b].uniq
        has_fp = ks.any? { |k| k == "s" || k == "d" }
        has_int = ks.any? { |k| k == "l" || k == "w" || k == "h" || k == "b" }
        if has_fp && has_int
          mem = true
          break
        end
        rem = sz - b
        if has_fp
          k = rem >= 8 ? "d" : "s"
        else
          k = rem >= 8 ? "l" : (rem >= 4 ? "w" : (rem >= 2 ? "h" : "b"))
        end
        parts << "(leaf #{b} #{k})"
      end
      if mem
        form = "(memory)"
      else
        form = parts.join(" ")
      end
    end
  end
  $abi_table[key] = form
  form
end

functions = []
src.scan(/^fn (.+?)\s*\{\n(.*?)\n\}/m) do |header, body|
  functions << {header: header.strip, body: body}
end
$extern_map = {}
src.scan(/^fn ([^\n]+?) = ([^\n]*?);\n/) do |header, linkage|
  functions << {header: header.strip, body: nil, linkage: linkage.strip}
  hm = header.strip.match(/^(\S+?)\s*\(/)
  lm = linkage.strip.match(/^"([^"]+)"/)
  if hm && lm
    $extern_map[pb_sym(hm[1])] = lm[1]
  end
end

lines = []
lines << "(ir-module \"#{File.basename(input)}\" (layout (short 2) (int 4) (long 8) (long_long 8) (pointer 8) (float 4) (double 8) (long_double 16)))"

types.each do |tname, tinfo|
  next if tname.start_with?("*") || tname.start_with?("[") || tname.start_with?("fn")
  next if ["i8", "u8", "i16", "u16", "i32", "u32", "i64", "u64", "isize", "usize", "f32", "f64", "bool", "char", "(", "!"].any? { |p| tname == p || tname.start_with?(p) }
  sz = tinfo[:size]; al = tinfo[:align]
  al = 8 if al > 8
  al = 1 if al < 1
  form = abi_form(tname, types)
  next if form.nil?
  lines << "(abi-type #{tname.inspect} #{sz} #{al} #{form})"
end

$fat_types = {}
def note_fat(ty, types)
  return unless ty
  ty = ty.strip
  return unless ty.start_with?("&")
  rest = ty.sub(/^&mut\s+|^&move\s+|^&\s*/, "")
  return unless fat_rest?(rest)
  $fat_types[ty] = true
end

src.scan(/^\tlet \S+: (&[^\n;]+);$/) { |m| note_fat(m[0], types) }
src.scan(/^fn \S+?\((.*?)\)\s*:/) { |m| m[0].split(",").each { |p| note_fat(p.strip, types) } }
$fat_types.each_key do |ft|
  lines << "(abi-type #{ft.inspect} 16 8 (leaf 0 l) (leaf 8 l))"
end

statics.each do |st|
  sname = pb_sym(st[:name])
  ty = st[:type]
  size, align = type_size_align(ty, types)
  align = 1 if align == 0
  size = 0 if size < 0
  pathb_ty = rust_type_to_pathb(ty, types)
  init = st[:init]
  base = init[/^"(.*)"\{/m, 1]
  base = "" if base.nil?
  base_bytes = unescape_mir(base)
  relocs = []
  init.scan(/@(\d+)\+(\d+)\s*=\s*("(?:\\.|[^"\\])*"|[^,}]+)/) do |off, len, target|
    relocs << [off.to_i, len.to_i, target.strip]
  end
  # covered ranges by relocations
  covered = Array.new(size, false)
  relocs.each do |off, len, target|
    (off...(off+len)).each { |i| covered[i] = true if i < size }
  end
  items = []
  # bytes segments for uncovered ranges
  i = 0
  while i < size
    if covered[i]
      i += 1; next
    end
    j = i
    while j < size && !covered[j]
      j += 1
    end
    seglen = j - i
    segbytes = base_bytes[i, seglen] || []
    segenc = encode_pb_str(segbytes)
    segname = "#{sname}_bytes#{i}"
    lines << "(data #{segname.inspect} (array #{seglen} (const char)) (string \"#{segenc}\"))"
    items << "(bytes #{i} #{seglen} @\"#{segname}\")"
    i = j
  end
  relocs.each do |off, len, target|
    if target.start_with?('"')
      tname = target.gsub(/^"|"$/, '')
      str_data = "#{sname}_str#{off}"
      lines << "(data #{str_data.inspect} (array #{tname.bytesize + 1} (const char)) (string \"#{tname}\"))"
      items << "(addr #{off} (ptr (const char)) @\"#{str_data}\" 0)"
    else
      items << "(addr #{off} (ptr (const char)) &\"#{pb_sym(target)}\" 0)"
    end
  end
  lines << "(global #{sname.inspect} #{pathb_ty} #{size} #{align} (weak) (init #{items.join(' ')}))"
end

def mir_unescape_str(s)
  unescape_mir(s)
end

def parse_hex_float(s)
  m = s.strip.match(/^([+-]?)0x([0-9A-Fa-f]*)\.?([0-9A-Fa-f]*)p([+-]?\d+)$/)
  return nil if m.nil?
  sign = m[1] == "-" ? -1.0 : 1.0
  intpart = m[2].empty? ? 0 : m[2].to_i(16)
  fracpart = m[3]
  frac = 0.0
  fracpart.each_char.with_index do |c, i|
    frac += c.to_i(16) * (16.0 ** -(i + 1))
  end
  exp = m[4].to_i
  sign * (intpart + frac) * (2.0 ** exp)
end

def pb_const_for_rust(ty, val, types)
  pt = rust_type_to_pathb(ty, types)
  if (pt == "float" || pt == "double") && val.match?(/[xXp]/)
    f = parse_hex_float(val) || val.to_f
    if pt == "float"
      f = [f].pack("f").unpack("f")[0]
    end
    val = f.to_s
    val += ".0" if val.match?(/\A-?\d+\z/)
  end
  "(const #{pt} #{val})"
end

def materialize_str(bytes, stmts, regi, lines)
  n = bytes.size
  data_name = "strlit_#{bytes.hash.abs}"
  unless lines.any? { |l| l.include?("(data #{data_name.inspect}") }
    lines << "(data #{data_name.inspect} (array #{n+1} (const char)) (string \"#{encode_pb_str(bytes)}\"))"
  end
  $lit_slots ||= []
  slot = "strtmp#{$lit_slots.size}"
  $lit_slots << "(slot #{slot.inspect} (struct \"&str\") 16 8)"
  r1 = regi; regi += 1
  stmts << "(let %#{r1} (ptr (const char)) &\"#{data_name}\")"
  stmts << "(store (ptr (const char)) $\"#{slot}\" %#{r1})"
  r2 = regi; regi += 1
  stmts << "(let %#{r2} unsigned_long (const unsigned_long #{n}))"
  r3 = regi; regi += 1
  stmts << "(let %#{r3} (ptr unsigned_long) (offset $\"#{slot}\" 8))"
  stmts << "(store unsigned_long %#{r3} %#{r2})"
  ["$\"#{slot}\"", regi]
end

def load_operand(expr, types, locals, params, param_reg, stmts, regi)
  expr = expr.strip
  m = expr.match(/^([+-]?(?:\d+|0x[0-9A-Fa-f.]+p[+-]?\d+))\s+([A-Za-z0-9_]+)$/)
  if m
    val = m[1].sub(/^\+/, ""); ty = m[2]
    return [pb_const_for_rust(ty, val, types), regi]
  end
  if expr == "true"
    return ["(const bool 1)", regi]
  end
  if expr == "false"
    return ["(const bool 0)", regi]
  end
  v, pt, regi = place_load(expr, types, locals, params, param_reg, stmts, regi)
  [v, regi]
end

def operand_pt(expr, types, locals, params)
  expr = expr.strip
  m = expr.match(/^([+-]?\d+)\s+([A-Za-z0-9_]+)$/)
  if m
    return rust_type_to_pathb(m[2], types)
  end
  return "bool" if expr == "true" || expr == "false"
  pt = place_type(expr, types, locals, params)
  pt ? rust_type_to_pathb(pt, types) : nil
end

def coerce_to(ty, v, vpt, stmts, regi)
  return [v, regi] if vpt == ty
  if v.start_with?("(const")
    m = v.match(/^\(const \S+ (.+)\)$/)
    if m
      return ["(const #{ty} #{m[1]})", regi]
    end
    return [v, regi]
  end
  r = regi; regi += 1
  if (ty == "float" || ty == "double") != ((vpt || "").include?("float") || (vpt || "") == "double")
    if ty == "float" || ty == "double"
      op = (vpt || "").include?("unsigned") ? "u2f" : "i2f"
      stmts << "(let %#{r} #{ty} (#{op} #{ty} #{v}))"
    else
      op = (vpt || "") == "float" ? "f2i" : "d2i"
      op = op + ".s" unless ty.include?("unsigned")
      stmts << "(let %#{r} #{ty} (#{op} #{ty} #{v}))"
    end
  else
    stmts << "(let %#{r} #{ty} (iconv #{ty} #{v}))"
  end
  ["%#{r}", regi]
end

def const_int_value(expr)
  m = expr.strip.match(/^([+-]?\d+)\s+([A-Za-z0-9_]+)$/)
  return nil if m.nil?
  [m[1].sub(/^\+/, ""), m[2]]
end

def eval_binop(op, l, r, types, locals, params, param_reg, stmts, regi, hint_ty = nil)
  lt, regi = load_operand(l, types, locals, params, param_reg, stmts, regi)
  rt, regi = load_operand(r, types, locals, params, param_reg, stmts, regi)
  ty = hint_ty || "int"
  lc = const_int_value(l)
  rc = const_int_value(r)
  if hint_ty.nil?
    if lc
      ty = rust_type_to_pathb(lc[1], types)
    elsif rc
      ty = rust_type_to_pathb(rc[1], types)
    else
      lt2 = place_type(l, types, locals, params)
      ty = rust_type_to_pathb(lt2, types) unless lt2.nil?
    end
  end
  lpt = operand_pt(l, types, locals, params)
  rpt = operand_pt(r, types, locals, params)
  lt, regi = coerce_to(ty, lt, lpt, stmts, regi)
  rt, regi = coerce_to(ty, rt, rpt, stmts, regi)
  unsigned = ty.include?("unsigned")
  code = case op
  when "+" then "(wadd #{ty} #{lt} #{rt})"
  when "-" then "(wsub #{ty} #{lt} #{rt})"
  when "*" then "(wmul #{ty} #{lt} #{rt})"
  when "/" then "(cdiv #{ty} #{lt} #{rt})"
  when "%" then "(crem #{ty} #{lt} #{rt})"
  when "&" then "(and #{ty} #{lt} #{rt})"
  when "|" then "(or #{ty} #{lt} #{rt})"
  when "^" then "(xor #{ty} #{lt} #{rt})"
  when "<<" then "(cshl #{ty} #{lt} #{rt})"
  when ">>" then "(cshr #{ty} #{lt} #{rt})"
  when "==" then "(eq #{ty} #{lt} #{rt})"
  when "!=" then "(ne #{ty} #{lt} #{rt})"
  when "<" then "(#{unsigned ? "lt.u" : "lt.s"} #{ty} #{lt} #{rt})"
  when "<=" then "(#{unsigned ? "le.u" : "le.s"} #{ty} #{lt} #{rt})"
  when ">" then "(#{unsigned ? "lt.u" : "lt.s"} #{ty} #{rt} #{lt})"
  when ">=" then "(#{unsigned ? "le.u" : "le.s"} #{ty} #{rt} #{lt})"
  end
  [code, ty, regi]
end

def eval_rvalue_operand(expr, types, locals, params, param_reg, stmts, regi, lines)
  expr = expr.strip
  if expr.start_with?("fn ")
    mangled = resolve_fn_item(expr)
    if mangled
      return ["&\"#{pb_sym(mangled)}\"", regi]
    end
  end
  if expr.start_with?('"') && expr.end_with?('"') && expr.length >= 2
    inner = expr[1...-1]
    bytes = unescape_mir(inner)
    return materialize_str(bytes, stmts, regi, lines)
  end
  m = expr.match(/^UNIOP\s+(!|-)\s+(.+)$/)
  if m
    op = m[1]; v = m[2].strip
    vt, regi = load_operand(v, types, locals, params, param_reg, stmts, regi)
    pt = place_type(v, types, locals, params)
    ty = pt ? rust_type_to_pathb(pt, types) : "int"
    ty = "int" if ty.start_with?("(")
    if op == "!"
      return ["(not #{ty} #{vt})", regi]
    else
      return ["(wneg #{ty} #{vt})", regi]
    end
  end
  m = expr.match(/^BINOP\s+(.+?)\s+(<=?|>=?|==|!=|<<|>>|[+\-*\/%&|^])\s+(.+)$/)
  if m
    code, ty, regi = eval_binop(m[2], m[1].strip, m[3].strip, types, locals, params, param_reg, stmts, regi, $binop_hint)
    return [code, regi]
  end
  if expr.start_with?("ADDROF")
    target = expr.sub(/^ADDROF\s+/, "").strip
    if $statics_names && $statics_names.include?(target)
      return ["@\"#{pb_sym(target)}\"", regi]
    end
    return ["&\"#{pb_sym(target)}\"", regi]
  end
  if expr.start_with?("&mut ") || expr.start_with?("&move ") || expr.start_with?("&")
    place = expr.sub(/^&mut\s+|^&move\s+|^&\s*/, "").strip
    p = parse_place(place)
    if p[:ops].size >= 1 && p[:ops].last[:k] == :deref
      prefix_ops = p[:ops][0...-1]
      cur = local_type(p[:root], locals, params)
      unless cur.nil?
        cur = cur.strip
        ok = true
        prefix_ops.each do |w|
          if w[:k] == :deref
            inner, _ = type_deref_once(cur, types)
            if inner.nil?
              ok = false
              break
            end
            cur = inner.strip
          else
            nc = apply_wrapper_ty(cur, w, types)
            if nc.nil?
              ok = false
              break
            end
            cur = nc
          end
        end
        if ok
          rest = cur.sub(/^&mut\s+|^&move\s+|^&\s*|^\*const\s+|^\*mut\s+|^\*move\s+/, "")
          if cur != rest && fat_rest?(rest.strip)
            prefix_str = p[:root]
            prefix_ops.each do |w|
              case w[:k]
              when :field then prefix_str = "#{prefix_str}.#{w[:idx]}"
              when :downcast then prefix_str = "#{prefix_str}@#{w[:idx]}"
              when :index then prefix_str = "#{prefix_str}[#{w[:idx]}]"
              when :deref then prefix_str = "(*#{prefix_str})"
              end
            end
            addr, regi = place_addr(prefix_str, types, locals, params, param_reg, stmts, regi)
            return [addr, regi]
          end
        end
      end
    end
    addr, regi = place_addr(place, types, locals, params, param_reg, stmts, regi)
    return [addr, regi]
  end
  load_operand(expr, types, locals, params, param_reg, stmts, regi)
end

def is_zst_ty(ty, types)
  return false if ty.nil?
  sz, _ = type_size_align(ty.strip, types)
  sz == 0
end

def store_rvalue(dst_place, rhs, types, locals, params, param_reg, stmts, regi, lines, pathb_ret)
  dst_root = parse_place(dst_place)[:root] rescue dst_place.split(/[^A-Za-z0-9_]/).first
  if dst_root == "RETURN"
    if rhs.strip.gsub(/\s+/, "") == "()"
      return regi
    end
    ret_active = pathb_ret != "void" || $agg_ret
    composite = rhs.start_with?("ENUM") || rhs.start_with?("{") || rhs.start_with?("UNION") || rhs.start_with?('"') || rhs.start_with?("MAKEDST") || rhs.start_with?("CAST") || rhs.start_with?("DSTPTR") || rhs.start_with?("DSTMETA") || (rhs.start_with?("(") && rhs.include?(","))
    if composite && ret_active
      regi = store_rvalue("$\"retval\"", rhs, types, locals, params, param_reg, stmts, regi, lines, pathb_ret)
      unless $agg_ret
        r = regi; regi += 1
        stmts << "(let %#{r} #{pathb_ret} (load #{pathb_ret} $\"retval\"))"
        $ret_reg = r
      end
      return regi
    end
    if ret_active
      val, regi = eval_rvalue_operand(rhs, types, locals, params, param_reg, stmts, regi, lines)
      if $agg_ret
        rsz, _ = type_size_align($cur_ret, types)
        stmts << "(copy #{rsz} $\"retval\" #{val})"
      else
        r = regi; regi += 1
        stmts << "(let %#{r} #{pathb_ret} #{val})"
        $ret_reg = r
      end
    end
    return regi
  end
  if rhs.start_with?('"')
    inner = rhs[1..rhs.rindex('"')-1]
    bytes = unescape_mir(inner)
    tmp, regi = materialize_str(bytes, stmts, regi, lines)
    addr, regi = place_addr(dst_place, types, locals, params, param_reg, stmts, regi)
    stmts << "(copy 16 #{addr} #{tmp})"
    return regi
  end
  if rhs.start_with?("MAKEDST")
    parts = rhs.sub(/^MAKEDST\s+/, "").split(",", 2).map(&:strip)
    ptr_expr = parts[0]
    meta_expr = parts[1]
    pv, regi = eval_rvalue_operand(ptr_expr, types, locals, params, param_reg, stmts, regi, lines)
    mty = nil
    begin
      mty = place_type(meta_expr, types, locals, params)
    rescue
      mty = nil
    end
    if meta_expr.start_with?("ADDROF") || meta_expr.start_with?("&") || meta_expr.start_with?('"') || meta_expr.match?(/^([+-]?\d+)\s+[A-Za-z0-9_]+$/) || meta_expr == "true" || meta_expr == "false"
      mty = "usize"
    end
    if mty.nil? || mty == "()" || mty == "!" || is_zst_ty(mty, types)
      mv = "(const unsigned_long 0)"
    else
      mv, regi = eval_rvalue_operand(meta_expr, types, locals, params, param_reg, stmts, regi, lines)
    end
    addr, regi = place_addr(dst_place, types, locals, params, param_reg, stmts, regi)
    r1 = regi; regi += 1
    stmts << "(let %#{r1} (ptr (const char)) #{pv})"
    stmts << "(store (ptr (const char)) #{addr} %#{r1})"
    r2 = regi; regi += 1
    stmts << "(let %#{r2} unsigned_long #{mv})"
    r3 = regi; regi += 1
    stmts << "(let %#{r3} (ptr unsigned_long) (offset #{addr} 8))"
    stmts << "(store unsigned_long %#{r3} %#{r2})"
    return regi
  end
  if rhs.start_with?("ENUM")
    m2 = rhs.match(/^ENUM (\S+) (\d+)\s*(\{(.*)\})?/)
    idx = m2 ? m2[2].to_i : 0
    ename = m2 ? m2[1] : nil
    vals_str = m2 && m2[4] ? m2[4].strip : ""
    vals = vals_str.empty? ? [] : split_top(vals_str)
    dst_ty = place_type(dst_place, types, locals, params)
    sz, _ = dst_ty ? type_size_align(dst_ty, types) : [8,8]
    sz = 1 if sz == 0
    stmts << "(zero-fill #{sz} $\"#{parse_place(dst_place)[:root]}\")" if false
    addr, regi = place_addr(dst_place, types, locals, params, param_reg, stmts, regi)
    addr_root = addr
    info = (ename && types.key?(ename)) ? types[ename] : (dst_ty && types.key?(dst_ty) ? types[dst_ty] : nil)
    if info && info[:tag]
      tag = info[:tag]
      arm = tag[:arms][idx]
      toff = 0
      fty = nil
      subs = tag[:sub].split(",").map(&:strip).reject(&:empty?).map(&:to_i)
      f0 = info[:fields][tag[:field]]
      unless f0.nil?
        toff += f0[:off]
        cur_t = f0[:type]
        fty = cur_t
        subs.each do |pi|
          rec = cur_t && types.key?(cur_t) ? types[cur_t] : nil
          f = rec ? rec[:fields][pi] : nil
          if f.nil?
            fty = nil
            break
          end
          toff += f[:off]
          fty = f[:type]
          cur_t = fty
        end
      end
      fty = "u8" if fty.nil?
      nbytes = 1
      if arm && arm[:val] && arm[:val] != "*"
        nbytes = [1, arm[:val].scan(/\\x[0-9A-Fa-f]{2}|\\0|\\.|[^\\"]/).size].max
      end
      fsz, _ = type_size_align(fty, types)
      fpt = rust_type_to_pathb(fty, types)
      if fsz != nbytes || fpt.start_with?("(")
        fpt = nbytes == 1 ? "unsigned_char" : (nbytes == 2 ? "unsigned_short" : (nbytes == 4 ? "unsigned_int" : "unsigned_long"))
      end
      taddr = toff == 0 ? addr_root : begin r = regi; regi += 1; stmts << "(let %#{r} (ptr #{fpt}) (offset #{addr_root} #{toff}))"; "%#{r}"; end
      if arm.nil? || arm[:val] == "*"
        stmts << "(zero-fill #{sz} #{addr_root})"
      else
        lit = arm[:val]
        blen = 0
        bval = 0
        lit.scan(/\\x([0-9A-Fa-f]{2})|\\0|\\(.)|([^\\"])/) do |hx, esc, ch|
          if hx then bval |= hx.to_i(16) << (blen*8)
          elsif esc then bval |= esc.ord << (blen*8)
          elsif ch then bval |= ch.ord << (blen*8)
          else bval |= 0
          end
          blen += 1
        end
        stmts << "(store #{fpt} #{taddr} (const #{fpt} #{bval}))"
        if blen < sz && toff == 0
          r = regi; regi += 1
          stmts << "(let %#{r} (ptr unsigned_char) (offset #{addr_root} #{blen}))"
          stmts << "(zero-fill #{sz - blen} %#{r})"
        end
      end
      unless vals.empty?
        vty = info[:fields][idx] ? info[:fields][idx][:type] : nil
        voff = info[:fields][idx] ? info[:fields][idx][:off] : 0
        vaddr = voff == 0 ? addr_root : begin r = regi; regi += 1; vpt0 = vty ? rust_type_to_pathb(vty, types) : "unsigned_long"; stmts << "(let %#{r} (ptr #{vpt0}) (offset #{addr_root} #{voff}))"; "%#{r}"; end
        vals.each_with_index do |fv, fi|
          fvv, regi = eval_rvalue_operand(fv, types, locals, params, param_reg, stmts, regi, lines)
          fvt = vty
          if vty && types.key?(vty)
            ff = types[vty][:fields][fi]
            if ff
              fvt = ff[:type]
              next if is_zst_ty(fvt, types)
              foff = ff[:off]
              faddr = foff == 0 ? vaddr : begin r = regi; regi += 1; fft = rust_type_to_pathb(fvt, types); stmts << "(let %#{r} (ptr #{fft}) (offset #{vaddr} #{foff}))"; "%#{r}"; end
              fsz2, _ = type_size_align(fvt, types)
              fpt2 = rust_type_to_pathb(fvt, types)
              if fpt2.start_with?("(") && !fpt2.start_with?("(ptr") && !fpt2.start_with?("(fn")
                stmts << "(copy #{fsz2} #{faddr} #{fvv})"
              else
                stmts << "(store #{fpt2} #{faddr} #{fvv})"
              end
              next
            end
          end
          next if fvt && is_zst_ty(fvt, types)
          fsz2, _ = fvt ? type_size_align(fvt, types) : [8,8]
          fpt2 = fvt ? rust_type_to_pathb(fvt, types) : "unsigned_long"
          if fpt2.start_with?("(") && !fpt2.start_with?("(ptr") && !fpt2.start_with?("(fn")
            stmts << "(copy #{fsz2} #{vaddr} #{fvv})"
          else
            stmts << "(store #{fpt2} #{vaddr} #{fvv})"
          end
        end
      end
    else
      if vals.empty?
        stmts << "(zero-fill #{sz} #{addr_root})"
      else
        vals.each_with_index do |fv, fi|
          fvv, regi = eval_rvalue_operand(fv, types, locals, params, param_reg, stmts, regi, lines)
          fvt = nil; foff = fi * 8
          if dst_ty && types.key?(dst_ty) && types[dst_ty][:fields][fi]
            foff = types[dst_ty][:fields][fi][:off]
            fvt = types[dst_ty][:fields][fi][:type]
          end
          fsz2, _ = fvt ? type_size_align(fvt, types) : [8,8]
          fpt2 = fvt ? rust_type_to_pathb(fvt, types) : "unsigned_long"
          faddr = foff == 0 ? addr_root : begin r = regi; regi += 1; stmts << "(let %#{r} (ptr #{fpt2}) (offset #{addr_root} #{foff}))"; "%#{r}"; end
          if fpt2.start_with?("(") && !fpt2.start_with?("(ptr") && !fpt2.start_with?("(fn")
            stmts << "(copy #{fsz2} #{faddr} #{fvv})"
          else
            stmts << "(store #{fpt2} #{faddr} #{fvv})"
          end
        end
      end
    end
    return regi
  end
  if rhs.start_with?("{") || (rhs.start_with?("(") && rhs.include?(","))
    is_struct = rhs.start_with?("{")
    inner = rhs[1..rhs.rindex(is_struct ? "}" : ")")-1].strip
    flds = inner.empty? ? [] : split_top(inner)
    dst_ty = place_type(dst_place, types, locals, params)
    addr, regi = place_addr(dst_place, types, locals, params, param_reg, stmts, regi)
    flds.each_with_index do |f, i|
      fvv, regi = eval_rvalue_operand(f, types, locals, params, param_reg, stmts, regi, lines)
      fvt = nil; foff = i * 8
      if dst_ty && types.key?(dst_ty) && types[dst_ty][:fields][i]
        foff = types[dst_ty][:fields][i][:off]
        fvt = types[dst_ty][:fields][i][:type]
      else
        fvt = place_type(f, types, locals, params)
      end
      next if fvt && is_zst_ty(fvt, types)
      fsz2, _ = fvt ? type_size_align(fvt, types) : [8,8]
      fpt2 = fvt ? rust_type_to_pathb(fvt, types) : "unsigned_long"
      faddr = foff == 0 ? addr : begin r = regi; regi += 1; stmts << "(let %#{r} (ptr #{fpt2}) (offset #{addr} #{foff}))"; "%#{r}"; end
      if fpt2.start_with?("(") && !fpt2.start_with?("(ptr") && !fpt2.start_with?("(fn")
        stmts << "(copy #{fsz2} #{faddr} #{fvv})"
      else
        stmts << "(store #{fpt2} #{faddr} #{fvv})"
      end
    end
    return regi
  end
  if rhs.start_with?("UNION")
    m2 = rhs.match(/^UNION (\S+) (\d+) (.+)$/)
    if m2
      fvt = place_type(m2[3].strip, types, locals, params)
      unless fvt && (fvt == "()" || fvt == "!" || is_zst_ty(fvt, types))
        fv, regi = eval_rvalue_operand(m2[3].strip, types, locals, params, param_reg, stmts, regi, lines)
        addr, regi = place_addr(dst_place, types, locals, params, param_reg, stmts, regi)
        fpt2 = fvt ? rust_type_to_pathb(fvt, types) : "unsigned_long"
        fsz2, _ = fvt ? type_size_align(fvt, types) : [8,8]
        if fpt2.start_with?("(") && !fpt2.start_with?("(ptr") && !fpt2.start_with?("(fn")
          stmts << "(copy #{fsz2} #{addr} #{fv})"
        else
          stmts << "(store #{fpt2} #{addr} #{fv})"
        end
      end
      return regi
    end
  end
  if rhs.start_with?("CAST")
    m2 = rhs.match(/^CAST (.+) as (.+)$/)
    if m2
      sv = m2[1].strip; dt = m2[2].strip
      svv, regi = eval_rvalue_operand(sv, types, locals, params, param_reg, stmts, regi, lines)
      sty = place_type(sv, types, locals, params)
      dpt = rust_type_to_pathb(dt, types)
      spt = sty ? rust_type_to_pathb(sty, types) : nil
      val = svv
      if dpt != spt && !dpt.start_with?("(") && !(spt || "").start_with?("(")
        if (dpt == "float" || dpt == "double") && !((spt || "").include?("float") || (spt || "") == "double")
          r = regi; regi += 1
          op = dpt == "float" ? "i2f" : "i2d"
          op = op + ".s" unless (spt || "").include?("unsigned")
          stmts << "(let %#{r} #{dpt} (#{op} #{dpt} #{svv}))"
          val = "%#{r}"
        elsif ((spt || "") == "float" || (spt || "") == "double") && !(dpt.include?("float") || dpt == "double")
          r = regi; regi += 1
          op = (spt || "") == "float" ? "f2i" : "d2i"
          op = op + ".s" unless dpt.include?("unsigned")
          stmts << "(let %#{r} #{dpt} (#{op} #{dpt} #{svv}))"
          val = "%#{r}"
        else
          r = regi; regi += 1
          stmts << "(let %#{r} #{dpt} (iconv #{dpt} #{svv}))"
          val = "%#{r}"
        end
      elsif dpt.start_with?("(ptr") && (spt || "").start_with?("(struct")
        r = regi; regi += 1
        stmts << "(let %#{r} #{dpt} (load #{dpt} #{svv}))"
        val = "%#{r}"
      elsif (dpt.start_with?("(ptr") && (spt || "").start_with?("(ptr")) && dpt != spt
        r = regi; regi += 1
        stmts << "(let %#{r} #{dpt} (bitcast #{dpt} #{svv}))"
        val = "%#{r}"
      end
      addr, fty, regi = place_addr(dst_place, types, locals, params, param_reg, stmts, regi, true)
      if dpt.start_with?("(") && !dpt.start_with?("(ptr") && !dpt.start_with?("(fn")
        dsz, _ = type_size_align(dt, types)
        stmts << "(copy #{dsz} #{addr} #{val})"
      else
        stmts << "(store #{dpt} #{addr} #{val})"
      end
      return regi
    end
  end
  if rhs.start_with?("DSTPTR")
    target = rhs.sub(/^DSTPTR\s+/, "").strip
    addr, regi = place_addr(target, types, locals, params, param_reg, stmts, regi)
    r = regi; regi += 1
    stmts << "(let %#{r} (ptr void) (load (ptr void) #{addr}))"
    return store_rvalue(dst_place, "%#{r} void*", types, locals, params, param_reg, stmts, regi, lines, pathb_ret) if false
    daddr, regi = place_addr(dst_place, types, locals, params, param_reg, stmts, regi)
    stmts << "(store (ptr void) #{daddr} %#{r})"
    return regi
  end
  if rhs.start_with?("DSTMETA")
    target = rhs.sub(/^DSTMETA\s+/, "").strip
    dty0 = place_type(dst_place, types, locals, params)
    if dty0.nil? || dty0 == "()" || dty0 == "!" || is_zst_ty(dty0, types)
      return regi
    end
    addr, regi = place_addr(target, types, locals, params, param_reg, stmts, regi)
    r = regi; regi += 1
    stmts << "(let %#{r} (ptr unsigned_long) (offset #{addr} 8))"
    r2 = regi; regi += 1
    stmts << "(let %#{r2} unsigned_long (load unsigned_long %#{r}))"
    daddr, regi = place_addr(dst_place, types, locals, params, param_reg, stmts, regi)
    dty = place_type(dst_place, types, locals, params)
    dpt = dty ? rust_type_to_pathb(dty, types) : "unsigned_long"
    dpt = "unsigned_long" if dpt.start_with?("(") && !dpt.start_with?("(ptr")
    stmts << "(store #{dpt} #{daddr} %#{r2})"
    return regi
  end
  if rhs.strip.gsub(/\s+/, "") == "()"
    return regi
  end
  if rhs.match(/^\[([^\]]+); (\d+)\]$/)
    m2 = rhs.match(/^\[([^\]]+); (\d+)\]$/)
    fv, regi = eval_rvalue_operand(m2[1].strip, types, locals, params, param_reg, stmts, regi, lines)
    n = m2[2].to_i
    fty = place_type(m2[1].strip, types, locals, params)
    fsz, _ = fty ? type_size_align(fty, types) : [1,1]
    fpt = fty ? rust_type_to_pathb(fty, types) : "unsigned_char"
    addr, regi = place_addr(dst_place, types, locals, params, param_reg, stmts, regi)
    n.times do |k|
      off = k * fsz
      fa = off == 0 ? addr : begin r = regi; regi += 1; stmts << "(let %#{r} (ptr #{fpt}) (offset #{addr} #{off}))"; "%#{r}"; end
      if fpt.start_with?("(") && !fpt.start_with?("(ptr") && !fpt.start_with?("(fn")
        stmts << "(copy #{fsz} #{fa} #{fv})"
      else
        stmts << "(store #{fpt} #{fa} #{fv})"
      end
    end
    return regi
  end
  if rhs.start_with?("[") && rhs.end_with?("]")
    inner = rhs[1...-1].strip
    flds = inner.empty? ? [] : split_top(inner)
    addr, regi = place_addr(dst_place, types, locals, params, param_reg, stmts, regi)
    el_ty = nil
    dst_t0 = place_type(dst_place, types, locals, params)
    if dst_t0 && dst_t0.include?(";")
      el_ty = dst_t0[1...-1].split(";", 2)[0].strip rescue nil
    end
    flds.each_with_index do |f, i|
      fvv, regi = eval_rvalue_operand(f, types, locals, params, param_reg, stmts, regi, lines)
      fty = el_ty || place_type(f, types, locals, params)
      fsz, _ = fty ? type_size_align(fty, types) : [8,8]
      fpt = fty ? rust_type_to_pathb(fty, types) : "unsigned_long"
      off = i * fsz
      fa = off == 0 ? addr : begin r = regi; regi += 1; stmts << "(let %#{r} (ptr #{fpt}) (offset #{addr} #{off}))"; "%#{r}"; end
      if fpt.start_with?("(") && !fpt.start_with?("(ptr") && !fpt.start_with?("(fn")
        stmts << "(copy #{fsz} #{fa} #{fvv})"
      else
        stmts << "(store #{fpt} #{fa} #{fvv})"
      end
    end
    return regi
  end
  hint = nil
  if rhs.strip.start_with?("BINOP")
    bm = rhs.strip.match(/^BINOP\s+(.+?)\s+(<=?|>=?|==|!=|<<|>>|[+\-*\/%&|^])\s+(.+)$/)
    if bm && !["==", "!=", "<", "<=", ">", ">="].include?(bm[2])
      dst_t0 = place_type(dst_place, types, locals, params)
      hint = dst_t0 ? rust_type_to_pathb(dst_t0, types) : nil
      hint = nil if hint && hint.start_with?("(")
    end
  end
  $binop_hint = hint
  val, regi = eval_rvalue_operand(rhs, types, locals, params, param_reg, stmts, regi, lines)
  $binop_hint = nil
  vty = place_type(rhs, types, locals, params)
  vpt = vty ? rust_type_to_pathb(vty, types) : nil
  if val.start_with?("(") && !val.start_with?("(const") && !val.start_with?("(load")
    vpt2 = vpt
    if vpt2.nil? || vpt2.start_with?("(")
      dst_t = place_type(dst_place, types, locals, params)
      vpt2 = dst_t ? rust_type_to_pathb(dst_t, types) : "unsigned_long"
    end
    unless vpt2.start_with?("(")
      r = regi; regi += 1
      stmts << "(let %#{r} #{vpt2} #{val})"
      val = "%#{r}"
    end
  end
  regi = store_place(dst_place, val, vpt, types, locals, params, param_reg, stmts, regi)
  regi
end

functions.each do |fn|
  header = fn[:header]
  name, params_str, ret = parse_fn_header(header)
  next if fn[:body].nil?
  next if name == "panic_impl" || name.start_with?("panic_impl")
  next if name == "main"
  params = parse_params_str(params_str)
  pathb_ret = rust_type_to_pathb(ret, types)
  agg_ret = pathb_ret.start_with?("(") && !pathb_ret.start_with?("(ptr") && !pathb_ret.start_with?("(fn")
  if agg_ret
    pathb_ret = "void"
  end
  body = fn[:body]
  $lit_slots = []
  $cur_ret = ret
  $agg_ret = agg_ret
  $ret_reg = nil
  locals = []
  body.scan(/^\tlet (.+?): (.+);$/) { |n, t| locals << [n.strip, t.strip] }
  slot_lines = []
  if pathb_ret != "void" || agg_ret
    rsz, ral = type_size_align(ret, types)
    ral = 1 if ral == 0
    rsz = 1 if rsz == 0
    rpt = agg_ret ? rust_type_to_pathb(ret, types) : pathb_ret
    slot_lines << "(slot \"retval\" #{rpt} #{rsz} #{ral})"
  end
  locals.each do |n, t|
    sz, al = type_size_align(t, types)
    al = 1 if al == 0
    sz = 1 if sz == 0
    slot_lines << "(slot #{n.inspect} #{rust_type_to_pathb(t, types)} #{sz} #{al})"
  end
  param_lines = []
  param_reg = {}
  ri = agg_ret ? 1 : 0
  if agg_ret
    param_lines << "(sret %0 #{rust_type_to_pathb(ret, types)})"
  end
  params.each_with_index do |t, i|
    pt = rust_type_to_pathb(t, types)
    if pt == "void"
      param_reg[i] = nil
      next
    end
    param_reg[i] = ri
    if pt.start_with?("(") && !pt.start_with?("(ptr") && !pt.start_with?("(fn") && !pt.start_with?("(array ?")
      # aggregate: pass by value
      param_lines << "(param %#{ri} \"arg#{i}\" (byval #{pt}))"
    else
      param_lines << "(param %#{ri} \"arg#{i}\" #{pt})"
    end
    ri += 1
  end
  # Spill every non-void arg into a slot so places can take addresses uniformly.
  dfidx = body.scan(/\bdf(\d+)\b/).flatten.map(&:to_i).uniq.sort
  dfidx.each do |d|
    slot_lines << "(slot \"df#{d}\" bool 1 1)"
  end
  params.each_with_index do |t, i|
    pt = rust_type_to_pathb(t, types)
    next if pt == "void"
    sz, al = type_size_align(t, types)
    al = 1 if al == 0
    sz = 1 if sz == 0
    slot_lines << "(slot \"arg#{i}\" #{pt} #{sz} #{al})"
  end

  blocks = {}
  body.scan(/^\t(\d+): \{\n(.*?)\n\t\}/m) do |num, content|
    blocks[num] = content
  end
  block_nums = body.scan(/^\t(\d+): \{\s*$/).flatten.sort_by(&:to_i)

  regi = 100
  stmts = []
  dfidx.each do |d|
    stmts << "(store bool $\"df#{d}\" (const bool 0))"
  end
  params.each_with_index do |t, i|
    r = param_reg[i]
    next if r.nil?
    pt = rust_type_to_pathb(t, types)
    agg = pt.start_with?("(") && !pt.start_with?("(ptr") && !pt.start_with?("(fn")
    sz0, _ = type_size_align(t, types)
    if agg
      stmts << "(copy #{sz0} $\"arg#{i}\" %#{r})" unless sz0 == 0
    else
      stmts << "(store #{pt} $\"arg#{i}\" %#{r})"
    end
  end
  block_nums.each do |bn|
    content = blocks[bn] || ""
    stmts << "(label #{bn.inspect})"
    content.each_line do |ln|
      ln = ln.strip
      next if ln.empty?
      if ln.start_with?("ASSIGN")
        m = ln.match(/^ASSIGN (.+?) = (.+);$/)
        place = m[1].strip
        rhs = m[2].strip
        regi = store_rvalue(place, rhs, types, locals, params, param_reg, stmts, regi, lines, pathb_ret)
      elsif ln.start_with?("SETFLAG")
        m = ln.match(/^SETFLAG df(\d+) = (!?)df?(\d*);?$/)
        if m
          idx = m[1]; neg = m[2]; src = m[3]
          if src.empty?
            val = neg.empty? ? "(const bool 1)" : "(const bool 0)"
            stmts << "(store bool $\"df#{idx}\" #{val})"
          else
            r = regi; regi += 1
            stmts << "(let %#{r} bool (load bool $\"df#{src}\"))"
            if neg.empty?
              stmts << "(store bool $\"df#{idx}\" %#{r})"
            else
              r2 = regi; regi += 1
              stmts << "(let %#{r2} bool (not bool %#{r}))"
              stmts << "(store bool $\"df#{idx}\" %#{r2})"
            end
          end
        else
          m2 = ln.match(/^SETFLAG df(\d+) = (\d+);?$/)
          if m2
            stmts << "(store bool $\"df#{m2[1]}\" (const bool #{m2[2]}))"
          end
        end
      elsif ln.start_with?("LOADFLAG")
        m = ln.match(/^LOADFLAG df(\d+) = (.+) BIT (\d+);?$/)
        if m
          idx = m[1]; slot = m[2].strip; bit = m[3].to_i
          addr, regi = place_addr(slot, types, locals, params, param_reg, stmts, regi)
          r = regi; regi += 1
          stmts << "(let %#{r} (ptr unsigned_char) (offset #{addr} #{bit / 8}))"
          r2 = regi; regi += 1
          stmts << "(let %#{r2} unsigned_char (load unsigned_char %#{r}))"
          r3 = regi; regi += 1
          stmts << "(let %#{r3} unsigned_char (and unsigned_char %#{r2} (const unsigned_char #{1 << (bit % 8)})))"
          r4 = regi; regi += 1
          stmts << "(let %#{r4} bool (ne unsigned_char %#{r3} (const unsigned_char 0)))"
          stmts << "(store bool $\"df#{idx}\" %#{r4})"
        end
      elsif ln.start_with?("SAVEFLAG")
        m = ln.match(/^SAVEFLAG (.+) BIT (\d+) = df(\d+);?$/)
        if m
          slot = m[1].strip; bit = m[2].to_i; idx = m[3]
          addr, regi = place_addr(slot, types, locals, params, param_reg, stmts, regi)
          r = regi; regi += 1
          stmts << "(let %#{r} bool (load bool $\"df#{idx}\"))"
          stmts << "(if %#{r} (then (let %#{regi} (ptr unsigned_char) (offset #{addr} #{bit / 8}))) )" if false
          r5 = regi; regi += 1
          stmts << "(let %#{r5} (ptr unsigned_char) (offset #{addr} #{bit / 8}))"
          r6 = regi; regi += 1
          stmts << "(let %#{r6} unsigned_char (load unsigned_char %#{r5}))"
          mask = 1 << (bit % 8)
          r7 = regi; regi += 1
          stmts << "(let %#{r7} unsigned_char (or unsigned_char %#{r6} (const unsigned_char #{mask})))"
          r8 = regi; regi += 1
          stmts << "(let %#{r8} unsigned_char (and unsigned_char %#{r6} (const unsigned_char #{255 - mask})))"
          r9 = regi; regi += 1
          stmts << "(let %#{r9} unsigned_char (if.val unsigned_char %#{r} %#{r7} %#{r8}))" if false
          stmts << "(if %#{r} (then (store unsigned_char %#{r5} %#{r7})) (else (store unsigned_char %#{r5} %#{r8})))"
        end
      elsif ln.start_with?("DROP")
        m = ln.match(/^DROP (.+?)( SHALLOW)?( IF df(\d+))?;?$/)
        if m
          slot = m[1].strip; flag = m[4]
          emit_drop = lambda do
            sty = place_type(slot, types, locals, params)
            glue = sty && types.key?(sty) ? types[sty][:drop] : nil
            if glue
              addr, regi2 = place_addr(slot, types, locals, params, param_reg, stmts, regi)
              stmts << "(eval (call void &\"#{pb_sym(glue)}\" #{addr}))"
              regi = regi2
            end
          end
          if flag
            r = regi; regi += 1
            sty = place_type(slot, types, locals, params)
            glue = sty && types.key?(sty) ? types[sty][:drop] : nil
            if glue
              stmts << "(let %#{r} bool (load bool $\"df#{flag}\"))"
              before = stmts.size
              addr, regi = place_addr(slot, types, locals, params, param_reg, stmts, regi)
              stmts << "(eval (call void &\"#{pb_sym(glue)}\" #{addr}))"
              added = stmts[before..-1] || []
              stmts[before..-1] = ["(if %#{r} (then #{added.join(' ')}))"]
            end
          else
            emit_drop.call
          end
        end
      elsif ln.start_with?("CALL")
        m = ln.match(/^CALL (.+?) = (.+) goto (\d+) else (\d+)$/)
        dest = m[1].strip
        call_expr = m[2].strip
        retblk = m[3]
        panicblk = m[4]
        s = call_expr.strip
        indirect_callee = nil
        fexpr = nil
        args_str = ""
        find_close = lambda do |str, open_idx|
          depth = 0; instr = false; esc = false
          (open_idx...str.bytesize).each do |j|
            c = str[j]
            if instr
              if esc
                esc = false
              elsif c == "\\"
                esc = true
              elsif c == "\""
                instr = false
              end
              next
            end
            if c == "\""
              instr = true
            elsif c == "("
              depth += 1
            elsif c == ")"
              depth -= 1
              return j if depth == 0
            end
          end
          nil
        end
        if s.start_with?("(")
          close1 = find_close.call(s, 0)
          callee_str = s[1...close1].strip
          rest = s[close1+1..-1].strip
          if rest.start_with?("(")
            close2 = find_close.call(rest, 0)
            args_str = rest[1...close2].strip
          end
          indirect_callee = callee_str
        else
          adepth = 0
          start = nil
          prevc = nil
          s.each_char.with_index do |c, i|
            if c == "<"
              adepth += 1
            elsif c == ">"
              adepth -= 1 if adepth > 0 && prevc != "-"
            elsif c == "("
              if adepth == 0
                start = i
                break
              end
            end
            prevc = c
          end
          if start.nil?
            fexpr = s
          else
            fexpr = s[0...start].strip
            close = find_close.call(s, start)
            args_str = close ? s[start+1...close].strip : ""
          end
        end
        genparams = nil
        if fexpr && fexpr.include?("<")
          gm = fexpr.match(/^(.*?)<(.*)>$/)
          if gm
            fexpr = gm[1].strip
            genparams = split_top(gm[2])
          end
        end
        if fexpr && fexpr =~ /\"([^\"]+)\"/
          fexpr = $1
        end
        if fexpr == "ZRG2cD8std0_0_02rt10lang_start0g"
          fexpr = "ZRG2cD8std0_0_02rt10lang_start1gT0"
          args_str = args_str.empty? ? "0 u8" : args_str + ", 0 u8"
        end
        raw_args = args_str.empty? ? [] : split_top(args_str)
        raw_args = raw_args.map(&:strip).reject(&:empty?)
        arg_vals = []
        raw_args.each do |a|
          at = place_type(a, types, locals, params)
          if at == "()" || at == "!"
            next
          end
          if at.nil? && (a.match(/^[A-Za-z]/).nil? || const_int_value(a))
            # constant or unknown; keep
          end
          v, regi = eval_rvalue_operand(a, types, locals, params, param_reg, stmts, regi, lines)
          apt = at ? rust_type_to_pathb(at, types) : nil
          agg_arg = at && (types.key?(at) || (at.start_with?("[") && at.include?(";")))
          fat_arg = apt && apt.start_with?("(struct \"&")
          str_arg = a.strip.start_with?('"') && a.strip.end_with?('"')
          if agg_arg || fat_arg || str_arg
            if str_arg
              addr = v
              apt = "(struct \"&str\")"
            else
              addr, regi = place_addr(a, types, locals, params, param_reg, stmts, regi)
            end
            arg_vals << ["(byval #{apt} #{addr})", at || "&str"]
          else
            arg_vals << [v, at]
          end
        end
        dest_ty = dest == "RETURN" ? (pathb_ret == "void" && !$agg_ret ? nil : ret) : place_type(dest, types, locals, params)
        dest_pt = dest == "RETURN" ? ($agg_ret ? rust_type_to_pathb(ret, types) : pathb_ret) : (dest_ty ? rust_type_to_pathb(dest_ty, types) : "unsigned_long")
        ret_void = dest == "RETURN" ? (pathb_ret == "void" && !$agg_ret) : (dest_pt.nil? || dest_pt == "void")
        dest_agg = !ret_void && dest_pt.start_with?("(") && !dest_pt.start_with?("(ptr") && !dest_pt.start_with?("(fn")
        dest_addr = nil
        if dest_agg
          if dest == "RETURN"
            dest_addr = "$\"retval\""
          else
            dest_addr, regi = place_addr(dest, types, locals, params, param_reg, stmts, regi)
          end
        end
        store_dest = lambda do |val|
          if val.start_with?("(byval ")
            m = val.match(/^\(byval (.+) (\S+)\)$/)
            if m
              baddr = m[2]
              if dest_agg
                dsz, _ = type_size_align(dest == "RETURN" ? ret : dest_ty, types)
                stmts << "(copy #{dsz} #{dest_addr} #{baddr})"
              elsif dest == "RETURN"
                if !ret_void && pathb_ret != "void"
                  r = regi; regi += 1
                  stmts << "(let %#{r} #{pathb_ret} (load #{pathb_ret} #{baddr}))"
                  $ret_reg = r
                end
              else
                r = regi; regi += 1
                stmts << "(let %#{r} #{dest_pt} (load #{dest_pt} #{baddr}))"
                regi = store_place(dest, "%#{r}", dest_pt, types, locals, params, param_reg, stmts, regi)
              end
              next
            end
          end
          if dest_agg
            dsz, _ = type_size_align(dest == "RETURN" ? ret : dest_ty, types)
            stmts << "(copy #{dsz} #{dest_addr} #{val})"
          elsif dest == "RETURN"
            if !ret_void && pathb_ret != "void"
              r = regi; regi += 1
              stmts << "(let %#{r} #{pathb_ret} #{val})"
              $ret_reg = r
            end
          else
            r = regi; regi += 1
            stmts << "(let %#{r} #{dest_pt} #{val})"
            regi = store_place(dest, "%#{r}", dest_pt, types, locals, params, param_reg, stmts, regi)
          end
        end
        call_with_result = lambda do |callee, argstr|
          if dest_agg
            dty = dest == "RETURN" ? ret : dest_ty
            dpt = rust_type_to_pathb(dty, types)
            stmts << "(eval (call void #{callee} (sret #{dpt} #{dest_addr}) #{argstr}))"
          elsif ret_void
            stmts << "(eval (call void #{callee} #{argstr}))"
          else
            r = regi; regi += 1
            stmts << "(let %#{r} #{dest_pt} (call #{dest_pt} #{callee} #{argstr}))"
            store_dest.call("%#{r}")
          end
        end
        is_intrinsic = fexpr && fexpr.start_with?(/[a-z]/) && !fexpr.include?("0g") && !fexpr.include?("ZRG") && !fexpr.include?("ZRI") && !fexpr.include?("ZRQ") && !fexpr.include?("ZRT")
        if is_intrinsic
          iname = fexpr
          iparams = genparams || []
          case iname
          when "black_box", "assume", "unlikely", "assert_inhabited", "caller_location", "unreachable"
            unless ret_void
              dty = dest == "RETURN" ? ret : dest_ty
              if dty
                dsz, _ = type_size_align(dty, types)
                if dsz > 0
                  daddr = dest == "RETURN" ? "$\"retval\"" : place_addr(dest, types, locals, params, param_reg, stmts, regi)[0]
                  stmts << "(zero-fill #{dsz} #{daddr})"
                end
              end
            end
          when "catch_unwind"
            if arg_vals.size >= 3
              r = regi; regi += 1
              stmts << "(let %#{r} (ptr void) (call (ptr void) #{arg_vals[0][0]} #{arg_vals[1][0]}))"
              if !ret_void && dest_ty
                dpt = rust_type_to_pathb(dest_ty, types)
                stmts << "(store #{dpt} #{dest == "RETURN" ? "$\"retval\"" : place_addr(dest, types, locals, params, param_reg, stmts, regi)[0]} (const #{dpt} 0))"
              end
            elsif !ret_void && dest_ty
              dpt = rust_type_to_pathb(dest_ty, types)
              dsz, _ = type_size_align(dest_ty, types)
              if dsz > 0
                daddr = dest == "RETURN" ? "$\"retval\"" : place_addr(dest, types, locals, params, param_reg, stmts, regi)[0]
                stmts << "(zero-fill #{dsz} #{daddr})"
              end
            end
          when "transmute", "transmute_unchecked"
            if arg_vals.size >= 1
              v, at = arg_vals[0]
              if dest_agg && v.start_with?("%")
                spt = at ? rust_type_to_pathb(at, types) : "unsigned_long"
                spt = "unsigned_long" if spt.start_with?("(") && !spt.start_with?("(ptr")
                stmts << "(store #{spt} #{dest_addr} #{v})"
              else
                store_dest.call(v)
              end
            end
          when "unchecked_add", "unchecked_sub", "unchecked_mul"
            op = iname.end_with?("add") ? "wadd" : (iname.end_with?("sub") ? "wsub" : "wmul")
            ty = dest_ty ? rust_type_to_pathb(dest_ty, types) : "unsigned_long"
            if arg_vals.size >= 2
              r = regi; regi += 1
              stmts << "(let %#{r} #{ty} (#{op} #{ty} #{arg_vals[0][0]} #{arg_vals[1][0]}))"
              store_dest.call("%#{r}")
            end
          when "unchecked_div", "unchecked_rem", "exact_div"
            op = iname.end_with?("div") ? "cdiv" : "crem"
            ty = dest_ty ? rust_type_to_pathb(dest_ty, types) : "unsigned_long"
            if arg_vals.size >= 2
              r = regi; regi += 1
              stmts << "(let %#{r} #{ty} (#{op} #{ty} #{arg_vals[0][0]} #{arg_vals[1][0]}))"
              store_dest.call("%#{r}")
            end
          when "unchecked_shl", "unchecked_shr"
            op = iname.end_with?("shl") ? "cshl" : "cshr"
            ty = dest_ty ? rust_type_to_pathb(dest_ty, types) : "unsigned_long"
            if arg_vals.size >= 2
              r = regi; regi += 1
              stmts << "(let %#{r} #{ty} (#{op} #{ty} #{arg_vals[0][0]} #{arg_vals[1][0]}))"
              store_dest.call("%#{r}")
            end
          when "wrapping_sub", "wrapping_mul", "wrapping_add", "saturating_add", "saturating_sub", "saturating_mul"
            op = iname.include?("sub") ? "wsub" : (iname.include?("mul") ? "wmul" : "wadd")
            ty = dest_ty ? rust_type_to_pathb(dest_ty, types) : "unsigned_long"
            if arg_vals.size >= 2
              r = regi; regi += 1
              stmts << "(let %#{r} #{ty} (#{op} #{ty} #{arg_vals[0][0]} #{arg_vals[1][0]}))"
              store_dest.call("%#{r}")
            end
          when "sqrtf32", "sqrtf64", "sinf32", "sinf64", "cosf32", "cosf64", "expf32", "expf64", "exp2f32", "exp2f64", "logf32", "logf64", "log2f32", "log2f64", "log10f32", "log10f64", "fabsf32", "fabsf64", "floorf32", "floorf64", "ceilf32", "ceilf64", "truncf32", "truncf64", "roundf32", "roundf64", "powf32", "powf64", "powif32", "powif64", "fmaf32", "fmaf64", "fmuladdf32", "fmuladdf64"
            is32 = iname.end_with?("f32")
            base = iname.sub(/f(32|64)$/, "")
            base = "pow" if base == "powi"
            base = "fma" if base == "fmuladd"
            fn = is32 ? base + "f" : base
            ty = dest_ty ? rust_type_to_pathb(dest_ty, types) : "double"
            if arg_vals.size >= 1
              r = regi; regi += 1
              stmts << "(let %#{r} #{ty} (call #{ty} &\"#{fn}\" #{arg_vals.map(&:first).join(' ')}))"
              store_dest.call("%#{r}")
            end
          when "add_with_overflow", "mul_with_overflow"
            op = iname.start_with?("add") ? "wadd" : "wmul"
            ty = iparams[0] ? rust_type_to_pathb(iparams[0], types) : "unsigned_long"
            if arg_vals.size >= 2
              r = regi; regi += 1
              stmts << "(let %#{r} #{ty} (#{op} #{ty} #{arg_vals[0][0]} #{arg_vals[1][0]}))"
              addr, regi = place_addr(dest, types, locals, params, param_reg, stmts, regi)
              stmts << "(store #{ty} #{addr} %#{r})"
            end
          when "offset"
            if arg_vals.size >= 2
              dty = dest_ty ? rust_type_to_pathb(dest_ty, types) : "(ptr unsigned_char)"
              ety = iparams[0] ? iparams[0].sub(/^\*(const|mut|move)\s+/, "") : "u8"
              es, _ = type_size_align(ety, types)
              es = 1 if es == 0
              cnt = const_int_value(raw_args[1])
              if cnt
                off = cnt[0].to_i * es
                r = regi; regi += 1
                stmts << "(let %#{r} #{dty} (offset #{arg_vals[0][0]} #{off}))"
                store_dest.call("%#{r}")
              else
                r = regi; regi += 1
                stmts << "(let %#{r} #{dty} (index #{arg_vals[0][0]} #{arg_vals[1][0]} #{es}))"
                store_dest.call("%#{r}")
              end
            end
          when "copy_nonoverlapping"
            if arg_vals.size >= 3
              ety = iparams[0] || "u8"
              es, _ = type_size_align(ety, types)
              cnt = const_int_value(raw_args[2])
              if cnt
                total = cnt[0].to_i * es
                stmts << "(copy #{total} #{arg_vals[1][0]} #{arg_vals[0][0]})"
              else
                r = regi; regi += 1
                stmts << "(let %#{r} unsigned_long (wmul unsigned_long #{arg_vals[2][0]} (const unsigned_long #{es})))"
                stmts << "(copy.dyn %#{r} #{arg_vals[1][0]} #{arg_vals[0][0]})" if false
                stmts << "(eval (call void &\"memcpy\" #{arg_vals[1][0]} #{arg_vals[0][0]} %#{r}))"
              end
            end
          when "write_bytes"
            if arg_vals.size >= 3
              cnt = const_int_value(raw_args[2])
              ety = iparams[0] || "u8"
              es, _ = type_size_align(ety, types)
              if cnt
                total = cnt[0].to_i * es
                stmts << "(zero-fill #{total} #{arg_vals[0][0]})" if arg_vals[0][0] =~ /0/
                unless arg_vals[0][0] =~ /0/
                  r = regi; regi += 1
                  stmts << "(let %#{r} unsigned_char #{arg_vals[1][0]})"
                  stmts << "(eval (call void &\"memset\" #{arg_vals[0][0]} %#{r} (const unsigned_long #{total})))"
                else
                  stmts << "(zero-fill #{total} #{arg_vals[0][0]})"
                end
              else
                r = regi; regi += 1
                stmts << "(let %#{r} unsigned_long (wmul unsigned_long #{arg_vals[2][0]} (const unsigned_long #{es})))"
                stmts << "(eval (call void &\"memset\" #{arg_vals[0][0]} #{arg_vals[1][0]} %#{r}))"
              end
            end
          when "ptr_offset_from_unsigned", "ptr_offset_from"
            ty = dest_ty ? rust_type_to_pathb(dest_ty, types) : "long"
            if arg_vals.size >= 2
              ety = iparams[0] ? iparams[0].sub(/^\*(const|mut|move)\s+/, "") : "u8"
              es, _ = type_size_align(ety, types)
              es = 1 if es == 0
              r = regi; regi += 1
              stmts << "(let %#{r} #{ty} (wsub #{ty} #{arg_vals[0][0]} #{arg_vals[1][0]}))"
              if es != 1
                r2 = regi; regi += 1
                stmts << "(let %#{r2} #{ty} (cdiv #{ty} %#{r} (const #{ty} #{es})))"
                store_dest.call("%#{r2}")
              else
                store_dest.call("%#{r}")
              end
            end
          when "arith_offset"
            if arg_vals.size >= 2
              dty = dest_ty ? rust_type_to_pathb(dest_ty, types) : "(ptr unsigned_char)"
              ety = iparams[0] ? iparams[0].sub(/^\*(const|mut|move)\s+/, "") : "u8"
              es, _ = type_size_align(ety, types)
              es = 1 if es == 0
              r = regi; regi += 1
              stmts << "(let %#{r} #{dty} (index #{arg_vals[0][0]} #{arg_vals[1][0]} #{es}))"
              store_dest.call("%#{r}")
            end
          when "drop_in_place"
            if arg_vals.size >= 1 && iparams.size >= 1
              tt = iparams[0]
              glue = types.key?(tt) ? types[tt][:drop] : nil
              if glue
                stmts << "(eval (call void &\"#{pb_sym(glue)}\" #{arg_vals[0][0]}))"
              end
            end
          when "size_of", "align_of"
            ty = dest_ty ? rust_type_to_pathb(dest_ty, types) : "unsigned_long"
            t = iparams[0] || "u8"
            sz, al = type_size_align(t, types)
            v = iname == "size_of" ? sz : al
            store_dest.call("(const #{ty} #{v})")
          when "cttz", "cttz_nonzero", "ctlz", "ctlz_nonzero", "ctpop", "compare_bytes"
            ty = dest_ty ? rust_type_to_pathb(dest_ty, types) : "unsigned_long"
            if iname == "compare_bytes" && arg_vals.size >= 3
              r = regi; regi += 1
              stmts << "(let %#{r} #{ty} (call #{ty} &\"memcmp\" #{arg_vals[0][0]} #{arg_vals[1][0]} #{arg_vals[2][0]}))"
              store_dest.call("%#{r}")
              next
            end
            if arg_vals.size >= 1
              x = arg_vals[0][0]
              xty = arg_vals[0][1] ? rust_type_to_pathb(arg_vals[0][1], types) : "unsigned_long"
              xty = "unsigned_long" if xty.start_with?("(")
              bits = xty.include?("char") || xty == "bool" ? 8 : (xty.include?("short") ? 16 : (xty == "int" || xty == "unsigned_int" || xty == "float" ? 32 : 64))
              ty = xty
              m1 = bits == 64 ? 0x5555555555555555 : 0x55555555
              m2 = bits == 64 ? 0x3333333333333333 : 0x33333333
              m4 = bits == 64 ? 0x0f0f0f0f0f0f0f0f : 0x0f0f0f0f
              h01 = bits == 64 ? 0x0101010101010101 : 0x01010101
              popcount = lambda do |v, out|
                r0 = regi; regi += 1
                stmts << "(let %#{r0} #{ty} (cshr #{ty} #{v} (const #{ty} 1)))"
                r1 = regi; regi += 1
                stmts << "(let %#{r1} #{ty} (and #{ty} %#{r0} (const #{ty} #{m1})))"
                r2 = regi; regi += 1
                stmts << "(let %#{r2} #{ty} (wsub #{ty} #{v} %#{r1}))"
                r3 = regi; regi += 1
                stmts << "(let %#{r3} #{ty} (and #{ty} %#{r2} (const #{ty} #{m2})))"
                r3b = regi; regi += 1
                stmts << "(let %#{r3b} #{ty} (cshr #{ty} %#{r2} (const #{ty} 2)))"
                r4 = regi; regi += 1
                stmts << "(let %#{r4} #{ty} (and #{ty} %#{r3b} (const #{ty} #{m2})))"
                r5 = regi; regi += 1
                stmts << "(let %#{r5} #{ty} (wadd #{ty} %#{r3} %#{r4}))"
                r5b = regi; regi += 1
                stmts << "(let %#{r5b} #{ty} (cshr #{ty} %#{r5} (const #{ty} 4)))"
                r5c = regi; regi += 1
                stmts << "(let %#{r5c} #{ty} (wadd #{ty} %#{r5} %#{r5b}))"
                r6 = regi; regi += 1
                stmts << "(let %#{r6} #{ty} (and #{ty} %#{r5c} (const #{ty} #{m4})))"
                r6b = regi; regi += 1
                stmts << "(let %#{r6b} #{ty} (wmul #{ty} %#{r6} (const #{ty} #{h01})))"
                stmts << "(let %#{out} #{ty} (cshr #{ty} %#{r6b} (const #{ty} #{bits - 8})))"
              end
              r = regi; regi += 1
              if iname.start_with?("ctpop")
                rt = regi; regi += 1
                popcount.call(x, rt)
                stmts << "(let %#{r} #{ty} %#{rt})"
              elsif iname.start_with?("cttz")
                r1 = regi; regi += 1
                stmts << "(let %#{r1} #{ty} (not #{ty} #{x}))"
                r2 = regi; regi += 1
                stmts << "(let %#{r2} #{ty} (wsub #{ty} #{x} (const #{ty} 1)))"
                r3 = regi; regi += 1
                stmts << "(let %#{r3} #{ty} (and #{ty} %#{r1} %#{r2}))"
                rt = regi; regi += 1
                popcount.call("%#{r3}", rt)
                stmts << "(let %#{r} #{ty} %#{rt})"
              else
                v = x
                s = 1
                while s < bits
                  rs = regi; regi += 1
                  stmts << "(let %#{rs} #{ty} (cshr #{ty} #{v} (const #{ty} #{s})))"
                  r1 = regi; regi += 1
                  stmts << "(let %#{r1} #{ty} (or #{ty} #{v} %#{rs}))"
                  v = "%#{r1}"
                  s *= 2
                end
                r8 = regi; regi += 1
                popcount.call(v, r8)
                stmts << "(let %#{r} #{ty} (wsub #{ty} (const #{ty} #{bits}) %#{r8}))"
              end
              dpt = dest_ty ? rust_type_to_pathb(dest_ty, types) : "unsigned_long"
              if dpt != ty && !dpt.start_with?("(")
                r2 = regi; regi += 1
                stmts << "(let %#{r2} #{dpt} (iconv #{dpt} %#{r}))"
                store_dest.call("%#{r2}")
              else
                store_dest.call("%#{r}")
              end
            end
          when "size_of_val", "align_of_val"
            ty = dest_ty ? rust_type_to_pathb(dest_ty, types) : "unsigned_long"
            t = iparams[0] || "u8"
            t = t.sub(/^(?:&|&mut\s+|&move\s+|\*const\s+|\*mut\s+|\*move\s+)/, "")
            sz, al = type_size_align(t, types)
            v = iname == "size_of_val" ? sz : al
            store_dest.call("(const #{ty} #{v})")
          when "discriminant_value"
            if arg_vals.size >= 1 && iparams.size >= 1
              t = iparams[0]
              info = types.key?(t) ? types[t] : nil
              if info && info[:tag]
                tag = info[:tag]
                toff = 0
                fty = nil
                subs = tag[:sub].split(",").map(&:strip).reject(&:empty?).map(&:to_i)
                f0 = info[:fields][tag[:field]]
                unless f0.nil?
                  toff += f0[:off]
                  cur_t = f0[:type]
                  fty = cur_t
                  subs.each do |pi|
                    rec = cur_t && types.key?(cur_t) ? types[cur_t] : nil
                    f = rec ? rec[:fields][pi] : nil
                    if f.nil?
                      fty = nil
                      break
                    end
                    toff += f[:off]
                    fty = f[:type]
                    cur_t = fty
                  end
                end
                fty = "u8" if fty.nil?
                fsz, _ = type_size_align(fty, types)
                fpt = rust_type_to_pathb(fty, types)
                if fsz > 8 || fpt.start_with?("(")
                  fpt = "unsigned_long"
                end
                dpt = dest_ty ? rust_type_to_pathb(dest_ty, types) : "long"
                r = regi; regi += 1
                if toff == 0
                  stmts << "(let %#{r} #{fpt} (load #{fpt} #{arg_vals[0][0]}))"
                else
                  r0 = regi; regi += 1
                  stmts << "(let %#{r0} (ptr #{fpt}) (offset #{arg_vals[0][0]} #{toff}))"
                  stmts << "(let %#{r} #{fpt} (load #{fpt} %#{r0}))"
                end
                if dpt != fpt && !dpt.start_with?("(")
                  r2 = regi; regi += 1
                  stmts << "(let %#{r2} #{dpt} (iconv #{dpt} %#{r}))"
                  store_dest.call("%#{r2}")
                else
                  store_dest.call("%#{r}")
                end
              else
                store_dest.call("(const #{dest_ty ? rust_type_to_pathb(dest_ty, types) : "unsigned_long"} 0)")
              end
            end
          when "needs_drop"
            ty = dest_ty ? rust_type_to_pathb(dest_ty, types) : "bool"
            t = iparams[0] || "u8"
            nd = (types.key?(t) && types[t][:drop]) ? 1 : 0
            store_dest.call("(const #{ty} #{nd})")
          else
            stmts << "(eval (call void &\"abort\"))" if false
          end
          stmts << "(goto #{retblk.inspect})"
        elsif indirect_callee
          callee_expr = indirect_callee.strip
          cm = callee_expr.match(/^\(\*(.+)\)\.(\d+)$/)
          if cm
            vtaddr, regi = place_addr("*" + cm[1].strip, types, locals, params, param_reg, stmts, regi) rescue [nil, regi]
            base_expr = cm[1].strip
            fidx = cm[2].to_i
            vbase, regi = eval_rvalue_operand(base_expr, types, locals, params, param_reg, stmts, regi, lines)
            bty = place_type(base_expr, types, locals, params)
            vty = nil
            if bty
              inner, _ = type_deref_once(bty, types)
              vty = inner if inner
              if vty.nil?
                vty = bty
              else
                vty = vty.strip
                if vty.start_with?("&") || vty.start_with?("*")
                  rest = vty.sub(/^&mut\s+|^&move\s+|^&\s*|^\*const\s+|^\*mut\s+|^\*move\s+/, "")
                  vty = rest
                end
              end
            end
            foff = fidx * 8; fty2 = nil
            if vty && types.key?(vty) && types[vty][:fields][fidx]
              foff = types[vty][:fields][fidx][:off]
            end
            r1 = regi; regi += 1
            stmts << "(let %#{r1} (ptr (ptr void)) (offset #{vbase} #{foff}))"
            r2 = regi; regi += 1
            stmts << "(let %#{r2} (ptr void) (load (ptr void) %#{r1}))"
            rty = ret_void ? "void" : dest_pt
            argstr = arg_vals.map(&:first).join(' ')
            if dest_agg
              dty = dest == "RETURN" ? ret : dest_ty
              dpt = rust_type_to_pathb(dty, types)
              stmts << "(eval (call void %#{r2} (sret #{dpt} #{dest_addr}) #{argstr}))"
            elsif ret_void
              stmts << "(eval (call void %#{r2} #{argstr}))"
            else
              r3 = regi; regi += 1
              stmts << "(let %#{r3} #{dest_pt} (call #{dest_pt} %#{r2} #{argstr}))"
              store_dest.call("%#{r3}")
            end
          else
            cv, regi = eval_rvalue_operand(callee_expr, types, locals, params, param_reg, stmts, regi, lines)
            rty = ret_void ? "void" : dest_pt
            argstr = arg_vals.map(&:first).join(' ')
            if dest_agg
              dty = dest == "RETURN" ? ret : dest_ty
              dpt = rust_type_to_pathb(dty, types)
              stmts << "(eval (call void #{cv} (sret #{dpt} #{dest_addr}) #{argstr}))"
            elsif ret_void
              stmts << "(eval (call void #{cv} #{argstr}))"
            else
              r3 = regi; regi += 1
              stmts << "(let %#{r3} #{dest_pt} (call #{dest_pt} #{cv} #{argstr}))"
              store_dest.call("%#{r3}")
            end
          end
          stmts << "(goto #{retblk.inspect})"
        else
          fname = fexpr
          if $extern_map && $extern_map[pb_sym(fname)]
            fname = $extern_map[pb_sym(fname)]
          end
          callee_code = "&\"#{pb_sym(fname)}\""
          argstr = arg_vals.map(&:first).join(' ')
          if dest == "RETURN"
            if $agg_ret
              dpt = rust_type_to_pathb(ret, types)
              stmts << "(eval (call void #{callee_code} (sret #{dpt} $\"retval\") #{argstr}))"
            elsif ret_void || pathb_ret == "void"
              stmts << "(eval (call void #{callee_code} #{argstr}))"
            else
              r = regi; regi += 1
              stmts << "(let %#{r} #{pathb_ret} (call #{pathb_ret} #{callee_code} #{argstr}))"
              $ret_reg = r
            end
            stmts << "(goto #{retblk.inspect})"
          else
            if dest_agg
              dpt = rust_type_to_pathb(dest_ty, types)
              stmts << "(eval (call void #{callee_code} (sret #{dpt} #{dest_addr}) #{argstr}))"
            elsif ret_void
              stmts << "(eval (call void #{callee_code} #{argstr}))"
            else
              r = regi; regi += 1
              stmts << "(let %#{r} #{dest_pt} (call #{dest_pt} #{callee_code} #{argstr}))"
              store_dest.call("%#{r}")
            end
            stmts << "(goto #{retblk.inspect})"
          end
        end
      elsif ln == "RETURN"
        if $agg_ret
          rsz, _ = type_size_align($cur_ret, types)
          stmts << "(copy #{rsz} %0 $\"retval\")"
          stmts << "(return)"
        elsif pathb_ret == "void"
          stmts << "(return)"
        elsif $ret_reg
          stmts << "(return %#{$ret_reg})"
        else
          stmts << "(return (const #{pathb_ret} 0))"
        end
      elsif ln == "DIVERGE"
        stmts << "(unreachable)"
      elsif ln.start_with?("GOTO")
        m = ln.match(/^GOTO (\d+)$/)
        stmts << "(goto #{m[1].inspect})" if m
      elsif ln.start_with?("IF")
        m = ln.match(/^IF (.+) goto (\d+) else (\d+)$/)
        if m
          cond = m[1].strip; tb = m[2]; fb = m[3]
          if cond.start_with?("df")
            d = cond.sub("df", "")
            r = regi; regi += 1
            stmts << "(let %#{r} bool (load bool $\"df#{d}\"))"
            stmts << "(if %#{r} (then (goto #{tb.inspect})) (else (goto #{fb.inspect})))"
          else
            cv, regi = eval_rvalue_operand(cond, types, locals, params, param_reg, stmts, regi, lines)
            stmts << "(if #{cv} (then (goto #{tb.inspect})) (else (goto #{fb.inspect})))"
          end
        end
      elsif ln.start_with?("SWITCH")
        m = ln.match(/^SWITCH (.+) \{ ([^}]*) \}$/)
        if m
          sval = m[1].strip; targets = m[2].split(",").map(&:strip).reject(&:empty?)
          sty = place_type(sval, types, locals, params)
          sv, regi = eval_rvalue_operand(sval, types, locals, params, param_reg, stmts, regi, lines)
          info = sty && types.key?(sty) ? types[sty] : nil
          if info && info[:tag]
            tag = info[:tag]
            toff = 0
            fty = nil
            cur_t = sty
            subs = tag[:sub].split(",").map(&:strip).reject(&:empty?).map(&:to_i)
            f0 = info[:fields][tag[:field]]
            if f0.nil?
              fty = nil
            else
              toff += f0[:off]
              cur_t = f0[:type]
              fty = cur_t
              subs.each do |pi|
                rec = cur_t && types.key?(cur_t) ? types[cur_t] : nil
                f = rec ? rec[:fields][pi] : nil
                if f.nil?
                  fty = nil
                  break
                end
                toff += f[:off]
                fty = f[:type]
                cur_t = fty
              end
            end
            fty = "u8" if fty.nil?
            saddr, regi = place_addr(sval, types, locals, params, param_reg, stmts, regi)
            lit0 = tag[:arms].find { |a| a[:val] != "*" }
            nbytes = 1
            if lit0
              nbytes = [1, lit0[:val].scan(/\\x[0-9A-Fa-f]{2}|\\0|\\.|[^\\"]/).size].max
            end
            fsz, _ = type_size_align(fty, types)
            fpt = rust_type_to_pathb(fty, types)
            if fsz != nbytes || fpt.start_with?("(")
              fpt = nbytes == 1 ? "unsigned_char" : (nbytes == 2 ? "unsigned_short" : (nbytes == 4 ? "unsigned_int" : "unsigned_long"))
            end
            r = regi; regi += 1
            if toff == 0
              stmts << "(let %#{r} #{fpt} (load #{fpt} #{saddr}))"
            else
              r0 = regi; regi += 1
              stmts << "(let %#{r0} (ptr #{fpt}) (offset #{saddr} #{toff}))"
              stmts << "(let %#{r} #{fpt} (load #{fpt} %#{r0}))"
            end
            arms = tag[:arms]
            decode_tag = lambda do |lit|
              bv = 0; bl = 0
              lit.scan(/\\x([0-9A-Fa-f]{2})|\\0|\\(.)|([^\\"])/) do |hx, esc, ch|
                if hx then bv |= hx.to_i(16) << (bl*8)
                elsif esc then bv |= esc.ord << (bl*8)
                elsif ch then bv |= ch.ord << (bl*8)
                end
                bl += 1
              end
              bv
            end
            if arms.all? { |a| a[:val] == "*" || a[:val].nil? }
              zidx = arms.index { |a| a[:val] != "*" } || 0
              zt = targets[zidx] || targets.first
              ot = targets.each_with_index.map { |t, i| i == zidx ? nil : t }.compact.first || targets.last
              cr = regi; regi += 1
              stmts << "(let %#{cr} bool (eq #{fpt} %#{r} (const #{fpt} 0)))"
              stmts << "(if %#{cr} (then (goto #{zt.inspect})) (else (goto #{ot.inspect})))"
            else
              cond_chain = targets.each_with_index.map do |t, i|
                arm = arms[i]
                av = nil
                if arm && arm[:val] && arm[:val] != "*"
                  av = decode_tag.call(arm[:val])
                end
                [t, av]
              end
              niche_idx = cond_chain.index { |_, av| av.nil? }
              emit_sw = lambda do |idx|
                idx += 1 while idx < cond_chain.size && cond_chain[idx][1].nil?
                if idx >= cond_chain.size
                  if niche_idx
                    "(goto #{cond_chain[niche_idx][0].inspect})"
                  else
                    "(unreachable)"
                  end
                elsif idx >= cond_chain.size - 1 && niche_idx.nil?
                  "(goto #{cond_chain[idx][0].inspect})"
                else
                  cr = regi; regi += 1
                  stmts << "(let %#{cr} bool (eq #{fpt} %#{r} (const #{fpt} #{cond_chain[idx][1]})))"
                  "(if %#{cr} (then (goto #{cond_chain[idx][0].inspect})) (else #{emit_sw.call(idx + 1)}))"
                end
              end
              stmts << emit_sw.call(0)
            end
          else
            if targets.size == 2
              stmts << "(if #{sv} (then (goto #{targets[0].inspect})) (else (goto #{targets[1].inspect})))"
            else
              stmts << "(goto #{targets.first.inspect})"
            end
          end
        end
      elsif ln.start_with?("PANIC")
        stmts << "(unreachable)"
      elsif ln.start_with?("INCOMPLETE")
        stmts << "(unreachable)"
      else
        # skip
      end
    end
  end

  func_text = []
  func_text << "(function #{name.inspect}"
  func_text << "  (ret #{pathb_ret})"
  func_text << "  (params #{param_lines.join(' ')})"
  # Weak: the dump repeats std functions that also live in mrustc's gcc-built
  # rlib objects (linked for the functions the dump lacks); the strong
  # definitions there win, and only this program's own functions bind here.
  # The bin main and its closures are unique to the dump either way.
  func_text << "  (weak)"
  slot_lines.each { |s| func_text << "  #{s}" }
  ($lit_slots || []).each { |s| func_text << "  #{s}" }
  stmts.each { |s| func_text << "  #{s}" }
  func_text << ")"
  lines << func_text.join("\n")
end


# alloc shims and panic globals (mrustc codegen_c provides these in the C route)
lines << "(global \"mrustc_panic_target\" (ptr void) 8 8 (thread) (init (zero 0 8)))"
lines << "(global \"mrustc_panic_value\" (ptr void) 8 8 (thread) (init (zero 0 8)))"
lines << "(global \"__rust_alloc_error_handler_should_panic\" unsigned_char 1 1 (init (zero 0 1)))"
lines << "(global \"__rust_no_alloc_shim_is_unstable\" unsigned_char 1 1 (init (zero 0 1)))"
lines << "(function \"__rust_alloc\" (ret (ptr signed_char)) (params (param %0 \"a0\" unsigned_long) (param %1 \"a1\" unsigned_long)) (let %10 (ptr signed_char) (call (ptr signed_char) &\"__rdl_alloc\" %0 %1)) (return %10))"
lines << "(function \"__rust_dealloc\" (ret void) (params (param %0 \"a0\" (ptr signed_char)) (param %1 \"a1\" unsigned_long) (param %2 \"a2\" unsigned_long)) (eval (call void &\"__rdl_dealloc\" %0 %1 %2)) (return))"
lines << "(function \"__rust_realloc\" (ret (ptr signed_char)) (params (param %0 \"a0\" (ptr signed_char)) (param %1 \"a1\" unsigned_long) (param %2 \"a2\" unsigned_long) (param %3 \"a3\" unsigned_long)) (let %10 (ptr signed_char) (call (ptr signed_char) &\"__rdl_realloc\" %0 %1 %2 %3)) (return %10))"
lines << "(function \"__rust_alloc_zeroed\" (ret (ptr signed_char)) (params (param %0 \"a0\" unsigned_long) (param %1 \"a1\" unsigned_long)) (let %10 (ptr signed_char) (call (ptr signed_char) &\"__rdl_alloc_zeroed\" %0 %1)) (return %10))"
lines << "(function \"__rust_no_alloc_shim_is_unstable_v2\" (ret void) (params) (return))"
lines << "(function \"__rust_alloc_error_handler_should_panic_v2\" (ret unsigned_char) (params) (return (const unsigned_char 0)))"
lines << "(function \"__rust_alloc_error_handler\" (ret void) (params (param %0 \"s\" unsigned_long) (param %1 \"a\" unsigned_long)) (eval (call void &\"abort\")) (return))"
lines << "(function \"panic_impl\" (ret unsigned_int) (params (param %0 \"payload\" unsigned_long)) (let %10 unsigned_int (call unsigned_int &\"ZRG2cD8std0_0_09panicking19begin_panic_handler0g\" %0)) (return %10))"


lines << "(function \"main\""
lines << "  (ret int)"
lines << "  (params)"
lines << "  (eval (call void &\"ZRG1cD3bin4main0g\"))"
lines << "  (return (const int 0))"
lines << ")"

output = lines.join("\n") + "\n"
if outpath
  File.write(outpath, output)
else
  puts output
end
