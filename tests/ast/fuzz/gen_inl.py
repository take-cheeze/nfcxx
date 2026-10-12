# Writes a Lua program for the inlining of small functions to stdout; run by tests/ast/fuzz.sh next to gen_expr.py and gen_pat.py.
# A few random helper functions (one to three parameters; a `return <expr>`, a local and a return, an if chain with returns, an
# update of an upvalue or of a field, a call of an earlier helper) and a few methods of two classes (reading and writing fields of
# self) are called from N random expressions, and each expression runs under pcall over several tuples of argument values
# (integers, floats, strings, tables, nil) and three receivers (two classes, and an object that shadows a method), so that a call
# site is hot by the time the values change type or the receiver changes class, the number of arguments at a site is not the number
# of parameters, and errors are raised inside the callees (the message, with its position, is compared with the reference's).
# Since the inliner takes loops, multiple assignment, parameter substitution and polymorphic sites: bodies with numeric/while/repeat/
# generic loops (break, return from inside), multiple assignment (parameters swapped, fields and upvalues as targets), assigned
# parameters, and calls through a list of helpers indexed by the argument tuple (the guard fails and the site is inlined again).
# usage: gen_inl.py SEED N
import random, sys
seed = int(sys.argv[1]); n = int(sys.argv[2])
rnd = random.Random(seed)
consts = ["0", "1", "2", "3", "7", "-1", "10", "255", "0x7fffffffffffffff", "math.maxinteger", "math.mininteger", "63", "64",
          "0.0", "0.5", "1.5", "-2.5", "3.0", "1e10", "2^53", "1/0", '"a"', '"abc"', '""', '"10"', '"0x10"', '" 5 "', '"3.5"',
          "nil", "true", "false", "{}", "{1,2,3}"]
bin_ops = ["+", "-", "*", "/", "//", "%", "^", "..", "==", "~=", "<", "<=", ">", ">=", "and", "or", "&", "|", "~", "<<", ">>"]
un_ops = ["-", "not ", "#", "~"]

def expr(d, names, calls):
    if d <= 0 or rnd.random() < 0.3:
        return rnd.choice(names) if rnd.random() < 0.65 else rnd.choice(consts)
    r = rnd.random()
    if r < 0.55: return "(" + expr(d - 1, names, calls) + " " + rnd.choice(bin_ops) + " " + expr(d - 1, names, calls) + ")"
    if r < 0.65: return "(" + rnd.choice(un_ops) + "(" + expr(d - 1, names, calls) + "))"
    if r < 0.70: return "tostring(" + expr(d - 1, names, calls) + ")"
    if calls:
        h, k = rnd.choice(calls)
        # the number of arguments need not be the callee's number of parameters
        cnt = k if rnd.random() < 0.7 else max(0, k + rnd.choice([-2, -1, 1, 2]))
        return "%s(%s)" % (h, ", ".join(expr(d - 1, names, calls) for _ in range(cnt)))
    return expr(d - 1, names, calls)

def body(names, calls, selfmode, params):
    e = lambda: expr(rnd.randint(1, 2), names, calls)
    ln = names + ["s", "s", "i"]                       # names inside the loop bodies below
    le = lambda: expr(rnd.randint(1, 2), ln, calls)
    shape = rnd.random()
    if shape < 0.20:
        return "return " + e()
    if shape < 0.30:
        return "local l = %s\n  return l %s %s" % (e(), rnd.choice(bin_ops), e())
    if shape < 0.40:
        return "if %s then return %s end\n  return %s" % (e(), e(), e())
    if shape < 0.47:
        return "if %s then return %s elseif %s then return %s else return %s end" % (e(), e(), e(), e(), e())
    if shape < 0.52:
        return "up = %s\n  return up" % e()
    if shape < 0.57:
        return ("self.f = %s\n  return self.f" if selfmode else "tab.f = %s\n  return tab.f") % e()
    if shape < 0.60:
        return "cnt = cnt + 1\n  return %s, cnt" % e()
    if shape < 0.64:
        return "local a, b = %s, %s\n  a, b = b, a\n  return a, b" % (e(), e())
    # ---- loops
    if shape < 0.69:
        return "local s = %s\n  for i = 1, %d do s = %s end\n  return s" % (e(), rnd.randint(0, 4), le())
    if shape < 0.72:
        return "local s = %s\n  for i = %d, %d, %d do s = %s end\n  return s, s" % (e(), rnd.randint(-2, 3), rnd.randint(-2, 5), rnd.choice([1, 2, -1, -2]), le())
    if shape < 0.75:
        return "local s, i = %s, 0\n  while i < %d do i = i + 1 s = %s end\n  return s" % (e(), rnd.randint(0, 4), le())
    if shape < 0.78:
        return "local s, i = %s, 0\n  repeat i = i + 1 s = %s until i >= %d or %s\n  return s" % (e(), le(), rnd.randint(1, 3), le())
    if shape < 0.81:
        return "local s = %s\n  for i = 1, 5 do if %s then break end s = %s end\n  return s" % (e(), le(), le())
    if shape < 0.83:
        return "local s = 0\n  for i = 1, 4 do if %s then return %s, i end s = s + i end\n  return s" % (le(), le())
    if shape < 0.86:
        return "local s = 0\n  for _, v in ipairs(%s) do s = s + v end\n  return s" % rnd.choice(params + ["tab", "{1, 2, 3}"])
    # ---- assigned parameters and multiple assignment
    if shape < 0.90:
        return "%s = %s\n  return %s" % (params[0], e(), params[-1])
    if shape < 0.93 and len(params) >= 2:
        return "%s, %s = %s, %s\n  return %s, %s" % (params[0], params[1], params[1], params[0], params[0], params[1])
    if shape < 0.96:
        return "local o = {}\n  o.x, o[1], up = %s, %s, %s\n  return o.x, o[1], up" % (e(), e(), e())
    if shape < 0.98:
        return "tab.f, cnt = %s, cnt + 1\n  return tab.f, cnt" % e()
    return "return"

def helper(i, helpers):
    k = rnd.randint(1, 3)
    params = ["p", "q", "r"][:k]
    name = "h%d" % i
    return "local function %s(%s)\n  %s\nend" % (name, ", ".join(params), body(params + ["up", "up"], helpers, False, params)), (name, k)

argsets = [
    "{3, 4.5, 'str', '12', {1, 2}}", "{1, 2, 3, 4, {}}", "{7, 7, 7, 7, 7}", "{2.5, 1, '5', 'x', {}}", "{0, -1, '0x10', ' 3 ', {1}}",
    "{math.maxinteger, 1, 1.5, '1e1', {n = 1}}", "{nil, 2, 3, 4, 5}", "{'a', 'b', 'c', 'd', 'e'}", "{true, false, 1, 2, 3}", "{1, 2, 3, 4, 5}",
]
out = ["local up, cnt, tab = 3, 0, {f = 1}",
       "local function show(ok, ...) if ok then local t = table.pack(...) for i = 1, t.n do t[i] = (math.type(t[i]) or type(t[i])) .. ':' .. tostring(t[i]) end print('ok', table.concat(t, ' ')) else print('err', tostring((...))) end end"]
helpers = []
for i in range(rnd.randint(4, 9)):
    src, h = helper(i, helpers)
    out.append(src)
    helpers.append(h)
# two classes with methods m0..m2 (the second lacks some); they read and write fields of self
out.append("local A, B = {}, {}\nA.__index = A\nB.__index = B")
methods = []
for i in range(3):
    k = rnd.randint(0, 2)
    params = ["p", "q"][:k]
    names = ["self.f", "self.g", "up"] + params
    for cls in ("A", "B"):
        if cls == "B" and rnd.random() < 0.25: continue
        out.append("function %s:m%d(%s)\n  %s\nend" % (cls, i, ", ".join(params), body(names, [], True, ["self"] + params)))
    methods.append(("o:m%d" % i, k))
out.append("local objs = {setmetatable({f = 1, g = 2}, A), setmetatable({f = 2.5, g = 'x'}, B), "
           "setmetatable({f = 7, g = 3, m0 = function(self, p) return p end}, A)}")
out.append("local argsets = {%s}" % ", ".join(argsets))
# a call through a list of helpers picked by the index of the argument tuple: the callee of the site changes
pol = []
for q in range(rnd.randint(1, 3)):
    cnt = rnd.randint(2, 4)
    members = [rnd.choice(helpers)[0] for _ in range(cnt)] if bool(helpers) else []
    pol.append(("fp%d[k %% %d + 1]" % (q, cnt), rnd.randint(1, 3)))
    out.append("local fp%d = {%s}" % (q, ", ".join(members)))
methods += pol
vars_ = ["a", "b", "c", "s", "t"]
for i in range(n):
    # the function literal is one prototype, so the call sites in it are the same sites on every iteration
    out.append("for k, args in ipairs(argsets) do show(pcall(function(a, b, c, s, t, o, k) return %s end, args[1], args[2], args[3], args[4], args[5], objs[k %% 3 + 1], k)) end"
               % expr(rnd.randint(1, 4), vars_, helpers + methods))
out.append("print(up, cnt, tab.f)")
print("\n".join(out))
