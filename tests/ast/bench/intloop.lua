-- integer loops: a function called ten times, each running a loop of three million additions, multiplications and a modulo
local function work(n)
  local s = 0
  for i = 1, n do
    s = s + i * 3 % 7
  end
  return s
end
local total = 0
for r = 1, 10 do total = total + work(3000000) end
print(total)
