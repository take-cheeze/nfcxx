# gen_kernel.rb: port of tests/ast/fuzz/gen_kernel.py for mruby (run by tests/ast/fuzz_tier.sh through scripts/mrb).
# Random numeric kernels for differential testing of the tier (tests/ast/fuzz_tier.sh).
#
# usage: scripts/mrb tests/ast/fuzz/gen_kernel.rb SEED [FUNCTIONS [SEGMENTS]]
#
# Prints a Lua program: FUNCTIONS (default 10) well-typed functions over integers, floats, booleans and "numbers" (variables,
# parameters and results that are an integer in one place and a float in another; type n below) (arithmetic, bitwise
# operators, comparisons, locals, if / while / repeat / numeric for / break / return, calls of earlier functions, some of them
# recursive), each called with a number of argument tuples, some of the wrong type, through pcall; the results and the error
# messages are printed. The tier compiles these functions, so the output has to be the same as a real Lua's.
# The draws come from Rng (xorshift64 seeded by SEED), not from Python's random module, so the program for a given seed is not
# the Python original's; the grammar and the order of the draws are the same. With no SEGMENTS argument the count of segments
# is drawn, as in the original.

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

  # two distinct elements of SEQ: one, then one of the others
  def sample2(seq)
    i = (u * seq.size).floor
    a = seq[i]
    rest = seq[0, i] + seq[i + 1..-1]
    j = (u * (seq.size - 1)).floor
    [a, rest[j]]
  end
end

SEED = ARGV.size > 0 ? ARGV[0].to_i : 1
NFUNCS = ARGV.size > 1 ? ARGV[1].to_i : 10
RND = Rng.new(SEED)

INT_LITS = ['0', '1', '-1', '2', '3', '5', '7', '10', '16', '63', '64', '100', '255', '65535', '2147483647', '4294967296',
            '9223372036854775807', '(-9223372036854775807 - 1)', '(1 << 62)', '9007199254740993', '-7', '-100']
FLT_LITS = ['0.0', '1.0', '0.5', '-2.5', '3.14159', '1e10', '-1e-5', '2.0', '100.25', '9007199254740992.0', '1e15', '(1e308 * 10)',
            '(-1e308 * 10)', '0.1', '-0.0']

class Func
  attr_accessor :name, :params, :ret, :level, :self_ok

  def initialize(name, params, ret, level)
    @name = name
    @params = params  # list of [name, type]
    @ret = ret
    @level = level  # a function calls only functions of a lower level, so the cost of a call is bounded
    @self_ok = false
  end
end

CUR_LEVEL = [0]
ALLOW_N = [true]
BUDGET = [0]       # calls of other functions this function may still contain (the cost of a call is bounded this way)
SELF_BUDGET = [0]  # and of itself

FUNCS = []  # callable earlier functions
TMP_COUNTER = [0]

def fresh(prefix)
  TMP_COUNTER[0] += 1
  format("%s%d", prefix, TMP_COUNTER[0])
end

def lit(t)
  t = RND.choice(['i', 'f']) if t == 'n'
  return RND.choice(INT_LITS) if t == 'i'
  return RND.choice(FLT_LITS) if t == 'f'
  RND.choice(['true', 'false'])
end

# numeric and boolean upvalues of the chunk and globals: free variables of the kernels, changed between the calls
UPS = [['u1', 'i'], ['u2', 'f'], ['u3', 'b'], ['g1', 'i'], ['g2', 'f']]

def count_of_type(env, t)
  n = 0
  env.each { |_, tt| n += 1 if tt == t }
  n
end

def vars_of(env, t)
  r = []
  env.each { |v, vt| r << v if vt == t }
  UPS.each { |v, vt| r << v if vt == t }
  if ['i', 'f'].include?(t) && ALLOW_N[0] && RND.random < 0.35
    env.each { |v, vt| r << v if vt == 'n' }  # a number of either kind where one of a given kind is wanted
  end
  r
end

def gen_expr(env, t, depth, self_fn = nil)
  # An expression of static type T (i, f, b, or n: an integer or a float, as it falls).
  if t == 'n'
    t = RND.choice(['i', 'f', 'f'])
    if depth > 1 && RND.random < 0.3
      vs = vars_of(env, 'n')
      return RND.choice(vs) unless vs.empty?
    end
  end
  leaf = depth <= 0 || RND.random < 0.18
  if t == 'b'
    if leaf
      vs = vars_of(env, 'b')
      return RND.choice(vs) if !vs.empty? && RND.random < 0.6
      return lit('b') if RND.random < 0.5
    end
    k = RND.random
    if k < 0.45
      lt = RND.choice(['i', 'f'])
      rt = RND.choice(['i', 'f'])
      op = RND.choice(['<', '<=', '>', '>=', '==', '~='])
      return format('(%s %s %s)', gen_expr(env, lt, depth - 1, self_fn), op, gen_expr(env, rt, depth - 1, self_fn))
    end
    if k < 0.6
      return format('(not %s)', gen_expr(env, 'b', depth - 1, self_fn))
    end
    if k < 0.8
      return format('(%s %s %s)', gen_expr(env, 'b', depth - 1, self_fn), RND.choice(['and', 'or']), gen_expr(env, 'b', depth - 1, self_fn))
    end
    if k < 0.9
      return format('(%s == %s)', gen_expr(env, 'b', depth - 1, self_fn), gen_expr(env, 'b', depth - 1, self_fn))
    end
    return call_expr(env, 'b', depth, self_fn) || lit('b')
  end
  if leaf
    vs = vars_of(env, t)
    return RND.choice(vs) if !vs.empty? && RND.random < 0.65
    return lit(t)
  end
  k = RND.random
  if t == 'i'
    if k < 0.30
      op = RND.choice(['+', '-', '*'])
      return format('(%s %s %s)', gen_expr(env, 'i', depth - 1, self_fn), op, gen_expr(env, 'i', depth - 1, self_fn))
    end
    if k < 0.42
      op = RND.choice(['//', '%'])
      d = gen_expr(env, 'i', depth - 1, self_fn)
      d = RND.choice(['3', '7', '-2', '10', '1', '-1']) if RND.random < 0.5
      return format('(%s %s %s)', gen_expr(env, 'i', depth - 1, self_fn), op, d)
    end
    if k < 0.60
      op = RND.choice(['&', '|', '~', '<<', '>>'])
      r = gen_expr(env, 'i', depth - 1, self_fn)
      if (op == '<<' || op == '>>') && RND.random < 0.6
        r = RND.choice(['0', '1', '3', '31', '32', '63', '64', '65', '-1', '-64'])
      end
      return format('(%s %s %s)', gen_expr(env, 'i', depth - 1, self_fn), op, r)
    end
    return format('(- %s)', gen_expr(env, 'i', depth - 1, self_fn)) if k < 0.68
    return format('(~ %s)', gen_expr(env, 'i', depth - 1, self_fn)) if k < 0.74
    c = call_expr(env, 'i', depth, self_fn)
    return c || lit('i')
  end
  # float
  if k < 0.30
    op = RND.choice(['+', '-', '*'])
    a, b = RND.choice([['f', 'f'], ['f', 'i'], ['i', 'f']])
    return format('(%s %s %s)', gen_expr(env, a, depth - 1, self_fn), op, gen_expr(env, b, depth - 1, self_fn))
  end
  if k < 0.45
    a, b = RND.choice([['f', 'f'], ['i', 'i'], ['f', 'i'], ['i', 'f']])
    return format('(%s / %s)', gen_expr(env, a, depth - 1, self_fn), gen_expr(env, b, depth - 1, self_fn))
  end
  if k < 0.55
    a, b = RND.choice([['f', 'f'], ['f', 'i'], ['i', 'f']])
    return format('(%s %s %s)', gen_expr(env, a, depth - 1, self_fn), RND.choice(['//', '%']), gen_expr(env, b, depth - 1, self_fn))
  end
  if k < 0.62
    a = RND.choice(['f', 'i'])
    return format('(%s ^ %s)', gen_expr(env, a, depth - 1, self_fn), RND.choice(['2', '0.5', '3', '-1', '2.0', gen_expr(env, 'f', depth - 1, self_fn)]))
  end
  return format('(- %s)', gen_expr(env, 'f', depth - 1, self_fn)) if k < 0.68
  c = call_expr(env, 'f', depth, self_fn)
  c || lit('f')
end

def call_expr(env, t, depth, self_fn)
  cands = []
  if BUDGET[0] > 0
    FUNCS.each do |f|
      ok = f.ret == t || (f.ret == 'n' && ['i', 'f'].include?(t) && RND.random < 0.5)
      cands << f if ok && f.level < CUR_LEVEL[0]
    end
  end
  if self_fn && (self_fn.ret == t || (self_fn.ret == 'n' && ['i', 'f'].include?(t))) && self_fn.self_ok && SELF_BUDGET[0] > 0
    cands << self_fn
  end
  return nil if cands.empty?
  f = RND.choice(cands)
  if f.equal?(self_fn)
    SELF_BUDGET[0] -= 1
  else
    BUDGET[0] -= 1
  end
  args = []
  f.params.each do |pname, pt|
    if f.equal?(self_fn) && pt == 'i' && pname == 'd'
      args << '(d - 1)'
    elsif pt == 'i' && pname == 'd'
      args << RND.choice(['0', '1', '2'])  # the depth of a recursive function: small, or the calls would never end
    else
      args << gen_expr(env, pt, depth - 1, self_fn)
    end
  end
  format('%s(%s)', f.name, args.join(', '))
end

# the names that are not assigned: loop counters and the depth of a recursive function
def protected_name?(v)
  return true if v == 'd'
  return false unless v.start_with?('c') && v.size > 1
  digits = v[1..-1]
  digits.each_char { |c| return false unless c >= '0' && c <= '9' }
  true
end

def self_tail_call(f, env)
  # `return f(d - 1, ...)`: the depth goes down, the other arguments are whatever the function takes
  args = []
  f.params.each do |pname, pt|
    if pt == 'i' && pname == 'd'
      args << '(d - 1)'
    else
      args << gen_expr(env, pt, 2, f)
    end
  end
  format('%s(%s)', f.name, args.join(', '))
end

def void_call(env, pad, out)
  cands = FUNCS.select { |f| f.ret == 'v' && f.level < CUR_LEVEL[0] }
  return false if cands.empty? || BUDGET[0] <= 0
  BUDGET[0] -= 1
  f = RND.choice(cands)
  out << format('%s%s(%s)', pad, f.name, f.params.map { |_, pt| gen_expr(env, pt, 2, nil) }.join(', '))
  true
end

def gen_block(env, ret, depth, indent, in_loop, self_fn, nstmts)
  # Statements; the returned text may end in a return. ENV is extended by the declarations (a copy is used by inner blocks).
  out = []
  pad = '  ' * indent
  nstmts.times do
    k = RND.random
    if k < 0.26
      t = RND.choice(['i', 'i', 'f', 'f', 'b', 'n', 'n'])
      n = fresh('l')
      if t == 'n'
        out << format('%slocal %s = %s', pad, n, gen_expr(env, 'i', 3, self_fn))  # starts as an integer; assigned floats later
      else
        out << format('%slocal %s = %s', pad, n, gen_expr(env, t, 3, self_fn))
      end
      env[n] = t
    elsif k < 0.46
      if RND.random < 0.15  # an assignment to an upvalue of the chunk: a kernel may make it (on a copy, written back at the end of the call)
        u, t = RND.choice(UPS.select { |x| x[0].start_with?('u') })
        if RND.random < 0.3
          u2, t2 = RND.choice(UPS.select { |x| x[0].start_with?('u') && x[1] == t })
          if u2 != u
            out << format('%s%s, %s = %s, %s', pad, u, u2, gen_expr(env, t, 3, self_fn), gen_expr(env, t, 3, self_fn))
            next
          end
        end
        out << format('%s%s = %s', pad, u, gen_expr(env, t, 3, self_fn))
        next
      end
      cand = env.to_a
      unless cand.empty?
        v, t = RND.choice(cand)
        next if protected_name?(v)
        if RND.random < 0.15 && count_of_type(env, t) >= 2
          # multiple assignment
          vs = []
          env.each { |x, tt| vs << x if tt == t && !protected_name?(x) }
          if vs.size >= 2
            a, b = RND.sample2(vs)
            out << format('%s%s, %s = %s, %s', pad, a, b, gen_expr(env, t, 3, self_fn), gen_expr(env, t, 3, self_fn))
            next
          end
        end
        out << format('%s%s = %s', pad, v, gen_expr(env, t, 3, self_fn))
      end
    elsif k < 0.58 && depth > 0
      n = RND.choice([1, 2, 3])
      parts = [format('%sif %s then', pad, gen_expr(env, 'b', 3, self_fn))]
      parts << gen_block(env.dup, ret, depth - 1, indent + 1, in_loop, self_fn, RND.choice([1, 2]))
      if n >= 2
        parts << format('%selseif %s then', pad, gen_expr(env, 'b', 3, self_fn))
        parts << gen_block(env.dup, ret, depth - 1, indent + 1, in_loop, self_fn, 1)
      end
      if n == 3 || RND.random < 0.3
        parts << format('%selse', pad)
        parts << gen_block(env.dup, ret, depth - 1, indent + 1, in_loop, self_fn, 1)
      end
      parts << format('%send', pad)
      out << parts.join("\n")
    elsif k < 0.70 && depth > 0
      kind = RND.choice(['int', 'int', 'float', 'cnt'])
      e2 = env.dup
      v = fresh('c')
      if kind == 'int'
        start = RND.choice(['1', '0', '-3', '5', gen_expr(env, 'i', 1, self_fn) + ' % 7'])
        limit = RND.choice(['3', '5', '0', '-2', format('(%s) %% 5', gen_expr(env, 'i', 2, self_fn)), format('(%s) %% 4.5', gen_expr(env, 'f', 2, self_fn))])
        step = RND.choice(['', '', ', 1', ', 2', ', -1', ', 3', ', -2'])
        if step.start_with?(', -') && limit.include?('%')
          # a computed limit that is NaN makes `for i = 0, 0/0, -1` count down to the smallest integer (as in Lua): it
          # would not end, so a computed limit stays out of loops that count down
          limit = RND.choice(['-3', '-5', '0', '-2'])
        end
        e2[v] = 'i'
        body = gen_block(e2, ret, depth - 1, indent + 1, true, self_fn, RND.choice([1, 2, 3]))
        out << format("%sfor %s = %s, %s%s do\n%s\n%send", pad, v, start, limit, step, body, pad)
      elsif kind == 'float'
        e2[v] = 'f'
        body = gen_block(e2, ret, depth - 1, indent + 1, true, self_fn, RND.choice([1, 2]))
        out << format("%sfor %s = %s, %s, %s do\n%s\n%send", pad, v, RND.choice(['0.5', '0.0', '1.0', '-1.5']), RND.choice(['3', '2.5', '4.0']), RND.choice(['0.5', '1', '0.75']), body, pad)
      else
        cnt = fresh('c')
        out << format('%slocal %s = 0', pad, cnt)
        e2[cnt] = 'i'
        w = RND.choice(['while', 'repeat'])
        if w == 'while'
          cond = gen_expr(e2, 'b', 2, self_fn)
          body = gen_block(e2, ret, depth - 1, indent + 1, true, self_fn, RND.choice([1, 2]))
        else
          body = gen_block(e2, ret, depth - 1, indent + 1, true, self_fn, RND.choice([1, 2]))
          cond = gen_expr(e2, 'b', 2, self_fn)
        end
        inc = format('%s  %s = %s + 1', pad, cnt, cnt)
        if w == 'while'
          out << format("%swhile %s < 6 and %s do\n%s\n%s\n%send", pad, cnt, cond, inc, body, pad)
        else
          out << format("%srepeat\n%s\n%s\n%suntil %s >= 5 or %s", pad, inc, body, pad, cnt, cond)
        end
      end
    elsif k < 0.76 && in_loop
      out << format('%sif %s then break end', pad, gen_expr(env, 'b', 2, self_fn))
    elsif k < 0.84 && !ret.nil?
      if ret == 'v'
        out << format('%sif %s then return end', pad, gen_expr(env, 'b', 2, self_fn))
      else
        out << format('%sif %s then return %s end', pad, gen_expr(env, 'b', 2, self_fn), gen_expr(env, ret, 3, self_fn))
      end
    elsif k < 0.90 && void_call(env, pad, out)
      # the call is appended by void_call
    else
      t = RND.choice(['i', 'f'])
      n = fresh('l')
      out << format('%slocal %s = %s', pad, n, gen_expr(env, t, 2, self_fn))
      env[n] = t
    end
  end
  out << format('%slocal _ = 0', pad) if out.empty?
  out.join("\n")
end

def gen_func(idx)
  name = format('k%d', idx)
  nparams = RND.choice([1, 2, 2, 3])
  params = []
  recursive = RND.random < 0.3
  params << ['d', 'i'] if recursive
  ['a', 'b', 'c'][0...nparams].each do |p|
    params << [p, RND.choice(['i', 'i', 'f', 'f', 'b', 'n'])]
  end
  ret = RND.choice(['i', 'i', 'f', 'f', 'b', 'v', 'n', 'n'])
  level = [idx, RND.choice([0, 1, 1, 2, 2, 3])].min
  CUR_LEVEL[0] = level
  BUDGET[0] = 2
  SELF_BUDGET[0] = 2
  f = Func.new(name, params, ret, level)
  f.self_ok = recursive
  env = {}
  params.each { |p, t| env[p] = t }
  lines = [format('local function %s(%s)', name, params.map { |p, _| p }.join(', '))]
  if recursive && ret == 'v'
    recursive = false
    f.self_ok = false  # a recursive function without a value: nothing to recurse into
  end
  if recursive
    lines << format('  if d <= 0 then return %s end', gen_expr(env.dup, ret, 2, nil))
  end
  lines << gen_block(env, ret, 2, 1, false, nil, RND.choice([2, 3, 4, 5]))
  if ret != 'v'
    if recursive && RND.random < 0.5  # a tail call of the function itself: a loop in the tier (docs/notes/ast.md, Tiering)
      lines << format('  return %s', self_tail_call(f, env))
    else
      lines << format('  return %s', gen_expr(env, ret, 3, recursive ? f : nil))
    end
  end
  lines << 'end'
  [f, lines.join("\n")]
end

def arg_for(t, wrong)
  if t == 'n'
    t = RND.choice(['i', 'f'])
    wrong = wrong && RND.random < 0.3
  end
  t = RND.choice(['i', 'f', 'b'].reject { |x| x == t }) if wrong
  if t == 'i'
    return RND.choice(['0', '1', '-1', '2', '5', '7', '-3', '100', '65536', '9223372036854775807', '(-9223372036854775807 - 1)', '3037000500', '64'])
  end
  if t == 'f'
    return RND.choice(['0.0', '1.5', '-2.5', '0.1', '3.0', '1e10', '2.0', '-0.5', '100.75'])
  end
  RND.choice(['true', 'false'])
end

def seg_loop(env, ret, indent)
  # A loop statement for an on-stack-replacement segment: the kind and the counts vary, the body is random.
  pad = '  ' * indent
  e2 = env.dup
  v = fresh('c')
  kind = RND.choice(['for', 'for', 'forstep', 'fordown', 'forflt', 'while', 'repeat'])
  if ['for', 'forstep', 'fordown'].include?(kind)
    e2[v] = 'i'
  elsif kind == 'forflt'
    e2[v] = 'f'
  end
  body = gen_block(e2, ret, 2, indent + 1, true, nil, RND.choice([2, 3, 4]))
  if kind == 'for'
    return format("%sfor %s = %s, %s do\n%s\n%send", pad, v, RND.choice(['1', '0', '-2', '3']), RND.choice(['1', '2', '3', '7', '20', '50']), body, pad)
  end
  if kind == 'forstep'
    return format("%sfor %s = %s, %s, %s do\n%s\n%send", pad, v, RND.choice(['1', '0', '-5']), RND.choice(['9', '30', '60']), RND.choice(['2', '3', '7']), body, pad)
  end
  if kind == 'fordown'
    return format("%sfor %s = %s, %s, %s do\n%s\n%send", pad, v, RND.choice(['10', '40', '3']), RND.choice(['1', '-3', '2']), RND.choice(['-1', '-2', '-3']), body, pad)
  end
  if kind == 'forflt'
    return format("%sfor %s = %s, %s, %s do\n%s\n%send", pad, v, RND.choice(['0.5', '0.0', '1.0', '-1.5']), RND.choice(['3', '9.5', '20.0']), RND.choice(['0.5', '1', '0.75', '0.25']), body, pad)
  end
  cnt = fresh('c')
  pre = format("%slocal %s = 0\n", pad, cnt)
  e2[cnt] = 'i'
  if kind == 'while'
    cond = gen_expr(e2, 'b', 2, nil)
    return format("%s%swhile %s < %s and %s do\n%s  %s = %s + 1\n%s\n%send", pre, pad, cnt, RND.choice(['3', '8', '30']), cond, pad, cnt, cnt, body, pad)
  end
  cond = gen_expr(e2, 'b', 2, nil)
  format("%srepeat\n%s  %s = %s + 1\n%s\n%suntil %s >= %s or %s", pre + pad, pad, cnt, cnt, body, pad, cnt, RND.choice(['3', '8', '30']), cond)
end

def gen_segment(idx)
  # A function that is not a kernel as a whole (it makes a table) and so is only ever compiled by its loops: locals of all four
  # types, a few loops that read and assign them, and a result. It is called three times with arguments that vary.
  name = format('seg%d', idx)
  CUR_LEVEL[0] = 99
  BUDGET[0] = 2
  SELF_BUDGET[0] = 0
  params = [['a', RND.choice(['i', 'f', 'n'])], ['b', RND.choice(['i', 'f', 'b'])]]
  env = {}
  params.each { |p, t| env[p] = t }
  lines = ['local function ' + name + '(a, b)', '  local _tab = {}']
  # a local that a closure captures (it lives in a cell, and a loop that uses it hands it over through the cell), and a local
  # function that the loops may call
  lines << format('  local cap = %s', gen_expr(env, 'i', 2, nil))
  lines << '  local function capget() return cap end'
  env['cap'] = 'i'
  lf = Func.new('lf', [['x', 'i']], 'i', 0)
  lines << format('  local function lf(x) return %s end', gen_expr({ 'x' => 'i' }, 'i', 2, nil))
  FUNCS << lf
  RND.choice([2, 3, 4]).times do
    t = RND.choice(['i', 'f', 'b', 'n', 'n'])
    n = fresh('s')
    lines << format('  local %s = %s', n, gen_expr(env, t == 'n' ? 'i' : t, 2, nil))
    env[n] = t
  end
  ret = RND.choice([nil, nil, 'i', 'f', 'n'])  # None: the function returns its locals; else a loop may return a value of that type
  RND.choice([1, 2, 2, 3]).times do
    if RND.random < 0.8
      lines << seg_loop(env, ret, 1)
    else
      lines << gen_block(env, ret, 2, 1, false, nil, 2)
    end
  end
  lines << '  _tab[1] = 0'
  FUNCS.delete(lf)
  if ret.nil?
    others = env.keys.reject { |v| v == 'a' || v == 'b' }
    lines << ('  return capget(), ' + (others + ['a', 'b']).join(', '))
  else
    lines << ('  return ' + gen_expr(env, ret, 3, nil))
  end
  lines << 'end'
  [name, lines.join("\n")]
end

def mutate_ups
  u, t = RND.choice(UPS)
  t = RND.choice(['i', 'f', 'b']) if RND.random < 0.15  # a different type: the compiled code assumed the old one
  v = lit(t)
  format('%s = %s', u, v)
end

out = ['local function show(...) print(...) end', 'local u1, u2, u3 = 7, 2.5, true', 'g1, g2 = 5, 0.5']
NFUNCS.times do |i|
  f, text = gen_func(i)
  text = text.sub('local function', 'function') if RND.random < 0.3  # a global function: called through the globals table
  out << text
  FUNCS << f
  RND.choice([4, 6, 8]).times do
    wrong = RND.random < 0.12
    args = []
    f.params.each do |pname, pt|
      if pname == 'd'
        args << RND.choice(['0', '1', '2', '3', '5'])
      else
        args << arg_for(pt, wrong && RND.random < 0.5)
      end
    end
    args.pop if !args.empty? && RND.random < 0.04  # a missing argument is nil
    out << mutate_ups if RND.random < 0.25
    out << format('show("%s", pcall(%s%s))', f.name, f.name, args.map { |a| ', ' + a }.join)
    out << 'show("ups", u1, u2, u3, g1, g2)'
  end
end
# segments for on-stack replacement (after the rest, so that seeds keep their functions)
seg_count = ARGV.size <= 2 ? RND.choice([0, 0, 1, 2, 3]) : ARGV[2].to_i
seg_count.times do |i|
  name, text = gen_segment(i)
  out << text
  3.times do
    a = arg_for(RND.choice(['i', 'f']), false)
    b = arg_for(RND.choice(['i', 'f', 'b']), RND.random < 0.1)
    out << mutate_ups if RND.random < 0.3
    out << format('show("%s", pcall(%s, %s, %s))', name, name, a, b)
    out << 'show("ups", u1, u2, u3, g1, g2)'
  end
end
print(out.join("\n") + "\n")
