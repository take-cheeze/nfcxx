local a, b = "abc", "abd"
local r = 0
if a < b then r = r + 1 end
if a == "abc" then r = r + 10 end
if a ~= b then r = r + 100 end
return r
