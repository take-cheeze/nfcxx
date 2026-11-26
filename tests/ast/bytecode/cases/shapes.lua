-- Shapes the bytecode of luac makes: loop variables captured per iteration, closures sharing a local, varargs and multiple
-- results (more than the registers of a frame), SETLIST with a multiple-results tail and with more than 50 items, `break` and
-- `goto` out of loops with captured locals.
local fs = {}
for i = 1, 3 do fs[i] = function() return i end end
print(fs[1](), fs[2](), fs[3]())

local acc = {}
for _, v in ipairs({"a", "b"}) do local w = v .. "!" acc[#acc + 1] = function() return w end end
print(acc[1](), acc[2]())

local function pair()
  local n = 0
  local function inc() n = n + 1 return n end
  local function get() return n end
  return inc, get
end
local inc, get = pair()
inc() inc()
print(get())

local function many(...) return ... end
local function count(...) return select("#", ...) end
print(count(many(table.unpack({1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15, 16, 17, 18, 19, 20}))))
local function keep(...) local a, b = ... local t = {...} return #t, a, b, select("#", ...) end
print(keep(1, nil, 3))
print((many(1, 2, 3)))

local big = {1,2,3,4,5,6,7,8,9,10,11,12,13,14,15,16,17,18,19,20,21,22,23,24,25,26,27,28,29,30,31,32,33,34,35,36,37,38,39,40,41,42,43,44,45,46,47,48,49,50,51,52,53,54,55,56,57,58,59,60}
print(#big, big[51], big[60])

local function va_twice(...)
  local x = select("#", ...)
  local y = select("#", ...)
  return x + y, ...
end
print(va_twice(7, 8, 9))

local function outer(...)
  local function inner(...) return select("#", ...) + #{...} end
  return inner(...), inner(..., "z"), ...
end
print(outer(1, 2))

local fns = {}
local i = 0
while true do
  i = i + 1
  local j = i * 10
  fns[#fns + 1] = function() return j end
  if i == 3 then break end
end
print(fns[1](), fns[2](), fns[3]())

local kept = {}
for k = 1, 3 do
  local m = k
  if k == 2 then goto continue end
  kept[k] = function() return m end
  ::continue::
end
print(kept[1](), type(kept[3]), kept[2])

local r_fn
repeat local r = 5; r_fn = function() return r end until r == 5
print(r_fn())
