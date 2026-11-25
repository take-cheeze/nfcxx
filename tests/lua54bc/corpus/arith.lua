local a, b = 7, 3
local x = a + b * 2 - a // b % 4 ^ 2 / 3
local y = a & b | (a ~ b) << 2 >> 1
local z = -a + ~b
local s = a + 1.5
if a < b or a >= 10 then x = x + 1 end
return x, y, z, s
