local t = nil
local u = false
local r = 1
if t then r = r + 2 end
if u then r = r + 4 end
local v = 0
if v then r = r + 8 end
return r
