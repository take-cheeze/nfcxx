local t = {10, 20, x = 5}
local s = 0
for k, v in pairs(t) do s = s + v end
return s
