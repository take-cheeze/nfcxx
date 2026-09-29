# frozen_string_literal: true

# Reader for mruby's RITE binary (`mrbc -g -o x.mrb`, src/dump.c): the irep
# tree with its raw iseq bytes, catch handler table, pool, symbols, local
# variable names and line/file debug info. No disassembly text is involved.
# Runs under CRuby (the compiler is a host tool), so `unpack` is fine here.
module RiteBinary
  # Pool entry: `kind` is :str, :int32, :int64, :float or :bigint; `value` is
  # the raw bytes (String, :str/:bigint), an Integer or a Float.
  PoolEntry = Struct.new(:kind, :value)
  # One `mrb_irep_debug_info_file`: `lines` is the raw packed line map.
  DebugFile = Struct.new(:start_pos, :filename, :line_type, :lines)
  # `debug_files` is nil when the binary has no debug section; `lv` is nil
  # without an LV section, else one name (or nil) per register 1...nlocals.
  RiteIrep = Struct.new(:nlocals, :nregs, :iseq, :catch_handlers, :pool, :syms, :lv, :debug_files,
                        keyword_init: true)
  RawCatch = Struct.new(:type, :begin_addr, :end_addr, :target, keyword_init: true)

  HEADER_SIZE = 20
  CATCH_SIZE = 13
  NULL_LEN = 0xffff
  TT_STR = 0
  TT_INT32 = 1
  TT_INT64 = 3
  TT_FLOAT = 5
  TT_BIGINT = 7
  LINE_PACKED_MAP = 2

  # Cursor over the binary; every multi-byte field is big-endian except the
  # float pool entry (little-endian double).
  class Reader
    attr_reader :pos

    def initialize(bytes, pos = 0)
      @bytes = bytes
      @pos = pos
    end

    def u8 = take(1).unpack1('C')
    def u16 = take(2).unpack1('n')
    def u32 = take(4).unpack1('N')

    def take(len)
      raise "bc2cpp: truncated RITE binary at #{@pos}+#{len}" if @pos + len > @bytes.bytesize

      chunk = @bytes.byteslice(@pos, len)
      @pos += len
      chunk
    end

    def skip(len)
      take(len)
      nil
    end
  end

  # All ireps of +bytes+ in depth-first pre-order (the order codedump prints).
  def self.parse(bytes)
    bytes = bytes.b
    raise 'bc2cpp: not a RITE binary' unless bytes.byteslice(0, 4) == 'RITE'

    pos = HEADER_SIZE
    ireps = nil
    debug = nil
    lv = nil
    while pos + 8 <= bytes.bytesize
      ident = bytes.byteslice(pos, 4)
      size = bytes.byteslice(pos + 4, 4).unpack1('N')
      body = Reader.new(bytes, pos + 8)
      case ident
      when 'IREP' then ireps = parse_irep_section(body)
      when "DBG\0" then debug = parse_debug_section(body, ireps || raise('bc2cpp: DBG before IREP'))
      when 'LVAR' then lv = parse_lv_section(body, ireps || raise('bc2cpp: LVAR before IREP'))
      end
      pos += size
      break if ident == "END\0"
    end
    raise 'bc2cpp: RITE binary has no IREP section' unless ireps

    ireps.each_with_index do |irep, i|
      irep.debug_files = debug && debug[i]
      irep.lv = lv && lv[i]
    end
    ireps
  end

  def self.parse_irep_section(reader)
    reader.skip(4) # rite_version
    ireps = []
    parse_irep_record(reader, ireps)
    ireps
  end

  def self.parse_irep_record(reader, out)
    reader.u32 # record size
    irep = RiteIrep.new(nlocals: reader.u16, nregs: reader.u16)
    rlen = reader.u16
    out << irep
    clen = reader.u16
    ilen = reader.u32
    irep.iseq = reader.take(ilen)
    irep.catch_handlers = Array.new(clen) do
      type = reader.u8
      RawCatch.new(type: type, begin_addr: reader.u32, end_addr: reader.u32, target: reader.u32)
    end
    irep.pool = Array.new(reader.u16) { parse_pool_entry(reader) }
    irep.syms = Array.new(reader.u16) { parse_sym(reader) }
    rlen.times { parse_irep_record(reader, out) }
  end

  def self.parse_pool_entry(reader)
    case (tt = reader.u8)
    when TT_INT32 then PoolEntry.new(:int32, reader.take(4).unpack1('l>'))
    when TT_INT64 then PoolEntry.new(:int64, reader.take(8).unpack1('q>'))
    when TT_FLOAT then PoolEntry.new(:float, reader.take(8).unpack1('E'))
    when TT_BIGINT
      len = reader.u8
      PoolEntry.new(:bigint, reader.take(len + 1))
    when TT_STR
      len = reader.u16
      value = reader.take(len)
      reader.skip(1) # NUL terminator
      PoolEntry.new(:str, value)
    else raise "bc2cpp: unknown pool entry type #{tt}"
    end
  end

  def self.parse_sym(reader)
    len = reader.u16
    return nil if len == NULL_LEN

    name = reader.take(len)
    reader.skip(1)
    name
  end

  def self.parse_filename_table(reader)
    Array.new(reader.u16) { reader.take(reader.u16).force_encoding(Encoding::UTF_8) }
  end

  def self.parse_debug_section(reader, ireps)
    filenames = parse_filename_table(reader)
    ireps.map do
      reader.u32 # record size
      Array.new(reader.u16) do
        start_pos = reader.u32
        filename = filenames.fetch(reader.u16)
        count = reader.u32
        line_type = reader.u8
        raise "bc2cpp: unsupported debug line type #{line_type}" unless line_type == LINE_PACKED_MAP

        DebugFile.new(start_pos, filename, line_type, reader.take(count))
      end
    end
  end

  def self.parse_lv_section(reader, ireps)
    names = Array.new(reader.u32) { reader.take(reader.u16) }
    ireps.map do |irep|
      Array.new([irep.nlocals - 1, 0].max) do
        idx = reader.u16
        idx == NULL_LEN ? nil : names.fetch(idx)
      end
    end
  end
end
