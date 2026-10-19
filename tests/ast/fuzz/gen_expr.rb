# gen_expr.rb: port of tests/ast/fuzz/gen_expr.py for mruby (run by tests/ast/fuzz.sh through scripts/mrb).
# Writes a Lua program of N random expressions (arithmetic, bitwise, comparison, concatenation, logic and a few math functions
# over integers, floats, strings and other values) to stdout, each evaluated under pcall; run by tests/ast/fuzz.sh.
# usage: scripts/mrb tests/ast/fuzz/gen_expr.rb SEED N
# The draws come from Rng (xorshift64 seeded by SEED), not from Python's random module, so the programs for a given seed are
# not the Python original's; the grammar and the order of the draws are the same.

M64 = (1 << 64) - 1

# Seeded draws. mruby has no Random class. Every draw goes through u, a float in [0, 1) with 30 random bits.
class Rng
  def initialize(seed)
    @s = ((seed + 1) * 0x9E3779B97F4A7C1) & M64
    @s = 1 if @s == 0
  end

  def u
    x = @s
    x ^= (x << 13) & M64
    x ^= x >> 7
    x ^= (x << 17) & M64
    @s = x
    (x >> 34) / 1073741824.0
  end

  def random
    u
  end

  def randint(a, b)
    a + (u * (b - a + 1)).floor
  end

  def choice(seq)
    seq[(u * seq.size).floor]
  end
end

RND = Rng.new(ARGV[0].to_i)
N = ARGV[1].to_i

INTS = ["0", "1", "2", "3", "7", "-1", "-2", "10", "255", "1000", "0x7fffffffffffffff", "math.maxinteger", "math.mininteger", "(-9223372036854775807 - 1)", "63", "64", "-64", "100"]
FLOATS = ["0.0", "-0.0", "0.5", "1.5", "-2.5", "3.0", "1e10", "1e300", "2^53", "2^63", "-2^63", "1/0", "-1/0", "0.1", "255.0", "1e15", "123456.789"]
STRS = ['"a"', '"abc"', '""', '"10"', '"0x10"', '" 5 "', '"1e1"', '"3.5"', '"x1"', '"-7"', '"hello world"', '"q"', '"%d"']
OTHERS = ["nil", "true", "false", "{}", "{1,2,3}", "print"]
VARS = ["a", "b", "c", "s", "t"]
BIN_OPS = ["+", "-", "*", "/", "//", "%", "^", "..", "==", "~=", "<", "<=", ">", ">=", "and", "or", "&", "|", "~", "<<", ">>"]
UN_OPS = ["-", "not ", "#", "~"]
MATH_FUNCS = ["floor", "ceil", "abs", "sqrt", "tointeger", "type"]

def atom
  r = RND.random
  return RND.choice(INTS) if r < 0.30
  return RND.choice(FLOATS) if r < 0.50
  return RND.choice(STRS) if r < 0.70
  return RND.choice(OTHERS) if r < 0.80
  RND.choice(VARS)
end

def expr(d)
  return atom if d <= 0 || RND.random < 0.25
  r = RND.random
  if r < 0.7
    return "(" + expr(d - 1) + " " + RND.choice(BIN_OPS) + " " + expr(d - 1) + ")"
  end
  if r < 0.85
    return "(" + RND.choice(UN_OPS) + "(" + expr(d - 1) + "))"
  end
  if r < 0.93
    return "math." + RND.choice(MATH_FUNCS) + "(" + expr(d - 1) + ")"
  end
  "tostring(" + expr(d - 1) + ")"
end

out = ["local a, b, c, s, t = 3, 4.5, 'str', '12', {1,2}", "local function show(ok, v) if ok then print('ok', math.type(v) or type(v), tostring(v)) else print('err', (tostring(v):gsub('^[^:]*:%d+: ', ''))) end end"]
N.times do
  out << format("show(pcall(function() return %s end))", expr(RND.randint(1, 4)))
end
print(out.join("\n") + "\n")
