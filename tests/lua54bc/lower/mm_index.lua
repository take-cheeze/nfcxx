local base = {x = 10}
local t = setmetatable({}, {__index = base})
local u = setmetatable({}, {__index = function(self, k) return k .. "!" end})
return t.x + 1, u.hello
