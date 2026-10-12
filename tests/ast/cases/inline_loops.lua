-- Small functions with loops and multiple assignment, called from sites that run many times (the engine inlines them): the
-- loops run in a frame of their own like in a real call; break, return from inside a loop, errors with their lines, the collector.
local function try(f, ...)
  local r = table.pack(pcall(f, ...))
  for i = 1, r.n do r[i] = tostring(r[i]) end
  print(table.concat(r, " "))
end

local function sumto(n) local s = 0 for i = 1, n do s = s + i end return s end
local function sumstep(a, b, st) local s = 0 for i = a, b, st do s = s + i end return s end
local function fsum(n) local s = 0 for i = 0.5, n, 0.5 do s = s + i end return s end
local function firstgt(t, v) for i = 1, #t do if t[i] > v then return i, t[i] end end return nil end
local function count(n) local c = 0 while n > 0 do n = n // 2 c = c + 1 end return c end
local function untilz(n) local c = 0 repeat local d = n % 10 c = c + d n = n // 10 until n == 0 return c end
local function brk(n) local s = 0 for i = 1, n do if i > 5 then break end s = s + i end return s end
local function nested(n) local s = 0 for i = 1, n do for j = 1, i do if j == 3 then break end s = s + i * j end end return s end
local function ipsum(t) local s = 0 for _, v in ipairs(t) do s = s + v end return s end
local function pairsum(t) local s = 0 for k, v in pairs(t) do s = s + v end return s end
local function keys(t) local n = 0 for k in next, t do n = n + 1 end return n end
local function whileret(n) while true do n = n + 1 if n % 7 == 0 then return n end end end
local function fill(n) local t = {} for i = 1, n do t[i] = i * i end return t end
local function lastof(t) local r for i = 1, #t do r = t[i] end return r end

print("-- loops")
local arr, map = {5, 3, 9, 1, 12}, {a = 1, b = 2, c = 3}
for i = 1, 8 do
  print(i, sumto(i), sumto(0), sumto(-1), sumstep(1, i * 3, 3), sumstep(i, 1, -1), fsum(i), fsum(0))
  print(firstgt(arr, i), firstgt(arr, 100), count(i * 1000), count(0), untilz(i * 111), untilz(0))
  print(brk(i), brk(2), nested(i), ipsum(arr), ipsum({}), pairsum(map), keys(map), keys({}), whileret(i), #fill(i), lastof(fill(i)))
end

print("-- errors inside loops")
local function badstep(a, b, c) local s = 0 for i = a, b, c do s = s + i end return s end
local function badlimit(n) local s = 0 for i = 1, n do s = s + i end return s end
local function idxloop(t, n) local s = 0 for i = 1, n do local v = t[i] s = s + v end return s end
local function callloop(f, n) local r for i = 1, n do r = f(i) end return r end
local function whilebad(x) local n = 0 while n < 3 do n = n + 1 x = x + n end return x end
for i = 1, 6 do
  try(badstep, 1, 10, 0); try(badstep, 1, "x", 1); try(badstep, "a", 1, 1); try(badstep, 1.5, 4, 1)
  try(badlimit, nil); try(badlimit, {}); try(badlimit, "5"); try(badlimit, 3)
  try(idxloop, {1, 2, 3}, 5); try(idxloop, {1, 2, "x"}, 3); try(idxloop, nil, 2); try(idxloop, {1, 2, 3}, 3)
  try(callloop, function(k) if k == 3 then error("three") end return k end, 5)
  try(callloop, function(k) if k == 3 then error(setmetatable({}, {__tostring = function() return 'obj' .. k end})) end return k end, 5)
  try(callloop, nil, 2); try(whilebad, 1); try(whilebad, nil); try(whilebad, "1")
end

print("-- errors raised with a level, from loops")
local function lv(n, level) for i = 1, n do if i == 2 then error("lv" .. i, level) end end end
for i = 1, 6 do try(lv, 3, 1); try(lv, 3, 2); try(lv, 3, 0); try(lv, 1, 2) end

print("-- multiple assignment")
local function swap(a, b) a, b = b, a return a, b end
local function rot(a, b, c) a, b, c = b, c, a return a, b, c end
local function fib(n) local a, b = 0, 1 for i = 1, n do a, b = b, a + b end return a end
local function tswap(t, i, j) t[i], t[j] = t[j], t[i] return t end
local function field(t, a, b) t.x, t.y = a, b return t.x, t.y end
local function mixed(t, a) local l l, t.k, G = a, a + 1, a + 2 return l, t.k, G end
local function more(a) local x, y, z x, y, z = a, a + 1 return x, y, z end
local function fewer(a, b) a = 1, 2, 3 return a end
local function order(t, i) i, t[i] = i + 1, 20 return i, t[1], t[2] end
local function ups(a) U1, U2 = a, a * 2 return U1 + U2 end
for i = 1, 8 do
  print(swap(i, 2), rot(i, 2, 3), fib(i), fib(0))
  print(table.concat(tswap({1, 2, 3}, 1, 3), ","), field({}, i, "s"), mixed({}, i), more(i), fewer(i, 2))
  print(order({}, 1), ups(i), G, U1, U2)
end
for i = 1, 6 do
  try(tswap, nil, 1, 2); try(tswap, {}, nil, 1); try(field, nil, 1, 2); try(field, 5, 1, 2); try(mixed, nil, 1)
  try(tswap, setmetatable({}, {__newindex = function(t, k, v) error("ni" .. tostring(k)) end}), 1, 2)
end

print("-- loops that allocate (the collector runs at every safe point under stress)")
local function build(n) local t = {} for i = 1, n do t[#t + 1] = {i, tostring(i) .. "x"} end return t end
local function joined(t) local s = "" for _, e in ipairs(t) do s = s .. e[2] end return s end
for i = 1, 8 do print(#build(i), joined(build(i)), joined(build(0))) end

print("-- recursion with loops")
local function tri(n) local s = 0 for i = 1, n do if n > 1 and i == n then s = s + tri(n - 1) else s = s + i end end return s end
for i = 1, 6 do print(tri(i + 3), tri(1)) end
local function inf(n) for i = 1, 1 do return inf(n + 1) + 1 end end
local ok, e = pcall(inf, 1)
print(ok, (tostring(e):gsub("^.-:%d+: ", "")))

print("-- methods with loops and multiple assignment")
local C = {}
C.__index = C
function C:sum() local s = 0 for _, v in ipairs(self) do s = s + v end return s end
function C:swap() self[1], self[2] = self[2], self[1] return self[1] end
function C:grow(n) for i = 1, n do self[#self + 1] = i end return #self end
local o = setmetatable({1, 2, 3}, C)
for i = 1, 8 do print(o:sum(), o:swap(), o:grow(i % 3), #o) end
try(function() return C.sum(nil) end); try(function() return C.sum(5) end)
