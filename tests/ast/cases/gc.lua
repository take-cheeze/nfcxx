local function show(...) print(...) end
-- garbage of every kind, collected in the middle of computations
local keep = {}
for i = 1, 2000 do
  local t = {i, tostring(i), {i}, function() return i end}
  if i % 100 == 0 then keep[#keep + 1] = t end
end
collectgarbage()
local sum = 0 for _, t in ipairs(keep) do sum = sum + t[1] + #t[2] + t[3][1] + t[4]() end show(#keep, sum)
-- strings built piece by piece
local s = "" for i = 1, 300 do s = s .. i .. "," end show(#s, s:sub(1, 20), s:sub(-8))
-- many closures sharing upvalues, collected and rebuilt
local function make(n) local fs = {} local shared = 0 for i = 1, n do fs[i] = function() shared = shared + i return shared end end return fs end
for round = 1, 5 do local fs = make(50) for i = 1, 50 do fs[i]() end collectgarbage() end
local fs = make(10) for i = 1, 10 do fs[i]() end show(fs[10]())
-- tables used as keys and values keep their referents alive
local registry = {}
for i = 1, 100 do local k = {id = i} registry[k] = {payload = ("x"):rep(i)} end
collectgarbage()
local n, total = 0, 0 for k, v in pairs(registry) do n = n + 1 total = total + k.id + #v.payload end show(n, total)
-- results of string functions survive collections triggered by callbacks
local out = {} for w in ("alpha beta gamma delta"):gmatch("%a+") do out[#out + 1] = w:upper():gsub("A", function(c) collectgarbage() return "4" end) end
show(table.concat(out, " "))
-- sort with an allocating comparator
local items = {} for i = 1, 60 do items[i] = {key = (i * 37) % 61, name = "n" .. i} end
table.sort(items, function(a, b) local t = {a.key, b.key} return t[1] < t[2] end)
local okk = true for i = 2, #items do if items[i - 1].key > items[i].key then okk = false end end show(okk, items[1].key, items[60].key)
-- gsub with table and function replacements while allocating
show((("one two three"):gsub("%a+", {one = "1", three = "3"})), (("a b c"):gsub("%a", function(c) return c:rep(2) .. tostring({}):sub(1, 0) end)))
-- error values survive unwinding and collection
local errs = {} for i = 1, 20 do local ok, e = pcall(function() local t = {i} error({code = i, t = t}) end) collectgarbage() errs[#errs + 1] = e.code + e.t[1] end show(#errs, errs[20])
-- pcall results and varargs pass through collections
local function churn(...) collectgarbage() return ... end
show(type(select(3, churn(1, "two", {3}, 4.5))), (churn(1, "two"))) show(select("#", churn(nil, nil)))
-- coroutine-free generator state kept in tables across collections
local gen = {state = {a = 1, b = 1}} function gen:next() local s = self.state s.a, s.b = s.b, s.a + s.b collectgarbage() return s.a end
local fibs = {} for i = 1, 10 do fibs[i] = gen:next() end show(table.concat(fibs, ","))
-- a big array being filled while garbage accumulates
local big = {} for i = 1, 5000 do big[i] = {i, i * 2} if i % 1000 == 0 then collectgarbage() end end show(#big, big[5000][2])
-- collectgarbage options
show(type(collectgarbage("count")), collectgarbage("isrunning"), pcall(collectgarbage, "bogus"))
local before = collectgarbage("count") local junk = {} for i = 1, 1000 do junk[i] = {i} end local mid = collectgarbage("count") junk = nil collectgarbage() local after = collectgarbage("count")
show(mid > before, after < mid)
