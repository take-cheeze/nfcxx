local function adder(a) return function(b) return a + b end end
local add5 = adder(5)
return add5(10)
