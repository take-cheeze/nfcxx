local t = {1, 2, 3}
table.insert(t, 4)
table.insert(t, 1, 0)
local r = table.remove(t)
local r2 = table.remove(t, 1)
return table.concat(t, ","), r, r2, #t
