-- Parameter substitution in inlined calls: an argument that is a local, a constant or an upvalue is not copied to a slot of the
-- callee but read where it is (when the callee never assigns the parameter). Every site runs many times, past the point where
-- the engine rewrites it; the results, the order of evaluation and the error messages must be those of a real call.
local log = {}
local function mark(tag, v) log[#log + 1] = tag; return v end
local function flush(label) print(label, table.concat(log, ",")); log = {} end
local function try(f, ...)
  local r = table.pack(pcall(f, ...))
  for i = 1, r.n do r[i] = tostring(r[i]) end
  print(table.concat(r, " "))
end

local function sq(x) return x * x end
local function add3(a, b, c) return a + b + c end
local function pick(c, a, b) if c then return a end return b end
local function bump(x) x = x + 1 return x end            -- assigns its parameter: not substituted
local function twice(x, y) y = y or x return x + y end   -- assigns the second
local function first(a) return a end

print("-- locals, constants and expressions as arguments")
for i = 1, 8 do
  local x, y = i, i * 2
  print(sq(x), sq(3), sq(x + 1), add3(x, y, 100), add3(1, 2, 3), add3(x, 5, y), pick(x > 4, x, y), pick(false, x, "b"))
  print(bump(x), bump(7), twice(x), twice(x, y), twice(2, nil), first(x), first("s"), first())
end

print("-- the same local twice, one parameter assigned")
for i = 1, 6 do
  local x = i
  print(twice(x, x), add3(x, x, x), bump(x) + x)
end

print("-- evaluation order with side effects between the pure arguments")
local u = 10
local function setu(v) u = v; return v end
local function sum2(a, b) return a + b end
for i = 1, 6 do
  local x = i
  print(sum2(u, setu(i)), sum2(setu(i * 2), u), add3(u, setu(0), u), add3(x, mark("m" .. i, 1), x))
end
flush("order")

print("-- a captured local is a cell: read at the call")
local cap = 1
local function chg() cap = cap + 1 end
local function readafter(a) chg() return a + cap end
for i = 1, 6 do print(readafter(cap), cap) end

print("-- an upvalue the callee changes")
local up = 1
local function upd(a) up = up + 100 return a + up end
for i = 1, 6 do print(upd(up), up) end

print("-- errors name the parameter of the callee, whatever was passed")
local function neg(v) return -v end
local function idx(t, k) return t[k] end
local function callit(f) return f() end
local function cat(a, b) return a .. b end
local nilv, tab = nil, {}
for i = 1, 6 do
  try(neg, nilv); try(function() return neg(nilv) end)
  try(function() return neg("abc") end); try(function() return neg({}) end)
  try(function() return idx(nilv, 1) end); try(function() return idx(tab, 1) end); try(function() return idx(5, "x") end)
  try(function() return callit(nilv) end); try(function() return callit(3) end); try(function() return callit(tab) end)
  try(function() return cat(nilv, "a") end); try(function() return cat("a", tab) end); try(function() return cat(1, 2) end)
  try(function() return sq(nilv) end); try(function() return sq("x") end); try(function() return sq(true) end)
end

print("-- chains: a local passed down through several inlined bodies")
local function l4(z) return z + 1 end
local function l3(y) return l4(y) * 2 end
local function l2(x) return l3(x) + l3(x + 1) end
local function l1(w) return l2(w) - l2(3) end
for i = 1, 8 do local v = i; print(l1(v), l1(10), l3(v), l4(l4(v))) end
local function e4(z) return z.x end
local function e3(y) return e4(y) end
local function e2(x) return e3(x) end
for i = 1, 6 do try(function() return e2(tab) end); try(function() return e2(nilv) end); try(function() return e2(i) end) end

print("-- recursion with a substituted parameter")
local function fib(n) if n < 2 then return n end return fib(n - 1) + fib(n - 2) end
local function fact(n) if n <= 1 then return 1 end return n * fact(n - 1) end
for i = 1, 6 do local n = i + 6; print(fib(n), fact(n), fib(i)) end

print("-- methods: arguments are locals and constants")
local C = {}
C.__index = C
function C:add(a, b) return self.v + a + b end
function C:get() return self.v end
function C:set(v) self.v = v return self end
function C:both(o, k) return self.v + o.v + k end
local o1, o2 = setmetatable({v = 1}, C), setmetatable({v = 20}, C)
for i = 1, 8 do
  local a = i
  print(o1:add(a, 1), o1:add(2, a), o2:both(o1, a), o1:set(a):get(), o2:both(o2, 5), o1:get(a, a))
end
for i = 1, 6 do try(function() return o1:add(nilv, 1) end); try(function() return o1:both(nilv, i) end) end

print("-- the site meets another function: the substituted values must reach it")
local fs = {function(x, y) return x - y end, function(x, y) return x * y end, math.max, function(x) return x end}
local function gen(f, a) return f(a, 3) end
for round = 1, 3 do
  for k = 1, #fs do
    local acc = 0
    for i = 1, 6 do local v = i; acc = acc + gen(fs[k], v) + gen(fs[k], 4) end
    print(round, k, acc)
  end
end
local function callsite(f) local a = 7; return f(a, 2, "k") end
for r = 1, 8 do
  print(callsite(function(x, y, z) return x + y .. z end), callsite(function(x) return x end), callsite(function() return "none" end),
        callsite(function(x, y, z, w) return tostring(w) end))
end

print("-- fewer and more arguments than parameters with pure arguments")
local function one(a) return a end
local function four(a, b, c, d) return tostring(a) .. tostring(b) .. tostring(c) .. tostring(d) end
for i = 1, 8 do
  local x = i
  print(one(), one(x), one(x, x, x), one(1, 2, 3, 4, 5), four(x), four(x, x, "c"), four(x, 2, 3, 4, x, x), four())
end
