local a, b = -7, 3
local r = a // b
r = r + (a % b) * 100
r = r + (7 // -2) * 10000
local f = 7.5
r = r + (f // 2) * 1000000 + (f % -2)
return r
