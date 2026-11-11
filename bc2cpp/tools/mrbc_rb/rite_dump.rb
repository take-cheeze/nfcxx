# frozen_string_literal: true

# The output formats of `mrbc` other than the -g RITE binary, derived from that binary (what MrbcRb.compile returns):
#   * strip: the binary without the debug section (no -g) and/or without the LVAR section (--remove-lv), as dump.c's
#     mrb_dump_irep writes it for those flags (the sections are independent, so this is a cut of the -g image);
#   * cfunc: `-B<symbol>` (mrb_dump_irep_cfunc: the binary as a C byte array);
#   * cstruct: `-B<symbol> -S` (mrb_dump_irep_cstruct in cdump.c: the irep tree as C structs).
# `-g` together with `-S`: cdump.c writes the symbol id of the file name, the number the symbol had in mrbc's own symbol table;
# file_syms.rb reproduces it from the sources (pass its result as file_syms:). Without file_syms: the first symbol after the
# presyms (FILENAME_SYM_BASE, 1472 for the fork's host mrbc) is only right for one input file.

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

    # `-B name -S` from a binary: parses it, then CDump.dump. (Where the irep tree is at hand, call CDump.dump with it.)
    def cstruct(image, name, static: false, sym_base: nil, file_syms: nil)
      require_relative 'cdump' # cdump.rb requires this file, so it is loaded on first use
      CDump.dump(parse(image), name, static: static, sym_base: sym_base, file_syms: file_syms)
    end
  end
end
