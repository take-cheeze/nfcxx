local a, b = 60, 25
local r = a & b
r = r | (a ~ b) << 1
r = r ~ (b >> 2)
r = r + (~a) + (-b)
return r
