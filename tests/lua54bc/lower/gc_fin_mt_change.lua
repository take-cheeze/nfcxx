-- The finalizer found is the one of the object's metatable when the object is finalized: a metatable without __gc
-- gives none, and an object given a metatable with __gc later is finalized.
local o = setmetatable({}, {__gc = function() print("not run: metatable changed") end})
setmetatable(o, {})
o = nil
collectgarbage()
local p = setmetatable({}, {})
getmetatable(p).__gc = function() print("not run either") end
p = nil
collectgarbage()
print("done")
