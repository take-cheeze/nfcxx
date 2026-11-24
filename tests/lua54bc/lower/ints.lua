local a, b = 7, 3
local c = a + b
local d = c * 2 - a
local e = d + 1
local f = 1.5 + e
if a < b then e = e + 100 end
if e == 10 then e = e + 1 end
return e
