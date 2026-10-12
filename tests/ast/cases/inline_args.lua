-- Small functions called from sites that run many times (the engine inlines them): argument count adjustment, the order in
-- which the callee and the arguments are evaluated, multiple values in the last argument, results adjusted by the caller.
-- Every site below runs 6 times, past the point where the engine rewrites it.
local log = {}
local function mark(tag, v) log[#log + 1] = tag; return v end
local function flush(label) print(label, table.concat(log, ",")); log = {} end

local function first(a, b) return a end
local function second(a, b) return b end
local function sum(a, b, c) return (a or 0) + (b or 0) + (c or 0) end
local function two(a, b) return a, b end
local function none() return 1 end
local function nothing() end
local function pass(...) return ... end   -- a vararg function: never inlined, produces the multiple values

print("-- fewer arguments than parameters: the rest are nil")
for i = 1, 6 do
  print(i, sum(i), sum(i, i), sum(i, i, i), first(), first(i), second(i), second(i, i + 1))
end

print("-- more arguments than parameters: evaluated, in order, then dropped")
for i = 1, 6 do
  local r = first(mark("a" .. i, i), mark("b" .. i, i + 1), mark("c" .. i, i + 2))
  print(i, r, none(mark("d" .. i, 0), mark("e" .. i, 0)))
end
flush("order")

print("-- the callee expression is evaluated before the arguments")
local function getf(tag, f) mark(tag, 0); return f end
for i = 1, 6 do
  print(i, getf("f" .. i, first)(mark("x" .. i, i), mark("y" .. i, 0)), getf("g" .. i, sum)(mark("p" .. i, 1), mark("q" .. i, 2)))
end
flush("order")

print("-- a call as the last argument contributes all its values")
for i = 1, 6 do
  print(sum(pass(i, i + 1, i + 2, i + 3)), first(pass()), second(pass(i)), sum(two(i, 10)), sum(1, two(i, 10)), sum(two(i, 10), 1))
end

print("-- results of the callee as the caller sees them")
for i = 1, 6 do
  print((two(i, 2)))
  local x, y, z = two(i, i * 2)
  print(x, y, z)
  local t = {two(i, 1), two(i, 2)}
  print(#t, t[1], t[2], t[3])
  print(select('#', none(), none()), select('#', nothing()), select('#', (nothing())), select('#', two(1, 2)))
  print(two(i, 1), two(i, 2))
end

print("-- arguments with side effects, and calls nested in arguments")
local k = 0
local function inc() k = k + 1; return k end
for i = 1, 6 do
  print(sum(inc(), inc(), inc()), sum(sum(i, 1), sum(i, 2), sum(sum(i, i), sum(i, i, i))))
end
print(k)

print("-- the callee changes its parameters; the caller's variables are untouched")
local function bump(x) x = x + 1; return x end
local function swap(a, b) a, b = b, a; return a, b end
local v = 10
for i = 1, 6 do
  print(bump(v), v, bump(bump(v)), v, swap(i, v))
end

print("-- the same function from several sites with different argument counts")
local function opt(a, b) if b == nil then return a end return a + b end
for i = 1, 6 do
  print(opt(i), opt(i, i), opt(i, nil), opt(i, 2), opt(opt(i), opt(i, i)))
end
