local function show(...) print(...) end
local function keys(t) local k = {} for key in pairs(t) do k[#k + 1] = tostring(key) end table.sort(k) return table.concat(k, ",") end
local t = {10, 20, 30, nil, 50}
show(#t == 5 or #t == 3, t[1], t[5], t[6], select("#", table.unpack({1, 2, nil, 4}, 1, 4)))
local a = {1, 2, 3}
a[#a + 1] = 4; a[#a + 1] = 5
show(#a, a[5], table.concat(a, ","), table.concat(a, ",", 2, 4), table.concat({}, ","), table.concat({1}, ","))
table.insert(a, 6); table.insert(a, 1, 0); table.insert(a, 4, 99)
show(table.concat(a, ","), table.remove(a), table.remove(a, 1), table.remove(a, 3), table.concat(a, ","), #a)
show(table.remove({}), table.remove({}, 0), pcall(table.insert, {}, 5, 1), pcall(table.insert, {}, 1, 2, 3), pcall(table.remove, {1}, 5))
show(table.unpack({1, 2, 3}), table.unpack({1, 2, 3}, 2), table.unpack({1, 2, 3}, 2, 3), table.unpack({}, 1, 2))
local p = table.pack(1, nil, 3)
show(p.n, p[1], p[2], p[3], #table.pack())
local m = table.move({1, 2, 3}, 1, 3, 2)
show(table.concat(m, ","), table.concat(table.move({1, 2, 3}, 2, 3, 1), ","), table.concat(table.move({1, 2}, 1, 2, 1, {9, 9, 9}), ","))
local words = {"pear", "apple", "fig", "banana", "cherry"}
table.sort(words); show(table.concat(words, " "))
table.sort(words, function(x, y) return #x < #y or (#x == #y and x < y) end); show(table.concat(words, " "))
table.sort(words, function(x, y) return x > y end); show(table.concat(words, " "))
local nums = {5, 2, 8, 1, 9, 3, 7, 4, 6, 0, 11, 15, 13, 12, 14, 10}
table.sort(nums); show(table.concat(nums, ","))
table.sort(nums, function(x, y) return x > y end); show(table.concat(nums, ","))
show(pcall(table.sort, {3, 1, "x"}), pcall(table.sort, {1, 2}, 5))
local fl = {3.5, 1, 2.25, -1, 10}
table.sort(fl); show(table.concat(fl, " "))
local mixed = {x = 1, y = 2, [1] = "a", [2] = "b", [3.0] = "c", [2^53] = "big", [true] = "t", z = {1, 2}}
show(keys(mixed), mixed[3], mixed[3.0], mixed[2^53], mixed[true], #mixed, mixed.z[2])
local cnt = 0 for _ in pairs(mixed) do cnt = cnt + 1 end show(cnt)
local n = 0 for i, v in ipairs({1, 2, nil, 4}) do n = n + i end show(n)
for i, v in ipairs({"a", "b"}) do show(i, v) end
local d = {} for i = 1, 10 do d[i] = i end for i = 1, 10, 2 do d[i] = nil end
local live = 0 for k, v in pairs(d) do live = live + v end show(live)
for k in pairs(d) do d[k] = nil end show(next(d), #d)
show(next({}), next({5}), type(next), rawlen({1, 2}), rawlen("abc"), rawequal(a, a), rawequal(a, {}), rawget(a, 1), rawset({}, "k", 1).k)
show(pcall(next, {}, "nokey"), pcall(rawset, {}, nil, 1), pcall(function() local x = {} x[nil] = 1 end), pcall(function() local x = {} x[0/0] = 1 end))
local nested = {a = {b = {c = {d = 42}}}, list = {{1, 2}, {3, 4}}}
show(nested.a.b.c.d, nested.list[2][1], #nested.list, nested["a"]["b"].c["d"])
local big = {} for i = 1, 1000 do big[i] = i * 2 end show(#big, big[1000], big[500])
for i = 1, 500 do big[#big] = nil end show(#big)
local sparse = {} sparse[1] = 1 sparse[2] = 2 sparse[4] = 4 show(sparse[4], sparse[3])
sparse[3] = 3 show(#sparse)
local tt = {[1] = "x", [2] = "y"} show(#tt, tt[1])
local c = {f = function(self, x) return x * 2 end, v = 21} show(c:f(c.v), c.f(c, 4))
local e1, e2 = {}, {} show(e1 == e2, e1 == e1, #e1, next(e1))
show(#{n = 1}, #{1, 2, 3, nil}, #{nil}, #{nil, nil, 3} >= 0, {} ~= {})
local tk = {} tk[1.0] = "one" tk[2^53] = "two" show(tk[1], next(tk) == 1)
local w = setmetatable({}, {__mode = "k"}) show(type(w))
local arr = {} for i = 1, 100 do arr[i] = {i} end local sum = 0 for _, v in ipairs(arr) do sum = sum + v[1] end show(sum)
local cat = {} for i = 1, 5 do cat[#cat + 1] = tostring(i) end show(table.concat(cat))
