-- Small functions that call small functions that call small functions: chains deeper than the engine inlines, natives and string
-- methods called from inside an inlined body, results flowing through several levels, and errors raised at the bottom of a
-- chain (the position is the innermost line; `error` levels count every level of the chain).
local function sq(x) return x * x end
local function dist2(ax, ay, bx, by) return sq(ax - bx) + sq(ay - by) end
local function dist(ax, ay, bx, by) return math.sqrt(dist2(ax, ay, bx, by)) end
local function near(ax, ay, bx, by, r) return dist2(ax, ay, bx, by) <= sq(r) end
local function level4(x) return near(x, x, 0, 0, 3) end
local function level5(x) return level4(x) and "near" or "far" end
local function level6(x) return level5(x) .. "!" end

print("-- chains of calls")
for i = 0, 7 do
  print(i, sq(i), dist2(i, 0, 0, i), dist(i, i, 0, 0), near(i, 0, 0, i, 3), level4(i), level5(i), level6(i))
end
for i = 0, 3 do print(dist(i + 0.5, 1, 2, i)) end

print("-- natives and string methods inside the body")
local function fmt(n) return string.format("%03d|%5.2f|%s", n, n / 3, tostring(n)) end
local function up(s) return s:upper() .. #s end
local function clamp(x, lo, hi) return math.max(lo, math.min(hi, x)) end
local function floorsum(a, b) return math.floor(a) + math.ceil(b) end
local function tag(s, n) return ("[" .. s:rep(n) .. "]"):lower() end
local function words(s) local n = 0 for _ in s:gmatch("%a+") do n = n + 1 end return n end
for i = 1, 6 do
  print(fmt(i), up("abc" .. i), clamp(i * 3, 4, 10), floorsum(i / 2, i / 3), tag("Ab", i), words("a b" .. string.rep(" c", i)))
end

print("-- the same helper at several depths of the same chain")
local function inc(x) return x + 1 end
local function inc2(x) return inc(inc(x)) end
local function inc4(x) return inc2(inc2(x)) end
local function inc8(x) return inc4(inc4(x)) end
local function inc9(x) return inc(inc8(x)) end
for i = 1, 6 do print(inc(i), inc2(i), inc4(i), inc8(i), inc9(i), inc9(inc9(i))) end

print("-- results of several values through the chain")
local function pair(a, b) return a, b end
local function pair2(a, b) return pair(b, a) end
local function pair3(a, b) return pair2(b, a) end
local function pair4(a, b) return pair3(a, b), "tail" end
local function swap2(a, b) local x, y = pair3(a, b) return y, x end
for i = 1, 6 do
  print(pair(i, 1), pair2(i, 1), pair3(i, 1), pair4(i, 1))
  print(swap2(i, "s"))
  local a, b, c = pair4(i, 2)
  print(a, b, c)
end

print("-- an error at the bottom of the chain")
local function bottom(x) if x > 3 then error("too big: " .. x) end return x end
local function bottom2(x) if x > 3 then error("too big (2): " .. x, 2) end return x end
local function bottom3(x) if x > 3 then error("too big (3): " .. x, 3) end return x end
local function m1(x) return bottom(x) + 1 end
local function m2(x) return m1(x) + 1 end
local function m3(x) return m2(x) + 1 end
local function n1(x) return bottom2(x) + 1 end
local function n2(x) return n1(x) + 1 end
local function o1(x) return bottom3(x) + 1 end
local function o2(x) return o1(x) + 1 end
local function o3(x)
  local r = o2(x)
  return r + 1
end
for i = 1, 6 do
  print(pcall(m3, i))
  print(pcall(n2, i))
  print(pcall(o3, i))
end

print("-- an error in an argument at an inner level")
local function arg2(a, b) return sq(a) + sq(b) end
local function arg3(a, b) return arg2(a, b) * 2 end
for i = 1, 6 do
  print(pcall(arg3, i, i % 3 == 0 and {} or i))
  print(pcall(arg3, i % 2 == 0 and nil or i, i))
end
