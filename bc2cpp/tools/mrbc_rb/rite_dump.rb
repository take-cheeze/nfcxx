# frozen_string_literal: true

# The output formats of `mrbc` other than the -g RITE binary, derived from that binary (what MrbcRb.compile returns):
#   * strip: the binary without the debug section (no -g) and/or without the LVAR section (--remove-lv), as dump.c's
#     mrb_dump_irep writes it for those flags (the sections are independent, so this is a cut of the -g image);
#   * cfunc: `-B<symbol>` (mrb_dump_irep_cfunc: the binary as a C byte array);
#   * cstruct: `-B<symbol> -S` (mrb_dump_irep_cstruct in cdump.c: the irep tree as C structs).
# `-g` together with `-S`: cdump.c writes the symbol id of the file name, the number the symbol had in mrbc's own symbol table.
# For one input file mrbc interns the file name first, so its id is the number of presyms of that mrbc plus one: FILENAME_SYM_BASE
# (1472 for the fork this was written against; MRBC_RB_FILENAME_SYM_BASE overrides it, and cli_test.rb checks it against the
# real mrbc). The base is that mrbc build's presym count (MRB_PRESYM_MAX in its include/mruby/presym/id.h). With several files the
# ids depend on what the parser interned between the files: not covered (Unsupported), unless MRBC_RB_LOOSE_FILENAME_SYM=1, which
# numbers the files base+1, base+2, ...: not the bytes of mrbc, but the value is only a placeholder (the generated
# <name>_init_syms assigns filename_sym from the file name at start-up, so the program is the same).

module MrbcRb
  module RiteDump
    Unsupported = Class.new(StandardError)

    HEADER = 20
    CATCH_SIZE = 13 # struct mrb_irep_catch_handler: type, begin, end, target

    Irep = Struct.new(:nlocals, :nregs, :clen, :ilen, :iseq, :pool, :syms, :reps, :lv, :debug)

    FILENAME_SYM_BASE = 1472

    module_function

    # [[ident, body] ...] of the sections of a RITE binary.
    def sections(image)
      raise Unsupported, 'not a RITE binary' unless image.byteslice(0, 8) == 'RITE0400'.b

      pos = HEADER
      out = []
      while pos < image.bytesize
        ident = image.byteslice(pos, 4)
        size = image.byteslice(pos + 4, 4).unpack1('N')
        out << [ident, image.byteslice(pos + 8, size - 8)]
        pos += size
      end
      out
    end

    def rebuild(secs)
      body = secs.map { |ident, b| [ident, b.bytesize + 8].pack('a4N') + b }.join.b
      ['RITE0400', HEADER + body.bytesize].pack('a8N') + 'MATZ0000'.b + body
    end

    # The binary +image+ (with debug info and LVAR) as mrbc writes it with or without -g and --remove-lv.
    def strip(image, debug:, lvar:)
      secs = sections(image).reject { |ident, _| (ident == "DBG\0" && !debug) || (ident == 'LVAR' && !lvar) }
      rebuild(secs)
    end

    # `-B name` (static: -s): the C byte array.
    def cfunc(image, name, static: false)
      out = +"#include <stdint.h>\n#{static ? 'static' : "#ifdef __cplusplus\nextern\n#endif"}\nconst uint8_t #{name}[] = {"
      image.each_byte.each_slice(16) do |row|
        out << "\n" << row.map { |b| format('0x%02x,', b) }.join
      end
      out << "\n};\n"
      out
    end

    # ---- parsing ----

    def parse(image)
      secs = sections(image)
      irep_body = secs.find { |i, _| i == 'IREP' }&.last or raise Unsupported, 'no IREP section'
      root, = read_irep(irep_body, 4) # after the version
      lvar = secs.find { |i, _| i == 'LVAR' }&.last
      read_lvar(root, lvar) if lvar
      dbg = secs.find { |i, _| i == "DBG\0" }&.last
      read_debug(root, dbg) if dbg
      root
    end

    # The DBG section: the file name table, then per irep (depth first) its files: [start_pos, name, entry count, line type, bytes].
    def read_debug(root, b)
      n = b.byteslice(0, 2).unpack1('n')
      p = 2
      names = Array.new(n) do
        len = b.byteslice(p, 2).unpack1('n')
        s = b.byteslice(p + 2, len)
        p += 2 + len
        s
      end
      each_irep(root) do |irep|
        size = b.byteslice(p, 4).unpack1('N')
        flen = b.byteslice(p + 4, 2).unpack1('n')
        q = p + 6
        irep.debug = Array.new(flen) do
          start, idx, count, type = b.byteslice(q, 11).unpack('NnNC')
          raise Unsupported, 'debug line type other than the packed map' unless type == 2

          data = b.byteslice(q + 11, count)
          q += 11 + count
          [start, names[idx], count, data]
        end
        raise Unsupported, 'debug record size mismatch' unless q - p == size

        p = q
      end
    end

    def read_irep(b, pos)
      recsize = b.byteslice(pos, 4).unpack1('N')
      nlocals, nregs, rlen, clen, ilen = b.byteslice(pos + 4, 12).unpack('nnnnN')
      p = pos + 16
      iseq = b.byteslice(p, ilen + clen * CATCH_SIZE)
      p += iseq.bytesize
      plen = b.byteslice(p, 2).unpack1('n')
      p += 2
      pool = Array.new(plen) do
        tag = b.getbyte(p)
        p += 1
        case tag
        when 0
          len = b.byteslice(p, 2).unpack1('n')
          s = b.byteslice(p + 2, len)
          p += 3 + len
          [:str, s]
        when 1 then v = b.byteslice(p, 4).unpack1('l>'); p += 4; [:i32, v]
        when 3 then v = b.byteslice(p, 8).unpack1('q>'); p += 8; [:i64, v]
        when 5 then v = b.byteslice(p, 8).unpack1('E'); p += 8; [:float, v]
        when 7
          len = b.getbyte(p)
          s = b.byteslice(p, len + 2)
          p += len + 2
          [:bigint, s]
        else raise Unsupported, "pool tag #{tag}"
        end
      end
      slen = b.byteslice(p, 2).unpack1('n')
      p += 2
      syms = Array.new(slen) do
        len = b.byteslice(p, 2).unpack1('n')
        p += 2
        next nil if len == 0xffff

        s = b.byteslice(p, len)
        p += len + 1
        s
      end
      raise Unsupported, 'irep record size mismatch' unless p - pos == recsize

      irep = Irep.new(nlocals, nregs, clen, ilen, iseq, pool, syms, [], nil)
      rlen.times do
        child, p = read_irep(b, p)
        irep.reps << child
      end
      [irep, p]
    end

    def each_irep(irep, &blk)
      yield irep
      irep.reps.each { |r| each_irep(r, &blk) }
    end

    def read_lvar(root, b)
      n = b.byteslice(0, 4).unpack1('N')
      p = 4
      names = Array.new(n) do
        len = b.byteslice(p, 2).unpack1('n')
        s = b.byteslice(p + 2, len)
        p += 2 + len
        s
      end
      each_irep(root) do |irep|
        cnt = irep.nlocals - 1
        next if cnt <= 0

        refs = b.byteslice(p, 2 * cnt).unpack('n*')
        p += 2 * cnt
        irep.lv = refs.map { |r| r == 0xffff ? nil : names[r] }
      end
    end

    # ---- cdump.c ----

    OPERATORS = [
      ['!', 'not'], ['%', 'mod'], ['&', 'and'], ['*', 'mul'], ['+', 'add'], ['-', 'sub'], ['/', 'div'], ['<', 'lt'],
      ['>', 'gt'], ['^', 'xor'], ['`', 'tick'], ['|', 'or'], ['~', 'neg'], ['!=', 'neq'], ['!~', 'nmatch'],
      ['&&', 'andand'], ['**', 'pow'], ['+@', 'plus'], ['-@', 'minus'], ['<<', 'lshift'], ['<=', 'le'], ['==', 'eq'],
      ['=~', 'match'], ['>=', 'ge'], ['>>', 'rshift'], ['[]', 'aref'], ['||', 'oror'], ['<=>', 'cmp'], ['===', 'eqq'],
      ['[]=', 'aset']
    ].freeze

    def word?(s) = s.match?(/\A[A-Za-z_][A-Za-z0-9_]*\z/n)

    # sym_operator_name: the binary search of cdump.c over the table (ordered by the operator's length, then bytes; the
    # result is the word), ported as is.
    def operator_name(name)
      size = OPERATORS.size
      return nil if OPERATORS.last[0].bytesize < name.bytesize

      start = 0
      while size != 0
        idx = start + size / 2
        text, word = OPERATORS[idx]
        cmp = name.bytesize - text.bytesize
        if cmp == 0
          cmp = name <=> text.b
          return word if cmp == 0
        end
        if cmp > 0
          start = idx + 1
          size -= 1
        end
        size /= 2
      end
      nil
    end

    # mrb_str_dump (str_escape without inspect).
    def str_dump(s)
      out = +'"'
      bytes = s.bytes
      bytes.each_with_index do |c, i|
        nxt = bytes[i + 1]
        if c == 0x22 || c == 0x5c || (c == 0x23 && nxt && [0x24, 0x40, 0x7b].include?(nxt))
          out << '\\' << c.chr
        elsif c >= 0x20 && c <= 0x7e
          out << c.chr
        else
          cc = { 10 => 'n', 13 => 'r', 9 => 't', 12 => 'f', 11 => 'v', 8 => 'b', 7 => 'a', 27 => 'e' }[c]
          out << (cc ? "\\#{cc}" : format('\\x%02x', c))
        end
      end
      out << '"'
    end

    # cdump_sym: appends the C for one symbol to +out+; a symbol with no macro form is 0 and an assignment in +init+.
    def cdump_sym(sym, var, idx, init, out)
      if sym.nil?
        out << '0,'
        return
      end
      s = sym.b
      if word?(s) then out << "MRB_SYM(#{s})"
      elsif s.bytesize >= 2 && s.end_with?('=') && word?(s[0...-1]) then out << "MRB_SYM_E(#{s[0...-1]})"
      elsif s.bytesize >= 2 && s.end_with?('?') && word?(s[0...-1]) then out << "MRB_SYM_Q(#{s[0...-1]})"
      elsif s.bytesize >= 2 && s.end_with?('!') && word?(s[0...-1]) then out << "MRB_SYM_B(#{s[0...-1]})"
      elsif s.bytesize >= 2 && s.start_with?('@') && word?(s[1..]) then out << "MRB_IVSYM(#{s[1..]})"
      elsif s.bytesize >= 3 && s.start_with?('@@') && word?(s[2..]) then out << "MRB_CVSYM(#{s[2..]})"
      elsif (op = operator_name(s)) then out << "MRB_OPSYM(#{op})"
      else
        init << "  #{var}[#{idx}] = mrb_intern_lit(mrb, #{str_dump(s)});\n"
        out << '0'
      end
      out << ', '
    end

    def cdump_syms(name, key, n, syms, init, out)
      var = "#{name}_#{key}_#{n}"
      before = init.bytesize
      out << "mrb_DEFINE_SYMS_VAR(#{var}, #{syms.size}, ("
      syms.each_with_index { |s, i| cdump_sym(s, var, i, init, out) }
      out << '), ' << (before == init.bytesize ? 'const' : '') << ");\n"
    end

    def cdump_pool(entry, out)
      kind, v = entry
      case kind
      when :i64
        out << (v < -0x8000_0000 || v > 0x7fff_ffff ? "{IREP_TT_INT64, {.i64=#{v}}},\n" : "{IREP_TT_INT32, {.i32=#{v}}},\n")
      when :i32 then out << "{IREP_TT_INT32, {.i32=#{v}}},\n"
      when :float then out << "{IREP_TT_FLOAT, {.f=#{format('%.17g', v)}}},\n"
      when :bigint then out << '{IREP_TT_BIGINT, {"' << v.bytes.map { |c| format('\\x%02x', c) }.join << "\"}},\n"
      when :str then out << "{IREP_TT_SSTR|(#{v.bytesize}<<2), {\"" << v.bytes.map { |c| format('\\x%02x', c) }.join << "\"}},\n"
      end
    end

    # cdump_debug: only for an irep with one file (simple_debug_info); false when it writes nothing.
    def cdump_debug(irep, out, name, n, init, file_syms)
      return false unless irep.debug.size == 1

      start, file, count, data = irep.debug[0]
      init << "  #{name}_debug_file_#{n}.filename_sym = mrb_intern_lit(mrb,#{str_dump(file)});\n"
      out << "static const char #{name}_debug_lines_#{n}[] = \"" << data.bytes.map { |c| format('\\x%02x', c) }.join << "\";\n"
      out << "static mrb_irep_debug_info_file #{name}_debug_file_#{n} = {\n"
      out << "#{start}, #{file_syms.fetch(file)}, #{count}, mrb_debug_line_packed_map, {#{name}_debug_lines_#{n}}};\n"
      out << "static mrb_irep_debug_info_file *#{name}_debug_file_#{n}_ = &#{name}_debug_file_#{n};\n"
      out << "static mrb_irep_debug_info #{name}_debug_#{n} = {\n"
      out << "#{irep.ilen}, 1, &#{name}_debug_file_#{n}_};\n"
      true
    end

    # cdump_irep_struct. +mp+ is a one-element array (the running irep number), as in the C.
    def cdump_irep(irep, out, name, n, init, mp, file_syms)
      max = mp[0]
      unless irep.reps.empty?
        irep.reps.each_with_index do |r, i|
          mp[0] += irep.reps.size
          cdump_irep(r, out, name, max + i, init, mp, file_syms)
        end
        out << "static const mrb_irep *const #{name}_reps_#{n}[#{irep.reps.size}] = {\n"
        irep.reps.each_index { |i| out << "  &#{name}_irep_#{max + i},\n" }
        out << "};\n"
      end
      unless irep.pool.empty?
        out << "static const mrb_irep_pool #{name}_pool_#{n}[#{irep.pool.size}] = {\n"
        irep.pool.each { |e| cdump_pool(e, out) }
        out << "};\n"
      end
      cdump_syms(name, 'syms', n, irep.syms, init, out) unless irep.syms.empty?
      out << "static const mrb_code #{name}_iseq_#{n}[#{irep.iseq.bytesize}] = {"
      irep.iseq.bytes.each_with_index do |c, i|
        out << "\n" if i % 20 == 0
        out << format('0x%02x,', c)
      end
      out << "};\n"
      cdump_syms(name, 'lv', n, irep.lv, init, out) if irep.lv
      debug = cdump_debug(irep, out, name, n, init, file_syms) if irep.debug
      out << "static const mrb_irep #{name}_irep_#{n} = {\n"
      out << "  #{irep.nlocals},#{irep.nregs},#{irep.clen},\n"
      out << "  MRB_IREP_STATIC,#{name}_iseq_#{n},\n"
      out << (irep.pool.empty? ? '  NULL,' : "  #{name}_pool_#{n},")
      out << (irep.syms.empty? ? 'NULL,' : "#{name}_syms_#{n},")
      out << (irep.reps.empty? ? "NULL,\n" : "#{name}_reps_#{n},\n")
      out << "#ifndef MRB_NO_IREP_DEBUG\n"
      out << (irep.lv ? "  #{name}_lv_#{n},\n" : "  NULL,\t\t\t\t\t/* lv */\n")
      out << (debug ? "  &#{name}_debug_#{n},\n" : "  NULL,\t\t\t\t\t/* debug_info */\n")
      out << "#endif\n"
      out << "  #{irep.ilen},#{irep.pool.size},#{irep.syms.size},#{irep.reps.size},0\n};\n"
    end

    # `-B name -S`: the irep tree of +image+ as C structs (with the debug tables when +image+ has the DBG section: -g).
    def cstruct(image, name, static: false, sym_base: nil)
      root = parse(image)
      base = sym_base || Integer(ENV.fetch('MRBC_RB_FILENAME_SYM_BASE', FILENAME_SYM_BASE))
      files = []
      each_irep(root) { |i| files.concat(i.debug.map { |f| f[1] }) if i.debug }
      files.uniq!
      loose = ENV['MRBC_RB_LOOSE_FILENAME_SYM'] == '1'
      raise Unsupported, 'file name symbol ids of several files (-g -S)' if files.size > 1 && !loose
      file_syms = files.each_with_index.to_h { |f, i| [f, base + 1 + i] }
      out = +"#include <mruby.h>\n#include <mruby/irep.h>\n#include <mruby/debug.h>\n#include <mruby/proc.h>\n\n"
      out << "#define mrb_BRACED(...) {__VA_ARGS__}\n"
      out << "#define mrb_DEFINE_SYMS_VAR(name, len, syms, qualifier) \\\n"
      out << "  static qualifier mrb_sym name[len] = mrb_BRACED syms\n\n"
      init = +''
      cdump_irep(root, out, name, 0, init, [1], file_syms)
      out << (static ? "static\n" : "#ifdef __cplusplus\nextern\n#endif\n")
      out << "const struct RProc #{name}[] = {{\n"
      out << "NULL,MRB_TT_PROC,MRB_GC_RED,MRB_OBJ_IS_FROZEN,0,{&#{name}_irep_0},NULL,{NULL},\n}};\n"
      out << "static void\n#{name}_init_syms(mrb_state *mrb)\n{\n#{init}}\n"
      out
    end
  end
end
