-- Loops taken over by compiled code in the middle of a call (on-stack replacement, docs/notes/ast.md "Tiering"): with the tier at
-- threshold 1 every loop below is compiled at its first iteration boundary and the rest of the loop runs as native code; the output
-- must be what the interpreter (and real Lua) gives. Loops that are not numeric kernels, loops that fail half way, and the state the
-- locals are in afterwards are the interesting part.

-- 1. the main chunk: integer, float, and "either" accumulators
local s = 0
for i = 1, 1000 do s = s + i % 7 end
print("sum", s)

local f = 0.5
for i = 1, 100 do f = f * 1.01 + i end
print("float", f)

local e = 0                       -- an integer until the loop adds a float: its kind is decided at run time
for i = 1, 10 do e = e + 0.25 end
print("either", e, math.type(e))
local e2 = 5
for i = 1, 10 do if i > 20 then e2 = e2 + 0.5 end end
print("either, never a float", e2, math.type(e2))

local w = 1
for i = 1, 70 do w = w * 3 end    -- wraps
print("wrap", w)

-- 2. while and repeat, break, a boolean live variable
local n, c = 27, 0
while n ~= 1 do
  if n % 2 == 0 then n = n // 2 else n = 3 * n + 1 end
  c = c + 1
end
print("collatz", c)

local k, acc = 0, 0
repeat
  k = k + 1
  local sq = k * k
  if sq > 500 then break end
  acc = acc + sq
until k >= 100
print("repeat", k, acc)

local flag, flips = true, 0
for i = 1, 25 do flag = not flag; if flag then flips = flips + 1 end end
print("boolean", flag, flips)

-- 3. steps, directions, limits
local t = 0
for i = 10, 1, -3 do t = t * 10 + i end
print("down", t)
t = 0
for i = 1, 3.9 do t = t + i end            -- a float limit on an integer loop
print("floor limit", t)
t = 0.0
for x = 0.1, 1.0, 0.1 do t = t + x end     -- a float loop
print("float loop", t)
t = 0
for i = math.maxinteger - 3, math.maxinteger do t = t + 1 end   -- no overflow of the counter
print("maxint", t)
t = 0
for i = math.mininteger, math.mininteger + 2 do t = t + 1 end
print("minint", t)
t = 0
for i = 1, 0 do t = t + 1 end
for i = 5, 5 do t = t + 10 end
print("empty and single", t)
t = 0
for i = 1, 10, 4 do t = t + i end
print("step 4", t)
t = 0
for x = 1, 0, -0.25 do t = t + x end
print("float down", t)
t = 0
for i = 1, 3 do for j = i, 3 do t = t + i * j end end
print("nested", t)

-- 4. what the loop body may call and read: kernels through upvalues and globals, numeric globals and upvalues
local function sq(x) return x * x end
function cube(x) return x * x * x end
scale = 3
local base = 100
local r = 0
for i = 1, 20 do r = r + sq(i) + cube(i) * scale - base end
print("calls", r)
scale = 4.5                      -- another type: the next loop is compiled for it
base = 7
local r2 = 0
for i = 1, 20 do r2 = r2 + cube(i) * scale - base end
print("calls, other types", r2)
function cube(x) return x * x end    -- the callee is another function now
r2 = 0
for i = 1, 20 do r2 = r2 + cube(i) end
print("callee rebound", r2)

-- 5. a function that is called once and runs a hot loop; a return in the loop
local function firstdiv(m)
  for d = 2, m do if m % d == 0 then return d end end
  return m
end
print("firstdiv", firstdiv(1000003), firstdiv(91), firstdiv(97))

local function find(limit)
  local x, y = 0, 1
  while true do
    x, y = y, x + y
    if y > limit then return y, x end
  end
end
print("find", find(1000000))

local function mixed(m)               -- the result is an integer or a float, as the run goes
  local v = 1
  for i = 1, m do
    v = v + 1
    if v > 50 then return v * 0.5 end
  end
  return v
end
print("mixed", mixed(10), mixed(100), math.type(mixed(10)), math.type(mixed(100)))

local function noret(m)
  local v = 0
  for i = 1, m do if i == 40 then return end v = v + i end
  return v
end
print("noret", noret(10), noret(100))

local function two(m)                 -- returns nothing in one place and a value in another: not compiled, still right
  for i = 1, m do if i == 30 then return i end end
end
print("two", two(10), two(100))

-- 6. the locals after the loop are the loop's results; locals the loop does not mention are left alone
local keep = {1, 2, 3}
local text = "kept"
local p, q = 1, 2
for i = 1, 50 do p, q = q, p + q end
print("swap", p, q, #keep, text)
local lastp = p
for i = 1, 3 do lastp = lastp + i end
print("after", lastp)

-- 7. a loop that fails half way: the error, its message and its position are the interpreter's
local function divloop(d)
  local acc = 0
  for i = 1, 100 do acc = acc + 1000 // (d - i) end
  return acc
end
print("divloop ok", divloop(200))
print("divloop", pcall(divloop, 60))
local function modloop(m)
  local acc, i = 0, 0
  while i < 100 do i = i + 1; acc = acc + 17 % (m - i) end
  return acc
end
print("modloop", pcall(modloop, 50))
local function bitloop(x)
  local acc = 0
  for i = 1, 20 do acc = acc + (i & x) end
  return acc
end
print("bitloop", pcall(bitloop, 5), pcall(bitloop, 5.0), pcall(bitloop, 5.5))
local function bits2()
  local x, acc = 1, 0
  for i = 1, 40 do acc = acc ~ (x << i); x = x + 0.5 end
  return acc
end
print("bits2", pcall(bits2))

-- the same loop run again after an error: it still works
print("divloop again", divloop(300), pcall(divloop, 10))

-- 8. an error after a loop that was taken over: the line is right
local ok, msg = pcall(function()
  local z = 0
  for i = 1, 30 do z = z + i end
  return z .. nil
end)
print("after", ok, msg)

-- 9. loops that are not kernels stay as they are
local tab = {}
for i = 1, 20 do tab[i] = i * i end
local ts = 0
for i = 1, #tab do ts = ts + tab[i] end
print("table", ts)
local str = ""
for i = 1, 10 do str = str .. i end
print("string", str)
local cl = {}
for i = 1, 3 do cl[i] = function() return i end end
print("closures", cl[1](), cl[2](), cl[3]())
local cnt = 0
local function bump() cnt = cnt + 1 end
for i = 1, 10 do bump() end
print("upvalue write", cnt)
for i = 1, 3 do local m = math.max(i, 2); cnt = cnt + m end
print("native call", cnt)

-- 10. the live locals have other types the next time: another version
local function total(a, b)
  local r = a
  for i = 1, 20 do r = r + b end
  return r
end
print("types", total(0, 1), total(0, 1.5), total(0.5, 1), total(1, 1))
print("types again", total(2, 2), total(2.5, 2))

-- 11. a recursive function with a loop; a loop calling the function it is in
local function tri(m)
  local s2 = 0
  for i = 1, m do s2 = s2 + i end
  if m > 0 then s2 = s2 + tri(m - 1) end
  return s2
end
print("tri", tri(30))
local function fibl(m)
  if m < 2 then return m end
  local a, b = 0, 1
  for i = 2, m do a, b = b, a + b end
  return b
end
local fs = 0
for i = 1, 60 do fs = fs + fibl(i) % 1000 end
print("fibl", fs)

-- 12. big counts
local big = 0
for i = 1, 300000 do big = big + (i * i) % 11 end
print("big", big)
local bf = 0.0
local bx = 0
while bx < 100000 do bx = bx + 1; bf = bf + 1 / bx end
print("harmonic", bf)

-- 13. callees that are held by locals of the running function
local function lsq(x) return x * x end
local lt = 0
for i = 1, 50 do lt = lt + lsq(i) end
print("local callee", lt)
local function lfact(n) if n <= 1 then return 1 end return n * lfact(n - 1) end   -- calls itself, so it is captured: a local in a Cell
local lf = 0
for i = 1, 20 do lf = lf + lfact(i) % 1000 end
print("recursive local callee", lf)
local callee = lsq
lt = 0
for i = 1, 30 do lt = lt + callee(i) end
callee = function(x) return x + 1 end
for i = 1, 30 do lt = lt + callee(i) end
print("local callee rebound between loops", lt)
for i = 1, 10 do if i == 5 then callee = lsq end lt = lt + callee(i) end
print("callee assigned in the loop", lt)
local notf = 5
print("callee not a function", pcall(function() local z = 0 for i = 1, 5 do z = z + notf(i) end return z end))

-- 14. locals captured by closures, read and assigned by the loop
local ctr = 0
local function ctrget() return ctr end
for i = 1, 100 do ctr = ctr + i end
print("captured local", ctr, ctrget())
local fl = 0.5
local function flget() return fl end
for i = 1, 10 do fl = fl * 2 end
print("captured float", fl, flget())
local mix = 1
local function mixget() return mix end
for i = 1, 10 do mix = mix + 0.5 end
print("captured, both kinds", mix, mixget(), math.type(mix))
local cb = true
local function cbget() return cb end
for i = 1, 5 do cb = not cb end
print("captured boolean", cb, cbget())

-- 15. functions that assign upvalues: the assignments are made when the call has ended, as if they had been made along the way
local tot = 0
local function addtot(x) tot = tot + x end
for i = 1, 100 do addtot(i) end
print("upvalue write", tot)
local hits = 0
local function hit(x) hits = hits + 1; return x + 1 end
local hr = 0
for i = 1, 1000 do hr = hit(hr) end
print("hits", hits, hr)
local both = 0
local function addf(x) both = both + x end
for i = 1, 10 do addf(0.5) end
print("upvalue, both kinds", both, math.type(both))
local up1, up2 = 1, 2
local function swapup() up1, up2 = up2, up1 + up2 end
for i = 1, 30 do swapup() end
print("multiple assignment to upvalues", up1, up2)
local seen = 0
local function risky(i) seen = seen + 1; return 100 // (5 - i) end
print("error after writes", pcall(function() for i = 1, 10 do risky(i) end end))
print("seen", seen)
local depth = 0
local function down(n) depth = depth + 1; if n == 0 then return 0 end return down(n - 1) + 1 end
print("recursion writing an upvalue", down(50), depth)
print("runaway", pcall(function() local function runaway(n) depth = depth + 1; return runaway(n + 1) + 1 end return runaway(1) end))
print("depth after", depth > 100)

-- 16. one cell reached in two ways while it is assigned: the interpreter runs it
local shared = 0
local function bump() shared = shared + 1 end
for i = 1, 50 do bump(); shared = shared + 10 end
print("alias, a local and a function", shared)
local function counter()
  local c = 0
  return function() c = c + 1 end, function() return c end
end
local inc, get = counter()
local ca = 0
for i = 1, 40 do inc(); ca = ca + get() end
print("alias, two functions", ca, get())
local inc2, get2 = counter()
for i = 1, 40 do inc2(); inc() end
print("two counters", get(), get2())
print("a function that reads and one that writes", (function() local c3 = 0 local function w() c3 = c3 + 1 end local function r() return c3 end
  local x = 0 for i = 1, 30 do w() x = x + r() end return x end)())
local fu = 0.5
local function fupd(i) if i % 2 == 0 then fu = 1 else fu = fu + 0.5 end end
for i = 1, 21 do fupd(i) end
print("upvalue: a float, assigned an integer and a float", fu, math.type(fu))
local ib = 7
local function ibd(i) ib = ib // 2 + i % 3 end
for i = 1, 25 do ibd(i) end
print("integer upvalue", ib, math.type(ib))
local bu = false
local function bud(i) bu = i % 3 == 0 end
for i = 1, 10 do bud(i) end
print("boolean upvalue", bu)

-- 17. kinds of numbers that are decided late, the loop alone compiled for several sets of types, the order of assignments to an upvalue
local ev = 0
for i = 1, 100 do if i > 50 then ev = ev + 0.5 end end
print("either kind, decided late", ev, math.type(ev))
local ev2 = 1.5
for i = 1, 100 do if i > 50 then ev2 = 3 end end
print("a float that becomes an integer", ev2, math.type(ev2))
local function total2(a, b)
  local _t = {}
  local r = a
  for i = 1, 50 do r = r + b end
  _t[1] = r
  return _t[1]
end
print("types, only the loop is compiled", total2(0, 1), total2(0, 1.5), total2(0.5, 1), total2(1, 1), total2(1, 2), total2(2.5, 2))
local fz = 0.25
local function fzd(i) if i > 100 then fz = 7 else fz = fz + 0.5 end end
for i = 1, 5 do fzd(i) end
print("upvalue: a float, entry kind", fz, math.type(fz))
local dup = 0
local function dupd() dup, dup = 1, 2 end
for i = 1, 5 do dupd() end
print("the same upvalue twice", dup)

-- 18. scoping inside a loop that is taken over: the loop variable assigned, a local that shadows a live one, `repeat` scope
local sa = 0
for i = 1, 10 do i = i * 2; sa = sa + i end
print("loop variable assigned", sa)
local x1 = 1
for i = 1, 6 do local x1 = x1 + i; sa = sa + x1 end
print("shadowing", sa, x1)
local wc = 0
while true do wc = wc + 1; if wc * wc > 1000 then break end end
print("while true", wc)
local n3, k3 = 0, 0
repeat local sq3 = k3 * k3; n3 = n3 + sq3; k3 = k3 + 1 until sq3 > 200
print("repeat scope", n3, k3)
do
  local a, b = 1, 2
  for i = 1, 5 do
    local a = a + i
    for j = 1, 3 do local b = b + j; a = a + b end
    sa = sa + a
  end
  print("nested shadowing", a, b, sa)
end

-- 19. a `return` from a loop that was taken over: the locals that closures hold are written back first
local G
local function mk()
  local c, d = 0, 0.5
  G = function() return c, d end
  for i = 1, 100 do
    c = c + i
    d = d * 2
    if c > 1000 then return c end
  end
  return -1
end
print("cells survive a return", mk(), G())
print("again", mk(), G())
