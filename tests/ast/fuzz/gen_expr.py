# Writes a Lua program of N random expressions (arithmetic, bitwise, comparison, concatenation, logic and a few math functions
# over integers, floats, strings and other values) to stdout, each evaluated under pcall; run by tests/ast/fuzz.sh.
# usage: gen_expr.py SEED N
import random, sys
seed = int(sys.argv[1]); n = int(sys.argv[2])
rnd = random.Random(seed)
ints = ["0", "1", "2", "3", "7", "-1", "-2", "10", "255", "1000", "0x7fffffffffffffff", "math.maxinteger", "math.mininteger", "(-9223372036854775807 - 1)", "63", "64", "-64", "100"]
floats = ["0.0", "-0.0", "0.5", "1.5", "-2.5", "3.0", "1e10", "1e300", "2^53", "2^63", "-2^63", "1/0", "-1/0", "0.1", "255.0", "1e15", "123456.789"]
strs = ['"a"', '"abc"', '""', '"10"', '"0x10"', '" 5 "', '"1e1"', '"3.5"', '"x1"', '"-7"', '"hello world"', '"q"', '"%d"']
others = ["nil", "true", "false", "{}", "{1,2,3}", "print"]
vars_ = ["a", "b", "c", "s", "t"]
bin_ops = ["+", "-", "*", "/", "//", "%", "^", "..", "==", "~=", "<", "<=", ">", ">=", "and", "or", "&", "|", "~", "<<", ">>"]
un_ops = ["-", "not ", "#", "~"]
def atom():
    r = rnd.random()
    if r < 0.30: return rnd.choice(ints)
    if r < 0.50: return rnd.choice(floats)
    if r < 0.70: return rnd.choice(strs)
    if r < 0.80: return rnd.choice(others)
    return rnd.choice(vars_)
def expr(d):
    if d <= 0 or rnd.random() < 0.25: return atom()
    r = rnd.random()
    if r < 0.7: return "(" + expr(d-1) + " " + rnd.choice(bin_ops) + " " + expr(d-1) + ")"
    if r < 0.85: return "(" + rnd.choice(un_ops) + "(" + expr(d-1) + "))"
    if r < 0.93: return "math." + rnd.choice(["floor","ceil","abs","sqrt","tointeger","type"]) + "(" + expr(d-1) + ")"
    return "tostring(" + expr(d-1) + ")"
out = ["local a, b, c, s, t = 3, 4.5, 'str', '12', {1,2}", "local function show(ok, v) if ok then print('ok', math.type(v) or type(v), tostring(v)) else print('err', (tostring(v):gsub('^[^:]*:%d+: ', ''))) end end"]
for i in range(n):
    out.append("show(pcall(function() return %s end))" % expr(rnd.randint(1, 4)))
print("\n".join(out))
