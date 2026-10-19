# Oracle for tests/hexagon/flatlink.rb: an mruby port of the Python original tests/mruby/oracle/flatlink.py (deleted
# with this change; it is in the git history at 972fccf). It follows the original exactly, so that tests/mruby/run.sh
# can compare the production harness against it. Known differences of tests/hexagon/flatlink.rb from the original
# (this file matches the original), all on malformed objects: a name that is not terminated or not UTF-8, a read past
# the end of the file, and a section whose bytes run past the end of the file (the original shrinks its image there).
#
# Turn one freestanding Hexagon ELF32 relocatable into a runnable Linux user-mode image.
#
# No Hexagon linker is installed (ld.lld and GNU ld have no Hexagon emulation), so this does the
# minimum: every SHF_ALLOC section (.text, .rodata*, .data*, .bss*, ...) is laid out in one PT_LOAD
# segment at BASE (.text first, .bss last, so memsz > filesz by the bss size), then these relocations
# are applied against final addresses:
#
#   R_HEX_B22_PCREL             call/jump (J2 word offset, PC-relative)
#   R_HEX_32                    absolute 32-bit word (data pointers, vtable entries)
#   R_HEX_32_6_X                constant extender (immext) carrying the high bits of an address
#   R_HEX_6_X / R_HEX_16_X / R_HEX_8_X   low 6 bits of the address in the consumer instruction
#
# The consumer forms are the ones clang emits for -fno-pic -G0 (the forms and bit positions were
# checked against llvm-mc encodings of "##value"); any other form is reported, not guessed.
# Anything it cannot load exits with a "SKIP-data" or "SKIP-undef" message (undefined symbols,
# GP-relative access, TLS, constructors) so the test runner reports the case as skipped, not failed.
#
# usage: scripts/mrb tests/hexagon/flatlink.rb <in.o> <out.elf> <entry_symbol>
#
# Port of flatlink.py (the Python original, deleted) for mruby (no Regexp, struct -> pack/unpack). Integer literals above 2**31-1 are
# avoided (mruby without mruby-bigint parses them as bigints): 32-bit masks are spelled as shifts.

BASE = 0x10000        # load address; file offset == address - BASE
HDR = 0x80            # ELF header + one program header; .text starts here (as before)
EM_HEXAGON = 164
SHT_SYMTAB = 2
SHT_NOBITS = 8
SHT_RELA = 4
SHT_INIT_ARRAY = 14
SHT_FINI_ARRAY = 15
SHF_ALLOC = 0x2
SHF_TLS = 0x400
SHN_UNDEF = 0
SHN_ABS = 0xfff1
SHN_COMMON = 0xfff2
M32 = (1 << 32) - 1

R_HEX_B22_PCREL = 1
R_HEX_32 = 6
R_HEX_32_6_X = 17
R_HEX_16_X = 23
R_HEX_10_X = 26
R_HEX_8_X = 28
R_HEX_6_X = 30
R_HEX_GPREL16 = [9, 10, 11]
RELOC_NAMES = { 1 => 'R_HEX_B22_PCREL', 6 => 'R_HEX_32', 9 => 'R_HEX_GPREL16_0', 10 => 'R_HEX_GPREL16_1',
                11 => 'R_HEX_GPREL16_2', 17 => 'R_HEX_32_6_X', 23 => 'R_HEX_16_X', 26 => 'R_HEX_10_X',
                28 => 'R_HEX_8_X', 30 => 'R_HEX_6_X' }

def die(tag, msg)
  $stderr.puts "flatlink: #{tag}: #{msg}"
  exit 1
end

def reloc_name(typ)
  RELOC_NAMES[typ] || typ.to_s
end

# Little-endian reads from a binary string. A read past the end is an error (struct.error in the Python original).
class StructError < StandardError; end

def need(d, off, n)
  raise StructError, "unpack_from requires a buffer of at least #{off + n} bytes" if off < 0 || off + n > d.bytesize
end

def u8(d, off)
  need(d, off, 1)
  d.getbyte(off)
end

def u16(d, off)
  need(d, off, 2)
  d.byteslice(off, 2).unpack("v")[0]
end

def u32(d, off)
  need(d, off, 4)
  d.byteslice(off, 4).unpack("V")[0]
end

def s32(d, off)
  v = u32(d, off)
  v >= (1 << 31) ? v - (1 << 32) : v
end

# Replace the bit field [shift, shift+bits) of w with val.
def ins(w, shift, bits, val)
  m = ((1 << bits) - 1) << shift
  (w & ~m) | ((val << shift) & m)
end

def image_need(image, place)
  raise StructError, "unpack_from requires a buffer of at least #{place + 4} bytes" if place < 0 || place + 4 > image.bytesize
end

def image_u32(image, place)
  image_need(image, place)
  image.getbyte(place) | (image.getbyte(place + 1) << 8) | (image.getbyte(place + 2) << 16) | (image.getbyte(place + 3) << 24)
end

def image_put32(image, place, w)
  image_need(image, place)
  4.times { |k| image.setbyte(place + k, (w >> (8 * k)) & 0xff) }
end

# Write absolute value v (32-bit) into the instruction or word at image[place].
def apply_abs(image, place, typ, v, where)
  w = image_u32(image, place)
  top = w >> 24
  if typ == R_HEX_32
    w = v
  elsif typ == R_HEX_32_6_X && top == 0x00
    # immext: bits [13:0] = v[19:6], bits [27:16] = v[31:20]; bit 14 is the extender marker.
    w = ins(ins(w, 0, 14, (v >> 6) & 0x3fff), 16, 12, (v >> 20) & 0xfff)
  elsif typ == R_HEX_6_X && (top == 0x9b || top == 0x9d)
    # Rd = memw(Rs<<#s + ##u6), Rd = memw(Rs=##u6): the 6-bit field is split into [6:5] and [11:8].
    w = ins(ins(w, 5, 2, v & 3), 8, 4, (v >> 2) & 0xf)
  elsif typ == R_HEX_6_X && ((w >> 14) & 3) == 0 && (top & 0x1c) == 0x08
    # Rd = #u6 in a duplex (parse bits 00; the sub-instruction class is in the top bits): bits [25:20].
    w = ins(w, 20, 6, v & 0x3f)
  elsif typ == R_HEX_6_X && top == 0x7c
    # Rdd = combine(#s8,##u6): the 6-bit field is split into [20:16] = v[5:1] and bit 13 = v[0].
    w = ins(ins(w, 16, 5, (v >> 1) & 0x1f), 13, 1, v & 1)
  elsif typ == R_HEX_16_X && (top == 0x78 || top == 0x49 || top == 0xb0)
    # Rd = ##u32, Rd = memw(##u32), Rd = add(Rs,##u32): bits [10:5].
    w = ins(w, 5, 6, v & 0x3f)
  elsif typ == R_HEX_10_X && top == 0x75
    # Pd = cmp.eq(Rs,##u32): bits [10:5].
    w = ins(w, 5, 6, v & 0x3f)
  elsif typ == R_HEX_16_X && top == 0x48
    # memw(##u32) = Rt: bits [5:0].
    w = ins(w, 0, 6, v & 0x3f)
  elsif typ == R_HEX_8_X && top == 0x7c
    # Rdd = combine(##u32,#s8): bits [10:5].
    w = ins(w, 5, 6, v & 0x3f)
  elsif typ == R_HEX_8_X && top == 0x3c
    # memw(Rs+#u6) = ##u32: bits [5:0].
    w = ins(w, 0, 6, v & 0x3f)
  else
    die('SKIP-data', "#{reloc_name(typ)} at #{where} on word 0x#{format('%08x', w)}: unsupported instruction form")
  end
  image_put32(image, place, w)
end

# data.index(b"\0", off) and .decode() (UTF-8, strict) of the Python original; a name that is not terminated, or is not
# valid UTF-8, ends the run with status 1.
def cstr(data, off)
  e = off
  e += 1 while e < data.bytesize && data.getbyte(e) != 0
  raise StructError, "substring not found" if e >= data.bytesize
  s = data.byteslice(off, e - off)
  raise StructError, "invalid UTF-8 in a name" unless utf8_valid?(s)
  s
end

# str.decode("utf-8") succeeds: no bad sequence, no overlong form, no surrogate, nothing above U+10FFFF.
def utf8_valid?(s)
  i = 0
  n = s.bytesize
  while i < n
    c = s.getbyte(i)
    if c < 0x80
      i += 1
      next
    end
    if c >= 0xc2 && c <= 0xdf
      k = 1; lo = 0x80; hi = 0xbf
    elsif c == 0xe0
      k = 2; lo = 0xa0; hi = 0xbf
    elsif c >= 0xe1 && c <= 0xec || c == 0xee || c == 0xef
      k = 2; lo = 0x80; hi = 0xbf
    elsif c == 0xed
      k = 2; lo = 0x80; hi = 0x9f
    elsif c == 0xf0
      k = 3; lo = 0x90; hi = 0xbf
    elsif c >= 0xf1 && c <= 0xf3
      k = 3; lo = 0x80; hi = 0xbf
    elsif c == 0xf4
      k = 3; lo = 0x80; hi = 0x8f
    else
      return false
    end
    return false if i + k >= n
    d1 = s.getbyte(i + 1)
    return false if d1.nil? || d1 < lo || d1 > hi
    j = 2
    while j <= k
      d = s.getbyte(i + j)
      return false if d.nil? || d < 0x80 || d > 0xbf
      j += 1
    end
    i += k + 1
  end
  true
end

def main
  src, dst, entry_sym = ARGV[0], ARGV[1], ARGV[2]
  data = File.open(src, "rb") { |f| f.read }
  if data.byteslice(0, 4) != "\x7fELF" || u8(data, 4) != 1 || u8(data, 5) != 1
    die('error', 'need an ELF32 little-endian object')
  end
  flags = u32(data, 0x24)
  shoff = u32(data, 0x20)
  shentsize = u16(data, 0x2e)
  shnum = u16(data, 0x30)
  shstrndx = u16(data, 0x32)
  sec = []
  shnum.times do |i|
    b = shoff + i * shentsize
    need(data, b, 40)   # struct.unpack_from('<IIIIIIIIII'): ten words
    sec << { name: u32(data, b), type: u32(data, b + 4), flags: u32(data, b + 8), off: u32(data, b + 16),
             size: u32(data, b + 20), link: u32(data, b + 24), info: u32(data, b + 28),
             align: [u32(data, b + 32), 1].max }
  end

  shstr = sec[shstrndx]
  sec.each { |s| s[:sname] = cstr(data, shstr[:off] + s[:name]) }
  texts = []
  sec.each_with_index { |s, i| texts << i if s[:sname] == '.text' }
  if texts.size != 1 || sec[texts[0]][:size] == 0
    die('error', 'expected exactly one non-empty .text section')
  end
  ti = texts[0]

  # Loaded sections: every SHF_ALLOC section with space in the image. Non-ALLOC sections
  # (.comment, .hexagon.attributes, debug info, .rela.* of them) are metadata and are not loaded.
  alloc = []
  sec.each_with_index { |s, i| alloc << i if (s[:flags] & SHF_ALLOC) != 0 && s[:size] != 0 }
  alloc.each do |i|
    s = sec[i]
    if (s[:flags] & SHF_TLS) != 0
      die('SKIP-data', "thread-local section #{s[:sname]} needs a TLS runtime")
    end
    if s[:type] == SHT_INIT_ARRAY || s[:type] == SHT_FINI_ARRAY
      die('SKIP-data', "#{s[:sname]} needs the C runtime to run static constructors")
    end
  end
  progbits = alloc.select { |i| sec[i][:type] != SHT_NOBITS }
  bss = alloc.select { |i| sec[i][:type] == SHT_NOBITS }
  pos = {}
  cur = HDR
  filesz = nil   # unset (a NameError in the Python original) when no PROGBITS section is loaded
  ([ti] + progbits.select { |i| i != ti } + bss).each do |i|
    a = sec[i][:align]
    cur = (cur + a - 1) & -a
    pos[i] = cur
    cur += sec[i][:size]
    filesz = cur if sec[i][:type] != SHT_NOBITS
  end
  memsz = cur
  raise NameError, "name 'filesz' is not defined" if filesz.nil?
  image = "\0".b * filesz
  # image[pos:pos+size] = data[off:off+size] of the Python original: a slice past the end of the file is short, and a
  # slice assignment replaces the range by the bytes it has (the image shrinks), it never pads.
  progbits.each do |i|
    s = sec[i]
    chunk = data.byteslice(s[:off], s[:size]) || ""
    a = [pos[i], image.bytesize].min
    b = [pos[i] + s[:size], image.bytesize].min
    b = a if b < a
    image[a...b] = chunk
  end

  symtab = sec.find { |s| s[:type] == SHT_SYMTAB }
  strtab = sec[symtab[:link]]
  syms = []
  (symtab[:size] / 16).times do |k|
    b = symtab[:off] + k * 16
    need(data, b, 16)
    syms << { name: cstr(data, strtab[:off] + u32(data, b)), value: u32(data, b + 4), shndx: u16(data, b + 14) }
  end

  sym_addr = lambda do |sym|
    return sym[:value] if sym[:shndx] == SHN_ABS
    die('SKIP-undef', "symbol #{sym[:name]} is not defined in this object (libc/runtime)") if sym[:shndx] == SHN_UNDEF
    die('SKIP-data', "common symbol #{sym[:name]} is not supported") if sym[:shndx] == SHN_COMMON
    die('error', "symbol #{sym[:name]} is in a section that is not loaded") unless pos.key?(sym[:shndx])
    BASE + pos[sym[:shndx]] + sym[:value]
  end

  sec.each do |r|
    # RELA sections that patch a loaded section (.text, .rodata, .data, ...).
    next if r[:type] != SHT_RELA || !pos.key?(r[:info])
    target = r[:info]
    if sec[target][:type] == SHT_NOBITS
      die('error', "relocations against #{sec[target][:sname]} (no file bytes)")
    end
    (r[:size] / 12).times do |k|
      b = r[:off] + k * 12
      off = u32(data, b)
      info = u32(data, b + 4)
      addend = s32(data, b + 8)
      symi = info >> 8
      typ = info & 0xff
      sym = syms[symi]
      place = pos[target] + off
      where = "#{sec[target][:sname]}+0x#{off.to_s(16)} against #{sym[:name]}"
      if R_HEX_GPREL16.include?(typ)
        die('SKIP-data', "#{reloc_name(typ)} at #{where}: GP-relative access, no GP is set up (-G0)")
      end
      s = sym_addr.call(sym)
      if typ == R_HEX_B22_PCREL
        words = (s + addend - (BASE + place)) >> 2       # Hexagon branch offsets are in words
        if !(-(1 << 21) <= words && words < (1 << 21))
          die('error', "branch to #{sym[:name]} out of range")
        end
        w = words & 0x3fffff
        insn = image_u32(image, place)
        # J2 branch encoding: imm bits [13:1] = w[12:0], bits [24:16] = w[21:13]; keep opcode bits.
        insn &= ~((0x1fff << 1) | (0x1ff << 16))
        insn |= ((w & 0x1fff) << 1) | (((w >> 13) & 0x1ff) << 16)
        image_put32(image, place, insn)
      elsif [R_HEX_32, R_HEX_32_6_X, R_HEX_16_X, R_HEX_10_X, R_HEX_8_X, R_HEX_6_X].include?(typ)
        apply_abs(image, place, typ, (s + addend) & M32, where)
      else
        die('SKIP-data', "relocation #{reloc_name(typ)} at #{where} is not supported")
      end
    end
  end

  ent = syms.find { |s| s[:name] == entry_sym }
  die('error', "entry symbol #{entry_sym} not found") if ent.nil?
  entry = sym_addr.call(ent)

  ehdr = "\x7fELF".b + [1, 1, 1, 0].pack("C*") + ("\0" * 8).b
  ehdr += [2, EM_HEXAGON, 1, entry, 52, 0, flags, 52, 32, 1, 0, 0, 0].pack("vvVVVVVvvvvvv")
  # One PT_LOAD: file bytes [0, filesz) at BASE, then zero-filled .bss up to memsz. RWX because
  # .text, .rodata and .data share the segment.
  phdr = [1, 0, BASE, BASE, filesz, memsz, 7, 0x1000].pack("V8")
  head = ehdr + phdr + ("\0" * (HDR - ehdr.bytesize - phdr.bytesize)).b
  # image[:HDR] = head (a slice assignment: the first HDR bytes are replaced by the header)
  hb = [HDR, image.bytesize].min
  image[0...hb] = head
  File.open(dst, "wb") { |f| f.write(image) }
end

main
