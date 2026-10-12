-- a sum that starts as the integer 0 and becomes a float (`local s = 0 ... s = s + x`): a number of either kind inside the tier
local function work(n, x)
  local s = 0
  for i = 1, n do
    s = s + x * i
  end
  return s
end
local total = 0
for r = 1, 10 do total = total + work(3000000, 0.5) end
print(total)
