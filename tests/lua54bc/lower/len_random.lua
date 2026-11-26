-- Random updates of integer-keyed tables, with the length and the traversal order checked along the way. The generator
-- is a linear congruential one in integer arithmetic, so the sequence is the same for every Lua.
local seed = 20240601
local function rnd(n)
  seed = (seed * 1103515245 + 12345) & 0x7fffffff
  return seed % n + 1
end

local function order_hash(t)
  local h = 0
  for k in pairs(t) do h = (h * 31 + k) & 0xffffff end
  return h
end

local out = {}
for round = 1, 4 do
  local range = round * round * 16
  local t = {}
  for step = 1, 1500 do
    local op = rnd(12)
    local k = rnd(range)
    if op <= 4 then
      t[k] = step
    elseif op <= 7 then
      t[k] = nil
    elseif op <= 9 then
      t[#t + 1] = step
    elseif op == 10 then
      table.insert(t, step)
    elseif op == 11 then
      table.remove(t)
    else
      t[k] = nil
      t[k + 1] = nil
    end
    if step % 25 == 0 then out[#out + 1] = #t .. ":" .. order_hash(t) end
  end
  print(round, table.concat(out, " ", #out - 59, #out))
end

-- constructors with holes, built the same way every time
local sizes = {}
for n = 1, 12 do
  local t = {}
  for i = 1, n do
    if rnd(3) > 1 then t[i] = i end
  end
  sizes[#sizes + 1] = #t
end
print(table.concat(sizes, " "))
