# Writes a Lua program for the inlining of small functions to stdout; run by tests/ast/fuzz.sh next to gen_expr.py and gen_pat.py.
# A few random helper functions (one to three parameters; a `return <expr>`, a local and a return, an if chain with returns, an
# update of an upvalue or of a field, a call of an earlier helper) are called from N random expressions, and each expression runs
# under pcall over several tuples of argument values (integers, floats, strings, tables, nil), so that a call site is hot by the
# time the values change type, the argument count at a site is not the parameter count of the helper, and errors are raised
# inside the helpers (the message, with its position, is compared with the reference's; two messages are compared without it, the
# modulo and the division of integers by zero: Lua raises them without a position when an operand is a string, because the string
# metamethod raises them, and nfcast does not yet).
# usage: gen_inl.py SEED N
import random, sys
seed = int(sys.argv[1]); n = int(sys.argv[2])
rnd = random.Random(seed)
consts = ["0", "1", "2", "3", "7", "-1", "10", "255", "0x7fffffffffffffff", "math.maxinteger", "math.mininteger", "63", "64",
          "0.0", "0.5", "1.5", "-2.5", "3.0", "1e10", "2^53", "1/0", '"a"', '"abc"', '""', '"10"', '"0x10"', '" 5 "', '"3.5"',
          "nil", "true", "false", "{}", "{1,2,3}"]
bin_ops = ["+", "-", "*", "/", "//", "%", "^", "..", "==", "~=", "<", "<=", ">", ">=", "and", "or", "&", "|", "~", "<<", ">>"]
un_ops = ["-", "not ", "#", "~"]

def expr(d, names, helpers):
    if d <= 0 or rnd.random() < 0.3:
        return rnd.choice(names) if rnd.random() < 0.65 else rnd.choice(consts)
    r = rnd.random()
    if r < 0.55: return "(" + expr(d - 1, names, helpers) + " " + rnd.choice(bin_ops) + " " + expr(d - 1, names, helpers) + ")"
    if r < 0.65: return "(" + rnd.choice(un_ops) + "(" + expr(d - 1, names, helpers) + "))"
    if r < 0.70: return "tostring(" + expr(d - 1, names, helpers) + ")"
    if helpers:
        h, k = rnd.choice(helpers)
        # the number of arguments need not be the helper's number of parameters
        cnt = k if rnd.random() < 0.7 else max(0, k + rnd.choice([-2, -1, 1, 2]))
        return "%s(%s)" % (h, ", ".join(expr(d - 1, names, helpers) for _ in range(cnt)))
    return expr(d - 1, names, helpers)

def helper(i, helpers):
    k = rnd.randint(1, 3)
    params = ["p", "q", "r"][:k]
    names = params + ["up", "up"]
    name = "h%d" % i
    shape = rnd.random()
    e = lambda: expr(rnd.randint(1, 2), names, helpers)
    if shape < 0.30:
        body = "return " + e()
    elif shape < 0.45:
        body = "local l = %s\n  return l %s %s" % (e(), rnd.choice(bin_ops), e())
    elif shape < 0.60:
        body = "if %s then return %s end\n  return %s" % (e(), e(), e())
    elif shape < 0.70:
        body = "if %s then return %s elseif %s then return %s else return %s end" % (e(), e(), e(), e(), e())
    elif shape < 0.78:
        body = "up = %s\n  return up" % e()
    elif shape < 0.84:
        body = "tab.f = %s\n  return tab.f" % e()
    elif shape < 0.90:
        body = "cnt = cnt + 1\n  return %s, cnt" % e()
    elif shape < 0.95:
        body = "local a, b = %s, %s\n  a, b = b, a\n  return a, b" % (e(), e())
    else:
        body = "return"
    return "local function %s(%s)\n  %s\nend" % (name, ", ".join(params), body), (name, k)

argsets = [
    "{3, 4.5, 'str', '12', {1, 2}}", "{1, 2, 3, 4, {}}", "{7, 7, 7, 7, 7}", "{2.5, 1, '5', 'x', {}}", "{0, -1, '0x10', ' 3 ', {1}}",
    "{math.maxinteger, 1, 1.5, '1e1', {n = 1}}", "{nil, 2, 3, 4, 5}", "{'a', 'b', 'c', 'd', 'e'}", "{true, false, 1, 2, 3}", "{1, 2, 3, 4, 5}",
]
out = ["local up, cnt, tab = 3, 0, {f = 1}",
       "local function show(ok, ...) if ok then local t = table.pack(...) for i = 1, t.n do t[i] = (math.type(t[i]) or type(t[i])) .. ':' .. tostring(t[i]) end print('ok', table.concat(t, ' ')) else print('err', (tostring((...)):gsub('^[^:]*:%d+: (attempt to perform .n%%0.)$', '%1'):gsub('^[^:]*:%d+: (attempt to divide by zero)$', '%1'))) end end"]
helpers = []
for i in range(rnd.randint(4, 9)):
    src, h = helper(i, helpers)
    out.append(src)
    helpers.append(h)
out.append("local argsets = {%s}" % ", ".join(argsets))
vars_ = ["a", "b", "c", "s", "t"]
for i in range(n):
    # the function literal is one prototype, so the call sites in it are the same sites on every iteration
    out.append("for _, args in ipairs(argsets) do show(pcall(function(a, b, c, s, t) return %s end, args[1], args[2], args[3], args[4], args[5])) end"
               % expr(rnd.randint(1, 4), vars_, helpers))
out.append("print(up, cnt, tab.f)")
print("\n".join(out))
