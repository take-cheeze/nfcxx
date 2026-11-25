local function sq(x) return x * x end
local function apply(g, x) return g(x) end
local function twice(g, x) local y = g(x) return g(y) end
return twice(sq, 3) + apply(sq, 2)
