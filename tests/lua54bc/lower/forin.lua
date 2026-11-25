local function iter(s, c)
  if c < s then return c + 1, c * 10 end
end
local total = 0
for k, v in iter, 3, 0 do total = total + k + v end
return total
