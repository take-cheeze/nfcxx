local log = {}
local t = setmetatable({}, {__newindex = function(self, k, v) log[k] = v end})
t.a = 5
return log.a, t.a
