# frozen_string_literal: true

require_relative 'rite_binary'
require_relative 'operand_schema'

# Decodes a RiteBinary irep's iseq bytes into the Insn stream bc2cpp's passes
# consume. Typed operands come straight from the decoded operand values; the
# `args`/`raw` text is synthesized in src/codedump.c's exact print format
# because diagnostics and generated-code comments still show it.
module InsnDecoder
  # mruby/ops.h, in opcode order (OP_NOP == 0); scripts/bc2cpp_binary_loader_check.rb
  # compares this table with the header.
  FORMATS = %w[
    NOP:Z MOVE:BB LOADL:BB LOADI8:BB LOADINEG:BB LOADI__1:B LOADI_0:B LOADI_1:B LOADI_2:B LOADI_3:B
    LOADI_4:B LOADI_5:B LOADI_6:B LOADI_7:B LOADI16:BS LOADI32:BSS LOADSYM:BB LOADNIL:B LOADSELF:B
    LOADTRUE:B LOADFALSE:B GETGV:BB SETGV:BB GETSV:BB SETSV:BB GETIV:BB SETIV:BB GETCV:BB SETCV:BB
    GETCONST:BB SETCONST:BB GETMCNST:BB SETMCNST:BB GETUPVAR:BBB SETUPVAR:BBB GETIDX:B GETIDX0:BB
    SETIDX:B JMP:S JMPIF:BS JMPNOT:BS JMPNIL:BS JMPUW:S EXCEPT:B RESCUE:BB RAISEIF:B MATCHERR:B
    SSEND:BBB SSEND0:BB SSENDB:BBB SEND:BBB SEND0:BB SENDB:BBB CALL:Z BLKCALL:BB SUPER:BB ARGARY:BS
    ENTER:W KEY_P:BB KEYEND:Z KARG:BB RETURN:B RETURN_BLK:B RETSELF:Z RETNIL:Z RETTRUE:Z RETFALSE:Z
    BREAK:B BLKPUSH:BS ADD:B ADDI:BB SUB:B SUBI:BB ADDILV:BBB SUBILV:BBB MUL:B DIV:B EQ:B LT:B LE:B
    GT:B GE:B ARRAY:BB ARRAY2:BBB ARYCAT:B ARYPUSH:BB ARYSPLAT:B AREF:BBB ASET:BBB APOST:BBB INTERN:B
    SYMBOL:BB STRING:BB STRCAT:B HASH:BB HASHADD:BB HASHCAT:B LAMBDA:BB BLOCK:BB METHOD:BB RANGE_INC:B
    RANGE_EXC:B OCLASS:B CLASS:BB MODULE:BB EXEC:BB DEF:BB TDEF:BBB SDEF:BBB ALIAS:BB UNDEF:B SCLASS:B
    TCLASS:B DEBUG:BBB ERR:B EXT1:Z EXT2:Z EXT3:Z STOP:Z
  ].map { |entry| entry.split(':') }.freeze

  EXT_WIDTH = { 'EXT1' => 1, 'EXT2' => 2, 'EXT3' => 3 }.freeze
  OPERAND_BYTES = { 'B' => 1, 'S' => 2, 'W' => 3 }.freeze
  Operand = OperandSchema::Operand

  # EXT1/EXT2/EXT3 are folded into the instruction they widen (ADR 0320), so no pass sees a prefix
  # between a producer and its consumer. BC2CPP_EXT_PREFIX=0 keeps the prefix as its own Insn.
  def self.fold_ext_prefix? = ENV['BC2CPP_EXT_PREFIX'] != '0'

  # Tab padding codedump.c prints between an op name and its operands.
  TWO_TABS = %w[
    MOVE LOADL GETGV SETGV GETSV SETSV GETIV SETIV GETCV SETCV JMP JMPUW JMPIF SSEND SEND SEND0 SENDB
    BLKCALL SUPER ENTER KEY_P KARG BREAK BLOCK DEF TDEF SDEF UNDEF ALIAS ADD ADDI SUB SUBI MUL DIV LT
    LE GT GE EQ ARRAY ARRAY2 AREF ASET APOST HASH CLASS EXEC ERR DEBUG
  ].freeze
  ONE_TAB = %w[
    LOADI8 LOADINEG LOADI16 LOADI32 LOADI__1 LOADI_0 LOADI_1 LOADI_2 LOADI_3 LOADI_4 LOADI_5 LOADI_6
    LOADI_7 LOADSYM LOADNIL LOADSELF LOADTRUE LOADFALSE GETCONST SETCONST GETMCNST SETMCNST GETUPVAR
    SETUPVAR GETIDX GETIDX0 SETIDX JMPNOT JMPNIL SSEND0 SSENDB ARGARY RETURN RETURN_BLK BLKPUSH LAMBDA
    METHOD RANGE_INC RANGE_EXC ADDILV SUBILV ARYCAT ARYPUSH ARYSPLAT INTERN SYMBOL STRING STRCAT HASHADD
    HASHCAT OCLASS MODULE SCLASS TCLASS EXCEPT RESCUE RAISEIF MATCHERR
  ].freeze
  SEPS = (TWO_TABS.to_h { |n| [n, "\t\t"] }
    .merge(ONE_TAB.to_h { |n| [n, "\t"] })
    .merge(%w[NOP CALL KEYEND RETSELF RETNIL RETTRUE RETFALSE STOP EXT1 EXT2 EXT3].to_h { |n| [n, ''] })).freeze

  # Operand byte widths of an instruction; EXT1 widens the first operand and
  # EXT2 the second, EXT3 both (ops.h FETCH_*_1/_2/_3). Only one-byte operands
  # widen, and a lone B operand is widened by EXT1 only.
  OPERAND_SIZES = Hash.new do |cache, (format, ext)|
    cache[[format, ext]] = compute_operand_sizes(format, ext).freeze
  end

  def self.operand_sizes(format, ext)
    OPERAND_SIZES[[format, ext]]
  end

  def self.compute_operand_sizes(format, ext)
    sizes = format.delete('Z').chars.map { |c| OPERAND_BYTES.fetch(c) }
    widen = case ext
            when 1 then [0]
            when 2 then sizes.length > 1 ? [1] : []
            when 3 then sizes.length > 1 ? [0, 1] : []
            else []
            end
    widen.each { |i| sizes[i] = 2 if sizes[i] == 1 }
    sizes
  end

  # mrb_sym_dump: the bare name when it is a valid symbol name, else the
  # name as a dumped (quoted, escaped) string.
  module SymbolDump
    module_function

    def call(name)
      name = name.b
      return name.dup.force_encoding(Encoding::UTF_8) if valid?(name) && !name.include?("\0")

      dump(name).force_encoding(Encoding::UTF_8)
    end

    def ident_char?(c) = c && c.match?(/[A-Za-z0-9_]/)

    def special_global?(m)
      case m[0]
      when '~', '*', '$', '?', '!', '@', '/', '\\', ';', ',', '.', '=', ':', '<', '>', '"', '&', '`', "'", '+', '0'
        m.length == 1
      when '-' then m.length == 1 || (m.length == 2 && ident_char?(m[1]))
      else m.match?(/\A[0-9]+\z/)
      end
    end

    # symname_p in src/symbol.c.
    def valid?(name)
      return false if name.empty?

      s = name.dup.force_encoding(Encoding::BINARY)
      localid = false
      case s[0]
      when '$'
        rest = s[1..]
        return true if special_global?(rest)

        s = rest
      when '@' then s = s[1] == '@' ? s[2..] : s[1..]
      when '<' then return s.match?(/\A(<<|<=>|<=|<)\z/)
      when '>' then return s.match?(/\A(>>|>=|>)\z/)
      when '=' then return s.match?(/\A(=~|===|==)\z/)
      when '*' then return s.match?(/\A(\*\*|\*)\z/)
      when '!' then return s.match?(/\A(!=|!~|!)\z/)
      when '+', '-' then return s.match?(/\A[+-]@?\z/)
      when '|' then return s.match?(/\A(\|\||\|)\z/)
      when '&' then return s.match?(/\A(&&|&)\z/)
      when '^', '/', '%', '~', '`' then return s.length == 1
      when '[' then return s.match?(/\A\[\]=?\z/)
      else localid = !s[0].match?(/[A-Z]/)
      end
      s.match?(localid ? /\A[A-Za-z_][A-Za-z0-9_]*[!?=]?\z/ : /\A[A-Za-z_][A-Za-z0-9_]*\z/)
    end

    ESCAPES = { "\n" => 'n', "\r" => 'r', "\t" => 't', "\f" => 'f', "\v" => 'v', "\b" => 'b', "\a" => 'a',
                "\e" => 'e' }.freeze

    # mrb_str_dump (str_escape with inspect off): every non-printable or
    # non-ASCII byte is escaped.
    def dump(name)
      out = +'"'
      bytes = name.bytes
      bytes.each_with_index do |byte, index|
        c = byte.chr
        if c == '"' || c == '\\' || (c == '#' && %w[{ $ @].include?(bytes[index + 1]&.chr))
          out << "\\#{c}"
        elsif byte >= 0x20 && byte < 0x7f
          out << c
        elsif ESCAPES.key?(c)
          out << "\\#{ESCAPES[c]}"
        else
          out << format('\\x%02x', byte)
        end
      end
      out << '"'
    end
  end

  # A RiteIrep's instructions and file. Returns [insns, file].
  def self.decode(rite)
    Decoder.new(rite).run
  end

  class Decoder
    def initialize(rite)
      @rite = rite
      @iseq = rite.iseq
      @syms = rite.syms
      @lv = rite.lv
      @lines = {}
    end

    def run
      insns = []
      file = nil
      pc = 0
      ext = 0
      ext_start = nil
      fold = InsnDecoder.fold_ext_prefix?
      while pc < @iseq.bytesize
        start = pc
        name, format = FORMATS.fetch(@iseq.getbyte(pc)) { raise "bc2cpp: unknown opcode at #{pc}" }
        # codedump prints the file at the start of every loop turn.
        file = debug_file_at(start)&.filename || file
        sizes = InsnDecoder.operand_sizes(format, ext)
        pc += 1
        values = sizes.map do |size|
          raise "bc2cpp: iseq overrun at #{pc}" if pc + size > @iseq.bytesize

          value = 0
          size.times { |k| value = (value << 8) | @iseq.getbyte(pc + k) }
          pc += size
          value
        end
        if fold && EXT_WIDTH.key?(name)
          raise "bc2cpp: EXT prefix at #{start} follows another prefix" if ext_start

          ext = EXT_WIDTH.fetch(name)
          ext_start = start
          next
        end
        # The folded Insn starts at the prefix byte (branch and handler addresses name it) but takes
        # its line from the widened opcode, as the unfolded listing does.
        insns << build(name, values, pc, ext_start || start, start)
        ext = fold ? 0 : EXT_WIDTH.fetch(name, 0)
        ext_start = nil
      end
      raise "bc2cpp: EXT prefix at #{ext_start} ends the iseq" if ext_start

      [insns, file]
    end

    private

    def debug_file_at(pc)
      files = @rite.debug_files
      return nil if files.nil? || files.empty? || pc >= @iseq.bytesize

      files.reverse_each.find { |f| f.start_pos <= pc } || files.first
    end

    # mrb_debug_get_line for a packed line map (-1 without debug info).
    def line_at(pc)
      file = debug_file_at(pc)
      return -1 unless file

      table = (@lines[file.object_id] ||= packed_line_table(file.lines))
      idx = table.bsearch_index { |pos, _| pc < pos }
      return s32(table.empty? ? 0 : table.last[1]) if idx.nil?

      s32(idx.zero? ? 0 : table[idx - 1][1])
    end

    # [[pos, cumulative line including this entry], ...]
    def packed_line_table(bytes)
      pos = 0
      line = 0
      offset = 0
      table = []
      while offset < bytes.bytesize
        delta, offset = packed_int(bytes, offset)
        diff, offset = packed_int(bytes, offset)
        pos = (pos + delta) & 0xffff_ffff
        line = (line + diff) & 0xffff_ffff # uint32 arithmetic in debug.c
        table << [pos, line]
      end
      table
    end

    def packed_int(bytes, offset)
      n = 0
      shift = 0
      loop do
        byte = bytes.getbyte(offset)
        offset += 1
        n |= (byte & 0x7f) << shift
        shift += 7
        break unless shift < 32 && byte.anybits?(0x80)
      end
      [n, offset]
    end

    def sym(index)
      name = @syms.fetch(index) or raise "bc2cpp: null symbol #{index}"
      SymbolDump.call(name)
    end

    def s16(value) = value >= 0x8000 ? value - 0x1_0000 : value
    def s32(value) = value >= 0x8000_0000 ? value - 0x1_0000_0000 : value

    # print_lv_a/print_lv_ab: `; R5:name` for registers with a local name.
    def lv_comment(*regs)
      return '' if @lv.nil?

      shown = regs.map do |n|
        n &= 0xffff
        n.positive? && n < @rite.nlocals && @lv[n - 1] ? " R#{n}:#{SymbolDump.call(@lv[n - 1])}" : nil
      end
      shown.any? ? "\t;#{shown.compact.join}" : ''
    end

    def argc(value)
      n = value & 0xf
      nk = (value >> 4) & 0xf
      text = "n=#{n == 15 ? '*' : n}"
      text += "|nk=#{nk == 15 ? '*' : nk}" if nk.positive?
      [Operand.new(:argc, [n == 15 ? nil : n, nk == 15 ? nil : nk, nk.zero?]), text]
    end

    # The disassembly prints a pool string as a C string, so it stops at NUL.
    def pool_str(index)
      entry = @rite.pool.fetch(index)
      raise "bc2cpp: pool #{index} is not a string" unless entry.kind == :str

      entry.value.split("\0", 2).first.to_s.dup.force_encoding(Encoding::UTF_8)
    end

    def loadl_comment(index)
      entry = @rite.pool.fetch(index)
      case entry.kind
      when :float then format("\t; %f", entry.value)
      when :int32, :int64 then "\t; #{entry.value}"
      else ''
      end
    end

    def r(n) = Operand.new(:reg, n)
    def pr(n) = Operand.new(:preg, n)
    def i(n) = Operand.new(:int, n)
    def sym_op(index) = Operand.new(:sym, sym(index))
    def name_op(index) = Operand.new(:name, sym(index))
    def lit(text) = Operand.new(:plit, text)

    # [operand text as codedump prints it, typed operands]; #build adds the
    # op name and its tab padding.
    # rubocop:disable Metrics/CyclomaticComplexity, Metrics/MethodLength
    def body(name, v, next_pc)
      a, b, c = v
      case name
      when 'NOP', 'CALL', 'KEYEND', 'RETSELF', 'RETNIL', 'RETTRUE', 'RETFALSE', 'STOP', 'EXT1', 'EXT2', 'EXT3'
        ['', []]
      when 'MOVE', 'RESCUE' then ["R#{a}\tR#{b}#{lv_comment(a, b)}", [r(a), r(b)]]
      when 'LOADL' then ["R#{a}\tL[#{b}]#{loadl_comment(b)}#{lv_comment(a)}", [r(a), Operand.new(:pool, b)]]
      when 'LOADI8' then ["R#{a}\t#{b}#{lv_comment(a)}", [r(a), i(b)]]
      when 'LOADINEG' then ["R#{a}\t-#{b}#{lv_comment(a)}", [r(a), i(-b)]]
      when 'LOADI16' then ["R#{a}\t#{s16(b)}#{lv_comment(a)}", [r(a), i(s16(b))]]
      when 'LOADI32'
        n = ((b << 16) + c) & 0xffff_ffff
        n -= 0x1_0000_0000 if n >= 0x8000_0000
        ["R#{a}\t#{n}#{lv_comment(a)}", [r(a), i(n)]]
      when 'LOADI__1' then ["R#{a}\t(-1)#{lv_comment(a)}", [r(a), lit('-1')]]
      when /\ALOADI_(\d)\z/ then ["R#{a}\t(#{Regexp.last_match(1)})#{lv_comment(a)}", [r(a), lit(Regexp.last_match(1))]]
      when 'LOADSYM' then ["R#{a}\t:#{sym(b)}#{lv_comment(a)}", [r(a), sym_op(b)]]
      when 'LOADNIL' then ["R#{a}\t(nil)#{lv_comment(a)}", [r(a), lit('nil')]]
      when 'LOADSELF' then ["R#{a}\t(R0)#{lv_comment(a)}", [r(a), pr(0)]]
      when 'LOADTRUE' then ["R#{a}\t(true)#{lv_comment(a)}", [r(a), lit('true')]]
      when 'LOADFALSE' then ["R#{a}\t(false)#{lv_comment(a)}", [r(a), lit('false')]]
      when 'GETGV', 'GETSV', 'GETIV', 'GETCV', 'GETCONST' then ["R#{a}\t#{sym(b)}#{lv_comment(a)}", [r(a), name_op(b)]]
      when 'SETGV', 'SETSV', 'SETIV', 'SETCV', 'SETCONST' then ["#{sym(b)}\tR#{a}#{lv_comment(a)}", [name_op(b), r(a)]]
      when 'GETMCNST' then ["R#{a}\t(R#{a})::#{sym(b)}#{lv_comment(a)}", [r(a), Operand.new(:mcnst, [a, sym(b)])]]
      when 'SETMCNST'
        ["(R#{a + 1})::#{sym(b)}\tR#{a}#{lv_comment(a)}", [Operand.new(:mcnst, [a + 1, sym(b)]), r(a)]]
      when 'GETUPVAR', 'SETUPVAR' then ["R#{a}\t#{b}\t#{c}#{lv_comment(a)}", [r(a), i(b), i(c)]]
      when 'GETIDX' then ["R#{a}\t(R#{a + 1})", [r(a), pr(a + 1)]]
      when 'GETIDX0' then ["R#{a}\tR#{b}[0]", [r(a), Operand.new(:idx0, b)]]
      when 'SETIDX' then ["R#{a}\t(R#{a + 1})\t(R#{a + 2})", [r(a), pr(a + 1), pr(a + 2)]]
      when 'JMP', 'JMPUW' then [format('%03d', next_pc + s16(a)), [Operand.new(:addr, next_pc + s16(a))]]
      when 'JMPIF', 'JMPNOT', 'JMPNIL'
        target = next_pc + s16(b)
        ["R#{a}\t#{format('%03d', target)}#{lv_comment(a)}", [r(a), Operand.new(:addr, target)]]
      when 'SSEND', 'SSENDB', 'SEND', 'SENDB'
        operand, text = argc(c)
        ["R#{a}\t:#{sym(b)}\t#{text}", [r(a), sym_op(b), operand]]
      when 'SSEND0', 'SEND0' then ["R#{a}\t:#{sym(b)}", [r(a), sym_op(b)]]
      when 'BLKCALL' then ["R#{a}\t#{b}", [r(a), i(b)]]
      when 'SUPER'
        operand, text = argc(b)
        ["R#{a}\t#{text}", [r(a), operand]]
      when 'ARGARY', 'BLKPUSH'
        spec = [(b >> 11) & 0x3f, (b >> 10) & 1, (b >> 5) & 0x1f, (b >> 4) & 1]
        ["R#{a}\t#{spec.join(':')} (#{b & 0xf})#{lv_comment(a)}",
         [r(a), Operand.new(:spec, spec), lit((b & 0xf).to_s)]]
      when 'ENTER'
        enter = [(a >> 18) & 0x1f, (a >> 13) & 0x1f, (a >> 12) & 1, (a >> 7) & 0x1f,
                 (a >> 2) & 0x1f, (a >> 1) & 1, a & 1, (a >> 23) & 1]
        flags = "0x#{a.to_s(16)}"
        ["#{enter.join(':')} (#{flags})", [Operand.new(:enter, enter), lit(flags)]]
      when 'KEY_P', 'KARG' then ["R#{a}\t:#{sym(b)}#{lv_comment(a)}", [r(a), sym_op(b)]]
      when 'RETURN', 'RETURN_BLK', 'BREAK', 'OCLASS', 'TCLASS', 'INTERN', 'EXCEPT', 'RAISEIF'
        ["R#{a}\t#{lv_comment(a)}", [r(a)]]
      when 'LAMBDA', 'BLOCK', 'METHOD' then ["R#{a}\tI[#{b}]", [r(a), Operand.new(:irep, b)]]
      when 'EXEC' then ["R#{a}\tI[#{b}]#{lv_comment(a)}", [r(a), Operand.new(:irep, b)]]
      when 'RANGE_INC', 'RANGE_EXC', 'MATCHERR' then ["R#{a}", [r(a)]]
      when 'DEF' then ["R#{a}\t:#{sym(b)}\t(R#{a + 1})", [r(a), sym_op(b), pr(a + 1)]]
      when 'TDEF', 'SDEF' then ["R#{a}\t:#{sym(b)}\tI[#{c}]", [r(a), sym_op(b), Operand.new(:irep, c)]]
      when 'UNDEF' then [":#{sym(a)}", [sym_op(a)]]
      when 'ALIAS' then [":#{sym(a)}\t#{sym(b)}", [sym_op(a), name_op(b)]]
      when 'ADD', 'SUB', 'MUL', 'DIV', 'LT', 'LE', 'GT', 'GE', 'EQ' then ["R#{a}\t(R#{a + 1})", [r(a), pr(a + 1)]]
      when 'ADDI', 'SUBI', 'ARRAY', 'ARYPUSH', 'HASH', 'HASHADD' then ["R#{a}\t#{b}#{lv_comment(a)}", [r(a), i(b)]]
      when 'ADDILV', 'SUBILV' then ["R#{a}\tR#{b}\t#{c}#{lv_comment(a)}", [r(a), r(b), i(c)]]
      when 'ARRAY2' then ["R#{a}\tR#{b}\t#{c}#{lv_comment(a, b)}", [r(a), r(b), i(c)]]
      when 'ARYCAT', 'STRCAT', 'HASHCAT' then ["R#{a}\t(R#{a + 1})#{lv_comment(a)}", [r(a), pr(a + 1)]]
      when 'ARYSPLAT', 'SCLASS' then ["R#{a}#{lv_comment(a)}", [r(a)]]
      when 'AREF', 'ASET' then ["R#{a}\tR#{b}\t#{c}#{lv_comment(a, b)}", [r(a), r(b), i(c)]]
      when 'APOST' then ["R#{a}\t#{b}\t#{c}#{lv_comment(a)}", [r(a), i(b), i(c)]]
      when 'SYMBOL' then ["R#{a}\tL[#{b}]\t; #{pool_str(b)}#{lv_comment(a)}", [r(a), Operand.new(:pool, b)]]
      when 'STRING'
        str = pool_str(b)
        ["R#{a}\tL[#{b}]#{str.empty? ? '' : "\t; #{str}"}#{lv_comment(a)}", [r(a), Operand.new(:pool, b)]]
      when 'CLASS', 'MODULE' then ["R#{a}\t:#{sym(b)}#{lv_comment(a)}", [r(a), sym_op(b)]]
      when 'ERR' then err_body(a)
      when 'DEBUG' then ["#{a}\t#{b}\t#{c}", [i(a), i(b), i(c)]]
      else raise "bc2cpp: no decoder for #{name}"
      end
    end
    # rubocop:enable Metrics/CyclomaticComplexity, Metrics/MethodLength

    # ERR's operand is a free-form message, the one text-typed operand.
    def err_body(index)
      text = @rite.pool.fetch(index).kind == :str ? pool_str(index) : "L[#{index}]"
      [text, OperandSchema.parse('ERR', text.split("\n", 2).first.to_s) || [Operand.new(:rest, '')]]
    end

    # `ERR\tL[n]` (a non-string pool slot) is padded with one tab, not two.
    def sep_for(name, values)
      return "\t" if name == 'ERR' && @rite.pool.fetch(values[0]).kind != :str

      SEPS.fetch(name)
    end

    def build(name, values, next_pc, start, line_pc = start)
      rest, operands = body(name, values, next_pc)
      op = name == 'ARRAY2' ? 'ARRAY' : name
      lineno = line_at(line_pc)
      raise "bc2cpp: no line info for #{op} at #{line_pc}" if lineno.negative?

      # The disassembly is line-oriented: a pool string with a newline is cut there.
      # scrub: a binary pool string (mruby-wolf's data.rb) is not valid UTF-8.
      first = "#{op}#{sep_for(name, values)}#{rest}".scrub.split("\n", 2).first
      insn = Insn.new(lineno: lineno, addr: start, op: op, args: first.delete_prefix(op).strip,
                      raw: (format('%5d %03d ', lineno, start) + first).rstrip)
      insn.typed = operands
      insn
    end
  end
end
