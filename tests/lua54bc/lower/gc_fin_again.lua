-- A finalizer that sets a metatable with __gc again registers the object again: it is finalized once more.
local count = 0
local mt = {}
mt.__gc = function(o)
  count = count + 1
  print("gc", count)
  if count < 3 then setmetatable(o, mt) end
end
setmetatable({}, mt)
collectgarbage()
collectgarbage()
collectgarbage()
print("count", count)
