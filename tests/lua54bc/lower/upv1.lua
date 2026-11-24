local function mk()
  local c = 0
  return function(d) c = c + d return c end
end
local f = mk()
f(1)
f(2)
return f(5)
