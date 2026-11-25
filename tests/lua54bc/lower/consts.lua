local a = 1000
local r = a // 3 + a % 7 + a ^ 2
r = r + (a & 255) + (a | 16) + (a ~ 5)
r = r + (a * 2.5) - (a / 4)
return r
