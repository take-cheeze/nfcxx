#!/usr/bin/env python3
# qbe2cil.py: translate one translation unit's QBE IL (cproc's output, after qbe-prep.rb) into a JSON fragment that
# scripts/cil-link.rb links into one CIL assembly (the nfcc `cil` backend; docs/notes/cil.md).
#
#   qbe2cil.py IN.ssa TAIL.s TU_NAME OUT.json
#
# Memory model: a C pointer is an int64 address in unmanaged memory (calloc at startup). Loads and stores are
# ldind/stind through conv.u. Each QBE temporary is an IL local (SSA: one definition). A phi becomes a copy on each
# edge; the copies go through the evaluation stack first, so they are one parallel assignment. Stack slots
# (`alloc`) are carved from one localloc per call. A global symbol's address is the IL static field
# `addr_<name>`, which the linker fills in. Symbols not exported by the unit are renamed `name@<TU>`.
# Refused with an error, not miscompiled: variadic definitions (va_start), bit casts other than float<->int of the
# same size, and inline asm.
import json
import re
import struct
import sys

IL_TYPE = {'w': 'int32', 'l': 'int64', 's': 'float32', 'd': 'float64'}
LOADS = {  # QBE load -> (ldind suffix, QBE type of the value it produces)
    'loadsb': ('i1', 'w'), 'loadub': ('u1', 'w'), 'loadsh': ('i2', 'w'), 'loaduh': ('u2', 'w'),
    'loadsw': ('i4', 'w'), 'loaduw': ('u4', 'w'), 'loadw': ('i4', 'w'), 'loadl': ('i8', 'l'),
    'loads': ('r4', 's'), 'loadd': ('r8', 'd'),
}
STORES = {  # QBE store -> (stind suffix, QBE type of the value)
    'storeb': ('i1', 'w'), 'storeh': ('i2', 'w'), 'storew': ('i4', 'w'), 'storel': ('i8', 'l'),
    'stores': ('r4', 's'), 'stored': ('r8', 'd'),
}
INT_OPS = {'add': 'add', 'sub': 'sub', 'mul': 'mul', 'div': 'div', 'udiv': 'div.un', 'rem': 'rem',
           'urem': 'rem.un', 'and': 'and', 'or': 'or', 'xor': 'xor', 'shl': 'shl', 'shr': 'shr.un', 'sar': 'shr'}
SHIFT_OPS = ('shl', 'shr', 'sar')
FLT_OPS = {'add': 'add', 'sub': 'sub', 'mul': 'mul', 'div': 'div'}
CONV = {  # QBE conversion -> (source QBE type, result QBE type, IL instructions)
    'extsw': ('w', 'l', ['conv.i8']), 'extuw': ('w', 'l', ['conv.u8']),
    'extsh': ('w', 'w', ['conv.i2']), 'extuh': ('w', 'w', ['conv.u2']),
    'extsb': ('w', 'w', ['conv.i1']), 'extub': ('w', 'w', ['conv.u1']),
    'exts': ('s', 'd', ['conv.r8']), 'truncd': ('d', 's', ['conv.r4']),
    'stosi': ('s', 'w', ['conv.i4']), 'dtosi': ('d', 'w', ['conv.i4']),
    'stoui': ('s', 'w', ['conv.u4']), 'dtoui': ('d', 'w', ['conv.u4']),
    'stosl': ('s', 'l', ['conv.i8']), 'dtosl': ('d', 'l', ['conv.i8']),
    'stoul': ('s', 'l', ['conv.u8']), 'dtoul': ('d', 'l', ['conv.u8']),
    'swtof': ('w', 's', ['conv.r4']), 'swtod': ('w', 'd', ['conv.r8']),
    'sltof': ('l', 's', ['conv.r4']), 'sltod': ('l', 'd', ['conv.r8']),
    'uwtof': ('w', 's', ['conv.r.un', 'conv.r4']), 'uwtod': ('w', 'd', ['conv.r.un', 'conv.r8']),
    'ultof': ('l', 's', ['conv.r.un', 'conv.r4']), 'ultod': ('l', 'd', ['conv.r.un', 'conv.r8']),
}
BITCAST = {  # result QBE type -> (source QBE type, System.BitConverter method)
    's': ('w', 'System.BitConverter::Int32BitsToSingle(int32)'),
    'w': ('s', 'System.BitConverter::SingleToInt32Bits(float32)'),
    'd': ('l', 'System.BitConverter::Int64BitsToDouble(int64)'),
    'l': ('d', 'System.BitConverter::DoubleToInt64Bits(float64)'),
}
CMP_INT = re.compile(r'^c(s|u)?(eq|ne|lt|le|gt|ge)([wl])$')
CMP_FLT = re.compile(r'^c(eq|ne|lt|le|gt|ge)([sd])$')


def die(msg):
    sys.exit('qbe2cil: ' + msg)


def strip_extern(tok):
    return tok[len('extern '):] if tok.startswith('extern ') else tok


def split_top(s):
    """Split a comma-separated list, ignoring commas inside parentheses and string literals."""
    out, cur, depth, quoted = [], '', 0, False
    for ch in s:
        if ch == '"':
            quoted = not quoted
        if not quoted:
            if ch == '(':
                depth += 1
            elif ch == ')':
                depth -= 1
            elif ch == ',' and depth == 0:
                out.append(cur.strip())
                cur = ''
                continue
        cur += ch
    if cur.strip():
        out.append(cur.strip())
    return out


FIELD_SIZE = {'b': (1, 1), 'h': (2, 2), 'w': (4, 4), 'l': (8, 8), 's': (4, 4), 'd': (8, 8)}


def parse_types(lines):
    """`type :name = { fields }` -> {':name': (size, align)}. A field is a basic type with an optional count, or a
    nested aggregate. Layout is natural alignment, which is what QBE and C use for these."""
    raw = {}
    for ln in lines:
        m = re.match(r'^type\s+(:\S+?)\s*=\s*(?:align\s+\d+\s*)?\{(.*)\}\s*$', ln.strip())
        if m:
            raw[m.group(1)] = split_top(m.group(2))
    layout = {}

    def size_align(name):
        if name in layout:
            return layout[name]
        if name not in raw:
            die(f'unknown aggregate type {name}')
        off, al = 0, 1
        for f in raw[name]:
            parts = f.split()
            if parts[0].startswith(':'):
                fs, fa = size_align(parts[0])
            else:
                fs, fa = FIELD_SIZE[parts[0]]
                fs *= int(parts[1]) if len(parts) > 1 else 1
            off = (off + fa - 1) // fa * fa + fs
            al = max(al, fa)
        layout[name] = ((off + al - 1) // al * al, al)
        return layout[name]

    for name in raw:
        size_align(name)
    return layout


def float_bits(tok):
    """A QBE float literal (d_1.5, s_3, d_-2.25, d_0x1p-1) as (IEEE bits, byte width)."""
    kind, v = tok[0], tok.split('_', 1)[1]
    x = float.fromhex(v) if v.lower().startswith(('0x', '-0x')) else float(v)
    if kind == 's':
        return struct.unpack('<I', struct.pack('<f', x))[0], 4
    return struct.unpack('<Q', struct.pack('<d', x))[0], 8


def int_value(text, bits):
    v = int(text, 0) & ((1 << bits) - 1)
    return v - (1 << bits) if v >= 1 << (bits - 1) else v


def parse_string(s, i):
    """A QBE string literal starting at s[i] == '"'. Returns (bytes, index after it)."""
    out = bytearray()
    i += 1
    while s[i] != '"':
        if s[i] == '\\' and s[i + 1 : i + 4] and all(c in '01234567' for c in s[i + 1 : i + 4]):
            out.append(int(s[i + 1 : i + 4], 8))
            i += 4
        elif s[i] == '\\':
            out.append(ord(s[i + 1]))
            i += 2
        else:
            out.append(ord(s[i]))
            i += 1
    return bytes(out), i + 1


def parse_data(line, sym_name):
    """`[export] data $name = [align N] { items }` -> dict, or None if the line is not a data definition."""
    m = re.match(r'^(export\s+)?data\s+\$([^\s=]+)\s*=\s*(align\s+(\d+)\s*)?\{(.*)\}\s*$', line)
    if not m:
        return None
    body, items, size, i = m.group(5), [], 0, 0
    widths = {'b': 1, 'h': 2, 'w': 4, 'l': 8, 's': 4, 'd': 8}
    names = {'b': 'int8', 'h': 'int16', 'w': 'int32', 'l': 'int64', 's': 'float32', 'd': 'float64'}
    while i < len(body):
        if body[i] in ' ,\t':
            i += 1
            continue
        if body[i] == 'z':
            mz = re.match(r'z\s+(\d+)', body[i:])
            items.append(['zero', int(mz.group(1))])
            size += int(mz.group(1))
            i += mz.end()
            continue
        k = body[i]
        if k not in widths:
            die(f'data ${m.group(2)}: unsupported item {body[i : i + 20]!r}')
        i += 1
        while body[i] == ' ':
            i += 1
        if k == 'b' and body[i] == '"':
            data, i = parse_string(body, i)
            items += [['int8', c] for c in data]
            size += len(data)
            continue
        mm = re.match(r'\$([^\s,}+]+)(\s*\+\s*(-?\d+))?|[^\s,}]+', body[i:])
        tok = mm.group(0)
        i += len(tok)
        if tok.startswith('$'):
            items.append(['addr', sym_name(mm.group(1)), int(mm.group(3) or 0)])
            size += 8
        elif k in 'sd':
            bits, n = float_bits(tok)
            items.append([names[k], bits])
            size += n
        else:
            items.append([names[k], int_value(tok, 8 * widths[k])])
            size += widths[k]
    return {'name': sym_name(m.group(2)), 'exported': bool(m.group(1)), 'align': int(m.group(4) or 1),
            'size': size, 'items': items}


class Unit:
    def __init__(self, tu, types):
        self.tu = tu
        self.types = types
        self.fn_defs = set()
        self.data_defs = set()
        self.exported = set()

    def name(self, sym):
        """The linker name of a symbol referenced in this unit."""
        if sym in self.exported or (sym not in self.fn_defs and sym not in self.data_defs):
            return sym
        return f'{sym}@{self.tu}'


def scan_definitions(lines, unit):
    pending = False
    for ln in lines:
        s = ln.strip()
        if s == 'export':
            pending = True
            continue
        m = re.match(r'^(export\s+)?function\s+(?:(?:[wlsd]|:\S+)\s+)?\$([^\s(]+)\(', s)
        if m:
            unit.fn_defs.add(m.group(2))
            if m.group(1) or pending:
                unit.exported.add(m.group(2))
        m = re.match(r'^(export\s+)?data\s+\$([^\s=]+)', s)
        if m:
            unit.data_defs.add(m.group(2))
            if m.group(1):
                unit.exported.add(m.group(2))
        if s:
            pending = False


def split_call(rest):
    """`extern $f(args)` / `$f(args)` / `%p(args)` -> (callee, [arg, ...])."""
    rest = strip_extern(rest.strip())
    p = rest.index('(')
    callee = rest[:p].strip()
    if callee.startswith('extern '):
        callee = callee[len('extern '):]
    args = split_top(rest[p + 1 : rest.rindex(')')])
    return callee, args


class Function:
    """One QBE function turned into a CIL method body."""

    def __init__(self, unit, fragment, lines, start, exported, ret_letter, sym, params_text):
        self.unit = unit
        self.fragment = fragment
        self.exported = exported
        self.name = unit.name(sym)
        self.params = []
        self.arg_index = {}
        self.agg_params = []  # (temp name, size, align, IL argument index): copied into the frame on entry
        self.agg_ret = None   # (size, align) of an aggregate result: the caller passes its address first
        if ret_letter and ret_letter.startswith(':'):
            self.agg_ret = unit.types[ret_letter]
            self.params.append('int64')
        self.ret = 'void' if self.agg_ret else (IL_TYPE.get(ret_letter) or 'void')
        for p in split_top(params_text):
            if p == '...':
                die(f'{self.name}: variadic definitions (va_start) are not supported by the CIL backend')
            t, v = p.split(None, 1)
            if t == 'env':
                die(f'{self.name}: env parameters are not supported')
            if t.startswith(':'):
                size, align = unit.types[t]
                self.agg_params.append((v[1:], size, align, len(self.params)))
                self.params.append('int64')
                continue
            self.arg_index[v[1:]] = len(self.params)
            self.params.append(IL_TYPE[t])
        self.body, self.next = self.read_body(lines, start)

    def read_body(self, lines, i):
        body = []
        while True:
            if i >= len(lines):
                die(f'{self.name}: no closing brace')
            s = lines[i].strip()
            i += 1
            if s == '}':
                return body, i
            if s and not s.startswith('#'):
                body.append(s)

    def err(self, msg):
        die(f'{self.name}: {msg}')

    def translate(self):
        blocks, order, cur = {}, [], None
        for s in self.body:
            if s.startswith('@'):
                cur = s[1:]
                blocks[cur] = []
                order.append(cur)
            else:
                if cur is None:
                    self.err(f'instruction before the first label: {s}')
                blocks[cur].append(s)
        self.blocks, self.order = blocks, order

        # Pass 1: temporaries (IL locals), stack slots (offsets in the frame), phi nodes.
        self.temps = {n: ('arg', idx, self.params[idx]) for n, idx in self.arg_index.items()}
        self.allocs, self.slots, self.dynamic, frame = {}, {}, {}, 0
        self.phis = {lbl: [] for lbl in order}
        self.local_types = []
        self.copies = []  # (local index, frame offset, size, IL argument index) for aggregate parameters
        for name, size, align, argi in self.agg_params:
            frame = (frame + align - 1) // align * align
            self.add_local(name, 'int64')
            self.copies.append((self.temps[name][1], frame, size, argi))
            frame += size
        for lbl in order:
            for s in blocks[lbl]:
                m = re.match(r'^%([^\s=]+)\s*=(:\S+)\s+call\s', s)
                if m:  # an aggregate result: a slot in this frame, its address passed to the callee
                    size, align = self.unit.types[m.group(2)]
                    frame = (frame + align - 1) // align * align
                    self.slots[m.group(1)] = frame
                    frame += size
                    self.add_local(m.group(1), 'int64')
                    continue
                m = re.match(r'^%([^\s=]+)\s*=l\s+alloc(4|8|16)\s+%', s)
                if m:  # alloca: a stack allocation of a run-time size, freed when the function returns
                    self.dynamic[m.group(1)] = True
                    self.add_local(m.group(1), 'int64')
                    continue
                m = re.match(r'^%([^\s=]+)\s*=(l|w|s|d)?\s*alloc(4|8|16)\s+(\d+)', s)
                if m:
                    align = int(m.group(3))
                    frame = (frame + align - 1) // align * align
                    self.allocs[m.group(1)] = frame
                    frame += int(m.group(4))
                    self.add_local(m.group(1), 'int64')
                    continue
                m = re.match(r'^%([^\s=]+)\s*=([wlsd])\s+phi\s+(.*)$', s)
                if m:
                    pairs = []
                    for part in split_top(m.group(3)):
                        lab, val = part.split()
                        pairs.append((lab[1:], val))
                    self.phis[lbl].append((m.group(1), IL_TYPE[m.group(2)], pairs))
                m = re.match(r'^%([^\s=]+)\s*=([wlsd])\s', s)
                if m and not (m.group(1) in self.temps):
                    self.add_local(m.group(1), IL_TYPE[m.group(2)])
        self.frame = (frame + 15) // 16 * 16
        self.frame_local = len(self.local_types)
        self.local_types.append('int64')
        self.label_id = {lbl: n for n, lbl in enumerate(order)}
        self.out, self.counter = [], 0
        self.emit_body()
        self.fragment['functions'].append(self.render())

    def add_local(self, name, il_type):
        self.temps[name] = ('local', len(self.local_types), il_type)
        self.local_types.append(il_type)

    def new_label(self):
        self.counter += 1
        return f'T{self.counter}'

    def emit(self, *lines):
        self.out.extend(lines)

    # operands ---------------------------------------------------------------

    def operand(self, tok, want):
        """Push operand `tok` converted to IL type `want` (int32, int64, float32, float64, or 'addr' = int64)."""
        tok = strip_extern(tok)
        if tok.startswith('%'):
            name = tok[1:]
            if name not in self.temps:
                self.err(f'undefined temporary {tok}')
            kind, idx, ty = self.temps[name]
            self.emit(f'ldarg {idx}' if kind == 'arg' else f'ldloc {idx}')
            return self.coerce(ty, want)
        if tok.startswith('$'):
            sym = self.unit.name(tok[1:])
            self.fragment['addrs'].add(sym)
            self.emit(f"ldsfld int64 Prog::'addr_{sym}'")
            return self.coerce('int64', want)
        if re.match(r'^[sd]_', tok):
            bits, n = float_bits(tok)
            if n == 4:
                self.emit('ldc.r4 (' + ' '.join(f'{b:02x}' for b in struct.pack('<I', bits)) + ')')
                return self.coerce('float32', want)
            self.emit('ldc.r8 (' + ' '.join(f'{b:02x}' for b in struct.pack('<Q', bits)) + ')')
            return self.coerce('float64', want)
        if want in ('int64', 'addr'):
            self.emit(f'ldc.i8 {int_value(tok, 64)}')
            return self.coerce('int64', want)
        self.emit(f'ldc.i4 {int_value(tok, 32)}')
        return self.coerce('int32', want)

    def coerce(self, have, want):
        if want is None or want == have or (want == 'addr' and have == 'int64'):
            return
        if want == 'addr':
            want = 'int64'
        table = {('int32', 'int64'): 'conv.i8', ('int64', 'int32'): 'conv.i4',
                 ('float32', 'float64'): 'conv.r8', ('float64', 'float32'): 'conv.r4'}
        if (have, want) not in table:
            self.err(f'no conversion from {have} to {want}')
        self.emit(table[(have, want)])

    def store_result(self, dst):
        self.emit(f'stloc {self.temps[dst][1]}')

    # control flow -----------------------------------------------------------

    def phi_copies(self, src, dst):
        moves = []
        for name, ty, pairs in self.phis[dst]:
            for lab, val in pairs:
                if lab == src:
                    moves.append((name, ty, val))
        for _, ty, val in moves:
            self.operand(val, ty)
        for name, _, _ in reversed(moves):
            self.emit(f'stloc {self.temps[name][1]}')

    def branch(self, src, dst):
        self.phi_copies(src, dst)
        self.emit(f'br B{self.label_id[dst]}')

    # instructions -----------------------------------------------------------

    def emit_body(self):
        frame_local = self.frame_local
        if self.frame:
            self.emit(f'ldc.i4 {self.frame}', 'localloc', 'conv.u8', f'stloc {frame_local}')
        for local, off, size, argi in self.copies:
            self.emit(f'ldloc {frame_local}', f'ldc.i8 {off}', 'add', f'stloc {local}')
            self.emit(f'ldloc {local}', 'conv.u', f'ldarg {argi}', 'conv.u', f'ldc.i4 {size}', 'cpblk')
        for n, lbl in enumerate(self.order):
            self.emit(f'B{self.label_id[lbl]}:')
            for s in self.blocks[lbl]:
                if re.match(r'^%[^\s=]+\s*=[wlsd]\s+phi\s', s):
                    continue
                self.instruction(s, lbl)
            # cproc leaves out a jump to the next block: the block falls through (with its phi copies).
            last = self.blocks[lbl][-1] if self.blocks[lbl] else ''
            if not last.startswith(('jmp ', 'jnz ', 'ret', 'hlt')):
                if n + 1 >= len(self.order):
                    self.err(f'block {lbl} falls off the end of the function')
                self.branch(lbl, self.order[n + 1])

    def instruction(self, s, lbl):
        m = re.match(r'^%([^\s=]+)\s*=([wlsd]|:\S+)\s+(\S+)\s*(.*)$', s)
        if m:
            return self.assignment(m.group(1), m.group(2), m.group(3), m.group(4), lbl)
        if s.startswith('blit '):  # blit src, dst, n: a block copy
            src, dst, n = split_top(s[5:])
            self.operand(dst, 'addr')
            self.emit('conv.u')
            self.operand(src, 'addr')
            self.emit('conv.u', f'ldc.i4 {int(n)}', 'cpblk')
            return
        m = re.match(r'^(store[bhwlsd])\s+(.*)$', s)
        if m:
            suffix, vt = STORES[m.group(1)]
            val, addr = split_top(m.group(2))
            self.operand(addr, 'addr')
            self.emit('conv.u')
            self.operand(val, IL_TYPE[vt])
            return self.emit(f'stind.{suffix}')
        if s == 'ret' or s.startswith('ret '):
            if s != 'ret' and self.agg_ret:  # copy the aggregate into the caller's result slot
                self.emit('ldarg 0', 'conv.u')
                self.operand(s[4:], 'addr')
                self.emit('conv.u', f'ldc.i4 {self.agg_ret[0]}', 'cpblk')
            elif s != 'ret':
                self.operand(s[4:], self.ret)
            return self.emit('ret')
        if s.startswith('jmp '):
            return self.branch(lbl, s[4:].strip()[1:])
        if s.startswith('jnz '):
            cond, t, f = split_top(s[4:])
            tramp = self.new_label()
            self.operand(cond, 'int32')
            self.emit(f'brtrue {tramp}')
            self.branch(lbl, f[1:])
            self.emit(f'{tramp}:')
            return self.branch(lbl, t[1:])
        if s.startswith('hlt'):
            return self.emit('ldc.i4.1', 'call void [System.Runtime]System.Environment::Exit(int32)', 'ldnull', 'throw')
        if s.startswith('call'):
            callee, args = split_call(s[4:])
            return self.call(None, None, callee, args)
        self.err(f'unsupported instruction {s}')

    def assignment(self, dst, dty, op, rest, lbl):
        if op.startswith('alloc') and dst in self.dynamic:
            self.operand(rest, 'int64')
            self.emit('conv.u', 'localloc', 'conv.u8', f'stloc {self.temps[dst][1]}')
            return
        if dty.startswith(':'):  # an aggregate result: op is call; the slot's address is the value
            if op != 'call':
                self.err(f'aggregate value from {op}')
            self.emit('ldloc %d' % self.frame_local, f'ldc.i8 {self.slots[dst]}', 'add',
                      f'stloc {self.temps[dst][1]}')
            callee, args = split_call(rest)
            return self.call(dst, dty, callee, args)
        dt = IL_TYPE[dty]
        if op.startswith('alloc'):
            self.emit('ldloc %d' % self.frame_local, f'ldc.i8 {self.allocs[dst]}', 'add',
                      f'stloc {self.temps[dst][1]}')
            return
        if op == 'phi':
            return  # the copies are on the edges
        if op == 'call':
            callee, args = split_call(rest)
            return self.call(dst, dty, callee, args)
        if op in LOADS:
            suffix, rty = LOADS[op]
            self.operand(rest, 'addr')
            self.emit('conv.u', f'ldind.{suffix}')
            if rty == 'w' and dty == 'l':  # a 32-bit load widened to a long
                self.emit('conv.i8' if op in ('loadw', 'loadsw', 'loadsb', 'loadsh') else 'conv.u8')
            else:
                self.coerce(IL_TYPE[rty], dt)
            return self.store_result(dst)
        if op == 'copy':
            self.operand(rest, dt)
            return self.store_result(dst)
        if op in CONV:
            src, _, il = CONV[op]
            self.operand(rest, IL_TYPE[src])
            self.emit(*il)
            return self.store_result(dst)
        if op == 'cast':
            src, method = BITCAST[dty]
            self.operand(rest, IL_TYPE[src])
            self.emit(f'call {dt} [System.Runtime]{method}')
            return self.store_result(dst)
        if op == 'neg':
            self.operand(rest, dt)
            self.emit('neg')
            return self.store_result(dst)
        if CMP_INT.match(op) or CMP_FLT.match(op):
            return self.compare(op, rest, dst)
        if op in INT_OPS or op in FLT_OPS:
            a, b = [x.strip() for x in rest.split(',', 1)]
            if dty in ('w', 'l'):
                if op not in INT_OPS:
                    self.err(f'{op} on integers')
                self.operand(a, dt)
                self.operand(b, 'int32' if op in SHIFT_OPS else dt)
                self.emit(INT_OPS[op])
            else:
                if op not in FLT_OPS:
                    self.err(f'{op} on floats')
                self.operand(a, dt)
                self.operand(b, dt)
                self.emit(FLT_OPS[op])
            return self.store_result(dst)
        if op in ('vastart', 'vaarg'):
            self.err('va_arg is not supported by the CIL backend')
        self.err(f'unsupported instruction %{dst} = {dty} {op} {rest}')

    def compare(self, op, rest, dst):
        a, b = [x.strip() for x in rest.split(',', 1)]
        m = CMP_INT.match(op)
        if m:
            un = m.group(1) == 'u'
            rel, t = m.group(2), IL_TYPE[m.group(3)]
        else:
            m = CMP_FLT.match(op)
            un = False
            rel, t = m.group(1), IL_TYPE[m.group(2)]
        self.operand(a, t)
        self.operand(b, t)
        # Ordered floats: clt/cgt are false on NaN, so ordered le/ge are the negations of the unordered-true forms.
        if rel == 'eq':
            self.emit('ceq')
        elif rel == 'ne':
            self.emit('ceq', 'ldc.i4.0', 'ceq')
        elif rel == 'lt':
            self.emit('clt.un' if un else 'clt')
        elif rel == 'gt':
            self.emit('cgt.un' if un else 'cgt')
        elif rel == 'le':  # not (a > b)
            self.emit('cgt.un' if un else 'cgt', 'ldc.i4.0', 'ceq')
        else:  # ge: not (a < b)
            self.emit('clt.un' if un else 'clt', 'ldc.i4.0', 'ceq')
        self.store_result(dst)

    def call(self, dst, dty, callee, args):
        typed, variadic = [], False
        for a in args:
            if a == '...':
                variadic = True
                continue
            parts = a.split(None, 1)
            if len(parts) != 2 or not (parts[0] in IL_TYPE or parts[0].startswith(':')):
                self.err(f'call argument without a type: {a}')
            typed.append(('int64' if parts[0].startswith(':') else IL_TYPE[parts[0]], parts[1]))
        aggregate = dty is not None and dty.startswith(':')
        ret = 'void' if aggregate else (IL_TYPE[dty] if dty else 'void')
        params = [t for t, _ in typed]
        if aggregate:
            if variadic:
                self.err('variadic calls returning aggregates are not supported')
            self.emit(f'ldloc {self.temps[dst][1]}')
            params = ['int64'] + params
            dst = None
        if variadic:
            return self.variadic_call(dst, dty, callee, typed)
        if callee.startswith('%'):  # indirect: a managed function pointer loaded from memory
            if aggregate:
                self.err('indirect calls returning aggregates are not supported')
            for t, v in typed:
                self.operand(v, t)
            self.operand(callee, 'int64')
            self.emit('conv.i')
            self.emit(f"calli {ret} ({', '.join(params)})")
        else:
            cname = self.unit.name(callee[1:])
            sig = {'ret': ret, 'params': params, 'variadic': variadic}
            known = self.fragment['calls'].get(cname)
            if known and known != sig:
                self.err(f'calls to {cname} with two signatures: {known} and {sig}')
            self.fragment['calls'][cname] = sig
            for t, v in typed:
                self.operand(v, t)
            self.emit(f"call {ret} Prog::'{cname}'({', '.join(params)})")
        if dst is not None:
            self.store_result(dst)
        elif ret != 'void':
            self.emit('pop')

    def variadic_call(self, dst, dty, callee, typed):
        """A C variadic call (printf): .NET cannot call a variadic function through P/Invoke, and the SysV ABI needs %al
        set to the number of vector registers used. The linker's shim nfcxx_vcall(name, six integer slots, eight
        double slots) calls the function through a variadic prototype, which sets %al. Integer and floating arguments
        keep their order within their own register class, as the callee expects."""
        if callee.startswith('%') or not callee.startswith('$'):
            self.err('indirect variadic calls are not supported by the CIL backend')
        name = self.unit.name(callee[1:])
        ints = [(t, v) for t, v in typed if t in ('int32', 'int64')]
        flts = [(t, v) for t, v in typed if t in ('float32', 'float64')]
        if len(ints) > 14 or len(flts) > 8:
            self.err(f'{name}: more than 14 integer or 8 floating arguments to a variadic call')
        self.fragment['calls'][name] = {'ret': 'int64', 'params': [], 'variadic': True}
        self.fragment['variadic'] = True
        # Integer arguments 7 to 14 go on the stack, in order: the shim's last eight integer slots.
        self.emit(f'ldstr "{name}"')
        for k in range(6):
            if k < len(ints):
                self.operand(ints[k][1], 'int64')
            else:
                self.emit('ldc.i8 0')
        for k in range(8):
            if k < len(flts):
                self.operand(flts[k][1], 'float64')
            else:
                self.emit('ldc.r8 (00 00 00 00 00 00 00 00)')
        for k in range(8):
            if k + 6 < len(ints):
                self.operand(ints[k + 6][1], 'int64')
            else:
                self.emit('ldc.i8 0')
        self.emit("call int64 Prog::'nfcxx_vcall'(string, int64, int64, int64, int64, int64, int64, float64, float64, "
                  "float64, float64, float64, float64, float64, float64, int64, int64, int64, int64, int64, int64, "
                  "int64, int64)")
        if dty is None:
            self.emit('pop')
        elif dty == 'w':
            self.emit('conv.i4')
        elif dty == 'l':
            pass
        else:
            self.err(f'{name}: a variadic call returning a float is not supported')
        if dst is not None:
            self.store_result(dst)

    def render(self):
        text = [f".method static {self.ret} '{self.name}'({', '.join(self.params)}) cil managed {{",
                '  .maxstack 1024']
        if self.local_types:
            text.append('  .locals init (' + ', '.join(f'{t} V{n}' for n, t in enumerate(self.local_types)) + ')')
        text += [x if x.endswith(':') else '    ' + x for x in self.out]
        text.append('}')
        return {'name': self.name, 'ret': self.ret, 'params': self.params, 'exported': self.exported,
                'il': text}


def main():
    src, tail_path, tu, out_path = sys.argv[1:5]
    lines = open(src, encoding='utf-8', errors='replace').read().split('\n')
    tail = open(tail_path, encoding='utf-8', errors='replace').read() if tail_path != '-' else ''
    unit = Unit(tu, parse_types(lines))
    scan_definitions(lines, unit)
    fragment = {'tu': tu, 'functions': [], 'data': [], 'calls': {}, 'addrs': set(),
                'ctors': [unit.name(c) for c in re.findall(r'^\s*\.quad\s+(\S+)\s*$', tail, re.M)]}
    sym_name = unit.name
    pending = False
    i = 0
    while i < len(lines):
        s = lines[i].strip()
        i += 1
        if not s or s.startswith('#'):
            continue
        if s == 'export':
            pending = True
            continue
        if s.startswith('type '):
            continue
        d = parse_data(s, sym_name)
        if d is not None:
            fragment['data'].append(d)
            continue
        m = re.match(r'^(export\s+)?function\s+(?:([wlsd]|:\S+)\s+)?\$([^\s(]+)\((.*)\)\s*\{\s*$', s)
        if not m:
            die(f'unexpected line: {s[:80]}')
        f = Function(unit, fragment, lines, i, bool(m.group(1)) or pending, m.group(2), m.group(3), m.group(4))
        pending = False
        f.translate()
        i = f.next
    fragment['addrs'] = sorted(fragment['addrs'])
    with open(out_path, 'w') as fh:
        json.dump(fragment, fh, indent=1)


if __name__ == '__main__':
    main()
