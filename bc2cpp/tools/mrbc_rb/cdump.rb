# frozen_string_literal: true

# `-B<symbol> -S` (mrb_dump_irep_cstruct in cdump.c): the irep tree as C structs, and `-B<symbol>` (mrb_dump_irep_cfunc): a
# RITE binary as a C byte array. CDump.dump takes the irep tree (RiteDump::Irep: what MrbcRb.compile_result builds from the
# emitter's data, or RiteDump.parse reads from a binary for inputs that arrive as .mrb), so no serialized bytes are re-read.
# `-g` together with `-S`: cdump.c writes the symbol id of the file name, the number the symbol had in mrbc's own symbol table;
# file_syms.rb reproduces it from the sources (pass its result as file_syms:). Without file_syms: the first symbol after the
# presyms (FILENAME_SYM_BASE, 1472 for the fork's host mrbc) is only right for one input file.

require_relative 'rite_dump'

module MrbcRb
  module CDump
    Unsupported = RiteDump::Unsupported
    FILENAME_SYM_BASE = RiteDump::FILENAME_SYM_BASE
    Irep = RiteDump::Irep

    module_function

    # A copy of the irep tree +root+ as mrbc writes it with or without -g (debug) and --remove-lv (lvar).
    def strip(root, debug:, lvar:)
      Irep.new(root.nlocals, root.nregs, root.clen, root.ilen, root.iseq, root.pool, root.syms,
               root.reps.map { |r| strip(r, debug: debug, lvar: lvar) }, lvar ? root.lv : nil, debug ? root.debug : nil)
    end

    # `-B name` (static: -s): the C byte array of a RITE binary.
    def cfunc(image, name, static: false) = RiteDump.cfunc(image, name, static: static)

    # `-B name -S`: the irep tree +root+ as C structs (with the debug tables when it has debug info: -g).
    def dump(root, name, static: false, sym_base: nil, file_syms: nil)
      base = sym_base || FILENAME_SYM_BASE
      files = []
      each_irep(root) { |i| files.concat(i.debug.map { |f| f[1] }) if i.debug }
      files.uniq!
      # file_syms: { file name => id } from FileSyms.ids; without it only one file is known (the first symbol after the presyms)
      raise Unsupported, 'file name symbol ids of several files (-g -S)' if files.size > 1 && !file_syms
      file_syms ||= files.each_with_index.to_h { |f, i| [f, base + 1 + i] }
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

    def each_irep(irep, &blk) = RiteDump.each_irep(irep, &blk)


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

  end
end
