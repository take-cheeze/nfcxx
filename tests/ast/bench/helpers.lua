-- A loop that calls small helper functions (predicates, math helpers, a getter-like accessor on a table): the case inlining is for.
local function sq(x) return x * x end
local function clamp(x, lo, hi) if x < lo then return lo elseif x > hi then return hi end return x end
local function lerp(a, b, t) return a + (b - a) * t end
local function isodd(n) return n % 2 == 1 end
local function dist2(ax, ay, bx, by) return sq(ax - bx) + sq(ay - by) end
local p = {x = 3, y = 4}
local function px(t) return t.x end
local function py(t) return t.y end

local n = 5000000
local s = 0
for i = 1, n do
  s = s + sq(i % 100) + clamp(i % 200, 20, 150) + (isodd(i) and 1 or 0) + dist2(i, px(p), 0, py(p)) % 7
  s = s + lerp(0, 100, (i % 10) / 10) // 1
end
print(s)
