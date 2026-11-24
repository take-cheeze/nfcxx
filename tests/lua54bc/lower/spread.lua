local function g(...) return ... end
local function h(a, b) return a * 10 + b end
return h(g(3, 4))
