-- Hot loops that are not in a function that is called often: the main chunk, and a function called once that is not a kernel as a whole
-- (it makes a table), so that only on-stack replacement of its loop can help (docs/notes/ast.md, "Tiering").
local s = 0
for i = 1, 30000000 do s = s + i % 7 end
print(s)

local x, n = 1.5, 0
while n < 10000000 do
  x = x * 1.0000001 + 1e-9
  n = n + 1
end
print(x, n)

local function once(m)
  local t = {}
  local a = 0
  for i = 1, m do a = a + (i * i) % 13 end
  t[1] = a
  return t[1]
end
print(once(30000000))
