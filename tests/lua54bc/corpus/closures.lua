local function counter()
  local c = 0
  return function(d, ...) c = c + (d or 1); return c, select("#", ...) end
end
local f = counter()
local g = { f(), f(2, "x", "y") }
local s = "hello" .. " " .. tostring(#g) .. "world"
return s, g[1], ...
