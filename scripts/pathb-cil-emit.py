#!/usr/bin/env python3
# pathb-cil-emit.py: Path B IR (scripts/pathb-dump --ir) -> a JSON fragment for scripts/cil-link.py, the CIL spike of the
# Path B route (docs/notes/pathb-cil.md). Same memory model as qbe2cil.py: pointers are int64 addresses, frame slots are
# one localloc per call, globals are the linker's addr_<name> fields.
#
#   pathb-dump --ir x.cpp | pathb-cil-emit.py - OUT.json
#
# The EH idiom of the lowered try (the IR of `try { B } catch (T) { H }`, see docs/notes/pathb-stage3.md):
#   if (_setjmp(buf) == 0) { B } else { H }
# becomes  .try { B } catch CxxThrow { H }, and _setjmp is 0 (the linker's runtime). throw is __throw_setup (the
# exception object's storage) followed by __throw, which raises CxxThrow (see cil-link.py's runtime). The
# destructors of the try block's objects are not run during unwinding yet (a documented gap).
# Refused with an error, never miscompiled: forms outside the subset below (bounds, index, switch, sret, copy,
# long double, inline asm, indirect calls).
import json
import re
import struct
import sys

EH_GLOBALS = {'__curr_eh_stack_entry', '__eh_curr_region', '__catch_clause_number', '__caught_object_address'}
SCALARS = {  # IR type -> (IL type, size, signed)
    'bool': ('int32', 1, False), 'char': ('int32', 1, True), 'signed_char': ('int32', 1, True),
    'unsigned_char': ('int32', 1, False), 'short': ('int32', 2, True), 'unsigned_short': ('int32', 2, False),
    'int': ('int32', 4, True), 'unsigned_int': ('int32', 4, False), 'long': ('int64', 8, True),
    'unsigned_long': ('int64', 8, False), 'long_long': ('int64', 8, True),
    'unsigned_long_long': ('int64', 8, False), 'float': ('float32', 4, True), 'double': ('float64', 8, True),
    'void': ('void', 0, False),
}
LDIND = {('int32', 1, True): 'i1', ('int32', 1, False): 'u1', ('int32', 2, True): 'i2', ('int32', 2, False): 'u2',
         ('int32', 4, True): 'i4', ('int32', 4, False): 'u4', ('int64', 8, True): 'i8', ('int64', 8, False): 'i8',
         ('float32', 4, True): 'r4', ('float64', 8, True): 'r8'}
STIND = {'int32': {1: 'i1', 2: 'i2', 4: 'i4'}, 'int64': {8: 'i8'}, 'float32': {4: 'r4'}, 'float64': {8: 'r8'}}
CMP = {'eq', 'ne', 'lt.s', 'lt.u', 'gt.s', 'gt.u', 'le.s', 'le.u', 'ge.s', 'ge.u'}
BIN = {'wadd': 'add', 'wsub': 'sub', 'wmul': 'mul', 'and': 'and', 'or': 'or', 'xor': 'xor'}


class Refused(Exception):
    pass


def refuse(msg):
    raise Refused(msg)


class Ref:
    def __init__(self, kind, name):
        self.kind, self.name = kind, name

    def __repr__(self):
        return f'{self.kind}"{self.name}"'


class Tmp:
    def __init__(self, n):
        self.n = n


def tokenize(text):
    toks, i, n = [], 0, len(text)
    while i < n:
        c = text[i]
        if c in ' \t\r\n':
            i += 1
        elif c in '()':
            toks.append(c)
            i += 1
        elif c == '"':
            j = text.index('"', i + 1)
            toks.append(text[i + 1 : j])
            i = j + 1
        elif c in '$@&' and i + 1 < n and text[i + 1] == '"':
            j = text.index('"', i + 2)
            toks.append(Ref({'$': 'slot', '@': 'glob', '&': 'fn'}[c], text[i + 2 : j]))
            i = j + 1
        elif c == '%' and i + 1 < n and text[i + 1].isdigit():
            j = i + 1
            while j < n and text[j].isdigit():
                j += 1
            toks.append(Tmp(int(text[i + 1 : j])))
            i = j
        else:
            j = i
            while j < n and text[j] not in ' \t\r\n()':
                j += 1
            atom = text[i:j]
            toks.append(int(atom) if re.match(r'^-?\d+$', atom) else
                        float(atom) if re.match(r'^-?\d+\.\d*(e-?\d+)?$', atom) else atom)
            i = j
    return toks


def parse(toks):
    pos = 0

    def read():
        nonlocal pos
        t = toks[pos]
        pos += 1
        if t == '(':
            out = []
            while toks[pos] != ')':
                out.append(read())
            pos += 1
            return out
        if t == ')':
            refuse('unbalanced )')
        return t
    forms = []
    while pos < len(toks):
        forms.append(read())
    return forms


class Emitter:
    def __init__(self, fragment):
        self.fragment = fragment
        self.globals = {}  # name -> IR type
        self.fn_sigs = {}

    def type_of(self, t):
        """IR type -> (IL type, size, signed); ptr and const are int64 addresses; aggregates are refused as values."""
        if isinstance(t, str):
            if t in SCALARS:
                return SCALARS[t]
            if t in ('long_double',):
                refuse('long double is not supported by the CIL spike')
            refuse(f'unsupported IR type {t}')
        if t and t[0] == 'ptr':
            return ('int64', 8, False)
        if t and t[0] == 'const':
            return self.type_of(t[1])
        if t and t[0] == 'fn':
            return ('int64', 8, False)
        refuse(f'aggregate or unsupported type {t!r} used as a value')


class Function:
    def __init__(self, em, form):
        self.em = em
        self.name = form[1]
        self.out = []
        self.locals = {}  # tmp name -> (index, IL type)
        self.local_types = []
        self.defs = {}    # tmp name -> defining let expression (for the EH idiom)
        self.loop_stack = []  # (break label, continue label, try depth)
        self.try_depth = 0
        self.labels = 0
        self.ret = 'void'
        self.params = []
        self.slots = {}
        self.frame = 0
        self.ret_local = None
        self.ret_label = None
        self.parse_header(form)

    def parse_header(self, form):
        for part in form[2:]:
            if not isinstance(part, list) or not part:
                continue
            if part[0] == 'ret':
                self.ret = self.em.type_of(part[1])[0]
            elif part[0] == 'params':
                for p in part[1:]:
                    # (param %N "name" TYPE) or, unnamed, (param %N TYPE)
                    if not (isinstance(p, list) and len(p) >= 3 and isinstance(p[1], Tmp)):
                        refuse(f'{self.name}: parameter form {p!r} is not supported by the spike')
                    pty = p[-1]
                    self.params.append((p[1].n, p[2] if len(p) == 4 else None, self.em.type_of(pty)[0]))
        if self.ret not in ('void', 'int32', 'int64', 'float32', 'float64'):
            refuse(f'{self.name}: unsupported return type {self.ret}')
        for pidx, pname, pil in self.params:
            self.locals[f'p{pidx}'] = ('arg', pidx, pil)

    def new_label(self, prefix):
        self.labels += 1
        return f'{prefix}{self.labels}'

    def new_local(self, il):
        self.local_types.append(il)
        return len(self.local_types) - 1

    def emit(self, *lines):
        self.out.extend(lines)

    # expressions -----------------------------------------------------------

    def coerce(self, have, want):
        if have == want or want is None or want == 'void':
            return
        table = {('int32', 'int64'): 'conv.i8', ('int64', 'int32'): 'conv.i4', ('int32', 'float64'): 'conv.r8',
                 ('int32', 'float32'): 'conv.r4', ('int64', 'float64'): 'conv.r8', ('float64', 'int32'): 'conv.i4',
                 ('float32', 'int32'): 'conv.i4', ('float64', 'float32'): 'conv.r4', ('float32', 'float64'): 'conv.r8',
                 ('float64', 'int64'): 'conv.i8', ('float32', 'int64'): 'conv.i8'}
        if (have, want) not in table:
            refuse(f'{self.name}: no conversion {have} -> {want}')
        self.emit(table[(have, want)])

    def expr(self, e):
        """Emit expression e; returns its IL type (the value is on the stack; void calls leave nothing)."""
        if isinstance(e, Tmp):
            key = f'p{e.n}' if f'p{e.n}' in self.locals else f'%{e.n}'
            if key not in self.locals:
                refuse(f'{self.name}: undefined temporary %{e.n}')
            kind, idx, il = self.locals[key]
            self.emit(f'ldarg {idx}' if kind == 'arg' else f'ldloc {idx}')
            return il
        if isinstance(e, Ref):
            if e.kind == 'slot':
                if e.name not in self.slots:
                    refuse(f'{self.name}: unknown slot {e.name}')
                self.emit('ldloc %d' % self.frame_local, f'ldc.i8 {self.slots[e.name]}', 'add')
                return 'int64'
            if e.kind == 'glob':
                self.em.addrs.add(self.em.gname(e.name))
                self.emit(f"ldsfld int64 Prog::'addr_{self.em.gname(e.name)}'")
                return 'int64'
            if e.kind == 'fn':
                refuse(f'{self.name}: taking the address of function {e.name} is not supported by the spike')
        if not isinstance(e, list) or not e:
            refuse(f'{self.name}: bad expression {e!r}')
        head = e[0]
        if head == 'const':
            il, size, signed = self.em.type_of(e[1])
            v = e[2]
            if il == 'float64':
                self.emit('ldc.r8 (' + ' '.join(f'{b:02x}' for b in struct.pack('<d', float(v))) + ')')
            elif il == 'float32':
                self.emit('ldc.r4 (' + ' '.join(f'{b:02x}' for b in struct.pack('<f', float(v))) + ')')
            elif il == 'int64':
                self.emit(f'ldc.i8 {int(v)}')
            else:
                self.emit(f'ldc.i4 {int(v)}')
            return il
        if head == 'null':
            self.emit('ldc.i8 0')
            return 'int64'
        if head == 'load':
            il, size, signed = self.em.type_of(e[1])
            self.expr(e[2])
            self.emit('conv.u')
            key = (il, size, signed)
            if key not in LDIND:
                refuse(f'{self.name}: load of {e[1]}')
            self.emit(f'ldind.{LDIND[key]}')
            return 'int32' if il == 'int32' else il
        if head == 'offset':
            self.expr(e[1])
            self.emit(f'ldc.i8 {int(e[2])}', 'add')
            return 'int64'
        if head == 'bitcast':
            il = self.em.type_of(e[1])[0]
            have = self.expr(e[2])
            self.coerce(have, il)
            return il
        if head == 'iconv':
            il = self.em.type_of(e[1])[0]
            have = self.expr(e[2])
            self.coerce(have, il)
            return il
        if head in CMP:
            il = self.em.type_of(e[1])[0]
            a = self.expr(e[2])
            self.coerce(a, il)
            b = self.expr(e[3])
            self.coerce(b, il)
            # le = not gt, ge = not lt; ne = not eq
            ops = {'eq': ['ceq'], 'ne': ['ceq', 'ldc.i4.0', 'ceq'], 'lt.s': ['clt'], 'lt.u': ['clt.un'],
                   'gt.s': ['cgt'], 'gt.u': ['cgt.un'], 'le.s': ['cgt', 'ldc.i4.0', 'ceq'],
                   'le.u': ['cgt.un', 'ldc.i4.0', 'ceq'], 'ge.s': ['clt', 'ldc.i4.0', 'ceq'],
                   'ge.u': ['clt.un', 'ldc.i4.0', 'ceq']}
            self.emit(*ops[head])
            return 'int32'
        if head in BIN:
            il = self.em.type_of(e[1])[0]
            a = self.expr(e[2])
            self.coerce(a, il)
            b = self.expr(e[3])
            self.coerce(b, il)
            self.emit(BIN[head])
            return il
        if head == 'wneg':
            il = self.em.type_of(e[1])[0]
            have = self.expr(e[2])
            self.coerce(have, il)
            self.emit('neg')
            return il
        if head == 'call':
            return self.call(e)
        refuse(f'{self.name}: unsupported expression {head}')

    def call(self, e):
        callee = e[2]
        if not isinstance(callee, Ref) or callee.kind != 'fn':
            refuse(f'{self.name}: indirect calls are not supported by the spike')
        name = callee.name
        ret = self.em.type_of(e[1])[0]
        args = e[3:]
        if name in ('_setjmp',):
            for a in args:
                self.expr(a)
                self.emit('pop')
            self.emit('ldc.i4.0')
            return 'int32'
        typed = []
        for a in args:
            if isinstance(a, list) and a and a[0] == 'sret':
                refuse(f'{self.name}: sret results are not supported by the spike')
            il = self.expr(a)
            typed.append(il)
        gname = self.em.fn_name(name)
        sig = {'ret': ret, 'params': typed, 'variadic': False}
        known = self.em.fragment_calls.get(gname)
        if known and known != sig:
            refuse(f'{self.name}: {name} called with two signatures')
        self.em.fragment_calls[gname] = sig
        self.emit(f"call {ret} Prog::'{gname}'({', '.join(typed)})")
        return ret

    # statements -------------------------------------------------------------

    def has_clause_test(self, node, k):
        """True if the IR tree compares something against the constant k in an eq (a clause-number test)."""
        if isinstance(node, list):
            if len(node) == 4 and node[0] == 'eq' and isinstance(node[3], list) and len(node[3]) == 3 \
                    and node[3][0] == 'const' and node[3][2] == k:
                return True
            return any(self.has_clause_test(x, k) for x in node)
        return False

    def ir_label(self, name):
        return re.sub(r'[^A-Za-z0-9_]', '_', name) + '_' + str(len(name))

    def stmts(self, lst):
        for x in lst:
            self.stmt(x)

    def stmt(self, s):
        if not isinstance(s, list) or not s:
            refuse(f'{self.name}: bad statement {s!r}')
        head = s[0]
        if head == 'block':
            for x in s[1:]:
                self.stmt(x)
            return
        if head == 'let':
            tmp, ty, e = s[1], s[2], s[3]
            il = self.em.type_of(ty)[0]
            if il == 'void':
                refuse(f'{self.name}: void let')
            self.defs[tmp.n] = e
            idx = self.new_local(il)
            self.locals[f'%{tmp.n}'] = ('local', idx, il)
            have = self.expr(e)
            self.coerce(have, il)
            self.emit(f'stloc {idx}')
            return
        if head == 'set':
            tmp, e = s[1], s[2]
            key = f'%{tmp.n}'
            if key not in self.locals:
                refuse(f'{self.name}: set of undefined %{tmp.n}')
            kind, idx, il = self.locals[key]
            have = self.expr(e)
            self.coerce(have, il)
            self.emit(f'stloc {idx}')
            return
        if head == 'store':
            ty, addr, val = s[1], s[2], s[3]
            il, size, _ = self.em.type_of(ty)
            self.expr(addr)
            self.emit('conv.u')
            have = self.expr(val)
            self.coerce(have, il)
            if il not in STIND or size not in STIND[il]:
                refuse(f'{self.name}: store of {ty}')
            self.emit(f'stind.{STIND[il][size]}')
            return
        if head == 'eval':
            il = self.expr(s[1])
            if il != 'void':
                self.emit('pop')
            return
        if head == 'return':
            if len(s) > 1:
                have = self.expr(s[1])
                self.coerce(have, self.ret)
                if self.try_depth:
                    self.emit(f'stloc {self.ret_local}', f'leave {self.ret_label}')
                else:
                    self.emit('ret')
            else:
                self.emit(f'leave {self.ret_label}' if self.try_depth else 'ret')
            return
        if head == 'unreachable':
            self.emit('ldnull', 'throw')
            return
        if head == 'nonnull':
            self.expr(s[1])
            self.emit('pop')
            return
        if head == 'if':
            return self.if_stmt(s)
        if head == 'loop':
            return self.loop_stmt(s)
        if head == 'label':
            self.emit(f'L_{self.ir_label(s[1])}:')
            return
        if head == 'goto':
            target = f'L_{self.ir_label(s[1])}'
            self.emit(f'leave {target}' if self.try_depth else f'br {target}')
            return
        if head == 'break' or head == 'continue':
            if not self.loop_stack:
                refuse(f'{self.name}: {head} outside a loop')
            brk, cont, depth = self.loop_stack[-1]
            target = brk if head == 'break' else cont
            self.emit(f'leave {target}' if self.try_depth > depth else f'br {target}')
            return
        refuse(f'{self.name}: unsupported statement {head}')

    def cond_defined_by_setjmp(self, cond):
        """True if cond is the lowered try's `_setjmp(...) == 0` (the defining let is an eq against 0 of a _setjmp call)."""
        if not isinstance(cond, Tmp):
            return False
        d = self.defs.get(cond.n)
        if not (isinstance(d, list) and d[0] == 'eq'):
            return False
        a, b = d[2], d[3]
        if not (isinstance(a, Tmp) and isinstance(b, list) and b[0] == 'const' and b[2] == 0):
            return False
        da = self.defs.get(a.n)
        return isinstance(da, list) and da[0] == 'call' and isinstance(da[2], Ref) and da[2].name == '_setjmp'

    def if_stmt(self, s):
        cond, then = s[1], s[2]
        els = s[3] if len(s) > 3 else None
        # (then S...) and (else S...) hold statement lists; a bare statement is a one-element list
        then_body = then[1:] if isinstance(then, list) and then and then[0] == 'then' else [then]
        else_body = None
        if els is not None:
            else_body = els[1:] if isinstance(els, list) and els and els[0] == 'else' else [els]
        if self.cond_defined_by_setjmp(cond):
            return self.try_stmt(then_body, else_body)
        end = self.new_label('IL_end')
        self.expr(cond)
        if else_body is None:
            self.emit(f'brfalse {end}')
            self.stmts(then_body)
            self.emit(f'{end}:')
            return
        els_l = self.new_label('IL_else')
        self.emit(f'brfalse {els_l}')
        self.stmts(then_body)
        self.emit(f'br {end}', f'{els_l}:')
        self.stmts(else_body)
        self.emit(f'{end}:')

    def try_stmt(self, body, handler):
        # Only one catch clause is supported: the catch sets __catch_clause_number to 1, and selecting among several
        # clauses needs the typeinfo objects (not emitted yet). An eq against a larger clause number means more clauses.
        if handler is not None and self.has_clause_test(handler, 2):
            refuse(f'{self.name}: try with several catch clauses is not supported by the spike (needs typeinfo matching)')
        end = self.new_label('IL_try_end')
        self.try_depth += 1
        self.emit('.try {')
        self.stmts(body)
        self.emit(f'leave {end}', '}')
        self.try_depth -= 1
        self.emit('catch class CxxThrow {')
        self.try_depth += 1
        self.emit('pop')  # the exception object; the thrown pointer is the linker's cxx_ptr
        self.emit(f"ldsfld int64 Prog::'addr_{self.em.gname('__caught_object_address')}'", 'conv.u',
                  "ldsfld int64 Prog::'cxx_ptr'", 'stind.i8')
        self.emit(f"ldsfld int64 Prog::'addr_{self.em.gname('__catch_clause_number')}'", 'conv.u', 'ldc.i4.1', 'stind.i4')
        self.em.addrs.update({self.em.gname('__caught_object_address'), self.em.gname('__catch_clause_number')})
        if handler is not None:
            self.stmts(handler)
        self.emit(f'leave {end}', '}')
        self.try_depth -= 1
        self.emit(f'{end}:')

    def loop_stmt(self, s):
        body = step = None
        for part in s[1:]:
            if isinstance(part, list) and part and part[0] == 'body':
                body = part[1:]
            elif isinstance(part, list) and part and part[0] == 'step':
                step = part[1:]
        top = self.new_label('IL_top')
        cont = self.new_label('IL_cont')
        brk = self.new_label('IL_brk')
        self.emit(f'{top}:')
        self.loop_stack.append((brk, cont, self.try_depth))
        self.stmts(body or [])
        self.emit(f'{cont}:')
        for st in step or []:  # break and continue in the step belong to this loop too
            self.stmt(st)
        self.loop_stack.pop()
        self.emit(f'br {top}', f'{brk}:')

    # the function -----------------------------------------------------------

    def translate(self, form):
        self.frame_local = None
        slots = []
        body = []
        for part in form[2:]:
            if isinstance(part, list) and part and part[0] == 'slot':
                slots.append(part)
            elif isinstance(part, list) and part and part[0] == 'body':
                body.extend(part[1:])
            elif isinstance(part, list) and part and part[0] in ('block', 'let', 'store', 'eval', 'return',
                                                                     'unreachable', 'if', 'set', 'loop', 'nonnull', 'label',
                                                                     'goto', 'break', 'continue'):
                body.append(part)
        off = 0
        for sl in slots:
            size, align = int(sl[3]), int(sl[4])
            off = (off + align - 1) // align * align
            self.slots[sl[1]] = off
            off += size
        self.frame = (off + 15) // 16 * 16
        self.frame_local = self.new_local('int64')
        self.ret_local = self.new_local(self.ret) if self.ret != 'void' else None
        self.ret_label = self.new_label('IL_ret')
        if self.frame:
            self.emit(f'ldc.i4 {self.frame}', 'localloc', 'conv.u8', f'stloc {self.frame_local}')
        for stmt in body:
            self.stmt(stmt)
        if self.ret == 'void':
            self.emit(f'{self.ret_label}:', 'ret')
        else:
            self.emit('ldnull', 'throw')  # falling off a non-void function: undefined behaviour in C++
            self.emit(f'{self.ret_label}:', 'ldloc %d' % self.ret_local, 'ret')
        lines = ['.method static %s %s(%s) cil managed {' % (self.ret, self.em.fn_name(self.name),
                                                           ', '.join(p[2] for p in self.params)), '  .maxstack 1024']
        if self.local_types:
            lines.append('  .locals init (' + ', '.join(f'{t} V{i}' for i, t in enumerate(self.local_types)) + ')')
        lines += ['    ' + x if not x.endswith(':') else x for x in self.out]
        lines.append('}')
        return lines


INT_ITEM = {1: 'int8', 2: 'int16', 4: 'int32', 8: 'int64'}


def global_data(f, em):
    """`(global NAME TYPE SIZE ALIGN [(static)] (init ITEM...))` -> a fragment data entry. ITEMs are (addr OFF TYPE REF
    ADD) and (scalar OFF TYPE (const TYPE V) | (null TYPE)); the offsets become zero fill. An EH runtime global
    (extern, in EH_GLOBALS) is zero storage here; any other extern is the linker's dlsym."""
    name, size, align = f[1], int(f[3]), int(f[4])
    init = None
    for part in f[5:]:
        if isinstance(part, list) and part and part[0] == 'init':
            init = part[1:]
        if part == ['extern'] or (isinstance(part, list) and part == ['extern']):
            if name in EH_GLOBALS:
                return {'name': name, 'exported': True, 'align': align, 'size': size, 'items': []}
            return None
    if init is None:
        return None
    items, pos = [], 0
    for it in init:
        kind, off = it[0], int(it[1])
        if off > pos:
            items.append(['zero', off - pos])
            pos = off
        if kind == 'zero':  # (zero OFF SIZE)
            items.append(['zero', int(it[2])])
            pos = off + int(it[2])
            continue
        if kind == 'addr':
            ref = it[3]
            if not isinstance(ref, Ref):
                refuse(f'{name}: address item of {ref!r}')
            items.append(['addr', ref.name, int(it[4])])
            pos += 8
        elif kind == 'scalar':
            val = it[3]
            il, sz, _ = em.type_of(it[2]) if not isinstance(it[2], list) else (
                'int64', 8, False) if it[2][0] == 'ptr' else em.type_of(it[2])
            if val[0] == 'null':
                items.append(['int64', 0])
                pos += 8
                continue
            v = val[2]
            if il == 'float64':
                items.append(['float64', struct.unpack('<Q', struct.pack('<d', float(v)))[0]])
            elif il == 'float32':
                items.append(['float32', struct.unpack('<I', struct.pack('<f', float(v)))[0]])
            else:
                items.append([INT_ITEM[sz], int(v)])
            pos += sz
        else:
            refuse(f'{name}: initializer item {kind}')
    if pos < size:
        items.append(['zero', size - pos])
    return {'name': name, 'exported': True, 'align': align, 'size': size, 'items': items}


def main():
    src, out_path = sys.argv[1], sys.argv[2]
    text = sys.stdin.read() if src == '-' else open(src).read()
    forms = parse(tokenize(text))
    fragment = {'tu': 'pathb', 'functions': [], 'data': [], 'calls': {}, 'addrs': set(), 'ctors': []}
    em = Emitter(fragment)
    em.addrs = fragment['addrs']
    em.fragment_calls = fragment['calls']
    em.gname = lambda n: n
    em.fn_name = lambda n: n
    em.fn_il = lambda n: f"int64 Prog::'{n}'()"
    for f in forms:
        if not isinstance(f, list) or not f:
            continue
        if f[0] == 'global':
            d = global_data(f, em)
            if d is not None:
                fragment['data'].append(d)
            continue
        if f[0] == 'function':
            name = f[1]
            if any(isinstance(p, list) and p and p[0] == 'variadic' for p in f):
                refuse(f'{name}: variadic definitions are not supported by the spike')
            fn = Function(em, f)
            fragment['functions'].append({'name': name, 'ret': fn.ret, 'params': [p[2] for p in fn.params],
                                          'exported': True, 'il': fn.translate(f)})
    fragment['addrs'] = sorted(fragment['addrs'])
    with open(out_path, 'w') as fh:
        json.dump(fragment, fh, indent=1)


if __name__ == '__main__':
    try:
        main()
    except Refused as e:
        sys.exit(f'pathb-cil-emit: refused: {e}')
