# gen_pat.rb: port of tests/ast/fuzz/gen_pat.py for mruby (run by tests/ast/fuzz.sh through scripts/mrb).
# Writes a Lua program of N random calls of string.find, string.match, string.gsub and string.gmatch with random patterns and
# subjects to stdout, each under pcall; run by tests/ast/fuzz.sh.
# usage: scripts/mrb tests/ast/fuzz/gen_pat.rb SEED N
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

ALPHA = "abc12 -_.,"
LITS = ["a", "b", "c", "1", "2", " ", "-", "_", ".", ","]
CLASSES = ["%a", "%d", "%s", "%w", "%l", "%u", "%p", "%x", "%A", "%D", "%S", "%W", "."]

def lit
  RND.choice(LITS)
end

def set_
  items = []
  RND.randint(1, 3).times do
    r = RND.random
    if r < 0.3
      items << RND.choice(["a-c", "1-2", "a-b"])
    elsif r < 0.5
      items << RND.choice(CLASSES[0...-1])
    else
      # the first lit() is the condition, the second one (if the first is not one of "-]^%") the item
      first = lit
      items << ("-]^%".include?(first) ? "a" : lit)
    end
  end
  "[" + (RND.random < 0.3 ? "^" : "") + items.join + "]"
end

def single
  r = RND.random
  if r < 0.45
    c = lit
    return (c == "." || c == "-") ? "%" + c : c
  end
  return RND.choice(CLASSES) if r < 0.7
  set_
end

def item
  s = single
  r = RND.random
  return s if r < 0.55
  s + RND.choice(["*", "+", "-", "?"])
end

def pattern(d = 0)
  parts = []
  RND.randint(1, 4).times do
    r = RND.random
    if r < 0.15 && d < 2
      parts << "(" + pattern(d + 1) + ")"
    elsif r < 0.2
      parts << "()"
    elsif r < 0.25
      parts << RND.choice(["%b()", "%f[%w]", "%f[%s]", "%1"])
    else
      parts << item
    end
  end
  pat = parts.join
  pat = "^" + pat if RND.random < 0.15
  pat = pat + "$" if RND.random < 0.15
  pat
end

def subject
  n = RND.randint(0, 12)
  Array.new(n) { RND.choice(ALPHA) }.join
end

# a Lua single-quoted string literal of S (backslash and quote escaped)
def q(s)
  body = ""
  s.each_char do |c|
    body << (c == "\\" ? "\\\\" : (c == "'" ? "\\'" : c))
  end
  "'" + body + "'"
end

out = ["local function show(...) local t = table.pack(...) for i = 1, t.n do t[i] = tostring(t[i]) end print(table.concat(t, ' | ')) end",
       "local function try(f, ...) local r = table.pack(pcall(f, ...)) if not r[1] then r[2] = tostring(r[2]):gsub('^[^:]*:%d+: ', '') end show(table.unpack(r, 1, r.n)) end"]
N.times do
  s = q(subject)
  pat = q(pattern)
  k = RND.random
  if k < 0.25
    out << format("try(string.find, %s, %s%s)", s, pat, RND.choice(["", ", 2", ", -3", ", 1, true"]))
  elsif k < 0.5
    out << format("try(string.match, %s, %s%s)", s, pat, RND.choice(["", ", 2", ", -2"]))
  elsif k < 0.75
    repl = RND.choice(["'<%0>'", "'%1'", "''", "'x'", "{a='A', b=false}", "function(...) return select('#', ...) end", "function(a) return a end"])
    out << format("try(string.gsub, %s, %s, %s%s)", s, pat, repl, RND.choice(["", ", 2", ", 0"]))
  else
    out << format("try(function() local t = {} for a, b in string.gmatch(%s, %s) do t[#t + 1] = tostring(a) .. ':' .. tostring(b) end return table.concat(t, ',') end)", s, pat)
  end
end
print(out.join("\n") + "\n")
