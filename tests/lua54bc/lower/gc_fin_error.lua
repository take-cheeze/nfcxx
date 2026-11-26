-- An error in a finalizer is not an error of the program (lua.c leaves the warnings off).
setmetatable({}, {__gc = function() error("boom") end})
collectgarbage()
print("survived")
setmetatable({}, {__gc = function() local t = nil; return t.x end})
collectgarbage()
print("still here")
return 1
