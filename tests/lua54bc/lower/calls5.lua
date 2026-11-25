local function mix(x, y)
  local t = x / y
  for i = 1, 3 do t = t + i end
  return t
end
local function run(g, a, b) return g(a, b) end
return run(mix, 7, 2)
