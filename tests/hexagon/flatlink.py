#!/usr/bin/env python3
"""Turn one freestanding Hexagon ELF32 relocatable into a runnable Linux user-mode image.

No Hexagon linker is installed (ld.lld and GNU ld have no Hexagon emulation), so this does the
minimum: every SHF_ALLOC section (.text, .rodata*, .data*, .bss*, ...) is laid out in one PT_LOAD
segment at BASE (.text first, .bss last, so memsz > filesz by the bss size), then these relocations
are applied against final addresses:

  R_HEX_B22_PCREL             call/jump (J2 word offset, PC-relative)
  R_HEX_32                    absolute 32-bit word (data pointers, vtable entries)
  R_HEX_32_6_X                constant extender (immext) carrying the high bits of an address
  R_HEX_6_X / R_HEX_16_X / R_HEX_8_X   low 6 bits of the address in the consumer instruction

The consumer forms are the ones clang emits for -fno-pic -G0 (the forms and bit positions were
checked against llvm-mc encodings of "##value"); any other form is reported, not guessed.
Anything it cannot load exits with a "SKIP-data" or "SKIP-undef" message (undefined symbols,
GP-relative access, TLS, constructors) so the test runner reports the case as skipped, not failed.

usage: flatlink.py <in.o> <out.elf> <entry_symbol>
"""
import struct
import sys

BASE = 0x10000        # load address; file offset == address - BASE
HDR = 0x80            # ELF header + one program header; .text starts here (as before)
EM_HEXAGON = 164
SHT_SYMTAB, SHT_NOBITS, SHT_RELA = 2, 8, 4
SHT_INIT_ARRAY, SHT_FINI_ARRAY = 14, 15
SHF_ALLOC, SHF_TLS = 0x2, 0x400
SHN_UNDEF, SHN_ABS, SHN_COMMON = 0, 0xfff1, 0xfff2

R_HEX_B22_PCREL, R_HEX_32, R_HEX_32_6_X, R_HEX_16_X, R_HEX_8_X, R_HEX_6_X = 1, 6, 17, 23, 28, 30
R_HEX_GPREL16 = (9, 10, 11)
RELOC_NAMES = {1: 'R_HEX_B22_PCREL', 6: 'R_HEX_32', 9: 'R_HEX_GPREL16_0', 10: 'R_HEX_GPREL16_1',
               11: 'R_HEX_GPREL16_2', 17: 'R_HEX_32_6_X', 23: 'R_HEX_16_X', 28: 'R_HEX_8_X',
               30: 'R_HEX_6_X'}


def die(tag, msg):
    sys.exit(f'flatlink: {tag}: {msg}')


def ins(w, shift, bits, val):
    """Replace the bit field [shift, shift+bits) of w with val."""
    m = ((1 << bits) - 1) << shift
    return (w & ~m) | ((val << shift) & m)


def apply_abs(image, place, typ, v, where):
    """Write absolute value v (32-bit) into the instruction or word at image[place]."""
    w, = struct.unpack_from('<I', image, place)
    top = w >> 24
    if typ == R_HEX_32:
        w = v
    elif typ == R_HEX_32_6_X and top == 0x00:
        # immext: bits [13:0] = v[19:6], bits [27:16] = v[31:20]; bit 14 is the extender marker.
        w = ins(ins(w, 0, 14, (v >> 6) & 0x3fff), 16, 12, (v >> 20) & 0xfff)
    elif typ == R_HEX_6_X and top in (0x9b, 0x9d):
        # Rd = memw(Rs<<#s + ##u6), Rd = memw(Rs=##u6): the 6-bit field is split into [6:5] and [11:8].
        w = ins(ins(w, 5, 2, v & 3), 8, 4, (v >> 2) & 0xf)
    elif typ == R_HEX_6_X and top in (0x28, 0x68):
        # Rd = #u6 (in a compound with another instruction): bits [25:20].
        w = ins(w, 20, 6, v & 0x3f)
    elif typ == R_HEX_16_X and top in (0x78, 0x49):
        # Rd = ##u32, Rd = memw(##u32): bits [10:5].
        w = ins(w, 5, 6, v & 0x3f)
    elif typ == R_HEX_16_X and top == 0x48:
        # memw(##u32) = Rt: bits [5:0].
        w = ins(w, 0, 6, v & 0x3f)
    elif typ == R_HEX_8_X and top == 0x3c:
        # memw(Rs+#u6) = ##u32: bits [5:0].
        w = ins(w, 0, 6, v & 0x3f)
    else:
        die('SKIP-data', f'{RELOC_NAMES.get(typ, typ)} at {where} on word 0x{w:08x}: unsupported instruction form')
    struct.pack_into('<I', image, place, w)


def main():
    src, dst, entry_sym = sys.argv[1:4]
    data = open(src, 'rb').read()
    if data[:4] != b'\x7fELF' or data[4] != 1 or data[5] != 1:
        die('error', 'need an ELF32 little-endian object')
    flags, = struct.unpack_from('<I', data, 0x24)
    shoff, = struct.unpack_from('<I', data, 0x20)
    shentsize, shnum, shstrndx = struct.unpack_from('<HHH', data, 0x2e)
    sec = []
    for i in range(shnum):
        name, typ, fl, _addr, off, size, link, info, align, _ent = struct.unpack_from(
            '<IIIIIIIIII', data, shoff + i * shentsize)
        sec.append(dict(name=name, type=typ, flags=fl, off=off, size=size, link=link, info=info,
                        align=max(align, 1)))

    def cstr(off):
        return data[off:data.index(b'\0', off)].decode()

    shstr = sec[shstrndx]
    for s in sec:
        s['sname'] = cstr(shstr['off'] + s['name'])
    texts = [i for i, s in enumerate(sec) if s['sname'] == '.text']
    if len(texts) != 1 or not sec[texts[0]]['size']:
        die('error', 'expected exactly one non-empty .text section')
    ti = texts[0]

    # Loaded sections: every SHF_ALLOC section with space in the image. Non-ALLOC sections
    # (.comment, .hexagon.attributes, debug info, .rela.* of them) are metadata and are not loaded.
    alloc = [i for i, s in enumerate(sec) if s['flags'] & SHF_ALLOC and s['size']]
    for i in alloc:
        s = sec[i]
        if s['flags'] & SHF_TLS:
            die('SKIP-data', f"thread-local section {s['sname']} needs a TLS runtime")
        if s['type'] in (SHT_INIT_ARRAY, SHT_FINI_ARRAY):
            die('SKIP-data', f"{s['sname']} needs the C runtime to run static constructors")
    progbits = [i for i in alloc if sec[i]['type'] != SHT_NOBITS]
    bss = [i for i in alloc if sec[i]['type'] == SHT_NOBITS]
    pos = {}
    cur = HDR
    for i in [ti] + [i for i in progbits if i != ti] + bss:
        cur = (cur + sec[i]['align'] - 1) & -sec[i]['align']
        pos[i] = cur
        cur += sec[i]['size']
        if sec[i]['type'] != SHT_NOBITS:
            filesz = cur
    memsz = cur
    image = bytearray(filesz)
    for i in progbits:
        s = sec[i]
        image[pos[i]:pos[i] + s['size']] = data[s['off']:s['off'] + s['size']]

    symtab = next(s for s in sec if s['type'] == SHT_SYMTAB)
    strtab = sec[symtab['link']]
    syms = []
    for k in range(symtab['size'] // 16):
        nm, val, _sz, _info, _other, shndx = struct.unpack_from('<IIIBBH', data, symtab['off'] + k * 16)
        syms.append(dict(name=cstr(strtab['off'] + nm), value=val, shndx=shndx))

    def sym_addr(sym):
        if sym['shndx'] == SHN_ABS:
            return sym['value']
        if sym['shndx'] == SHN_UNDEF:
            die('SKIP-undef', f'symbol {sym["name"]} is not defined in this object (libc/runtime)')
        if sym['shndx'] == SHN_COMMON:
            die('SKIP-data', f'common symbol {sym["name"]} is not supported')
        if sym['shndx'] not in pos:
            die('error', f'symbol {sym["name"]} is in a section that is not loaded')
        return BASE + pos[sym['shndx']] + sym['value']

    for r in sec:
        # RELA sections that patch a loaded section (.text, .rodata, .data, ...).
        if r['type'] != SHT_RELA or r['info'] not in pos:
            continue
        target = r['info']
        if sec[target]['type'] == SHT_NOBITS:
            die('error', f"relocations against {sec[target]['sname']} (no file bytes)")
        for k in range(r['size'] // 12):
            off, info, addend = struct.unpack_from('<IIi', data, r['off'] + k * 12)
            symi, typ = info >> 8, info & 0xff
            sym = syms[symi]
            place = pos[target] + off
            where = f"{sec[target]['sname']}+0x{off:x} against {sym['name']}"
            if typ in R_HEX_GPREL16:
                die('SKIP-data', f'{RELOC_NAMES[typ]} at {where}: GP-relative access, no GP is set up (-G0)')
            s = sym_addr(sym)
            if typ == R_HEX_B22_PCREL:
                words = (s + addend - (BASE + place)) >> 2       # Hexagon branch offsets are in words
                if not -(1 << 21) <= words < (1 << 21):
                    die('error', f'branch to {sym["name"]} out of range')
                w = words & 0x3fffff
                insn, = struct.unpack_from('<I', image, place)
                # J2 branch encoding: imm bits [13:1] = w[12:0], bits [24:16] = w[21:13]; keep opcode bits.
                insn &= ~((0x1fff << 1) | (0x1ff << 16))
                insn |= ((w & 0x1fff) << 1) | (((w >> 13) & 0x1ff) << 16)
                struct.pack_into('<I', image, place, insn)
            elif typ in (R_HEX_32, R_HEX_32_6_X, R_HEX_16_X, R_HEX_8_X, R_HEX_6_X):
                apply_abs(image, place, typ, (s + addend) & 0xffffffff, where)
            else:
                die('SKIP-data', f'relocation {RELOC_NAMES.get(typ, typ)} at {where} is not supported')

    ents = [s for s in syms if s['name'] == entry_sym]
    if not ents:
        die('error', f'entry symbol {entry_sym} not found')
    entry = sym_addr(ents[0])

    ehdr = b'\x7fELF' + bytes([1, 1, 1, 0]) + bytes(8)
    ehdr += struct.pack('<HHIIIIIHHHHHH', 2, EM_HEXAGON, 1, entry, 52, 0, flags, 52, 32, 1, 0, 0, 0)
    # One PT_LOAD: file bytes [0, filesz) at BASE, then zero-filled .bss up to memsz. RWX because
    # .text, .rodata and .data share the segment.
    phdr = struct.pack('<IIIIIIII', 1, 0, BASE, BASE, filesz, memsz, 7, 0x1000)
    image[:HDR] = ehdr + phdr + bytes(HDR - len(ehdr) - len(phdr))
    with open(dst, 'wb') as f:
        f.write(image)


if __name__ == '__main__':
    main()
