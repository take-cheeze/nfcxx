#!/usr/bin/env python3
"""Path B stage 3: emit QBE IL from the nfcxx mid-level IR text (docs/notes/pathb-stage2.md, sections 6 and 7).

Usage: pathb-qbe-emit.py [FILE.ir | -]        QBE IL on stdout (reads stdin for '-' or no argument)
       pathb-qbe-emit.py --append-weak IL.ssa ASM.s   append `.weak` lines for the IR (weak) definitions (QBE has no weak)

Exit status:
  0  the module was emitted
  3  refused: the IR has a node, type or marker this emitter does not handle; the reason is on stderr
  1  error: malformed IR text, or an IR format older than this emitter (rebuild the harness)

The emitter never guesses. Anything it does not know is a refusal, never silently dropped. Checked IR operations
(cdiv, crem, cshl, cshr, cf2i, cadd, csub, cmul, cneg, bounds, nonnull, unreachable) become a compare and a branch
to one shared abort block that calls abort(). Registers are stack slots; QBE's own promotion turns them back into
SSA temporaries. Scalar sizes assume LP64 (int 4, long 8, pointers 8), which is what the x86-64 Linux target uses.
"""
import math
import re
import struct
import sys


class Refused(Exception):
    """A node this emitter does not handle (exit status 3)."""


class BadIR(Exception):
    """Malformed IR text or an unknown IR format (exit status 1)."""


# ------------------------------------------------------------------ reading the IR text

class Str(str):
    """A double-quoted string. Each character is one byte (latin-1)."""


class Sym(tuple):
    """A sigil and a quoted name: $"x" (slot), @"x" (static object), &"f" (function)."""


def _read_string(text, i):
    assert text[i] == '"'
    out = []
    i += 1
    n = len(text)
    while True:
        if i >= n:
            raise BadIR("unterminated string in IR")
        c = text[i]
        if c == '"':
            return "".join(out), i + 1
        if c == "\\":
            i += 1
            if i >= n:
                raise BadIR("bad escape at end of IR")
            e = text[i]
            if e == "n":
                out.append("\n")
                i += 1
            elif e in '"\\':
                out.append(e)
                i += 1
            elif e in "01234567" and i + 2 < n and text[i + 1] in "01234567" and text[i + 2] in "01234567":
                out.append(chr(int(text[i:i + 3], 8)))
                i += 3
            else:
                raise BadIR("unknown escape \\%s in IR string" % e)
        else:
            out.append(c)
            i += 1


def tokenize(text):
    toks = []
    i = 0
    n = len(text)
    while i < n:
        c = text[i]
        if c.isspace():
            i += 1
        elif c in "()":
            toks.append(c)
            i += 1
        elif c == '"':
            s, i = _read_string(text, i)
            toks.append(Str(s))
        elif c in "$@&" and i + 1 < n and text[i + 1] == '"':
            s, i = _read_string(text, i + 1)
            toks.append(Sym((c, s)))
        else:
            j = i
            while j < n and not text[j].isspace() and text[j] not in '()"':
                j += 1
            toks.append(text[i:j])
            i = j
    return toks


def parse_forms(toks):
    """Return the list of top-level forms. A form is a Python list, or an atom (str, Str, Sym)."""
    stack = [[]]
    for t in toks:
        if t == "(":
            stack.append([])
        elif t == ")":
            if len(stack) == 1:
                raise BadIR("unbalanced ')' in IR")
            done = stack.pop()
            stack[-1].append(done)
        else:
            stack[-1].append(t)
    if len(stack) != 1:
        raise BadIR("unbalanced '(' in IR")
    return stack[0]


# ------------------------------------------------------------------ types

VOID = ("void",)
SCALARS = {
    "bool": ("int", 1, False, True),
    "char": ("int", 1, True, False),
    "signed_char": ("int", 1, True, False),
    "unsigned_char": ("int", 1, False, False),
    "short": ("int", 2, True, False),
    "unsigned_short": ("int", 2, False, False),
    "int": ("int", 4, True, False),
    "unsigned_int": ("int", 4, False, False),
    "long": ("int", 8, True, False),
    "unsigned_long": ("int", 8, False, False),
    "long_long": ("int", 8, True, False),
    "unsigned_long_long": ("int", 8, False, False),
    "float": ("float", 4),
    "double": ("float", 8),
}


def parse_type(x):
    if isinstance(x, str) and not isinstance(x, Str):
        if x == "void":
            return VOID
        if x in SCALARS:
            return SCALARS[x]
        if x == "long_double":
            raise Refused("type long_double (no QBE type; cproc refuses it too)")
        raise Refused("type %s" % x)
    if not isinstance(x, list) or not x:
        raise BadIR("bad type form %r" % (x,))
    head = x[0]
    if head == "ptr":
        return ("ptr", parse_type(x[1]) if len(x) == 2 else None)
    if head == "const" or head == "volatile":
        return parse_type(x[1])
    if head == "array":
        if x[1] == "?":
            return ("array", None, parse_type(x[2]))   # variable-length: no count
        return ("array", int(x[1]), parse_type(x[2]))
    if head in ("struct", "class", "union"):
        return ("agg", head, str(x[1]))
    if head == "fn":
        return ("fn",)
    raise Refused("type form (%s ...)" % head)


def is_agg(ty):
    return ty[0] in ("agg", "array")


def is_int(ty):
    return ty[0] == "int"


def is_bool(ty):
    return ty[0] == "int" and ty[3]


def ty_size(ty):
    if ty[0] == "int":
        return ty[1]
    if ty[0] == "float":
        return ty[1]
    if ty[0] in ("ptr", "fn"):
        return 8
    raise Refused("scalar size of aggregate type in value position")


def qcls(ty):
    """QBE class of a value of IR type ty."""
    if ty[0] == "int":
        return "w" if ty[1] <= 4 else "l"
    if ty[0] == "float":
        return "s" if ty[1] == 4 else "d"
    if ty[0] in ("ptr", "fn"):
        return "l"
    if ty[0] == "void":
        return None
    raise Refused("aggregate value of type %s (aggregates are addresses in the IR)" % (ty,))


def int_is_signed(ty):
    return ty[0] == "int" and ty[2]


def int_range(ty):
    bits = ty[1] * 8
    if int_is_signed(ty):
        return -(1 << (bits - 1)), (1 << (bits - 1)) - 1
    return 0, (1 << bits) - 1


def wrap_int(v, cls):
    bits = 32 if cls == "w" else 64
    v &= (1 << bits) - 1
    if v >= 1 << (bits - 1):
        v -= 1 << bits
    return v


def float_lit(v, size):
    if not math.isfinite(v):
        raise Refused("non-finite floating constant %r" % v)
    if size == 4:
        v = struct.unpack("f", struct.pack("f", v))[0]
        return "s_" + repr(v)
    return "d_" + repr(v)


def data_float(v, size):
    if not math.isfinite(v):
        raise Refused("non-finite floating constant %r" % v)
    if size == 4:
        v = struct.unpack("f", struct.pack("f", v))[0]
        return "s", "s_" + repr(v)
    return "d", "d_" + repr(v)


# ------------------------------------------------------------------ helpers over forms

def head_of(x):
    if isinstance(x, list) and x and isinstance(x[0], str) and not isinstance(x[0], Str):
        return x[0]
    return None


def form_text(x):
    if isinstance(x, list):
        return "(" + " ".join(form_text(y) for y in x) + ")"
    if isinstance(x, Sym):
        return "%s\"%s\"" % (x[0], x[1])
    if isinstance(x, Str):
        return '"%s"' % x
    return str(x)


def as_int(x):
    """An integer atom. The IR prints unsigned constants in hexadecimal (0x...) as well as in decimal."""
    if isinstance(x, str) and not isinstance(x, Str) and re.fullmatch(r"-?(0x[0-9a-fA-F]+|\d+)", x):
        return int(x, 0)
    raise BadIR("expected an integer, got %s" % form_text(x))


REG_RE = re.compile(r"%(\d+)$")
QNAME_RE = re.compile(r"[A-Za-z_][A-Za-z0-9_.]*$")


def qsym(name):
    if not QNAME_RE.match(name):
        raise Refused("symbol name %r needs quoting in QBE" % name)
    return name


# ------------------------------------------------------------------ values

class Val:
    __slots__ = ("t", "cls", "ty")

    def __init__(self, t, cls, ty):
        self.t = t
        self.cls = cls
        self.ty = ty


MEM_LOAD = {"w": "loadw", "l": "loadl", "s": "loads", "d": "loadd"}
MEM_STORE = {"w": "storew", "l": "storel", "s": "stores", "d": "stored"}
CMP_INT = {"lt.s": "cslt", "le.s": "csle", "lt.u": "cult", "le.u": "cule"}
CMP_FLT = {"lt.f": "clt", "le.f": "cle"}


class Module:
    def __init__(self):
        self.globals = {}      # IR name -> type
        self.strings = {}      # data name -> bytes
        self.out = []
        self.need_sink = False  # a function that returns twice stores slot addresses into SINK
        self.thread = {}       # IR name -> "def" or "ext": thread-local globals ((thread) marker; ext = declaration only)
        self.vhelpers = {}     # volatile access helpers used so far: QBE function name -> its text lines
        self.weakrefs = {}     # undefined functions that are weak references (TLS init functions, see weak_refs)
        self.startup = []      # (".init_array" or ".fini_array", priority (0: none), QBE symbol)
        self.funcs = set()     # IR names of the functions defined in this module
        self.got = {}          # IR name of an external function whose address is taken -> its pointer cell
        self.abi = {}          # struct name -> AbiType: the C calling convention shape of aggregates by value


# Functions that return twice. QBE does not know that, and it promotes a stack slot to an SSA temporary when only
# loads and stores use its address. After longjmp the promoted value would be the one from the setjmp call, not the
# last one assigned. A function that calls one of these keeps every slot in memory (see escape_slots).
SINK = "pathb_escape"
RETURNS_TWICE = frozenset(["setjmp", "_setjmp", "sigsetjmp", "__sigsetjmp", "savectx", "vfork", "getcontext"])


def escape_slots(allocs):
    """Store the address of every slot into a module-level sink. An address that escapes to memory is neither
    promoted to a temporary nor forwarded across calls by QBE's load optimisation, so each slot's value stays in
    memory, where longjmp finds the last assignment. (The sink has to be a global: a stack slot used for this would
    itself be promoted, and the stores would vanish before QBE looks at escapes.)"""
    return ["\tstorel %s, $%s" % (line.split()[0], SINK) for line in allocs]


class AbiType:
    """(abi-type "NAME" SIZE ALIGN SHAPE): how a struct or class is passed and returned by value. shape is "leaves"
    (the scalars to classify), "memory" (more than 16 bytes), "empty" (no data: not passed) or "unsupported"."""

    def __init__(self, tn, size, align, shape, why):
        self.tn = tn
        self.size = size
        self.align = align
        self.shape = shape
        self.why = why


LEAF_SIZE = {"b": 1, "h": 2, "w": 4, "l": 8, "s": 4, "d": 8}


def declare_abi_type(mod, f):
    """Read an (abi-type ...) form, add it to the module and write the QBE type declaration."""
    if len(f) < 5:
        raise BadIR("abi-type form")
    name = str(f[1])
    size = as_int(f[2])
    align = as_int(f[3])
    if align not in (1, 2, 4, 8, 16):
        raise BadIR("abi-type %s: alignment %d" % (name, align))
    spec = f[4]
    tn = ":ty%d" % len(mod.abi)
    shape = head_of(spec)
    why = None
    fields = None
    if shape == "memory":
        fields = "%d" % size
    elif shape == "empty":
        fields = ""
    elif shape == "unsupported":
        why = str(spec[1])
    elif shape == "leaf":
        parts = []
        cur = 0
        for lf in f[4:]:
            if head_of(lf) != "leaf" or len(lf) != 3:
                raise BadIR("abi-type %s: bad leaf %s" % (name, form_text(lf)))
            off = as_int(lf[1])
            k = lf[2]
            if not isinstance(k, str) or k not in LEAF_SIZE:
                raise BadIR("abi-type %s: leaf kind %s" % (name, form_text(lf)))
            ks = LEAF_SIZE[k]
            if off < cur:
                raise BadIR("abi-type %s: leaf at %d out of order or overlapping" % (name, off))
            if off % ks != 0:
                raise Refused("abi-type %s: member at offset %d is not naturally aligned" % (name, off))
            if off > cur:
                parts.append("b %d" % (off - cur))
            parts.append(k)
            cur = off + ks
        if cur > size:
            raise BadIR("abi-type %s: leaves exceed the size" % name)
        if size > cur:
            parts.append("b %d" % (size - cur))
        fields = ", ".join(parts)
        shape = "leaves"
    else:
        raise BadIR("abi-type %s: unknown shape %s" % (name, form_text(spec)))
    mod.abi[name] = AbiType(tn, size, align, shape, why)
    if fields is not None:
        mod.out.append("type %s = align %d { %s }" % (tn, align, fields))


def abi_of(mod, tyform):
    """The AbiType of an aggregate type form, or None (an IR without (abi-type ...) keeps the pointer convention)."""
    ty = parse_type(tyform)
    if ty[0] != "agg":
        return None
    return mod.abi.get(ty[2])


class Fn:
    """One function body. Statements are emitted into self.body; registers and slots into self.allocs."""

    def __init__(self, mod, name, ret_ty):
        self.mod = mod
        self.name = name
        self.ret_ty = ret_ty
        self.body = []
        self.allocs = []
        self.inits = []      # instructions that run first in @start, after the allocs
        self.nvla = 0        # vlaalloc statements so far (each has a capacity slot)
        self.returns_twice = False  # calls setjmp or another function that returns twice
        self.ntmp = 0
        self.nlab = 0
        self.dead = False
        self.regs = {}       # N -> (type, cls)
        self.slots = {}      # IR name -> (qname, type)
        self.nslot = 0
        self.labels = {}     # IR label name -> @name
        self.breaks = []     # exit labels of enclosing loops and switches
        self.conts = []      # step labels of enclosing loops, for (continue)
        self.case_labels = {}  # id(marker) -> @label, for the switch being emitted
        self.abort_used = False
        self.sret_buf = None   # a function returning an aggregate in the C convention: the buffer whose address it returns

    # ---- output
    def _put(self, s):
        self.body.append("\t" + s)

    def tmp(self):
        self.ntmp += 1
        return "%%t%d" % self.ntmp

    def newlab(self):
        self.nlab += 1
        return "@b%d" % self.nlab

    def start_block(self, lab):
        if not self.dead:
            self._put("jmp %s" % lab)
        self.body.append(lab)
        self.dead = False

    def ensure_live(self):
        if self.dead:
            self.body.append(self.newlab())
            self.dead = False

    def emit(self, s):
        self.ensure_live()
        self._put(s)

    def jmp(self, lab):
        self.ensure_live()
        self._put("jmp %s" % lab)
        self.dead = True

    def jnz(self, c, yes, no):
        self.ensure_live()
        self._put("jnz %s, %s, %s" % (c, yes, no))
        self.dead = True

    def ret(self, v=None):
        self.ensure_live()
        self._put(("ret" if self.sret_buf is None else "ret %s" % self.sret_buf) if v is None else "ret %s" % v)
        self.dead = True

    def label(self, lab):
        self.start_block(lab)

    def abort_label(self):
        self.abort_used = True
        return "@abort"

    def trap_if(self, c):
        """Abort when the w value c is nonzero."""
        ok = self.newlab()
        self.jnz(c, self.abort_label(), ok)
        self.label(ok)

    def trap_unless(self, c):
        """Abort when the w value c is zero."""
        ok = self.newlab()
        self.jnz(c, ok, self.abort_label())
        self.label(ok)

    def lab_for(self, name):
        if name not in self.labels:
            self.labels[name] = "@L%d" % len(self.labels)
        return self.labels[name]

    # ---- registers and slots
    def declare_reg(self, n, ty):
        if n in self.regs:
            raise BadIR("register %%%d declared twice in %s" % (n, self.name))
        cls = qcls(ty)
        if cls is None:
            raise Refused("register %%%d of type void" % n)
        self.regs[n] = (ty, cls)
        size = 4 if cls == "w" else 8 if cls == "l" else ty_size(ty)
        self.allocs.append("\t%%r%d =l alloc%d %d" % (n, size, size))
        return cls

    def reg_val(self, n):
        if n not in self.regs:
            raise BadIR("register %%%d used before its declaration in %s" % (n, self.name))
        ty, cls = self.regs[n]
        t = self.tmp()
        self.emit("%s =%s %s %%r%d" % (t, cls, MEM_LOAD[cls], n))
        return Val(t, cls, ty)

    def set_reg(self, n, v):
        if n not in self.regs:
            raise BadIR("assignment to undeclared register %%%d in %s" % (n, self.name))
        ty, cls = self.regs[n]
        if v.cls != cls:
            raise Refused("register %%%d of class %s assigned a value of class %s" % (n, cls, v.cls))
        self.emit("%s %s, %%r%d" % (MEM_STORE[cls], v.t, n))

    def slot_val(self, name):
        if name not in self.slots:
            raise BadIR("slot $\"%s\" not declared in %s" % (name, self.name))
        q, ty = self.slots[name]
        return Val(q, "l", ("ptr", ty))

    # ---- operands
    def const(self, c):
        if len(c) != 3:
            raise BadIR("bad constant %s" % form_text(c))
        ty = parse_type(c[1])
        v = c[2]
        if isinstance(v, list) or isinstance(v, Str):
            raise Refused("constant %s" % form_text(c))
        if ty[0] == "float":
            fv = float(str(v))
            return Val(float_lit(fv, ty[1]), qcls(ty), ty)
        if ty[0] in ("int", "ptr"):
            cls = qcls(ty)
            return Val(str(wrap_int(as_int(v), cls)), cls, ty)
        raise Refused("constant of type %s" % (ty,))

    def opnd(self, op, want=None):
        """Value of an operand. want is the expected QBE class (checked)."""
        v = self._opnd(op)
        if want is not None and v.cls != want:
            raise Refused("operand class %s where %s is expected: %s" % (v.cls, want, form_text(op)))
        return v

    def _opnd(self, op):
        if isinstance(op, str) and not isinstance(op, Str):
            if REG_RE.match(op):
                return self.reg_val(int(op[1:]))
            raise BadIR("unknown operand %s" % op)
        if isinstance(op, Sym):
            sig, name = op
            if sig == "$":
                return self.slot_val(name)
            if sig == "@":
                if name in self.mod.thread:
                    # Thread-local object: its address is the thread pointer plus the object's TLS offset. A definition
                    # in this module uses the local-exec model (`thread $x`); a declaration uses initial-exec through
                    # the GOT (`extern thread $x`), so the object may live in another object file or in a shared
                    # library. The address goes through a temporary so that it is a plain `l` value wherever it is used.
                    t = self.tmp()
                    self.emit("%s =l copy %s $%s" % (t, "extern thread" if self.mod.thread[name] == "ext" else "thread", qsym(name)))
                    return Val(t, "l", ("ptr", self.mod.globals.get(name)))
                return Val("$" + qsym(name), "l", ("ptr", self.mod.globals.get(name)))
            if sig == "&":
                # A weak reference goes through the GOT (`extern`), so that an absent definition reads as null in a PIE too.
                if name in self.mod.weakrefs:
                    return Val("extern $" + qsym(name), "l", ("ptr", ("fn",)))
                if name in self.mod.funcs:
                    return Val("$" + qsym(name), "l", ("ptr", ("fn",)))
                # The address of a function defined elsewhere: loaded from a local pointer cell (see the
                # mruby port; a PIE link rejects a PC-relative reference to a shared-library function).
                cell = "pathb_got." + qsym(name)
                self.mod.got[name] = cell
                t = self.tmp()
                self.emit("%s =l loadl $%s" % (t, cell))
                return Val(t, "l", ("ptr", ("fn",)))
        if head_of(op) == "const":
            return self.const(op)
        if head_of(op) == "null":
            ty = parse_type(op[1])
            return Val("0", "l", ty)
        if head_of(op) == "unsupported":
            raise Refused(form_text(op))
        raise BadIR("bad operand %s" % form_text(op))

    def ival(self, v, cls):
        return v

    # ---- conversions
    def narrow(self, v, ty):
        """Normalize a w value to a 1- or 2-byte integer type (QBE has no narrow temporaries)."""
        if ty[0] == "int" and ty[1] in (1, 2) and not ty[3]:
            op = {(1, True): "extsb", (1, False): "extub", (2, True): "extsh", (2, False): "extuh"}[(ty[1], ty[2])]
            t = self.tmp()
            self.emit("%s =w %s %s" % (t, op, v.t))
            return Val(t, "w", ty)
        return Val(v.t, v.cls, ty)

    def int_conv(self, v, src, dst):
        """Integer or pointer conversion from the value v of type src to type dst (both integer or pointer)."""
        if dst[0] == "int" and dst[3]:  # bool: nonzero is true
            t = self.tmp()
            self.emit("%s =w cne%s %s, 0" % (t, v.cls, v.t))
            return Val(t, "w", dst)
        dcls = qcls(dst)
        if dcls == "w":
            if v.cls == "l":
                t = self.tmp()
                self.emit("%s =w copy %s" % (t, v.t))
                v = Val(t, "w", src)
            return self.narrow(Val(v.t, "w", dst), dst)
        # 8-byte destination
        if v.cls == "w":
            if src[0] == "int" and int_is_signed(src) and not src[3]:
                op = "extsw"
            else:
                op = "extuw"
            t = self.tmp()
            self.emit("%s =l %s %s" % (t, op, v.t))
            return Val(t, "l", dst)
        return Val(v.t, "l", dst)

    # ---- rvalues: returns a Val
    def rval(self, x, declared=None):
        h = head_of(x)
        if h is None or h in ("const", "null", "unsupported"):
            return self.opnd(x)
        fn = RVAL.get(h)
        if fn is None:
            raise Refused("rvalue (%s ...)" % h)
        return fn(self, x)

    def stmt(self, x):
        if not isinstance(x, list):
            raise BadIR("statement expected, got %s" % form_text(x))
        h = head_of(x)
        fn = STMT.get(h)
        if fn is None:
            if h == "unsupported":
                raise Refused("statement %s" % form_text(x))   # an IR gap marker: say which
            raise Refused("statement (%s ...)" % h)
        fn(self, x)

    def stmts(self, xs):
        for s in xs:
            self.stmt(s)


# -------- rvalue handlers (x is the form, x[0] the head)

def _arith_cls(ty, x):
    if not is_int(ty):
        raise Refused("%s on non-integer type %s" % (x[0], (ty,)))
    return qcls(ty)


def r_wbin(op):
    def f(fn, x):
        ty = parse_type(x[1])
        cls = _arith_cls(ty, x)
        a = fn.opnd(x[2], cls)
        b = fn.opnd(x[3], cls)
        t = fn.tmp()
        fn.emit("%s =%s %s %s, %s" % (t, cls, op, a.t, b.t))
        return fn.narrow(Val(t, cls, ty), ty)
    return f


def r_wneg(fn, x):
    ty = parse_type(x[1])
    cls = _arith_cls(ty, x)
    a = fn.opnd(x[2], cls)
    t = fn.tmp()
    fn.emit("%s =%s sub 0, %s" % (t, cls, a.t))
    return fn.narrow(Val(t, cls, ty), ty)


def _check_signed(ty, x):
    if not int_is_signed(ty):
        raise Refused("%s on unsigned type %s (the IR only emits checked forms for signed types)" % (x[0], (ty,)))


def r_cadd_like(op):
    """Checked signed add, sub or mul. The operation runs in 64 bits and the result must fit the type; a 64-bit
    add or sub is checked with the sign-bit identities. A 64-bit multiply is refused."""
    def f(fn, x):
        ty = parse_type(x[1])
        _check_signed(ty, x)
        cls = _arith_cls(ty, x)
        a = fn.opnd(x[2], cls)
        b = fn.opnd(x[3], cls)
        if ty_size(ty) == 8:
            if op == "mul":
                raise Refused("checked 64-bit signed multiply (cmul on %s)" % (ty,))
            r = fn.tmp()
            fn.emit("%s =l %s %s, %s" % (r, "add" if op == "add" else "sub", fn.ext64(a), fn.ext64(b)))
            if op == "add":
                x1, x2, x3 = fn.tmp(), fn.tmp(), fn.tmp()
                fn.emit("%s =l xor %s, %s" % (x1, fn.ext64(a), r))
                fn.emit("%s =l xor %s, %s" % (x2, fn.ext64(b), r))
                fn.emit("%s =l and %s, %s" % (x3, x1, x2))
            else:
                x1, x2, x3 = fn.tmp(), fn.tmp(), fn.tmp()
                fn.emit("%s =l xor %s, %s" % (x1, fn.ext64(a), fn.ext64(b)))
                fn.emit("%s =l xor %s, %s" % (x2, fn.ext64(a), r))
                fn.emit("%s =l and %s, %s" % (x3, x1, x2))
            c = fn.tmp()
            fn.emit("%s =w csltl %s, 0" % (c, x3))
            fn.trap_if(c)
            return Val(r, "l", ty)
        # 1-, 2- and 4-byte types: 64-bit result, then it must survive truncation to the type
        r = fn.tmp()
        fn.emit("%s =l %s %s, %s" % (r, {"add": "add", "sub": "sub", "mul": "mul"}[op], fn.ext64(a), fn.ext64(b)))
        return fn.fits(r, ty)
    return f


def _ext64(self, v):
    """A w value as an l value, sign-extended (the operands of checked operations are signed)."""
    if v.cls == "l":
        return v.t
    t = self.tmp()
    self.emit("%s =l extsw %s" % (t, v.t))
    return t


def _fits(self, r, ty):
    """Trap unless the 64-bit value r is representable in the integer type ty; return it as a value of ty."""
    t32 = self.tmp()
    self.emit("%s =w copy %s" % (t32, r))
    tn = self.tmp()
    op = {1: "extsb", 2: "extsh", 4: None}[ty[1]]
    if op is None:
        tn = t32
    else:
        self.emit("%s =w %s %s" % (tn, op, t32))
    back = self.tmp()
    self.emit("%s =l extsw %s" % (back, tn))
    c = self.tmp()
    self.emit("%s =w ceql %s, %s" % (c, back, r))
    self.trap_unless(c)
    return Val(tn, "w", ty)


Fn.ext64 = _ext64
Fn.fits = _fits


def r_divrem(op):
    def f(fn, x):
        ty = parse_type(x[1])
        cls = _arith_cls(ty, x)
        a = fn.opnd(x[2], cls)
        b = fn.opnd(x[3], cls)
        c = fn.tmp()
        fn.emit("%s =w ceq%s %s, 0" % (c, cls, b.t))
        fn.trap_if(c)
        if int_is_signed(ty):
            lo, _ = int_range(ty)
            c2, c3, c4 = fn.tmp(), fn.tmp(), fn.tmp()
            fn.emit("%s =w ceq%s %s, %d" % (c2, cls, a.t, lo))
            fn.emit("%s =w ceq%s %s, -1" % (c3, cls, b.t))
            fn.emit("%s =w and %s, %s" % (c4, c2, c3))
            fn.trap_if(c4)
            qop = "div" if op == "div" else "rem"
        else:
            qop = "udiv" if op == "div" else "urem"
        t = fn.tmp()
        fn.emit("%s =%s %s %s, %s" % (t, cls, qop, a.t, b.t))
        return fn.narrow(Val(t, cls, ty), ty)
    return f


def r_shift(left):
    def f(fn, x):
        ty = parse_type(x[1])
        cls = _arith_cls(ty, x)
        a = fn.opnd(x[2], cls)
        b = fn.opnd(x[3])
        width = ty[1] * 8
        bcls = b.cls
        # Trap unless 0 <= count < width. An unsigned compare also rejects negative counts.
        c = fn.tmp()
        fn.emit("%s =w cult%s %s, %d" % (c, bcls, b.t, width))
        fn.trap_unless(c)
        if left:
            op = "shl"
        else:
            op = "sar" if int_is_signed(ty) else "shr"
        t = fn.tmp()
        fn.emit("%s =%s %s %s, %s" % (t, cls, op, a.t, b.t))
        return fn.narrow(Val(t, cls, ty), ty) if left else Val(t, cls, ty)
    return f


def r_cneg(fn, x):
    ty = parse_type(x[1])
    _check_signed(ty, x)
    cls = _arith_cls(ty, x)
    a = fn.opnd(x[2], cls)
    lo, _ = int_range(ty)
    c = fn.tmp()
    fn.emit("%s =w ceq%s %s, %d" % (c, cls, a.t, lo))
    fn.trap_if(c)
    t = fn.tmp()
    fn.emit("%s =%s sub 0, %s" % (t, cls, a.t))
    return fn.narrow(Val(t, cls, ty), ty)


def r_fbin(op):
    def f(fn, x):
        ty = parse_type(x[1])
        if ty[0] != "float":
            raise Refused("%s on non-float type" % x[0])
        cls = qcls(ty)
        a = fn.opnd(x[2], cls)
        b = fn.opnd(x[3], cls)
        t = fn.tmp()
        fn.emit("%s =%s %s %s, %s" % (t, cls, op, a.t, b.t))
        return Val(t, cls, ty)
    return f


def r_fneg(fn, x):
    ty = parse_type(x[1])
    if ty[0] != "float":
        raise Refused("fneg on non-float type")
    cls = qcls(ty)
    a = fn.opnd(x[2], cls)
    t = fn.tmp()
    fn.emit("%s =%s neg %s" % (t, cls, a.t))
    return Val(t, cls, ty)


def r_bitop(op):
    def f(fn, x):
        ty = parse_type(x[1])
        if not (is_int(ty) or is_bool(ty)):
            raise Refused("%s on type %s" % (x[0], (ty,)))
        cls = qcls(ty)
        a = fn.opnd(x[2], cls)
        b = fn.opnd(x[3], cls)
        t = fn.tmp()
        fn.emit("%s =%s %s %s, %s" % (t, cls, op, a.t, b.t))
        return fn.narrow(Val(t, cls, ty), ty)
    return f


def r_not(fn, x):
    ty = parse_type(x[1])
    cls = qcls(ty)
    a = fn.opnd(x[2], cls)
    t = fn.tmp()
    if is_bool(ty):
        fn.emit("%s =w xor %s, 1" % (t, a.t))
        return Val(t, "w", ty)
    if not is_int(ty):
        raise Refused("not on type %s" % (ty,))
    fn.emit("%s =%s xor %s, -1" % (t, cls, a.t))
    return fn.narrow(Val(t, cls, ty), ty)


def r_eqne(op):
    def f(fn, x):
        ty = parse_type(x[1])
        cls = qcls(ty)
        a = fn.opnd(x[2], cls)
        b = fn.opnd(x[3], cls)
        t = fn.tmp()
        fn.emit("%s =w c%s%s %s, %s" % (t, op, cls, a.t, b.t))
        return Val(t, "w", SCALARS["bool"])
    return f


def r_cmp(op):
    def f(fn, x):
        ty = parse_type(x[1])
        cls = qcls(ty)
        a = fn.opnd(x[2], cls)
        b = fn.opnd(x[3], cls)
        if op in CMP_INT:
            if ty[0] not in ("int", "ptr"):
                raise Refused("%s on non-integer type" % op)
            name = CMP_INT[op] + cls
        else:
            if ty[0] != "float":
                raise Refused("%s on non-float type" % op)
            name = CMP_FLT[op] + cls
        t = fn.tmp()
        fn.emit("%s =w %s %s, %s" % (t, name, a.t, b.t))
        return Val(t, "w", SCALARS["bool"])
    return f


def r_iconv(fn, x):
    dst = parse_type(x[1])
    v = fn.opnd(x[2])
    src = v.ty if v.ty is not None else ("int", 8, False, False)
    if dst[0] not in ("int", "ptr") or src[0] not in ("int", "ptr"):
        raise Refused("iconv between %s and %s" % (src, dst))
    return fn.int_conv(v, src, dst)


def r_p2i(fn, x):
    dst = parse_type(x[1])
    v = fn.opnd(x[2], "l")
    return fn.int_conv(v, ("ptr", None), dst)


def r_i2p(fn, x):
    dst = parse_type(x[1])
    v = fn.opnd(x[2])
    src = v.ty
    if src is None or src[0] != "int":
        raise Refused("i2p from %s" % (src,))
    return fn.int_conv(v, src, ("ptr", None))


def r_bitcast(fn, x):
    pt = parse_type(x[1])
    v = fn.opnd(x[2], "l")
    return Val(v.t, "l", pt)


def r_i2f(fn, x):
    dst = parse_type(x[1])
    if dst[0] != "float":
        raise Refused("i2f to non-float")
    v = fn.opnd(x[2])
    src = v.ty
    if src is None or src[0] != "int":
        raise Refused("i2f from %s" % (src,))
    signed = int_is_signed(src) and not src[3]
    op = {("w", True): "swtof", ("l", True): "sltof", ("w", False): "uwtof", ("l", False): "ultof"}[(v.cls, signed)]
    t = fn.tmp()
    fn.emit("%s =%s %s %s" % (t, qcls(dst), op, v.t))
    return Val(t, qcls(dst), dst)


def r_fconv(fn, x):
    dst = parse_type(x[1])
    v = fn.opnd(x[2])
    if dst[0] != "float" or v.ty is None or v.ty[0] != "float":
        raise Refused("fconv between non-float types")
    if qcls(dst) == v.cls:
        return Val(v.t, v.cls, dst)
    t = fn.tmp()
    if v.cls == "s":
        fn.emit("%s =d exts %s" % (t, v.t))
    else:
        fn.emit("%s =s truncd %s" % (t, v.t))
    return Val(t, qcls(dst), dst)


def r_cf2i(fn, x):
    """Float to integer with the trap of section 4: NaN or a value that does not fit the type. The test is done
    in double, where the bounds of each integer range are exact, so a float source is widened first."""
    dst = parse_type(x[1])
    if not is_int(dst) or is_bool(dst):
        raise Refused("cf2i to %s" % (dst,))
    v = fn.opnd(x[2])
    if v.ty is None or v.ty[0] != "float":
        raise Refused("cf2i from non-float")
    d = v.t
    if v.cls == "s":
        d = fn.tmp()
        fn.emit("%s =d exts %s" % (d, v.t))
    lo, hi = _cf2i_bounds(dst)
    c1, c2, c3 = fn.tmp(), fn.tmp(), fn.tmp()
    fn.emit("%s =w %s %s, %s" % (c1, lo[0], d, lo[1]))
    fn.emit("%s =w %s %s, %s" % (c2, hi[0], d, hi[1]))
    fn.emit("%s =w and %s, %s" % (c3, c1, c2))
    fn.trap_unless(c3)
    conv = ("dtosi" if int_is_signed(dst) else "dtoui")
    cls = "l" if dst[1] == 8 else "w"
    t = fn.tmp()
    fn.emit("%s =%s %s %s" % (t, cls, conv, d))
    return fn.narrow(Val(t, cls, dst), dst)


def _cf2i_bounds(ty):
    """Comparisons that a double d must satisfy to truncate into ty: (op, literal) for the lower and the upper bound.
    Lower: d > MIN-1 (32-bit and smaller), or d >= MIN for 64-bit (no double lies strictly between -2^63-1 and -2^63).
    Upper: d < MAX+1."""
    signed = int_is_signed(ty)
    bits = ty[1] * 8
    if signed:
        if bits == 64:
            lo = ("cged", repr(float(-(1 << 63))))
        else:
            lo = ("cgtd", repr(float(-(1 << (bits - 1)) - 1)))
        hi = ("cltd", repr(float(1 << (bits - 1))))
    else:
        lo = ("cgtd", "-1.0")
        hi = ("cltd", repr(float(1 << 64 if bits == 64 else 1 << bits)))
    return (lo[0], "d_" + lo[1]), (hi[0], "d_" + hi[1])


def r_offset(fn, x):
    a = fn.opnd(x[1], "l")
    n = as_int(x[2])
    t = fn.tmp()
    fn.emit("%s =l add %s, %d" % (t, a.t, n))
    return Val(t, "l", ("ptr", None))


def size_text(fn, s):
    """The SIZE of index and pdiff: a number, or a register (a VLA element type) as an l-class QBE operand."""
    if isinstance(s, str) and REG_RE.match(s):
        v = fn.opnd(s)
        if v.cls == "l":
            return v.t
        t = fn.tmp()
        fn.emit("%s =l extuw %s" % (t, v.t))
        return t
    return str(as_int(s))


def r_index(fn, x):
    base = fn.opnd(x[1], "l")
    idx = fn.opnd(x[2])
    size = size_text(fn, x[3])
    if idx.cls == "l":
        i64 = idx.t
    elif idx.ty is not None and idx.ty[0] == "int" and idx.ty[2] and not idx.ty[3]:
        i64 = fn.tmp()
        fn.emit("%s =l extsw %s" % (i64, idx.t))
    else:
        i64 = fn.tmp()
        fn.emit("%s =l extuw %s" % (i64, idx.t))
    m = fn.tmp()
    fn.emit("%s =l mul %s, %s" % (m, i64, size))
    t = fn.tmp()
    fn.emit("%s =l add %s, %s" % (t, base.t, m))
    return Val(t, "l", ("ptr", None))


def r_pdiff(fn, x):
    a = fn.opnd(x[1], "l")
    b = fn.opnd(x[2], "l")
    size = size_text(fn, x[3])
    if size == "0":
        raise Refused("pdiff with element size 0")
    d = fn.tmp()
    fn.emit("%s =l sub %s, %s" % (d, a.t, b.t))
    t = fn.tmp()
    fn.emit("%s =l div %s, %s" % (t, d, size))
    return Val(t, "l", ("int", 8, True, False))


# Volatile accesses. QBE has no volatile: its load optimisation forwards a store to a later load of the same
# address, merges equal loads, and drops a load whose result is unused. So a volatile access is never written as a
# QBE load or store. It is a call of a small helper function (defined in the module, so a call QBE cannot look into
# or inline) that does the one real access. A call is neither merged nor removed, calls keep their order, and the
# address operand of the call makes a stack slot escape, so a volatile local stays in memory (QBE promotes a slot
# only when loads and stores are its sole uses). Cost: one call per access.
def vhelper(mod, op, cls):
    kind = "ld" if op.startswith("load") else "st"
    suffix = op[4:] if kind == "ld" else op[5:]
    name = "__pathb_v%s_%s" % (kind, suffix)
    if name not in mod.vhelpers:
        if kind == "ld":
            mod.vhelpers[name] = ["function %s $%s(l %%p) {" % (cls, name), "@start", "\t%%v =%s %s %%p" % (cls, op), "\tret %v", "}", ""]
        else:
            mod.vhelpers[name] = ["function $%s(l %%p, %s %%v) {" % (name, cls), "@start", "\t%s %%v, %%p" % op, "\tret", "}", ""]
    return name


def r_load(fn, x):
    if len(x) != 3:
        raise BadIR("load form")
    vol = x[0] == "load.v"
    ty = parse_type(x[1])
    if is_agg(ty):
        raise Refused("load of an aggregate (aggregates are addresses)")
    addr = fn.opnd(x[2], "l")
    op, cls = _load_op(ty)
    t = fn.tmp()
    if vol:
        fn.emit("%s =%s call $%s(l %s)" % (t, cls, vhelper(fn.mod, op, cls), addr.t))
    else:
        fn.emit("%s =%s %s %s" % (t, cls, op, addr.t))
    if ty[0] == "int" and ty[3]:
        # A bool object may hold bytes other than 0 and 1 (memcpy, a union, a char alias). The IR and the rest of the
        # emitter assume a bool operand is 0 or 1 (! is xor 1, == compares bits), so a load normalises: nonzero is true.
        t0 = t
        t = fn.tmp()
        fn.emit("%s =w cnew %s, 0" % (t, t0))
    return Val(t, cls, ty)


def _load_op(ty):
    if ty[0] == "ptr" or ty[0] == "fn":
        return "loadl", "l"
    if ty[0] == "float":
        return ("loads", "s") if ty[1] == 4 else ("loadd", "d")
    if ty[0] == "int":
        size, signed, isbool = ty[1], ty[2], ty[3]
        if isbool:
            return "loadub", "w"
        return {(1, True): "loadsb", (1, False): "loadub", (2, True): "loadsh", (2, False): "loaduh",
                (4, True): "loadw", (4, False): "loadw", (8, True): "loadl", (8, False): "loadl"}[(size, signed)], \
            "w" if size <= 4 else "l"
    raise Refused("load of type %s" % (ty,))


def r_call(fn, x):
    # (call TYPE CALLEE [(variadic N)] ARG*): with (variadic N) the first N arguments match named parameters
    # and the QBE call gets "..." after them, so the callee's register-save prologue is set up (%al).
    ret = parse_type(x[1])
    if isinstance(x[2], Sym) and x[2][0] == "&":
        callee = Val("$" + qsym(x[2][1]), "l", ("ptr", ("fn",)))
    else:
        callee = fn.opnd(x[2])
    if isinstance(x[2], Sym) and x[2][1] in RETURNS_TWICE:
        fn.returns_twice = True
    rest = x[3:]
    nfixed = None
    if rest and head_of(rest[0]) == "variadic":
        nfixed = as_int(rest[0][1])
        rest = rest[1:]
        if nfixed > len(rest):
            raise BadIR("call: (variadic %d) with only %d arguments" % (nfixed, len(rest)))
    # An aggregate argument is (byval TYPE ADDR), an aggregate result (sret TYPE ADDR) first. With an (abi-type ...) for
    # the type they are passed the way the C calling convention says (QBE classifies its aggregate types); without one
    # (older IR) they are plain addresses.
    sret = None
    args = []
    for i, a in enumerate(rest):
        h = head_of(a)
        if h == "sret" or h == "byval":
            if len(a) != 3:
                raise BadIR("call: bad %s" % form_text(a))
            info = abi_of(fn.mod, a[1])
            if info is None:
                args.append((fn.opnd(a[2], "l"), None))
            else:
                if info.shape == "unsupported":
                    raise Refused("aggregate %s by value: %s" % (str(parse_type(a[1])[2]), info.why))
                if h == "sret":
                    if i != 0:
                        raise BadIR("call: sret is not the first argument")
                    sret = (info, fn.opnd(a[2], "l"))
                    args.append(None)
                else:
                    args.append((fn.opnd(a[2], "l"), info))
        else:
            args.append((fn.opnd(a), None))
    parts = []
    for i, a in enumerate(args):
        if i == nfixed:
            parts.append("...")
        if a is None:
            continue
        v, info = a
        if v.cls is None:
            raise Refused("call argument without a class")
        if info is None:
            parts.append("%s %s" % (v.cls, v.t))
        elif info.shape != "empty":
            parts.append("%s %s" % (info.tn, v.t))
    if nfixed is not None and nfixed == len(args):
        parts.append("...")
    target = callee.t
    if sret is not None:
        info, dest = sret
        if info.shape == "empty":
            fn.emit("call %s(%s)" % (target, ", ".join(parts)))
        else:
            t = fn.tmp()
            fn.emit("%s =%s call %s(%s)" % (t, info.tn, target, ", ".join(parts)))
            fn.emit("call $memmove(l %s, l %s, l %d)" % (dest.t, t, info.size))
        return None
    if ret == VOID:
        fn.emit("call %s(%s)" % (target, ", ".join(parts)))
        return None
    cls = qcls(ret)
    t = fn.tmp()
    fn.emit("%s =%s call %s(%s)" % (t, cls, target, ", ".join(parts)))
    return Val(t, cls, ret)


# ---- bit-fields. (bfload T UNIT ADDR BOFF WIDTH) reads the UNIT-byte storage unit at ADDR and extracts WIDTH bits from
# bit BOFF (little-endian bit numbering); the result has type T (sign-extended when T is signed, else zero-extended).
# (bfstore T UNIT ADDR BOFF WIDTH VALUE) replaces those bits of the unit with the low WIDTH bits of VALUE and leaves
# the others alone. The unit is accessed whole (a read-modify-write for the store).
BF_LOAD = {1: "loadub", 2: "loaduh", 4: "loadw", 8: "loadl"}
BF_STORE = {1: "storeb", 2: "storeh", 4: "storew", 8: "storel"}


def bf_args(x, nargs):
    if len(x) != nargs:
        raise BadIR("%s form" % x[0])
    unit = as_int(x[2])
    boff = as_int(x[4])
    width = as_int(x[5])
    if unit not in BF_LOAD:
        raise BadIR("%s: unit %d" % (x[0], unit))
    if width < 1 or boff < 0 or boff + width > unit * 8:
        raise BadIR("%s: bits %d+%d outside a %d-byte unit" % (x[0], boff, width, unit))
    return unit, boff, width


def bf_mask(width, cls):
    return wrap_int((1 << width) - 1, cls)


def r_bfload(fn, x):
    vol = x[0] == "bfload.v"
    unit, boff, width = bf_args(x, 6)
    ty = parse_type(x[1])
    if ty[0] != "int":
        raise Refused("bit-field of type %s" % (ty,))
    addr = fn.opnd(x[3], "l")
    ucls = "l" if unit == 8 else "w"
    ubits = 64 if unit == 8 else 32
    t = fn.tmp()
    if vol:
        # a volatile bit-field: the whole unit is read once, through the volatile helper (see vhelper)
        fn.emit("%s =%s call $%s(l %s)" % (t, ucls, vhelper(fn.mod, BF_LOAD[unit], ucls), addr.t))
    else:
        fn.emit("%s =%s %s %s" % (t, ucls, BF_LOAD[unit], addr.t))
    # Extraction is a shift pair (to the top of the register, then back down), never an `and` with a low mask: QBE's
    # width analysis (copy.c, "redundant and mask") drops such an `and` wrongly when the value comes round a loop through
    # memory (a phi it has visited and failed on is taken as narrow), which a do { } while (0) in a macro is enough
    # to produce. Shifts are never removed that way.
    if ubits - boff - width > 0:
        t2 = fn.tmp()
        fn.emit("%s =%s shl %s, %d" % (t2, ucls, t, ubits - boff - width))
        t = t2
    if ubits - width > 0:
        t2 = fn.tmp()
        fn.emit("%s =%s %s %s, %d" % (t2, ucls, "sar" if int_is_signed(ty) and not ty[3] else "shr", t, ubits - width))
        t = t2
    tcls = qcls(ty)
    if tcls != ucls:
        t2 = fn.tmp()
        if tcls == "l":
            fn.emit("%s =l %s %s" % (t2, "extsw" if int_is_signed(ty) and not ty[3] else "extuw", t))
        else:
            fn.emit("%s =w copy %s" % (t2, t))
        t = t2
    return Val(t, tcls, ty)


RVAL = {
    "vaarg": r_vaarg,
    "load": r_load,
    "load.v": r_load,
    "wadd": r_wbin("add"), "wsub": r_wbin("sub"), "wmul": r_wbin("mul"),
    "wneg": r_wneg,
    "cadd": r_cadd_like("add"), "csub": r_cadd_like("sub"), "cmul": r_cadd_like("mul"),
    "cneg": r_cneg,
    "cdiv": r_divrem("div"), "crem": r_divrem("rem"),
    "cshl": r_shift(True), "cshr": r_shift(False),
    "fadd": r_fbin("add"), "fsub": r_fbin("sub"), "fmul": r_fbin("mul"), "fdiv": r_fbin("div"),
    "fneg": r_fneg,
    "and": r_bitop("and"), "or": r_bitop("or"), "xor": r_bitop("xor"),
    "not": r_not,
    "eq": r_eqne("eq"), "ne": r_eqne("ne"),
    "lt.s": r_cmp("lt.s"), "le.s": r_cmp("le.s"), "lt.u": r_cmp("lt.u"), "le.u": r_cmp("le.u"),
    "lt.f": r_cmp("lt.f"), "le.f": r_cmp("le.f"),
    "iconv": r_iconv, "p2i": r_p2i, "i2p": r_i2p, "bitcast": r_bitcast,
    "i2f": r_i2f, "u2f": r_i2f, "fconv": r_fconv, "cf2i": r_cf2i,
    "offset": r_offset, "index": r_index, "pdiff": r_pdiff,
    "bfload": r_bfload, "bfload.v": r_bfload,
    "call": r_call,
}


# -------- statement handlers

def s_block(fn, x):
    fn.stmts(x[1:])


def s_let(fn, x):
    if len(x) != 4:
        raise BadIR("let form")
    n = int(x[1][1:]) if REG_RE.match(x[1]) else None
    if n is None:
        raise BadIR("let without a register")
    ty = parse_type(x[2])
    if is_agg(ty):
        raise Refused("register of aggregate type")
    fn.declare_reg(n, ty)
    v = fn.rval(x[3], ty)
    if v is None:
        raise BadIR("void value assigned to a register")
    if v.cls != fn.regs[n][1]:
        raise Refused("let %%%d: value class %s, register class %s" % (n, v.cls, fn.regs[n][1]))
    fn.set_reg(n, v)


def s_set(fn, x):
    n = int(x[1][1:])
    v = fn.opnd(x[2])
    fn.set_reg(n, v)


def s_store(fn, x):
    vol = x[0] == "store.v"
    ty = parse_type(x[1])
    if is_agg(ty):
        raise Refused("store of an aggregate type")
    addr = fn.opnd(x[2], "l")
    val = fn.opnd(x[3])
    if ty[0] == "ptr" or ty[0] == "fn" or (ty[0] == "int" and ty[1] == 8):
        op, cls = "storel", "l"
    elif ty[0] == "float":
        op, cls = ("stores", "s") if ty[1] == 4 else ("stored", "d")
    elif ty[0] == "int":
        op, cls = {1: "storeb", 2: "storeh", 4: "storew"}[ty[1]], "w"
    else:
        raise Refused("store of type %s" % (ty,))
    if val.cls != cls:
        raise Refused("store class mismatch: value %s, store %s" % (val.cls, cls))
    if vol:
        fn.emit("call $%s(l %s, %s %s)" % (vhelper(fn.mod, op, cls), addr.t, cls, val.t))
    else:
        fn.emit("%s %s, %s" % (op, val.t, addr.t))


def s_bfstore(fn, x):
    vol = x[0] == "bfstore.v"
    unit, boff, width = bf_args(x, 7)
    ty = parse_type(x[1])
    if ty[0] != "int":
        raise Refused("bit-field of type %s" % (ty,))
    addr = fn.opnd(x[3], "l")
    val = fn.opnd(x[6])
    ucls = "l" if unit == 8 else "w"
    ubits = 64 if unit == 8 else 32
    if val.cls != qcls(ty):
        raise Refused("bit-field store of a value of class %s" % val.cls)
    v = val.t
    if val.cls != ucls:
        t2 = fn.tmp()
        fn.emit(("%s =l extuw %s" if ucls == "l" else "%s =w copy %s") % (t2, v))
        v = t2
    old = fn.tmp()
    if vol:
        fn.emit("%s =%s call $%s(l %s)" % (old, ucls, vhelper(fn.mod, BF_LOAD[unit], ucls), addr.t))
    else:
        fn.emit("%s =%s %s %s" % (old, ucls, BF_LOAD[unit], addr.t))
    # The value's low WIDTH bits, moved to bit BOFF: a shift pair again (see r_bfload), no `and` with a low mask.
    if width < ubits:
        t2 = fn.tmp()
        fn.emit("%s =%s shl %s, %d" % (t2, ucls, v, ubits - width))
        v = t2
        if ubits - width - boff > 0:
            t2 = fn.tmp()
            fn.emit("%s =%s shr %s, %d" % (t2, ucls, v, ubits - width - boff))
            v = t2
    clear = ((1 << ubits) - 1) ^ (((1 << width) - 1) << boff)
    nw = v
    if clear != 0:
        keep = fn.tmp()
        if boff + width == ubits:
            # the field is the top of the unit, so the bits to keep are a low mask: shifts again
            fn.emit("%s =%s shl %s, %d" % (keep, ucls, old, ubits - boff))
            k2 = fn.tmp()
            fn.emit("%s =%s shr %s, %d" % (k2, ucls, keep, ubits - boff))
            keep = k2
        else:
            fn.emit("%s =%s and %s, %d" % (keep, ucls, old, wrap_int(clear, ucls)))
        nw = fn.tmp()
        fn.emit("%s =%s or %s, %s" % (nw, ucls, keep, v))
    if vol:
        fn.emit("call $%s(l %s, %s %s)" % (vhelper(fn.mod, BF_STORE[unit], ucls), addr.t, ucls, nw))
    else:
        fn.emit("%s %s, %s" % (BF_STORE[unit], nw, addr.t))


def s_vlaalloc(fn, x):
    """(vlaalloc $"slot" SIZE): the storage of a variable-length array. The slot receives the address of SIZE bytes of
    dynamic stack (QBE: alloc16 outside @start, released when the function returns). QBE cannot give the space back
    at the end of a block, so each statement keeps its capacity in a hidden slot (zero at function entry): the
    storage is allocated again only when SIZE exceeds it, and then for max(SIZE, 2 * capacity) bytes. Executing the
    statement again (a loop body, a backward goto) ends the previous array's lifetime, so its storage is reused, and
    the stack a function uses stays within a constant factor of its largest array."""
    if len(x) != 3:
        raise BadIR("vlaalloc form")
    slot = fn.opnd(x[1], "l")
    sz = fn.opnd(x[2])
    if sz.ty is None or sz.ty[0] != "int":
        raise Refused("vlaalloc size of type %s" % (sz.ty,))
    size = sz.t
    if sz.cls != "l":
        size = fn.tmp()
        fn.emit("%s =l extuw %s" % (size, sz.t))
    capq = "%%vc%d" % fn.nvla
    fn.nvla += 1
    fn.allocs.append("\t%s =l alloc8 8" % capq)
    fn.inits.append("\tstorel 0, %s" % capq)
    cap = fn.tmp()
    fn.emit("%s =l loadl %s" % (cap, capq))
    need = fn.tmp()
    fn.emit("%s =w cultl %s, %s" % (need, cap, size))
    grow = fn.newlab()
    fix = fn.newlab()
    alloc = fn.newlab()
    done = fn.newlab()
    fn.jnz(need, grow, done)
    fn.label(grow)
    dbl = fn.tmp()
    fn.emit("%s =l add %s, %s" % (dbl, cap, cap))
    fn.emit("storel %s, %s" % (dbl, capq))
    lt = fn.tmp()
    fn.emit("%s =w cultl %s, %s" % (lt, dbl, size))
    fn.jnz(lt, fix, alloc)
    fn.label(fix)
    fn.emit("storel %s, %s" % (size, capq))
    fn.label(alloc)
    n = fn.tmp()
    fn.emit("%s =l loadl %s" % (n, capq))
    p = fn.tmp()
    fn.emit("%s =l alloc16 %s" % (p, n))
    fn.emit("storel %s, %s" % (p, slot.t))
    fn.label(done)


def s_zero_fill(fn, x):
    # (zero-fill BYTES DST): clear an aggregate object (the part of a constant initializer that names no element).
    n = as_int(x[1])
    dst = fn.opnd(x[2], "l")
    if n == 0:
        return
    fn.emit("call $memset(l %s, w 0, l %d)" % (dst.t, n))


def s_vastart(fn, x):
    # (vastart ADDR): start the va_list at ADDR (the enclosing function must have an (ellipsis) parameter).
    if len(x) != 2:
        raise BadIR("vastart form")
    ap = fn.opnd(x[1], "l")
    fn.emit("vastart %s" % ap.t)


def r_vaarg(fn, x):
    # (vaarg TYPE ADDR): the next variadic argument of the va_list at ADDR. QBE's vaarg takes w, l, s and d.
    if len(x) != 3:
        raise BadIR("vaarg form")
    ty = parse_type(x[1])
    if is_agg(ty) or ty[0] == "fn":
        raise Refused("vaarg of type %s" % (ty,))
    cls = qcls(ty)
    ap = fn.opnd(x[2], "l")
    t = fn.tmp()
    fn.emit("%s =%s vaarg %s" % (t, cls, ap.t))
    return Val(t, cls, ty)


def s_copy(fn, x):
    n = as_int(x[1])
    dst = fn.opnd(x[2], "l")
    src = fn.opnd(x[3], "l")
    if n == 0:
        return
    fn.emit("call $memmove(l %s, l %s, l %d)" % (dst.t, src.t, n))


def s_eval(fn, x):
    e = x[1]
    if head_of(e) == "call":
        r_call(fn, e)
        return
    fn.rval(e)


def s_bounds(fn, x):
    idx = fn.opnd(x[1])
    n = as_int(x[2])
    if idx.ty is None or idx.ty[0] != "int":
        raise Refused("bounds on a non-integer index")
    cls = idx.cls
    c = fn.tmp()
    fn.emit("%s =w cult%s %s, %d" % (c, cls, idx.t, wrap_int(n, cls)))
    fn.trap_unless(c)


def s_nonnull(fn, x):
    p = fn.opnd(x[1], "l")
    if p.t.startswith("$"):
        return  # the address of an object or a function
    if p.t == "0":
        fn.jmp(fn.abort_label())
        return
    c = fn.tmp()
    fn.emit("%s =w cnel %s, 0" % (c, p.t))
    fn.trap_unless(c)


def s_if(fn, x):
    c = fn.opnd(x[1], "w")
    then = None
    els = None
    for part in x[2:]:
        h = head_of(part)
        if h == "then":
            then = part[1:]
        elif h == "else":
            els = part[1:]
        else:
            raise BadIR("if arm expected, got %s" % form_text(part))
    if then is None:
        raise BadIR("if without then")
    lt = fn.newlab()
    le = fn.newlab() if els is not None else None
    lend = fn.newlab()
    fn.jnz(c.t, lt, le if le is not None else lend)
    fn.label(lt)
    fn.stmts(then)
    fn.jmp(lend)
    if els is not None:
        fn.label(le)
        fn.stmts(els)
        fn.jmp(lend)
    fn.label(lend)


def s_loop(fn, x):
    body = step = None
    for part in x[1:]:
        h = head_of(part)
        if h == "body":
            body = part[1:]
        elif h == "step":
            step = part[1:]
        else:
            raise BadIR("loop part expected, got %s" % form_text(part))
    if body is None or step is None:
        raise BadIR("loop without body or step")
    head = fn.newlab()
    lstep = fn.newlab()
    lexit = fn.newlab()
    fn.label(head)
    fn.breaks.append(lexit)  # a do-while test in step may break too, so the target covers body and step
    fn.conts.append(lstep)
    fn.stmts(body)
    fn.conts.pop()  # (continue) is not allowed in step
    fn.label(lstep)
    fn.stmts(step)
    fn.breaks.pop()
    fn.jmp(head)
    fn.label(lexit)


def _switch_markers(xs, out):
    """Case and default markers in the switch body, in order. Markers may sit in nested blocks only."""
    for s in xs:
        h = head_of(s)
        if h == "block":
            _switch_markers(s[1:], out)
        elif h in ("case", "default"):
            out.append(s)
    return out


def s_switch(fn, x):
    v = fn.opnd(x[1])
    if v.cls not in ("w", "l"):
        raise Refused("switch on a non-integer value")
    if len(x) != 3 or head_of(x[2]) != "body":
        raise BadIR("switch form")
    markers = _switch_markers(x[2][1:], [])
    lexit = fn.newlab()
    ldefault = None
    cases = []
    seen = set()
    for m in markers:
        lab = fn.newlab()
        fn.case_labels[id(m)] = lab
        if head_of(m) == "default":
            if ldefault is not None:
                raise BadIR("two default labels")
            ldefault = lab
        else:
            cv = fn.const(m[1])
            key = int(cv.t)
            if key in seen:
                raise BadIR("duplicate case value %d" % key)
            seen.add(key)
            cases.append((cv, lab))
    # Dispatch: one compare per case, in order; then the default (or the exit).
    for cv, lab in cases:
        c = fn.tmp()
        fn.emit("%s =w ceq%s %s, %s" % (c, v.cls, v.t, cv.t))
        nxt = fn.newlab()
        fn.jnz(c, lab, nxt)
        fn.label(nxt)
    fn.jmp(ldefault if ldefault is not None else lexit)
    fn.breaks.append(lexit)
    fn.stmts(x[2][1:])
    fn.breaks.pop()
    fn.label(lexit)


def s_case(fn, x):
    lab = fn.case_labels.get(id(x))
    if lab is None:
        raise Refused("case marker outside a switch body")
    fn.label(lab)


def s_default(fn, x):
    lab = fn.case_labels.get(id(x))
    if lab is None:
        raise Refused("default marker outside a switch body")
    fn.label(lab)


def s_break(fn, x):
    if not fn.breaks:
        raise BadIR("break outside a loop or switch")
    fn.jmp(fn.breaks[-1])


def s_continue(fn, x):
    if not fn.conts:
        raise BadIR("continue outside a loop body")
    fn.jmp(fn.conts[-1])


def s_goto(fn, x):
    fn.jmp(fn.lab_for(str(x[1])))


def s_label(fn, x):
    fn.label(fn.lab_for(str(x[1])))


def s_return(fn, x):
    if fn.ret_ty == VOID:
        if len(x) != 1:
            raise BadIR("return with a value in a void function")
        fn.ret()
        return
    if len(x) != 2:
        raise Refused("return without a value in a non-void function")
    v = fn.opnd(x[1], qcls(fn.ret_ty))
    fn.ret(v.t)


def s_unreachable(fn, x):
    fn.jmp(fn.abort_label())


STMT = {
    "block": s_block, "let": s_let, "set": s_set,
    "store": s_store, "store.v": s_store,
    "bfstore": s_bfstore, "bfstore.v": s_bfstore, "vlaalloc": s_vlaalloc,
    "copy": s_copy, "zero-fill": s_zero_fill, "vastart": s_vastart, "eval": s_eval, "bounds": s_bounds, "nonnull": s_nonnull,
    "if": s_if, "loop": s_loop, "switch": s_switch,
    "case": s_case, "default": s_default, "break": s_break, "continue": s_continue,
    "goto": s_goto, "label": s_label, "return": s_return, "unreachable": s_unreachable,
}


# ------------------------------------------------------------------ module and functions

def emit_data_items(mod, name, size, items):
    """Items of a static initializer, as QBE data items; gaps are zero bytes."""
    pieces = []
    pos = 0
    for off, nbytes, text in sorted(items, key=lambda t: t[0]):
        if off < pos:
            raise BadIR("initializer items overlap at offset %d in %s" % (off, name))
        if off > pos:
            pieces.append("z %d" % (off - pos))
        pieces.append(text)
        pos = off + nbytes
    if pos > size:
        raise BadIR("initializer of %s runs past its size" % name)
    if size > pos:
        pieces.append("z %d" % (size - pos))
    return pieces or ["z 0"]


def item_scalar(val_text, ty):
    """A scalar item of IR type ty with the value text val_text. Returns (bytes, QBE data item)."""
    if ty[0] == "float":
        cls, lit = data_float(float(str(val_text)), ty[1])
        return ty[1], "%s %s" % (cls, lit)
    if ty[0] in ("int", "ptr", "fn"):
        size = ty_size(ty)
        v = wrap_int(as_int(val_text), "w" if size <= 4 else "l")
        letter = {1: "b", 2: "h", 4: "w", 8: "l"}[size]
        return size, "%s %d" % (letter, v)
    raise Refused("scalar item of type %s" % (ty,))


def global_items(mod, name, items_form):
    """Translate (init ITEM*) into (offset, bytes, text) triples."""
    out = []
    bits = {}   # byte offset -> value: the bits that (bitfield OFF UNIT BOFF WIDTH TYPE (const TYPE V)) items put in that byte
    for it in items_form[1:]:
        h = head_of(it)
        if h == "bitfield":
            if len(it) != 7:
                raise BadIR("bitfield item form")
            off = as_int(it[1])
            unit = as_int(it[2])
            boff = as_int(it[3])
            width = as_int(it[4])
            val = it[6]
            if unit not in BF_LOAD:
                raise BadIR("bitfield item: unit %d" % unit)
            if width < 1 or boff < 0 or boff + width > unit * 8:
                raise BadIR("bitfield item: bits %d+%d outside a %d-byte unit" % (boff, width, unit))
            if head_of(val) != "const":
                raise Refused("bitfield item operand %s" % form_text(val))
            # Fields are placed by absolute bit position; storage units of different fields may overlap, so the bits are
            # collected per byte (a bit-field never shares a byte with another kind of member).
            v = as_int(val[2]) & ((1 << width) - 1)
            for i in range(width):
                pos = off * 8 + boff + i
                bits[pos // 8] = bits.get(pos // 8, 0) | (((v >> i) & 1) << (pos % 8))
        elif h == "scalar":
            off = as_int(it[1])
            ty = parse_type(it[2])
            val = it[3]
            if head_of(val) == "null":
                size = ty_size(ty)
                out.append((off, size, "%s 0" % {8: "l", 4: "w", 2: "h", 1: "b"}[size]))
                continue
            if head_of(val) != "const":
                raise Refused("scalar item operand %s" % form_text(val))
            size, text = item_scalar(val[2], ty)
            out.append((off, size, text))
        elif h == "addr":
            off = as_int(it[1])
            target = it[3]
            add = as_int(it[4])
            if not isinstance(target, Sym):
                raise Refused("address item target %s" % form_text(target))
            if target[0] == "@" and target[1] in mod.thread:
                raise Refused("address of the thread-local object %s in a static initializer" % target[1])
            sym = "$" + qsym(target[1])
            if add == 0:
                text = "l %s" % sym
            elif add > 0:
                text = "l %s + %d" % (sym, add)
            else:
                text = "l %s - %d" % (sym, -add)
            out.append((off, 8, text))
        elif h == "bytes":
            off = as_int(it[1])
            n = as_int(it[2])
            src = it[3]
            if not isinstance(src, Sym) or src[0] != "@" or src[1] not in mod.strings:
                raise Refused("bytes item from %s" % form_text(src))
            data = mod.strings[src[1]]
            if len(data) != n:
                raise BadIR("bytes item of %d bytes from a %d-byte string" % (n, len(data)))
            for i, ch in enumerate(data):
                out.append((off + i, 1, "b %d" % ord(ch)))
        elif h == "zero":
            off = as_int(it[1])
            n = as_int(it[2])
            if n:
                out.append((off, n, "z %d" % n))
        elif h == "unsupported":
            raise Refused(form_text(it))
        else:
            raise BadIR("unknown initializer item %s" % form_text(it))
    for off in sorted(bits):
        out.append((off, 1, "b %d" % bits[off]))
    return out


# QBE has no weak linkage. A COMDAT definition (IR marker (weak)) is exported, and a comment line in the IL names it;
# `pathb-qbe-emit.py --append-weak IL ASM` turns those comments into `.weak` directives at the end of the assembly
# that QBE produced (the same trick as scripts/weak-symbols.py, but driven by the IR instead of EDG's __weak__ text).
WEAK_MARK = "# pathb-weak "


def append_weak(il_path, asm_path):
    names = []
    for line in open(il_path, encoding="latin-1"):
        if line.startswith(WEAK_MARK):
            names.append(line[len(WEAK_MARK):].strip())
    if names:
        with open(asm_path, "a") as f:
            f.write("\n" + "".join(".weak %s\n" % n for n in names))
    return 0


def emit_global(mod, g):
    # (global "NAME" TYPE BYTES ALIGN [(static)] INIT)
    if len(g) < 6:
        raise BadIR("global form too short: %s" % form_text(g))
    name = str(g[1])
    size = as_int(g[3])
    align = as_int(g[4])
    rest = g[5:]
    static = False
    weak = False
    if rest and head_of(rest[0]) == "static":
        static = True
        rest = rest[1:]
    elif rest and head_of(rest[0]) == "weak":
        weak = True
        rest = rest[1:]
    thread = False
    if rest and head_of(rest[0]) == "thread":
        thread = True
        rest = rest[1:]
    if len(rest) != 1:
        raise BadIR("global %s: expected one INIT" % name)
    init = rest[0]
    h = head_of(init)
    if h == "extern":
        return
    if h == "unsupported":
        raise Refused("global %s: %s" % (name, form_text(init)))
    if h != "init":
        raise BadIR("global %s: unknown INIT %s" % (name, form_text(init)))
    if align not in (1, 2, 4, 8, 16):
        raise BadIR("global %s: alignment %d" % (name, align))
    items = global_items(mod, name, init)
    pieces = emit_data_items(mod, name, size, items)
    linkage = ("thread " if thread else "") + ("" if static else "export ")
    if weak:
        mod.out.append(WEAK_MARK + qsym(name))
    mod.out.append("%sdata $%s = align %d { %s }" % (linkage, qsym(name), align, ", ".join(pieces)))


def emit_string(mod, d):
    # (data "NAME" TYPE (string "..."))
    name = str(d[1])
    ty = parse_type(d[2])
    if ty[0] != "array":
        raise BadIR("data %s is not an array" % name)
    text = d[3]
    if head_of(text) != "string":
        raise Refused("data %s: %s" % (name, form_text(text)))
    raw = str(text[1])
    # The string is bytes; a wide string (wchar_t, char16_t, char32_t) is an array of 2 or 4 byte integers.
    total = ty[1] * (ty[2][1] if ty[2][0] == "int" else 1)
    if len(raw) > total:
        raise BadIR("string data %s longer than its array" % name)
    raw = raw + "\0" * (total - len(raw))
    mod.strings[name] = raw
    parts = ["b %d" % ord(c) for c in raw]
    mod.out.append("data $%s = { %s }" % (qsym(name), ", ".join(parts)) if parts else "data $%s = { z 0 }" % qsym(name))


def emit_function(mod, f):
    # (function "NAME" (ret TYPE|void) (params PARAM*) [(static)] SLOT* STMT*)
    name = str(f[1])
    ret_form = f[2]
    if head_of(ret_form) != "ret":
        raise BadIR("function %s: no (ret ...)" % name)
    ret = parse_type(ret_form[1])
    if is_agg(ret):
        raise BadIR("function %s returns an aggregate; it must use sret" % name)
    params_form = f[3]
    if head_of(params_form) != "params":
        raise BadIR("function %s: no (params ...)" % name)
    fn = Fn(mod, name, ret)
    static = False
    weak = False
    startup = []
    qparams = []
    param_stores = []
    body_forms = []
    for part in f[4:]:
        h = head_of(part)
        if h == "static":
            static = True
        elif h == "weak":
            weak = True
        elif h in ("constructor", "destructor"):
            # (constructor [PRIO]) / (destructor [PRIO]): the function runs before main / at exit
            if len(part) > 2:
                raise BadIR("function %s: bad %s" % (name, form_text(part)))
            prio = as_int(part[1]) if len(part) == 2 else 0
            if prio < 0 or prio > 65535:
                raise BadIR("function %s: bad priority in %s" % (name, form_text(part)))
            startup.append((".init_array" if h == "constructor" else ".fini_array", prio, qsym(name)))
        elif h == "slot":
            # (slot "NAME" TYPE BYTES ALIGN)
            if len(part) != 5:
                raise BadIR("slot form in %s is not (slot NAME TYPE BYTES ALIGN); rebuild the harness" % name)
            sname = str(part[1])
            sty = parse_type(part[2])
            if sty[0] == "array" and sty[1] is None:
                raise Refused("variable-length array type")
            ssize = as_int(part[3])
            salign = as_int(part[4])
            q = "%%s%d" % fn.nslot
            fn.nslot += 1
            a = 16 if salign >= 16 else 8 if salign >= 8 else 4
            fn.allocs.append("\t%s =l alloc%d %d" % (q, a, max(ssize, 1)))
            fn.slots[sname] = (q, sty)
        else:
            body_forms.append(part)
    # Parameters: each arrives in a QBE temporary %pI and is copied into its register slot.
    pi = 0
    sret_tn = None
    for p in params_form[1:]:
        h = head_of(p)
        if h == "sret":
            n = int(p[1][1:])
            info = abi_of(mod, p[2])
            fn.declare_reg(n, ("ptr", None))
            if info is None:
                qparams.append("l %%p%d" % pi)
                param_stores.append(("l", pi, n))
            else:
                if info.shape == "unsupported":
                    raise Refused("aggregate %s returned by value: %s" % (str(parse_type(p[2])[2]), info.why))
                # The C convention: no hidden parameter; the function fills a buffer of its own and returns its address.
                fn.allocs.append("\t%%sretbuf =l alloc%d %d" % (16 if info.align >= 16 else 8, max(info.size, 1)))
                fn.inits.append("\tstorel %%sretbuf, %%r%d" % n)
                if info.shape != "empty":
                    fn.sret_buf = "%sretbuf"
                    sret_tn = info.tn
        elif h == "param":
            n = int(p[1][1:])
            pty = p[3]
            if head_of(pty) == "byval":
                info = abi_of(mod, pty[1])
                fn.declare_reg(n, ("ptr", None))
                if info is None:
                    qparams.append("l %%p%d" % pi)
                    param_stores.append(("l", pi, n))
                else:
                    if info.shape == "unsupported":
                        raise Refused("aggregate %s passed by value: %s" % (str(parse_type(pty[1])[2]), info.why))
                    if info.shape == "empty":
                        fn.allocs.append("\t%%ebuf%d =l alloc8 8" % pi)
                        fn.inits.append("\tstorel %%ebuf%d, %%r%d" % (pi, n))
                    else:
                        qparams.append("%s %%p%d" % (info.tn, pi))
                        param_stores.append(("l", pi, n))
            else:
                ty = parse_type(pty)
                cls = qcls(ty)
                fn.declare_reg(n, ty)
                qparams.append("%s %%p%d" % (cls, pi))
                param_stores.append((cls, pi, n))
        elif h == "ellipsis":
            qparams.append("...")
        else:
            raise Refused("parameter form %s" % form_text(p))
        pi += 1
    # Parameter copies into their register slots, at the top of the start block.
    for cls, idx, n in param_stores:
        fn._put("%s %%p%d, %%r%d" % (MEM_STORE[cls], idx, n))
    fn.stmts(body_forms)
    if not fn.dead:
        if ret == VOID:
            fn.ret()
        else:
            fn.jmp(fn.abort_label())
    if fn.abort_used:
        fn.body.append("@abort")
        fn._put("call $abort()")
        fn._put("hlt")
    rc = "" if ret == VOID else qcls(ret) + " "
    if sret_tn is not None:
        rc = sret_tn + " "
    linkage = "" if static else "export "
    if weak:
        mod.out.append(WEAK_MARK + qsym(name))
    mod.out.append("%sfunction %s$%s(%s) {" % (linkage, rc, qsym(name), ", ".join(qparams)))
    mod.out.append("@start")
    mod.out.extend(fn.allocs)
    mod.out.extend(fn.inits)
    if fn.returns_twice:
        mod.out.extend(escape_slots(fn.allocs))
        mod.need_sink = True
    mod.out.extend(fn.body)
    mod.out.append("}")
    mod.out.append("")
    mod.startup.extend(startup)


def emit_startup_tables(mod):
    """A (constructor [PRIO]) function gets a pointer in .init_array, a (destructor [PRIO]) one in .fini_array
    (the dynamic loader runs .fini_array backwards). A priority P goes to the section .init_array.PPPPP (five
    decimal places, as GCC names it): the linker sorts those by name, before the plain section. Every entry is its
    own object, in the order of the functions in the IR."""
    for i, (sect, prio, sym) in enumerate(mod.startup):
        if prio != 0:
            sect += ".%05d" % prio
        mod.out.append('section "%s" "aw"' % sect)
        mod.out.append("data $pathb_startup%d = align 8 { l $%s }" % (i, sym))


LP64 = {"short": 2, "int": 4, "long": 8, "long_long": 8, "pointer": 8, "float": 4, "double": 8}


def check_layout(header):
    """The emitter's scalar sizes are LP64's. The module header carries the target's: (layout (int 4) ...).
    A target with other sizes is refused, not emitted with wrong sizes. An IR without (layout ...) is older
    than this check and is taken as LP64."""
    for part in header[2:]:
        if head_of(part) != "layout":
            continue
        for item in part[1:]:
            name, size = str(item[0]), as_int(item[1])
            if name in LP64 and LP64[name] != size:
                raise Refused("layout: %s is %d bytes, the emitter assumes LP64 (%d)" % (name, size, LP64[name]))


def _symbols(x, out):
    """Collect the names of the global symbols (@"name" and &"name") that the form x refers to."""
    if isinstance(x, Sym):
        if x[0] in "@&":
            out.add(x[1])
    elif isinstance(x, list):
        for y in x:
            _symbols(y, out)


def _is_startup(f):
    """A function that runs without being called: (constructor) or (destructor). It stays whatever refers to it."""
    return head_of(f) == "function" and any(head_of(p) in ("constructor", "destructor") for p in f[2:])


def _is_linked(f):
    """A function or global that other translation units can see: not (static), not (weak), and a definition."""
    h = head_of(f)
    for part in f[2:]:
        if head_of(part) in ("static", "weak", "extern"):
            return False
        if h == "global" and head_of(part) == "extern":
            return False
    return True


def prune(forms):
    """Reachability. The IR carries every routine EDG marks as needed, including inline and template code that
    nothing reaches. Keep the external definitions (they are the translation unit's interface) and what they refer
    to, transitively. A (weak) or (static) definition that nothing reaches is dropped: another translation unit that
    needs a weak definition has its own copy. A declaration ((extern) global) that nothing reaches is dropped too (a
    hosted program's headers declare many objects of types this emitter refuses). String data always stays."""
    defs = {}
    for f in forms[1:]:
        if head_of(f) in ("function", "global"):
            defs[str(f[1])] = f
    live = set()
    work = []
    for name, f in defs.items():
        if head_of(f) == "global" and any(head_of(p) == "extern" for p in f[2:]):
            continue  # a declaration emits nothing
        if _is_linked(f) or _is_startup(f):
            live.add(name)
            work.append(name)
    while work:
        refs = set()
        _symbols(defs[work.pop()], refs)
        for r in refs:
            if r in defs and r not in live:
                live.add(r)
                work.append(r)
    return [f for f in forms[1:] if head_of(f) not in ("function", "global") or str(f[1]) in live]


# The Itanium C++ ABI declares the thread_local initialization function `_ZTH<name>` of an `extern thread_local`
# variable as a weak reference: the wrapper `_ZTW<name>` calls it only when it exists (`if (&_ZTH<name>) _ZTH<name>()`).
# The IR has no weak declarations, so an undefined function with this prefix that the module refers to is taken as one.
def weak_refs(forms):
    defined = set(str(f[1]) for f in forms[1:] if head_of(f) == "function")
    refs = set()
    for f in forms[1:]:
        if head_of(f) == "function":
            _symbols(f, refs)
    return {n: True for n in sorted(refs) if n.startswith("_ZTH") and n not in defined}


def _mentions_long_double(x):
    """Does the form mention the type long_double (a bare atom, not a string constant)?"""
    if isinstance(x, list):
        return any(_mentions_long_double(y) for y in x)
    return type(x) is str and x == "long_double"


def stub_long_double(forms):
    """--long-double=trap: QBE has no 80-bit type, so a function that mentions long double cannot be emitted. Instead
    of refusing the module, such a function becomes a stub that aborts when it runs (its linkage and start-up markers
    stay), and a global of that type is dropped."""
    out = [forms[0]]
    for f in forms[1:]:
        h = head_of(f)
        if h == "function" and _mentions_long_double(f):
            keep = [p for p in f[2:] if head_of(p) in ("static", "weak", "constructor", "destructor")]
            out.append(["function", f[1], ["ret", "void"], ["params"]] + keep + [["unreachable"]])
        elif h == "global" and _mentions_long_double(f):
            continue
        else:
            out.append(f)
    return out


def emit_module(text, do_prune=True, ld_trap=False):
    forms = parse_forms(tokenize(text))
    if not forms or head_of(forms[0]) != "ir-module":
        raise BadIR("the input is not an (ir-module ...) IR text")
    check_layout(forms[0])
    if ld_trap:
        forms = stub_long_double(forms)
    mod = Module()
    all_forms = forms
    if do_prune:
        forms = [forms[0]] + prune(forms)
    mod.weakrefs = weak_refs(forms)
    for f in forms[1:]:
        if head_of(f) == "abi-type":
            declare_abi_type(mod, f)
    for f in all_forms[1:]:
        if head_of(f) == "function":
            mod.funcs.add(str(f[1]))
    for f in forms[1:]:   # the globals that stay: a dropped one (unreferenced) may have a type this emitter refuses
        if head_of(f) == "global":
            mod.globals[str(f[1])] = parse_type(f[2])
            if any(head_of(p) == "thread" for p in f[5:]):
                mod.thread[str(f[1])] = "ext" if any(head_of(p) == "extern" for p in f[5:]) else "def"
    # Strings first: a string data item may be referenced from a global initializer.
    for f in forms[1:]:
        if head_of(f) == "data":
            emit_string(mod, f)
    for f in forms[1:]:
        if head_of(f) == "global":
            emit_global(mod, f)
    for f in forms[1:]:
        if head_of(f) == "function":
            try:
                emit_function(mod, f)
            except Refused as e:
                raise Refused("%s [in %s]" % (e, str(f[1])))   # which function holds the unsupported node
        elif head_of(f) not in ("global", "data", "abi-type"):
            raise Refused("top-level form (%s ...)" % head_of(f))
    emit_startup_tables(mod)
    for name, cell in mod.got.items():
        mod.out.append("data $%s = align 8 { l $%s }" % (cell, qsym(name)))
    if mod.need_sink:
        mod.out.append('data $%s = align 8 { z 8 }' % SINK)
    for lines in mod.vhelpers.values():
        mod.out.extend(lines)
    for n in mod.weakrefs:
        mod.out.append(WEAK_MARK + qsym(n))
    return "# QBE IL generated from the nfcxx Path B IR by scripts/pathb-qbe-emit.py\n" + "\n".join(mod.out) + "\n"


def main(argv):
    args = argv[1:]
    if args and args[0] == "--append-weak":
        if len(args) != 3:
            sys.stderr.write("usage: pathb-qbe-emit.py --append-weak IL.ssa ASM.s\n")
            return 1
        return append_weak(args[1], args[2])
    do_prune = True
    ld_trap = False
    if args and args[0] == "--no-prune":
        do_prune = False
        args = args[1:]
    if args and args[0] == "--long-double=trap":
        ld_trap = True
        args = args[1:]
    if len(args) > 1:
        sys.stderr.write("usage: pathb-qbe-emit.py [--no-prune] [--long-double=trap] [FILE.ir | -]  |  --append-weak IL.ssa ASM.s\n")
        return 1
    src = sys.stdin.read() if not args or args[0] == "-" else open(args[0], encoding="latin-1").read()
    try:
        sys.stdout.write(emit_module(src, do_prune, ld_trap))
    except Refused as e:
        sys.stderr.write("refused: %s\n" % e)
        return 3
    except BadIR as e:
        sys.stderr.write("error: %s\n" % e)
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
