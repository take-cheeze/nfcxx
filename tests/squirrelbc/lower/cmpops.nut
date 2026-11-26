local a = 4
local r = 0
if (a > 3) { r = r + 1 }
if (a >= 4) { r = r + 2 }
if (a < 4) { r = r + 4 }
if (a <= 4) { r = r + 8 }
return r
