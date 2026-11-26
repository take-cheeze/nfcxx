// Integer literals across the LOADINT range and beyond it (LOAD of a literal), with negative values.
local a = 2147483647
local b = -2147483648
local c = 4294967296
local d = -9223372036854775807
local e = 255
local f = 256
return a + b + c + d + e + f
