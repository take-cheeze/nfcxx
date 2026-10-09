#!/usr/bin/env python3
"""Turn one freestanding Hexagon ELF32 relocatable into a runnable Linux user-mode image.

No Hexagon linker is installed (ld.lld and GNU ld have no Hexagon emulation), so this does the
minimum: a single .text section, R_HEX_B22_PCREL (call/jump) resolved against .text symbols, and
an ELF32 EXEC header wrapped around the result. Anything it cannot handle exits with a
"SKIP-data" or "SKIP-undef" message so the test runner can report the case as skipped, not failed.

usage: flatlink.py <in.o> <out.elf> <entry_symbol>
"""
import struct
import sys

R_HEX_B22_PCREL = 1          # ELF relocation type (llvm-readelf: R_HEX_B22_PCREL)
EM_HEXAGON = 164
ALLOWED = {'', '.text', '.strtab', '.symtab', '.shstrtab', '.comment', '.note.GNU-stack', '.llvm_addrsig'}


def die(tag, msg):
    sys.exit(f'flatlink: {tag}: {msg}')


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
        name, typ, fl, addr, off, size, link, info, align, entsize = struct.unpack_from(
            '<IIIIIIIIII', data, shoff + i * shentsize)
        sec.append(dict(name=name, type=typ, off=off, size=size, link=link, info=info))

    def cstr(off):
        return data[off:data.index(b'\0', off)].decode()

    shstr = sec[shstrndx]
    for s in sec:
        s['sname'] = cstr(shstr['off'] + s['name'])
    texts = [i for i, s in enumerate(sec) if s['sname'] == '.text']
    if len(texts) != 1:
        die('error', 'expected exactly one .text section')
    ti = texts[0]
    text = sec[ti]
    for s in sec:
        if s['sname'] in ALLOWED or s['sname'].startswith('.rela') or not s['size']:
            continue
        die('SKIP-data', f"section {s['sname']} ({s['size']} bytes) needs data relocations")

    symtab = next(s for s in sec if s['type'] == 2)            # SHT_SYMTAB
    strtab = sec[symtab['link']]
    syms = []
    for k in range(symtab['size'] // 16):
        nm, val, _sz, _info, _other, shndx = struct.unpack_from('<IIIBBH', data, symtab['off'] + k * 16)
        syms.append(dict(name=cstr(strtab['off'] + nm), value=val, shndx=shndx))

    code = bytearray(data[text['off']:text['off'] + text['size']])
    for s in sec:
        if s['type'] != 4 or s['info'] != ti:                   # SHT_RELA applying to .text
            continue
        for k in range(s['size'] // 12):
            off, info, addend = struct.unpack_from('<IIi', data, s['off'] + k * 12)
            symi, typ = info >> 8, info & 0xff
            sym = syms[symi]
            if typ != R_HEX_B22_PCREL:
                die('SKIP-data', f'relocation type {typ} at 0x{off:x} against {sym["name"]}')
            if sym['shndx'] != ti:
                die('SKIP-undef', f'symbol {sym["name"]} is not defined in this object (libc/runtime)')
            words = (sym['value'] + addend - off) >> 2          # Hexagon branch offsets are in words
            if not -(1 << 21) <= words < (1 << 21):
                die('error', f'branch to {sym["name"]} out of range')
            w = words & 0x3fffff
            insn, = struct.unpack_from('<I', code, off)
            # J2 branch encoding: imm bits [13:1] = w[12:0], bits [24:16] = w[21:13]; keep opcode bits.
            insn &= ~((0x1fff << 1) | (0x1ff << 16))
            insn |= ((w & 0x1fff) << 1) | (((w >> 13) & 0x1ff) << 16)
            struct.pack_into('<I', code, off, insn)

    ents = [s['value'] for s in syms if s['name'] == entry_sym]
    if not ents:
        die('error', f'entry symbol {entry_sym} not found')
    base, off = 0x10000, 0x80
    ehdr = b'\x7fELF' + bytes([1, 1, 1, 0]) + bytes(8)
    ehdr += struct.pack('<HHIIIIIHHHHHH', 2, EM_HEXAGON, 1, base + off + ents[0], 52, 0, flags,
                        52, 32, 1, 0, 0, 0)
    phdr = struct.pack('<IIIIIIII', 1, 0, base, base, off + len(code), off + len(code), 5, 0x1000)
    image = ehdr + phdr + b'\0' * (off - len(ehdr) - len(phdr)) + bytes(code)
    with open(dst, 'wb') as f:
        f.write(image)


if __name__ == '__main__':
    main()
