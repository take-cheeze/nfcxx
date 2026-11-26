math.randomseed(42)
local a, b, c = math.random(), math.random(10), math.random(5, 7)
print(a, b, c)
math.randomseed(42)
print(math.random() == a, math.random(10) == b)
print(math.randomseed(7))
local inside = true
for i = 1, 200 do
  local r = math.random(3, 4)
  if r < 3 or r > 4 then inside = false end
end
print(inside, math.type(math.random(0)), math.type(math.random()))
print(pcall(function() return math.random(2, 1) end))
print(pcall(function() return math.random(1, 2, 3) end))
math.randomseed(1)
local seen = {}
for i = 1, 300 do seen[math.random(3)] = true end
print(seen[1], seen[2], seen[3])
