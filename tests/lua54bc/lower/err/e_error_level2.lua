local function f()
  error("bad input", 2)
end
local function g()
  local x = 1
  f()
end
g()
