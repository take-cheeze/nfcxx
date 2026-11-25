local a = 5
local r = 0
if a < 10 then r = 1 else r = 2 end
if a >= 5 then r = r + 10 end
if a ~= 3 then r = r + 100 end
if a <= 4.5 then r = r + 1000 end
return r
