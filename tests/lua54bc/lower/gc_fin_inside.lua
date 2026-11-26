-- Inside a finalizer, collectgarbage gives nil, as lbaselib's fail does.
local mt = {__gc = function() print("inside", collectgarbage()) end}
setmetatable({}, mt)
collectgarbage()
print("outside", collectgarbage("count") > 0)
