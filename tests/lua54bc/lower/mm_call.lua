local obj = setmetatable({}, {__call = function(self, a, b) return a + b end})
return obj(3, 4)
