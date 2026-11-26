-- an error in a generic for's iterator: "in for iterator 'for iterator'"
local function gen(s, i)
  if i >= 2 then
    return nil + i
  end
  return i + 1
end

local function walk()
  for i in gen, nil, 0 do
    print("step", i)
  end
end

walk()
