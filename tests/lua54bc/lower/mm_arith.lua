local V = {}
V.__add = function(a, b) return a.v + b.v end
V.__mul = function(a, b) return a.v * b end
local a = setmetatable({v = 2}, V)
local b = setmetatable({v = 5}, V)
return a + b, a * 4
