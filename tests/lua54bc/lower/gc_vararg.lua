local function f(...) local t = {...} return #t end
local acc = 0
for i = 1, 50000 do acc = acc + f(i, "x", i) end
return acc
