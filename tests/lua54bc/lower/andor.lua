local a = nil
local b = a or 5
local c = b and 7
local d = false and 3
return b + c, d
