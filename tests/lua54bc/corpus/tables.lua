local t = { 1, 2, 3, x = "y", [10] = 4.5, nested = { true, false, nil } }
t.x = t[1]
t[2] = t.nested
local u = setmetatable({}, { __index = t })
return u.x, #t, t["x"]
