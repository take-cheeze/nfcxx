# frozen_string_literal: true

require_relative 'rite_dump'
require_relative 'cdump'

module MrbcRb
  # The instruction listing of `mrbc -v` (mrb_codedump_all, src/codedump.c), for the irep tree of a RITE image (what
  # MrbcRb.compile returns): one block per irep, depth first. The text is the C's, byte for byte, except the `irep 0x...`
  # address of each block (a pointer of the C process: here a counter, 0x...1000 up; compare modulo that number).
  # `mrbc -v` also prints the C parser's AST dump before the listing, which is not reproduced (it is the C grammar's tree).
  module Codedump
    OPS = %w[
      NOP:Z MOVE:BB LOADL:BB LOADI8:BB LOADINEG:BB LOADI__1:B LOADI_0:B LOADI_1:B LOADI_2:B LOADI_3:B LOADI_4:B LOADI_5:B
      LOADI_6:B LOADI_7:B LOADI16:BS LOADI32:BSS LOADSYM:BB LOADNIL:B LOADSELF:B LOADTRUE:B LOADFALSE:B GETGV:BB SETGV:BB
      GETSV:BB SETSV:BB GETIV:BB SETIV:BB GETCV:BB SETCV:BB GETCONST:BB SETCONST:BB GETMCNST:BB SETMCNST:BB GETUPVAR:BBB
      SETUPVAR:BBB GETIDX:B GETIDX0:BB SETIDX:B JMP:S JMPIF:BS JMPNOT:BS JMPNIL:BS JMPUW:S EXCEPT:B RESCUE:BB RAISEIF:B
      MATCHERR:B SSEND:BBB SSEND0:BB SSENDB:BBB SEND:BBB SEND0:BB SENDB:BBB CALL:Z BLKCALL:BB SUPER:BB ARGARY:BS ENTER:W
      KEY_P:BB KEYEND:Z KARG:BB RETURN:B RETURN_BLK:B RETSELF:Z RETNIL:Z RETTRUE:Z RETFALSE:Z BREAK:B BLKPUSH:BS ADD:B
      ADDI:BB SUB:B SUBI:BB ADDILV:BBB SUBILV:BBB MUL:B DIV:B EQ:B LT:B LE:B GT:B GE:B ARRAY:BB ARRAY2:BBB ARYCAT:B
      ARYPUSH:BB ARYSPLAT:B AREF:BBB ASET:BBB APOST:BBB INTERN:B SYMBOL:BB STRING:BB STRCAT:B HASH:BB HASHADD:BB HASHCAT:B
      LAMBDA:BB BLOCK:BB METHOD:BB RANGE_INC:B RANGE_EXC:B OCLASS:B CLASS:BB MODULE:BB EXEC:BB DEF:BB TDEF:BBB SDEF:BBB
      ALIAS:BB UNDEF:B SCLASS:B TCLASS:B DEBUG:BBB ERR:B EXT1:Z EXT2:Z EXT3:Z STOP:Z FSTRING:BB
    ].map { |s| s.split(':') }.freeze

    module_function

    def ident?(c) = c && (c.between?(48, 57) || c.between?(65, 90) || c.between?(97, 122) || c == 95)

    # symbol.c is_special_global_name, on bytes from +m+.
    def special_global?(b, m)
      c = b[m]
      case c
      when 126, 42, 36, 63, 33, 64, 47, 92, 59, 44, 46, 61, 58, 60, 62, 34, 38, 96, 39, 43, 48 then m += 1 # ~*$?!@/\;,.=:<>"&`'+0
      when 45
        m += 1
        m += 1 if ident?(b[m])
      else
        return false unless c&.between?(48, 57)

        m += 1 while b[m]&.between?(48, 57)
      end
      b[m].nil?
    end

    # symbol.c symname_p: a symbol that can be written without quotes.
    def symname_p(name)
      b = name.b.bytes
      return false if b.empty? || b.include?(0)

      m = 0
      localid = false
      id = false
      case b[0]
      when 36 # $
        m = 1
        return true if special_global?(b, m)

        id = true
      when 64 # @
        m = 1
        m += 1 if b[m] == 64
        id = true
      when 60 # <
        m += 1
        case b[m]
        when 60 then m += 1
        when 61
          m += 1
          m += 1 if b[m] == 62
        end
      when 62 # >
        m += 1
        m += 1 if [62, 61].include?(b[m])
      when 61 # =
        m += 1
        case b[m]
        when 126 then m += 1
        when 61
          m += 1
          m += 1 if b[m] == 61
        else return false
        end
      when 42 # *
        m += 1
        m += 1 if b[m] == 42
      when 33 # !
        m += 1
        m += 1 if [61, 126].include?(b[m])
      when 43, 45 # + -
        m += 1
        m += 1 if b[m] == 64
      when 124 # |
        m += 1
        m += 1 if b[m] == 124
      when 38 # &
        m += 1
        m += 1 if b[m] == 38
      when 94, 47, 37, 126, 96 then m += 1 # ^ / % ~ `
      when 91 # [
        m += 1
        return false unless b[m] == 93

        m += 1
        m += 1 if b[m] == 61
      else
        localid = !b[0].between?(65, 90)
        id = true
      end
      if id
        return false unless b[m] == 95 || b[m]&.between?(65, 90) || b[m]&.between?(97, 122)

        m += 1 while ident?(b[m])
        m += 1 if localid && [33, 63, 61].include?(b[m])
      end
      b[m].nil?
    end

    def sym_dump(sym)
      return '(null)'.b if sym.nil?

      symname_p(sym) ? sym.b : CDump.str_dump(sym).b
    end

    # The listing of the irep tree +root+ (RiteDump.parse of an image).
    def listing(root)
      out = String.new(encoding: Encoding::BINARY)
      counter = 0
      walk = lambda do |irep|
        counter += 1
        dump_irep(irep, out, format('0x%012x', 0x5555_0000_0000 + counter * 0x1000))
        irep.reps.each { |r| walk.call(r) }
      end
      walk.call(root)
      out
    end

    def unpack_be(s) = s.unpack1('N')

    def dump_irep(irep, out, addr)
      out << format("irep %s nregs=%d nlocals=%d pools=%d syms=%d reps=%d ilen=%d\n", addr, irep.nregs, irep.nlocals,
                    irep.pool.size, irep.syms.size, irep.reps.size, irep.ilen)
      if irep.lv
        head = false
        (1...irep.nlocals).each do |i|
          s = irep.lv[i - 1]
          next unless s

          unless head
            head = true
            out << "local variable names:\n"
          end
          out << "  R#{i}:" << sym_dump(s) << "\n"
        end
      end
      table = irep.iseq.byteslice(irep.ilen, irep.clen * RiteDump::CATCH_SIZE)
      irep.clen.times do |i|
        e = table.byteslice(i * 13, 13)
        type = { 0 => 'rescue', 1 => 'ensure' }[e.getbyte(0)] || format('0x%02x <unknown>', e.getbyte(0))
        out << format("catch type: %-8s begin: %04d end: %04d target: %04d\n", type, unpack_be(e.byteslice(1, 4)),
                      unpack_be(e.byteslice(5, 4)), unpack_be(e.byteslice(9, 4)))
      end
      Insns.new(irep, out).run
      out << "\n"
    end

    # codedump(): one irep's instructions.
    class Insns
      def initialize(irep, out)
        @irep = irep
        @out = out
        @iseq = irep.iseq.byteslice(0, irep.ilen).bytes
        @pc = 0
      end

      def b1 = @iseq.fetch(@pc).tap { @pc += 1 }

      def s2
        v = (@iseq[@pc] << 8) | @iseq[@pc + 1]
        @pc += 2
        v
      end

      def w3
        v = (@iseq[@pc] << 16) | (@iseq[@pc + 1] << 8) | @iseq[@pc + 2]
        @pc += 3
        v
      end

      def sym(i) = Codedump.sym_dump(@irep.syms[i])

      # mrb_debug_get_filename / mrb_debug_get_line
      def file_at(pc)
        f = file_entry(pc)
        f && f[1]
      end

      def file_entry(pc)
        files = @irep.debug
        return nil if files.nil? || pc >= @irep.ilen

        files.reverse_each { |f| return f if f[0] <= pc }
        nil
      end

      def line_at(pc)
        f = file_entry(pc)
        return -1 unless f

        data = f[3].bytes
        i = 0
        pos = line = 0
        varint = lambda do
          n = shift = 0
          loop do
            c = data[i]
            i += 1
            n |= (c & 0x7f) << shift
            shift += 7
            break unless shift < 32 && (c & 0x80) != 0
          end
          n
        end
        while i < data.size
          pos += varint.call
          diff = varint.call
          break if pc < pos

          line = (line + diff) & 0xffff_ffff
        end
        line >= 0x8000_0000 ? line - 0x1_0000_0000 : line
      end

      def header(i)
        line = line_at(i)
        @out << (line < 0 ? '      ' : format('%5d ', line)) << format('%03d ', i)
      end

      def r_p?(n) = n != 0 && @irep.lv && n < @irep.nlocals && !@irep.lv[n - 1].nil?

      def print_r(n)
        return if n == 0 || n >= @irep.nlocals || @irep.lv.nil? || @irep.lv[n - 1].nil?

        @out << " R#{n}:" << Codedump.sym_dump(@irep.lv[n - 1])
      end

      def lv_a(a)
        if r_p?(a)
          @out << "\t;"
          print_r(a)
        end
        @out << "\n"
      end

      def lv_ab(a, b)
        if r_p?(a) || r_p?(b)
          @out << "\t;"
          print_r(a)
          print_r(b)
        end
        @out << "\n"
      end

      def args(i)
        n = i & 0xf
        nk = (i >> 4) & 0xf
        @out << (n == 15 ? 'n=*' : "n=#{n}")
        @out << '|' << (nk == 15 ? 'nk=*' : "nk=#{nk}") if nk > 0
        @out << "\n"
      end

      def s16(v) = v >= 0x8000 ? v - 0x10000 : v

      def cstr(s) = s.b.split("\0", 2).first.to_s

      def run
        file = nil
        while @pc < @irep.ilen
          i = @pc
          nf = file_at(i)
          if nf && file != nf
            @out << "file: " << nf.b << "\n"
            file = nf
          end
          header(i)
          ins = b1
          insn(ins, 0)
        end
      end

      # +ext+: 0 none, 1 first operand 16 bit, 2 second, 3 both (OP_EXT1..3).
      def insn(ins, ext)
        name, fmt = OPS[ins]
        if name.nil?
          @out << format("unknown_op (0x%x)\n", ins)
          return
        end
        a = b = c = nil
        case fmt
        when 'Z' then nil
        when 'B' then a = ext.odd? ? s2 : b1
        when 'BB'
          a = ext.odd? ? s2 : b1
          b = ext >= 2 ? s2 : b1
        when 'BBB'
          a = ext.odd? ? s2 : b1
          b = ext >= 2 ? s2 : b1
          c = b1
        when 'BS'
          a = ext.odd? ? s2 : b1
          b = s2
        when 'BSS'
          if ext.odd?
            a = s2
            b = s2
            c = s2
          else
            a = b1
            b = s2
            c = s2
          end
        when 'S' then a = s2
        when 'W' then a = w3
        end
        o = @out
        case name
        when 'NOP' then o << "NOP\n"
        when 'MOVE'
          o << "MOVE\t\tR#{a}\tR#{b}"
          lv_ab(a, b)
        when 'LOADL'
          kind, v = @irep.pool[b]
          case kind
          when :float then o << format("LOADL\t\tR%d\tL[%d]\t; %s", a, b, c_float(v))
          when :i32, :i64 then o << format("LOADL\t\tR%d\tL[%d]\t; %d", a, b, v)
          else o << format("LOADL\t\tR%d\tL[%d]", a, b)
          end
          lv_a(a)
        when 'LOADI8'
          o << "LOADI8\tR#{a}\t#{b}"
          lv_a(a)
        when 'LOADINEG'
          o << "LOADINEG\tR#{a}\t-#{b}"
          lv_a(a)
        when 'LOADI16'
          o << "LOADI16\tR#{a}\t#{s16(b)}"
          lv_a(a)
        when 'LOADI32'
          v = ((b << 16) + c) & 0xffff_ffff
          v -= 0x1_0000_0000 if v >= 0x8000_0000
          o << "LOADI32\tR#{a}\t#{v}"
          lv_a(a)
        when 'LOADI__1'
          o << "LOADI__1\tR#{a}\t(-1)"
          lv_a(a)
        when /\ALOADI_(\d)\z/
          o << "LOADI_#{$1}\tR#{a}\t(#{$1})"
          lv_a(a)
        when 'LOADSYM'
          o << "LOADSYM\tR#{a}\t:" << sym(b)
          lv_a(a)
        when 'LOADNIL'
          o << "LOADNIL\tR#{a}\t(nil)"
          lv_a(a)
        when 'LOADSELF'
          o << "LOADSELF\tR#{a}\t(R0)"
          lv_a(a)
        when 'LOADTRUE'
          o << "LOADTRUE\tR#{a}\t(true)"
          lv_a(a)
        when 'LOADFALSE'
          o << "LOADFALSE\tR#{a}\t(false)"
          lv_a(a)
        when 'GETGV', 'GETSV', 'GETIV', 'GETCV'
          o << "#{name}\t\tR#{a}\t" << sym(b)
          lv_a(a)
        when 'SETGV', 'SETSV', 'SETIV', 'SETCV'
          o << "#{name}\t\t" << sym(b) << "\tR#{a}"
          lv_a(a)
        when 'GETCONST'
          o << "GETCONST\tR#{a}\t" << sym(b)
          lv_a(a)
        when 'SETCONST'
          o << "SETCONST\t" << sym(b) << "\tR#{a}"
          lv_a(a)
        when 'GETMCNST'
          o << "GETMCNST\tR#{a}\t(R#{a})::" << sym(b)
          lv_a(a)
        when 'SETMCNST'
          o << "SETMCNST\t(R#{a + 1})::" << sym(b) << "\tR#{a}"
          lv_a(a)
        when 'GETUPVAR', 'SETUPVAR'
          o << "#{name}\tR#{a}\t#{b}\t#{c}"
          lv_a(a)
        when 'GETIDX' then o << "GETIDX\tR#{a}\t(R#{a + 1})\n"
        when 'GETIDX0' then o << "GETIDX0\tR#{a}\tR#{b}[0]\n"
        when 'SETIDX' then o << "SETIDX\tR#{a}\t(R#{a + 1})\t(R#{a + 2})\n"
        when 'JMP' then o << format("JMP\t\t%03d\n", @pc + s16(a))
        when 'JMPUW' then o << format("JMPUW\t\t%03d\n", @pc + s16(a))
        when 'JMPIF', 'JMPNOT', 'JMPNIL'
          o << format("#{name}#{name == 'JMPIF' ? "\t\t" : "\t"}R%d\t%03d", a, @pc + s16(b))
          lv_a(a)
        when 'SSEND', 'SSENDB', 'SEND', 'SENDB'
          tabs = name == 'SSENDB' ? "\t" : "\t\t"
          o << "#{name}#{tabs}R#{a}\t:" << sym(b) << "\t"
          args(c)
        when 'SSEND0', 'SEND0'
          o << "#{name}#{name == 'SSEND0' ? "\t" : "\t\t"}R#{a}\t:" << sym(b) << "\n"
        when 'CALL' then o << "CALL\n"
        when 'BLKCALL' then o << "BLKCALL\t\tR#{a}\t#{b}\n"
        when 'SUPER'
          o << "SUPER\t\tR#{a}\t"
          args(b)
        when 'ARGARY', 'BLKPUSH'
          o << format("#{name}\tR%d\t%d:%d:%d:%d (%d)", a, (b >> 11) & 0x3f, (b >> 10) & 1, (b >> 5) & 0x1f, (b >> 4) & 1, b & 0xf)
          lv_a(a)
        when 'ENTER'
          o << format("ENTER\t\t%d:%d:%d:%d:%d:%d:%d:%d (0x%x)\n", (a >> 18) & 0x1f, (a >> 13) & 0x1f, (a >> 12) & 1,
                      (a >> 7) & 0x1f, (a >> 2) & 0x1f, (a >> 1) & 1, a & 1, (a >> 23) & 1, a)
        when 'KEY_P', 'KARG'
          o << "#{name}\t\tR#{a}\t:" << sym(b)
          lv_a(a)
        when 'KEYEND' then o << "KEYEND\n"
        when 'RETURN'
          o << "RETURN\tR#{a}\t"
          lv_a(a)
        when 'RETURN_BLK'
          o << "RETURN_BLK\tR#{a}\t"
          lv_a(a)
        when 'RETSELF', 'RETNIL', 'RETTRUE', 'RETFALSE', 'STOP' then o << "#{name}\n"
        when 'BREAK'
          o << "BREAK\t\tR#{a}\t"
          lv_a(a)
        when 'LAMBDA', 'METHOD' then o << "#{name}\tR#{a}\tI[#{b}]\n"
        when 'BLOCK' then o << "BLOCK\t\tR#{a}\tI[#{b}]\n"
        when 'RANGE_INC', 'RANGE_EXC' then o << "#{name}\tR#{a}\n"
        when 'DEF' then o << "DEF\t\tR#{a}\t:" << sym(b) << "\t(R#{a + 1})\n"
        when 'TDEF', 'SDEF' then o << "#{name}\t\tR#{a}\t:" << sym(b) << "\tI[#{c}]\n"
        when 'UNDEF' then o << "UNDEF\t\t:" << sym(a) << "\n"
        when 'ALIAS' then o << "ALIAS\t\t:" << sym(a) << "\t" << sym(b) << "\n"
        when 'ADD', 'SUB', 'MUL', 'DIV', 'LT', 'LE', 'GT', 'GE', 'EQ'
          o << "#{name}\t\tR#{a}\t(R#{a + 1})\n"
        when 'ADDI', 'SUBI'
          o << "#{name}\t\tR#{a}\t#{b}"
          lv_a(a)
        when 'ADDILV', 'SUBILV'
          o << "#{name}\tR#{a}\tR#{b}\t#{c}"
          lv_a(a)
        when 'ARRAY'
          o << "ARRAY\t\tR#{a}\t#{b}"
          lv_a(a)
        when 'ARRAY2'
          o << "ARRAY\t\tR#{a}\tR#{b}\t#{c}"
          lv_ab(a, b)
        when 'ARYCAT'
          o << "ARYCAT\tR#{a}\t(R#{a + 1})"
          lv_a(a)
        when 'ARYPUSH'
          o << "ARYPUSH\tR#{a}\t#{b}"
          lv_a(a)
        when 'ARYSPLAT'
          o << "ARYSPLAT\tR#{a}"
          lv_a(a)
        when 'AREF', 'ASET'
          o << "#{name}\t\tR#{a}\tR#{b}\t#{c}"
          lv_ab(a, b)
        when 'APOST'
          o << "APOST\t\tR#{a}\t#{b}\t#{c}"
          lv_a(a)
        when 'INTERN'
          o << "INTERN\tR#{a}\t"
          lv_a(a)
        when 'SYMBOL'
          o << "SYMBOL\tR#{a}\tL[#{b}]\t; " << cstr(@irep.pool[b][1])
          lv_a(a)
        when 'STRING', 'FSTRING'
          o << "#{name}\tR#{a}\tL[#{b}]"
          s = cstr(@irep.pool[b][1])
          o << "\t; " << s unless s.empty?
          lv_a(a)
        when 'STRCAT'
          o << "STRCAT\tR#{a}\t(R#{a + 1})"
          lv_a(a)
        when 'HASH'
          o << "HASH\t\tR#{a}\t#{b}"
          lv_a(a)
        when 'HASHADD'
          o << "HASHADD\tR#{a}\t#{b}"
          lv_a(a)
        when 'HASHCAT'
          o << "HASHCAT\tR#{a}\t(R#{a + 1})"
          lv_a(a)
        when 'OCLASS'
          o << "OCLASS\tR#{a}\t"
          lv_a(a)
        when 'CLASS'
          o << "CLASS\t\tR#{a}\t:" << sym(b)
          lv_a(a)
        when 'MODULE'
          o << "MODULE\tR#{a}\t:" << sym(b)
          lv_a(a)
        when 'EXEC'
          o << "EXEC\t\tR#{a}\tI[#{b}]"
          lv_a(a)
        when 'SCLASS'
          o << "SCLASS\tR#{a}"
          lv_a(a)
        when 'TCLASS'
          o << "TCLASS\tR#{a}\t"
          lv_a(a)
        when 'ERR'
          kind, v = @irep.pool[a]
          if kind == :str then o << "ERR\t\t" << cstr(v) << "\n"
          else o << "ERR\tL[#{a}]\n"
          end
        when 'EXCEPT'
          o << "EXCEPT\tR#{a}\t"
          lv_a(a)
        when 'RESCUE'
          o << "RESCUE\tR#{a}\tR#{b}"
          lv_ab(a, b)
        when 'RAISEIF'
          o << "RAISEIF\tR#{a}\t"
          lv_a(a)
        when 'MATCHERR' then o << "MATCHERR\tR#{a}\n"
        when 'DEBUG' then o << "DEBUG\t\t#{a}\t#{b}\t#{c}\n"
        when 'EXT1', 'EXT2', 'EXT3'
          o << "#{name}\n"
          header(@pc)
          insn(b1, name[-1].to_i)
        end
      end

      def c_float(v)
        return (v.nan? ? 'nan' : (v > 0 ? 'inf' : '-inf')) if v.nan? || v.infinite?

        format('%f', v)
      end
    end
  end
end
