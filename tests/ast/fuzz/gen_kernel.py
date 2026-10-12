#!/usr/bin/env python3
"""Random numeric kernels for differential testing of the tier (tests/ast/fuzz_tier.sh).

usage: gen_kernel.py SEED [FUNCTIONS]

Prints a Lua program: FUNCTIONS (default 10) well-typed functions over integers, floats, booleans and "numbers" (variables,
parameters and results that are an integer in one place and a float in another; type n below) (arithmetic, bitwise
operators, comparisons, locals, if / while / repeat / numeric for / break / return, calls of earlier functions, some of them
recursive), each called with a number of argument tuples, some of the wrong type, through pcall; the results and the error
messages are printed. The tier compiles these functions, so the output has to be the same as a real Lua's.
"""
import random
import sys

seed = int(sys.argv[1]) if len(sys.argv) > 1 else 1
nfuncs = int(sys.argv[2]) if len(sys.argv) > 2 else 10
R = random.Random(seed)

INT_LITS = ['0', '1', '-1', '2', '3', '5', '7', '10', '16', '63', '64', '100', '255', '65535', '2147483647', '4294967296',
            '9223372036854775807', '(-9223372036854775807 - 1)', '(1 << 62)', '9007199254740993', '-7', '-100']
FLT_LITS = ['0.0', '1.0', '0.5', '-2.5', '3.14159', '1e10', '-1e-5', '2.0', '100.25', '9007199254740992.0', '1e15', '(1e308 * 10)',
            '(-1e308 * 10)', '0.1', '-0.0']


class Func:
    def __init__(self, name, params, ret, level):
        self.name = name
        self.params = params  # list of (name, type)
        self.ret = ret
        self.level = level  # a function calls only functions of a lower level, so the cost of a call is bounded
        self.self_ok = False


CUR_LEVEL = [0]
ALLOW_N = [True]  # off while the start of a loop is made: a NaN there meets a difference of the engine from Lua
BUDGET = [0]       # calls of other functions this function may still contain (the cost of a call is bounded this way)
SELF_BUDGET = [0]  # and of itself


funcs = []  # callable earlier functions
tmp_counter = [0]


def fresh(prefix):
    tmp_counter[0] += 1
    return '%s%d' % (prefix, tmp_counter[0])


def lit(t):
    if t == 'n':
        t = R.choice(['i', 'f'])
    if t == 'i':
        return R.choice(INT_LITS)
    if t == 'f':
        return R.choice(FLT_LITS)
    return R.choice(['true', 'false'])


# numeric and boolean upvalues of the chunk and globals: free variables of the kernels, changed between the calls
UPS = [('u1', 'i'), ('u2', 'f'), ('u3', 'b'), ('g1', 'i'), ('g2', 'f')]


def vars_of(env, t):
    r = [v for v, vt in env.items() if vt == t] + [v for v, vt in UPS if vt == t]
    if t in ('i', 'f') and ALLOW_N[0] and R.random() < 0.35:
        r += [v for v, vt in env.items() if vt == 'n']  # a number of either kind where one of a given kind is wanted
    return r


def gen_expr(env, t, depth, self_fn=None):
    """An expression of static type T (i, f, b, or n: an integer or a float, as it falls)."""
    if t == 'n':
        t = R.choice(['i', 'f', 'f'])
        if depth > 1 and R.random() < 0.3:
            vs = vars_of(env, 'n')
            if vs:
                return R.choice(vs)
    leaf = depth <= 0 or R.random() < 0.18
    if t == 'b':
        if leaf:
            vs = vars_of(env, 'b')
            if vs and R.random() < 0.6:
                return R.choice(vs)
            if R.random() < 0.5:
                return lit('b')
        k = R.random()
        if k < 0.45:
            lt = R.choice(['i', 'f'])
            rt = R.choice(['i', 'f'])
            op = R.choice(['<', '<=', '>', '>=', '==', '~='])
            return '(%s %s %s)' % (gen_expr(env, lt, depth - 1, self_fn), op, gen_expr(env, rt, depth - 1, self_fn))
        if k < 0.6:
            return '(not %s)' % gen_expr(env, 'b', depth - 1, self_fn)
        if k < 0.8:
            return '(%s %s %s)' % (gen_expr(env, 'b', depth - 1, self_fn), R.choice(['and', 'or']), gen_expr(env, 'b', depth - 1, self_fn))
        if k < 0.9:
            return '(%s == %s)' % (gen_expr(env, 'b', depth - 1, self_fn), gen_expr(env, 'b', depth - 1, self_fn))
        return call_expr(env, 'b', depth, self_fn) or lit('b')
    if leaf:
        vs = vars_of(env, t)
        if vs and R.random() < 0.65:
            return R.choice(vs)
        return lit(t)
    k = R.random()
    if t == 'i':
        if k < 0.30:
            op = R.choice(['+', '-', '*'])
            return '(%s %s %s)' % (gen_expr(env, 'i', depth - 1, self_fn), op, gen_expr(env, 'i', depth - 1, self_fn))
        if k < 0.42:
            op = R.choice(['//', '%'])
            d = gen_expr(env, 'i', depth - 1, self_fn)
            if R.random() < 0.5:
                d = R.choice(['3', '7', '-2', '10', '1', '-1'])
            return '(%s %s %s)' % (gen_expr(env, 'i', depth - 1, self_fn), op, d)
        if k < 0.60:
            op = R.choice(['&', '|', '~', '<<', '>>'])
            r = gen_expr(env, 'i', depth - 1, self_fn)
            if op in ('<<', '>>') and R.random() < 0.6:
                r = R.choice(['0', '1', '3', '31', '32', '63', '64', '65', '-1', '-64'])
            return '(%s %s %s)' % (gen_expr(env, 'i', depth - 1, self_fn), op, r)
        if k < 0.68:
            return '(- %s)' % gen_expr(env, 'i', depth - 1, self_fn)
        if k < 0.74:
            return '(~ %s)' % gen_expr(env, 'i', depth - 1, self_fn)
        c = call_expr(env, 'i', depth, self_fn)
        return c or lit('i')
    # float
    if k < 0.30:
        op = R.choice(['+', '-', '*'])
        a, b = R.choice([('f', 'f'), ('f', 'i'), ('i', 'f')])
        return '(%s %s %s)' % (gen_expr(env, a, depth - 1, self_fn), op, gen_expr(env, b, depth - 1, self_fn))
    if k < 0.45:
        a, b = R.choice([('f', 'f'), ('i', 'i'), ('f', 'i'), ('i', 'f')])
        return '(%s / %s)' % (gen_expr(env, a, depth - 1, self_fn), gen_expr(env, b, depth - 1, self_fn))
    if k < 0.55:
        a, b = R.choice([('f', 'f'), ('f', 'i'), ('i', 'f')])
        return '(%s %s %s)' % (gen_expr(env, a, depth - 1, self_fn), R.choice(['//', '%']), gen_expr(env, b, depth - 1, self_fn))
    if k < 0.62:
        a = R.choice(['f', 'i'])
        return '(%s ^ %s)' % (gen_expr(env, a, depth - 1, self_fn), R.choice(['2', '0.5', '3', '-1', '2.0', gen_expr(env, 'f', depth - 1, self_fn)]))
    if k < 0.68:
        return '(- %s)' % gen_expr(env, 'f', depth - 1, self_fn)
    c = call_expr(env, 'f', depth, self_fn)
    return c or lit('f')


def call_expr(env, t, depth, self_fn):
    cands = [f for f in funcs if (f.ret == t or (f.ret == 'n' and t in ('i', 'f') and R.random() < 0.5)) and f.level < CUR_LEVEL[0]] if BUDGET[0] > 0 else []
    if self_fn is not None and (self_fn.ret == t or (self_fn.ret == 'n' and t in ('i', 'f'))) and self_fn.self_ok and SELF_BUDGET[0] > 0:
        cands.append(self_fn)
    if not cands:
        return None
    f = R.choice(cands)
    if f is self_fn:
        SELF_BUDGET[0] -= 1
    else:
        BUDGET[0] -= 1
    args = []
    for pname, pt in f.params:
        if f is self_fn and pt == 'i' and pname == 'd':
            args.append('(d - 1)')
        elif pt == 'i' and pname == 'd':
            args.append(R.choice(['0', '1', '2']))  # the depth of a recursive function: small, or the calls would never end
        else:
            args.append(gen_expr(env, pt, depth - 1, self_fn))
    return '%s(%s)' % (f.name, ', '.join(args))


def protected(v):
    return v == 'd' or (v.startswith('c') and v[1:].isdigit())


def void_call(env, pad, out):
    cands = [f for f in funcs if f.ret == 'v' and f.level < CUR_LEVEL[0]]
    if not cands or BUDGET[0] <= 0:
        return False
    BUDGET[0] -= 1
    f = R.choice(cands)
    out.append('%s%s(%s)' % (pad, f.name, ', '.join(gen_expr(env, pt, 2, None) for _, pt in f.params)))
    return True


def gen_block(env, ret, depth, indent, in_loop, self_fn, nstmts):
    """Statements; the returned text may end in a return. ENV is extended by the declarations (a copy is used by inner blocks)."""
    out = []
    pad = '  ' * indent
    for _ in range(nstmts):
        k = R.random()
        if k < 0.26:
            t = R.choice(['i', 'i', 'f', 'f', 'b', 'n', 'n'])
            n = fresh('l')
            if t == 'n':
                out.append('%slocal %s = %s' % (pad, n, gen_expr(env, 'i', 3, self_fn)))  # starts as an integer; assigned floats later
            else:
                out.append('%slocal %s = %s' % (pad, n, gen_expr(env, t, 3, self_fn)))
            env[n] = t
        elif k < 0.46:
            cand = list(env.items())
            if cand:
                v, t = R.choice(cand)
                if protected(v):
                    continue  # loop counters and the depth of a recursive function are not assigned
                if R.random() < 0.15 and len([1 for x, tt in env.items() if tt == t]) >= 2:
                    # multiple assignment
                    vs = [x for x, tt in env.items() if tt == t and not protected(x)]
                    if len(vs) >= 2:
                        a, b = R.sample(vs, 2)
                        out.append('%s%s, %s = %s, %s' % (pad, a, b, gen_expr(env, t, 3, self_fn), gen_expr(env, t, 3, self_fn)))
                        continue
                out.append('%s%s = %s' % (pad, v, gen_expr(env, t, 3, self_fn)))
        elif k < 0.58 and depth > 0:
            n = R.choice([1, 2, 3])
            parts = ['%sif %s then' % (pad, gen_expr(env, 'b', 3, self_fn))]
            parts.append(gen_block(dict(env), ret, depth - 1, indent + 1, in_loop, self_fn, R.choice([1, 2])))
            if n >= 2:
                parts.append('%selseif %s then' % (pad, gen_expr(env, 'b', 3, self_fn)))
                parts.append(gen_block(dict(env), ret, depth - 1, indent + 1, in_loop, self_fn, 1))
            if n == 3 or R.random() < 0.3:
                parts.append('%selse' % pad)
                parts.append(gen_block(dict(env), ret, depth - 1, indent + 1, in_loop, self_fn, 1))
            parts.append('%send' % pad)
            out.append('\n'.join(parts))
        elif k < 0.70 and depth > 0:
            kind = R.choice(['int', 'int', 'float', 'cnt'])
            e2 = dict(env)
            v = fresh('c')
            if kind == 'int':
                ALLOW_N[0] = False
                start = R.choice(['1', '0', '-3', '5', gen_expr(env, 'i', 1, self_fn) + ' % 7'])
                ALLOW_N[0] = True
                limit = R.choice(['3', '5', '0', '-2', '(%s) %% 5' % gen_expr(env, 'i', 2, self_fn), '(%s) %% 4.5' % gen_expr(env, 'f', 2, self_fn)])
                step = R.choice(['', '', ', 1', ', 2', ', -1', ', 3', ', -2'])
                if step.startswith(', -') and '%' in limit:
                    # Lua runs `for i = 0, 0/0, -1` down to the smallest integer (a NaN limit that is not positive); nfcast skips it
                    # (a difference of the engine, not of the tier), so a computed limit stays out of loops that count down
                    limit = R.choice(['-3', '-5', '0', '-2'])
                e2[v] = 'i'
                body = gen_block(e2, ret, depth - 1, indent + 1, True, self_fn, R.choice([1, 2, 3]))
                out.append('%sfor %s = %s, %s%s do\n%s\n%send' % (pad, v, start, limit, step, body, pad))
            elif kind == 'float':
                e2[v] = 'f'
                body = gen_block(e2, ret, depth - 1, indent + 1, True, self_fn, R.choice([1, 2]))
                out.append('%sfor %s = %s, %s, %s do\n%s\n%send' % (pad, v, R.choice(['0.5', '0.0', '1.0', '-1.5']), R.choice(['3', '2.5', '4.0']), R.choice(['0.5', '1', '0.75']), body, pad))
            else:
                cnt = fresh('c')
                out.append('%slocal %s = 0' % (pad, cnt))
                e2[cnt] = 'i'
                w = R.choice(['while', 'repeat'])
                if w == 'while':
                    cond = gen_expr(e2, 'b', 2, self_fn)
                    body = gen_block(e2, ret, depth - 1, indent + 1, True, self_fn, R.choice([1, 2]))
                else:
                    body = gen_block(e2, ret, depth - 1, indent + 1, True, self_fn, R.choice([1, 2]))
                    cond = gen_expr(e2, 'b', 2, self_fn)
                inc = '%s  %s = %s + 1' % (pad, cnt, cnt)
                if w == 'while':
                    out.append('%swhile %s < 6 and %s do\n%s\n%s\n%send' % (pad, cnt, cond, inc, body, pad))
                else:
                    out.append('%srepeat\n%s\n%s\n%suntil %s >= 5 or %s' % (pad, inc, body, pad, cnt, cond))
        elif k < 0.76 and in_loop:
            out.append('%sif %s then break end' % (pad, gen_expr(env, 'b', 2, self_fn)))
        elif k < 0.84:
            if ret == 'v':
                out.append('%sif %s then return end' % (pad, gen_expr(env, 'b', 2, self_fn)))
            else:
                out.append('%sif %s then return %s end' % (pad, gen_expr(env, 'b', 2, self_fn), gen_expr(env, ret, 3, self_fn)))
        elif k < 0.90 and void_call(env, pad, out):
            pass
        else:
            t = R.choice(['i', 'f'])
            n = fresh('l')
            out.append('%slocal %s = %s' % (pad, n, gen_expr(env, t, 2, self_fn)))
            env[n] = t
    if not out:
        out.append('%slocal _ = 0' % pad)
    return '\n'.join(out)


def gen_func(idx):
    name = 'k%d' % idx
    nparams = R.choice([1, 2, 2, 3])
    params = []
    recursive = R.random() < 0.3
    if recursive:
        params.append(('d', 'i'))
    for p in 'abc'[:nparams]:
        params.append((p, R.choice(['i', 'i', 'f', 'f', 'b', 'n'])))
    ret = R.choice(['i', 'i', 'f', 'f', 'b', 'v', 'n', 'n'])
    level = min(idx, R.choice([0, 1, 1, 2, 2, 3]))
    CUR_LEVEL[0] = level
    BUDGET[0] = 2
    SELF_BUDGET[0] = 2
    f = Func(name, params, ret, level)
    f.self_ok = recursive
    env = dict(params)
    lines = ['local function %s(%s)' % (name, ', '.join(p for p, _ in params))]
    if recursive and ret == 'v':
        recursive = f.self_ok = False  # a recursive function without a value: nothing to recurse into
    if recursive:
        lines.append('  if d <= 0 then return %s end' % gen_expr({k: v for k, v in env.items()}, ret, 2, None))
    lines.append(gen_block(env, ret, 2, 1, False, None, R.choice([2, 3, 4, 5])))
    if ret != 'v':
        lines.append('  return %s' % gen_expr(env, ret, 3, f if recursive else None))
    lines.append('end')
    return f, '\n'.join(lines)


def arg_for(t, wrong):
    if t == 'n':
        t = R.choice(['i', 'f'])
        wrong = wrong and R.random() < 0.3
    if wrong:
        t = R.choice([x for x in 'ifb' if x != t])
    if t == 'i':
        return R.choice(['0', '1', '-1', '2', '5', '7', '-3', '100', '65536', '9223372036854775807', '(-9223372036854775807 - 1)', '3037000500', '64'])
    if t == 'f':
        return R.choice(['0.0', '1.5', '-2.5', '0.1', '3.0', '1e10', '2.0', '-0.5', '100.75'])
    return R.choice(['true', 'false'])


def mutate_ups():
    u, t = R.choice(UPS)
    if R.random() < 0.15:
        t = R.choice('ifb')  # a different type: the compiled code assumed the old one
    v = lit(t)
    while '1e308' in v:  # no infinities in the free variables: a NaN start of a float loop would meet a difference of the engine
        v = lit(t)       # from Lua's (the loop's body is skipped, Lua runs it once)
    return '%s = %s' % (u, v)


out = ['local function show(...) print(...) end', 'local u1, u2, u3 = 7, 2.5, true', 'g1, g2 = 5, 0.5']
calls = []
for i in range(nfuncs):
    f, text = gen_func(i)
    if R.random() < 0.3:
        text = text.replace('local function', 'function', 1)  # a global function: called through the globals table
    out.append(text)
    funcs.append(f)
    for _ in range(R.choice([4, 6, 8])):
        wrong = R.random() < 0.12
        args = []
        for pname, pt in f.params:
            if pname == 'd':
                args.append(R.choice(['0', '1', '2', '3', '5']))
            else:
                args.append(arg_for(pt, wrong and R.random() < 0.5))
        if args and R.random() < 0.04:
            args.pop()  # a missing argument is nil
        if R.random() < 0.25:
            out.append(mutate_ups())
        out.append('show("%s", pcall(%s%s))' % (f.name, f.name, ''.join(', ' + a for a in args)))
print('\n'.join(out))
