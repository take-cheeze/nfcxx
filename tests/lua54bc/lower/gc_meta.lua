local obj = setmetatable({}, {__index = function(t, k) return ("v" .. k):upper() end})
local acc = 0
for i = 1, 50000 do acc = acc + #obj[i] end
return acc
