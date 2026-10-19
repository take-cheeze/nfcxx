#!/usr/bin/env ruby
# monomir-to-pathb.rb: translate mrustc monomir (.mir) to Path B IR (.ir)
abort "usage: #{$0} INPUT.mir [OUTPUT.ir]" if ARGV.empty?
input = ARGV[0]
outpath = ARGV[1]
src = File.read(input)

types = {}
src.scan(/^type (.+?) \{\n(.*?)\n\}/m) do |name, body|
  size = 0; align = 1; fields = []
  body.each_line do |ln|
    ln = ln.strip
    m = ln.match(/^SIZE (\d+), ALIGN (\d+);/)
    if m
      size = m[1].to_i; align = m[2].to_i; next
    end
    m = ln.match(/^(\d+) = (.+);$/)
    if m
      fields << {off: m[1].to_i, type: m[2].strip}
    end
  end
  types[name.strip] = {size: size, align: align, fields: fields}
end

def split_top(s)
  res = []; depth = 0; cur = ""
  s.each_char do |c|
    if c == "(" || c == "[" || c == "{" || c == "<"
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
    if rest == "str" || rest.start_with?("[") || rest.start_with?("dyn")
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
      if rest == "str" || rest.start_with?("[") || rest.start_with?("dyn")
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
  name = m[1]
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

def eval_simple(expr, types, locals, params)
  expr = expr.strip
  # BINOP
  if expr.start_with?("BINOP")
    parts = expr.sub(/^BINOP\s+/, "").split(/\s+/, 3)
    # parts: [L, op, R] but L/R may contain spaces? L/R are simple tokens/projections without spaces usually
    # Re-parse: find op token
    # Format: BINOP <left_expr> <op> <right_expr> where left/right have no spaces except projections
    m = expr.match(/^BINOP\s+(.+?)\s+(<=?|>=?|==|!=|<<|>>|[+\-*\/%&|^])\s+(.+)$/)
    if m
      l = m[1].strip; op = m[2]; r = m[3].strip
      lt = eval_simple(l, types, locals, params)
      rt = eval_simple(r, types, locals, params)
      # determine type from l if const? default int
      ty = "int"
      # if l is a const with type, extract
      cm = l.match(/^\+?[\-]?\d+\s+([A-Za-z0-9_]+)$/)
      if cm
        ty = rust_type_to_pathb(cm[1], types) rescue "int"
      end
      # signedness guess: unsigned if ty contains unsigned
      unsigned = ty.include?("unsigned")
      case op
      when "+" then return "(wadd #{ty} #{lt} #{rt})"
      when "-" then return "(wsub #{ty} #{lt} #{rt})"
      when "*" then return "(wmul #{ty} #{lt} #{rt})"
      when "/" then return "(cdiv #{ty} #{lt} #{rt})"
      when "%" then return "(crem #{ty} #{lt} #{rt})"
      when "&" then return "(and #{ty} #{lt} #{rt})"
      when "|" then return "(or #{ty} #{lt} #{rt})"
      when "^" then return "(xor #{ty} #{lt} #{rt})"
      when "<<" then return "(cshl #{ty} #{lt} #{rt})"
      when ">>" then return "(cshr #{ty} #{lt} #{rt})"
      when "==" then return "(eq #{ty} #{lt} #{rt})"
      when "!=" then return "(ne #{ty} #{lt} #{rt})"
      when "<" then return "(#{unsigned ? "lt.u" : "lt.s"} #{ty} #{lt} #{rt})"
      when "<=" then return "(#{unsigned ? "le.u" : "le.s"} #{ty} #{lt} #{rt})"
      when ">" then return "(#{unsigned ? "lt.u" : "lt.s"} #{ty} #{rt} #{lt})"
      when ">=" then return "(#{unsigned ? "le.u" : "le.s"} #{ty} #{rt} #{lt})"
      end
    end
  end
  # projection: (*argN).field or (*varN).field
  m = expr.match(/^\(\*(arg|var)(\d+)\)\.(\d+)$/)
  if m
    kind = m[1]; idx = m[2].to_i; field = m[3].to_i
    if kind == "arg"
      reg = idx  # may be remapped? assume direct
      # find type of arg
      # field 0 of closure is fn ptr
      return "(load (fn void ()) %#{reg})"
    else
      return "(load (fn void ()) $\"var#{idx}\")"
    end
  end
  if locals.map(&:first).include?(expr) || expr.start_with?("var") || expr.start_with?("arg")
    expr = "=" + expr
  end
  if expr.start_with?("=")
    place = expr[1..-1].strip
    name = place.split(/[^A-Za-z0-9_]/).first
    t = nil
    locals.each { |n, ty| t = ty if n == name }
    if name.start_with?("arg")
      i = name.sub("arg", "").to_i
      t = params[i] if i < params.size
    end
    pt = t ? rust_type_to_pathb(t, types) : "unsigned_long"
    return "(load #{pt} $\"#{name}\")"
  end
  if expr.start_with?("ADDROF")
    target = expr.sub(/^ADDROF\s+/, "").strip
    return "&#{target.inspect}"
  end
  if expr.start_with?("&")
    place = expr[1..-1].strip
    name = place.split(/[^A-Za-z0-9_]/).first
    return "$\"#{name}\""
  end
  m = expr.match(/^([+-]?\d+)\s+([A-Za-z0-9_]+)$/)
  if m
    val = m[1].sub(/^\+/, ""); ty = m[2]
    pt = rust_type_to_pathb(ty, types)
    return "(const #{pt} #{val})"
  end
  expr
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

functions = []
src.scan(/^fn (.+?)\s*\{\n(.*?)\n\}/m) do |header, body|
  functions << {header: header.strip, body: body}
end
src.scan(/^fn (.+?) = (.*?);\n/m) do |header, linkage|
  functions << {header: header.strip, body: nil, linkage: linkage.strip}
end

lines = []
lines << "(ir-module \"#{File.basename(input)}\" (layout (short 2) (int 4) (long 8) (long_long 8) (pointer 8) (float 4) (double 8) (long_double 16)))"

statics.each do |st|
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
    segname = "#{st[:name]}_bytes#{i}"
    lines << "(data #{segname.inspect} (array #{seglen} (const char)) (string \"#{segenc}\"))"
    items << "(bytes #{i} #{seglen} @\"#{segname}\")"
    i = j
  end
  relocs.each do |off, len, target|
    if target.start_with?('"')
      tname = target.gsub(/^"|"$/, '')
      str_data = "#{st[:name]}_str#{off}"
      lines << "(data #{str_data.inspect} (array #{tname.bytesize + 1} (const char)) (string \"#{tname}\"))"
      items << "(addr #{off} (ptr (const char)) @\"#{str_data}\" 0)"
    else
      items << "(addr #{off} (ptr (const char)) &\"#{target}\" 0)"
    end
  end
  lines << "(global #{st[:name].inspect} #{pathb_ty} #{size} #{align} (init #{items.join(' ')}))"
end

functions.each do |fn|
  header = fn[:header]
  name, params_str, ret = parse_fn_header(header)
  next if fn[:body].nil?
  next if name == "panic_impl" || name.start_with?("panic_impl")
  next if name == "main"
  params = parse_params_str(params_str)
  pathb_ret = rust_type_to_pathb(ret, types)
  body = fn[:body]
  locals = []
  body.scan(/^\tlet (.+?): (.+);$/) { |n, t| locals << [n.strip, t.strip] }
  slot_lines = []
  locals.each do |n, t|
    sz, al = type_size_align(t, types)
    al = 1 if al == 0
    sz = 1 if sz == 0
    slot_lines << "(slot #{n.inspect} #{rust_type_to_pathb(t, types)} #{sz} #{al})"
  end
  param_lines = []
  param_reg = {}
  ri = 0
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

  blocks = {}
  body.scan(/^\t(\d+): \{\n(.*?)\n\t\}/m) do |num, content|
    blocks[num] = content
  end
  block_nums = body.scan(/^\t(\d+): \{\s*$/).flatten.sort_by(&:to_i)

  regi = 100
  stmts = []
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
        dst_name = place.split(/[^A-Za-z0-9_]/).first
        if dst_name == "RETURN"
            if rhs.strip.gsub(/\s+/, "") == "()"
                # nothing
            else
                dst_type = pathb_ret
                dst_pt = pathb_ret == "void" ? "void" : pathb_ret
                val = eval_simple(rhs, types, locals, params)
                if pathb_ret != "void"
                    stmts << "(let %99 #{pathb_ret} #{val})"
                end
            end
            next
        end
        dst_type = nil
        locals.each { |n, t| dst_type = t if n == dst_name }
        if dst_name.start_with?("arg")
          i = dst_name.sub("arg", "").to_i
          dst_type = params[i] if i < params.size
        end
        dst_pt = dst_type ? rust_type_to_pathb(dst_type, types) : "unsigned_long"

        if rhs.start_with?("MAKEDST")
          parts = rhs.sub(/^MAKEDST\s+/, "").split(",", 2).map(&:strip)
          ptr_expr = parts[0]
          meta_expr = parts[1]
          r1 = regi; regi += 1
          stmts << "(let %#{r1} (ptr (const char)) #{eval_simple(ptr_expr, types, locals, params)})"
          stmts << "(store (ptr (const char)) $\"#{dst_name}\" %#{r1})"
          r2 = regi; regi += 1
          stmts << "(let %#{r2} unsigned_long #{eval_simple(meta_expr, types, locals, params)})"
          r3 = regi; regi += 1
          stmts << "(let %#{r3} (ptr unsigned_long) (offset $\"#{dst_name}\" 8))"
          stmts << "(store unsigned_long %#{r3} %#{r2})"
        elsif rhs.start_with?("ENUM")
          m2 = rhs.match(/^ENUM \S+ (\d+)/)
          idx = m2 ? m2[1].to_i : 0
          sz, _ = dst_type ? type_size_align(dst_type, types) : [8,8]
          sz = 1 if sz == 0
          stmts << "(zero-fill #{sz} $\"#{dst_name}\")"
        elsif rhs.start_with?("{")
          inner = rhs[1..rhs.rindex("}")-1].strip
          fields = split_top(inner)
          offsets = []
          field_types = []
          if dst_type && types.key?(dst_type)
            offsets = types[dst_type][:fields].map { |f| f[:off] }
            field_types = types[dst_type][:fields].map { |f| f[:type] }
          end
          offsets = (0...fields.size).map { |i| i * 8 } if offsets.empty? || offsets.size != fields.size
          fields.each_with_index do |f, i|
            frt = (field_types && field_types[i]) ? field_types[i] : nil
            fsize, _ = frt ? type_size_align(frt, types) : [8,8]
            ft = frt ? rust_type_to_pathb(frt, types) : "unsigned_long"
            fstrip = f.strip
            if fstrip.start_with?("arg")
              val = "%#{fstrip.sub('arg','').to_i}"
            elsif fstrip.start_with?("var")
              if fsize > 8 || (ft.start_with?("(") && !ft.start_with?("(ptr") && !ft.start_with?("(fn"))
                val = "$\"#{fstrip}\""
              else
                r = regi; regi += 1
                stmts << "(let %#{r} #{ft} (load #{ft} $\"#{fstrip}\"))"
                val = "%#{r}"
              end
            else
              val = eval_simple(fstrip, types, locals, params)
            end
            off = offsets[i] || (i * 8)
            if off == 0
              addr = "$\"#{dst_name}\""
            else
              r = regi; regi += 1
              stmts << "(let %#{r} (ptr #{ft}) (offset $\"#{dst_name}\" #{off}))"
              addr = "%#{r}"
            end
            if fsize > 8 || (ft.start_with?("(") && !ft.start_with?("(ptr") && !ft.start_with?("(fn"))
              stmts << "(copy #{fsize} #{addr} #{val})"
            else
              stmts << "(store #{ft} #{addr} #{val})"
            end
          end
        elsif rhs.strip.gsub(/\s+/, "") == "()"
          # nothing
        else
          val = eval_simple(rhs, types, locals, params)
          r = regi; regi += 1
          stmts << "(let %#{r} #{dst_pt} #{val})"
          stmts << "(store #{dst_pt} $\"#{dst_name}\" %#{r})"
        end
      elsif ln.start_with?("CALL")
        m = ln.match(/^CALL (.+?) = (.+) goto (\d+) else (\d+)$/)
        dest = m[1].strip
        call_expr = m[2].strip
        retblk = m[3]
        panicblk = m[4]
        # find the outermost args parens (scan from the end)
        s = call_expr.strip
        if s.start_with?("(")
            # indirect call: (callee)(args)
            # first group
            pdepth = 0
            close1 = nil
            (0...s.bytesize).each do |j|
                c = s[j]
                if c == "("
                    pdepth += 1
                elsif c == ")"
                    pdepth -= 1
                    if pdepth == 0
                        close1 = j
                        break
                    end
                end
            end
            callee_str = s[1...close1].strip
            rest = s[close1+1..-1].strip
            # args group
            if rest.start_with?("(")
                pdepth = 0
                close2 = nil
                (0...rest.bytesize).each do |j|
                    c = rest[j]
                    if c == "("
                        pdepth += 1
                    elsif c == ")"
                        pdepth -= 1
                        if pdepth == 0
                            close2 = j
                            break
                        end
                    end
                end
                args_str = rest[1...close2].strip
            else
                args_str = ""
            end
            fexpr = nil
            indirect_callee = callee_str
        else
            adepth = 0
            pdepth = 0
            start = nil
            s.each_char.with_index do |c, i|
                if c == "<"
                    adepth += 1
                elsif c == ">"
                    adepth -= 1 if adepth > 0
                elsif c == "("
                    if adepth == 0 && pdepth == 0
                        start = i
                        break
                    end
                    pdepth += 1
                elsif c == ")"
                    pdepth -= 1 if pdepth > 0
                end
            end
            if start.nil?
                fexpr = s
                args_str = ""
            else
                fexpr = s[0...start].strip
                pdepth = 0
                close = nil
                (start...s.bytesize).each do |j|
                    c = s[j]
                    if c == "("
                        pdepth += 1
                    elsif c == ")"
                        pdepth -= 1
                        if pdepth == 0
                            close = j
                            break
                        end
                    end
                end
                args_str = s[start+1...close].strip
            end
            indirect_callee = nil
        end
        if indirect_callee
            # callee is a place/expression; evaluate to register if needed
            callee_expr = indirect_callee.strip
            cname = callee_expr.split(/[^A-Za-z0-9_]/).first
            # param register?
            if cname.start_with?("arg")
                i = cname.sub("arg","").to_i
                # map to param_reg if available
                r = (defined?(param_reg) && param_reg[i]) ? param_reg[i] : i
                callee_val = "%#{r}"
                fname = nil
            elsif name.start_with?("var") || locals.map(&:first).include?(name)
                t = nil
                locals.each { |n, ty| t = ty if n == name }
                pt = t ? rust_type_to_pathb(t, types) : "unsigned_long"
                r = regi; regi += 1
                stmts << "(let %#{r} #{pt} (load #{pt} $\"#{name}\"))"
                callee_val = "%#{r}"
                fname = nil
            else
                fname = callee_expr
            end
        else
            if fexpr =~ /\"([^\"]+)\"/
                fexpr = $1
            end
            if fexpr == "ZRG2cD8std0_0_02rt10lang_start0g"
                fexpr = "ZRG2cD8std0_0_02rt10lang_start1gT0"
                args_str = args_str.empty? ? "0 u8" : args_str + ", 0 u8"
            end
            fname = fexpr
        end
        args = args_str.empty? ? [] : split_top(args_str)
        arg_code = args.map do |a|
          a = a.strip
          # deref without field: (*argN) or (*varN)
          m0 = a.match(/^\(\*(arg|var)(\d+)\)$/)
          if m0
            kind = m0[1]; idx = m0[2].to_i
            if kind == "arg"
              r = param_reg[idx]
              r.nil? ? nil : "%#{r}"
            else
              "$\"var#{idx}\""
            end
          else
          # projection (*argN).field or (*varN).field
          m = a.match(/^\(\*(arg|var)(\d+)\)\.(\d+)$/)
          if m
            kind = m[1]; idx = m[2].to_i; field = m[3].to_i
            if kind == "arg"
                r = regi; regi += 1
                stmts << "(let %#{r} (fn void ()) (load (fn void ()) %#{idx}))"
                "%#{r}"
            else
                r = regi; regi += 1
                stmts << "(let %#{r} (fn void ()) (load (fn void ()) $\"var#{idx}\"))"
                "%#{r}"
            end
          elsif a.start_with?("var") || a.start_with?("arg") || locals.map(&:first).include?(a)
            if a.start_with?("arg")
              i = a.sub("arg", "").to_i
              r = param_reg[i]
              r.nil? ? nil : "%#{r}"
            else
              t = nil
              locals.each { |n, ty| t = ty if n == a }
              if t && (t.include?("[") || types.key?(t) || t.start_with?("&"))
                "(byval #{rust_type_to_pathb(t, types)} $\"#{a}\")"
              elsif t == "()" || t == "!"
                nil
              else
                pt = t ? rust_type_to_pathb(t, types) : "unsigned_long"
                r = regi; regi += 1
                stmts << "(let %#{r} #{pt} (load #{pt} $\"#{a}\"))"
                "%#{r}"
              end
            end
          else
            val = eval_simple(a, types, locals, params)
            if val.start_with?("(") && !val.start_with?("(const") && !val.start_with?("(load")
                r = regi; regi += 1
                stmts << "(let %#{r} unsigned_long #{val})"
                "%#{r}"
            else
                val
            end
          end
        end
        end
        arg_code = arg_code.compact
        if fname == "black_box"
            stmts << "(goto #{retblk.inspect})"
            next
        end
        callee_code = fname ? "&\"#{fname}\"" : callee_val
        if dest == "RETURN"
          if pathb_ret == "void"
            stmts << "(eval (call void #{callee_code} #{arg_code.join(' ')}))"
          else
            stmts << "(let %99 #{pathb_ret} (call #{pathb_ret} #{callee_code} #{arg_code.join(' ')}))"
          end
          stmts << "(goto #{retblk.inspect})"
        else
          stmts << "(eval (call void #{callee_code} #{arg_code.join(' ')}))"
          stmts << "(goto #{retblk.inspect})"
        end
      elsif ln == "RETURN"
        if pathb_ret == "void"
          stmts << "(return)"
        else
          stmts << "(return %99)"
        end
      elsif ln == "DIVERGE"
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
  slot_lines.each { |s| func_text << "  #{s}" }
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
