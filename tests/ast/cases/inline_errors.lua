-- Errors raised inside small functions that the engine inlines into hot call sites: the message and its position (the line of
-- the operation inside the callee), the variable names in the message, `error` with levels (blaming the callee, its caller, the
-- caller's caller), values that are not strings, errors caught by pcall inside and outside the callee, and errors in the
-- arguments of an inlined call. Each call site runs many times, with the failing input coming after the site was rewritten.
local function div(a, b) return a // b end
local function mod(a, b) return a % b end
local function idx(t, k) local v = t[k]; return v.x end
local function field(t) return t.a.b end
local function callit(f, x) return f(x) end
local function cat(a, b) return a .. b end
local function lt(a, b) return a < b end
local function len(x) return #x end
local function neg(x) return -x end
local function band(a, b) return a & b end
local function gcall(x) return undefined_function(x) end
local up = nil
local function upval(x) return x + up end
local function setfield(t, v) t.x.y = v end

local function try(f, ...)
  local ok, e = pcall(f, ...)
  print(ok, e)
end

print("-- arithmetic, indexing, calls, comparisons, concatenation")
local inputs = {
  {1, 1}, {7, 2}, {8, 0}, {9, 3}, {1.5, 0.5}, {"x", 1}, {nil, 1}, {5, 5}, {{}, 1}, {2, nil}, {3, 3}, {-4, 0},
}
for round = 1, 2 do
  for i, p in ipairs(inputs) do
    local a, b = p[1], p[2]
    print(i, pcall(function() return div(a, b) end))
    print(i, pcall(function() return mod(a, b) end))
    print(i, pcall(function() return lt(a, b) end))
    print(i, pcall(function() return cat(a, b) end))
    print(i, pcall(function() return band(a, b) end))
    print(i, pcall(function() return neg(a) end))
    print(i, pcall(function() return len(a) end))
  end
end

print("-- indexing")
local tabs = {{{x = 1}}, {{}}, {}, {{x = 5}}, {[1] = 3}, "str", {{x = "deep"}}}
for round = 1, 2 do
  for i, t in ipairs(tabs) do
    print(i, pcall(function() return idx(t, 1) end))
    print(i, pcall(function() return field(t) end))
    print(i, pcall(function() return field({a = t}) end))
  end
end

print("-- calling a value that is not a function, a global that is not defined, an upvalue that is nil")
for i, f in ipairs({print == nil, math.abs, 3, "s", {}, function(x) return x end, false, math.abs}) do
  print(i, pcall(function() return callit(f, -i) end))
end
for i = 1, 4 do
  print(i, pcall(function() return gcall(i) end))
  print(i, pcall(function() return upval(i) end))
  up = i < 3 and 10 or nil
  print(i, pcall(function() return upval(i) end))
end
print(pcall(function() return setfield({}, 1) end))
print(pcall(function() return setfield({x = {}}, 1) end))
print(pcall(function() return setfield({x = 1}, 1) end))

print("-- error with levels")
local function lvl0(m) error(m, 0) end
local function lvl1(m) error(m) end
local function lvl2(m) error(m, 2) end
local function lvl3(m) error(m, 3) end
local function w1(m) lvl1(m) end
local function w2(m) lvl2(m) end            -- level 2 blames the call in w2
local function w3(m) lvl3(m) end            -- level 3 blames the call of w3
local function w4(m)
  w3(m)                                     -- the line that level 3 of lvl3 points to when w3 is called from here
end
local function ww(m) w4(m) end
for i = 1, 6 do
  try(lvl0, "zero " .. i)
  try(function() lvl0("zero " .. i) end)
  try(function() lvl1("one " .. i) end)
  try(function() w1("one " .. i) end)
  try(function() lvl2("two " .. i) end)
  try(function() w2("two " .. i) end)
  try(function() w3("three " .. i) end)
  try(function() w4("three " .. i) end)
  try(function() ww("three " .. i) end)
  try(function() lvl3("deep " .. i) end)
end

print("-- error values that are not strings, and nested pcall")
local function throw(v) error(v) end
local function throw2(v) error(v, 2) end
local function guarded(v) return pcall(throw, v) end
local function guarded2(v) local ok, e = pcall(throw2, v) return ok, e end
local obj = {code = 7}
for i = 1, 6 do
  local ok, e = pcall(function() throw(obj) end)
  print(ok, e == obj, e.code)
  print(pcall(function() throw(i) end))
  print(pcall(function() throw(nil) end))
  print(pcall(function() throw(true) end))
  print(guarded("g" .. i))
  print(guarded2("h" .. i))
  print(select('#', pcall(function() throw() end)))
end

print("-- a callee that catches the error of the function it calls")
local function safe(f, x) local ok, e = pcall(f, x) if ok then return e end return "caught: " .. tostring(e) end
local function bad(x) return x.y.z end
for i = 1, 6 do
  print(safe(bad, {y = {z = i}}), safe(bad, {}), safe(bad, i))
end

print("-- errors in the arguments of an inlined call come from the caller's line")
local function id(x) return x end
for i = 1, 6 do
  print(pcall(function() return id(nil + i) end))
  print(pcall(function() return id(id(i) .. {}) end))
  print(pcall(function() return id(i < "x") end))
end

print("-- tostring of an error value and the unwinding state afterwards")
for i = 1, 6 do
  local ok, e = pcall(function() return div(i, 0) end)
  print(ok, e)
  print(div(i, 1), mod(i, 4), neg(i))
end

print("-- a callee from another chunk: its own chunk name and lines in messages, its caller's position for level 2")
local other = load("local M = {}\nfunction M.get(t)\n  return t.a.b\nend\nfunction M.lvl2(m)\n  error(m, 2)\nend\nfunction M.div(a, b) return a // b end\nreturn M", "=other")()
for i = 1, 6 do
  print(pcall(function() return other.get({a = {b = i}}) end))
  print(pcall(function() return other.get({a = i}) end))
  print(pcall(function() return other.get({}) end))
  print(pcall(function() other.lvl2("m" .. i) end))
  print(pcall(function() return other.div(i, i - 3) end))
end

print("-- natives called from an inlined body with bad arguments: the name at the call site, the position of the callee")
local function rep1(s, n) return s:rep(n) end
local function rep2(s, n) return string.rep(s, n) end
local function flo(x) return math.floor(x) end
local function fmt(f, x) return string.format(f, x) end
local function tn(x, b) return tonumber(x, b) end
local function ins(t, v) table.insert(t, v) return #t end
for i = 1, 6 do
  print(pcall(function() return rep1("ab", i % 3 == 0 and {} or i) end))
  print(pcall(function() return rep2(i % 2 == 0 and {} or "x", i) end))
  print(pcall(function() return flo(i % 3 == 0 and "x" or i + 0.5) end))
  print(pcall(function() return fmt(i % 2 == 0 and "%d" or "%q", i / 2) end))
  print(pcall(function() return tn(i, i % 2 == 0 and 99 or 10) end))
  print(pcall(function() return ins(i % 4 == 0 and 5 or {}, i) end))
end
