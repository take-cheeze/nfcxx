-- local functions and the main chunk: "in local 'f'", "in upvalue 'f'", "in main chunk"
local function leaf(v)
  error("bad value " .. tostring(v))
end

local function middle(v)
  local r = leaf(v)
  return r
end

local function top()
  local a = middle(1)
  return a
end

top()
