local i = 3
local f = 3.0
local r = 0
if i == f then r = 1 end
if i < 4.5 then r = r + 2 end
if f > 2 then r = r + 4 end
local s = i + f
return s + r
