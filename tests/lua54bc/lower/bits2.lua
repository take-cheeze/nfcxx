local v = -1
local w = 2.0
local r = v >> 60
r = r + (w << 3) + (v << 63) + (3 << 62 >> 61)
return r
