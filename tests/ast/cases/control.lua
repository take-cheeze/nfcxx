local function show(...) print(...) end
-- numeric for: ints, negative steps, floats, empty loops, limits
local function loop(a, b, c) c = c or 1 local r = {} for i = a, b, c do r[#r + 1] = tostring(i) end return table.concat(r, " ") end
show(loop(1, 5), loop(5, 1), loop(5, 1, -1), loop(1, 10, 3), loop(10, 1, -3), loop(1, 0), loop(1, 1), loop(0, 1, 0.25))
show(loop(1.0, 3), loop(1, 3.5), loop(1, 3.0), loop(3, 1.5, -1), loop(1, 2, 0.5), loop(math.maxinteger - 2, math.maxinteger), loop(math.mininteger, math.mininteger + 2))
show(loop(1, 3.7), loop(3, 1.2, -1), loop(-3, -1), loop("1", 3))
local n = 0 for i = 1, 3 do for j = 1, 3 do if j == 2 then break end n = n + 1 end end show(n)
-- while / repeat / break / nested
local i, s = 0, 0 while i < 10 do i = i + 1 if i % 2 == 0 then s = s + i end if i > 7 then break end end show(i, s)
local r = 0 repeat r = r + 1 local done = r >= 5 until done show(r)
local cnt = 0 for a = 1, 10 do for b = 1, 10 do if a * b > 20 then break end cnt = cnt + 1 end end show(cnt)
-- if / elseif / else, and/or short-circuit
local function cls(x) if x < 0 then return "neg" elseif x == 0 then return "zero" elseif x < 10 then return "small" else return "big" end end
show(cls(-1), cls(0), cls(5), cls(50))
show(nil and 1, false and 1, 0 and 1, "" and 1, nil or 2, false or 2, 1 or error("no"), nil and error("no"), 1 and 2 and 3, nil or false or 0)
show(not nil, not 0, not "", not not nil, 1 == 1 and "yes" or "no", 1 == 2 and "yes" or "no")
local calls = {} local function t(x) calls[#calls + 1] = tostring(x) return x end
local _ = t(1) and t(false) and t(3) or t(4) show(table.concat(calls, ","))
-- multiple assignment, swaps, evaluation order
local a, b, c = 1, 2 show(a, b, c)
a, b = b, a show(a, b)
local tt = {1, 2, 3} local k = 1 k, tt[k] = k + 1, 99 show(k, tt[1], tt[2])
local x, y, z = (function() return 1, 2, 3 end)() show(x, y, z)
local q = {} q.a, q.b = 1 show(q.a, q.b)
-- numeric edge cases in loops
local acc = 0 for i = math.maxinteger - 1, math.maxinteger do acc = acc + 1 end show(acc)
local acc2 = 0 for i = math.mininteger, math.mininteger + 1 do acc2 = acc2 + 1 end show(acc2)
local acc3 = 0 for i = 1, 0 do acc3 = acc3 + 1 end show(acc3)
-- loop variable is a copy
for i = 1, 3 do local j = i i = i * 10 show(j, i) end
-- ipairs stops at nil, pairs counts everything
local holes = {1, 2, nil, 4} local ic = 0 for _ in ipairs(holes) do ic = ic + 1 end show(ic)
-- generic for with custom iterators and stateful closures
local function range(n) local i = 0 return function() i = i + 1 if i <= n then return i end end end
local rs = 0 for v in range(5) do rs = rs + v end show(rs)
local function iter(t, i) i = i + 1 if t[i] then return i, t[i] end end
for i, v in iter, {"a", "b", "c"}, 0 do io = nil show(i, v) end
for k, v in next, {10, 20} do show(k, v) end
for a, b, c in function(s, c) if c < 2 then return c + 1, "b", "c" end end, nil, 0 do show(a, b, c) end
-- nested functions with early returns in loops
local function first_neg(t) for i, v in ipairs(t) do if v < 0 then return i end end return nil end
show(first_neg({1, 2, -3, 4}), first_neg({1, 2}))
-- string keys iteration with deletion during traversal
local del = {} for i = 1, 20 do del["k" .. i] = i end
local removed = 0 for k, v in pairs(del) do if v % 2 == 0 then del[k] = nil removed = removed + 1 end end
local left = 0 for _ in pairs(del) do left = left + 1 end show(removed, left)
-- long if-chains and deep expression nesting
local deep = 0 for i = 1, 100 do deep = deep + (((((i)))) * 1) end show(deep)
show((((((((1))))))), (2 + (3 * (4 - (5 / (6 + 7))))))
-- integer vs float loop counters
for i = 1, 3 do io = nil end for i = 1.0, 3 do show(i, math.type(i)) end
-- semicolons and empty statements
;;; local e = 1; ; show(e);
-- numeric for with large steps
show(loop(1, 100, 33), loop(100, 1, -33), loop(0, math.maxinteger, math.maxinteger // 2))
-- break out of while true
local w = 0 while true do w = w + 1 if w == 5 then break end end show(w)
-- repeat-until scoping: body locals visible in condition
local rr = 0 repeat local stop = rr > 2 rr = rr + 1 until stop show(rr)
-- shadowing
local sh = 1 do local sh = 2 show(sh) end show(sh)
local sh2 = 1 local sh2 = sh2 + 1 show(sh2)
-- long string concatenation chain
show(("a"):rep(3) .. "-" .. 1 .. "-" .. 2.5 .. "-" .. tostring(nil) .. "-" .. tostring(true))
-- globals
G1 = 10 G2 = G1 * 2 show(G1, G2, _G.G1, _G["G2"], rawget(_G, "G1"), _G == _G._G)
_G.G3 = 5 show(G3) G3 = nil show(G3, rawget(_G, "G3"))
local env = _G show(env.print == print, type(_VERSION))
