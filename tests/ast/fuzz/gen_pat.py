# Writes a Lua program of N random calls of string.find, string.match, string.gsub and string.gmatch with random patterns and
# subjects to stdout, each under pcall; run by tests/ast/fuzz.sh.
# usage: gen_pat.py SEED N
import random, sys
seed = int(sys.argv[1]); n = int(sys.argv[2])
rnd = random.Random(seed)
alpha = "abc12 -_.,"
def lit(): return rnd.choice(["a", "b", "c", "1", "2", " ", "-", "_", ".", ","])
classes = ["%a", "%d", "%s", "%w", "%l", "%u", "%p", "%x", "%A", "%D", "%S", "%W", "."]
def set_():
    items = []
    for _ in range(rnd.randint(1, 3)):
        r = rnd.random()
        if r < 0.3: items.append(rnd.choice(["a-c", "1-2", "a-b"]))
        elif r < 0.5: items.append(rnd.choice(classes[:-1]))
        else: items.append(lit() if lit() not in "-]^%" else "a")
    return "[" + ("^" if rnd.random() < 0.3 else "") + "".join(items) + "]"
def single():
    r = rnd.random()
    if r < 0.45: c = lit(); return ("%" + c) if c in ".-" else c
    if r < 0.7: return rnd.choice(classes)
    return set_()
def item():
    s = single()
    r = rnd.random()
    if r < 0.55: return s
    return s + rnd.choice(["*", "+", "-", "?"])
def pattern(d=0):
    parts = []
    for _ in range(rnd.randint(1, 4)):
        r = rnd.random()
        if r < 0.15 and d < 2: parts.append("(" + pattern(d + 1) + ")")
        elif r < 0.2: parts.append("()")
        elif r < 0.25: parts.append(rnd.choice(["%b()", "%f[%w]", "%f[%s]", "%1"]))
        else: parts.append(item())
    p = "".join(parts)
    if rnd.random() < 0.15: p = "^" + p
    if rnd.random() < 0.15: p = p + "$"
    return p
def subject():
    return "".join(rnd.choice(alpha) for _ in range(rnd.randint(0, 12)))
def q(s): return "'" + s.replace("\\", "\\\\").replace("'", "\\'") + "'"
out = ["local function show(...) local t = table.pack(...) for i = 1, t.n do t[i] = tostring(t[i]) end print(table.concat(t, ' | ')) end",
       "local function try(f, ...) local r = table.pack(pcall(f, ...)) if not r[1] then r[2] = tostring(r[2]):gsub('^[^:]*:%d+: ', '') end show(table.unpack(r, 1, r.n)) end"]
for i in range(n):
    s, p = q(subject()), q(pattern())
    k = rnd.random()
    if k < 0.25: out.append("try(string.find, %s, %s%s)" % (s, p, rnd.choice(["", ", 2", ", -3", ", 1, true"])))
    elif k < 0.5: out.append("try(string.match, %s, %s%s)" % (s, p, rnd.choice(["", ", 2", ", -2"])))
    elif k < 0.75: out.append("try(string.gsub, %s, %s, %s%s)" % (s, p, rnd.choice(["'<%0>'", "'%1'", "''", "'x'", "{a='A', b=false}", "function(...) return select('#', ...) end", "function(a) return a end"]), rnd.choice(["", ", 2", ", 0"])))
    else: out.append("try(function() local t = {} for a, b in string.gmatch(%s, %s) do t[#t + 1] = tostring(a) .. ':' .. tostring(b) end return table.concat(t, ',') end)" % (s, p))
print("\n".join(out))
