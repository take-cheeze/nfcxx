-- The order of pairs over integer keys follows the table's layout (ltable.c's array and node parts).
local function keys(t)
  local out = {}
  for k in pairs(t) do out[#out + 1] = tostring(k) end
  return table.concat(out, " ")
end

local t = {}
t[10] = 1; t[20] = 2; t[3] = 3; t[1] = 4
print(keys(t))

t = {1, 2, nil, 4}
t[7] = 7
print(keys(t))

t = {}
for i = 1, 12 do t[i * i] = i end
print(keys(t))

t = {}
for i = 8, 1, -1 do t[i] = i end
print(keys(t))

t = {}
t[1.5] = 1; t[2] = 2; t[-3] = 3; t[true] = 4
local n = 0
for _ in pairs(t) do n = n + 1 end
print(n)
