-- Callees whose body is more than `return <expr>`: local variables, if chains with returns in some or all branches, assignments to
-- locals, upvalues, globals, fields and array slots, call statements, no result, several results. Also callees the engine leaves
-- as calls (loops, closures, varargs, multiple assignment, large bodies): they must behave the same.
print("-- locals and early returns")
local function sign(x) if x < 0 then return -1 elseif x == 0 then return 0 else return 1 end end
local function abs(x) if x < 0 then return -x end return x end
local function clamp(x, lo, hi)
  local r = x
  if r < lo then r = lo end
  if r > hi then r = hi end
  return r
end
local function mid(a, b, c)
  local lo, hi = a, b
  if lo > hi then lo, hi = hi, lo end
  if c < lo then return lo end
  if c > hi then return hi end
  return c
end
local function classify(n)
  local kind
  if n % 15 == 0 then kind = "fizzbuzz" elseif n % 5 == 0 then kind = "buzz" elseif n % 3 == 0 then kind = "fizz" else kind = tostring(n) end
  return kind, n
end
for i = -3, 18 do
  print(i, sign(i), abs(i), clamp(i, 0, 10), mid(i, 5, 9), classify(i))
end

print("-- falling off the end, and bare returns")
local function nothing() end
local function bare(x) if x then return end end
local function maybe(x) if x > 2 then return x end end
for i = 1, 6 do
  print(select('#', nothing()), select('#', bare(i)), select('#', maybe(i)), maybe(i), (maybe(i)), bare(i), nothing())
  local a, b = maybe(i)
  print(a, b, #{maybe(i)})
end

print("-- assignments in the callee")
local total = 0
local list = {}
local obj = {n = 0, items = {}}
local function addto(x) total = total + x; return total end
function setglobal(v) counter = (counter or 0) + v; return counter end
local function push(t, v) t[#t + 1] = v; return #t end
local function setfield(o, k, v) o[k] = v; o.last = v; return o end
local function record(o, v) o.n = o.n + 1; o.items[o.n] = v * v end
local function swapfields(o) o.a, o.b = o.b, o.a end
for i = 1, 8 do
  print(addto(i), setglobal(i), push(list, i * 2), setfield(obj, "k" .. i % 3, i).last)
  record(obj, i)
end
print(total, counter, #list, list[8], obj.n, obj.items[8], obj.k1, obj.k2, obj.k0)
local sw = {a = 1, b = 2}
for i = 1, 5 do swapfields(sw); print(sw.a, sw.b) end

print("-- call statements and their results are dropped")
local calls = 0
local function side() calls = calls + 1; return calls, "unused" end
local function viaside() side(); side(); return side() end
for i = 1, 6 do
  side()
  print(calls, viaside())
end

print("-- local shadowing and block scopes inside the callee")
local function scopes(x)
  local y = x
  do
    local y = y * 2
    x = x + y
  end
  if x > 10 then
    local y = -1
    x = x + y
  end
  return x, y
end
for i = 1, 8 do print(scopes(i)) end

print("-- a callee that reads a global, a nested table, and a string field")
cfg = {mult = 3, names = {"a", "b", "c"}, label = "L"}
local function scaled(i) return i * cfg.mult end
local function nm(i) local n = cfg.names[i % 3 + 1]; return n .. cfg.label end
for i = 1, 6 do print(scaled(i), nm(i)) end
cfg.mult = 10
cfg.names = {"x", "y"}
print(scaled(2), pcall(nm, 2))
cfg = nil
print(pcall(scaled, 1))

print("-- callees that are not inlined: loops, closures, varargs, multiple assignment into fields, large bodies")
local function loop(n) local s = 0 for i = 1, n do s = s + i end return s end
local function whiles(n) local s = 0 while n > 0 do s = s + n; n = n - 1 end return s end
local function maker(k) return function(x) return x + k end end
local function va(...) return select('#', ...), ... end
local function va2(a, ...) local t = {...} return a, #t end
local function multi(t, a, b) t.x, t.y = a, b; return t end
local function big(x)
  local a = x + 1
  local b = a * 2 - x
  local c = (a + b) * (a - b) + x
  local d = a .. b .. c
  if #d > 6 then a = a + #d elseif #d > 3 then a = a - #d else a = a * 2 end
  b = b + a + c
  c = c - b + a
  a = a + b + c + #d
  return a, b, c, d, a + b, b + c, c + a, a - b, b - c, c - a, a * b, b * c, c * a, (a + b + c) % 7, (a - b - c) % 11
end
for i = 1, 6 do
  print(loop(i), whiles(i), maker(i)(i), va(i, i + 1), va2(i, i, i), multi({}, i, i + 1).y)
  print(big(i))
end

print("-- the callee has a local function that is never called, a method definition, an upvalue declared later")
local late
local function usesLate() return late end
for i = 1, 4 do
  late = i
  print(usesLate())
end
