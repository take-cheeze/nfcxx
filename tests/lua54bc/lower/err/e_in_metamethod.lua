local t = setmetatable({}, {__index = function(s, k) return nil + 1 end})
return t.x
