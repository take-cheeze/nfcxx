# gen_inl.rb: port of tests/ast/fuzz/gen_inl.py for mruby (run by tests/ast/fuzz.sh through scripts/mrb).
# Writes a Lua program for the inlining of small functions to stdout; run by tests/ast/fuzz.sh next to gen_expr.rb and gen_pat.rb.
# A few random helper functions (one to three parameters; a `return <expr>`, a local and a return, an if chain with returns, an
# update of an upvalue or of a field, a call of an earlier helper) and a few methods of two classes (reading and writing fields of
# self) are called from N random expressions, and each expression runs under pcall over several tuples of argument values
# (integers, floats, strings, tables, nil) and three receivers (two classes, and an object that shadows a method), so that a call
# site is hot by the time the values change type or the receiver changes class, the number of arguments at a site is not the number
# of parameters, and errors are raised inside the callees (the message, with its position, is compared with the reference's).
# Since the inliner takes loops, multiple assignment, parameter substitution and polymorphic sites: bodies with numeric/while/repeat/
# generic loops (break, return from inside), multiple assignment (parameters swapped, fields and upvalues as targets), assigned
# parameters, and calls through a list of helpers indexed by the argument tuple (the guard fails and the site is inlined again).
# usage: scripts/mrb tests/ast/fuzz/gen_inl.rb SEED N
# The draws come from Rng (mruby-random's Random seeded by SEED), not from Python's random module, so the programs for a given seed are
# not the Python original's; the grammar and the order of the draws are the same.

# Seeded draws: mruby-random's Random, seeded by SEED. The helpers keep the names the generator calls.
class Rng
  def initialize(seed)
    @r = Random.new(seed)
  end

  def random
    @r.rand
  end

  def randint(a, b)
    @r.rand(a..b)
  end

  def choice(seq)
    seq[@r.rand(seq.size)]
  end
end

RND = Rng.new(ARGV[0].to_i)
N = ARGV[1].to_i

CONSTS = ["0", "1", "2", "3", "7", "-1", "10", "255", "0x7fffffffffffffff", "math.maxinteger", "math.mininteger", "63", "64",
          "0.0", "0.5", "1.5", "-2.5", "3.0", "1e10", "2^53", "1/0", '"a"', '"abc"', '""', '"10"', '"0x10"', '" 5 "', '"3.5"',
          "nil", "true", "false", "{}", "{1,2,3}"]
BIN_OPS = ["+", "-", "*", "/", "//", "%", "^", "..", "==", "~=", "<", "<=", ">", ">=", "and", "or", "&", "|", "~", "<<", ">>"]
UN_OPS = ["-", "not ", "#", "~"]
INT_LITS = ["0", "1", "-1", "2", "3", "5", "7", "10", "16", "63", "64", "100", "255", "65535", "2147483647", "4294967296",
            "9223372036854775807", "(-9223372036854775807 - 1)", "(1 << 62)", "9007199254740993", "-7", "-100"]
FLT_LITS = ["0.0", "1.0", "0.5", "-2.5", "3.14159", "1e10", "-1e-5", "2.0", "100.25", "9007199254740992.0", "1e15", "(1e308 * 10)",
            "(-1e308 * 10)", "0.1", "-0.0"]

# CALLS holds [name, number of parameters] pairs of the helpers and methods an expression may call
def expr(d, names, calls)
  if d <= 0 || RND.random < 0.3
    return (RND.random < 0.65) ? RND.choice(names) : RND.choice(CONSTS)
  end
  r = RND.random
  if r < 0.55
    return "(" + expr(d - 1, names, calls) + " " + RND.choice(BIN_OPS) + " " + expr(d - 1, names, calls) + ")"
  end
  if r < 0.65
    return "(" + RND.choice(UN_OPS) + "(" + expr(d - 1, names, calls) + "))"
  end
  if r < 0.70
    return "tostring(" + expr(d - 1, names, calls) + ")"
  end
  unless calls.empty?
    h, k = RND.choice(calls)
    # the number of arguments need not be the callee's number of parameters
    cnt = (RND.random < 0.7) ? k : [0, k + RND.choice([-2, -1, 1, 2])].max
    args = Array.new(cnt) { expr(d - 1, names, calls) }
    return h + "(" + args.join(", ") + ")"
  end
  expr(d - 1, names, calls)
end

def body(names, calls, selfmode, params)
  e = -> { expr(RND.randint(1, 2), names, calls) }
  ln = names + ["s", "s", "i"]                       # names inside the loop bodies below
  le = -> { expr(RND.randint(1, 2), ln, calls) }
  shape = RND.random
  return "return " + e.call if shape < 0.20
  return format("local l = %s\n  return l %s %s", e.call, RND.choice(BIN_OPS), e.call) if shape < 0.30
  return format("if %s then return %s end\n  return %s", e.call, e.call, e.call) if shape < 0.40
  if shape < 0.47
    return format("if %s then return %s elseif %s then return %s else return %s end", e.call, e.call, e.call, e.call, e.call)
  end
  return format("up = %s\n  return up", e.call) if shape < 0.52
  if shape < 0.57
    return format(selfmode ? "self.f = %s\n  return self.f" : "tab.f = %s\n  return tab.f", e.call)
  end
  return format("cnt = cnt + 1\n  return %s, cnt", e.call) if shape < 0.60
  return format("local a, b = %s, %s\n  a, b = b, a\n  return a, b", e.call, e.call) if shape < 0.64
  # ---- loops
  if shape < 0.69
    return format("local s = %s\n  for i = 1, %d do s = %s end\n  return s", e.call, RND.randint(0, 4), le.call)
  end
  if shape < 0.72
    return format("local s = %s\n  for i = %d, %d, %d do s = %s end\n  return s, s", e.call, RND.randint(-2, 3), RND.randint(-2, 5), RND.choice([1, 2, -1, -2]), le.call)
  end
  if shape < 0.75
    return format("local s, i = %s, 0\n  while i < %d do i = i + 1 s = %s end\n  return s", e.call, RND.randint(0, 4), le.call)
  end
  if shape < 0.78
    return format("local s, i = %s, 0\n  repeat i = i + 1 s = %s until i >= %d or %s\n  return s", e.call, le.call, RND.randint(1, 3), le.call)
  end
  return format("local s = %s\n  for i = 1, 5 do if %s then break end s = %s end\n  return s", e.call, le.call, le.call) if shape < 0.81
  return format("local s = 0\n  for i = 1, 4 do if %s then return %s, i end s = s + i end\n  return s", le.call, le.call) if shape < 0.83
  if shape < 0.86
    return format("local s = 0\n  for _, v in ipairs(%s) do s = s + v end\n  return s", RND.choice(params + ["tab", "{1, 2, 3}"]))
  end
  # ---- assigned parameters and multiple assignment
  if shape < 0.90
    return format("%s = %s\n  return %s", params[0], e.call, params[-1])
  end
  if shape < 0.93 && params.size >= 2
    return format("%s, %s = %s, %s\n  return %s, %s", params[0], params[1], params[1], params[0], params[0], params[1])
  end
  if shape < 0.96
    return format("local o = {}\n  o.x, o[1], up = %s, %s, %s\n  return o.x, o[1], up", e.call, e.call, e.call)
  end
  return format("tab.f, cnt = %s, cnt + 1\n  return tab.f, cnt", e.call) if shape < 0.98
  "return"
end

def helper(i, helpers)
  k = RND.randint(1, 3)
  params = ["p", "q", "r"][0...k]
  name = format("h%d", i)
  src = format("local function %s(%s)\n  %s\nend", name, params.join(", "), body(params + ["up", "up"], helpers, false, params))
  [src, [name, k]]
end

argsets = [
  "{3, 4.5, 'str', '12', {1, 2}}", "{1, 2, 3, 4, {}}", "{7, 7, 7, 7, 7}", "{2.5, 1, '5', 'x', {}}", "{0, -1, '0x10', ' 3 ', {1}}",
  "{math.maxinteger, 1, 1.5, '1e1', {n = 1}}", "{nil, 2, 3, 4, 5}", "{'a', 'b', 'c', 'd', 'e'}", "{true, false, 1, 2, 3}", "{1, 2, 3, 4, 5}",
]
out = ["local up, cnt, tab = 3, 0, {f = 1}",
       "local function show(ok, ...) if ok then local t = table.pack(...) for i = 1, t.n do t[i] = (math.type(t[i]) or type(t[i])) .. ':' .. tostring(t[i]) end print('ok', table.concat(t, ' ')) else print('err', tostring((...))) end end"]
helpers = []
RND.randint(4, 9).times do |i|
  src, h = helper(i, helpers)
  out << src
  helpers << h
end
# two classes with methods m0..m2 (the second lacks some); they read and write fields of self
out << "local A, B = {}, {}\nA.__index = A\nB.__index = B"
methods = []
3.times do |i|
  k = RND.randint(0, 2)
  params = ["p", "q"][0...k]
  names = ["self.f", "self.g", "up"] + params
  ["A", "B"].each do |cls|
    next if cls == "B" && RND.random < 0.25
    out << format("function %s:m%d(%s)\n  %s\nend", cls, i, params.join(", "), body(names, [], true, ["self"] + params))
  end
  methods << ["o:m#{i}", k]
end
out << "local objs = {setmetatable({f = 1, g = 2}, A), setmetatable({f = 2.5, g = 'x'}, B), " \
       "setmetatable({f = 7, g = 3, m0 = function(self, p) return p end}, A)}"
out << format("local argsets = {%s}", argsets.join(", "))
# a call through a list of helpers picked by the index of the argument tuple: the callee of the site changes
pol = []
RND.randint(1, 3).times do |q|
  cnt = RND.randint(2, 4)
  members = helpers.empty? ? [] : Array.new(cnt) { RND.choice(helpers)[0] }
  pol << [format("fp%d[k %% %d + 1]", q, cnt), RND.randint(1, 3)]
  out << format("local fp%d = {%s}", q, members.join(", "))
end
methods += pol
vars = ["a", "b", "c", "s", "t"]
N.times do
  # the function literal is one prototype, so the call sites in it are the same sites on every iteration
  out << format("for k, args in ipairs(argsets) do show(pcall(function(a, b, c, s, t, o, k) return %s end, args[1], args[2], args[3], args[4], args[5], objs[k %% 3 + 1], k)) end",
                expr(RND.randint(1, 4), vars, helpers + methods))
end
out << "print(up, cnt, tab.f)"
print(out.join("\n") + "\n")
