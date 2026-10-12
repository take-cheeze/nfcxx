-- Recursive functions and the sites that call them: direct and mutual recursion, a recursive function called from a loop, a small
-- function that calls a recursive one, recursion that never ends (the depth limit still applies to calls that were inlined), and a
-- recursion that is deep but legal.
print("-- direct recursion")
local function fact(n) if n <= 1 then return 1 end return n * fact(n - 1) end
local function fib(n) if n < 2 then return n end return fib(n - 1) + fib(n - 2) end
local function sumto(n) if n == 0 then return 0 end return n + sumto(n - 1) end
local function pow2(n) return n == 0 and 1 or 2 * pow2(n - 1) end
local function gcd(a, b) if b == 0 then return a end return gcd(b, a % b) end
local function ack(m, n)
  if m == 0 then return n + 1 end
  if n == 0 then return ack(m - 1, 1) end
  return ack(m - 1, ack(m, n - 1))
end
for i = 0, 10 do print(i, fact(i), fib(i), sumto(i), pow2(i)) end
print(fact(20), fib(20), sumto(100), gcd(48, 18), gcd(17, 5), gcd(0, 9), ack(2, 3))

print("-- mutual recursion")
local even, odd
function even(n) if n == 0 then return true end return odd(n - 1) end
function odd(n) if n == 0 then return false end return even(n - 1) end
for i = 0, 9 do print(i, even(i), odd(i)) end
print(even(100), odd(101), even(7), odd(8))

print("-- a recursion that builds a table and one that passes functions")
local function range(n, acc) acc = acc or {}; if n == 0 then return acc end acc[#acc + 1] = n; return range(n - 1, acc) end
local function map(f, t, i, out) i = i or 1; out = out or {}; if i > #t then return out end out[i] = f(t[i]); return map(f, t, i + 1, out) end
local function double(x) return x * 2 end
for i = 1, 5 do print(table.concat(map(double, range(i + 2)), ",")) end

print("-- small helpers around a recursive function")
local function twice(n) return fib(n) + fib(n) end
local function wrap(n) return twice(n) - fact(n % 5) end
for i = 1, 8 do print(wrap(i), twice(i)) end

print("-- recursion with errors in the middle")
local function down(n)
  if n == 0 then error("bottom") end
  return down(n - 1)
end
local function down2(n)
  if n == 0 then error("bottom2", 2) end
  return (down2(n - 1))        -- not a tail call: the frame of each level stays
end
local function down3(n)
  if n == 0 then error("bottom3", 2) end
  return down3(n - 1)          -- a tail call: level 2 is the caller of the first call
end
for i = 0, 5 do
  print(pcall(down, i))
  print(pcall(down2, i))
  print(pcall(down3, i))
end
local function bad(n) if n == 0 then return nil + 1 end return bad(n - 1) end
for i = 0, 4 do print(pcall(bad, i)) end

print("-- runaway recursion is a stack overflow whatever was inlined")
local function inf(n) return inf(n + 1) + 1 end
local function inf2(n) return inf3(n) + 1 end
function inf3(n) return inf2(n + 1) + 1 end
local function leaf(n) return n end
local function inf4(n) return leaf(inf4(n + 1)) end
for i = 1, 3 do
  local ok, e = pcall(inf, 1)
  print(ok, type(e), tostring(e):find("stack overflow", 1, true) ~= nil)
  ok, e = pcall(inf2, 1)
  print(ok, type(e), tostring(e):find("stack overflow", 1, true) ~= nil)
  ok, e = pcall(inf4, 1)
  print(ok, type(e), tostring(e):find("stack overflow", 1, true) ~= nil)
  print(fact(5), fib(10))      -- the interpreter is fine afterwards
end

print("-- deep but legal")
local function depth(n) if n == 0 then return 0 end return 1 + depth(n - 1) end
for i = 1, 3 do print(depth(100 * i), depth(150)) end
print(depth(1000))
