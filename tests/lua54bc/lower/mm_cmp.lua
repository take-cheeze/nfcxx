local M = {}
M.__eq = function(a, b) return a.id == b.id end
M.__lt = function(a, b) return a.id < b.id end
M.__le = function(a, b) return a.id <= b.id end
M.__len = function(a) return 42 end
M.__concat = function(a, b) return "cat" end
M.__unm = function(a) return -a.id end
local x = setmetatable({id = 1}, M)
local y = setmetatable({id = 2}, M)
local z = setmetatable({id = 1}, M)
return (x == z), (x < y), (y <= x), #x, x .. "s", -x
